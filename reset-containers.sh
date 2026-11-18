#!/usr/bin/env bash
set -e

ids=(100 101 102 103 104 105)
names=(ct-db ct-web ct-docker-web ct-jellyfin ct-surveillance ct-files)

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

for i in "${!ids[@]}"; do
  id=${ids[$i]}
  name=${names[$i]}

  if ! pct status "$id" >/dev/null 2>&1; then
    echo "CT $id ($name) not found, skipping"
    continue
  fi

  if pct status "$id" | grep -q running; then
    echo "Stopping CT $id ($name)..."
    pct stop "$id"
  fi

  echo "Destroying CT $id ($name)..."
  pct destroy "$id" --purge 1
done

echo "Done. Host data and configs were not touched."
