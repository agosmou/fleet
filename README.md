# fleet

What makes a machine a server: what exists (terraform), how it is born
(cloud-init), how it stays configured (ansible), and the tailnet policy
that ties them together. What makes a machine *mine* (shell, editor,
dotfiles, `ssh <name>`) is [`environment`](https://github.com/agosmou/environment),
which this repository hands off to as its last step. environment installs
root-level things only on machines fleet never touches (the Fedora laptop,
the Mac); on servers it asserts and installs nothing.

Machines: `spectre` (HP laptop, Ubuntu Server, at home), droplets on
DigitalOcean named in `terraform/digitalocean/terraform.tfvars`, and soon two
Raspberry Pis. All are reached by tailnet name; no IP appears in a command.

## Layout

```
justfile                  the UX; `just` lists it
flake.nix  .envrc         tools (tofu, ansible, doctl, cloud-init) via direnv
secrets.env.example       tokens; copy to secrets.env, which is gitignored

terraform/digitalocean/   EXISTENCE  droplets + provider firewall; the tailnet
  policy.hujson                      policy (tailscale.tf) and a single-use
                                     birth key per droplet; writes
                                     ansible/inventory/20-vps.yml
cloud-init/               BIRTH      base.yaml.tftpl: user, keys, ufw,
                                     tailscale up. Only what ansible needs
ansible/                  STEADY     roles: base ssh ufw laptop, after the
                                     tailscale check (pre_tasks, fails fast)
  inventory/10-home.yml              hand-written: spectre, the Pis
  inventory/00-local.yml             gitignored: LAN facts, from home-network
  inventory/20-vps.yml               terraform-written: the droplets
  playbooks/site.yml                 groups -> roles
```

The rule that keeps the layers apart: cloud-init runs once and contains
only what ansible needs to reach the box. Anything you would want to change
later goes in a role, where `just check` shows the diff before `just apply`.

Tailscale is the one thing every layer touches, so its ownership is
explicit: **the tool that had to install it owns it.** On servers that is
cloud-init (nothing can reach the box before it); ansible only checks
(`BackendState == Running`, right node name, key expiry); environment only
asserts the daemon is up. On the Fedora laptop and the Mac, environment
installs it because nothing else is there to.

## How a server is born

| Machine | Exists because | cloud-init arrives via | Joins the tailnet by |
|---|---|---|---|
| droplets | `terraform.tfvars` | DO user-data | single-use `tag:server` key minted by terraform |
| Pi 4, Pi Zero 2 W | bought | `user-data` on the SD card's `system-boot` | single-use key from `just key <name>` |
| spectre | owned | none yet (autoinstall USB, if ever reinstalled) | by hand, `sudo tailscale up`; untagged, so its key expires |

## Setup, once

```sh
cp secrets.env.example secrets.env   # fill in: DO token, Tailscale OAuth client, password hash
cp ansible/00-local.yml.example ansible/inventory/00-local.yml         # LAN subnet, from home-network
direnv allow                         # loads the tools and the secrets on cd
just lint                            # everything parses
just acl-pull                        # live tailnet policy -> policy.hujson, imported; first plan is empty
just plan                            # add tag:server to policy.hujson if the pull lacked it
```

## Usage

```sh
just                 # list recipes

just new do1         # a droplet from nothing to ready: up, wait, apply, env
                     #   ~4 min; asks: tofu apply (yes), sudo password (ansible),
                     #   sudo password again (nix installer on the new box)
ssh do1              # ~/environment's ssh config knows the name once you add it

just up              # terraform: make DO match terraform.tfvars
just down            # terraform: destroy it all
just wait do1        # until first boot is done and it answers on the tailnet
just status do1      # cloud-init and tailscale state

just online          # which inventory hosts are on the tailnet, no ssh
just ping            # ansible reaches every host?
just check           # online, then dry run with diff, all hosts
just key pi4         # single-use birth key for a machine terraform does not create
just apply -l spectre
just env do1         # user layer: environment's bootstrap, --target server
```

Adding a droplet: add a line to `terraform.tfvars`, `just new <name>`.
Removing one: delete the line, `just up`, and delete its node in the
Tailscale admin console (terraform does not know about the tailnet).

## Roles

| Role        | Effect |
|-------------|--------|
| `base`      | Baseline packages, unattended security upgrades, auto-reboot at 04:00 only when a kernel update requires it |
| `ssh`       | Keys only, no root, only listed users, no X11/agent forwarding, idle sessions dropped; removes the hand-written drop-in it replaced |
| `ufw`       | Default deny inbound. Allowed: anything over `tailscale0`, Tailscale's WireGuard port, and SSH from `lan_cidr` where a host defines one |
| `tailscale` | Check only, first: connected (`Running`), online, node name is the inventory name, warns 30 days before an untagged key expires. Installs nothing: see "How a server is born" |
| `laptop`    | Lid closed and idle never suspend; sleep targets masked. Group `laptops` only |

## Lockout safety

- Provider firewall admits nothing inbound but Tailscale's UDP port, so a
  droplet whose `ufw` failed still exposes nothing; DigitalOcean's web
  console (password from `secrets.env`) is the fallback.
- The SSH drop-in is validated with `sshd -t` before it is written, and
  `ssh` is only reloaded (existing sessions survive).
- Firewall rules are added before `ufw` is enabled.
- Always test a **new** SSH connection before closing the one you're in.
- `spectre` keeps its LAN SSH rule (`lan_cidr`, from `00-local.yml`) as the
  fallback for when Tailscale is down; keyboard and monitor on the box is
  the last resort.

## Secrets

`secrets.env` (gitignored) holds the DO token, the Tailscale OAuth client
and the password hash; keep the same three in a Bitwarden secure note.
Nothing else here is secret. Terraform state (gitignored) contains the
birth keys and rendered user-data; treat `.tfstate` like a key. Each
droplet's user-data also holds its birth key, readable from the metadata
service by any local user, but the key is single-use and spent at first
boot, so that copy is worthless. The OAuth client is the credential that
matters.

Nothing about the house is here either: subnets, addresses, MACs and
switch ports live in the private home-network repository and reach ansible
only through the gitignored `inventory/00-local.yml`. That is what lets
this repository be public; the configuration never depended on secrecy.
