{ config, lib, ... }:

{
  disko.devices = {
    disk = {
      system = {
        type = "disk";
        device = "/dev/sdc";
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
              size = "4G";
              content = {
                type = "swap";
                randomEncryption = false;
                resumeDevice = true;
              };
            };

            root = {
              size = "100G";
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
                extraArgs = [ "-L" "parity" ];
              };
            };
          };
        };
      };

      data1 = {
        type = "disk";
        device = "/dev/sda";
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
                extraArgs = [ "-L" "disk1" ];
              };
            };
          };
        };
      };

      data2 = {
        type = "disk";
        device = "/dev/sdb";
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
                extraArgs = [ "-L" "disk2" ];
              };
            };
          };
        };
      };
    };
  };
}
