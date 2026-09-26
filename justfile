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

# ---- Everyday: the same verbs as environment ---------------------------------
# sync, check, apply, update, doctor mean what they mean in ~/environment,
# applied to the fleet instead of to this machine: the tailnet policy and
# the droplets (terraform), then every host's configuration (ansible).

# fleet acts on the servers and the tailnet from the workstation that holds
# secrets.env and the terraform state; a server never runs it (it runs only
# ~/environment's `just sync`). Every recipe that touches terraform or the
# hosts starts here, so the mistake is a sentence, not `tofu: not found`.
[private]
workstation:
    @[[ -f "{{repo}}/secrets.env" ]] || { echo "fleet runs from the workstation that has secrets.env and the terraform state (t14s), not here." >&2; echo "On a server, only: cd ~/environment && just sync" >&2; exit 1; }
    @command -v tofu >/dev/null || { echo "tofu is not on PATH: the dev shell is not loaded. Run: direnv allow (or prefix: nix develop -c just ...)" >&2; exit 1; }

# Bring the fleet up to date: pull, show every change, ask once, apply it all, then doctor
sync: workstation
    @cd "{{repo}}" && if git diff --quiet && git diff --cached --quiet; then git pull --ff-only; else echo "local changes present; not pulling"; fi
    cd "{{tf}}" && tofu init -input=false >/dev/null && tofu plan -out=sync.tfplan
    just online
    cd "{{ansible_dir}}" && ansible-playbook {{playbook}} --check --diff
    @read -rp "Apply all of the above? [y/N] " a; [[ "$a" == [yY] ]] || { rm -f "{{tf}}/sync.tfplan"; echo "nothing applied"; exit 1; }
    cd "{{tf}}" && tofu apply sync.tfplan && rm -f sync.tfplan
    cd "{{ansible_dir}}" && ansible-playbook {{playbook}} --diff
    just doctor

# Dry run of everything, changes nothing: terraform's plan, then who is online and what ansible would change. `just check -l spectre` for one host
check *ARGS: plan online
    cd "{{ansible_dir}}" && ansible-playbook {{playbook}} --check --diff {{ARGS}}

# A machine that still asks for a sudo password (built by hand, never
# converged): add -K once; roles/base then makes sudo passwordless.
# Apply everything: terraform (asks when there is a change), then every host, or `just apply -l NAME` for one
apply *ARGS: workstation
    cd "{{tf}}" && tofu init -input=false >/dev/null && tofu apply
    cd "{{ansible_dir}}" && ansible-playbook {{playbook}} --diff {{ARGS}}

# Update flake.lock (the tools) and the terraform provider lock to the newest versions. Then check, apply, commit both
update:
    @token="$(gh auth token 2>/dev/null)"; [[ -n "$token" ]] || { echo "no GitHub token; run: gh auth login" >&2; exit 1; }
    nix flake update --flake "{{repo}}" --option access-tokens "github.com=$(gh auth token)"
    cd "{{tf}}" && tofu init -upgrade -input=false >/dev/null && echo "terraform providers: .terraform.lock.hcl updated"

# Compare the fleet against the repository: this workstation can run it, and every host is on the tailnet with its tag. No ssh
doctor:
    #!/usr/bin/env bash
    set -euo pipefail
    fails=0
    ok()   { printf 'ok    %s\n' "$1"; }
    look() { printf 'look  %s\n' "$1"; }
    bad()  { printf 'FAIL  %s\n' "$1"; fails=1; }
    [[ -f "{{repo}}/secrets.env" ]] && ok "secrets.env present" \
      || bad "secrets.env missing: cp secrets.env.example secrets.env, values from Bitwarden"
    [[ -f "{{tf}}/terraform.tfstate" ]] && ok "terraform state present" \
      || look "no terraform state here; plan/up would start from nothing. Run fleet from the workstation that has it"
    status="$(tailscale status --json)"
    cd "{{ansible_dir}}"
    # tailscale_tag per host comes from the inventory (group_vars/all.yml,
    # overridden per host), the same value roles/tailscale asserts.
    while IFS=$'\t' read -r host tag; do
      node="$(jq -c --arg h "$host" '[.Self, (.Peer // {} | .[])] | map(select(.HostName == $h)) | .[0]' <<<"$status")"
      if [[ "$node" == null ]]; then
        bad "$host is not on the tailnet (new or reinstalled? just join $host)"; continue
      fi
      if jq -e --arg t "$tag" '(.Tags // []) | index($t)' <<<"$node" >/dev/null; then
        ok "$host carries $tag"
      else
        bad "$host is on the tailnet without $tag, so the policy treats it as one of your devices. Fix: just join $host"
      fi
      [[ "$(jq -r .Online <<<"$node")" == true ]] && ok "$host online" || look "$host offline"
    done < <(ansible-inventory --list | jq -r '._meta.hostvars | to_entries[] | [.key, (.value.tailscale_tag // "tag:server")] | @tsv')
    exit "$fails"

# ---- The whole thing --------------------------------------------------------

# Birth to ready: create what terraform.tfvars describes, then configure NAME and give it the environment
new NAME: up (wait NAME) (apply "-l" NAME) (env NAME)

# ---- Existence: terraform ---------------------------------------------------

# Create or change droplets to match terraform.tfvars (asks before acting)
up: workstation
    cd "{{tf}}" && tofu init -input=false >/dev/null && tofu apply

# Show what `just up` would do
plan: workstation
    cd "{{tf}}" && tofu init -input=false >/dev/null && tofu plan

# Destroy every droplet, its firewall and birth key (asks first); the tailnet policy stays managed. Then `just forget NAME` for each
down:
    cd "{{tf}}" && tofu destroy -target='digitalocean_droplet.this' -target='tailscale_tailnet_key.birth'

# Replace NAME from scratch: a fresh birth key and a new droplet with the current cloud-init (asks first)
rebirth NAME: (forget NAME)
    cd "{{tf}}" && tofu apply -replace='tailscale_tailnet_key.birth["{{NAME}}"]' -replace='digitalocean_droplet.this["{{NAME}}"]'

# ---- Tailnet: policy and birth keys -----------------------------------------

# Once: fetch the live tailnet policy into policy.hujson and import it, so the first plan is empty
acl-pull:
    cd "{{tf}}" && tofu init -input=false >/dev/null
    curl -fsS -H "Authorization: Bearer {{ts_token}}" -H "Accept: application/hujson" \
      "{{ts_api}}/tailnet/-/acl" > "{{tf}}/policy.hujson"
    cd "{{tf}}" && tofu import tailscale_acl.policy acl
    @echo "policy.hujson is now the live policy. Add tag:server under tagOwners if missing, then: just plan"

# Mint a single-use birth key (1 h) carrying TAG for a machine terraform does not create, e.g. a Pi's SD card
key NAME TAG="tag:server":
    @curl -fsS -H "Authorization: Bearer {{ts_token}}" -H "Content-Type: application/json" \
      -d '{"description":"fleet birth key for {{NAME}}","expirySeconds":3600,"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":false,"preauthorized":true,"tags":["{{TAG}}"]}}}}' \
      "{{ts_api}}/tailnet/-/keys" | jq -r .key

# Put NAME on the tailnet as a machine (TAG, default tag:server): a Pi, or spectre after a reinstall. Prints the one command to run on it
join NAME TAG="tag:server":
    @key="$(just key {{NAME}} {{TAG}})"; \
    printf '\nOn %s, within the hour (the key is single-use):\n\n' "{{NAME}}"; \
    printf '  curl -fsSL https://tailscale.com/install.sh | sh        # only if tailscale is missing\n'; \
    printf '  sudo tailscale up --reset --force-reauth --hostname=%s --auth-key=%s\n\n' "{{NAME}}" "$key"; \
    printf 'It joins as %s, never as one of your devices. Then here:\n\n' "{{TAG}}"; \
    printf '  just apply -l %s && just env %s && just doctor\n\n' "{{NAME}}" "{{NAME}}"

# Remove NAME's node from the tailnet (so the next NAME is not NAME-1) and its ssh host key here. Needs the Devices scope
forget NAME:
    @ssh-keygen -R "{{NAME}}" >/dev/null 2>&1 || true
    @token="{{ts_token}}"; \
    id="$(curl -fsS -H "Authorization: Bearer $token" "{{ts_api}}/tailnet/-/devices" \
      | jq -r --arg h "{{NAME}}" '.devices[] | select(.hostname==$h) | .nodeId' | head -1)"; \
    if [ -z "$id" ]; then echo "{{NAME}}: no such node on the tailnet, nothing to forget"; \
    elif curl -fsS -X DELETE -H "Authorization: Bearer $token" "{{ts_api}}/device/$id" >/dev/null 2>&1; then echo "{{NAME}}: removed from the tailnet"; \
    else echo "{{NAME}}: could not remove node $id. The OAuth client lacks the Devices (Core) write scope;"; \
         echo "  delete it in the admin console (Machines -> {{NAME}} -> Remove) or issue a client with that scope."; exit 1; fi

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

# check and apply are at the top (Everyday): terraform, then these hosts.

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
