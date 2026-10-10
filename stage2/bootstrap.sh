#!/bin/bash
# One-liner entry point for stage 2, run on the freshly installed Omarchy box:
#
#   curl -fsSL https://raw.githubusercontent.com/GH_USER/omarchy-haos/main/stage2/bootstrap.sh | bash
#
# Offline, from the install stick (it stays readable after the install):
#
#   bash /run/media/$USER/CIDATA/stage2/bootstrap.sh --local
#
set -euo pipefail
REPO_URL="https://github.com/GH_USER/omarchy-haos.git"
DEST="$HOME/omarchy-haos"

if [[ ${1:-} == --local ]]; then
  src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  mkdir -p "$DEST/stage2"
  cp -r "$src"/. "$DEST/stage2/"
elif [[ -d $DEST/.git ]]; then
  git -C "$DEST" pull --ff-only
else
  git clone --depth 1 "$REPO_URL" "$DEST"
fi

exec sudo env STAGE2_USER="$USER" bash "$DEST/stage2/setup.sh"
