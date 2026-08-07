#!/usr/bin/env bash
# Plain AWS CLI, no Terraform, no CloudFormation. Run backend/build.sh
# first. Creates: the DynamoDB table (replaces Postgres for this
# variant -- see README for why), the Lambda execution role, the
# Lambda function itself, and an API Gateway HTTP API in front of it
# with a single ANY /api/{proxy+} route. No load balancer anywhere in
# this file -- API Gateway is a managed API front door, not a load
# balancer, and Lambda has no EC2/Fargate compute to balance across.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${AWS_REGION:=us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

if [ ! -f "$HERE/backend/function.zip" ]; then
  echo "Run ./backend/build.sh first (no function.zip yet)." >&2
  exit 1
fi

echo "== DynamoDB table =="
TABLE_NAME="pathgate-lambda-items"
aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || \
  aws dynamodb create-table --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION" >/dev/null
aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$AWS_REGION"

echo "== Lambda execution role =="
ROLE_NAME="pathgate-lambda-exec-role"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]
  }' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name pathgate-dynamodb-access --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{\"Effect\": \"Allow\", \"Action\": [\"dynamodb:PutItem\", \"dynamodb:Scan\", \"dynamodb:DescribeTable\"], \"Resource\": \"arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}\"}]
  }" >/dev/null
  echo "Waiting for IAM role propagation..."
  sleep 10
fi
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo "== Lambda function =="
FUNCTION_NAME="pathgate-lambda-backend"
if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://$HERE/backend/function.zip" --region "$AWS_REGION" >/dev/null
else
  aws lambda create-function --function-name "$FUNCTION_NAME" \
    --runtime python3.12 --handler handler.handler --role "$ROLE_ARN" \
    --zip-file "fileb://$HERE/backend/function.zip" \
    --timeout 10 --memory-size 256 \
    --environment "Variables={STORAGE_BACKEND=dynamodb,DYNAMODB_TABLE=$TABLE_NAME}" \
    --region "$AWS_REGION" >/dev/null
fi
aws lambda wait function-active --function-name "$FUNCTION_NAME" --region "$AWS_REGION"
FUNCTION_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"

echo "== API Gateway (HTTP API) =="
API_ID="$(aws apigatewayv2 get-apis --region "$AWS_REGION" \
  --query "Items[?Name=='pathgate-lambda-api'].ApiId | [0]" --output text)"
if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
  API_ID="$(aws apigatewayv2 create-api --name pathgate-lambda-api --protocol-type HTTP \
    --region "$AWS_REGION" --query ApiId --output text)"
fi

INTEGRATION_ID="$(aws apigatewayv2 create-integration --api-id "$API_ID" \
  --integration-type AWS_PROXY --integration-uri "$FUNCTION_ARN" \
  --payload-format-version 2.0 --region "$AWS_REGION" --query IntegrationId --output text)"

aws apigatewayv2 create-route --api-id "$API_ID" \
  --route-key 'ANY /api/{proxy+}' --target "integrations/$INTEGRATION_ID" \
  --region "$AWS_REGION" >/dev/null

aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' \
  --auto-deploy --region "$AWS_REGION" >/dev/null 2>&1 || true

aws lambda add-permission --function-name "$FUNCTION_NAME" \
  --statement-id apigw-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${API_ID}/*/*" \
  --region "$AWS_REGION" >/dev/null 2>&1 || true

APIGW_DOMAIN="${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"

cat > "$HERE/.env.foundation" <<EOF
export AWS_REGION="$AWS_REGION"
export ACCOUNT_ID="$ACCOUNT_ID"
export TABLE_NAME="$TABLE_NAME"
export FUNCTION_NAME="$FUNCTION_NAME"
export API_ID="$API_ID"
export APIGW_DOMAIN="$APIGW_DOMAIN"
EOF
echo "Wrote $HERE/.env.foundation"
echo "API Gateway domain: https://$APIGW_DOMAIN/api/health (works standalone already)"
echo "Next: ./02-setup-cloudfront.sh"
