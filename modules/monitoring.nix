{ config, lib, pkgs, nasConfig, ... }:

let
  dataDisks = nasConfig.dataDisks;
  diskMountChecks = builtins.concatStringsSep "\n" (
    map (d: ''
        if mountpoint -q "/mnt/${d}" 2>/dev/null; then
          echo "OK: /mnt/${d} is mounted"
        else
          echo "WARNING: /mnt/${d} is NOT mounted!"
        fi'') dataDisks
  );
  diskSpaceChecks = builtins.concatStringsSep "\n" (
    map (d: ''
        if mountpoint -q "/mnt/${d}" 2>/dev/null; then
          USAGE=$(${pkgs.coreutils}/bin/df --output=pcent "/mnt/${d}" | tail -1 | tr -d ' %')
          if [ "$USAGE" -gt "$THRESHOLD" ]; then
            echo "WARNING: /mnt/${d} is at $USAGE% capacity (threshold: $THRESHOLD%)"
          else
            echo "OK: /mnt/${d} is at $USAGE% capacity"
          fi
        fi'') dataDisks
  );
  diskMountList = builtins.concatStringsSep " " (
    map (d: "/mnt/${d}") dataDisks
  );
in
{
  services.prometheus.exporters.node = {
    enable = false;
    port = 9100;
    enabledCollectors = [
      "systemd"
      "filesystem"
      "diskstats"
      "netstat"
      "netdev"
    ];
  };

  systemd.services.storage-health-check = {
    description = "Storage Health Check (MergerFS)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeScript "storage-health-check" ''
        #!${pkgs.bash}/bin/bash

        echo "=== Storage Health Check ==="
        echo ""

        echo "--- Disk Mounts ---"
        ${diskMountChecks}
        if mountpoint -q /mnt/storage 2>/dev/null; then
          echo "OK: /mnt/storage is mounted"
        else
          echo "WARNING: /mnt/storage is NOT mounted!"
        fi
        echo ""

        echo "--- Disk Space ---"
        ${pkgs.coreutils}/bin/df -h ${diskMountList} /mnt/storage 2>/dev/null
        echo ""

        echo "--- SMART Health ---"
        for disk in /dev/sd[a-z]; do
          if [ -e "$disk" ]; then
            HEALTH=$(${pkgs.smartmontools}/bin/smartctl -H "$disk" 2>/dev/null | grep -i "overall-health\|result" | head -1)
            echo "$disk: $HEALTH"
          fi
        done
      '';
    };
  };

  systemd.timers.storage-health-check = {
    description = "Storage Health Check Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };

  systemd.services.disk-space-check = {
    description = "Check disk space usage";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeScript "disk-space-check" ''
        #!${pkgs.bash}/bin/bash

        THRESHOLD=85

        echo "=== Disk Space Check ==="

        ${diskSpaceChecks}

        if mountpoint -q /mnt/storage 2>/dev/null; then
          POOL_USAGE=$(${pkgs.coreutils}/bin/df --output=pcent /mnt/storage | tail -1 | tr -d ' %')
          echo ""
          echo "MergerFS Pool: $POOL_USAGE% used"
        fi
      '';
    };
  };

  systemd.timers.disk-space-check = {
    description = "Disk Space Check Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };

  systemd.services.temperature-check = {
    description = "Check system temperatures";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeScript "temperature-check" ''
        #!${pkgs.bash}/bin/bash

        echo "=== Temperature Check ==="

        for disk in /dev/sd[a-z]; do
          if [ -e "$disk" ]; then
            TEMP=$(${pkgs.smartmontools}/bin/smartctl -A "$disk" 2>/dev/null | ${pkgs.gnugrep}/bin/grep -i "Temperature" | head -1 | ${pkgs.gawk}/bin/awk '{print $(NF-0)}')
            if [ ! -z "$TEMP" ]; then
              if [ "$TEMP" -gt "50" ] 2>/dev/null; then
                echo "WARNING: $disk temperature is $TEMP C (threshold: 50 C)"
              else
                echo "OK: $disk temperature is $TEMP C"
              fi
            fi
          fi
        done
      '';
    };
  };

  systemd.timers.temperature-check = {
    description = "Temperature Check Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };

  environment.systemPackages = with pkgs; [
    (writeScriptBin "nas-status" ''
      #!${bash}/bin/bash

      echo "================================"
      echo "NAS STATUS REPORT"
      echo "MergerFS"
      echo "================================"
      echo ""

      echo "--- Disk Mounts ---"
      for mount in ${diskMountList} /mnt/storage; do
        if mountpoint -q "$mount" 2>/dev/null; then
          echo "OK $mount mounted"
        else
          echo "FAIL $mount NOT mounted"
        fi
      done
      echo ""

      echo "--- Disk Usage ---"
      ${coreutils}/bin/df -h ${diskMountList} /mnt/storage 2>/dev/null
      echo ""

      echo "--- MergerFS Pool ---"
      ${coreutils}/bin/df -h /mnt/storage 2>/dev/null
      echo ""

      echo "--- Memory Usage ---"
      ${procps}/bin/free -h
      echo ""

      echo "--- Active Connections ---"
      echo "Samba:"
      ${samba}/bin/smbstatus -b 2>/dev/null || echo "No active Samba connections"
      echo ""
      echo "NFS:"
      ${nfs-utils}/bin/showmount -a 2>/dev/null || echo "No active NFS mounts"
      echo ""

      echo "--- SMART Status ---"
      for disk in /dev/sd[a-z]; do
        if [ -e "$disk" ]; then
          echo -n "$disk: "
          ${smartmontools}/bin/smartctl -H "$disk" 2>/dev/null | ${gnugrep}/bin/grep -i "result\|overall" | head -1 || echo "unknown"
        fi
      done
      echo ""

      echo "================================"
    '')
  ];
}
