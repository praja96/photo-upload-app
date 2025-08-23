terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}



# Random suffix for globally-unique bucket names
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  lambda_name     = "presign-post-${random_id.suffix.hex}"
  max_upload_bytes = var.max_upload_mb * 1024 * 1024
}



# ---------- Lambda that returns a presigned POST ----------

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/main.py"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_iam_role" "lambda_role" {
  name = "role-${local.lambda_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

# give the Lambda role permission to "sign" PutObject for your bucket
resource "aws_iam_role_policy" "lambda_put_to_bucket" {
  name = "allow-putobject-to-uploads"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid: "AllowPutObjectToUploadsPrefix",
        Effect: "Allow",
        Action: [
          "s3:PutObject"
          # If you ever add ACLs in presigned fields, also add:
          # "s3:PutObjectAcl"
        ],
        Resource: [
          # allow objects in the whole bucket (easiest):
          "arn:aws:s3:::*"
          # or narrowly, just your uploads prefix:
          # "arn:aws:s3:::rajas-wedding-photos-2025/uploads/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_list_buckets" {
  name = "allow-list-buckets-and-tags"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { "Effect":"Allow", "Action":["s3:ListAllMyBuckets"], "Resource":"*" },
      { "Effect":"Allow", "Action":["s3:GetBucketTagging","s3:GetBucketLocation","s3:GetBucketEncryption","s3:GetEncryptionConfiguration"],
        "Resource":"arn:aws:s3:::*" }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "presign" {
  function_name = local.lambda_name
  filename      = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  role          = aws_iam_role.lambda_role.arn
  handler       = "main.handler"
  runtime       = "python3.12"
  timeout       = 10

  environment {
    variables = {
      MAX_UPLOAD_BYTES = tostring(local.max_upload_bytes)
      //ALLOWED_BUCKETS = join(",", var.allowed_buckets)
    }
  }
}

resource "aws_lambda_alias" "prod" {
  name             = "prod"
  function_name    = aws_lambda_function.presign.function_name
  function_version = "$LATEST"
}

resource "aws_lambda_alias" "test" {
  name             = "test"
  function_name    = aws_lambda_function.presign.function_name
  function_version = "$LATEST"
}

# ---------- API Gateway (HTTP) in front of Lambda test -----------

resource "aws_apigatewayv2_api" "api_test" {
  name          = "${aws_lambda_function.presign.function_name}-http-test"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = [var.test_app_origin]  # only the staging site
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Authorization", "Content-Type"]
  }
}

resource "aws_apigatewayv2_integration" "lambda_integration_test" {
  api_id                 = aws_apigatewayv2_api.api_test.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = "${aws_lambda_function.presign.arn}:${aws_lambda_alias.test.name}"  # <- use invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000
}

resource "aws_apigatewayv2_authorizer" "cognito_test" {
  api_id           = aws_apigatewayv2_api.api_test.id
  name             = "cognito-test"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  jwt_configuration {
    audience = [aws_cognito_user_pool_client.web.id]  # same SPA client id
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.app.id}"
  }
}

resource "aws_apigatewayv2_route" "buckets_route_test" {
  api_id             = aws_apigatewayv2_api.api_test.id
  route_key          = "GET /buckets"
  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration_test.id}"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_test.id
  authorization_type = "JWT"
}

resource "aws_apigatewayv2_route" "presign_route_test" {
  api_id             = aws_apigatewayv2_api.api_test.id
  route_key          = "POST /presign"
  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration_test.id}"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_test.id
  authorization_type = "JWT"
}

resource "aws_apigatewayv2_stage" "default_test" {
  api_id      = aws_apigatewayv2_api.api_test.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw_test_invoke" {
  statement_id  = "AllowInvokeFromHttpApiStaging"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.presign.function_name
  qualifier     = aws_lambda_alias.test.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api_test.execution_arn}/*/*"
}

resource "aws_cloudwatch_log_group" "apigw_test" {
  name              = "/aws/api-http-test/${aws_apigatewayv2_api.api_test.name}"
  retention_in_days = 7
}


output "staging_api_base_url" {
  value = aws_apigatewayv2_api.api_test.api_endpoint
}


# ---------- API Gateway (HTTP API) in front of Lambda ----------

resource "aws_apigatewayv2_api" "api" {
  name          = "presign-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = [var.app_origin]                 # e.g., "http://localhost:3000"
    allow_methods = ["GET","POST","OPTIONS"]
    allow_headers = ["authorization","content-type"] # lowercase is safest
    expose_headers = ["etag","location"]
    max_age       = 86400
  }
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = aws_apigatewayv2_api.api.id
  authorizer_type  = "JWT"
  name             = "cognito-jwt"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    # Audience must be the User Pool App Client ID
    audience = [aws_cognito_user_pool_client.web.id]
    # Issuer must match your region + user pool ID
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.app.id}"
  }
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = "${aws_lambda_function.presign.arn}:${aws_lambda_alias.prod.name}"  # <- use invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000
}


resource "aws_apigatewayv2_route" "presign_route" {
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = "POST /presign"
  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
  authorization_type = "JWT"
}

resource "aws_apigatewayv2_route" "buckets_route" {
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = "GET /buckets"
  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
  authorization_type = "JWT"
}

# Catch-all with NO auth, so OPTIONS (and typos) don't 401
resource "aws_apigatewayv2_route" "default_route" {
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = "$default"
  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
  authorization_type = "NONE"     # <-- key change
  # no authorizer_id here
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/http-api/presign"
  retention_in_days = 7
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format = jsonencode({
      requestId    = "$context.requestId",
      routeKey     = "$context.routeKey",
      status       = "$context.status",
      error        = "$context.error.message",
      integration  = "$context.integration.error",
      jwtSub       = "$context.authorizer.claims.sub"
    })
  }
}

resource "aws_lambda_permission" "allow_apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.presign.function_name
  qualifier     = aws_lambda_alias.prod.name
  principal     = "apigateway.amazonaws.com"
  # Allow any stage/route of this API to invoke
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# Allow API Gateway to invoke the Lambda
resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowInvokeFromAPIGW"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.presign.function_name
  qualifier     = aws_lambda_alias.prod.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*/presign"
}

# ---------- Outputs ----------

output "api_base_url" {
  value = aws_apigatewayv2_api.api.api_endpoint
}

output "example_presign_url" {
  value = "${aws_apigatewayv2_api.api.api_endpoint}/presign"
}


# cognito.tf
resource "aws_cognito_user_pool" "app" {
  name = "uploader-users"
  auto_verified_attributes = ["email"]
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }
  # Optional: password policy, MFA, etc.
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "uploader-webclient"
  user_pool_id = aws_cognito_user_pool.app.id

  # Use OAuth code flow (recommended) — we'll start with a quick implicit flow in the frontend,
  # but keeping code flow enabled lets you upgrade to PKCE later without TF changes.
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code", "implicit"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  # Dev callbacks (add your production origin when ready)
  callback_urls = [
    "${var.app_origin}/callback",
    var.app_origin, "${var.test_app_origin}/callback",
    var.test_app_origin
  ]
  logout_urls = [var.app_origin,"${var.app_origin}/?signedout=1",var.test_app_origin,"${var.test_app_origin}/?signedout=1"]

  generate_secret = false
}

# Hosted UI domain (must be globally unique)
resource "aws_cognito_user_pool_domain" "domain" {
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.app.id
}
