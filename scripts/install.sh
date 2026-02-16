#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
resolve_machine "${1:-}"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         NixOS NAS - Installation ($MACHINE)                  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check that machine keys exist
if [[ ! -f "$KEY_DIR/ssh_host_ed25519_key" ]]; then
    echo -e "${RED}Error: NAS SSH keys not found at $KEY_DIR${NC}"
    echo "Run first: ./scripts/setup.sh $MACHINE"
    exit 1
fi

# Check that Samba secret exists
if [[ ! -f "$SECRETS_DIR/$MACHINE/samba-password.age" ]]; then
    echo -e "${RED}Error: Samba secret not found${NC}"
    echo "Run first: ./scripts/setup.sh $MACHINE"
    exit 1
fi

# Read configuration
read_config

echo -e "${GREEN}Machine:${NC} $MACHINE"
echo -e "${GREEN}NAS:${NC}     $HOSTNAME"
echo -e "${GREEN}IP:${NC}      $NAS_IP"
echo -e "${GREEN}User:${NC}    $ADMIN_USER"
echo ""

# Check connectivity
echo -e "${YELLOW}Checking connectivity...${NC}"
if ! ping -c 1 -W 3 "$NAS_IP" &>/dev/null; then
    echo -e "${RED}Cannot reach $NAS_IP${NC}"
    echo ""
    echo "Verify that:"
    echo "  1. The NAS is powered on"
    echo "  2. It is booted with the NixOS ISO"
    echo "  3. It has the correct IP configured"
    exit 1
fi
echo -e "${GREEN}NAS reachable${NC}"

# Clean known_hosts
ssh-keygen -R "$NAS_IP" &>/dev/null || true

# Detect SSH user
echo -e "${YELLOW}Detecting SSH user...${NC}"

SSH_USER=""

# Try with admin user (NixOS already installed)
if ssh $SSH_OPTS -o ConnectTimeout=10 -o BatchMode=yes "$ADMIN_USER@$NAS_IP" "echo ok" &>/dev/null; then
    SSH_USER="$ADMIN_USER"
    echo -e "${GREEN}Connecting as $SSH_USER (existing NixOS)${NC}"
# Try with nixos + password
elif command -v sshpass &>/dev/null && sshpass -p nixos ssh $SSH_OPTS -o ConnectTimeout=10 -o PubkeyAuthentication=no "nixos@$NAS_IP" "echo ok" &>/dev/null; then
    SSH_USER="nixos"
    USE_SSHPASS="true"
    echo -e "${GREEN}Connecting as nixos (installation ISO)${NC}"
# Try with nixos + SSH key
elif ssh $SSH_OPTS -o ConnectTimeout=10 -o BatchMode=yes "nixos@$NAS_IP" "echo ok" &>/dev/null; then
    SSH_USER="nixos"
    echo -e "${GREEN}Connecting as nixos (SSH key)${NC}"
else
    echo -e "${YELLOW}Could not auto-detect SSH user${NC}"
    echo ""
    echo "Is the NAS booted with the NixOS ISO?"
    echo ""
    echo "On the NAS, run:"
    echo "  sudo systemctl start sshd"
    echo "  passwd nixos  # set password 'nixos'"
    echo ""
    exit 1
fi

# Copy SSH key if needed
if ! ssh $SSH_OPTS -o BatchMode=yes "$SSH_USER@$NAS_IP" "echo ok" &>/dev/null; then
    echo -e "${YELLOW}Copying SSH key to NAS...${NC}"
    if [[ "${USE_SSHPASS:-}" == "true" ]]; then
        sshpass -p nixos ssh-copy-id $SSH_OPTS -o PubkeyAuthentication=no "$SSH_USER@$NAS_IP"
    else
        ssh-copy-id $SSH_OPTS "$SSH_USER@$NAS_IP"
    fi
fi
echo -e "${GREEN}SSH key configured${NC}"

# Show disk information
echo -e "\n${BLUE}=== Disks Detected on NAS ===${NC}\n"

if [[ "${USE_SSHPASS:-}" == "true" ]]; then
    sshpass -p nixos ssh $SSH_OPTS "$SSH_USER@$NAS_IP" "lsblk -d -o NAME,SIZE,MODEL | grep -E 'sd|nvme'"
else
    ssh $SSH_OPTS "$SSH_USER@$NAS_IP" "lsblk -d -o NAME,SIZE,MODEL | grep -E 'sd|nvme'"
fi

echo ""

# Confirm installation
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  WARNING: This will ERASE ALL content on the disks           ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}Continue with installation? [y/N]:${NC} ")" confirm_install
if [[ ! "$confirm_install" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

# Create temporary directory for extra-files (server SSH keys)
echo -e "\n${BLUE}=== Preparing Installation ===${NC}\n"

EXTRA_FILES=$(mktemp -d)
mkdir -p "$EXTRA_FILES/etc/ssh"
cp "$KEY_DIR/ssh_host_ed25519_key" "$EXTRA_FILES/etc/ssh/"
cp "$KEY_DIR/ssh_host_ed25519_key.pub" "$EXTRA_FILES/etc/ssh/"
chmod 600 "$EXTRA_FILES/etc/ssh/ssh_host_ed25519_key"

echo -e "${GREEN}SSH keys prepared${NC}"

# Run nixos-anywhere
echo -e "\n${BLUE}=== Starting Installation with nixos-anywhere ===${NC}\n"

cd "$PROJECT_DIR"

if [[ "${USE_SSHPASS:-}" == "true" ]]; then
    SSHPASS=nixos nix run github:nix-community/nixos-anywhere -- \
        --flake ".#$MACHINE" \
        --target-host "$SSH_USER@$NAS_IP" \
        --extra-files "$EXTRA_FILES" \
        --env-password
else
    nix run github:nix-community/nixos-anywhere -- \
        --flake ".#$MACHINE" \
        --target-host "$SSH_USER@$NAS_IP" \
        --extra-files "$EXTRA_FILES"
fi

# Cleanup
rm -rf "$EXTRA_FILES"

# Wait for NAS to reboot
echo -e "\n${YELLOW}Waiting for NAS to reboot...${NC}"
sleep 15

# Clean known_hosts again (new SSH key)
ssh-keygen -R "$NAS_IP" &>/dev/null || true

# Try to connect
for i in $(seq 1 30); do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$ADMIN_USER@$NAS_IP" "echo ok" &>/dev/null; then
        echo -e "${GREEN}NAS accessible${NC}"
        break
    fi
    echo "Waiting for SSH... ($i/30)"
    sleep 10
done

# Check status
echo -e "\n${BLUE}=== Verifying Installation ===${NC}\n"

if ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$NAS_IP" "nas-status" 2>/dev/null; then
    echo ""
else
    echo -e "${YELLOW}Could not run nas-status (NAS may still be starting)${NC}"
fi

# Configure Samba password
echo -e "\n${BLUE}=== Configuring Samba ===${NC}\n"
echo -e "${YELLOW}Now you need to configure the Samba password.${NC}"
echo -e "${YELLOW}Use the same password you configured in setup.sh${NC}"
echo ""

read -rp "$(echo -e "${GREEN}Configure Samba password now? [Y/n]:${NC} ")" setup_samba
if [[ ! "$setup_samba" =~ ^[Nn]$ ]]; then
    ssh -t -o StrictHostKeyChecking=no "$ADMIN_USER@$NAS_IP" "sudo smbpasswd -a $ADMIN_USER"
fi

# Final summary
echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              Installation Complete!                          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}Connect via SSH:${NC}"
echo -e "    ssh $ADMIN_USER@$NAS_IP"
echo ""
echo -e "  ${GREEN}Web services:${NC}"
echo -e "    Cockpit:      http://$NAS_IP:9090"
echo -e "    File Browser: http://$NAS_IP:8080"
echo ""
echo -e "  ${GREEN}Samba shares:${NC}"
echo -e "    \\\\\\\\$NAS_IP\\\\storage"
echo -e "    smb://$NAS_IP/storage"
echo ""
echo -e "  ${GREEN}NFS:${NC}"
echo -e "    mount -t nfs $NAS_IP:/mnt/storage /mnt/nas"
echo ""
echo -e "  ${GREEN}Useful commands:${NC}"
echo -e "    nas-status           # View NAS status"
echo ""
