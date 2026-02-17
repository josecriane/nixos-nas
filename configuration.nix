{
  config,
  lib,
  pkgs,
  nasConfig,
  ...
}:

{
  system.stateVersion = "24.11";
  networking.hostName = nasConfig.hostname;
  time.timeZone = nasConfig.timezone;
  i18n.defaultLocale = "en_US.UTF-8";

  environment.systemPackages = with pkgs; [
    htop
    iotop
    smartmontools
    mergerfs
    mergerfs-tools
    nfs-utils
    samba
    tmux
    vim
    curl
    wget
    lsof
    ncdu
    tree
  ];

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true;
    };
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22
      139
      445
      2049
    ];
    allowedUDPPorts = [
      137
      138
      2049
    ];
  };

  nas.webui = {
    enable = true;
    cockpit = {
      enable = true;
      port = 9090;
      allowUnencrypted = true;
      origins = [
        "https://nas.local"
        "https://${nasConfig.nasName}.${nasConfig.subdomain}.${nasConfig.domain}"
        "http://localhost:9090"
      ];
    };
    filebrowser = {
      enable = true;
      port = 8080;
      rootPath = "/mnt/storage";
      proxyAuth = true;
      proxyHeader = "X-authentik-username";
    };
  };

  nas.reverseProxy = {
    enable = false;
    domain = "nas.local";
    ssl = {
      enable = true;
      useSelfSigned = true;
    };
    authentik = {
      enable = false;
      url = "https://authentik.local";
      outpostUrl = "http://authentik-outpost:9000";
    };
    cockpit.enable = true;
    filebrowser.enable = true;
  };
}
