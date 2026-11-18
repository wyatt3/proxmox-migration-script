#!/usr/bin/env bash
# Usage:
#   sudo ./create-migration-pack.sh [DEST_DIR] [HOME_USER]
#
# Arguments:
#   DEST_DIR   Output directory for the migration pack (default: /nas/migration-pack)
#   HOME_USER  User whose home data (IP-Monitor, .ssh, git config) is archived (default: wyatt)
#
# Environment variables:
#   HOME_USER      Alternate way to set the home user (arg takes precedence)
#   MYSQL_AUTH     Extra auth args for mysql/mysqldump (e.g. '--defaults-file=/root/.my.cnf' or '-uroot -psecret')
#   FEELIN_DB_PATH Override path to feelin-it SQLite DB
#                  (default: /var/lib/docker/volumes/feelin-it_feelin-it-data/_data/feelin-it.db)
#
# Examples:
#   sudo ./create-migration-pack.sh
#   sudo ./create-migration-pack.sh /nas/migration-pack-new wyatt
#   sudo MYSQL_AUTH='--defaults-file=/root/.my.cnf' ./create-migration-pack.sh
#
# Notes:
#   - Run as root/sudo to read protected configs, keys, databases, and crontabs.
#   - For a consistent snapshot, quiesce write-heavy services first (MySQL, Jellyfin,
#     Stalwart, motionEye, and the feelin-it app/SQLite DB).
#   - Renewal configs are captured as-is; setup converts any webroot challenges to
#     the certbot nginx authenticator after the containers take over the web roots.
#
# Recreates this migration-pack backup from the current filesystem.

set -euo pipefail

DEST="${1:-/nas/migration-pack}"
HOME_USER="${2:-${HOME_USER:-wyatt}}"
HOME_DIR="$(getent passwd "$HOME_USER" | cut -d: -f6 2>/dev/null || echo "/home/$HOME_USER")"

# shellcheck disable=SC2206
MYSQL_AUTH_ARR=(${MYSQL_AUTH:-})

umask 077
mkdir -p "$DEST"

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

copy_file() {
  local src="$1" dst="$2"
  if [ -e "$src" ]; then
    cp -a "$src" "$dst"
  else
    warn "missing: $src"
  fi
}

tar_if_exists() {
  local out="$1" base="$2"; shift 2
  local -a paths=()
  local p
  for p in "$@"; do
    if [ -e "$base/$p" ] || [ -e "$p" ]; then
      paths+=("$p")
    fi
  done
  if [ ${#paths[@]} -eq 0 ]; then
    warn "nothing to archive for $out"
    return 0
  fi
  tar -czpf "$out" -C "$base" "${paths[@]}" || warn "failed to create $out"
}

log "System inventory"
if have dpkg; then dpkg -l > "$DEST/installed-packages.txt" || true; fi
if have systemctl; then
  systemctl list-unit-files --state=enabled --no-pager > "$DEST/enabled-services.txt" || true
  systemctl list-units --type=service --all --no-pager > "$DEST/running-services.txt" || true
fi
if have lsblk; then lsblk -f > "$DEST/disks.txt" || true; fi
copy_file /etc/fstab "$DEST/fstab.txt"
if have crontab; then crontab -l -u root > "$DEST/root.cron" 2>/dev/null || warn "could not read root crontab"; fi

log "Standalone config copies"
if [ -e /etc/samba/smb.conf ]; then
  copy_file /etc/samba/smb.conf "$DEST/smb.conf"
elif [ -e /etc/smb.conf ]; then
  copy_file /etc/smb.conf "$DEST/smb.conf"
else
  warn "smb.conf not found"
fi
copy_file /etc/systemd/resolved.conf "$DEST/resolved.conf"
if have resolvectl; then
  resolvectl status > "$DEST/resolved-status.txt" 2>/dev/null || true
elif have systemd-resolve; then
  systemd-resolve --status > "$DEST/resolved-status.txt" 2>/dev/null || true
fi

log "Tar archives (configs/data)"
tar_if_exists "$DEST/nginx.tar.gz"       / etc/nginx
tar_if_exists "$DEST/var-www.tar.gz"     / var/www
tar_if_exists "$DEST/letsencrypt.tar.gz" / etc/letsencrypt
tar_if_exists "$DEST/wireguard.tar.gz"   / etc/wireguard

# motionEye: configs, unit, and state
tar_if_exists "$DEST/motioneye.tar.gz" / \
  etc/motioneye etc/motion etc/systemd/system/motioneye.service var/lib/motioneye

# Stalwart: install dir and systemd unit
tar_if_exists "$DEST/stalwart.tar.gz" / opt/stalwart etc/systemd/system/stalwart.service

# IP-Monitor from user home (archived as IP-Monitor/...)
if [ -d "$HOME_DIR/IP-Monitor" ]; then
  tar -czpf "$DEST/ip-monitor.tar.gz" -C "$HOME_DIR" IP-Monitor || warn "failed to create ip-monitor.tar.gz"
else
  warn "missing: $HOME_DIR/IP-Monitor"
fi

# Home SSH/git material (archived as relative paths from home)
if [ -d "$HOME_DIR" ]; then
  (
    cd "$HOME_DIR"
    files=()
    for f in .ssh .gitconfig .git-credentials; do
      [ -e "$f" ] && files+=("$f")
    done
    if [ ${#files[@]} -gt 0 ]; then
      tar -czpf "$DEST/home-ssh-git.tar.gz" "${files[@]}"
    else
      warn "no home ssh/git files found in $HOME_DIR"
    fi
  ) || warn "failed to create home-ssh-git.tar.gz"
else
  warn "home directory not found: $HOME_DIR"
fi

log "MySQL/MariaDB exports"
if have mysqldump; then
  mysqldump "${MYSQL_AUTH_ARR[@]}" --all-databases --routines --triggers --events \
    > "$DEST/all-databases.sql" 2>/dev/null || warn "mysqldump failed (check credentials/permissions)"
else
  warn "mysqldump not found"
fi

if have mysql; then
  mysql "${MYSQL_AUTH_ARR[@]}" -NBe "SELECT user,host,plugin,authentication_string FROM mysql.user ORDER BY user,host" \
    > "$DEST/mysql-users.txt" 2>/dev/null || warn "mysql user listing failed"

  # Best-effort exports; formatting may differ from prior manual captures.
  mysql "${MYSQL_AUTH_ARR[@]}" -NBe "SELECT CONCAT('SHOW CREATE USER ''',user,'''\@''',host,''';') FROM mysql.user" \
    | mysql "${MYSQL_AUTH_ARR[@]}" -NBr 2>/dev/null \
    | sed 's/$/;/' > "$DEST/mysql-create-users.sql" || warn "mysql-create-users export failed"

  mysql "${MYSQL_AUTH_ARR[@]}" -NBe "SELECT CONCAT('SHOW GRANTS FOR ''',user,'''\@''',host,''';') FROM mysql.user" \
    | mysql "${MYSQL_AUTH_ARR[@]}" -NBr 2>/dev/null \
    | sed 's/$/;/' > "$DEST/mysql-grants.sql" || warn "mysql-grants export failed"
else
  warn "mysql client not found"
fi

log "feelin-it SQLite database"
FEELIN_SRC="${FEELIN_DB_PATH:-/var/lib/docker/volumes/feelin-it_feelin-it-data/_data/feelin-it.db}"
if [ -f "$FEELIN_SRC" ]; then
  if have sqlite3; then
    sqlite3 "$FEELIN_SRC" ".backup '$DEST/feelin-it.db'" 2>/dev/null || cp -a "$FEELIN_SRC" "$DEST/feelin-it.db"
  else
    cp -a "$FEELIN_SRC" "$DEST/feelin-it.db" || true
  fi
  [ -f "${FEELIN_SRC}-wal" ] && cp -a "${FEELIN_SRC}-wal" "$DEST/feelin-it.db-wal" || true
  [ -f "${FEELIN_SRC}-shm" ] && cp -a "${FEELIN_SRC}-shm" "$DEST/feelin-it.db-shm" || true
else
  warn "feelin-it db not found at $FEELIN_SRC (set FEELIN_DB_PATH to override)"
fi

# Adjust ownership of newly created top-level text/list files to match common pack style (best-effort)
  if id "$HOME_USER" >/dev/null 2>&1; then
    chown "$HOME_USER":www-data \
      "$DEST/installed-packages.txt" "$DEST/enabled-services.txt" "$DEST/running-services.txt" \
      "$DEST/disks.txt" "$DEST/fstab.txt" "$DEST/all-databases.sql" "$DEST/mysql-users.txt" \
      "$DEST/mysql-create-users.sql" "$DEST/mysql-grants.sql" 2>/dev/null || true
  fi

log "Done: $DEST"
ls -la "$DEST"
