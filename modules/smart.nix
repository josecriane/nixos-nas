{
  config,
  lib,
  pkgs,
  nasConfig,
  ...
}:

let
  cfg = config.smart;
  dataDiskPaths = map (d: "/mnt/${d}") (nasConfig.dataDisks or [ ]);
  defaultMonitored = dataDiskPaths ++ [ "/mnt/storage" ];
  monEnabled = nasConfig.services.monitoring or false;
in
{
  options.smart = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable SMART monitoring (smartd + periodic health/temperature/space checks).";
    };

    tempThreshold = lib.mkOption {
      type = lib.types.int;
      default = 55;
      description = "Temperature in Celsius above which a warning is logged.";
    };

    usageThreshold = lib.mkOption {
      type = lib.types.int;
      default = 85;
      description = "Filesystem usage percent above which a warning is logged.";
    };

    monitoredPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = defaultMonitored;
      description = "Filesystem paths checked by the disk-space timer. Defaults to every dataDisk plus the MergerFS pool.";
    };

    exporter = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = monEnabled;
        defaultText = lib.literalExpression "nasConfig.services.monitoring or false";
        description = ''
          Expose SMART attributes to Prometheus via smartctl_exporter.
          Defaults to true when NAS monitoring is enabled so external scrapers
          (e.g. a K8s cluster's ServiceMonitor) have something to hit.
        '';
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 9633;
        description = "Port for smartctl_exporter.";
      };
      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = monEnabled;
        defaultText = lib.literalExpression "nasConfig.services.monitoring or false";
        description = "Open the exporter port in the firewall (LAN only).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      smartmontools
      nvme-cli
    ];

    services.smartd = {
      enable = true;
      autodetect = true;
      notifications = {
        mail.enable = false;
        wall.enable = true;
      };
      defaults.monitored = "-a -o on -s (S/../.././02|L/../../6/03)";
    };

    services.prometheus.exporters.smartctl = lib.mkIf cfg.exporter.enable {
      enable = true;
      port = cfg.exporter.port;
      openFirewall = cfg.exporter.openFirewall;
    };

    # NVMe controller char devices ship as 0600 root:root, which the
    # smartctl-exporter user (supplementary group "disk") cannot open. Relax to
    # disk group so the exporter can query SMART on NVMe drives.
    services.udev.extraRules = lib.mkIf cfg.exporter.enable ''
      KERNEL=="nvme[0-9]*", SUBSYSTEM=="nvme", MODE="0660", GROUP="disk"
    '';

    systemd.services.disk-health-check = {
      description = "SMART health check across all block devices";
      serviceConfig.Type = "oneshot";
      script = ''
        set -u
        export PATH=${
          lib.makeBinPath [
            pkgs.smartmontools
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.util-linux
          ]
        }:$PATH

        exit_code=0
        for dev in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}'); do
          if ! out=$(smartctl -H "$dev" 2>&1); then
            echo "ERROR: smartctl failed on $dev"
            exit_code=1
            continue
          fi
          status=$(echo "$out" | grep -iE "overall-health|SMART Health Status|result" | head -1)
          echo "$dev: $status"
          if echo "$status" | grep -qiE "FAIL|BAD"; then
            echo "CRITICAL: $dev reports failing SMART status"
            exit_code=1
          fi
        done
        exit "$exit_code"
      '';
    };

    systemd.timers.disk-health-check = {
      description = "Daily SMART health check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "15min";
      };
    };

    systemd.services.disk-temperature-check = {
      description = "Disk temperature check";
      serviceConfig.Type = "oneshot";
      script = ''
        set -u
        export PATH=${
          lib.makeBinPath [
            pkgs.smartmontools
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gawk
            pkgs.util-linux
          ]
        }:$PATH

        threshold=${toString cfg.tempThreshold}
        exit_code=0

        for dev in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}'); do
          temp=$(smartctl -A "$dev" 2>/dev/null | \
            awk '/Temperature_Celsius|Current Drive Temperature|Temperature:/ { for (i=1;i<=NF;i++) if ($i+0>0 && $i+0<150) { print $i+0; exit } }')
          [ -z "$temp" ] && continue
          if [ "$temp" -ge "$threshold" ]; then
            echo "WARNING: $dev temperature is $temp C (threshold: $threshold C)"
            exit_code=1
          else
            echo "OK: $dev temperature $temp C"
          fi
        done
        exit "$exit_code"
      '';
    };

    systemd.timers.disk-temperature-check = {
      description = "Hourly disk temperature check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
        RandomizedDelaySec = "5min";
      };
    };

    systemd.services.disk-space-check = {
      description = "Disk space usage check";
      serviceConfig.Type = "oneshot";
      script = ''
        set -u
        export PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gawk
            pkgs.util-linux
          ]
        }:$PATH

        threshold=${toString cfg.usageThreshold}
        exit_code=0

        for path in ${lib.concatStringsSep " " (map (p: "'${p}'") cfg.monitoredPaths)}; do
          [ -d "$path" ] || continue
          mountpoint -q "$path" 2>/dev/null || true
          usage=$(df --output=pcent "$path" | tail -1 | tr -d ' %')
          [ -z "$usage" ] && continue
          if [ "$usage" -ge "$threshold" ]; then
            echo "WARNING: $path is at $usage% (threshold: $threshold%)"
            exit_code=1
          else
            echo "OK: $path at $usage%"
          fi
        done
        exit "$exit_code"
      '';
    };

    systemd.timers.disk-space-check = {
      description = "Daily disk space check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    };
  };
}
