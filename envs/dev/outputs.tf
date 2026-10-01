output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "node_instance_id" {
  value = aws_instance.node.id
}
output "db_endpoint" {
  value = aws_db_instance.main.endpoint
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}

output "node_public_ip" {
  value = aws_eip.node.public_ip
}

# Read by scripts/bootstrap-cluster.sh to create the backend-secret Secret.
output "database_url" {
  value     = "postgresql+psycopg://${aws_db_instance.main.username}:${random_password.db.result}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${aws_db_instance.main.db_name}"
  sensitive = true
}

output "domain" {
  value = var.domain
}

# Read by scripts/bootstrap-cluster.sh to create the origin-tls Secret.
output "origin_cert_pem" {
  value = cloudflare_origin_ca_certificate.origin.certificate
}

output "origin_key_pem" {
  value     = tls_private_key.origin.private_key_pem
  sensitive = true
}
