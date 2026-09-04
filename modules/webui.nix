{
  config,
  lib,
  pkgs,
  nasConfig,
  ...
}:

let
  cfg = config.nas.webui;
  adminUser = nasConfig.adminUser;
in
{
  options.nas.webui = {
    enable = lib.mkEnableOption "Web UI services (Cockpit and File Browser)";

    cockpit = {
      enable = lib.mkEnableOption "Cockpit web interface" // {
        default = true;
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 9090;
        description = "Port for Cockpit web interface";
      };
      allowUnencrypted = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Allow unencrypted connections (useful when behind reverse proxy)";
      };
      origins = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "https://nas.local"
          "http://localhost:9090"
        ];
        description = "Allowed origins for Cockpit (for reverse proxy/Authentik)";
      };
    };

    filebrowser = {
      enable = lib.mkEnableOption "File Browser web interface" // {
        default = true;
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "Port for File Browser";
      };
      rootPath = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/storage";
        description = "Root path for File Browser";
      };
      databasePath = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/filebrowser/filebrowser.db";
        description = "Path to File Browser database";
      };
      proxyAuth = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable proxy authentication (for Authentik)";
      };
      proxyHeader = lib.mkOption {
        type = lib.types.str;
        default = "X-authentik-username";
        description = "Header name for proxy authentication";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.cockpit = lib.mkIf cfg.cockpit.enable {
      enable = true;
      port = cfg.cockpit.port;

      settings = {
        WebService = {
          AllowUnencrypted = cfg.cockpit.allowUnencrypted;
          Origins = lib.mkForce (lib.concatStringsSep " " cfg.cockpit.origins);
          ListenAddress = "0.0.0.0";
        };
      };
    };

    systemd.services.filebrowser = lib.mkIf cfg.filebrowser.enable {
      description = "File Browser - Web File Manager";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      preStart = ''
        mkdir -p $(dirname ${cfg.filebrowser.databasePath})
        chown ${adminUser}:${adminUser} $(dirname ${cfg.filebrowser.databasePath})

        cat > /var/lib/filebrowser/config.json <<EOF
        {
          "port": ${toString cfg.filebrowser.port},
          "address": "0.0.0.0",
          "database": "${cfg.filebrowser.databasePath}",
          "root": "${cfg.filebrowser.rootPath}",
          "log": "stdout",
          "baseURL": "",
          ${lib.optionalString cfg.filebrowser.proxyAuth ''
            "auth": {
              "method": "proxy",
              "header": "${cfg.filebrowser.proxyHeader}"
            },
          ''}
          "commands": [],
          "shell": []
        }
        EOF

        chown ${adminUser}:${adminUser} /var/lib/filebrowser/config.json
      '';

      serviceConfig = {
        Type = "simple";
        User = adminUser;
        Group = adminUser;
        ExecStart = "${pkgs.filebrowser}/bin/filebrowser -c /var/lib/filebrowser/config.json";
        Restart = "on-failure";
        RestartSec = "10s";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = false;
        ReadWritePaths = [
          cfg.filebrowser.rootPath
          "/var/lib/filebrowser"
        ];

        MemoryMax = "256M";
        MemoryHigh = "200M";
        CPUQuota = "50%";
      };
    };

    systemd.tmpfiles.rules = lib.mkIf cfg.filebrowser.enable [
      "d /var/lib/filebrowser 0755 ${adminUser} ${adminUser} -"
    ];

    environment.systemPackages =
      with pkgs;
      (lib.optionals cfg.cockpit.enable [
        cockpit
        cockpit-machines
        cockpit-podman
      ])
      ++ (lib.optional cfg.filebrowser.enable filebrowser);

    networking.firewall.allowedTCPPorts =
      (lib.optional cfg.cockpit.enable cfg.cockpit.port)
      ++ (lib.optional cfg.filebrowser.enable cfg.filebrowser.port);
  };
}
