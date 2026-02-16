{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    snapraid
  ];

  environment.etc."snapraid.conf" = {
    text = ''
      parity /mnt/parity/snapraid.parity

      content /var/snapraid/snapraid.content
      content /mnt/disk1/snapraid.content
      content /mnt/disk2/snapraid.content
      content /mnt/disk3/snapraid.content

      data disk1 /mnt/disk1
      data disk2 /mnt/disk2
      data disk3 /mnt/disk3

      exclude *.unrecoverable
      exclude /tmp/
      exclude /lost+found/
      exclude *.bak
      exclude *.tmp
      exclude .Thumbs.db
      exclude .DS_Store

      exclude snapraid.content
      exclude snapraid.content.tmp

      exclude /downloads/incomplete/
      exclude /.Trash-*/

      nohidden

      autosave 500

      blocksize 256
    '';
    mode = "0644";
  };

  systemd.tmpfiles.rules = [
    "d /var/snapraid 0755 root root -"
  ];

  environment.etc."nixos-nas/snapraid-sync.sh" = {
    text = ''
      #!/usr/bin/env bash

      set -euo pipefail

      LOG_FILE="/var/log/snapraid-sync.log"
      DATE=$(date '+%Y-%m-%d %H:%M:%S')

      echo "[$DATE] Starting SnapRAID sync..." | tee -a "$LOG_FILE"

      if ! mountpoint -q /mnt/disk1; then
        echo "ERROR: /mnt/disk1 is not mounted" | tee -a "$LOG_FILE"
        exit 1
      fi

      if ! mountpoint -q /mnt/disk2; then
        echo "ERROR: /mnt/disk2 is not mounted" | tee -a "$LOG_FILE"
        exit 1
      fi

      if ! mountpoint -q /mnt/disk3; then
        echo "ERROR: /mnt/disk3 is not mounted" | tee -a "$LOG_FILE"
        exit 1
      fi

      if ! mountpoint -q /mnt/parity; then
        echo "ERROR: /mnt/parity is not mounted" | tee -a "$LOG_FILE"
        exit 1
      fi

      echo "Checking disk SMART status..." | tee -a "$LOG_FILE"
      SMART_FAILED=0
      for disk in /dev/sda /dev/sdb /dev/sdc /dev/sdd; do
        if ! ${pkgs.smartmontools}/bin/smartctl -H "$disk" | grep -q "PASSED"; then
          echo "WARNING: SMART failed for $disk" | tee -a "$LOG_FILE"
          SMART_FAILED=1
        fi
      done

      if [ $SMART_FAILED -eq 1 ]; then
        echo "WARNING: Some disks have SMART issues" | tee -a "$LOG_FILE"
        echo "Continuing anyway (you can cancel with Ctrl+C)..." | tee -a "$LOG_FILE"
        sleep 5
      fi

      echo "Running diff..." | tee -a "$LOG_FILE"
      ${pkgs.snapraid}/bin/snapraid diff | tee -a "$LOG_FILE"

      echo "Running sync..." | tee -a "$LOG_FILE"
      ${pkgs.snapraid}/bin/snapraid sync 2>&1 | tee -a "$LOG_FILE"

      RESULT=$?
      if [ $RESULT -eq 0 ]; then
        echo "[$DATE] Sync completed successfully" | tee -a "$LOG_FILE"
      else
        echo "[$DATE] Sync failed with code $RESULT" | tee -a "$LOG_FILE"
        exit $RESULT
      fi

      echo "Final status:" | tee -a "$LOG_FILE"
      ${pkgs.snapraid}/bin/snapraid status | tee -a "$LOG_FILE"
    '';
    mode = "0755";
  };

  environment.etc."nixos-nas/snapraid-scrub.sh" = {
    text = ''
      #!/usr/bin/env bash

      set -euo pipefail

      LOG_FILE="/var/log/snapraid-scrub.log"
      DATE=$(date '+%Y-%m-%d %H:%M:%S')

      echo "[$DATE] Starting SnapRAID scrub..." | tee -a "$LOG_FILE"

      ${pkgs.snapraid}/bin/snapraid scrub -p 8 -o 0 2>&1 | tee -a "$LOG_FILE"

      RESULT=$?
      if [ $RESULT -eq 0 ]; then
        echo "[$DATE] Scrub completed successfully" | tee -a "$LOG_FILE"
      else
        echo "[$DATE] Scrub failed with code $RESULT" | tee -a "$LOG_FILE"
        exit $RESULT
      fi
    '';
    mode = "0755";
  };

  systemd.services.snapraid-sync = {
    description = "SnapRAID sync";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/etc/nixos-nas/snapraid-sync.sh";
      User = "root";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  systemd.timers.snapraid-sync = {
    description = "SnapRAID sync timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:00:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };

  systemd.services.snapraid-scrub = {
    description = "SnapRAID scrub";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/etc/nixos-nas/snapraid-scrub.sh";
      User = "root";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };

  systemd.timers.snapraid-scrub = {
    description = "SnapRAID scrub timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 03:00:00";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  environment.etc."nixos-nas/snapraid-commands.txt" = {
    text = ''
      sudo snapraid status

      sudo snapraid diff

      sudo snapraid sync

      sudo snapraid scrub -p 10
      sudo snapraid scrub -p 100

      sudo snapraid fix -f FILE

      sudo snapraid fix -d disk2

      sudo snapraid list

      sudo snapraid smart

      sudo journalctl -u snapraid-sync
      sudo journalctl -u snapraid-scrub
      tail -f /var/log/snapraid-sync.log
      tail -f /var/log/snapraid-scrub.log

      sudo /etc/nixos-nas/snapraid-sync.sh

      sudo /etc/nixos-nas/snapraid-scrub.sh

      systemctl list-timers | grep snapraid

      sudo systemctl stop snapraid-sync.timer
      sudo systemctl disable snapraid-sync.timer
      sudo systemctl enable snapraid-sync.timer
      sudo systemctl start snapraid-sync.timer
    '';
    mode = "0644";
  };

  services.logrotate.settings.snapraid = {
    files = "/var/log/snapraid-*.log";
    frequency = "weekly";
    rotate = 4;
    compress = true;
    delaycompress = true;
    missingok = true;
    notifempty = true;
  };
}
