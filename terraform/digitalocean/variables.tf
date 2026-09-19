# The fleet: one entry per droplet, keyed by its name. The name is also the
# hostname, the tailnet name, and the ansible inventory name, so a machine
# is called the same thing everywhere. Add an entry, `just up`; remove it,
# `just up` again.
variable "droplets" {
  type = map(object({
    size   = optional(string, "s-1vcpu-1gb") # $6/mo; `doctl compute size list`
    region = optional(string, "sfo3")        # `doctl compute region list`
    image  = optional(string, "ubuntu-26-04-x64")
  }))
  default = {}
}

# `openssl passwd -6` output for ag's password. TF_VAR_ag_passwd_hash.
variable "ag_passwd_hash" {
  type      = string
  sensitive = true
}
