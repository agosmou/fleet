terraform {
  required_version = ">= 1.8"
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = ">= 0.17"
    }
  }
  # State is local (gitignored) while this is one person's fleet. Move it to
  # a DO Spaces / S3 backend before a second workstation runs `just up`.
}

# Reads DIGITALOCEAN_TOKEN from the environment (secrets.env via direnv).
provider "digitalocean" {}
