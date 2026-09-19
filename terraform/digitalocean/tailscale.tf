# The tailnet as infrastructure: the policy (tags, who may reach what) and
# a birth key per droplet. Credentials: TAILSCALE_OAUTH_CLIENT_ID and
# TAILSCALE_OAUTH_CLIENT_SECRET from secrets.env (an OAuth client with the
# auth_keys and policy_file write scopes).
provider "tailscale" {}

# The whole policy file, in git. Applying REPLACES what the admin console
# holds, so anything clicked there is reverted; edit policy.hujson instead.
# First time: `just acl-pull` fetches the live policy into policy.hujson
# and imports it, so the first plan is empty.
resource "tailscale_acl" "policy" {
  acl = file("${path.module}/policy.hujson")
}

# One single-use key per droplet, minted right before the droplet is
# created and handed to cloud-init. Spent on first `tailscale up`, so the
# copy that stays readable in the droplet's user-data is worthless.
# tag:server: the node is a machine identity, not a user's device, and
# tagged nodes never key-expire.
resource "tailscale_tailnet_key" "birth" {
  for_each = var.droplets

  description   = "fleet birth key for ${each.key}"
  reusable      = false
  ephemeral     = false
  preauthorized = true
  expiry        = 3600 # one hour to be born
  tags          = ["tag:server"]

  # Once used the key is invalid by design; do not mint a fresh one on
  # every plan (a changed user_data would try to replace the droplet).
  recreate_if_invalid = "never"

  depends_on = [tailscale_acl.policy] # tag:server must exist first
}
