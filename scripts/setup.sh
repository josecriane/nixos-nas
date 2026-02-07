#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config.nix"
SECRETS_DIR="$PROJECT_DIR/secrets"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         NixOS NAS - Initial Configuration                    ║${NC}"
echo -e "${BLUE}║         MergerFS + SnapRAID                                  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check dependencies
MISSING_DEPS=()
command -v age &>/dev/null || MISSING_DEPS+=("age")
command -v ssh-keygen &>/dev/null || MISSING_DEPS+=("openssh")
command -v ssh-to-age &>/dev/null || MISSING_DEPS+=("ssh-to-age")

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    echo -e "${RED}Error: Missing dependencies: ${MISSING_DEPS[*]}${NC}"
    echo ""
    echo "Install them with:"
    echo "  nix-shell -p ${MISSING_DEPS[*]} --run \"$0\""
    echo ""
    echo "Or enter the devShell:"
    echo "  nix develop"
    exit 1
fi

# Utility functions
ask() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"

    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${GREEN}$prompt${NC} [$default]: ")" value
        value="${value:-$default}"
    else
        read -rp "$(echo -e "${GREEN}$prompt${NC}: ")" value
    fi

    eval "$var_name='$value'"
}

ask_secret() {
    local prompt="$1"
    local var_name="$2"

    read -srp "$(echo -e "${GREEN}$prompt${NC}: ")" value
    echo ""
    eval "$var_name='$value'"
}

confirm() {
    local prompt="$1"
    read -rp "$(echo -e "${YELLOW}$prompt${NC} [y/N]: ")" response
    [[ "$response" =~ ^[Yy]$ ]]
}

echo -e "${YELLOW}This wizard will guide you through NAS configuration.${NC}"
echo -e "${YELLOW}You will need to decide:${NC}"
echo "  - Network configuration (IP, gateway)"
echo "  - Samba password"
echo "  - Services to enable (Cockpit, File Browser)"
echo ""

# ═══════════════════════════════════════════════════════════════
# NAS IDENTIFICATION
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== NAS Identification ===${NC}\n"

ask "NAS name (e.g.: nas1, nas2)" "nas1" NAS_NAME
ask "System hostname" "nixos-nas" HOSTNAME

# ═══════════════════════════════════════════════════════════════
# NETWORK CONFIGURATION
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Network Configuration ===${NC}\n"

ask "NAS IP" "192.168.1.100" NAS_IP
ask "Gateway (router)" "192.168.1.1" GATEWAY
ask "Primary DNS" "192.168.1.1" DNS_PRIMARY
ask "Secondary DNS" "1.1.1.1" DNS_SECONDARY

# ═══════════════════════════════════════════════════════════════
# DOMAIN (for server integration)
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Domain (optional - for Authentik) ===${NC}\n"

ask "Your domain" "example.com" DOMAIN
ask "Subdomain for services" "in" SUBDOMAIN

echo -e "\n${CYAN}URLs that will be configured:${NC}"
echo "  - Cockpit: https://${NAS_NAME}.${SUBDOMAIN}.${DOMAIN}"
echo "  - Files:   https://files-${NAS_NAME}.${SUBDOMAIN}.${DOMAIN}"
echo ""

# ═══════════════════════════════════════════════════════════════
# USER AND SSH
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Administrator User ===${NC}\n"

ask "NAS administrator user" "nas" ADMIN_USER
ask "Timezone" "Europe/Madrid" TIMEZONE

# SSH Key - auto-detect
echo -e "\n${GREEN}Detecting SSH key...${NC}"
SSH_KEY=""
for keyfile in "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ed25519.pub"; do
    if [[ -f "$keyfile" ]]; then
        SSH_KEY=$(cat "$keyfile")
        echo -e "${GREEN}Found: $keyfile${NC}"
        echo -e "  ${YELLOW}${SSH_KEY:0:50}...${NC}"
        break
    fi
done

if [[ -z "$SSH_KEY" ]]; then
    echo -e "${RED}No SSH key found in ~/.ssh/${NC}"
    echo -e "${YELLOW}Generate one with: ssh-keygen -t ed25519${NC}"
    ask "Paste your public SSH key" "" SSH_KEY
fi

# ═══════════════════════════════════════════════════════════════
# SAMBA PASSWORD
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Samba Password ===${NC}\n"

echo -e "${YELLOW}This password will be used to access Samba shares.${NC}"
echo -e "${YELLOW}It will be stored encrypted with agenix.${NC}"
echo ""

while true; do
    ask_secret "Samba password" SAMBA_PASSWORD
    ask_secret "Confirm password" SAMBA_PASSWORD_CONFIRM

    if [[ "$SAMBA_PASSWORD" == "$SAMBA_PASSWORD_CONFIRM" ]]; then
        if [[ ${#SAMBA_PASSWORD} -lt 4 ]]; then
            echo -e "${RED}Password must be at least 4 characters${NC}"
        else
            echo -e "${GREEN}Password configured${NC}"
            break
        fi
    else
        echo -e "${RED}Passwords do not match, try again${NC}"
    fi
done

# ═══════════════════════════════════════════════════════════════
# SERVICES
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Services to Enable ===${NC}\n"

echo -e "${GREEN}Services always included:${NC}"
echo "  - Samba (Windows/Mac/Linux file sharing)"
echo "  - NFS (Linux file sharing)"
echo "  - SnapRAID (data protection)"
echo "  - MergerFS (disk pool)"
echo ""

echo -e "${GREEN}Optional services:${NC}\n"

SVC_COCKPIT="true"
if ! confirm "  Cockpit (web administration)?"; then SVC_COCKPIT="false"; fi

SVC_FILEBROWSER="true"
if ! confirm "  File Browser (web file manager)?"; then SVC_FILEBROWSER="false"; fi

# Authentik integration
SVC_AUTHENTIK="false"
LDAP_SERVER=""
LDAP_ENABLED="false"

echo ""
if confirm "  Integrate with Authentik SSO?"; then
    SVC_AUTHENTIK="true"
    echo ""
    echo -e "${CYAN}Authentik SSO enabled.${NC}"
    echo "  - Cockpit and File Browser will use ForwardAuth"
    echo ""

    if confirm "  Use Authentik LDAP for Samba? (experimental)"; then
        LDAP_ENABLED="true"
        ask "LDAP server IP (Authentik)" "" LDAP_SERVER
        echo ""
        echo -e "${YELLOW}NOTE: Users must exist in Authentik to access Samba.${NC}"
        echo -e "${YELLOW}      Requires K3s server to have LDAP Outpost configured.${NC}"
    fi
fi

# ═══════════════════════════════════════════════════════════════
# GENERATE NAS SSH KEYS
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Generating NAS Keys ===${NC}\n"

mkdir -p "$SECRETS_DIR"
NAS_KEY_DIR="$SECRETS_DIR/nas-keys"
mkdir -p "$NAS_KEY_DIR"

if [[ ! -f "$NAS_KEY_DIR/ssh_host_ed25519_key" ]]; then
    ssh-keygen -t ed25519 -f "$NAS_KEY_DIR/ssh_host_ed25519_key" -N "" -C "root@$HOSTNAME"
    echo -e "${GREEN}NAS SSH keys generated${NC}"
else
    echo -e "${GREEN}NAS SSH keys already exist${NC}"
    if confirm "Regenerate NAS SSH keys?"; then
        rm -f "$NAS_KEY_DIR/ssh_host_ed25519_key" "$NAS_KEY_DIR/ssh_host_ed25519_key.pub"
        ssh-keygen -t ed25519 -f "$NAS_KEY_DIR/ssh_host_ed25519_key" -N "" -C "root@$HOSTNAME"
        echo -e "${GREEN}NAS SSH keys regenerated${NC}"
    fi
fi

NAS_PUBLIC_KEY=$(cat "$NAS_KEY_DIR/ssh_host_ed25519_key.pub")

# Convert SSH key to age format
NAS_AGE_KEY=$(ssh-to-age < "$NAS_KEY_DIR/ssh_host_ed25519_key.pub")
echo -e "${GREEN}NAS age key: ${NAS_AGE_KEY}${NC}"

# Extract admin public key
ADMIN_PUBLIC_KEY=$(echo "$SSH_KEY" | awk '{print $1 " " $2}')

# ═══════════════════════════════════════════════════════════════
# SAVE CONFIG.NIX
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Saving Configuration ===${NC}\n"

cat > "$CONFIG_FILE" << EOF
# NAS Configuration - Generated by setup.sh
# Regenerate with: ./scripts/setup.sh
{
  # Identification
  nasName = "$NAS_NAME";
  hostname = "$HOSTNAME";

  # Network
  nasIP = "$NAS_IP";
  gateway = "$GATEWAY";
  nameservers = [ "$DNS_PRIMARY" "$DNS_SECONDARY" ];

  # Domain (for server integration)
  domain = "$DOMAIN";
  subdomain = "$SUBDOMAIN";

  # Administrator user
  adminUser = "$ADMIN_USER";
  adminSSHKeys = [
    "$SSH_KEY"
  ];

  # User/group IDs
  puid = 1000;
  pgid = 1000;

  # Timezone
  timezone = "$TIMEZONE";

  # Services
  services = {
    samba = true;
    nfs = true;
    cockpit = $SVC_COCKPIT;
    filebrowser = $SVC_FILEBROWSER;
    authentikIntegration = $SVC_AUTHENTIK;
  };

  # LDAP (for Samba with Authentik)
  ldap = {
    enable = $LDAP_ENABLED;
    server = "$LDAP_SERVER";
    baseDN = "dc=nas,dc=local";
  };
}
EOF

echo -e "${GREEN}config.nix saved${NC}"

# ═══════════════════════════════════════════════════════════════
# CONFIGURE AGENIX SECRETS
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Configuring Secrets (agenix) ===${NC}\n"

# Create secrets.nix
cat > "$SECRETS_DIR/secrets.nix" << EOF
let
  # NAS public key (age format, generated by setup.sh)
  nas = "$NAS_AGE_KEY";

  # Your public key for encrypting/decrypting
  admin = "$ADMIN_PUBLIC_KEY";

  allKeys = [ nas admin ];
in
{
  "samba-password.age".publicKeys = allKeys;
}
EOF

echo -e "${GREEN}secrets.nix created${NC}"

# Encrypt Samba password using age with NAS recipient
echo -n "$SAMBA_PASSWORD" | age -r "$NAS_AGE_KEY" -o "$SECRETS_DIR/samba-password.age"
if [[ -f "$SECRETS_DIR/samba-password.age" ]]; then
    echo -e "${GREEN}samba-password.age encrypted successfully${NC}"
else
    echo -e "${RED}Error: Could not create samba-password.age${NC}"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════
# VERIFY CONFIGURATION
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Verifying Configuration ===${NC}\n"

cd "$PROJECT_DIR"
if nix build .#nixosConfigurations.nas.config.system.build.toplevel --impure --no-link 2>/dev/null; then
    echo -e "${GREEN}Configuration valid${NC}"
else
    echo -e "${YELLOW}Warning: Configuration has errors (review manually)${NC}"
fi

# ═══════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                  Configuration Complete                      ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}NAS:${NC}          $NAS_NAME ($HOSTNAME)"
echo -e "  ${GREEN}IP:${NC}           $NAS_IP"
echo -e "  ${GREEN}User:${NC}         $ADMIN_USER"
echo -e "  ${GREEN}Gateway:${NC}      $GATEWAY"
echo ""
echo -e "  ${GREEN}Services:${NC}"
echo "    - Samba + NFS"
echo "    - MergerFS + SnapRAID"
[[ "$SVC_COCKPIT" == "true" ]] && echo "    - Cockpit (https://$NAS_IP:9090)"
[[ "$SVC_FILEBROWSER" == "true" ]] && echo "    - File Browser (http://$NAS_IP:8080)"
[[ "$SVC_AUTHENTIK" == "true" ]] && echo "    - Authentik SSO integration"
echo ""
echo -e "  ${GREEN}Encrypted secrets:${NC}"
echo "    - samba-password.age"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo ""
echo "  1. Prepare the physical NAS:"
echo "     - Boot with NixOS USB"
echo "     - Verify it has IP: $NAS_IP"
echo ""
echo "  2. Install NixOS on the NAS:"
echo -e "     ${CYAN}./scripts/install.sh${NC}"
echo ""
echo "  3. After installation, configure Samba manually:"
echo -e "     ${CYAN}ssh $ADMIN_USER@$NAS_IP 'sudo smbpasswd -a $ADMIN_USER'${NC}"
echo ""
