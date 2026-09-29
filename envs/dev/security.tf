resource "aws_security_group" "node" {
  name        = "url-shortener-dev-node"
  description = "k3s node: public HTTP/HTTPS, Kubernetes API from admin only"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "url-shortener-dev-node"
  }
}

resource "aws_vpc_security_group_ingress_rule" "node_http" {
  security_group_id = aws_security_group.node.id
  description       = "HTTP from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "node_https" {
  security_group_id = aws_security_group.node.id
  description       = "HTTPS from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
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
