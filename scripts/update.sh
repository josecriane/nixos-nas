#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
resolve_machine "${1:-}"
read_config

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         NixOS NAS - Update Configuration ($MACHINE)          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

toggle_bool() {
    local current="$1"
    if [[ "$current" == "true" ]]; then
        echo "false"
    else
        echo "true"
    fi
}

# Read service status
SVC_COCKPIT=$(grep -A5 'services = {' "$CONFIG_FILE" | grep 'cockpit' | grep -o 'true\|false')
SVC_FILEBROWSER=$(grep -A5 'services = {' "$CONFIG_FILE" | grep 'filebrowser' | grep -o 'true\|false')
SVC_AUTHENTIK=$(grep -A5 'services = {' "$CONFIG_FILE" | grep 'authentikIntegration' | grep -o 'true\|false' || echo "false")

echo -e "${GREEN}Machine:${NC} $MACHINE"
echo -e "${GREEN}NAS:${NC}     $HOSTNAME ($NAS_IP)"
echo -e "${GREEN}User:${NC}    $ADMIN_USER"
echo ""

# Show current configuration
echo -e "${BLUE}=== Current Configuration ===${NC}"
echo ""
echo -e "  1. Cockpit:              ${CYAN}$SVC_COCKPIT${NC}"
echo -e "  2. File Browser:         ${CYAN}$SVC_FILEBROWSER${NC}"
echo -e "  3. Authentik SSO:        ${CYAN}$SVC_AUTHENTIK${NC}"
echo ""

# Ask if they want to change anything
if confirm "Do you want to change any configuration?"; then
    echo ""
    echo -e "${YELLOW}Enter the numbers of options to change (separated by space)${NC}"
    echo -e "${YELLOW}Example: 1 3 (to change Cockpit and Authentik)${NC}"
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
        esac
    done

    if [[ "$CHANGED" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}Applying changes to config.nix...${NC}"

        # Update services in config.nix
        sed -i "s/cockpit = \(true\|false\);/cockpit = $SVC_COCKPIT;/" "$CONFIG_FILE"
        sed -i "s/filebrowser = \(true\|false\);/filebrowser = $SVC_FILEBROWSER;/" "$CONFIG_FILE"
        sed -i "s/authentikIntegration = \(true\|false\);/authentikIntegration = $SVC_AUTHENTIK;/" "$CONFIG_FILE"

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

# Get current NAS key
CURRENT_NAS_KEY=$(ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$NAS_IP" "cat /etc/ssh/ssh_host_ed25519_key.pub" 2>/dev/null)

if [[ -z "$CURRENT_NAS_KEY" ]]; then
    echo -e "${YELLOW}Warning: Could not get NAS SSH key${NC}"
else
    # Check if it matches saved key
    if [[ -f "$KEY_DIR/ssh_host_ed25519_key.pub" ]]; then
        SAVED_NAS_KEY=$(cat "$KEY_DIR/ssh_host_ed25519_key.pub")
        if [[ "$CURRENT_NAS_KEY" != "$SAVED_NAS_KEY" ]]; then
            echo -e "${YELLOW}Warning: NAS SSH key has changed${NC}"
            echo -e "${YELLOW}  Re-encrypting secrets...${NC}"

            # Save new key
            echo "$CURRENT_NAS_KEY" > "$KEY_DIR/ssh_host_ed25519_key.pub"

            # Convert to age
            if command -v ssh-to-age &>/dev/null; then
                NAS_AGE_KEY=$(echo "$CURRENT_NAS_KEY" | ssh-to-age)
            else
                NAS_AGE_KEY=$(echo "$CURRENT_NAS_KEY" | nix run nixpkgs#ssh-to-age 2>/dev/null)
            fi

            if [[ -n "$NAS_AGE_KEY" ]]; then
                # Update the machine's key in secrets.nix
                sed -i "s|$MACHINE = \"age1[a-z0-9]*\";|$MACHINE = \"$NAS_AGE_KEY\";|" "$SECRETS_DIR/secrets.nix"
                echo -e "${GREEN}secrets.nix updated${NC}"

                # Re-encrypt samba-password if exists
                if [[ -f "$SECRETS_DIR/$MACHINE/samba-password.age" ]]; then
                    echo -e "${YELLOW}  Samba secret needs to be re-encrypted${NC}"
                    echo -e "${YELLOW}  Run ./scripts/setup.sh $MACHINE to configure the password again${NC}"
                    echo -e "${YELLOW}  Or configure it manually after: sudo smbpasswd -a $ADMIN_USER${NC}"

                    rm -f "$SECRETS_DIR/$MACHINE/samba-password.age"
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
if ! nix build ".#nixosConfigurations.$MACHINE.config.system.build.toplevel" --impure --no-link 2>/dev/null; then
    echo -e "${RED}Error: Configuration has errors${NC}"
    exit 1
fi
echo -e "${GREEN}Configuration valid${NC}"

# Confirm update
echo ""
if ! confirm "Apply changes to $MACHINE?"; then
    echo "Update cancelled."
    exit 0
fi

# Update
echo -e "\n${BLUE}=== Updating $MACHINE ===${NC}\n"

NIX_SSHOPTS="-o StrictHostKeyChecking=no" nixos-rebuild switch \
    --flake ".#$MACHINE" \
    --target-host "$ADMIN_USER@$NAS_IP" \
    --use-remote-sudo \
    --build-host "$ADMIN_USER@$NAS_IP" \
    --impure

echo -e "\n${GREEN}$MACHINE updated successfully${NC}"
echo ""

# Show status
echo -e "${YELLOW}Current NAS status:${NC}"
ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$NAS_IP" "nas-status" 2>/dev/null || true
