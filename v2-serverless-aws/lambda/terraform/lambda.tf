# Run ../backend/build.sh before the first `terraform apply` -- it
# produces function.zip, which this resource packages and uploads.
resource "aws_lambda_function" "backend" {
  function_name    = "${var.project}-backend"
  role              = aws_iam_role.lambda_exec.arn
  handler           = "handler.handler"
  runtime           = "python3.12"
  filename          = "${path.module}/../backend/function.zip"
  source_code_hash  = filebase64sha256("${path.module}/../backend/function.zip")
  timeout           = 10
  memory_size       = 256

  environment {
    variables = {
      STORAGE_BACKEND = "dynamodb"
      DYNAMODB_TABLE  = aws_dynamodb_table.items.name
    }
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backend.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}
