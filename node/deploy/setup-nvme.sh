#!/bin/bash
# Usage: setup-nvme.sh [mount_path] [--force] [--fs=xfs|ext4]
# Discovers the VM's local (ephemeral) NVMe "direct" disks, combines multiple
# disks into a single RAID0 array, formats and mounts them for fast scratch
# storage (e.g. Valkey AOF/RDB or Garnet storage tiering / checkpoints).
#
# Examples:
#   setup-nvme.sh                 - discover + mount local NVMe at /mnt/nvme (default)
#   setup-nvme.sh /mnt/nvme       - same, explicit mount path
#   setup-nvme.sh --force         - rebuild even if already mounted (DESTROYS data)
#   setup-nvme.sh --fs=ext4       - format ext4 instead of xfs
#
# IMPORTANT: Local NVMe disks (e.g. on Dldsv6/Ev6-series) are EPHEMERAL. Their
# contents survive a reboot but are LOST when the VM is deallocated (stopped).
# Never store anything durable here - it is scratch/benchmark storage only.
set -e
source /opt/deploy-actions/config.env

MOUNT_PATH="$NVME_DIR"
FORCE=false
FSTYPE="xfs"
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --fs=*)  FSTYPE="${arg#*=}" ;;
    /*)      MOUNT_PATH="$arg" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done
MOUNT_PATH="${MOUNT_PATH:-/mnt/nvme}"

echo "==== Setting up local NVMe storage ===="
echo "  Mount path : $MOUNT_PATH"
echo "  Filesystem : $FSTYPE"

# Already mounted?
if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
  if ! $FORCE; then
    echo "  $MOUNT_PATH is already mounted; nothing to do (use --force to rebuild)."
    df -h "$MOUNT_PATH"
    exit 0
  fi
  echo "  --force specified: unmounting existing $MOUNT_PATH"
  umount "$MOUNT_PATH"
fi

# Discover local ephemeral NVMe disks by model string. Azure exposes them as
# whole disks with the model "Microsoft NVMe Direct Disk ...". The OS disk and
# remote (Premium/Ultra) data disks report different models, so they are excluded.
mapfile -t DISKS < <(lsblk -dno NAME,MODEL | awk '/Microsoft NVMe Direct Disk/ {print "/dev/"$1}')

if [ ${#DISKS[@]} -eq 0 ]; then
  echo "  ERROR: No local NVMe (Microsoft NVMe Direct Disk) devices found." >&2
  echo "  This VM size may not have local NVMe storage. Current block devices:" >&2
  lsblk -o NAME,SIZE,MODEL,MOUNTPOINT >&2
  exit 1
fi

echo "  Found ${#DISKS[@]} local NVMe disk(s): ${DISKS[*]}"

# Safety: refuse any candidate disk that is currently mounted or partitioned.
for d in "${DISKS[@]}"; do
  if [ -n "$(lsblk -no MOUNTPOINT "$d" | tr -d '[:space:]')" ]; then
    echo "  ERROR: $d appears to be in use (has a mountpoint). Aborting for safety." >&2
    exit 1
  fi
done

mkdir -p "$MOUNT_PATH"

if [ ${#DISKS[@]} -eq 1 ]; then
  TARGET="${DISKS[0]}"
  echo "  Single disk -> formatting $TARGET as $FSTYPE"
else
  TARGET="/dev/md/nvme0"
  echo "  ${#DISKS[@]} disks -> creating RAID0 array at $TARGET"
  # Tear down any stale array from a previous run before recreating.
  mdadm --stop "$TARGET" 2>/dev/null || true
  yes | mdadm --create "$TARGET" --level=0 --raid-devices=${#DISKS[@]} "${DISKS[@]}" --force
fi

# Format
if [ "$FSTYPE" = "ext4" ]; then
  mkfs.ext4 -F -m 0 "$TARGET"
else
  mkfs.xfs -f "$TARGET"
fi

mount "$TARGET" "$MOUNT_PATH"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$MOUNT_PATH"

echo "==== Local NVMe ready at $MOUNT_PATH ===="
df -h "$MOUNT_PATH"
# NOTE: Not persisted to /etc/fstab on purpose - the array/format does not
# survive deallocation, so re-run this script after each VM (re)start.
