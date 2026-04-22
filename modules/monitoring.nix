{
  config,
  lib,
  pkgs,
  nasConfig,
  ...
}:

let
  dataDisks = nasConfig.dataDisks;
  diskMountList = builtins.concatStringsSep " " (map (d: "/mnt/${d}") dataDisks);
  monEnabled = nasConfig.services.monitoring or false;
in
{
  services.prometheus.exporters.node = lib.mkIf monEnabled {
    enable = true;
    port = 9100;
    openFirewall = true;
    enabledCollectors = [
      "systemd"
      "filesystem"
      "diskstats"
      "netstat"
      "netdev"
      "meminfo"
      "cpu"
      "loadavg"
    ];
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
