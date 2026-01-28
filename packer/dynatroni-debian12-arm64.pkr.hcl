packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = env("DYNATRONI_AWS_REGION")
}

variable "source_ami" {
  type    = string
  default = env("DYNATRONI_SOURCE_AMI")
}

variable "instance_type" {
  type    = string
  default = env("DYNATRONI_INSTANCE_TYPE")
}

variable "ssh_username" {
  type    = string
  default = env("DYNATRONI_SSH_USERNAME")
}

variable "ami_name" {
  type    = string
  default = env("DYNATRONI_AMI_NAME")
}

variable "ami_description" {
  type    = string
  default = env("DYNATRONI_AMI_DESCRIPTION")
}

variable "iam_instance_profile" {
  type    = string
  default = env("DYNATRONI_IAM_INSTANCE_PROFILE")
}

variable "subnet_id" {
  type    = string
  default = env("DYNATRONI_SUBNET_ID")
}

variable "security_group_id" {
  type    = string
  default = env("DYNATRONI_SECURITY_GROUP_ID")
}

variable "ami_tags_json" {
  type    = string
  default = env("DYNATRONI_AMI_TAGS_JSON")
}

locals {
  ami_tags = var.ami_tags_json != "" ? jsondecode(var.ami_tags_json) : {}
}

source "amazon-ebs" "dynatroni" {
  region                  = var.aws_region
  source_ami              = var.source_ami
  instance_type           = var.instance_type
  ssh_username            = var.ssh_username
  ami_name                = var.ami_name
  ami_description         = var.ami_description
  subnet_id               = var.subnet_id
  security_group_id       = var.security_group_id
  iam_instance_profile    = var.iam_instance_profile
  tags                    = local.ami_tags

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 16
    volume_type           = "gp3"
    delete_on_termination = true
  }
}

build {
  name    = "dynatroni"
  sources = ["source.amazon-ebs.dynatroni"]

  provisioner "file" {
    source      = "packer/files/"
    destination = "/tmp/pack_files"
  }

  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [
      "set -euxo pipefail",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq python3-pip python3-venv",
      "sudo python3 -m venv /opt/patroni",
      "sudo /opt/patroni/bin/pip install --upgrade pip",
      "sudo /opt/patroni/bin/pip install patroni dynatroni boto3 psycopg2-binary",
      "sudo ln -sf /opt/patroni/bin/patroni /usr/local/bin/patroni",
      "sudo ln -sf /opt/patroni/bin/patronictl /usr/local/bin/patronictl",
      "sudo mkdir -p /etc/patroni",
      "sudo install -m 0644 -o root -g root /tmp/pack_files/etc/patroni/patroni.yml.template /etc/patroni/patroni.yml.template",
      "sudo install -m 0755 -o root -g root /tmp/pack_files/usr/local/bin/dynatroni-configure.sh /usr/local/bin/dynatroni-configure.sh",
      "sudo install -m 0644 -o root -g root /tmp/pack_files/etc/systemd/system/patroni.service /etc/systemd/system/patroni.service"
    ]
  }
}
