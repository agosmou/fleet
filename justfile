# just: the command runner. `just` alone lists these recipes with the
# comment above each. Tools come from flake.nix (loaded by direnv, or
# `nix develop`); nothing is installed on the workstation.
set shell := ["bash", "-euo", "pipefail", "-c"]

repo := justfile_directory()
tf := repo / "terraform/digitalocean"
ansible_dir := repo / "ansible"
playbook := "playbooks/site.yml"
# Every ssh from here is by tailnet name; a new machine's key is unknown on
# first contact, so accept it then and refuse any later change.
ssh := "ssh -o StrictHostKeyChecking=accept-new"
env_bootstrap := "https://raw.githubusercontent.com/agosmou/environment/main/bootstrap"
ts_api := "https://api.tailscale.com/api/v2"
# Bearer token for the Tailscale API from the OAuth client in secrets.env.
ts_token := "$(curl -fsS -d client_id=\"$TAILSCALE_OAUTH_CLIENT_ID\" -d client_secret=\"$TAILSCALE_OAUTH_CLIENT_SECRET\" " + ts_api + "/oauth/token | jq -r .access_token)"

default:
    @just --list --unsorted

# ---- The whole thing --------------------------------------------------------

# Birth to ready: create what terraform.tfvars describes, then configure NAME and give it the environment
new NAME: up (wait NAME) (apply "-l" NAME) (env NAME)

# ---- Existence: terraform ---------------------------------------------------

# Create or change droplets to match terraform.tfvars (asks before acting)
up:
    cd "{{tf}}" && tofu init -input=false >/dev/null && tofu apply

# Show what `just up` would do
plan:
    cd "{{tf}}" && tofu init -input=false >/dev/null && tofu plan

# Destroy every droplet in terraform.tfvars (asks before acting)
down:
    cd "{{tf}}" && tofu destroy

# ---- Tailnet: policy and birth keys -----------------------------------------

# Once: fetch the live tailnet policy into policy.hujson and import it, so the first plan is empty
acl-pull:
    cd "{{tf}}" && tofu init -input=false >/dev/null
    curl -fsS -H "Authorization: Bearer {{ts_token}}" -H "Accept: application/hujson" \
      "{{ts_api}}/tailnet/-/acl" > "{{tf}}/policy.hujson"
    cd "{{tf}}" && tofu import tailscale_acl.policy acl
    @echo "policy.hujson is now the live policy. Add tag:server under tagOwners if missing, then: just plan"

# Mint a single-use tag:server birth key (1 h) for a machine terraform does not create, e.g. a Pi's SD card
key NAME:
    @curl -fsS -H "Authorization: Bearer {{ts_token}}" -H "Content-Type: application/json" \
      -d '{"description":"fleet birth key for {{NAME}}","expirySeconds":3600,"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":false,"preauthorized":true,"tags":["tag:server"]}}}}' \
      "{{ts_api}}/tailnet/-/keys" | jq -r .key

# Which inventory hosts are on the tailnet right now, from this machine's view, no ssh
online:
    @cd "{{ansible_dir}}" && for h in $(ansible-inventory --list | jq -r '._meta.hostvars | keys[]'); do \
      printf '%-10s %s\n' "$h" "$(tailscale status --json | jq -r --arg h "$h" \
        '[.Peer[] | select(.HostName==$h)][0] | if . == null then "NOT ON TAILNET" elif .Online then "online" else "offline" end')"; done

# ---- Birth: cloud-init ------------------------------------------------------

# Block until HOST has finished its first boot and is on the tailnet
wait HOST:
    @printf 'waiting for %s on the tailnet...' "{{HOST}}"
    @until {{ssh}} -o ConnectTimeout=5 -o BatchMode=yes "{{HOST}}" true 2>/dev/null; do printf .; sleep 5; done; echo
    {{ssh}} "{{HOST}}" 'cloud-init status --wait --long'

# Render the first boot of NAME with placeholder secrets into .rendered/ and validate it
render NAME="do1":
    @mkdir -p "{{repo}}/.rendered"
    cd "{{tf}}" && tofu init -backend=false -input=false >/dev/null && \
      echo 'templatefile("{{repo}}/cloud-init/base.yaml.tftpl", { hostname = "{{NAME}}", ssh_keys = local.ssh_keys, passwd_hash = "$6$placeholder$placeholder", tailscale_authkey = "tskey-auth-PLACEHOLDER" })' \
      | tofu console -var ag_passwd_hash=x \
      | sed '1{/^<<EOT$/d};${/^EOT$/d}' > "{{repo}}/.rendered/{{NAME}}.yaml"
    cloud-init schema --config-file "{{repo}}/.rendered/{{NAME}}.yaml" 2>/dev/null
    @echo "rendered: .rendered/{{NAME}}.yaml"

# First-boot and tailnet state of HOST
status HOST:
    {{ssh}} "{{HOST}}" 'cloud-init status --long; echo; tailscale status --self --peers=false; echo; sudo -n ufw status 2>/dev/null || echo "(ufw status needs sudo: ssh in)"'

# ---- Steady state: ansible --------------------------------------------------

# Can ansible reach every host over the tailnet?
ping *ARGS:
    cd "{{ansible_dir}}" && ANSIBLE_BECOME=false ansible all -m ping {{ARGS}}

# Dry run: who is online, then what would change (asks for the sudo password). `just check -l spectre` for one host
check *ARGS: online
    cd "{{ansible_dir}}" && ansible-playbook {{playbook}} --check --diff -K {{ARGS}}

# Apply the configuration to every host, or `just apply -l NAME` for one
apply *ARGS:
    cd "{{ansible_dir}}" && ansible-playbook {{playbook}} --diff -K {{ARGS}}

# ---- User layer: ~/environment ----------------------------------------------

# Install the user environment on HOST as ag (interactive: nix's installer asks for sudo)
env HOST:
    {{ssh}} -t "{{HOST}}" 'curl -fsSL {{env_bootstrap}} | bash -s -- --target server'

# ---- Checks -----------------------------------------------------------------

# Syntax and formatting of everything, no network, no changes
lint:
    cd "{{tf}}" && tofu fmt -check -recursive && tofu init -backend=false -input=false >/dev/null && tofu validate
    cd "{{ansible_dir}}" && ansible-playbook {{playbook}} --syntax-check
    cd "{{ansible_dir}}" && ansible-inventory --graph
    just render
