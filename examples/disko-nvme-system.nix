# NVMe system disk + HDD data disks
# Fast system disk, spinning disks for bulk storage
# Suitable for: Performance-oriented NAS
#
# Disk layout:
#   /dev/nvme0n1 - System NVMe (boot + root)
#   /dev/sda     - Parity disk (HDD)
#   /dev/sdb     - Data disk 1 (HDD)
#   /dev/sdc     - Data disk 2 (HDD)
#   /dev/sdd     - Data disk 3 (HDD)
#
# Capacity: 3 data disks (parity protects against 1 disk failure)

{ config, lib, ... }:

{
  disko.devices = {
    disk = {
      system = {
        type = "disk";
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "defaults"
                  "umask=0077"
                ];
              };
            };
            swap = {
              size = "8G";
              content = {
                type = "swap";
                randomEncryption = false;
                resumeDevice = true;
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
                mountOptions = [
                  "defaults"
                  "noatime"
                ];
              };
            };
          };
        };
      };

      parity = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            parity = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/mnt/parity";
                mountOptions = [
                  "defaults"
                  "noatime"
                  "nodiratime"
                ];
                extraArgs = [
                  "-L"
                  "parity"
                ];
              };
            };
          };
        };
      };

      data1 = {
        type = "disk";
        device = "/dev/sdb";
        content = {
          type = "gpt";
          partitions = {
            disk1 = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/mnt/disk1";
                mountOptions = [
                  "defaults"
                  "noatime"
                  "nodiratime"
                  "user_xattr"
                ];
                extraArgs = [
                  "-L"
                  "disk1"
                ];
              };
            };
          };
        };
      };

      data2 = {
        type = "disk";
        device = "/dev/sdc";
        content = {
          type = "gpt";
          partitions = {
            disk2 = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/mnt/disk2";
                mountOptions = [
                  "defaults"
                  "noatime"
                  "nodiratime"
                  "user_xattr"
                ];
                extraArgs = [
                  "-L"
                  "disk2"
                ];
              };
            };
          };
        };
      };

      data3 = {
        type = "disk";
        device = "/dev/sdd";
        content = {
          type = "gpt";
          partitions = {
            disk3 = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/mnt/disk3";
                mountOptions = [
                  "defaults"
                  "noatime"
                  "nodiratime"
                  "user_xattr"
                ];
                extraArgs = [
                  "-L"
                  "disk3"
                ];
              };
            };
          };
        };
      };
    };
  };
}
