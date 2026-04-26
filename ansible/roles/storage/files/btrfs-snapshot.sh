#!/usr/bin/env bash
# Daily read-only btrfs snapshot of /mnt/elements.
#
# Snapshots land under $MOUNT/.snapshots/<ISO-8601>. .snapshots is itself
# created as a btrfs subvolume (not a regular dir) so child subvolumes are
# excluded from each new snapshot — without that, every snapshot would
# nest the previous ones and storage would balloon on day 2.
#
# Read-only flag (-r) makes the snapshot immutable; deletion requires
# `btrfs subvolume delete` (the prune step below). A stray `rm -rf` on
# a read-only snap fails with EROFS — accident protection.
#
# CoW means same-content blocks are shared with /mnt/elements; a fresh
# snapshot of an unchanged FS costs only metadata. The cost grows with
# churn, not with snapshot count.
#
# Idempotent. Safe to re-run on the same minute (target name includes
# seconds so collisions are practically impossible, but the script
# handles them anyway via `set -e`).
set -euo pipefail

MOUNT="${MOUNT:-/mnt/elements}"
SNAP_DIR="${MOUNT}/.snapshots"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

# Sanity gate: refuse to run on a non-btrfs mount or a path that isn't
# actually mounted (e.g. disk pulled, fstab nofail kicked in).
if ! mountpoint -q "$MOUNT"; then
  echo "btrfs-snapshot: $MOUNT is not mounted, skipping" >&2
  exit 0
fi
if [ "$(stat -f -c '%T' "$MOUNT")" != "btrfs" ]; then
  echo "btrfs-snapshot: $MOUNT is not btrfs" >&2
  exit 1
fi

# Ensure .snapshots is a SUBVOLUME, not a directory. Subvolume status is
# what keeps snapshots from recursively including each other on the next
# `btrfs subvolume snapshot` of the parent.
if ! btrfs subvolume show "$SNAP_DIR" >/dev/null 2>&1; then
  if [ -e "$SNAP_DIR" ] && [ ! -d "$SNAP_DIR" ]; then
    echo "btrfs-snapshot: $SNAP_DIR exists and is not a directory" >&2
    exit 1
  fi
  if [ -d "$SNAP_DIR" ]; then
    # Existing dir was created by hand — refuse to clobber. Operator must
    # rmdir manually before this script can convert it to a subvolume.
    if [ -n "$(ls -A "$SNAP_DIR" 2>/dev/null)" ]; then
      echo "btrfs-snapshot: $SNAP_DIR is a non-empty directory; remove or convert manually" >&2
      exit 1
    fi
    rmdir "$SNAP_DIR"
  fi
  btrfs subvolume create "$SNAP_DIR"
fi

stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
target="$SNAP_DIR/$stamp"
btrfs subvolume snapshot -r "$MOUNT" "$target" >/dev/null
echo "btrfs-snapshot: created $target"

# Prune older than RETENTION_DAYS. ISO-8601 timestamps with leading zeros
# sort lexicographically; we use the same format for the cutoff string.
cutoff=$(date -u -d "$RETENTION_DAYS days ago" +%Y-%m-%dT%H-%M-%SZ)
for snap in "$SNAP_DIR"/*; do
  [ -d "$snap" ] || continue
  name=$(basename "$snap")
  # Skip anything that doesn't match the timestamp pattern — defensive
  # against operator-created subvolumes living alongside automated ones.
  [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z$ ]] || continue
  if [[ "$name" < "$cutoff" ]]; then
    btrfs subvolume delete "$snap" >/dev/null
    echo "btrfs-snapshot: pruned $snap"
  fi
done
