terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.43.0"
    }
    sops = {
      source = "carlpett/sops"
      version = "1.0.0"
    }
  }
  /** Change here for your own tfstate backend
  backend "s3" {
    bucket = "tfstate"
    key    = "minio/tfstate"
    region = "eu-central-1"
  }*/
}

data "sops_file" "secrets" {
  source_file = "secrets.enc.yaml"
}

variable "flynnt_cluster" {
  type = string
  description = "The cluster name that will be used for nodes"
}

# Configure the Hetzner Cloud Provider
provider "hcloud" {
  token = data.sops_file.secrets.data["hcloud_token"]
}

locals {
  cluster_members = ["minio-1", "minio-2"]
}

data "hcloud_ssh_keys" "all_keys" {}

data "hcloud_image" "ubuntu_image" {
  name              = "ubuntu-22.04"
  with_architecture = "x86"
  most_recent = true
}

resource "hcloud_server" "node" {
  for_each    = toset(local.cluster_members)
  name        = each.key
  image       = data.hcloud_image.ubuntu_image.id
  server_type = "cx31"
  location    = "nbg1"

  ssh_keys = data.hcloud_ssh_keys.all_keys.ssh_keys.*.name

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }
  labels = {
    project = "flynnt-minio"
  }
  lifecycle {
    ignore_changes = [
      image,
    ]
  }

  user_data = <<-EOF
    #cloud-config
    runcmd:
    - curl -s https://github.com/flynnt-io/flynnt-agent-install/releases/latest/download/flynnt.sh | API_KEY=${data.sops_file.secrets.data["flynnt_token"]} bash -s - install -c ${var.flynnt_cluster} -n ${each.key}
  EOF
}

resource "hcloud_firewall" "basic_firewall" {
  name = "firewall"
  // Enabled this to allow ssh access
  /*
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }*/
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "443"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "80"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }
}

resource "hcloud_firewall_attachment" "fw_ref" {
    firewall_id = hcloud_firewall.basic_firewall.id
    server_ids  = [for node in hcloud_server.node : node.id]
}

output "host_ips" {
  value = [for node in hcloud_server.node : node.ipv4_address]
}
