{
  description = "NixOS NAS - Declarative MergerFS NAS on NixOS (library flake)";

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

  outputs =
    {
      self,
      nixpkgs,
      disko,
      agenix,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      mkNasMachine =
        {
          name,
          nasConfig,
          hostsPath,
          secretsPath,
          extraModules ? [ ],
          extraSpecialArgs ? { },
        }:
        let
          cfg = nixpkgs.lib.recursiveUpdate (import ./modules/nas-defaults.nix) (
            nasConfig // { inherit name; }
          );
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit inputs secretsPath;
            nasConfig = cfg;
            machineName = name;
          }
          // extraSpecialArgs;
          modules = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            "${hostsPath}/${name}"
            "${self}/modules/options.nix"
            "${self}/configuration.nix"
            "${self}/modules/users.nix"
            "${self}/modules/storage-mergerfs.nix"
            "${self}/modules/networking.nix"
            "${self}/modules/services.nix"
            "${self}/modules/monitoring.nix"
            "${self}/modules/smart.nix"
            "${self}/modules/webui.nix"
            "${self}/modules/reverse-proxy.nix"
            "${self}/modules/samba-setup.nix"
          ]
          ++ extraModules;
        };

      mkNasMachines =
        {
          nasConfigs,
          hostsPath,
          secretsPath,
          extraModules ? [ ],
          extraSpecialArgs ? { },
        }:
        nixpkgs.lib.mapAttrs (
          name: nasConfig:
          mkNasMachine {
            inherit
              name
              nasConfig
              hostsPath
              secretsPath
              extraModules
              extraSpecialArgs
              ;
          }
        ) nasConfigs;

      # Standalone mode: enumerate machines/<name>/ dirs and build each using
      # its own config.nix.
      machinesDir = "${self}/machines";
      hasMachinesDir = builtins.pathExists machinesDir;
      standaloneNames =
        if hasMachinesDir then
          builtins.attrNames (nixpkgs.lib.filterAttrs (_: t: t == "directory") (builtins.readDir machinesDir))
        else
          [ ];

      standaloneConfigs = builtins.listToAttrs (
        map (name: {
          inherit name;
          value = mkNasMachine {
            inherit name;
            nasConfig = import "${machinesDir}/${name}/config.nix";
            hostsPath = machinesDir;
            secretsPath = "${self}/secrets";
          };
        }) standaloneNames
      );
    in
    {
      lib = {
        inherit mkNasMachine mkNasMachines;
      };

      nixosConfigurations = standaloneConfigs;

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

      checks.${system} = {
        example = self.nixosConfigurations.example.config.system.build.toplevel;

        example-full =
          (mkNasMachine {
            name = "example";
            nasConfig = import ./examples/config-full.nix // {
              inherit (import ./machines/example/config.nix) dataDisks;
            };
            hostsPath = ./machines;
            secretsPath = "${self}/secrets";
          }).config.system.build.toplevel;
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
