#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -x .build/release/sysvideo-rec ]; then
  swift build -c release
fi
exec .build/release/sysvideo-rec
