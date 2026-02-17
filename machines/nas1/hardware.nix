{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  boot.kernelPackages = pkgs.linuxPackages_6_6;
  boot.kernelModules = [ "kvm-intel" ];
  boot.kernelParams = [ "vm.swappiness=10" ];
  boot.supportedFilesystems = [
    "ext4"
    "vfat"
  ];

  hardware.cpu.intel.updateMicrocode = true;
}
