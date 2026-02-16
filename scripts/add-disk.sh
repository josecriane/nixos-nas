#!/usr/bin/env bash
#
# Add Disk to NAS - Assistant for adding a new disk (runs remotely via SSH)
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config.nix"

separator() {
    echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
}

header() {
    echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"
}

confirm() {
    local prompt="$1"
    local response
    read -r -p "$(echo -e ${YELLOW}${prompt}${NC} [y/N]: )" response
    [[ "${response,,}" == "y" ]]
}

# ============================================================================
# CHECK LOCAL CONFIGURATION
# ============================================================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error: config.nix not found${NC}"
    echo "Run first: ./scripts/setup.sh"
    exit 1
fi

# Read connection details from config.nix
NAS_IP=$(grep 'nasIP' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
ADMIN_USER=$(grep 'adminUser' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
HOSTNAME=$(grep 'hostname' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')

SSH_OPTS="-o StrictHostKeyChecking=no"
SSH_TARGET="$ADMIN_USER@$NAS_IP"

# Helper to run commands on the NAS
nas() {
    ssh $SSH_OPTS "$SSH_TARGET" "$@"
}

nas_sudo() {
    ssh $SSH_OPTS "$SSH_TARGET" "sudo $*"
}

# ============================================================================
# CONNECTIVITY CHECK
# ============================================================================

echo -e "${YELLOW}Connecting to NAS ($HOSTNAME at $NAS_IP)...${NC}"

if ! ping -c 1 -W 3 "$NAS_IP" &>/dev/null; then
    echo -e "${RED}Cannot reach $NAS_IP${NC}"
    exit 1
fi

if ! ssh $SSH_OPTS -o ConnectTimeout=5 -o BatchMode=yes "$SSH_TARGET" "echo ok" &>/dev/null; then
    echo -e "${RED}Cannot connect via SSH to $SSH_TARGET${NC}"
    exit 1
fi

echo -e "${GREEN}Connected${NC}"
echo

# Banner
cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║              Add Disk to NAS                                  ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

EOF

echo -e "${YELLOW}This assistant will help you add a new disk to the NAS${NC}"
echo
separator
echo

# ============================================================================
# DISK DETECTION
# ============================================================================

header "CURRENT DISKS"

echo -e "${BOLD}Already configured disks:${NC}"
echo
nas "df -h /mnt/disk* 2>/dev/null | grep -v 'Filesystem'" || echo "  None"
echo

echo -e "${BOLD}Available disks in the system:${NC}"
echo

nas "lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -E 'disk|NAME'"

echo
separator
echo

# Request device
read -r -p "$(echo -e ${CYAN}Enter the device to add [e.g.: sdd]:${NC} )" device

# Validate input
if [[ ! "$device" =~ ^sd[a-z]$ ]] && [[ ! "$device" =~ ^nvme[0-9]n[0-9]$ ]]; then
    echo -e "${RED}Invalid device${NC}"
    exit 1
fi

# Add /dev/ if not present
if [[ ! "$device" =~ ^/dev/ ]]; then
    device="/dev/$device"
fi

# Check that it exists on the NAS
if ! nas "test -b $device"; then
    echo -e "${RED}Device $device does not exist on the NAS${NC}"
    exit 1
fi

# Check that it's not mounted
if nas "mount | grep -q '^$device'"; then
    echo -e "${RED}Device $device is already mounted${NC}"
    nas "mount | grep '^$device'"
    exit 1
fi

# ============================================================================
# DISK INFORMATION
# ============================================================================

header "DISK INFORMATION"

# Model and capacity (fetched from NAS)
model=$(nas "lsblk -d -n -o MODEL '$device' 2>/dev/null" || echo "Unknown")
size=$(nas "lsblk -d -n -o SIZE '$device' 2>/dev/null" || echo "Unknown")

echo -e "${BOLD}Device:${NC} $device"
echo -e "${BOLD}Model:${NC}  $model"
echo -e "${BOLD}Size:${NC}   $size"
echo

# Check if it has data
if nas "lsblk -n '$device' 2>/dev/null | grep -q part"; then
    echo -e "${RED}${BOLD}WARNING: The disk has existing partitions${NC}"
    echo
    nas "lsblk '$device'"
    echo
    echo -e "${RED}All partitions and data will be DESTROYED${NC}"
    echo
else
    echo -e "${GREEN}The disk appears to be empty${NC}"
    echo
fi

separator
echo

# ============================================================================
# DETERMINE DISK NUMBER
# ============================================================================

# Find next available number on the NAS
next_num=$(nas "n=1; while [ -d /mnt/disk\$n ]; do n=\$((n+1)); done; echo \$n")

disk_name="disk$next_num"
mount_point="/mnt/$disk_name"

echo -e "${BOLD}Disk name:${NC}    $disk_name"
echo -e "${BOLD}Mount point:${NC} $mount_point"
echo -e "${BOLD}Disk label:${NC}  $disk_name"
echo

separator
echo

# ============================================================================
# CONFIRMATION
# ============================================================================

echo -e "${RED}${BOLD}FINAL WARNING${NC}"
echo
echo -e "${RED}This operation will DESTROY all data on:${NC}"
echo -e "${RED}  $device (on NAS $NAS_IP)${NC}"
echo
echo "The following actions will be performed:"
echo "  1. Partition the disk (GPT)"
echo "  2. Format with ext4"
echo "  3. Assign label: $disk_name"
echo "  4. Create mount point: $mount_point"
echo
echo -e "${YELLOW}After this you will need to:${NC}"
echo "  1. Update modules/storage-mergerfs.nix"
echo "  2. Update modules/snapraid.nix"
echo "  3. Run: ./scripts/update.sh"
echo "  4. Run on NAS: sudo snapraid sync"
echo

if ! confirm "Continue with partitioning and formatting?"; then
    echo "Operation cancelled"
    exit 0
fi

echo
read -r -p "$(echo -e ${YELLOW}Type exactly: FORMAT${NC} )" final_confirm

if [[ "$final_confirm" != "FORMAT" ]]; then
    echo "Incorrect confirmation. Operation cancelled."
    exit 0
fi

echo

# ============================================================================
# PARTITIONING AND FORMATTING (remote)
# ============================================================================

header "PARTITIONING AND FORMATTING"

echo "1. Creating GPT partition table..."
nas_sudo "parted -s '$device' mklabel gpt"

echo "2. Creating primary partition..."
nas_sudo "parted -s '$device' mkpart primary ext4 0% 100%"

# Determine partition name
if [[ "$device" =~ nvme ]]; then
    partition="${device}p1"
else
    partition="${device}1"
fi

# Wait for kernel to detect partition
echo "   Waiting for kernel..."
nas_sudo "sleep 2 && partprobe '$device' && sleep 1"

echo "3. Formatting with ext4..."
nas_sudo "mkfs.ext4 -F -L '$disk_name' '$partition'"

echo "4. Creating mount point..."
nas_sudo "mkdir -p '$mount_point'"

echo "5. Mounting disk temporarily..."
nas_sudo "mount '$partition' '$mount_point'"

echo "6. Setting permissions..."
nas_sudo "chown $ADMIN_USER:$ADMIN_USER '$mount_point'"
nas_sudo "chmod 755 '$mount_point'"

echo

echo -e "${GREEN}Disk formatted and mounted successfully${NC}"
echo

# Show result
nas "df -h '$mount_point'"

echo
separator
echo

# ============================================================================
# UPDATE CONFIGURATION
# ============================================================================

header "UPDATE CONFIGURATION"

echo -e "${BOLD}Now you need to update the NixOS configuration:${NC}"
echo

# Generate snippet for storage-mergerfs.nix
echo -e "${CYAN}1. Add this to modules/storage-mergerfs.nix:${NC}"
echo
cat << EOF
  # Disk $next_num - $size $model
  fileSystems."/mnt/$disk_name" = {
    device = "/dev/disk/by-label/$disk_name";
    fsType = "ext4";
    options = [
      "defaults"
      "noatime"
      "nodiratime"
      "user_xattr"
      "barrier=1"
    ];
  };
EOF
echo

echo -e "${CYAN}   And add to systemd.mounts dependencies:${NC}"
echo "     - \"mnt-${disk_name}.mount\" in after and requires"
echo

separator
echo

# Generate snippet for snapraid.nix
echo -e "${CYAN}2. Add this to /etc/snapraid.conf:${NC}"
echo
echo "  data $disk_name /mnt/$disk_name"
echo "  content /mnt/$disk_name/snapraid.content"
echo

separator
echo

# Generate snippet for disko.nix
echo -e "${CYAN}3. (Optional) Add this to modules/disko.nix for future installations:${NC}"
echo
cat << EOF
      data$next_num = {
        type = "disk";
        device = "$device";
        content = {
          type = "gpt";
          partitions = {
            $disk_name = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/mnt/$disk_name";
                label = "$disk_name";
                mountOptions = [
                  "defaults"
                  "noatime"
                  "nodiratime"
                  "user_xattr"
                  "barrier=1"
                ];
              };
            };
          };
        };
      };
EOF
echo

separator
echo

# ============================================================================
# NEXT STEPS
# ============================================================================

header "NEXT STEPS"

echo "1. Edit the local configuration:"
echo "   vim modules/storage-mergerfs.nix"
echo "   vim modules/snapraid.nix"
echo

echo "2. Apply the changes:"
echo "   ./scripts/update.sh"
echo

echo "3. Verify that MergerFS detected it:"
echo "   ssh $SSH_TARGET 'df -h /mnt/storage'"
echo

echo "4. Sync SnapRAID:"
echo "   ssh $SSH_TARGET 'sudo snapraid sync'"
echo

echo "5. Verify the status:"
echo "   ssh $SSH_TARGET 'sudo snapraid status'"
echo

separator
echo

echo -e "${GREEN}${BOLD}Disk added successfully at hardware level${NC}"
echo -e "${YELLOW}Remember to complete the configuration steps above${NC}"
echo
