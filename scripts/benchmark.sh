#!/usr/bin/env bash
# benchmark.sh - Performance benchmark for NAS

set -e

TESTFILE="/mnt/nas/media/benchmark-test-file"
TESTSIZE_MB=5120  # 5GB

echo "=================================="
echo "NAS Performance Benchmark"
echo "=================================="
echo ""
echo "Test file: $TESTFILE"
echo "Test size: ${TESTSIZE_MB}MB ($(($TESTSIZE_MB / 1024))GB)"
echo ""
echo "WARNING: This will create a ${TESTSIZE_MB}MB file"
echo "and may impact NAS performance during the test"
echo ""
read -p "Press Enter to continue or Ctrl+C to abort..."

# Check if test location exists
if [ ! -d "$(dirname $TESTFILE)" ]; then
    echo "Error: $(dirname $TESTFILE) does not exist"
    exit 1
fi

# Cleanup function
cleanup() {
    if [ -f "$TESTFILE" ]; then
        echo "Cleaning up test file..."
        rm -f "$TESTFILE"
    fi
}

trap cleanup EXIT

echo ""
echo "--- Sequential Write Test ---"
echo "Writing ${TESTSIZE_MB}MB..."
WRITE_SPEED=$(dd if=/dev/zero of="$TESTFILE" bs=1M count=$TESTSIZE_MB oflag=direct 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1)
echo "Write speed: $WRITE_SPEED"

# Clear cache
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || echo "Cannot clear cache (needs root)"

echo ""
echo "--- Sequential Read Test (cold cache) ---"
echo "Reading ${TESTSIZE_MB}MB..."
READ_SPEED_COLD=$(dd if="$TESTFILE" of=/dev/null bs=1M iflag=direct 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1)
echo "Read speed (cold): $READ_SPEED_COLD"

echo ""
echo "--- Sequential Read Test (warm cache) ---"
echo "Reading ${TESTSIZE_MB}MB again..."
READ_SPEED_WARM=$(dd if="$TESTFILE" of=/dev/null bs=1M iflag=direct 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1)
echo "Read speed (warm): $READ_SPEED_WARM"

# ZFS stats
echo ""
echo "--- ZFS Pool I/O Stats ---"
zpool iostat tank 1 5

# Network bandwidth (if iperf3 is available)
if command -v iperf3 >/dev/null 2>&1; then
    echo ""
    echo "--- Network Bandwidth Test ---"
    echo "Note: This requires an iperf3 server running on another machine"
    read -p "Enter iperf3 server IP (or press Enter to skip): " IPERF_SERVER

    if [ ! -z "$IPERF_SERVER" ]; then
        echo "Testing network bandwidth to $IPERF_SERVER..."
        iperf3 -c "$IPERF_SERVER" -t 10
    fi
fi

# Summary
echo ""
echo "=================================="
echo "Benchmark Results Summary"
echo "=================================="
echo "Sequential Write:      $WRITE_SPEED"
echo "Sequential Read (cold): $READ_SPEED_COLD"
echo "Sequential Read (warm): $READ_SPEED_WARM"
echo ""
echo "Expected performance on Gigabit Ethernet: ~110 MB/s"
echo "Expected performance on 10GbE: ~600-1000 MB/s"
echo ""
echo "ZFS Pool Status:"
zpool list tank

echo ""
echo "Benchmark completed!"
