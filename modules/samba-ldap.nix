{ config, lib, pkgs, nasConfig, ... }:

with lib;

let
  ldapEnabled = (nasConfig.ldap.enable or false) && (nasConfig.services.authentikIntegration or false);
  ldapServer = nasConfig.ldap.server or "";
  ldapBaseDN = nasConfig.ldap.baseDN or "dc=nas,dc=local";
in
{
  config = mkIf ldapEnabled {
    environment.systemPackages = with pkgs; [
      openldap
    ];

    services.samba = {
      settings = {
        global = {
          "passdb backend" = "ldapsam:ldap://${ldapServer}";

          "ldap suffix" = ldapBaseDN;
          "ldap user suffix" = "ou=users";
          "ldap group suffix" = "ou=groups";
          "ldap admin dn" = "cn=admin,${ldapBaseDN}";
          "ldap ssl" = "off";

          "ldap passwd sync" = "yes";

          "ldap delete dn" = "no";
        };
      };
    };

    environment.etc."nixos-nas/check-ldap.sh" = {
      text = ''
        #!/usr/bin/env bash
        echo "=== LDAP Verification for Samba ==="
        echo ""
        echo "LDAP Server: ${ldapServer}"
        echo "Base DN: ${ldapBaseDN}"
        echo ""

        echo "--- Connection Test ---"
        if ${pkgs.openldap}/bin/ldapsearch -x -H ldap://${ldapServer} -b "${ldapBaseDN}" "(objectClass=*)" dn 2>/dev/null | head -5; then
          echo "OK: LDAP connection works"
        else
          echo "ERROR: Cannot connect to LDAP"
          echo ""
          echo "Verify that:"
          echo "  1. K3s server is running"
          echo "  2. Authentik LDAP Outpost is deployed"
          echo "  3. IP ${ldapServer} is correct"
        fi
        echo ""

        echo "--- Available Users ---"
        ${pkgs.openldap}/bin/ldapsearch -x -H ldap://${ldapServer} -b "ou=users,${ldapBaseDN}" "(objectClass=person)" cn 2>/dev/null | grep "^cn:" || echo "No users found"
      '';
      mode = "0755";
    };

    warnings = [
      ''
        Samba is configured to use Authentik LDAP.
        Users must exist in Authentik to access shares.

        To verify: /etc/nixos-nas/check-ldap.sh
        LDAP Server: ${ldapServer}
      ''
    ];
  };
}
