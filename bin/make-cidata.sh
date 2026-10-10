#!/bin/bash
# Build the autoinstall (cidata) payload for the Omarchy ISO from config.env.
#
#   bin/make-cidata.sh [-c path/to/config.env] [-o build]
#
# Produces <out>/cidata/ (the files the ISO's cidata loader copies into /root)
# and <out>/cidata.img, a FAT image labeled CIDATA that bin/make-usb.sh writes
# onto the stick. stage2/ is copied into the image as well so the console
# fallback can run without network access.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG="$REPO/config.env"
OUT="$REPO/build"
while getopts "c:o:h" opt; do
  case $opt in
    c) CONFIG=$OPTARG ;;
    o) OUT=$OPTARG ;;
    *) sed -n 2,9p "$0"; exit 0 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing tool: $1 (install with: omarchy-pkg-add $2)"; }
need openssl openssl
need mkfs.vfat dosfstools
need mcopy mtools
need python3 python

[[ -f $CONFIG ]] || die "$CONFIG not found (copy config.example.env to config.env and edit it)"
# shellcheck disable=SC1090
source "$CONFIG"

for v in USERNAME PASSWORD FULL_NAME EMAIL HOSTNAME TIMEZONE KB_LAYOUT TARGET_DISK TARGET_DISK_BYTES SSH_PUBKEY; do
  [[ -n ${!v:-} ]] || die "$v is not set in $CONFIG"
done
[[ $USERNAME =~ ^[a-z_][a-z0-9_-]*$ ]] || die "USERNAME must be a valid lowercase unix name"
[[ $TARGET_DISK_BYTES =~ ^[0-9]+$ ]] || die "TARGET_DISK_BYTES must be an integer"
[[ $PASSWORD != 'change-me' ]] || die "set a real PASSWORD in $CONFIG"
SSH_PUBKEY=${SSH_PUBKEY/#\~/$HOME}
[[ -s $SSH_PUBKEY ]] || die "SSH_PUBKEY $SSH_PUBKEY is missing or empty"
grep -qE '^(ssh-(ed25519|rsa)|ecdsa-sha2|sk-) ' "$SSH_PUBKEY" || die "$SSH_PUBKEY does not look like an OpenSSH public key"

# Partition sizes exactly as the ISO's configurator computes them:
# 1 MiB gap, 2 GiB ESP, the rest btrfs minus a 1 MiB GPT backup reserve.
mib=$((1024 * 1024)); gib=$((1024 * mib))
disk_in_mib=$((TARGET_DISK_BYTES / mib * mib))
BOOT_START=$mib
BOOT_SIZE=$((2 * gib))
MAIN_START=$((BOOT_START + BOOT_SIZE))
MAIN_SIZE=$((disk_in_mib - MAIN_START - mib))
(( MAIN_SIZE >= 30 * gib )) || die "TARGET_DISK_BYTES too small: Omarchy needs at least 32 GiB"

dir="$OUT/cidata"
rm -rf "$dir"; mkdir -p "$dir"

export TARGET_DISK BOOT_START BOOT_SIZE MAIN_START MAIN_SIZE HOSTNAME TIMEZONE KB_LAYOUT
python3 -I - "$REPO/lib/user_configuration.json.tmpl" "$dir/user_configuration.json" <<'PY'
import json, os, sys
from string import Template
src, dst = sys.argv[1], sys.argv[2]
keys = ["TARGET_DISK","BOOT_START","BOOT_SIZE","MAIN_START","MAIN_SIZE","HOSTNAME","TIMEZONE","KB_LAYOUT"]
text = Template(open(src).read()).safe_substitute({k: os.environ[k] for k in keys})
data = json.loads(text)  # fails loudly if a value broke the JSON
with open(dst, "w") as f:
    json.dump(data, f, indent=4)
    f.write("\n")
PY

hash=$(openssl passwd -6 "$PASSWORD")
python3 -I - "$dir/user_credentials.json" "$USERNAME" "$hash" <<'PY'
import json, sys
dst, user, h = sys.argv[1:4]
json.dump({"root_enc_password": h,
           "users": [{"enc_password": h, "groups": [], "sudo": True, "username": user}]},
          open(dst, "w"), indent=4)
PY
chmod 600 "$dir/user_credentials.json"

printf '%s\n' "$FULL_NAME" > "$dir/user_full_name.txt"
printf '%s\n' "$EMAIL" > "$dir/user_email_address.txt"
echo false > "$dir/user_encrypt_installation.txt"
cp "$SSH_PUBKEY" "$dir/authorized_keys"
if [[ -n ${TAILSCALE_AUTHKEY:-} ]]; then
  printf '%s\n' "$TAILSCALE_AUTHKEY" > "$dir/tailscale_authkey"
  chmod 600 "$dir/tailscale_authkey"
fi

# FAT image: the ISO mounts anything labeled cidata/CIDATA read-only and copies
# the known files; the stage2 tree rides along for the offline console path.
img="$OUT/cidata.img"
rm -f "$img"
truncate -s 32M "$img"
mkfs.vfat -n CIDATA "$img" >/dev/null
mcopy -i "$img" "$dir"/* ::/
mmd -i "$img" ::/stage2
mcopy -i "$img" "$REPO/stage2"/* ::/stage2/
cp "$CONFIG" "$OUT/config.env.used"

echo "cidata payload: $dir"
echo "cidata image:   $img"
echo "target disk:    $TARGET_DISK ($TARGET_DISK_BYTES bytes): ESP ${BOOT_SIZE} B @ ${BOOT_START}, btrfs ${MAIN_SIZE} B @ ${MAIN_START}"
