{
  config,
  lib,
  pkgs,
  nasConfig,
  ...
}:

let
  adminUser = nasConfig.adminUser;
  networkPrefix =
    builtins.head (builtins.match "([0-9]+\\.[0-9]+\\.[0-9]+)\\.[0-9]+" nasConfig.gateway) + ".";
  networkCIDR = networkPrefix + "0/24";
in
{
  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = "NixOS NAS";
        "netbios name" = nasConfig.hostname;
        security = "user";
        "hosts allow" = "${networkPrefix} 127.0.0.1";
        "hosts deny" = "0.0.0.0/0";
        "aio read size" = 16384;
        "aio write size" = 16384;
        "use sendfile" = true;
        "min receivefile size" = 16384;
        "socket options" = "TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=524288 SO_SNDBUF=524288";
        "read raw" = true;
        "write raw" = true;
        "max xmit" = 65535;
        "strict allocate" = true;
        "allocation roundup size" = 4096;
        "log level" = 1;
        "max log size" = 50;
        oplocks = false;
        "level2 oplocks" = false;
        "kernel oplocks" = false;
      };

      media = {
        path = "/mnt/storage/media";
        "valid users" = adminUser;
        writable = "yes";
        browseable = "yes";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = adminUser;
        "force group" = adminUser;
        comment = "Media files";
        "strict allocate" = "yes";
        "read raw" = "yes";
        "write raw" = "yes";
      };

      files = {
        path = "/mnt/storage/files";
        "valid users" = adminUser;
        writable = "yes";
        browseable = "yes";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = adminUser;
        "force group" = adminUser;
        comment = "General files";
      };

      backups = {
        path = "/mnt/storage/backups";
        "valid users" = adminUser;
        writable = "yes";
        browseable = "yes";
        "create mask" = "0600";
        "directory mask" = "0700";
        "force user" = adminUser;
        "force group" = adminUser;
        comment = "Backup storage";
      };

      downloads = {
        path = "/mnt/storage/downloads";
        "valid users" = adminUser;
        writable = "yes";
        browseable = "yes";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = adminUser;
        "force group" = adminUser;
        comment = "Downloads";
      };
    };
  };

  services.nfs.settings = {
    nfsd = {
      udp = false;
      tcp = true;
      threads = 16;
    };
  };

  services.nfs.server = {
    enable = true;
    exports = ''
      /mnt/storage          ${networkCIDR}(rw,async,no_subtree_check,no_root_squash,fsid=0,all_squash,anonuid=${toString nasConfig.puid},anongid=${toString nasConfig.pgid})
      /mnt/storage/media    ${networkCIDR}(rw,async,no_subtree_check,no_root_squash,fsid=1,all_squash,anonuid=${toString nasConfig.puid},anongid=${toString nasConfig.pgid})
      /mnt/storage/files    ${networkCIDR}(rw,async,no_subtree_check,no_root_squash,fsid=2,all_squash,anonuid=${toString nasConfig.puid},anongid=${toString nasConfig.pgid})
      /mnt/storage/backups  ${networkCIDR}(rw,sync,no_subtree_check,no_root_squash,fsid=3,all_squash,anonuid=${toString nasConfig.puid},anongid=${toString nasConfig.pgid})
      /mnt/storage/downloads ${networkCIDR}(rw,async,no_subtree_check,no_root_squash,fsid=4,all_squash,anonuid=${toString nasConfig.puid},anongid=${toString nasConfig.pgid})
    '';
  };

  networking.firewall.allowedTCPPorts = [
    2049
    111
  ];
  networking.firewall.allowedUDPPorts = [
    2049
    111
  ];

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      domain = true;
      workstation = true;
    };
    extraServiceFiles = {
      smb = ''
        <?xml version="1.0" standalone='no'?>
        <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
        <service-group>
          <name replace-wildcards="yes">%h</name>
          <service>
            <type>_smb._tcp</type>
            <port>445</port>
          </service>
        </service-group>
      '';
    };
  };
}
