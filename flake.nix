{
  description = "NixOS NAS Configuration - MergerFS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, agenix, ... }@inputs:
    let
      system = "x86_64-linux";

      # Add new machines here
      machineNames = [ "nas2" "nas1" ];

      # secrets/ and secrets.nix are gitignored, so we read them from
      # the real filesystem using PWD (requires --impure)
      projectDir = builtins.getEnv "PWD";
      secretsPath =
        if projectDir != "" then builtins.path {
          path = "${projectDir}/secrets";
          name = "nas-secrets";
          filter = path: type:
            type == "directory" || (type == "regular" && builtins.match ".*\\.age$" path != null);
        }
        else null;

      mkMachineConfig = name:
        let
          machineDir = ./machines/${name};
          nasConfig = import (machineDir + "/config.nix");
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs nasConfig secretsPath; machineName = name; };
          modules = [
            disko.nixosModules.disko
            (machineDir + "/disko.nix")
            (machineDir + "/hardware.nix")
            agenix.nixosModules.default
            ./configuration.nix
            ./modules/users.nix
            ./modules/storage-mergerfs.nix
            ./modules/networking.nix
            ./modules/services.nix
            ./modules/monitoring.nix
            ./modules/webui.nix
            ./modules/reverse-proxy.nix
            ./modules/samba-setup.nix
            ./modules/samba-ldap.nix
          ];
        };

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      nixosConfigurations = builtins.listToAttrs (
        map (name: { inherit name; value = mkMachineConfig name; }) machineNames
      );

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          nixos-anywhere
          age
          ssh-to-age
          sshpass
        ];
        shellHook = ''
          echo ""
          echo "NixOS NAS - Dev Shell"
          echo ""
          echo "Tools: nixos-anywhere, age, ssh-to-age, sshpass"
          echo ""
          echo "Commands:"
          echo "  ./scripts/setup.sh <machine>    - Initial configuration"
          echo "  ./scripts/install.sh <machine>   - Install on NAS"
          echo "  ./scripts/update.sh <machine>    - Update configuration"
          echo ""
        '';
      };
    };
}
