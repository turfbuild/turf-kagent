# The engine's AWS identity: an IAM user whose one policy covers the Lambda
# fleet's own names and nothing else in the account, and one access key for
# it. Run once, by a person, with their own AWS session:
#
#   turf -C setup/aws up        (or: tofu -chdir=setup/aws apply)
#
# The key is written to .secrets/, where setup/secrets.sh reads it into the
# turf-aws Secret, which only the engine's pods mount. It is also in this
# directory's state file, which git ignores: keep both out of version control.
# The agent never sees the key, and a plan it brings can do only what this
# policy allows.
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.17"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "Region the fleets are created in. Keep it equal to AWS_REGION in manifests/turf/engine.yaml and the origin in manifests/kagent/egress-policy.yaml."
  type        = string
  default     = "us-west-2"
}

variable "name_prefix" {
  description = "Every function and role the engine may manage starts with this, followed by a dash. The agent names a stack's fleet <name_prefix>-<stack>."
  type        = string
  default     = "turf-kagent"
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

resource "aws_iam_user" "engine" {
  name          = "${var.name_prefix}-engine"
  force_destroy = true
}

resource "aws_iam_user_policy" "fleet" {
  name = "${var.name_prefix}-fleet"
  user = aws_iam_user.engine.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Functions"
        Effect = "Allow"
        Action = [
          "lambda:Get*",
          "lambda:List*",
          "lambda:CreateFunction",
          "lambda:DeleteFunction",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:AddPermission",
          "lambda:RemovePermission",
          "lambda:CreateFunctionUrlConfig",
          "lambda:UpdateFunctionUrlConfig",
          "lambda:DeleteFunctionUrlConfig",
          "lambda:TagResource",
          "lambda:UntagResource",
        ]
        Resource = "arn:aws:lambda:${var.aws_region}:${local.account_id}:function:${var.name_prefix}-*"
      },
      {
        Sid    = "ExecutionRole"
        Effect = "Allow"
        Action = [
          "iam:Get*",
          "iam:List*",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:UpdateRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
        ]
        Resource = "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"
      },
      # A role the key creates can carry one managed policy, the one the fleet's
      # execution role needs, and can be handed to Lambda and to nothing else:
      # the name prefix alone would let such a role be given any policy.
      {
        Sid      = "ExecutionRolePolicy"
        Effect   = "Allow"
        Action   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
        Resource = "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"
        Condition = {
          ArnEquals = {
            "iam:PolicyARN" = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
          }
        }
      },
      {
        Sid      = "PassExecutionRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"
        Condition = {
          StringEquals = { "iam:PassedToService" = "lambda.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_iam_access_key" "engine" {
  user = aws_iam_user.engine.name
}

# No trailing newline in either file: kubectl stores a file's bytes as they are.
resource "local_sensitive_file" "access_key_id" {
  filename        = "${path.module}/../../.secrets/aws-access-key-id"
  content         = aws_iam_access_key.engine.id
  file_permission = "0600"
}

resource "local_sensitive_file" "secret_access_key" {
  filename        = "${path.module}/../../.secrets/aws-secret-access-key"
  content         = aws_iam_access_key.engine.secret
  file_permission = "0600"
}

output "user" {
  description = "The IAM user the engine acts as."
  value       = aws_iam_user.engine.arn
}
