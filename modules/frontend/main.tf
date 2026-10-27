# =============================================================================
# FRONTEND MODULE
# A private S3 bucket for the website files, served by CloudFront over HTTPS.
# Only CloudFront can read the bucket (Origin Access Control).
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  name = "${var.project_name}-${var.environment}"

  # File extension -> Content-Type, so browsers know what each file is
  mime_types = {
    html = "text/html; charset=utf-8"
    css  = "text/css; charset=utf-8"
    js   = "application/javascript; charset=utf-8"
    json = "application/json"
    svg  = "image/svg+xml"
    png  = "image/png"
    ico  = "image/x-icon"
  }

  # Content Security Policy: where the page may load things from.
  #  - scripts and styles: only from our own site ('self')
  #  - network calls: our site, any API Gateway in our region, and Cognito
  #  - frame-ancestors 'none': nobody may embed our site (anti-clickjacking)
  content_security_policy = join("; ", [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self' data: https://*.amazonaws.com",
    "connect-src 'self' https://*.execute-api.${var.aws_region}.amazonaws.com https://cognito-idp.${var.aws_region}.amazonaws.com https://*.s3.amazonaws.com https://*.s3.${var.aws_region}.amazonaws.com",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
  ])
}

# -----------------------------------------------------------------------------
# S3 bucket: private storage for the website files
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "site" {
  #checkov:skip=CKV_AWS_21:Website files are rebuilt from Git by the pipeline; Git is the version history.
  #checkov:skip=CKV2_AWS_61:All files are managed by Terraform; nothing to expire.
  bucket = "${local.name}-web-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# CloudFront: HTTPS, global caching, security headers
# -----------------------------------------------------------------------------

# How CloudFront proves its identity to S3: it signs every request (SigV4)
resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${local.name}-site-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# AWS's ready-made caching policy, which respects our Cache-Control headers
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_response_headers_policy" "security" {
  #checkov:skip=CKV_AWS_259:HSTS is sent (1 year, subdomains). Rule also wants preload, which requires owning the domain; not possible for cloudfront.net.
  name = "${local.name}-security-headers"

  security_headers_config {
    content_type_options {
      override = true # X-Content-Type-Options: nosniff
    }

    frame_options {
      frame_option = "DENY" # never allow this site inside a frame
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    strict_transport_security {
      access_control_max_age_sec = 31536000 # one year: "always use HTTPS"
      include_subdomains         = true
      override                   = true
    }

    content_security_policy {
      content_security_policy = local.content_security_policy
      override                = true
    }
  }
}

resource "aws_cloudfront_distribution" "site" {
  #checkov:skip=CKV_AWS_174:Default *.cloudfront.net certificate can't set a minimum TLS version. Revisit with a custom domain and ACM certificate.
  #checkov:skip=CKV_AWS_68:WAF costs ~$5-10/month plus requests. Recommended before a real public launch (with rate-based rules).
  #checkov:skip=CKV_AWS_86:Static files only; all API requests are already in API Gateway access logs.
  #checkov:skip=CKV_AWS_310:Site is redeployed from Git by the pipeline in minutes; cross-region failover not justified.
  #checkov:skip=CKV2_AWS_42:Custom certificate needs a custom domain. Revisit with a domain and ACM certificate.
  #checkov:skip=CKV2_AWS_47:No WAF yet (see CKV_AWS_68). Log4j is a Java vulnerability; nothing here runs Java.
  enabled             = true
  comment             = "${local.name} website"
  default_root_object = "index.html"     # what to serve for "/"
  price_class         = "PriceClass_100" # cheapest: North America and Europe edges
  http_version        = "http2and3"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-site"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id           = "s3-site"
    viewer_protocol_policy     = "redirect-to-https" # http:// -> https://
    allowed_methods            = ["GET", "HEAD"]     # a static site is read-only
    cached_methods             = ["GET", "HEAD"]
    compress                   = true # gzip/brotli: smaller, faster downloads
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Free HTTPS certificate for the *.cloudfront.net address
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# -----------------------------------------------------------------------------
# Bucket policy: ONLY this CloudFront distribution may read the files
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "site" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    # Without this condition, ANY CloudFront distribution (including
    # someone else's) could read our bucket.
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket     = aws_s3_bucket.site.id
  policy     = data.aws_iam_policy_document.site.json
  depends_on = [aws_s3_bucket_public_access_block.site]
}

# -----------------------------------------------------------------------------
# Website files: every file in site_dir is uploaded to the bucket.
# (config.js is NOT here; it is generated in envs/<env>, see the explanation.)
# -----------------------------------------------------------------------------
resource "aws_s3_object" "site_files" {
  for_each = setsubtract(fileset(var.site_dir, "**"), ["config.js"])

  bucket       = aws_s3_bucket.site.id
  key          = each.value
  source       = "${var.site_dir}/${each.value}"
  etag         = filemd5("${var.site_dir}/${each.value}") # re-upload when the file changes
  content_type = lookup(local.mime_types, regex("[^.]+$", each.value), "application/octet-stream")

  # HTML must always be fresh (it points to everything else).
  # Other files may be cached for 5 minutes.
  cache_control = endswith(each.value, ".html") ? "no-cache" : "public, max-age=300"
}
