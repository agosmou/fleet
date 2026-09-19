# The fleet. Names are hostnames: short, lowercase, stable through role
# changes. See variables.tf for the per-droplet options and their defaults.
#
# Sizing, learned 2026-09-19: s-1vcpu-1gb ($6) births fine and runs a
# service fine, but environment's `server` target (8.5 GiB of nix store,
# ~70 derivations built locally) took over an hour on it and OOM-killed
# nix before the base role added swap. A box you install the environment
# on starts at s-2vcpu-4gb ($24) until environment can build on the
# workstation and push (`nix copy`). DO resizes never shrink the disk.
droplets = {
  # do1 = { size = "s-2vcpu-4gb" }   # uncomment, `just new do1`; delete, `just down`
}
