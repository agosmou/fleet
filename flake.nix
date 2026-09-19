{
  description = "Root layer of ag's machines: terraform, cloud-init, ansible";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      # `nix develop`, or automatically via direnv (.envrc). Every tool the
      # justfile calls, so nothing is installed on the workstation itself.
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              opentofu # terraform, the open-source fork; `tofu` reads the same .tf files
              ansible # ansible-core plus the community collections (community.general.ufw)
              doctl # DigitalOcean CLI, for looking things up (sizes, images, what exists)
              cloud-init # `cloud-init schema` to validate user-data on the workstation
              jq # the justfile's Tailscale API calls (acl-pull, key, online)
              just
            ];
          };
        }
      );
    };
}
