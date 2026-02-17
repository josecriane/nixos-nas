# Example hardware configuration
# Customize for your CPU type (intel/amd) and kernel version
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
  boot.kernelModules = [ "kvm-intel" ]; # Change to kvm-amd for AMD
  boot.kernelParams = [ "vm.swappiness=10" ];
  boot.supportedFilesystems = [
    "ext4"
    "vfat"
  ];

  hardware.cpu.intel.updateMicrocode = true; # Change to amd for AMD

  services.smartd = {
    enable = true;
    autodetect = true;
    notifications = {
      test = true;
      wall.enable = true;
    };
    defaults.monitored = "-a -o on -s (S/../.././02|L/../../7/04)";
  };
}
