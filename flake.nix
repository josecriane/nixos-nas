{
  description = "NixOS NAS Configuration - MergerFS + SnapRAID";

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
      configPath = if builtins.pathExists ./config.nix
                   then ./config.nix
                   else ./config.example.nix;
      nasConfig = import configPath;
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      nixosConfigurations.nas = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs nasConfig; };
        modules = [
          disko.nixosModules.disko
          ./modules/disko.nix
          agenix.nixosModules.default
          ./configuration.nix
          ./modules/users.nix
          ./modules/hardware.nix
          ./modules/storage-mergerfs.nix
          ./modules/snapraid.nix
          ./modules/networking.nix
          ./modules/services.nix
          ./modules/monitoring.nix
          ./modules/webui.nix
          ./modules/reverse-proxy.nix
          ./modules/samba-setup.nix
          ./modules/samba-ldap.nix
        ];
      };

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
          echo "  ./scripts/setup.sh   - Initial configuration"
          echo "  ./scripts/install.sh - Install on NAS"
          echo ""
        '';
      };
    };
}
