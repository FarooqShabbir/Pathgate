#!/usr/bin/env bash
# Reverse of 01/02. CloudFront distributions must be disabled before
# they can be deleted, and that takes a few minutes to propagate --
# this script disables it, waits, then deletes everything else, and
# tells you to re-run once more for the distribution itself once it
# reports Deployed after being disabled.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/.env.foundation"

echo "== Emptying + deleting S3 buckets =="
for bucket in "$APP1_BUCKET" "$APP2_BUCKET"; do
  aws s3 rm "s3://$bucket" --recursive --region "$AWS_REGION" >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "$bucket" --region "$AWS_REGION" 2>/dev/null || true
done

echo "== Disabling CloudFront distribution (delete requires Disabled + Deployed) =="
ETAG="$(aws cloudfront get-distribution-config --id "$DIST_ID" --region "$AWS_REGION" --query ETag --output text 2>/dev/null || true)"
if [ -n "$ETAG" ]; then
  aws cloudfront get-distribution-config --id "$DIST_ID" --region "$AWS_REGION" --query DistributionConfig \
    | python -c "import json,sys; c=json.load(sys.stdin); c['Enabled']=False; print(json.dumps(c))" \
    > "$HERE/.disable-dist.json" 2>/dev/null || true
  if [ -s "$HERE/.disable-dist.json" ]; then
    aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
      --distribution-config "file://$HERE/.disable-dist.json" --region "$AWS_REGION" >/dev/null 2>&1 || true
    rm -f "$HERE/.disable-dist.json"
    echo "Disabled. Wait for it to report Deployed (aws cloudfront get-distribution --id $DIST_ID), then:"
    echo "  ETAG=\$(aws cloudfront get-distribution-config --id $DIST_ID --query ETag --output text)"
    echo "  aws cloudfront delete-distribution --id $DIST_ID --if-match \$ETAG"
  fi
fi

echo "== Deleting Lambda function, API Gateway, DynamoDB table =="
aws lambda delete-function --function-name "$FUNCTION_NAME" --region "$AWS_REGION" 2>/dev/null || true
aws apigatewayv2 delete-api --api-id "$API_ID" --region "$AWS_REGION" 2>/dev/null || true
aws dynamodb delete-table --table-name "$TABLE_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || true

echo "== Deleting IAM role =="
aws iam delete-role-policy --role-name pathgate-lambda-exec-role --policy-name pathgate-dynamodb-access 2>/dev/null || true
aws iam detach-role-policy --role-name pathgate-lambda-exec-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam delete-role --role-name pathgate-lambda-exec-role 2>/dev/null || true

echo "Done (except the final CloudFront delete-distribution step above, if printed)."
