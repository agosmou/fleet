# cloud-init

`base.yaml.tftpl` is the first boot of every machine. It is a terraform
template: `terraform/digitalocean` renders it into a droplet's user-data
with `templatefile()`. The same content will feed the Pi images
(`user-data` on the `system-boot` partition) and the Spectre's autoinstall
USB (`user-data:` section) when those targets arrive; each gets a thin
wrapper here, not a copy.

What it does, and nothing more: hostname, the `ag` user with the keys in
`authorized_keys` and a hashed password, firewall closed except the
tailnet, Tailscale installed and joined. From there Ansible takes over.

`authorized_keys` holds public keys only, one per line, and is committed.
The password hash and the Tailscale auth key come from `secrets.env`.

Check a machine's first boot from the workstation:

    just status <name>      # cloud-init status --long, tailscale status

Debug on the machine itself:

    sudo cloud-init status --long
    sudo cat /var/log/cloud-init-output.log
    sudo cloud-init schema --system     # validate what it actually ran
