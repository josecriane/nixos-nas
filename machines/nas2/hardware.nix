{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/disk/by-id/ata-TOSHIBA_MK1237GSX_186VTEQ2T";

  boot.kernelPackages = pkgs.linuxPackages_6_6;
  boot.kernelModules = [ "kvm-intel" ];
  boot.kernelParams = [ "vm.swappiness=10" ];
  boot.supportedFilesystems = [ "ext4" "vfat" ];

  hardware.cpu.intel.updateMicrocode = true;
}
