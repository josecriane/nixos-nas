#!/usr/bin/env bash
set -euo pipefail

# Colors (defined before sourcing common.sh for the machine name prompt)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MACHINES_DIR="$PROJECT_DIR/machines"
SECRETS_DIR="$PROJECT_DIR/secrets"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         NixOS NAS - Initial Configuration                    ║${NC}"
echo -e "${BLUE}║         MergerFS Multi-Machine Setup                         ║${NC}"
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
    echo "  nix-shell -p ${MISSING_DEPS[*]} --run \"$0 $*\""
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

# ═══════════════════════════════════════════════════════════════
# MACHINE NAME
# ═══════════════════════════════════════════════════════════════

MACHINE="${1:-}"
if [[ -z "$MACHINE" ]]; then
    echo -e "${YELLOW}This wizard will configure a new NAS machine.${NC}"
    echo ""
    ask "Machine name (e.g.: nas1, nas2)" "" MACHINE
fi

if [[ -z "$MACHINE" || "$MACHINE" == "example" ]]; then
    echo -e "${RED}Error: Invalid machine name${NC}"
    exit 1
fi

MACHINE_DIR="$MACHINES_DIR/$MACHINE"
KEY_DIR="$SECRETS_DIR/${MACHINE}-keys"

if [[ -d "$MACHINE_DIR" ]]; then
    echo -e "${YELLOW}Machine '$MACHINE' already exists at $MACHINE_DIR${NC}"
    if ! confirm "Overwrite configuration?"; then
        echo "Setup cancelled."
        exit 0
    fi
fi

echo ""
echo -e "${YELLOW}Configuring machine: ${CYAN}$MACHINE${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# NAS IDENTIFICATION
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== NAS Identification ===${NC}\n"

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
echo "  - Cockpit: https://${MACHINE}.${SUBDOMAIN}.${DOMAIN}"
echo "  - Files:   https://files-${MACHINE}.${SUBDOMAIN}.${DOMAIN}"
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
# HARDWARE CONFIGURATION
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Hardware Configuration ===${NC}\n"

echo -e "${YELLOW}CPU type:${NC}"
echo "  1) Intel"
echo "  2) AMD"
read -rp "$(echo -e "${GREEN}Select [1]:${NC} ")" CPU_CHOICE
CPU_CHOICE="${CPU_CHOICE:-1}"

if [[ "$CPU_CHOICE" == "2" ]]; then
    CPU_TYPE="amd"
    KVM_MODULE="kvm-amd"
else
    CPU_TYPE="intel"
    KVM_MODULE="kvm-intel"
fi

echo ""
echo -e "${YELLOW}Boot mode:${NC}"
echo "  1) UEFI (modern machines)"
echo "  2) Legacy BIOS (old machines)"
read -rp "$(echo -e "${GREEN}Select [1]:${NC} ")" BOOT_CHOICE
BOOT_CHOICE="${BOOT_CHOICE:-1}"

if [[ "$BOOT_CHOICE" == "2" ]]; then
    BOOT_MODE="bios"
else
    BOOT_MODE="uefi"
fi

echo ""
echo -e "${YELLOW}Disk configuration:${NC}"
echo ""
ask "System disk device" "/dev/sda" SYSTEM_DISK

echo ""
echo -e "${YELLOW}Data disks (these will be pooled with MergerFS):${NC}"
echo -e "${YELLOW}Enter disk devices separated by spaces (e.g.: /dev/sdb /dev/sdc /dev/sdd)${NC}"
read -rp "$(echo -e "${GREEN}Data disks:${NC} ")" DATA_DISKS_INPUT

# Parse data disks
IFS=' ' read -ra DATA_DISK_DEVICES <<< "$DATA_DISKS_INPUT"
NUM_DATA_DISKS=${#DATA_DISK_DEVICES[@]}

if [[ $NUM_DATA_DISKS -lt 1 ]]; then
    echo -e "${RED}Error: At least one data disk is required${NC}"
    exit 1
fi

# Generate disk names
DATA_DISK_NAMES=()
for i in $(seq 1 $NUM_DATA_DISKS); do
    DATA_DISK_NAMES+=("disk$i")
done

echo ""
echo -e "${GREEN}Configuration:${NC}"
echo "  System disk: $SYSTEM_DISK"
for i in $(seq 0 $((NUM_DATA_DISKS - 1))); do
    echo "  ${DATA_DISK_NAMES[$i]}: ${DATA_DISK_DEVICES[$i]}"
done
echo ""

# ═══════════════════════════════════════════════════════════════
# SERVICES
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Services to Enable ===${NC}\n"

echo -e "${GREEN}Services always included:${NC}"
echo "  - Samba (Windows/Mac/Linux file sharing)"
echo "  - NFS (Linux file sharing)"
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
    fi
fi

# ═══════════════════════════════════════════════════════════════
# GENERATE NAS SSH KEYS
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Generating NAS Keys ===${NC}\n"

mkdir -p "$KEY_DIR"

if [[ ! -f "$KEY_DIR/ssh_host_ed25519_key" ]]; then
    ssh-keygen -t ed25519 -f "$KEY_DIR/ssh_host_ed25519_key" -N "" -C "root@$HOSTNAME"
    echo -e "${GREEN}NAS SSH keys generated${NC}"
else
    echo -e "${GREEN}NAS SSH keys already exist${NC}"
    if confirm "Regenerate NAS SSH keys?"; then
        rm -f "$KEY_DIR/ssh_host_ed25519_key" "$KEY_DIR/ssh_host_ed25519_key.pub"
        ssh-keygen -t ed25519 -f "$KEY_DIR/ssh_host_ed25519_key" -N "" -C "root@$HOSTNAME"
        echo -e "${GREEN}NAS SSH keys regenerated${NC}"
    fi
fi

NAS_PUBLIC_KEY=$(cat "$KEY_DIR/ssh_host_ed25519_key.pub")

# Convert SSH key to age format
NAS_AGE_KEY=$(ssh-to-age < "$KEY_DIR/ssh_host_ed25519_key.pub")
echo -e "${GREEN}NAS age key: ${NAS_AGE_KEY}${NC}"

# Extract admin public key
ADMIN_PUBLIC_KEY=$(echo "$SSH_KEY" | awk '{print $1 " " $2}')

# ═══════════════════════════════════════════════════════════════
# SAVE MACHINE CONFIG
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Saving Configuration ===${NC}\n"

mkdir -p "$MACHINE_DIR"

# Build dataDisks nix list
DATA_DISKS_NIX=""
for name in "${DATA_DISK_NAMES[@]}"; do
    DATA_DISKS_NIX="$DATA_DISKS_NIX \"$name\""
done

cat > "$MACHINE_DIR/config.nix" << EOF
# NAS Configuration - Generated by setup.sh
# Regenerate with: ./scripts/setup.sh $MACHINE
{
  # Identification
  nasName = "$MACHINE";
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

  # Data disks (used by storage-mergerfs.nix and monitoring.nix)
  dataDisks = [$DATA_DISKS_NIX ];

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

echo -e "${GREEN}machines/$MACHINE/config.nix saved${NC}"

# ═══════════════════════════════════════════════════════════════
# GENERATE DISKO.NIX
# ═══════════════════════════════════════════════════════════════

# Start disko.nix
cat > "$MACHINE_DIR/disko.nix" << 'DISKO_HEADER'
{ config, lib, ... }:

{
  disko.devices = {
    disk = {
DISKO_HEADER

# System disk - boot partition depends on UEFI vs BIOS
if [[ "$BOOT_MODE" == "uefi" ]]; then
    BOOT_PARTITION='            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "defaults"
                  "umask=0077"
                ];
              };
            };'
else
    BOOT_PARTITION='            boot = {
              size = "1M";
              type = "EF02";
            };'
fi

cat >> "$MACHINE_DIR/disko.nix" << EOF
      system = {
        type = "disk";
        device = "$SYSTEM_DISK";
        content = {
          type = "gpt";
          partitions = {
$BOOT_PARTITION

            swap = {
              size = "4G";
              content = {
                type = "swap";
                randomEncryption = false;
                resumeDevice = true;
              };
            };

            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
                mountOptions = [
                  "defaults"
                  "noatime"
                ];
              };
            };
          };
        };
      };
EOF

# Data disks
for i in $(seq 0 $((NUM_DATA_DISKS - 1))); do
    disk_num=$((i + 1))
    disk_name="${DATA_DISK_NAMES[$i]}"
    disk_device="${DATA_DISK_DEVICES[$i]}"

    cat >> "$MACHINE_DIR/disko.nix" << EOF

      data$disk_num = {
        type = "disk";
        device = "$disk_device";
        content = {
          type = "gpt";
          partitions = {
            $disk_name = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/mnt/$disk_name";
                mountOptions = [
                  "defaults"
                  "noatime"
                  "nodiratime"
                  "user_xattr"
                ];
                extraArgs = [ "-L" "$disk_name" ];
              };
            };
          };
        };
      };
EOF
done

# Close disko.nix
cat >> "$MACHINE_DIR/disko.nix" << 'DISKO_FOOTER'
    };
  };
}
DISKO_FOOTER

echo -e "${GREEN}machines/$MACHINE/disko.nix saved${NC}"

# ═══════════════════════════════════════════════════════════════
# GENERATE HARDWARE.NIX
# ═══════════════════════════════════════════════════════════════

# Generate boot loader config based on mode
if [[ "$BOOT_MODE" == "uefi" ]]; then
    BOOT_LOADER_NIX='  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };'
else
    BOOT_LOADER_NIX='  boot.loader.grub.enable = true;'
fi

cat > "$MACHINE_DIR/hardware.nix" << EOF
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

$BOOT_LOADER_NIX

  boot.kernelPackages = pkgs.linuxPackages_6_6;
  boot.kernelModules = [ "$KVM_MODULE" ];
  boot.kernelParams = [ "vm.swappiness=10" ];
  boot.supportedFilesystems = [ "ext4" "vfat" ];

  hardware.cpu.${CPU_TYPE}.updateMicrocode = true;

  services.smartd = {
    enable = true;
    autodetect = true;
    notifications = {
      test = true;
      wall.enable = true;
    };
    defaults.monitored = "-a -o on -s (S/../.././02|L/../../7/04)";
  };
}
EOF

echo -e "${GREEN}machines/$MACHINE/hardware.nix saved${NC}"

# ═══════════════════════════════════════════════════════════════
# CONFIGURE AGENIX SECRETS
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Configuring Secrets (agenix) ===${NC}\n"

# Create per-machine secrets directory
mkdir -p "$SECRETS_DIR/$MACHINE"

# Update or create secrets.nix
# Check if secrets.nix exists and already has entries
if [[ -f "$SECRETS_DIR/secrets.nix" ]]; then
    # Check if this machine already has an entry
    if grep -q "^  $MACHINE = " "$SECRETS_DIR/secrets.nix"; then
        # Update existing key
        sed -i "s|$MACHINE = \"age1[a-z0-9]*\";|$MACHINE = \"$NAS_AGE_KEY\";|" "$SECRETS_DIR/secrets.nix"
        echo -e "${GREEN}Updated $MACHINE key in secrets.nix${NC}"
    else
        # Add new machine key before the admin line
        sed -i "/^  # Your public key/i\\  $MACHINE = \"$NAS_AGE_KEY\";\n" "$SECRETS_DIR/secrets.nix"

        # Add secret entry before the closing }
        sed -i "/^}$/i\\  \"$MACHINE/samba-password.age\".publicKeys = [ $MACHINE admin ];" "$SECRETS_DIR/secrets.nix"
        echo -e "${GREEN}Added $MACHINE to secrets.nix${NC}"
    fi
else
    cat > "$SECRETS_DIR/secrets.nix" << EOF
let
  # NAS public keys (age format, generated by setup.sh)
  $MACHINE = "$NAS_AGE_KEY";

  # Your public key for encrypting/decrypting
  admin = "$ADMIN_PUBLIC_KEY";
in
{
  "$MACHINE/samba-password.age".publicKeys = [ $MACHINE admin ];
}
EOF
    echo -e "${GREEN}secrets.nix created${NC}"
fi

# Encrypt Samba password (to both NAS and admin keys, matching secrets.nix)
AGE_RECIPIENTS=(-r "$NAS_AGE_KEY")

# Add admin key as recipient (supports both age and SSH key formats)
ADMIN_KEY_FILE=""
if [[ "$ADMIN_PUBLIC_KEY" == age1* ]]; then
    AGE_RECIPIENTS+=(-r "$ADMIN_PUBLIC_KEY")
elif [[ "$ADMIN_PUBLIC_KEY" == ssh-* ]]; then
    ADMIN_KEY_FILE=$(mktemp)
    echo "$ADMIN_PUBLIC_KEY" > "$ADMIN_KEY_FILE"
    AGE_RECIPIENTS+=(-R "$ADMIN_KEY_FILE")
fi

echo -n "$SAMBA_PASSWORD" | age "${AGE_RECIPIENTS[@]}" -o "$SECRETS_DIR/$MACHINE/samba-password.age"
[[ -n "$ADMIN_KEY_FILE" ]] && rm -f "$ADMIN_KEY_FILE"
if [[ -f "$SECRETS_DIR/$MACHINE/samba-password.age" ]]; then
    echo -e "${GREEN}samba-password.age encrypted successfully${NC}"
else
    echo -e "${RED}Error: Could not create samba-password.age${NC}"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════
# ADD MACHINE TO FLAKE.NIX
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Updating flake.nix ===${NC}\n"

FLAKE_FILE="$PROJECT_DIR/flake.nix"

if grep -q "machineNames" "$FLAKE_FILE"; then
    # Check if machine is already in the list
    if grep "machineNames" "$FLAKE_FILE" | grep -q "\"$MACHINE\""; then
        echo -e "${GREEN}$MACHINE already in flake.nix machineNames${NC}"
    else
        # Add machine to the list
        sed -i "s|machineNames = \[|machineNames = [ \"$MACHINE\"|" "$FLAKE_FILE"
        echo -e "${GREEN}Added $MACHINE to flake.nix machineNames${NC}"
    fi
fi

# ═══════════════════════════════════════════════════════════════
# STAGE FILES FOR NIX FLAKE
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Staging files for nix flake ===${NC}\n"

cd "$PROJECT_DIR"

# Nix flakes only see git-tracked files; stage the generated files
# (secrets/*.age and secrets/secrets.nix are gitignored, no need to stage)
git add "machines/$MACHINE/config.nix" "machines/$MACHINE/disko.nix" "machines/$MACHINE/hardware.nix" flake.nix
echo -e "${GREEN}Files staged in git${NC}"

# ═══════════════════════════════════════════════════════════════
# VERIFY CONFIGURATION
# ═══════════════════════════════════════════════════════════════
echo -e "\n${BLUE}=== Verifying Configuration ===${NC}\n"

if nix build ".#nixosConfigurations.$MACHINE.config.system.build.toplevel" --impure --no-link 2>/dev/null; then
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
echo -e "  ${GREEN}Machine:${NC}      $MACHINE"
echo -e "  ${GREEN}Hostname:${NC}     $HOSTNAME"
echo -e "  ${GREEN}IP:${NC}           $NAS_IP"
echo -e "  ${GREEN}User:${NC}         $ADMIN_USER"
echo -e "  ${GREEN}CPU:${NC}          $CPU_TYPE"
echo -e "  ${GREEN}System disk:${NC}  $SYSTEM_DISK"
echo -e "  ${GREEN}Data disks:${NC}   ${DATA_DISK_DEVICES[*]}"
echo ""
echo -e "  ${GREEN}Services:${NC}"
echo "    - Samba + NFS"
echo "    - MergerFS"
[[ "$SVC_COCKPIT" == "true" ]] && echo "    - Cockpit (https://$NAS_IP:9090)"
[[ "$SVC_FILEBROWSER" == "true" ]] && echo "    - File Browser (http://$NAS_IP:8080)"
[[ "$SVC_AUTHENTIK" == "true" ]] && echo "    - Authentik SSO integration"
echo ""
echo -e "  ${GREEN}Files generated:${NC}"
echo "    - machines/$MACHINE/config.nix"
echo "    - machines/$MACHINE/disko.nix"
echo "    - machines/$MACHINE/hardware.nix"
echo "    - secrets/$MACHINE/samba-password.age"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo ""
echo "  1. Prepare the physical NAS:"
echo "     - Boot with NixOS USB"
echo "     - Verify it has IP: $NAS_IP"
echo ""
echo "  2. Install NixOS on the NAS:"
echo -e "     ${CYAN}./scripts/install.sh $MACHINE${NC}"
echo ""
echo "  3. After installation, configure Samba manually:"
echo -e "     ${CYAN}ssh $ADMIN_USER@$NAS_IP 'sudo smbpasswd -a $ADMIN_USER'${NC}"
echo ""
