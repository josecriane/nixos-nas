{ config, lib, pkgs, nasConfig, ... }:

let
  dataDisks = nasConfig.dataDisks;
  user = nasConfig.adminUser;
in
{
  environment.systemPackages = with pkgs; [
    mergerfs
    mergerfs-tools
  ];

  systemd.tmpfiles.rules =
    (map (d: "d /mnt/${d} 0755 ${user} ${user} -") dataDisks)
    ++ [
      "d /mnt/storage 0755 ${user} ${user} -"
      "d /mnt/storage/media 0775 ${user} ${user} -"
      "d /mnt/storage/files 0775 ${user} ${user} -"
      "d /mnt/storage/backups 0775 ${user} ${user} -"
      "d /mnt/storage/downloads 0775 ${user} ${user} -"
    ];

  fileSystems."/mnt/storage" = {
    device = "/mnt/disk*";
    fsType = "fuse.mergerfs";
    depends = map (d: "/mnt/${d}") dataDisks;
    options = [
      "defaults"
      "allow_other"
      "use_ino"
      "cache.files=auto-full"
      "dropcacheonclose=true"
      "category.create=epmfs"
      "category.search=ff"
      "func.getattr=newest"
      "minfreespace=10G"
      "fsname=mergerfs-storage"
    ];
  };

  services.smartd = {
    enable = true;
    autodetect = true;

    notifications = {
      mail.enable = false;
      wall.enable = true;
    };

    defaults.monitored = "-a -o on -s (S/../.././02|L/../../6/03)";
  };

  environment.etc."nixos-nas/disk-status.sh" = {
    text = ''
      #!/usr/bin/env bash

      echo "=== MergerFS Disk Status ==="
      echo

      echo "INDIVIDUAL DISKS:"
      df -h /mnt/disk* 2>/dev/null | grep -v tmpfs
      echo

      echo "MERGERFS POOL:"
      df -h /mnt/storage
      echo

      echo "=== SMART Status ==="
      for disk in /dev/sd[a-z]; do
        if [ -e "$disk" ]; then
          echo
          echo "DISK: $disk"
          sudo smartctl -H "$disk" 2>/dev/null | grep -E "SMART|result"
        fi
      done
    '';
    mode = "0755";
  };

  environment.etc."nixos-nas/balance-disks.sh" = {
    text = ''
      #!/usr/bin/env bash

      echo "=== MergerFS Disk Balance ==="
      echo
      echo "This script will redistribute files to balance disk space usage"
      echo

      df -h /mnt/disk* 2>/dev/null | grep -v tmpfs
      echo

      read -p "Continue with balance? [y/N] " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        ${pkgs.mergerfs-tools}/bin/mergerfs.balance -p mfs /mnt/storage
        echo
        echo "Balance completed. Final status:"
        df -h /mnt/disk* 2>/dev/null | grep -v tmpfs
      else
        echo "Balance cancelled"
      fi
    '';
    mode = "0755";
  };
}
