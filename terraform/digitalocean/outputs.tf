output "droplets" {
  description = "name => public IPv4 (for the record; use the tailnet name)"
  value       = { for name, d in digitalocean_droplet.this : name => d.ipv4_address }
}
