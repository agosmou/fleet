locals {
  # Public keys allowed to log in as ag, shared with every other target.
  ssh_keys = [
    for line in split("\n", file("${path.module}/../../cloud-init/authorized_keys")) :
    trimspace(line) if trimspace(line) != ""
  ]
}

resource "digitalocean_droplet" "this" {
  for_each = var.droplets

  name   = each.key
  size   = each.value.size
  region = each.value.region
  image  = each.value.image

  # No provider-injected root key: the only way in is ag over the tailnet,
  # set up by cloud-init below.
  user_data = templatefile("${path.module}/../../cloud-init/base.yaml.tftpl", {
    hostname          = each.key
    ssh_keys          = local.ssh_keys
    passwd_hash       = var.ag_passwd_hash
    tailscale_authkey = tailscale_tailnet_key.birth[each.key].key
  })

  lifecycle {
    # user_data is consumed once at first boot and cannot change on DO
    # anyway; never let a re-rendered template try to replace the droplet.
    ignore_changes = [user_data]
  }

  monitoring = true
  ipv6       = true
  tags       = ["fleet"]
}

# The provider's firewall, in front of ufw. Nothing inbound from the
# internet except Tailscale's WireGuard port; with that, even a machine
# whose ufw failed to enable exposes nothing.
resource "digitalocean_firewall" "tailnet_only" {
  name        = "fleet-tailnet-only"
  droplet_ids = [for d in digitalocean_droplet.this : d.id]

  inbound_rule {
    protocol         = "udp"
    port_range       = "41641"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# Hand the fleet to ansible: every droplet is in the vps group, reached by
# its tailnet name. Committed, so the inventory in git is the whole fleet.
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../../ansible/inventory/20-vps.yml"
  file_permission = "0644"
  content = yamlencode({
    all = {
      children = {
        vps = {
          # Names only: ansible connects by tailnet name, and this file is
          # public. `just up` prints the IPs if you ever need one.
          hosts = { for name, d in digitalocean_droplet.this : name => {} }
        }
      }
    }
  })
}
