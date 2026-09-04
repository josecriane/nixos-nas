{
  config,
  lib,
  nasConfig,
  ...
}:
let
  inherit (lib) mkOption types;

  defaults = import ./nas-defaults.nix;

  freeform =
    options:
    types.submodule {
      inherit options;
      freeformType = types.attrs;
    };
in
{
  options.machine = mkOption {
    description = "Per-machine NAS configuration, as passed to `mkNasMachine`.";
    type = freeform {
      nasName = mkOption { type = types.str; };
      hostname = mkOption { type = types.str; };
      nasIP = mkOption { type = types.str; };

      gateway = mkOption { type = types.str; };
      nameservers = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      domain = mkOption { type = types.str; };
      subdomain = mkOption { type = types.str; };

      adminUser = mkOption { type = types.str; };
      adminSSHKeys = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      puid = mkOption { type = types.int; };
      pgid = mkOption { type = types.int; };
      timezone = mkOption { type = types.str; };

      dataDisks = mkOption {
        type = types.listOf types.str;
        default = defaults.dataDisks;
      };

      services = mkOption {
        default = { };
        type = freeform {
          monitoring = mkOption {
            type = types.bool;
            default = defaults.services.monitoring;
          };
          cockpit = mkOption {
            type = types.bool;
            default = defaults.services.cockpit;
          };
          filebrowser = mkOption {
            type = types.bool;
            default = defaults.services.filebrowser;
          };
          authentikIntegration = mkOption {
            type = types.bool;
            default = defaults.services.authentikIntegration;
          };
        };
      };
    };
  };

  config = {
    machine = nasConfig;

    assertions = [
      {
        assertion = builtins.deepSeq config.machine true;
        message = "unreachable: machine config failed to evaluate";
      }
    ];
  };
}
