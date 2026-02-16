#!/usr/bin/env bash
#
# Add Disk to NAS - Assistant for adding a new disk (runs remotely via SSH)
#

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
resolve_machine "${1:-}"
read_config
check_connectivity

# Banner
cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║              Add Disk to NAS                                  ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

EOF

echo -e "${YELLOW}This assistant will help you add a new disk to $MACHINE${NC}"
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
echo "  1. Update machines/$MACHINE/config.nix (add \"$disk_name\" to dataDisks)"
echo "  2. Update machines/$MACHINE/disko.nix (add the disk entry)"
echo "  3. Run: ./scripts/update.sh $MACHINE"
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

echo -e "${CYAN}1. Add \"$disk_name\" to dataDisks in machines/$MACHINE/config.nix:${NC}"
echo
echo "  dataDisks = [ ... \"$disk_name\" ];"
echo

echo -e "${CYAN}2. Add this to machines/$MACHINE/disko.nix:${NC}"
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
echo

separator
echo

# ============================================================================
# NEXT STEPS
# ============================================================================

header "NEXT STEPS"

echo "1. Edit the configuration:"
echo "   vim machines/$MACHINE/config.nix"
echo "   vim machines/$MACHINE/disko.nix"
echo

echo "2. Apply the changes:"
echo "   ./scripts/update.sh $MACHINE"
echo

echo "3. Verify that MergerFS detected it:"
echo "   ssh $SSH_TARGET 'df -h /mnt/storage'"
echo

separator
echo

echo -e "${GREEN}${BOLD}Disk added successfully at hardware level${NC}"
echo -e "${YELLOW}Remember to complete the configuration steps above${NC}"
echo
