# A tour of the repository

Every file, top to bottom: what it is, why it exists, when it runs, and
where to read more. Read it once with the tree open; after that the
comments in each file carry the same information at the point of use.

The one idea to hold onto: a server has three phases, and each phase has a
tool that is good at exactly that phase and bad at the others.

| Phase | Question it answers | Tool | Runs |
|---|---|---|---|
| Existence | does this machine exist, with what size, behind what firewall? | terraform (OpenTofu) | when you change the roster |
| Birth | what must happen on first boot before anyone can log in? | cloud-init | once, at first boot |
| Steady state | how is it configured, forever? | ansible | whenever you say |

Everything in the repository is one of those three, plus the plumbing
that makes them one command.

## The root

### `justfile`

The user interface. `just` is a command runner: a recipe is a name plus
the shell lines it stands for, so `just new do1` is what you type instead
of remembering four tools' flags. Read it top to bottom once; the comment
above each recipe is what `just` prints in its listing.

- `new NAME` chains the whole birth: `up` → `wait` → `apply -l NAME` →
  `env NAME`. Each step is also its own recipe so a failed step can be
  rerun alone.
- `up` / `plan` / `down` are terraform. `up` and `down` ask before acting
  because they can destroy. `down` targets only machines and their keys;
  the tailnet policy stays under management.
- `acl-pull`, `key`, `forget`, `online` talk to the Tailscale API directly
  with `curl` and `jq`, using the same OAuth client terraform uses.
- `wait`, `status` are ssh over the tailnet; `wait` blocks on
  `cloud-init status --wait`, which returns when first boot is finished.
- `ping` / `check` / `apply` are ansible. `check` is a dry run with a diff:
  the answer to "has anything drifted?" and the thing to run before
  `apply`.
- `env HOST` runs environment's own bootstrap on the box. fleet stops
  here; the user layer is environment's.
- `render` / `lint` are the tests that need no machine: terraform
  validates, ansible syntax-checks, the cloud-init template is rendered
  with placeholder secrets and checked against cloud-init's own schema.

Read more: [just manual](https://just.systems/man/en/).

### `flake.nix`, `flake.lock`

The tools, pinned. A Nix flake with one output, a development shell that
contains `tofu`, `ansible`, `doctl`, `cloud-init`, `jq` and `just` at
exact versions from the pinned `nixpkgs`. Nothing is installed on the
workstation itself; `nix develop` (or direnv, below) puts these on `PATH`
while you are in the directory. The lock file is what makes another
workstation get the same versions.

Read more: [Nix flakes](https://nix.dev/concepts/flakes.html);
[`mkShell`](https://nixos.org/manual/nixpkgs/stable/#sec-pkgs-mkShell).

### `.envrc`

Two lines for direnv, which runs them whenever you `cd` into the
directory: `use flake` loads the dev shell above, `dotenv_if_exists
secrets.env` exports the secrets as environment variables. Terraform and
its providers read their credentials from the environment by name
(`DIGITALOCEAN_TOKEN`, `TAILSCALE_OAUTH_CLIENT_ID`, …), so nothing about
credentials appears in any `.tf` file. direnv refuses to run an `.envrc`
until you `direnv allow` it, once, and again after it changes: an `.envrc`
is arbitrary shell that runs on `cd`.

Read more: [direnv](https://direnv.net/); [nix-direnv](https://github.com/nix-community/nix-direnv).

### `secrets.env.example` → `secrets.env`

The three secrets and, in comments, where each comes from and what it is
for. `secrets.env` itself is gitignored. Keep a copy in a Bitwarden
secure note; a new workstation is then `cp` + paste.

- `DIGITALOCEAN_TOKEN`: lets terraform create and destroy droplets on your
  account, and `doctl` list things. Also exported as
  `DIGITALOCEAN_ACCESS_TOKEN`, the name `doctl` reads.
- `TAILSCALE_OAUTH_CLIENT_ID` / `_SECRET`: an OAuth client scoped to
  exactly three things: mint auth keys for `tag:server`, read/write the
  policy file, remove devices. Terraform, `just key` and `just forget` use
  it. This is the credential that matters most here.
- `TF_VAR_ag_passwd_hash`: `ag`'s password on new machines as a hash
  (`openssl passwd -6`). Terraform reads any `TF_VAR_<name>` as the input
  variable `<name>`. Slated for removal (TODO 1).

Read more: [Tailscale OAuth clients](https://tailscale.com/kb/1215/oauth-clients);
[terraform environment variables](https://opentofu.org/docs/cli/config/environment-variables/#tf_var_name).

### `.gitignore`

Secrets, terraform state and plugin cache, the rendered previews, direnv's
cache, and `ansible/inventory/00-local.yml`. Terraform state is listed
because it contains every rendered user-data, birth keys included.

### `TODO.md`

What is next, in order. The top item is always the one that most changes
the daily experience.

## `terraform/digitalocean/` — existence

Terraform describes what should exist; `tofu apply` makes reality match.
OpenTofu is the open-source fork of Terraform; the language and the
providers are the same, the command is `tofu`.

Read more: [OpenTofu docs](https://opentofu.org/docs/);
[the language](https://opentofu.org/docs/language/).

### `versions.tf`

Which providers this module uses and at what versions: `digitalocean`
(droplets, firewalls), `tailscale` (policy, keys), `local` (writing a file
on the workstation). The `provider "digitalocean" {}` block is empty
because the token comes from the environment. State is local for now; the
comment says when to move it.

Read more: [DigitalOcean provider](https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs);
[Tailscale provider](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs);
[state](https://opentofu.org/docs/language/state/).

### `variables.tf`

The inputs. `droplets` is the roster: a map from name to options, with
defaults for size, region and image, so a droplet with no opinions is
`do1 = {}`. `ag_passwd_hash` is marked `sensitive` so it never appears in
plan output (it still lands in state, which is why state is gitignored).

Read more: [input variables](https://opentofu.org/docs/language/values/variables/);
[sensitive variables](https://developer.hashicorp.com/terraform/tutorials/configuration-language/sensitive-variables).

### `terraform.tfvars`

The values for those inputs: the roster itself, one line per droplet.
This is the file you edit to add or remove a machine. Committed, because
"what exists" is not a secret and should be in history. Its comment
carries the sizing lesson from the first droplet.

### `main.tf`

Three resources. `digitalocean_droplet.this` is created once per roster
entry (`for_each`), with `user_data` rendered from the cloud-init template
by `templatefile()`, and `lifecycle { ignore_changes = [user_data] }`
because DigitalOcean cannot change user-data after creation and a
re-rendered template must never try to replace a running machine.
`digitalocean_firewall.tailnet_only` is the provider's firewall in front
of the droplet's own: inbound, only Tailscale's UDP port; a machine whose
`ufw` failed still exposes nothing. `local_file.ansible_inventory` writes
`ansible/inventory/20-vps.yml`, names only, so ansible learns about a
droplet without anyone editing an inventory.

Read more: [`for_each`](https://opentofu.org/docs/language/meta-arguments/for_each/);
[`templatefile`](https://opentofu.org/docs/language/functions/templatefile/);
[`lifecycle`](https://opentofu.org/docs/language/meta-arguments/lifecycle/);
[`digitalocean_droplet`](https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs/resources/droplet);
[`digitalocean_firewall`](https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs/resources/firewall).

### `tailscale.tf`, `policy.hujson`

The tailnet as infrastructure. `tailscale_acl.policy` is the whole tailnet
policy file, from `policy.hujson`; applying replaces what the admin
console holds, so the console becomes read-only in practice and the
policy has a history. `just acl-pull` fetched the live policy into the
file and imported it, which is why the first plan was empty.
`tailscale_tailnet_key.birth` is one single-use, pre-authorized,
`tag:server` key per droplet, valid for an hour, handed to cloud-init.
Single-use means the copy left in the droplet's metadata is spent and
worthless; `tag:server` means the node is a machine identity with no key
expiry. `recreate_if_invalid = "never"` stops terraform from minting a
fresh key on every plan once the first is used.

`policy.hujson` is JSON with comments (HuJSON). `tagOwners` says who may
assign `tag:server`; `grants` is allow-all, Tailscale's default for a
personal tailnet, to be tightened later (TODO, explore).

Read more: [`tailscale_acl`](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs/resources/acl);
[`tailscale_tailnet_key`](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs/resources/tailnet_key);
[tailnet policy file](https://tailscale.com/kb/1395/tailnet-policy-file);
[tags](https://tailscale.com/kb/1068/tags); [auth keys](https://tailscale.com/kb/1085/auth-keys).

### `outputs.tf`

What `tofu apply` prints at the end: each droplet's public IP, for the
record. Nothing reads it; machines are addressed by tailnet name.

### `.terraform.lock.hcl`

Provider versions and checksums, terraform's own lock file. Committed, like
`flake.lock`, so another workstation gets the same providers.

## `cloud-init/` — birth

cloud-init is the program in every cloud image (and Ubuntu's installer
images) that runs on first boot and reads a YAML document, the
`#cloud-config`, describing users, keys, packages and commands. The
provider passes the document in; DigitalOcean calls it user-data.

Read more: [cloud-init docs](https://docs.cloud-init.io/);
[cloud-config reference](https://docs.cloud-init.io/en/latest/reference/modules.html);
[DigitalOcean user data](https://docs.digitalocean.com/products/droplets/how-to/provide-user-data/).

### `base.yaml.tftpl`

The first boot of every machine. `.tftpl` marks it as a terraform
template: `${hostname}`, `${passwd_hash}`, `${tailscale_authkey}` and the
`%{ for }` over keys are filled by `templatefile()` in `main.tf`. Read the
top comment: it contains only what ansible needs to reach the box, and
the file explains why each line is there. The order in `runcmd` matters:
firewall closed first, then Tailscale installed and joined, so the machine
is never reachable except over the tailnet.

The same document will feed the Pis (as `user-data` on the boot
partition) and the Spectre's autoinstall USB (in its `user-data:`
section) through thin wrappers here; the delivery differs, the content
does not.

### `authorized_keys`

Public keys allowed to log in as `ag`, one per line. Public by
definition, so committed. `main.tf` reads it into the template.

### `README.md`

How to check a first boot from the workstation and how to debug one on the
machine.

## `ansible/` — steady state

Ansible connects over ssh, gathers facts about the machine, and runs
tasks that each describe a desired state: this file has these contents,
this package is installed, this service is enabled. A task that finds the
state already true reports `ok` and changes nothing; that is what makes
`just apply` safe to run any time and `just check` a meaningful diff.

Read more: [Ansible user guide](https://docs.ansible.com/ansible/latest/user_guide/index.html);
[playbooks](https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_intro.html);
[roles](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html);
[idempotency](https://docs.ansible.com/ansible/latest/reference_appendices/glossary.html#term-Idempotency).

### `ansible.cfg`

Ansible's settings for this directory. `inventory = inventory/` merges
every file in that directory. `ssh_args` accepts a new host's key on
first contact and refuses a changed one; the tailnet is what makes first
contact trustworthy. `force_handlers` runs notified handlers even when a
later task fails, so an sshd drop-in is never left unloaded. `become_exe =
sudo.ws` is a workaround with an expiry date: Ubuntu's default `sudo` is
now sudo-rs, which wraps ansible's password prompt so ansible cannot see
it; classic sudo is still shipped as `sudo.ws`.

Read more: [configuration settings](https://docs.ansible.com/ansible/latest/reference_appendices/config.html);
[become](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_privilege_escalation.html);
[handlers](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_handlers.html).

### `inventory/`

Who the machines are. Ansible merges every file here, so a host named in
two files is one host with both sets of variables.

- `10-home.yml`, hand-written: `spectre` in group `laptops`, the Pis to
  come in `pis`, an empty `vps` group. Groups say what a machine *is*;
  the playbook maps groups to roles. Hosts have no `ansible_host` because
  the inventory name is the tailnet name and MagicDNS resolves it.
- `20-vps.yml`, written by terraform: every droplet, in group `vps`.
  Committed, so the inventory in git is the whole fleet; deleted by
  `just down`.
- `00-local.yml`, gitignored, from `../00-local.yml.example`: the LAN
  facts, today only `lan_cidr` for spectre, the subnet allowed to reach
  ssh directly as the fallback when Tailscale is down. Its source of truth
  is the private home-network repository.
- `group_vars/all.yml`: defaults for every machine (`ansible_user`, the
  allowed ssh users, the auto-reboot time). It lives under `inventory/`
  because that is where ansible looks for `group_vars`.

Read more: [inventory](https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html);
[variable precedence](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_variables.html#understanding-variable-precedence).

### `playbooks/site.yml`

The whole fleet in one playbook: which groups get which roles, in what
order. Two plays: every machine gets the tailscale check as a `pre_task`
(so a disconnected or misnamed node fails before anything is touched),
then `base`, `ssh`, `ufw`; laptops additionally get `laptop`. Every recipe
runs this one file; `-l NAME` limits it to one host.

### `roles/`

A role is a directory of tasks (and templates, handlers) about one
subject. Each has a comment at the top saying what it does and why.

- **`tailscale/`**: check only. Reads `tailscale status --json` and
  asserts `BackendState == Running`, `Self.Online`, and that the node's
  DNS name starts with the inventory name; warns when an untagged key
  has under 30 days. Installs nothing, for a reason the comment spells
  out: if tailscaled were missing, ansible could not have reached the box
  to install it.
- **`base/`**: baseline packages; `20auto-upgrades` turns on daily
  unattended security updates; `52unattended-upgrades-local` (a template,
  because the reboot time is a variable) allows an automatic reboot at
  04:00 only when a kernel update needs one and removes unused kernels;
  a 2 GB swapfile where a machine has under 512 MB of swap, because cloud
  images ship none and nix was OOM-killed without it.
- **`ssh/`**: one drop-in, `/etc/ssh/sshd_config.d/00-hardening.conf`,
  from a template (the allowed users are a variable). `validate: sshd -t`
  refuses to write a file sshd would reject; the handler reloads rather
  than restarts, so open sessions survive. Also removes the hand-written
  drop-in it superseded on spectre.
- **`ufw/`**: rules first, enable last, so the ssh session that is
  applying them is never cut. LAN rule only where `lan_cidr` is defined;
  `tailscale0` and Tailscale's UDP port everywhere; default deny inbound.
- **`laptop/`**: a logind drop-in so closing the lid or idling never
  suspends, and the sleep targets masked so nothing else can either.
  Battery charge limits are deliberately not here (no sysfs knob on the
  Spectre).

Read more: [unattended-upgrades](https://help.ubuntu.com/community/AutomaticSecurityUpdates);
[`sshd_config`](https://manpages.ubuntu.com/manpages/noble/en/man5/sshd_config.5.html);
[ufw](https://help.ubuntu.com/community/UFW);
[`logind.conf`](https://www.freedesktop.org/software/systemd/man/latest/logind.conf.html);
[`community.general.ufw`](https://docs.ansible.com/ansible/latest/collections/community/general/ufw_module.html).

### `00-local.yml.example`

The template for `inventory/00-local.yml`. It lives one level up because
ansible would try to parse anything inside `inventory/`.

## `docs/`

This file. The README has the diagram and the commands; the files have
the comments; this is the connective tissue.

## Reading order, if you want one

1. `README.md`, the diagram.
2. `justfile`, top to bottom.
3. `cloud-init/base.yaml.tftpl`: the shortest complete picture of a
   server.
4. `ansible/playbooks/site.yml`, then each role's `tasks/main.yml`.
5. `terraform/digitalocean/main.tf` and `tailscale.tf`.
6. `TODO.md`, to know what is still rough and why.
