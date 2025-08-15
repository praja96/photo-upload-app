variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "max_upload_mb" {
  description = "Max upload size (MB) enforced in presigned policy"
  type        = number
  default     = 5368709120
}

variable "allowed_origin" {
  description = "Origin allowed by CORS (set to your site origin in prod)"
  type        = string
  default     = "*"
}

# variables.tf
variable "app_origin" {
  description = "Your web app origin"
  type        = string
  default     = "https://upload.therajas.net"
}

variable "test_app_origin" {
  description = "Your web app origin for test"
  type        = string
  default     = "https://upload-test.therajas.net"
}

variable "cognito_domain_prefix" {
  description = "Globally-unique domain prefix for Cognito Hosted UI"
  type        = string
  default     = "rajas-uploader" # change to something unique
}


