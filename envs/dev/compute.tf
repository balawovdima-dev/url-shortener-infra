data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_instance" "node" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.medium"
  subnet_id              = module.vpc.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name
  depends_on             = [module.vpc]

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    # Wait for outbound connectivity (NAT route may not be ready at boot)
    for i in $(seq 1 30); do
      curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh && head -1 /tmp/k3s-install.sh | grep -q '^#!' && break
      echo "no usable installer yet, attempt $i"
      sleep 10
    done

    snap install amazon-ssm-agent --classic || true
    snap start amazon-ssm-agent || true

    INSTALL_K3S_EXEC="--disable=traefik" sh /tmp/k3s-install.sh
  EOF

  # Re-run user_data when the script changes (instance is replaced)
  user_data_replace_on_change = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "url-shortener-dev-node"
  }
}
