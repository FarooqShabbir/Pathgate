#!/usr/bin/env bash
# Two private S3 buckets (static frontend builds), a CloudFront
# distribution routing /app1/*, /app2/* to them and /api/* to API
# Gateway, and a CloudFront Function standing in for nginx's
# try_files (S3 has no directory-index concept). No load balancer:
# CloudFront is a CDN/router, not a load balancer, and there's no
# compute behind the S3 origins to balance across.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/.env.foundation"

echo "== S3 buckets (private -- CloudFront reads them via OAC only) =="
APP1_BUCKET="pathgate-lambda-app1-${ACCOUNT_ID}"
APP2_BUCKET="pathgate-lambda-app2-${ACCOUNT_ID}"
for bucket in "$APP1_BUCKET" "$APP2_BUCKET"; do
  aws s3api head-bucket --bucket "$bucket" --region "$AWS_REGION" >/dev/null 2>&1 || {
    if [ "$AWS_REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$bucket" --region "$AWS_REGION" >/dev/null
    else
      aws s3api create-bucket --bucket "$bucket" --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
    fi
  }
  aws s3api put-public-access-block --bucket "$bucket" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
    --region "$AWS_REGION"
done

echo "== CloudFront Origin Access Control =="
OAC_ID="$(aws cloudfront list-origin-access-controls --region "$AWS_REGION" \
  --query "OriginAccessControlList.Items[?Name=='pathgate-lambda-oac'].Id | [0]" --output text)"
if [ -z "$OAC_ID" ] || [ "$OAC_ID" = "None" ]; then
  OAC_ID="$(aws cloudfront create-origin-access-control --origin-access-control-config '{
    "Name": "pathgate-lambda-oac",
    "SigningProtocol": "sigv4",
    "SigningBehavior": "always",
    "OriginAccessControlOriginType": "s3"
  }' --query OriginAccessControl.Id --output text)"
fi

echo "== CloudFront Function (directory-index rewrite) =="
FUNCTION_ETAG=""
if aws cloudfront describe-function --name pathgate-index-rewrite --region "$AWS_REGION" >/dev/null 2>&1; then
  FUNCTION_ETAG="$(aws cloudfront describe-function --name pathgate-index-rewrite --region "$AWS_REGION" --query ETag --output text)"
  aws cloudfront update-function --name pathgate-index-rewrite --if-match "$FUNCTION_ETAG" \
    --function-config '{"Comment":"Append index.html to directory-style requests","Runtime":"cloudfront-js-2.0"}' \
    --function-code "fileb://$HERE/cloudfront-function.js" --region "$AWS_REGION" >/dev/null
else
  aws cloudfront create-function --name pathgate-index-rewrite \
    --function-config '{"Comment":"Append index.html to directory-style requests","Runtime":"cloudfront-js-2.0"}' \
    --function-code "fileb://$HERE/cloudfront-function.js" --region "$AWS_REGION" >/dev/null
fi
FUNCTION_ETAG="$(aws cloudfront describe-function --name pathgate-index-rewrite --region "$AWS_REGION" --query ETag --output text)"
CF_FUNCTION_ARN="$(aws cloudfront publish-function --name pathgate-index-rewrite --if-match "$FUNCTION_ETAG" \
  --region "$AWS_REGION" --query FunctionSummary.FunctionMetadata.FunctionARN --output text)"

echo "== CloudFront distribution =="
CALLER_REFERENCE="pathgate-lambda-$(date +%s)"
APP1_BUCKET_DOMAIN="${APP1_BUCKET}.s3.${AWS_REGION}.amazonaws.com"
APP2_BUCKET_DOMAIN="${APP2_BUCKET}.s3.${AWS_REGION}.amazonaws.com"
FUNCTION_ARN="$CF_FUNCTION_ARN" \
CALLER_REFERENCE="$CALLER_REFERENCE" \
APP1_BUCKET_DOMAIN="$APP1_BUCKET_DOMAIN" \
APP2_BUCKET_DOMAIN="$APP2_BUCKET_DOMAIN" \
OAC_ID="$OAC_ID" \
APIGW_DOMAIN="$APIGW_DOMAIN" \
  envsubst < "$HERE/cloudfront-distribution-config.json.template" > "$HERE/cloudfront-distribution-config.json"

DIST_JSON="$(aws cloudfront create-distribution --distribution-config "file://$HERE/cloudfront-distribution-config.json" --region "$AWS_REGION")"
DIST_ID="$(echo "$DIST_JSON" | python -c "import json,sys; print(json.load(sys.stdin)['Distribution']['Id'])" 2>/dev/null \
  || echo "$DIST_JSON" | grep -o '"Id": *"[^"]*"' | head -1 | sed 's/.*"\(E[A-Z0-9]*\)".*/\1/')"
DIST_DOMAIN="$(aws cloudfront get-distribution --id "$DIST_ID" --region "$AWS_REGION" --query 'Distribution.DomainName' --output text)"
DIST_ARN="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"

echo "== Bucket policies (allow this distribution's OAC to read, nothing else) =="
for bucket in "$APP1_BUCKET" "$APP2_BUCKET"; do
  aws s3api put-bucket-policy --bucket "$bucket" --region "$AWS_REGION" --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"cloudfront.amazonaws.com\"},
      \"Action\": \"s3:GetObject\",
      \"Resource\": \"arn:aws:s3:::${bucket}/*\",
      \"Condition\": {\"StringEquals\": {\"AWS:SourceArn\": \"${DIST_ARN}\"}}
    }]
  }"
done

cat >> "$HERE/.env.foundation" <<EOF
export APP1_BUCKET="$APP1_BUCKET"
export APP2_BUCKET="$APP2_BUCKET"
export DIST_ID="$DIST_ID"
export DIST_DOMAIN="$DIST_DOMAIN"
EOF
echo "Wrote distribution info to $HERE/.env.foundation"
echo "CloudFront distribution created: https://$DIST_DOMAIN"
echo "(takes several minutes to reach Deployed status)"
echo "Next: ./deploy_frontends.sh"
