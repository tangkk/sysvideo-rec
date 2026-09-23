#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
pid_file="$repo_dir/.run/sysvideo-rec.pid"

if [ ! -f "$pid_file" ]; then
  echo "sysvideo-rec is not running from scripts/start.sh."
  exit 0
fi

pid="$(cat "$pid_file")"
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
  echo "sysvideo-rec stopped (PID $pid)."
else
  echo "Stale PID file removed."
fi
rm -f "$pid_file"
