# To Do

Short list of what is next, in order. Done items are deleted, not ticked.

## Next

1. **Passwordless sudo on servers**, so `just new` asks nothing. Today
   every ansible run asks for ag's password (`-K`) and environment's
   bootstrap asks again on the box. On a server the only way in is the
   ssh key over the tailnet, so the password defends nothing, and its
   hash sits in tfstate and in the droplet's user-data where a short
   password cracks in seconds. Change: cloud-init `users.ag.sudo:
   "ALL=(ALL) NOPASSWD:ALL"` and no `passwd`; `roles/base` writes
   `/etc/sudoers.d/ag` the same way (validated with `visudo -cf`) so
   spectre converges with one last `-K`; drop `-K` from `check`/`apply`;
   `TF_VAR_ag_passwd_hash` leaves secrets.env; `just new` runs
   `tofu apply -auto-approve` (`up`/`down` keep asking, they can destroy).
   Workstations (t14s, mini) keep password sudo; they are not servers.

2. **Build on the workstation, push to the server** (`nix copy`), so a
   1 GB droplet is enough again and `just env` takes minutes. Today
   `just env HOST` runs environment's bootstrap *on* the box: 8.5 GiB
   downloaded and ~70 derivations compiled there, over an hour and an
   OOM kill on 1 GB (2026-09-19). The recipe lives in `environment`:
   build the target's activation package on t14s, `nix copy --to
   ssh-ng://HOST`, run `activate` over ssh. Needs on the server: nix
   installed (bootstrap step 2 only) and `trusted-users = ag` in
   `/etc/nix/nix.conf` so the daemon accepts pushed paths; that line is
   root layer, so `roles/base` here. Then droplets default back to
   `s-1vcpu-1gb` and the sizing note in terraform.tfvars shrinks.

3. **Pis**: `just key pi4` → `user-data` on the SD card's `system-boot`;
   add to `inventory/10-home.yml` group `pis` and to `00-local.yml`;
   the cloud-init hostname must be the inventory name.

4. **Ansible on sudo-rs**: drop `become_exe = sudo.ws` from
   `ansible/ansible.cfg` once ansible-core recognises sudo-rs's
   `[sudo: <prompt>] Password:` wrapping. Moot after item 1 for
   password prompts, still needed for the prompt detection.

5. **Spectre rebirth, if ever reinstalled**: autoinstall wrapper around
   `cloud-init/base.yaml.tftpl` with `storage: {layout: {name: lvm,
   sizing-policy: all}}` (the whole SSD, as done by hand 2026-09-17).

## Explore

- `tailscale_acl`: tighten from allow-all to `autogroup:member →
  tag:server:22` once every server carries the tag.
- `just vm`: boot the rendered cloud-init in a local libvirt VM
  (cloud-init's QEMU tutorial) so `runcmd` mistakes surface before a
  droplet does.
- CI: `just lint` on push. Nothing that needs secrets.
- `roles/docker`: a weekly `docker system prune -af --filter until=168h`
  timer on the droplets; image bloat is how a 25 GB disk fills. And
  `default-address-pools` if a subnet router ever advertises 172.16/12.
- Remote terraform state (DO Spaces) before a second workstation runs
  `just up`.
