# Medium setup: 1 system disk + 1 parity disk + 4 data disks
# Dedicated parity disk for better performance
# Suitable for: Home media server, growing collection
#
# Disk layout:
#   /dev/sda - System (boot + root only)
#   /dev/sdb - Dedicated parity disk
#   /dev/sdc - Data disk 1
#   /dev/sdd - Data disk 2
#   /dev/sde - Data disk 3
#   /dev/sdf - Data disk 4
#
# Capacity: 4 data disks (parity protects against 1 disk failure)
# Note: Parity disk must be >= largest data disk

{ config, lib, ... }:

{
  disko.devices = {
    disk = {
      system = {
        type = "disk";
        device = "/dev/sda";
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
        device = "/dev/sdb";
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
        device = "/dev/sdc";
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
        device = "/dev/sdd";
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
        device = "/dev/sde";
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

      data4 = {
        type = "disk";
        device = "/dev/sdf";
        content = {
          type = "gpt";
          partitions = {
            disk4 = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/mnt/disk4";
                mountOptions = [
                  "defaults"
                  "noatime"
                  "nodiratime"
                  "user_xattr"
                ];
                extraArgs = [
                  "-L"
                  "disk4"
                ];
              };
            };
          };
        };
      };
    };
  };
}
