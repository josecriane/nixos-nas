#!/usr/bin/env bash
#
# Add Disk to NAS - Assistant for adding a new disk
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

# Check that we are root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}This script must be run as root${NC}"
    echo "Use: sudo $0"
    exit 1
fi

# Banner
clear
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
df -h /mnt/disk* 2>/dev/null | grep -v "Filesystem" || echo "  None"
echo

echo -e "${BOLD}Available disks in the system:${NC}"
echo

lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -E "disk|NAME"

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

# Check that it exists
if [ ! -b "$device" ]; then
    echo -e "${RED}Device $device does not exist${NC}"
    exit 1
fi

# Check that it's not mounted
if mount | grep -q "^$device"; then
    echo -e "${RED}Device $device is already mounted${NC}"
    mount | grep "^$device"
    exit 1
fi

# ============================================================================
# DISK INFORMATION
# ============================================================================

header "DISK INFORMATION"

# Model and capacity
model=$(lsblk -d -n -o MODEL "$device" 2>/dev/null || echo "Unknown")
size=$(lsblk -d -n -o SIZE "$device" 2>/dev/null || echo "Unknown")

echo -e "${BOLD}Device:${NC} $device"
echo -e "${BOLD}Model:${NC}  $model"
echo -e "${BOLD}Size:${NC}   $size"
echo

# Check if it has data
if lsblk -n "$device" 2>/dev/null | grep -q "part"; then
    echo -e "${RED}${BOLD}WARNING: The disk has existing partitions${NC}"
    echo
    lsblk "$device"
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

# Find next available number
next_num=1
while [ -d "/mnt/disk$next_num" ]; do
    ((next_num++))
done

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
echo -e "${RED}  $device${NC}"
echo
echo "The following actions will be performed:"
echo "  1. Partition the disk (GPT)"
echo "  2. Format with ext4"
echo "  3. Assign label: $disk_name"
echo "  4. Create mount point: $mount_point"
echo
echo -e "${YELLOW}After this you will need to:${NC}"
echo "  1. Update /etc/nixos/modules/storage-mergerfs.nix"
echo "  2. Update /etc/nixos/modules/snapraid.nix"
echo "  3. Run: sudo nixos-rebuild switch"
echo "  4. Run: sudo snapraid sync"
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
# PARTITIONING AND FORMATTING
# ============================================================================

header "PARTITIONING AND FORMATTING"

echo "1. Creating GPT partition table..."
parted -s "$device" mklabel gpt

echo "2. Creating primary partition..."
parted -s "$device" mkpart primary ext4 0% 100%

# Determine partition name
if [[ "$device" =~ nvme ]]; then
    partition="${device}p1"
else
    partition="${device}1"
fi

# Wait for kernel to detect partition
sleep 2
partprobe "$device"
sleep 1

echo "3. Formatting with ext4..."
mkfs.ext4 -F -L "$disk_name" "$partition"

echo "4. Creating mount point..."
mkdir -p "$mount_point"

echo "5. Mounting disk temporarily..."
mount "$partition" "$mount_point"

echo "6. Setting permissions..."
chown nas:nas "$mount_point"
chmod 755 "$mount_point"

echo

echo -e "${GREEN}Disk formatted and mounted successfully${NC}"
echo

# Show result
df -h "$mount_point"

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

echo "1. Edit the configuration:"
echo "   sudo vim /etc/nixos/modules/storage-mergerfs.nix"
echo "   sudo vim /etc/snapraid.conf"
echo

echo "2. Apply the changes:"
echo "   sudo nixos-rebuild switch"
echo

echo "3. Verify that MergerFS detected it:"
echo "   df -h /mnt/storage"
echo

echo "4. Sync SnapRAID:"
echo "   sudo snapraid sync"
echo

echo "5. Verify the status:"
echo "   sudo snapraid status"
echo

separator
echo

echo -e "${GREEN}${BOLD}Disk added successfully at hardware level${NC}"
echo -e "${YELLOW}Remember to complete the configuration steps above${NC}"
echo
