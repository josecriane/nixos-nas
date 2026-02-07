# Full configuration example
# All services and options enabled
{
  nasName = "nas1";
  hostname = "nixos-nas";

  nasIP = "192.168.1.100";
  gateway = "192.168.1.1";
  nameservers = [ "192.168.1.1" "1.1.1.1" ];

  domain = "example.com";
  subdomain = "home";

  adminUser = "admin";
  adminSSHKeys = [
    "ssh-ed25519 AAAA... primary-key"
    "ssh-ed25519 AAAA... backup-key"
  ];

  puid = 1000;
  pgid = 1000;

  timezone = "America/New_York";

  services = {
    samba = true;
    nfs = true;
    cockpit = true;
    filebrowser = true;
    authentikIntegration = true;
  };

  ldap = {
    enable = true;
    server = "ldap://authentik.example.com";
    baseDN = "dc=example,dc=com";
  };
}
