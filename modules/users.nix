{
  config,
  lib,
  pkgs,
  nasConfig,
  ...
}:

{
  users.users.${nasConfig.adminUser} = {
    isNormalUser = true;
    description = "NAS Administrator";
    uid = nasConfig.puid;
    group = nasConfig.adminUser;
    extraGroups = [
      "wheel"
      "users"
    ];
    openssh.authorizedKeys.keys = nasConfig.adminSSHKeys;
    shell = pkgs.bash;
  };

  users.groups.${nasConfig.adminUser} = {
    gid = nasConfig.pgid;
  };

  security.sudo.wheelNeedsPassword = false;
  users.users.root.hashedPassword = "!";
}
