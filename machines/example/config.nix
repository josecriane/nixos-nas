{
  nasName = "nas1";

  hostname = "nixos-nas";

  nasIP = "192.168.1.100";

  gateway = "192.168.1.1";

  nameservers = [ "192.168.1.1" "1.1.1.1" ];

  domain = "example.com";

  subdomain = "in";

  adminUser = "admin";

  adminSSHKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderKeyReplaceWithYourOwn example@example.com"
  ];

  puid = 1000;
  pgid = 1000;

  timezone = "UTC";

  # Data disks (names matching disko.nix partition labels)
  dataDisks = [ "disk1" "disk2" "disk3" ];

  services = {
    samba = true;
    nfs = true;

    cockpit = true;
    filebrowser = true;

    authentikIntegration = false;
  };

  ldap = {
    enable = false;
    server = "";
    baseDN = "dc=nas,dc=local";
  };
}
