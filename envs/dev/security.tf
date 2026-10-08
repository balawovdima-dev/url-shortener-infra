resource "aws_security_group" "node" {
  # name_prefix + create_before_destroy: changing the description replaces the
  # group, and the new one must exist before the node lets go of the old one.
  name_prefix = "url-shortener-dev-node-"
  description = "k3s node: HTTPS from Cloudflare only, admin via SSM"
  vpc_id      = module.vpc.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "url-shortener-dev-node"
  }
}

# Cloudflare's edge is the only client of the origin (proxied DNS, SSL mode
# "Full (strict)" over 443). No port 80: Cloudflare redirects visitors to
# HTTPS itself, and Traefik answers plain HTTP with 404 anyway.
data "cloudflare_ip_ranges" "cf" {}

resource "aws_vpc_security_group_ingress_rule" "node_https_cloudflare" {
  for_each = toset(data.cloudflare_ip_ranges.cf.ipv4_cidrs)

  security_group_id = aws_security_group.node.id
  description       = "HTTPS from Cloudflare"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  description       = "Outbound: image pulls, packages, SSM"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "db" {
  name        = "url-shortener-dev-db"
  description = "RDS Postgres: reachable only from cluster nodes"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "url-shortener-dev-db"
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_node" {
  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from k3s nodes"
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
