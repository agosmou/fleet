# To Do

Short list of what is next. Done items are deleted, not ticked.

## Next

- **Build on the workstation, push to the server** (`nix copy`). Today
  `just env HOST` runs environment's bootstrap *on* the box, which
  downloads 8.5 GiB and compiles ~70 derivations there: over an hour and
  an OOM kill on a 1 GB droplet (2026-09-19). The fix is in
  `environment`, not here: a recipe that builds the target's activation
  package on t14s, `nix copy --to ssh-ng://HOST` it, and runs `activate`
  over ssh. Needs on the server: nix installed (bootstrap's step 2 only),
  and `trusted-users = ag` in /etc/nix/nix.conf or signed paths, so the
  daemon accepts pushed store paths; that nix.conf line is root layer,
  so it lands in ansible `roles/base` here. Then `just env` calls the
  new recipe, droplets go back to `s-1vcpu-1gb`, and the sizing note in
  `terraform.tfvars` shrinks to one line.
- **Spectre onto the fleet baseline**: `just apply -l spectre` (lid never
  suspends, `00-hardening` replaces the hand-written drop-in, ufw gains
  the tailscale0 rule) and `just sync` on the box for environment PR #1.
- **Pis**: `just key pi4` → `user-data` on the SD card; add to
  `inventory/10-home.yml` group `pis`; the hostname in cloud-init must be
  the inventory name.
- **Ansible on sudo-rs**: drop `become_exe = sudo.ws` from
  `ansible/ansible.cfg` once ansible-core recognises sudo-rs's
  `[sudo: <prompt>] Password:` wrapping.
- **Spectre rebirth, if ever reinstalled**: autoinstall wrapper around
  `cloud-init/base.yaml.tftpl` with `storage: {layout: {name: lvm,
  sizing-policy: all}}` (the whole SSD, as done by hand on 2026-09-17).

## Explore

- `tailscale_acl`: tighten from allow-all to `autogroup:member →
  tag:server:22` once every server carries the tag.
- `just vm`: boot the rendered cloud-init in a local libvirt VM
  (cloud-init's QEMU tutorial) so `runcmd` mistakes surface before a
  droplet does.
- CI: `just lint` on push. Nothing that needs secrets.
