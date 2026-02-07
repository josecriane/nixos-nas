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

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         NixOS NAS - Update Configuration                     ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check that config.nix exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error: config.nix not found${NC}"
    echo "Run first: ./scripts/setup.sh"
    exit 1
fi

# Functions
confirm() {
    local prompt="$1"
    read -rp "$(echo -e "${YELLOW}$prompt${NC} [y/N]: ")" response
    [[ "$response" =~ ^[Yy]$ ]]
}

toggle_bool() {
    local current="$1"
    if [[ "$current" == "true" ]]; then
        echo "false"
    else
        echo "true"
    fi
}

# Read current configuration
NAS_IP=$(grep 'nasIP' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
ADMIN_USER=$(grep 'adminUser' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
HOSTNAME=$(grep 'hostname' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')

# Read service status
SVC_COCKPIT=$(grep -A5 'services = {' "$CONFIG_FILE" | grep 'cockpit' | grep -o 'true\|false')
SVC_FILEBROWSER=$(grep -A5 'services = {' "$CONFIG_FILE" | grep 'filebrowser' | grep -o 'true\|false')
SVC_AUTHENTIK=$(grep -A5 'services = {' "$CONFIG_FILE" | grep 'authentikIntegration' | grep -o 'true\|false' || echo "false")
LDAP_ENABLED=$(grep -A5 'ldap = {' "$CONFIG_FILE" | grep 'enable' | grep -o 'true\|false' || echo "false")

echo -e "${GREEN}NAS:${NC} $HOSTNAME ($NAS_IP)"
echo -e "${GREEN}User:${NC} $ADMIN_USER"
echo ""

# Show current configuration
echo -e "${BLUE}=== Current Configuration ===${NC}"
echo ""
echo -e "  1. Cockpit:              ${CYAN}$SVC_COCKPIT${NC}"
echo -e "  2. File Browser:         ${CYAN}$SVC_FILEBROWSER${NC}"
echo -e "  3. Authentik SSO:        ${CYAN}$SVC_AUTHENTIK${NC}"
echo -e "  4. LDAP for Samba:       ${CYAN}$LDAP_ENABLED${NC}"
echo ""

# Ask if they want to change anything
if confirm "Do you want to change any configuration?"; then
    echo ""
    echo -e "${YELLOW}Enter the numbers of options to change (separated by space)${NC}"
    echo -e "${YELLOW}Example: 3 4 (to change Authentik and LDAP)${NC}"
    echo -e "${YELLOW}Enter to change nothing${NC}"
    read -rp "> " OPTIONS

    CHANGED=false

    for opt in $OPTIONS; do
        case $opt in
            1)
                SVC_COCKPIT=$(toggle_bool "$SVC_COCKPIT")
                echo -e "  Cockpit: ${GREEN}$SVC_COCKPIT${NC}"
                CHANGED=true
                ;;
            2)
                SVC_FILEBROWSER=$(toggle_bool "$SVC_FILEBROWSER")
                echo -e "  File Browser: ${GREEN}$SVC_FILEBROWSER${NC}"
                CHANGED=true
                ;;
            3)
                SVC_AUTHENTIK=$(toggle_bool "$SVC_AUTHENTIK")
                echo -e "  Authentik SSO: ${GREEN}$SVC_AUTHENTIK${NC}"
                CHANGED=true
                ;;
            4)
                LDAP_ENABLED=$(toggle_bool "$LDAP_ENABLED")
                echo -e "  LDAP for Samba: ${GREEN}$LDAP_ENABLED${NC}"
                CHANGED=true
                ;;
        esac
    done

    if [[ "$CHANGED" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}Applying changes to config.nix...${NC}"

        # Update services in config.nix
        sed -i "s/cockpit = \(true\|false\);/cockpit = $SVC_COCKPIT;/" "$CONFIG_FILE"
        sed -i "s/filebrowser = \(true\|false\);/filebrowser = $SVC_FILEBROWSER;/" "$CONFIG_FILE"
        sed -i "s/authentikIntegration = \(true\|false\);/authentikIntegration = $SVC_AUTHENTIK;/" "$CONFIG_FILE"

        # Update LDAP
        sed -i "/ldap = {/,/};/s/enable = \(true\|false\);/enable = $LDAP_ENABLED;/" "$CONFIG_FILE"

        echo -e "${GREEN}config.nix updated${NC}"
    fi
fi

echo ""

# Check connectivity
echo -e "${YELLOW}Checking connectivity...${NC}"
if ! ping -c 1 -W 3 "$NAS_IP" &>/dev/null; then
    echo -e "${RED}Cannot reach $NAS_IP${NC}"
    exit 1
fi
echo -e "${GREEN}NAS reachable${NC}"

# Check SSH
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "$ADMIN_USER@$NAS_IP" "echo ok" &>/dev/null; then
    echo -e "${RED}Cannot connect via SSH${NC}"
    exit 1
fi
echo -e "${GREEN}SSH working${NC}"

# ═══════════════════════════════════════════════════════════════
# VERIFY SSH KEYS (for agenix)
# ═══════════════════════════════════════════════════════════════
echo -e "\n${YELLOW}Verifying NAS SSH keys...${NC}"

NAS_KEY_DIR="$PROJECT_DIR/secrets/nas-keys"
SECRETS_DIR="$PROJECT_DIR/secrets"

# Get current NAS key
CURRENT_NAS_KEY=$(ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$NAS_IP" "cat /etc/ssh/ssh_host_ed25519_key.pub" 2>/dev/null)

if [[ -z "$CURRENT_NAS_KEY" ]]; then
    echo -e "${YELLOW}Warning: Could not get NAS SSH key${NC}"
else
    # Check if it matches saved key
    if [[ -f "$NAS_KEY_DIR/ssh_host_ed25519_key.pub" ]]; then
        SAVED_NAS_KEY=$(cat "$NAS_KEY_DIR/ssh_host_ed25519_key.pub")
        if [[ "$CURRENT_NAS_KEY" != "$SAVED_NAS_KEY" ]]; then
            echo -e "${YELLOW}Warning: NAS SSH key has changed${NC}"
            echo -e "${YELLOW}  Re-encrypting secrets...${NC}"

            # Save new key
            echo "$CURRENT_NAS_KEY" > "$NAS_KEY_DIR/ssh_host_ed25519_key.pub"

            # Convert to age
            if command -v ssh-to-age &>/dev/null; then
                NAS_AGE_KEY=$(echo "$CURRENT_NAS_KEY" | ssh-to-age)
            else
                NAS_AGE_KEY=$(echo "$CURRENT_NAS_KEY" | nix run nixpkgs#ssh-to-age 2>/dev/null)
            fi

            if [[ -n "$NAS_AGE_KEY" ]]; then
                # Update secrets.nix
                ADMIN_KEY=$(grep "admin = " "$SECRETS_DIR/secrets.nix" | sed 's/.*"\(.*\)".*/\1/')
                cat > "$SECRETS_DIR/secrets.nix" << EOF
let
  # NAS public key (age format, updated by update.sh)
  nas = "$NAS_AGE_KEY";

  # Your public key for encrypting/decrypting
  admin = "$ADMIN_KEY";

  allKeys = [ nas admin ];
in
{
  "samba-password.age".publicKeys = allKeys;
}
EOF
                echo -e "${GREEN}secrets.nix updated${NC}"

                # Re-encrypt samba-password if exists and we can read the password
                if [[ -f "$SECRETS_DIR/samba-password.age" ]]; then
                    echo -e "${YELLOW}  Samba secret needs to be re-encrypted${NC}"
                    echo -e "${YELLOW}  Run ./scripts/setup.sh to configure the password again${NC}"
                    echo -e "${YELLOW}  Or configure it manually after: sudo smbpasswd -a $ADMIN_USER${NC}"

                    # Remove old secret to avoid agenix errors
                    rm -f "$SECRETS_DIR/samba-password.age"
                    echo -e "${GREEN}Samba secret removed (configure manually after)${NC}"
                fi
            fi
        else
            echo -e "${GREEN}SSH keys match${NC}"
        fi
    fi
fi

# Verify configuration
echo -e "\n${YELLOW}Verifying configuration...${NC}"
cd "$PROJECT_DIR"
if ! nix build .#nixosConfigurations.nas.config.system.build.toplevel --impure --no-link 2>/dev/null; then
    echo -e "${RED}Error: Configuration has errors${NC}"
    exit 1
fi
echo -e "${GREEN}Configuration valid${NC}"

# Confirm update
echo ""
if ! confirm "Apply changes to NAS?"; then
    echo "Update cancelled."
    exit 0
fi

# Update
echo -e "\n${BLUE}=== Updating NAS ===${NC}\n"

NIX_SSHOPTS="-o StrictHostKeyChecking=no" nixos-rebuild switch \
    --flake .#nas \
    --target-host "$ADMIN_USER@$NAS_IP" \
    --use-remote-sudo \
    --build-host "$ADMIN_USER@$NAS_IP"

echo -e "\n${GREEN}NAS updated successfully${NC}"
echo ""

# Show status
echo -e "${YELLOW}Current NAS status:${NC}"
ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$NAS_IP" "nas-status" 2>/dev/null || true
