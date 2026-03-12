# ═══════════════════════════════════════════════════════════════════
# AWS CodePipeline — Full CI/CD for Lambda CRUD API
# Pipeline: GitHub → CodePipeline → CodeBuild → Lambda → Verified
# ═══════════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── Variables ──────────────────────────────────────────────────────
variable "aws_region"          { default = "us-east-1" }
variable "github_owner"        { description = "Your GitHub username" }
variable "github_repo"         { description = "Your GitHub repo name e.g. users-api" }
variable "github_branch"       { default = "main" }
variable "github_oauth_token"  { description = "GitHub personal access token", sensitive = true }
variable "lambda_function_name"{ default = "users-api" }
variable "api_url"             { default = "https://vo0720kqid.execute-api.us-east-1.amazonaws.com/dev/users" }

locals {
  project = "users-api-pipeline"
  tags    = { Project = "users-api", ManagedBy = "Terraform" }
}

# ══════════════════════════════════════════════════════════════════
# S3 BUCKET — stores build artifacts between stages
# ══════════════════════════════════════════════════════════════════
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.project}-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

data "aws_caller_identity" "current" {}

# ══════════════════════════════════════════════════════════════════
# IAM — CodePipeline Role
# ══════════════════════════════════════════════════════════════════
resource "aws_iam_role" "codepipeline" {
  name = "${local.project}-codepipeline-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "${local.project}-codepipeline-policy"
  role = aws_iam_role.codepipeline.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:ListBucket"]
        Resource = ["${aws_s3_bucket.artifacts.arn}", "${aws_s3_bucket.artifacts.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode", "lambda:GetFunction", "lambda:UpdateFunctionConfiguration"]
        Resource = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.lambda_function_name}"
      }
    ]
  })
}

# ══════════════════════════════════════════════════════════════════
# IAM — CodeBuild Role
# ══════════════════════════════════════════════════════════════════
resource "aws_iam_role" "codebuild" {
  name = "${local.project}-codebuild-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "codebuild" {
  name = "${local.project}-codebuild-policy"
  role = aws_iam_role.codebuild.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:ListBucket"]
        Resource = ["${aws_s3_bucket.artifacts.arn}", "${aws_s3_bucket.artifacts.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode", "lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:UpdateFunctionConfiguration", "lambda:InvokeFunction"]
        Resource = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.lambda_function_name}"
      }
    ]
  })
}

# ══════════════════════════════════════════════════════════════════
# CODEBUILD — Stage 1: Test + Package
# Runs pytest, zips code, uploads to S3
# ══════════════════════════════════════════════════════════════════
resource "aws_codebuild_project" "build" {
  name          = "${local.project}-build"
  description   = "Run tests and package Lambda"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 10

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "LAMBDA_FUNCTION_NAME"
      value = var.lambda_function_name
    }
    environment_variable {
      name  = "AWS_REGION_NAME"
      value = var.aws_region
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/build.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${local.project}-build"
      stream_name = "build-log"
    }
  }

  tags = local.tags
}

# ══════════════════════════════════════════════════════════════════
# CODEBUILD — Stage 2: Deploy to Lambda
# Takes zip artifact, deploys to Lambda
# ══════════════════════════════════════════════════════════════════
resource "aws_codebuild_project" "deploy" {
  name          = "${local.project}-deploy"
  description   = "Deploy Lambda function"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 10

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "LAMBDA_FUNCTION_NAME"
      value = var.lambda_function_name
    }
    environment_variable {
      name  = "AWS_REGION_NAME"
      value = var.aws_region
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/deploy.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${local.project}-deploy"
      stream_name = "deploy-log"
    }
  }

  tags = local.tags
}

# ══════════════════════════════════════════════════════════════════
# CODEBUILD — Stage 3: Smoke Test
# Calls live API and verifies 200 OK
# ══════════════════════════════════════════════════════════════════
resource "aws_codebuild_project" "verify" {
  name          = "${local.project}-verify"
  description   = "Smoke test live API"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 5

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "API_URL"
      value = var.api_url
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/verify.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${local.project}-verify"
      stream_name = "verify-log"
    }
  }

  tags = local.tags
}

# ══════════════════════════════════════════════════════════════════
# CODEPIPELINE — Orchestrates all 4 stages
# ══════════════════════════════════════════════════════════════════
resource "aws_codepipeline" "main" {
  name     = local.project
  role_arn = aws_iam_role.codepipeline.arn
  tags     = local.tags

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  # ── STAGE 1: SOURCE ────────────────────────────────────────────
  # Watches GitHub repo for new commits
  stage {
    name = "Source"
    action {
      name             = "GitHub-Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        Owner                = var.github_owner
        Repo                 = var.github_repo
        Branch               = var.github_branch
        OAuthToken           = var.github_oauth_token
        PollForSourceChanges = "true"
      }
    }
  }

  # ── STAGE 2: BUILD ─────────────────────────────────────────────
  # Run pytest + zip code
  stage {
    name = "Build"
    action {
      name             = "Test-and-Package"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  # ── STAGE 3: DEPLOY ────────────────────────────────────────────
  # Update Lambda with new zip
  stage {
    name = "Deploy"
    action {
      name            = "Deploy-to-Lambda"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.deploy.name
      }
    }
  }

  # ── STAGE 4: VERIFY ────────────────────────────────────────────
  # Smoke test the live API
  stage {
    name = "Verify"
    action {
      name            = "Smoke-Test-API"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.verify.name
      }
    }
  }
}

# ══════════════════════════════════════════════════════════════════
# CLOUDWATCH — Log groups for each stage
# ══════════════════════════════════════════════════════════════════
resource "aws_cloudwatch_log_group" "build" {
  name              = "/aws/codebuild/${local.project}-build"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "deploy" {
  name              = "/aws/codebuild/${local.project}-deploy"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "verify" {
  name              = "/aws/codebuild/${local.project}-verify"
  retention_in_days = 7
  tags              = local.tags
}

# ══════════════════════════════════════════════════════════════════
# OUTPUTS
# ══════════════════════════════════════════════════════════════════
output "pipeline_name" {
  value = aws_codepipeline.main.name
}

output "pipeline_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.main.name}/view"
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}
