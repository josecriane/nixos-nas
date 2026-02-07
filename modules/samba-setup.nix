{ config, lib, pkgs, nasConfig, ... }:

with lib;

let
  sambaSecretPath = ../secrets/samba-password.age;
  sambaSecretExists = builtins.pathExists sambaSecretPath;
in
{
  age.secrets = mkIf sambaSecretExists {
    samba-password = {
      file = sambaSecretPath;
      owner = "root";
      group = "root";
      mode = "0400";
      symlink = false;
    };
  };

  systemd.services.samba-setup-password = mkIf sambaSecretExists {
    description = "Setup Samba password for ${nasConfig.adminUser}";
    after = [ "samba-smbd.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      SuccessExitStatus = "0 1";
    };

    script = ''
      SECRET_FILE="/run/agenix/samba-password"

      if [[ ! -f "$SECRET_FILE" ]]; then
        echo "Samba secret not found at $SECRET_FILE"
        echo "Configure password manually with: sudo smbpasswd -a ${nasConfig.adminUser}"
        exit 0
      fi

      if [[ ! -s "$SECRET_FILE" ]]; then
        echo "Samba secret is empty"
        echo "Configure password manually with: sudo smbpasswd -a ${nasConfig.adminUser}"
        exit 0
      fi

      if ! ${pkgs.samba}/bin/pdbedit -L 2>/dev/null | grep -q "^${nasConfig.adminUser}:"; then
        echo "Creating Samba user: ${nasConfig.adminUser}"
        (cat "$SECRET_FILE"; echo; cat "$SECRET_FILE"; echo) | \
          ${pkgs.samba}/bin/smbpasswd -a -s ${nasConfig.adminUser} 2>/dev/null || {
            echo "Error creating Samba user"
            echo "Configure password manually with: sudo smbpasswd -a ${nasConfig.adminUser}"
            exit 0
          }
        echo "Samba user created successfully"
      else
        echo "Samba user ${nasConfig.adminUser} already exists, updating password"
        (cat "$SECRET_FILE"; echo; cat "$SECRET_FILE"; echo) | \
          ${pkgs.samba}/bin/smbpasswd -s ${nasConfig.adminUser} 2>/dev/null || {
            echo "Error updating Samba password"
            exit 0
          }
        echo "Samba password updated"
      fi
    '';
  };
}
