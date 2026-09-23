#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
binary="$repo_dir/.build/release/sysvideo-rec"
pid_dir="$repo_dir/.run"
pid_file="$pid_dir/sysvideo-rec.pid"

if [ ! -x "$binary" ]; then
  (cd "$repo_dir" && swift build -c release)
fi

mkdir -p "$pid_dir"
if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
  echo "sysvideo-rec is already running (PID $(cat "$pid_file"))."
  exit 0
fi

rm -f "$pid_file"
"$binary" >/dev/null 2>&1 &
echo $! > "$pid_file"
echo "sysvideo-rec started (PID $(cat "$pid_file"))."
