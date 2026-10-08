# Cloudflare fronts the app: proxied DNS, TLS to visitors, and an Origin CA
# cert so the Cloudflare -> node leg is encrypted too ("Full (strict)").
#
# Auth: export CLOUDFLARE_API_TOKEN, scoped to this zone with
#   Zone:Read, DNS:Edit, Zone Settings:Edit, SSL and Certificates:Edit
provider "cloudflare" {}

variable "domain" {
  description = "Cloudflare zone the app is served on (apex)"
  type        = string
  default     = "supabase.win"
}

data "cloudflare_zone" "main" {
  filter = { name = var.domain }
}

resource "cloudflare_dns_record" "apex" {
  zone_id = data.cloudflare_zone.main.zone_id
  name    = var.domain
  type    = "A"
  content = aws_eip.node.public_ip
  proxied = true
  ttl     = 1 # automatic (required for proxied records)
}

resource "cloudflare_zone_setting" "ssl" {
  zone_id    = data.cloudflare_zone.main.zone_id
  setting_id = "ssl"
  value      = "strict"
}

resource "cloudflare_zone_setting" "always_use_https" {
  zone_id    = data.cloudflare_zone.main.zone_id
  setting_id = "always_use_https"
  value      = "on"
}

# Origin CA cert: trusted only by Cloudflare's edge, which is all that ever
# talks to the node. The key lives in (encrypted) state, like the DB password;
# scripts/bootstrap-cluster.sh loads both into the origin-tls Secret.
resource "tls_private_key" "origin" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "origin" {
  private_key_pem = tls_private_key.origin.private_key_pem

  subject {
    common_name = var.domain
  }
}

resource "cloudflare_origin_ca_certificate" "origin" {
  csr = tls_cert_request.origin.cert_request_pem
  # In the order the API returns them; any other order shows as a perpetual
  # diff that forces a new certificate.
  hostnames          = ["*.${var.domain}", var.domain]
  request_type       = "origin-ecc"
  requested_validity = 5475 # 15 years, the maximum
}
