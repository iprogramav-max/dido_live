#!/usr/bin/env bash
set -euo pipefail

FLUTTER_VERSION="3.47.2"
FLUTTER_ROOT="${FLUTTER_ROOT:-/tmp/flutter}"

if ! command -v flutter >/dev/null 2>&1; then
  archive="/tmp/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  curl --fail --location --silent --show-error \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    --output "$archive"
  mkdir -p "$(dirname "$FLUTTER_ROOT")"
  tar -xf "$archive" -C "$(dirname "$FLUTTER_ROOT")"
  rm -f "$archive"
  export PATH="$FLUTTER_ROOT/bin:$PATH"
fi

flutter config --no-analytics
flutter pub get
flutter build web --release
