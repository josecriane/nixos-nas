{ config, lib, ... }:

{
  disko.devices = {
    disk = {
      system = {
        type = "disk";
        device = "/dev/disk/by-id/ata-TOSHIBA_MK1237GSX_186VTEQ2T";
        content = {
          type = "table";
          format = "msdos";
          partitions = [
            {
              name = "swap";
              start = "1MiB";
              end = "4GiB";
              content = {
                type = "swap";
                randomEncryption = false;
                resumeDevice = true;
              };
            }
            {
              name = "root";
              start = "4GiB";
              end = "100%";
              bootable = true;
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
                mountOptions = [
                  "defaults"
                  "noatime"
                ];
              };
            }
          ];
        };
      };

      data1 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-ST4000DM000-1F2168_Z300H6HY";
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
        device = "/dev/disk/by-id/ata-WDC_WD20EZRX-00D8PB0_WD-WMC4N2965313";
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
        device = "/dev/disk/by-id/ata-ST31500341AS_9VS1FSEM";
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
