# Stand-in for the RDS/db container used everywhere else. Chosen for
# this variant specifically because it needs no VPC, no NAT gateway,
# and no connection pooling in front of it -- all things a Lambda
# talking to RDS would otherwise need. See apps/backend/app/storage
# for the DynamoStorage driver this table backs.
resource "aws_dynamodb_table" "items" {
  name         = "${var.project}-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}
