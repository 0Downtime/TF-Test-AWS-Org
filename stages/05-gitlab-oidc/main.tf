locals {
  oidc_issuer_url = "https://${aws_cloudfront_distribution.gitlab_oidc.domain_name}"
  oidc_claim_host = trimprefix(local.oidc_issuer_url, "https://")
}

resource "aws_s3_bucket" "gitlab_oidc" {
  bucket        = var.oidc_bucket_name
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "gitlab_oidc" {
  bucket = aws_s3_bucket.gitlab_oidc.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gitlab_oidc" {
  bucket = aws_s3_bucket.gitlab_oidc.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "gitlab_oidc" {
  bucket = aws_s3_bucket.gitlab_oidc.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "gitlab_oidc" {
  bucket                  = aws_s3_bucket.gitlab_oidc.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "gitlab_oidc" {
  name                              = "${var.oidc_bucket_name}-oac"
  description                       = "Private CloudFront access to GitLab OIDC metadata"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "gitlab_oidc" {
  enabled         = true
  comment         = "Public GitLab OIDC metadata mirror"
  price_class     = "PriceClass_100"
  is_ipv6_enabled = true

  origin {
    domain_name              = aws_s3_bucket.gitlab_oidc.bucket_regional_domain_name
    origin_id                = "gitlab-oidc-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.gitlab_oidc.id
  }

  default_cache_behavior {
    target_origin_id       = "gitlab-oidc-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 60
    max_ttl     = 300
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  depends_on = [aws_s3_bucket_public_access_block.gitlab_oidc]
}

data "aws_iam_policy_document" "gitlab_oidc_bucket" {
  statement {
    sid    = "AllowCloudFrontReadOnly"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.gitlab_oidc.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.gitlab_oidc.arn]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.gitlab_oidc.arn, "${aws_s3_bucket.gitlab_oidc.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "gitlab_oidc" {
  bucket = aws_s3_bucket.gitlab_oidc.id
  policy = data.aws_iam_policy_document.gitlab_oidc_bucket.json

  depends_on = [
    aws_s3_bucket_public_access_block.gitlab_oidc,
    aws_s3_bucket_ownership_controls.gitlab_oidc,
  ]
}

resource "aws_iam_openid_connect_provider" "gitlab" {
  count = var.create_aws_oidc_resources ? 1 : 0

  provider = aws.production

  url            = local.oidc_issuer_url
  client_id_list = [var.gitlab_oidc_audience]

  tags = {
    ManagedBy = "Terraform"
    Purpose   = "GitLabCI"
  }

  depends_on = [aws_s3_bucket_policy.gitlab_oidc]
}

data "aws_iam_policy_document" "gitlab_trust" {
  count = var.create_aws_oidc_resources ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gitlab[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_claim_host}:aud"
      values   = [var.gitlab_oidc_audience]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_claim_host}:sub"
      values   = [var.gitlab_subject]
    }
  }
}

resource "aws_iam_role" "gitlab" {
  count = var.create_aws_oidc_resources ? 1 : 0

  provider           = aws.production
  name               = var.gitlab_role_name
  assume_role_policy = data.aws_iam_policy_document.gitlab_trust[0].json

  tags = {
    ManagedBy = "Terraform"
    Purpose   = "GitLabCI"
  }
}

resource "aws_iam_role_policy" "gitlab" {
  count = var.create_aws_oidc_resources && var.gitlab_role_policy_json != null ? 1 : 0

  provider = aws.production
  name     = "${var.gitlab_role_name}-inline"
  role     = aws_iam_role.gitlab[0].name
  policy   = var.gitlab_role_policy_json
}
