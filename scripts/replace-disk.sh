#!/usr/bin/env bash
#
# Replace Disk - Migrate data from a failing disk, guide physical replacement,
# and optionally restore data. Runs from local machine via SSH.
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
║              Replace Disk - Data Migration                    ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

EOF

# ============================================================================
# SHOW CURRENT DISK STATUS
# ============================================================================

header "CURRENT DISK STATUS"

echo -e "${BOLD}MergerFS data disks:${NC}"
echo
nas "df -h /mnt/disk* 2>/dev/null" || echo "  No disks mounted"
echo

echo -e "${BOLD}SMART health:${NC}"
echo
nas '
for disk in /dev/sd[a-z]; do
    if [ -b "$disk" ]; then
        info=$(sudo smartctl -i "$disk" 2>/dev/null)
        model=$(echo "$info" | grep "Device Model" | cut -d: -f2 | xargs)
        [ -z "$model" ] && continue

        attrs=$(sudo smartctl -A "$disk" 2>/dev/null)
        reallocated=$(echo "$attrs" | grep "Reallocated_Sector" | awk "{print \$10}")
        hours=$(echo "$attrs" | grep "Power_On_Hours" | awk "{print \$10}" | grep -o "^[0-9]*")

        status="OK"
        if ! sudo smartctl -H "$disk" 2>/dev/null | grep -q "PASSED"; then
            status="FAILED"
        elif [ -n "$reallocated" ] && [ "$reallocated" -gt 0 ] 2>/dev/null; then
            status="WARNING (${reallocated} reallocated sectors)"
        fi

        mount_info=$(lsblk -n -o MOUNTPOINT "$disk"* 2>/dev/null | grep -v "^$" | head -1)
        [ -z "$mount_info" ] && mount_info="not mounted"

        printf "  %-10s %-25s %-15s %s\n" "$disk" "$model" "$mount_info" "$status"
    fi
done
'

echo
separator
echo

# ============================================================================
# SELECT SOURCE DISK (failing disk)
# ============================================================================

header "SELECT FAILING DISK"

echo -e "${YELLOW}Which disk do you want to replace?${NC}"
echo -e "Enter the mount name (e.g. disk1, disk2, disk3)"
echo
read -rp "$(echo -e "${CYAN}Disk to replace: ${NC}")" SOURCE_DISK

# Validate
if ! nas "test -d /mnt/$SOURCE_DISK"; then
    echo -e "${RED}Error: /mnt/$SOURCE_DISK does not exist on the NAS${NC}"
    exit 1
fi

if ! nas "mountpoint -q /mnt/$SOURCE_DISK"; then
    echo -e "${RED}Error: /mnt/$SOURCE_DISK is not mounted${NC}"
    exit 1
fi

# Show source disk usage
echo
echo -e "${BOLD}Data on /mnt/$SOURCE_DISK:${NC}"
nas "du -sh /mnt/$SOURCE_DISK/ 2>/dev/null" || echo "  Could not read"
echo

separator
echo

# ============================================================================
# SELECT DESTINATION DISK
# ============================================================================

header "SELECT DESTINATION DISK"

echo -e "${YELLOW}Where should the data be moved to?${NC}"
echo
echo -e "${BOLD}Available space on other disks:${NC}"
echo

nas '
for d in /mnt/disk*; do
    name=$(basename "$d")
    [ "$name" = "'"$SOURCE_DISK"'" ] && continue
    if mountpoint -q "$d" 2>/dev/null; then
        avail=$(df -h "$d" | tail -1 | awk "{print \$4}")
        used=$(df -h "$d" | tail -1 | awk "{print \$3}")
        printf "  %-10s Available: %s  (Used: %s)\n" "$name" "$avail" "$used"
    fi
done
'

echo
read -rp "$(echo -e "${CYAN}Move data to: ${NC}")" DEST_DISK

# Validate destination
if [[ "$DEST_DISK" == "$SOURCE_DISK" ]]; then
    echo -e "${RED}Source and destination cannot be the same${NC}"
    exit 1
fi

if ! nas "mountpoint -q /mnt/$DEST_DISK"; then
    echo -e "${RED}Error: /mnt/$DEST_DISK is not mounted${NC}"
    exit 1
fi

# Check available space
echo
echo -e "${YELLOW}Checking space...${NC}"

SOURCE_USED=$(nas "du -sb /mnt/$SOURCE_DISK/ 2>/dev/null | awk '{print \$1}'" || echo "0")
DEST_AVAIL=$(nas "df -B1 /mnt/$DEST_DISK | tail -1 | awk '{print \$4}'" || echo "0")

SOURCE_HUMAN=$(nas "du -sh /mnt/$SOURCE_DISK/ 2>/dev/null | awk '{print \$1}'" || echo "?")
DEST_HUMAN=$(nas "df -h /mnt/$DEST_DISK | tail -1 | awk '{print \$4}'" || echo "?")

echo -e "  Data to move:      ${BOLD}$SOURCE_HUMAN${NC}"
echo -e "  Space available:   ${BOLD}$DEST_HUMAN${NC}"

if [[ "$SOURCE_USED" -gt "$DEST_AVAIL" ]]; then
    echo
    echo -e "${RED}Not enough space on /mnt/$DEST_DISK${NC}"
    echo -e "${YELLOW}Free space or distribute data manually across multiple disks.${NC}"
    exit 1
fi

echo -e "  ${GREEN}Enough space${NC}"
echo

separator
echo

# ============================================================================
# MIGRATE DATA
# ============================================================================

header "DATA MIGRATION"

echo -e "${YELLOW}This will copy all data from /mnt/$SOURCE_DISK to /mnt/$DEST_DISK${NC}"
echo -e "${YELLOW}The original data will NOT be deleted yet.${NC}"
echo

if ! confirm "Start migration?"; then
    echo "Operation cancelled."
    exit 0
fi

echo
echo -e "${BLUE}Migrating data with rsync...${NC}"
echo -e "${BLUE}This may take a long time depending on the amount of data.${NC}"
echo

nas_sudo "rsync -avh --progress /mnt/$SOURCE_DISK/ /mnt/$DEST_DISK/" || {
    echo -e "${RED}rsync failed. Check the NAS for errors.${NC}"
    echo -e "${YELLOW}The source data has NOT been deleted.${NC}"
    exit 1
}

echo
echo -e "${GREEN}Migration complete${NC}"
echo

# Verify
header "VERIFICATION"

echo -e "${BOLD}Source (/mnt/$SOURCE_DISK):${NC}"
SOURCE_COUNT=$(nas "find /mnt/$SOURCE_DISK -type f 2>/dev/null | wc -l")
echo "  Files: $SOURCE_COUNT"
nas "du -sh /mnt/$SOURCE_DISK/ 2>/dev/null | awk '{print \"  Size:  \" \$1}'"

echo
echo -e "${BOLD}Destination (/mnt/$DEST_DISK):${NC}"
DEST_COUNT=$(nas "find /mnt/$DEST_DISK -type f 2>/dev/null | wc -l")
echo "  Files: $DEST_COUNT"
nas "du -sh /mnt/$DEST_DISK/ 2>/dev/null | awk '{print \"  Size:  \" \$1}'"

echo

if [[ "$SOURCE_COUNT" -le "$DEST_COUNT" ]]; then
    echo -e "${GREEN}File count OK${NC}"
else
    echo -e "${RED}File count mismatch: source=$SOURCE_COUNT, dest=$DEST_COUNT${NC}"
    echo -e "${YELLOW}Review before proceeding.${NC}"
fi

echo
separator
echo

# ============================================================================
# CLEAN SOURCE DISK
# ============================================================================

header "CLEAN SOURCE DISK"

echo -e "${YELLOW}Data has been copied to /mnt/$DEST_DISK${NC}"
echo

if confirm "Delete all data from /mnt/$SOURCE_DISK?"; then
    nas_sudo "rm -rf /mnt/$SOURCE_DISK/*"
    echo -e "${GREEN}Source disk cleaned${NC}"
else
    echo -e "${YELLOW}Skipped. Clean manually later:${NC}"
    echo "  ssh $SSH_TARGET 'sudo rm -rf /mnt/$SOURCE_DISK/*'"
fi

echo
separator
echo

# ============================================================================
# PHYSICAL REPLACEMENT GUIDE
# ============================================================================

header "PHYSICAL REPLACEMENT"

# Get by-id of the source disk
OLD_BY_ID=$(nas '
dev=$(df /mnt/'"$SOURCE_DISK"' 2>/dev/null | tail -1 | awk "{print \$1}" | sed "s/[0-9]*$//" | sed "s/p$//" )
if [ -n "$dev" ]; then
    ls -la /dev/disk/by-id/ 2>/dev/null | grep "$(basename "$dev")$" | awk "{print \$9}" | grep "^ata-" | head -1
fi
' || echo "unknown")

echo -e "${BOLD}Current disk identifier:${NC} /dev/disk/by-id/$OLD_BY_ID"
echo
echo -e "${BOLD}Steps:${NC}"
echo
echo "  1. Power off the NAS:"
echo "     ssh $SSH_TARGET 'sudo poweroff'"
echo
echo "  2. Physically swap the disk"
echo
echo "  3. Boot the NAS and find the new disk's ID:"
echo "     ssh $SSH_TARGET 'ls -la /dev/disk/by-id/ | grep -v part | grep ata-'"
echo
echo "  4. Update machines/$MACHINE/disko.nix:"
echo "     Replace the device path for $SOURCE_DISK with the new by-id"
echo
echo "  5. Format the new disk:"
echo "     ssh $SSH_TARGET 'sudo parted -s /dev/disk/by-id/NEW_ID mklabel gpt'"
echo "     ssh $SSH_TARGET 'sudo parted -s /dev/disk/by-id/NEW_ID mkpart primary ext4 0% 100%'"
echo "     ssh $SSH_TARGET 'sudo mkfs.ext4 -L $SOURCE_DISK /dev/disk/by-id/NEW_ID-part1'"
echo
echo "  6. Apply NixOS config:"
echo "     ./scripts/update.sh $MACHINE"
echo
echo "  7. (Optional) Move data back:"
echo "     ssh $SSH_TARGET 'sudo rsync -avh /mnt/$DEST_DISK/FOLDER/ /mnt/$SOURCE_DISK/FOLDER/'"
echo

separator
echo

echo -e "${GREEN}${BOLD}Data migration complete${NC}"
echo -e "${YELLOW}Follow the steps above to finish the physical replacement.${NC}"
echo
