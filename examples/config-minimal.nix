# Minimal configuration example
# Only essential services enabled
{
  nasName = "nas";
  hostname = "nixos-nas";

  nasIP = "192.168.1.100";
  gateway = "192.168.1.1";
  nameservers = [ "1.1.1.1" "8.8.8.8" ];

  domain = "local";
  subdomain = "";

  adminUser = "admin";
  adminSSHKeys = [
    "ssh-ed25519 AAAA... your-key-here"
  ];

  puid = 1000;
  pgid = 1000;

  timezone = "UTC";

  services = {
    samba = true;
    nfs = false;
    cockpit = false;
    filebrowser = false;
    authentikIntegration = false;
  };

  ldap = {
    enable = false;
    server = "";
    baseDN = "";
  };
}
