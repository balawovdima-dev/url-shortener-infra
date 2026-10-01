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
  subnet_id              = module.vpc.public_subnet_ids[0] # public: serves HTTP via the Elastic IP below
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    # Wait for outbound connectivity (networking may not be ready at boot)
    for i in $(seq 1 30); do
      curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh && head -1 /tmp/k3s-install.sh | grep -q '^#!' && break
      echo "no usable installer yet, attempt $i"
      sleep 10
    done

    snap install amazon-ssm-agent --classic || true
    snap start amazon-ssm-agent || true

    # Pinned so a rebuilt node runs the same Kubernetes. k3s's bundled Traefik
    # serves the Ingress on host ports 80/443 (via ServiceLB).
    INSTALL_K3S_VERSION="${var.k3s_version}" sh /tmp/k3s-install.sh
  EOF

  # ANY edit to user_data (even a comment) REBUILDS the node and wipes the
  # cluster. Afterwards run scripts/bootstrap-cluster.sh to restore the app.
  user_data_replace_on_change = true

  lifecycle {
    # A new Ubuntu image must not silently replace the node.
    ignore_changes = [ami]
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "url-shortener-dev-node"
  }
}

variable "k3s_version" {
  description = "k3s release installed on the node (bump deliberately: changing it rebuilds the node)"
  type        = string
  default     = "v1.36.4+k3s1"
}

resource "aws_eip" "node" {
  domain = "vpc"
  tags   = { Name = "url-shortener-dev-node" }
}

resource "aws_eip_association" "node" {
  instance_id   = aws_instance.node.id
  allocation_id = aws_eip.node.id
}
