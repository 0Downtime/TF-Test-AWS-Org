locals {
  issuer_url  = "https://${aws_cloudfront_distribution.oidc_metadata.domain_name}"
  issuer_host = replace(local.issuer_url, "https://", "")

  metadata_object_arns = [
    "${aws_s3_bucket.oidc_metadata.arn}/.well-known/openid-configuration",
    "${aws_s3_bucket.oidc_metadata.arn}/oauth/discovery/keys",
  ]
}

resource "aws_s3_bucket" "oidc_metadata" {
  bucket        = var.metadata_bucket_name
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "oidc_metadata" {
  bucket = aws_s3_bucket.oidc_metadata.id

  versioning_configuration {
    status = "Enabled"
  }
}

#trivy:ignore:AVD-AWS-0132:exp:2027-09-02
resource "aws_s3_bucket_server_side_encryption_configuration" "oidc_metadata" {
  bucket = aws_s3_bucket.oidc_metadata.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "oidc_metadata" {
  bucket                  = aws_s3_bucket.oidc_metadata.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "oidc_metadata" {
  bucket = aws_s3_bucket.oidc_metadata.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_cloudfront_origin_access_control" "oidc_metadata" {
  name                              = "${var.metadata_bucket_name}-oac"
  description                       = "CloudFront access to the private GitLab OIDC metadata bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "oidc_metadata" {
  enabled         = true
  comment         = "Public GitLab OIDC discovery and JWKS metadata"
  is_ipv6_enabled = true
  price_class     = var.cloudfront_price_class

  lifecycle {
    prevent_destroy = true
  }

  origin {
    domain_name              = aws_s3_bucket.oidc_metadata.bucket_regional_domain_name
    origin_id                = "S3-${var.metadata_bucket_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.oidc_metadata.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-${var.metadata_bucket_name}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    min_ttl                = 0
    default_ttl            = var.metadata_cache_seconds
    max_ttl                = var.metadata_cache_seconds

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

data "aws_iam_policy_document" "oidc_metadata_bucket" {
  statement {
    sid    = "AllowCloudFrontReadOnly"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = local.metadata_object_arns

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.oidc_metadata.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "oidc_metadata" {
  bucket = aws_s3_bucket.oidc_metadata.id
  policy = data.aws_iam_policy_document.oidc_metadata_bucket.json
}

resource "aws_iam_openid_connect_provider" "gitlab" {
  count = var.enable_iam_oidc_provider ? 1 : 0

  url             = local.issuer_url
  client_id_list  = [var.oidc_audience]
  thumbprint_list = length(var.oidc_thumbprints) > 0 ? var.oidc_thumbprints : null
}

data "aws_iam_policy_document" "gitlab_role_trust" {
  count = var.create_gitlab_role && var.enable_iam_oidc_provider ? 1 : 0

  statement {
    sid    = "GitLabWebIdentity"
    effect = "Allow"

    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gitlab[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host}:aud"
      values   = [var.oidc_audience]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host}:sub"
      values   = var.allowed_subjects
    }
  }
}

resource "aws_iam_role" "gitlab" {
  count = var.create_gitlab_role && var.enable_iam_oidc_provider ? 1 : 0

  name               = var.gitlab_role_name
  assume_role_policy = data.aws_iam_policy_document.gitlab_role_trust[0].json
  description        = "Workload role assumed by the approved private GitLab CI subjects."
}

resource "aws_iam_role_policy_attachment" "gitlab" {
  for_each = var.create_gitlab_role && var.enable_iam_oidc_provider ? var.gitlab_role_policy_arns : toset([])

  role       = aws_iam_role.gitlab[0].name
  policy_arn = each.value
}

data "aws_iam_policy_document" "metadata_sync_trust" {
  count = var.create_metadata_sync_role ? 1 : 0

  statement {
    sid    = "TrustedMetadataSyncPrincipals"
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.metadata_sync_principal_arns
    }
  }
}

data "aws_iam_policy_document" "metadata_sync_permissions" {
  count = var.create_metadata_sync_role ? 1 : 0

  statement {
    sid    = "ReadWriteOnlyOidcObjects"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]

    resources = local.metadata_object_arns
  }

  statement {
    sid    = "ReadBucketLocation"
    effect = "Allow"

    actions   = ["s3:GetBucketLocation"]
    resources = [aws_s3_bucket.oidc_metadata.arn]
  }
}

resource "aws_iam_role" "metadata_sync" {
  count = var.create_metadata_sync_role ? 1 : 0

  name               = var.metadata_sync_role_name
  assume_role_policy = data.aws_iam_policy_document.metadata_sync_trust[0].json
  description        = "Least-privilege role for synchronizing the two GitLab OIDC metadata objects."
}

resource "aws_iam_role_policy" "metadata_sync" {
  count = var.create_metadata_sync_role ? 1 : 0

  name   = "GitLabOidcMetadataSync"
  role   = aws_iam_role.metadata_sync[0].id
  policy = data.aws_iam_policy_document.metadata_sync_permissions[0].json
}

check "oidc_bootstrap_order" {
  assert {
    condition     = !var.create_gitlab_role || var.enable_iam_oidc_provider
    error_message = "create_gitlab_role requires enable_iam_oidc_provider=true after the public metadata has been synchronized."
  }
}

check "oidc_role_subjects" {
  assert {
    condition     = !var.create_gitlab_role || length(var.allowed_subjects) > 0
    error_message = "allowed_subjects must contain at least one exact GitLab sub claim when create_gitlab_role=true."
  }
}

check "sync_role_principals" {
  assert {
    condition     = !var.create_metadata_sync_role || length(var.metadata_sync_principal_arns) > 0
    error_message = "metadata_sync_principal_arns must contain at least one AWS principal when create_metadata_sync_role=true."
  }
}
