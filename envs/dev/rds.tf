resource "random_password" "db" {
  length  = 32
  special = false # avoids URL-encoding headaches in connection strings
}

# The prod environment's own role and database on the same instance, created
# by scripts/bootstrap-cluster.sh (RDS is private: Terraform can't reach it).
resource "random_password" "db_prod" {
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "main" {
  name       = "url-shortener-dev"
  subnet_ids = module.vpc.private_subnet_ids

  tags = { Name = "url-shortener-dev" }
}

resource "aws_db_instance" "main" {
  identifier     = "url-shortener-dev"
  engine         = "postgres"
  engine_version = "17"
  instance_class = "db.t4g.micro"

  allocated_storage     = 20
  max_allocated_storage = 50 # autoscaling ceiling
  storage_encrypted     = true

  db_name  = "shortener"
  username = "shortener"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  backup_retention_period = 1
  skip_final_snapshot     = true # dev only: no snapshot on destroy
  deletion_protection     = false

  tags = { Name = "url-shortener-dev" }
}
