#!/bin/bash
# Write a bootable Omarchy autoinstall stick: the official ISO plus an extra
# GPT partition labeled CIDATA carrying build/cidata.img.
#
#   bin/make-usb.sh /dev/sdX          # real USB stick (will be ERASED)
#   bin/make-usb.sh build/usb.img     # regular file, for testing in a VM
#
# Run bin/make-cidata.sh first. Downloads and verifies the ISO on first use.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$REPO/build"
CONFIG="${CONFIG:-$REPO/config.env}"
die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing tool: $1 (install with: omarchy-pkg-add $2)"; }
need sfdisk util-linux; need gpg gnupg; need sha256sum coreutils; need curl curl

TARGET=${1:-}
[[ -n $TARGET ]] || { sed -n 2,8p "$0"; exit 1; }
CIDATA_IMG=${BUILD_CIDATA:-$BUILD/cidata.img}
[[ -f $CIDATA_IMG ]] || die "$CIDATA_IMG missing: run bin/make-cidata.sh first"

# shellcheck disable=SC1090
[[ -f $CONFIG ]] && source "$CONFIG"
VER=${OMARCHY_VERSION:-4.0.4}
ISO="$BUILD/omarchy-$VER.iso"
URL="https://iso.omarchy.org/omarchy-$VER.iso"

echo "==> Omarchy ISO $VER"
for f in "$ISO.sha256" "$ISO.sig" "$ISO"; do
  [[ -s $f ]] || curl -fSL -C - -o "$f" "$URL${f#"$ISO"}"
done
( cd "$BUILD" && sha256sum -c --quiet "$(basename "$ISO").sha256" ) || die "ISO checksum mismatch; delete $ISO and retry"
# Modern gpg ignores --keyring (keyboxd), so verify inside a throwaway home.
gnupg_tmp=$(mktemp -d); trap 'rm -rf "$gnupg_tmp"' EXIT
GNUPGHOME=$gnupg_tmp gpg -q --import "$REPO/lib/omarchy.asc" 2>/dev/null
GNUPGHOME=$gnupg_tmp gpg --verify "$ISO.sig" "$ISO" 2>/dev/null \
  || die "ISO signature did not verify against lib/omarchy.asc"
echo "    checksum and signature OK"

iso_bytes=$(stat -c %s "$ISO")
cidata_bytes=$(stat -c %s "$CIDATA_IMG")

if [[ -b $TARGET ]]; then
  [[ $EUID -eq 0 ]] || die "writing to a block device needs root: sudo $0 $TARGET"
  dev=$(basename "$(readlink -f "$TARGET")")
  [[ -e /sys/block/$dev ]] || die "$TARGET is a partition or not a whole disk"
  [[ $(cat "/sys/block/$dev/removable") == 1 ]] || die "$TARGET is not a removable device; refusing"
  if [[ -n $(lsblk -nro MOUNTPOINTS "$TARGET" | tr -d '[:space:]') ]]; then
    die "$TARGET has mounted partitions; unmount them first"
  fi
  (( $(lsblk -bdno SIZE "$TARGET") > iso_bytes + cidata_bytes + 4 * 1024 * 1024 )) || die "$TARGET is too small"
  echo
  lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS "$TARGET"
  echo
  read -r -p "ALL DATA on $TARGET will be destroyed. Type the device path to continue: " confirm
  [[ $confirm == "$TARGET" ]] || die "aborted"
  echo "==> Writing ISO to $TARGET"
  dd if="$ISO" of="$TARGET" bs=4M status=progress conv=fsync
  disk=$TARGET
else
  echo "==> Building disk image $TARGET"
  rm -f "$TARGET"
  truncate -s $((iso_bytes + cidata_bytes + 8 * 1024 * 1024)) "$TARGET"
  dd if="$ISO" of="$TARGET" bs=4M conv=notrunc status=none
  disk=$TARGET
fi

echo "==> Appending CIDATA partition"
# The archiso image is an isohybrid: the kernel reads its MBR (two entries:
# the ISO9660 data and the EFI image); its GPT copy is not a valid table.
# Add a third MBR primary partition right after the last one.
last_end=$(sfdisk -l -o End "$disk" 2>/dev/null | awk '/^[0-9]+$/ && $1>m {m=$1} END{print m}')
[[ $last_end =~ ^[0-9]+$ ]] || die "could not read the ISO's partition table"
start_sector=$(( (last_end + 2048) / 2048 * 2048 ))
size_sectors=$(( (cidata_bytes + 511) / 512 ))
printf 'start=%s, size=%s, type=0c\n' "$start_sector" "$size_sectors" \
  | sfdisk --quiet --append --no-reread --no-tell-kernel --wipe never "$disk" >/dev/null \
  || die "sfdisk could not append the CIDATA partition"
partnum=$(sfdisk -l -o Device,Start "$disk" | awk -v s="$start_sector" '$2==s {print $1}' | sed -E 's/.*[^0-9]([0-9]+)$/\1/' | tail -1)
[[ -n $partnum ]] || die "could not find the CIDATA partition after creating it"

if [[ -b $disk ]]; then
  partprobe "$disk" 2>/dev/null || true
  udevadm settle
fi
dd if="$CIDATA_IMG" of="$disk" bs=512 seek="$start_sector" conv=notrunc,fsync status=none
sync

echo
echo "Done. $disk holds Omarchy $VER plus CIDATA (partition $partnum)."
if [[ -b $disk ]]; then
  lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$disk"
  echo
  echo "Boot the Mac mini with the stick inserted, hold Option, pick 'EFI Boot'."
  echo "The install runs unattended and reboots; then: bin/provision.sh <hostname-or-ip>"
fi
