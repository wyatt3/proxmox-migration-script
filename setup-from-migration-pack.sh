#!/usr/bin/env bash
#
# setup-from-migration-pack.sh
#
# Restore Wyatt's home server into Proxmox VE using the pack produced by
# create-migration-pack.sh. Built for the runbook in proxmox-migration-plan.md.
#
# Safe by default: every mutating command is printed instead of run unless
# --apply is supplied. Phases can be run independently and are idempotent.
#
# Usage:
#   sudo ./setup-from-migration-pack.sh [--apply] <phase> [options]
#
# Phases:
#   preflight       Validate host, pack, mounts, template, and free IPs
#   fix-repos       Switch to no-subscription apt repos when no key is present
#   host            Restore host edge services (nginx/certs/wg/stalwart/home/cron/ufw)
#   create          Create the six privileged LXC containers + bind mounts
#   restore <ct>    Stage data/config for one CT (or "all") and write guides
#   configure <ct>  Install and configure one CT (or "all") after restore
#   nginx-rewrite   Repoint host nginx vhosts at the container upstreams
#   verify          Check container/service/bind state and live endpoints
#   all             preflight -> host -> create -> restore all -> configure all
#                   -> nginx-rewrite -> verify
#
# Options:
#   --apply             Actually make changes (default: dry-run)
#   --dry-run           Force dry-run (default behaviour)
#   --yes, -y           Do not prompt for confirmation
#   --pack DIR          Migration pack directory (default: /nas/migration-pack)
#   --storage NAME      Proxmox storage for CT root disks (default: local-lvm)
#   --template VOLID    Ubuntu 24.04 template (default: auto-detect)
#   --bridge NAME       Network bridge (default: vmbr0)
#   --only NAME         Limit create/restore/configure to one container
#   --log FILE          Log file (default: /var/log/migration-restore-<ts>.log)
#   --secrets FILE      Secrets file for Samba and MySQL passwords (default: /root/migration-secrets.env)
#   --verify-live       With "verify", also curl the public vhosts
#   --require-mounts    Fail if a bind source is missing or not on a data disk
#   --apt-repos MODE    auto (default), keep, or no-subscription
#   --help, -h          Show this help
#
# Mounts:
#   By default missing bind sources (/nas, /media/jellyfin, /nas/Wyatt/vids)
#   are created as empty placeholder directories so staging runs and runs
#   without the data disks connected still work. Use --require-mounts on the
#   real host to require the 1T/2T disks to be mounted before creating CTs.
#
# Environment:
#   CT_ROOT_PASSWORD    Password for new containers (else /root/.ssh/authorized_keys)
#   SMB_WYATT_PASSWORD  Samba password for wyatt (or use --secrets / prompt)
#   DB_PUBLIC_USER_PASSWORD MySQL password for public_user (or use --secrets / prompt)
#   DB_ROUNDCUBE_PASSWORD MySQL password for roundcube (or use --secrets / prompt)
#   GATEWAY             LAN gateway (default: 192.168.0.1)
#   WORKDIR             Where guides are written (default: /root/migration-guides)
#   PVE_LXC_DIR         LXC config dir (default: /etc/pve/lxc)
#
# Containers (all privileged, Ubuntu 24.04):
#   100 ct-db          .70  1.5G 2c  4G
#   101 ct-web         .71  1.5G 2c  8G
#   102 ct-docker-web  .72  2G   2c 10G  nesting=1,keyctl=1
#   103 ct-jellyfin    .73  2G   4c 10G  bind /media/jellyfin
#   104 ct-surveillance .74 1G   3c  4G  bind /nas/Wyatt/vids
#   105 ct-files       .75  0.25G 1c 1G  bind /nas
#
set -Eeuo pipefail

SCRIPT_VERSION="1.1.0"
PACK="${PACK:-/nas/migration-pack}"
APPLY="${APPLY:-0}"
ASSUME_YES=0
VERIFY_LIVE=0
REQUIRE_MOUNTS=0
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE="${TEMPLATE:-}"
BRIDGE="${BRIDGE:-vmbr0}"
GATEWAY="${GATEWAY:-192.168.0.1}"
ONLY=""
LOG="${LOG:-}"
SECRETS_FILE="${SECRETS_FILE:-/root/migration-secrets.env}"
WORKDIR="${WORKDIR:-/root/migration-guides}"
PVE_LXC_DIR="${PVE_LXC_DIR:-/etc/pve/lxc}"
APT_REPOS="${APT_REPOS:-auto}"
APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
APT_AUTH_DIR="${APT_AUTH_DIR:-/etc/apt/auth.conf.d}"
PROXMOX_KEYRING="${PROXMOX_KEYRING:-/usr/share/keyrings/proxmox-archive-keyring.gpg}"
CMD=""

if [ -t 1 ]; then
  C_RST=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RST=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BOLD=""
fi

log()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RST"; }

trap 'rc=$?; printf "%s[x]%s failed at line %s (exit %s): %s\n" "$C_RED" "$C_RST" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR

usage() {
  awk 'NR > 1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else { exit } }' "$0"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 ...)"
}

init_log() {
  [ -n "$LOG" ] || LOG="/var/log/migration-restore-$(date +%Y%m%d-%H%M%S).log"
  mkdir -p "$(dirname "$LOG")"
  touch "$LOG"
  exec > >(tee -a "$LOG") 2>&1
  log "Logging to $LOG"
}

require_pve() {
  local c
  for c in pveversion pct pvesm pveam; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' not found — is this a Proxmox VE host?"
  done
}

run() {
  if [ "$APPLY" -eq 1 ]; then
    printf '    %s+ %s%s\n' "$C_GRN" "$*" "$C_RST"
    "$@"
  else
    printf '    %s[dry-run]%s %s\n' "$C_YEL" "$C_RST" "$*"
  fi
}

run_sh() {
  if [ "$APPLY" -eq 1 ]; then
    printf '    %s+ %s%s\n' "$C_GRN" "$*" "$C_RST"
    bash -c "$*"
  else
    printf '    %s[dry-run]%s %s\n' "$C_YEL" "$C_RST" "$*"
  fi
}

confirm() {
  [ "$APPLY" -eq 0 ] && return 0
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local ans
  read -r -p "$1 [y/N] " ans
  case "$ans" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) die "aborted by user" ;;
  esac
}

# ---------------------------------------------------------------------------
# Container metadata
# ---------------------------------------------------------------------------
ct_ids=(     100    101    102             103         104             105    )
ct_names=(   ct-db  ct-web ct-docker-web   ct-jellyfin ct-surveillance ct-files )
ct_ips=(     192.168.0.70 192.168.0.71 192.168.0.72 192.168.0.73 192.168.0.74 192.168.0.75 )
ct_ram=(     1536   1536   2048    2048   1024   256   )
ct_cores=(   2      2      2       4      3      1     )
ct_disk=(    4      8      10      10      4      3     )
ct_features=(""     ""     "nesting=1,keyctl=1" "" "" "")

ct_index() {
  local name=$1 i
  for i in "${!ct_names[@]}"; do
    if [ "${ct_names[$i]}" = "$name" ]; then echo "$i"; return 0; fi
  done
  return 1
}

ct_field() {
  local name=$1 field=$2 idx
  idx=$(ct_index "$name") || return 1
  case "$field" in
    id)       echo "${ct_ids[$idx]}" ;;
    ip)       echo "${ct_ips[$idx]}" ;;
    ram)      echo "${ct_ram[$idx]}" ;;
    cores)    echo "${ct_cores[$idx]}" ;;
    disk)     echo "${ct_disk[$idx]}" ;;
    features) echo "${ct_features[$idx]}" ;;
    *) return 1 ;;
  esac
}

# Emit "host:container" bind entries separated by commas, or empty.
ct_binds() {
  case "$1" in
    ct-jellyfin)     echo "/media/jellyfin:/media/jellyfin" ;;
    ct-surveillance) echo "/nas/Wyatt/vids:/nas/Wyatt/vids" ;;
    ct-files)        echo "/nas:/nas" ;;
    *)               echo "" ;;
  esac
}

# Nearest mountpoint for a path (e.g. /nas for /nas/Wyatt/vids), or empty.
bind_mount_root() {
  findmnt -rn -o TARGET -T "$1" 2>/dev/null || true
}

# True when the path exists and is backed by a filesystem other than /.
bind_on_data_disk() {
  local src=$1 root
  [ -d "$src" ] || return 1
  root=$(bind_mount_root "$src")
  [ -n "$root" ] && [ "$root" != "/" ]
}

bind_expected_uuid() {
  case "$1" in
    /nas|/nas/*)      echo "bdb80da4-0405-431c-8248-619ec5c04273" ;;
    /media/jellyfin)  echo "12751a0b-1f43-47f9-b09c-f975a449f74d" ;;
  esac
}

bind_device_present() {
  local uuid
  uuid=$(bind_expected_uuid "$1")
  [ -n "$uuid" ] || return 1
  command -v blkid >/dev/null 2>&1 || return 1
  [ -n "$(blkid -U "$uuid" 2>/dev/null || true)" ]
}

# Ensure a bind source exists. Permissive by default: create an empty
# placeholder directory when the drive is not mounted. --require-mounts
# turns a missing/unmounted source into a fatal error.
ensure_bind_source() {
  local src=$1
  if [ ! -d "$src" ]; then
    if [ "$REQUIRE_MOUNTS" -eq 1 ]; then
      die "bind source missing: $src — connect/mount the data disk first (or drop --require-mounts for staging)"
    fi
    warn "bind source missing: $src — creating empty placeholder directory (drive not mounted)"
    run mkdir -p "$src"
    return 0
  fi
  bind_on_data_disk "$src" && return 0
  if [ "$REQUIRE_MOUNTS" -eq 1 ]; then
    die "bind source is not on a data disk: $src — mount it first (or drop --require-mounts for staging)"
  fi
  if bind_device_present "$src"; then
    warn "bind source $src is a placeholder, but the expected drive is present — mount it and restart the CT"
  else
    warn "bind source $src is a placeholder directory (drive not mounted); the CT will see it as empty"
  fi
  return 0
}

bind_status_text() {
  local src=$1 root
  if bind_on_data_disk "$src"; then
    root=$(bind_mount_root "$src")
    if [ "$root" = "$src" ]; then
      printf 'mounted (%s)' "$root"
    else
      printf 'mounted (%s via %s)' "$src" "$root"
    fi
  elif [ -d "$src" ]; then
    if bind_device_present "$src"; then
      printf 'placeholder (drive present, not mounted)'
    else
      printf 'placeholder (drive missing, root fs)'
    fi
  else
    if bind_device_present "$src"; then
      printf 'missing (drive present, not mounted)'
    else
      printf 'missing (drive absent)'
    fi
  fi
}

ct_has_bind() {
  local id=$1 src=$2 dst=$3 conf="$PVE_LXC_DIR/$1.conf" line
  [ -f "$conf" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      mp*": $src,mp=$dst"|mp*": $src,mp=$dst,"*) return 0 ;;
    esac
  done < "$conf"
  return 1
}

next_mp_index() {
  local id=$1 conf="$PVE_LXC_DIR/$1.conf" n
  for n in $(seq 0 15); do
    grep -q "^mp${n}:" "$conf" 2>/dev/null || { echo "$n"; return 0; }
  done
  return 1
}


resolve_template() {
  local t=""
  if [ -n "$TEMPLATE" ]; then echo "$TEMPLATE"; return 0; fi
  if command -v pveam >/dev/null 2>&1; then
    t=$( { pveam list local 2>/dev/null || true; } | awk '/ubuntu-24.04-standard/{print $1}' | sort -V | tail -n1)
    if [ -z "$t" ]; then
      t=$( { pveam available --section system 2>/dev/null || true; } | awk '/ubuntu-24.04-standard/{print $1}' | sort -V | tail -n1)
    fi
  fi
  echo "$t"
}

ram_h() {
  awk -v m="$1" 'BEGIN { printf "%gG", m/1024 }'
}

print_plan() {
  printf '\n%s%-16s %-6s %-6s %-5s %-5s %-22s %s%s\n' \
    "$C_BOLD" "CT" "ID" "IP" "RAM" "Cores" "Disk" "Binds" "$C_RST"
  local i
  for i in "${!ct_names[@]}"; do
    printf '%-16s %-6s %-6s %-6s %-5s %-5s %-22s\n' \
      "${ct_names[$i]}" "${ct_ids[$i]}" "${ct_ips[$i]}" \
      "$(ram_h "${ct_ram[$i]}")" "${ct_cores[$i]}" "${ct_disk[$i]}G" \
      "$(ct_binds "${ct_names[$i]}")"
  done
  printf 'Pack: %s\nTemplate: %s\nStorage: %s\nSecrets: %s\n' "$PACK" "${TEMPLATE:-<auto>}" "$STORAGE" "$SECRETS_FILE"
  if [ "$REQUIRE_MOUNTS" -eq 1 ]; then
    printf 'Mounts: strict (--require-mounts)\n'
  else
    printf 'Mounts: permissive (missing sources become empty placeholder dirs)\n'
  fi
}

# ---------------------------------------------------------------------------
# Apt repositories
# ---------------------------------------------------------------------------
apt_enterprise_files() {
  grep -l 'enterprise\.proxmox\.com' \
    "$APT_SOURCES_DIR"/*.list "$APT_SOURCES_DIR"/*.sources 2>/dev/null || true
}

apt_has_subscription_key() {
  local pat='machine[[:space:]]\+enterprise\.proxmox\.com'
  grep -qs "$pat" "$APT_AUTH_DIR"/* 2>/dev/null && return 0
  grep -qs "$pat" /etc/apt/auth.conf 2>/dev/null && return 0
  return 1
}

apt_debian_codename() {
  local c=""
  if [ -r /etc/os-release ]; then
    c=$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-}")
  fi
  printf '%s\n' "$c"
}

apt_ceph_suite() {
  { grep -ho 'debian/ceph-[a-z]*' "$APT_SOURCES_DIR"/*.list "$APT_SOURCES_DIR"/*.sources 2>/dev/null || true; } \
    | head -n1 | cut -d/ -f2
}

apt_keyring_path() {
  local k=""
  k=$( { grep -ho 'Signed-By:[[:space:]]*[^[:space:]]*' "$APT_SOURCES_DIR"/*.sources 2>/dev/null || true; } \
       | head -n1 | sed 's/^Signed-By:[[:space:]]*//')
  if [ -z "$k" ]; then
    k=$( { grep -ho 'signed-by=[^]]*' "$APT_SOURCES_DIR"/*.list 2>/dev/null || true; } \
         | head -n1 | sed 's/^signed-by=//')
  fi
  if [ -n "$k" ] && [ -r "$k" ]; then printf '%s\n' "$k"; return 0; fi
  if [ -r "$PROXMOX_KEYRING" ]; then printf '%s\n' "$PROXMOX_KEYRING"; return 0; fi
  return 1
}

apt_disable_enterprise_sources() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in *.disabled) continue ;; esac
    run mv -f "$f" "$f.disabled"
    ok "disabled enterprise repo: $f (renamed to $(basename "$f").disabled)"
  done < <(apt_enterprise_files)
}

apt_write_no_subscription_sources() {
  local codename=$1 ceph=$2 keyring=$3
  run_sh "printf '%s\n' 'Types: deb' 'URIs: http://download.proxmox.com/debian/pve' 'Suites: $codename' 'Components: pve-no-subscription' 'Signed-By: $keyring' > '$APT_SOURCES_DIR/pve-no-subscription.sources'"
  if [ -n "$ceph" ]; then
    run_sh "printf '%s\n' 'Types: deb' 'URIs: http://download.proxmox.com/debian/$ceph' 'Suites: $codename' 'Components: no-subscription' 'Signed-By: $keyring' > '$APT_SOURCES_DIR/ceph-no-subscription.sources'"
  fi
}

apt_update_or_die() {
  if [ "$APPLY" -eq 1 ]; then
    printf '    %s+ apt-get update%s\n' "$C_GRN" "$C_RST"
    if ! apt-get update; then
      die "apt-get update failed — if enterprise.proxmox.com returned 401, run: sudo $0 --apply fix-repos (or add a subscription key)"
    fi
  else
    printf '    %s[dry-run]%s apt-get update\n' "$C_YEL" "$C_RST"
  fi
}

configure_apt_repos() {
  case "$APT_REPOS" in
    auto|keep|no-subscription) ;;
    *) die "invalid --apt-repos mode: $APT_REPOS (use auto, keep, or no-subscription)" ;;
  esac

  local -a ent=()
  mapfile -t ent < <(apt_enterprise_files)

  if [ "${#ent[@]}" -eq 0 ]; then
    ok "no enterprise Proxmox repositories enabled — leaving apt sources alone"
    return 0
  fi

  if [ "$APT_REPOS" = "keep" ]; then
    log "--apt-repos keep: leaving enterprise repositories in place"
    return 0
  fi

  if apt_has_subscription_key; then
    ok "Proxmox subscription key found — keeping enterprise repositories"
    return 0
  fi

  local codename ceph keyring f have_ceph=0
  codename=$(apt_debian_codename)
  [ -n "$codename" ] || die "could not determine the Debian codename from /etc/os-release"
  ceph=$(apt_ceph_suite)
  for f in "${ent[@]}"; do
    if grep -q 'debian/ceph-' "$f" 2>/dev/null; then have_ceph=1; fi
  done
  [ "$have_ceph" -eq 1 ] || ceph=""

  keyring=$(apt_keyring_path || true)
  [ -n "$keyring" ] || die "no Proxmox archive keyring found (nothing in Signed-By, and $PROXMOX_KEYRING is missing)"

  warn "no Proxmox subscription key found — switching enterprise repos to no-subscription"
  log "suite: $codename${ceph:+, ceph: $ceph}, keyring: $keyring"

  apt_disable_enterprise_sources
  apt_write_no_subscription_sources "$codename" "$ceph" "$keyring"
  ok "no-subscription repositories configured (revert by restoring the *.disabled files)"
}

phase_fix_repos() {
  step "Apt repositories"
  require_root
  require_pve
  configure_apt_repos
  apt_update_or_die
  ok "apt-repos phase complete"
}

# ---------------------------------------------------------------------------
# Phase: preflight
# ---------------------------------------------------------------------------
phase_preflight() {
  step "Preflight"
  require_root
  require_pve

  if [ "$APT_REPOS" != "keep" ] && ! apt_has_subscription_key && [ -n "$(apt_enterprise_files)" ]; then
    warn "enterprise Proxmox repos are enabled but no subscription key is configured — 'host' will switch them to no-subscription (use --apt-repos keep to opt out)"
  fi

  [ -d "$PACK" ] || die "migration pack not found: $PACK"
  local f missing=0
  for f in nginx.tar.gz var-www.tar.gz letsencrypt.tar.gz wireguard.tar.gz \
           stalwart.tar.gz motioneye.tar.gz ip-monitor.tar.gz \
           home-ssh-git.tar.gz all-databases.sql feelin-it.db smb.conf jellyfin.zip; do
    if [ ! -e "$PACK/$f" ]; then warn "required pack file missing: $f"; missing=1; fi
  done
  [ "$missing" -eq 0 ] || die "migration pack is incomplete"
  for f in mysql-grants.sql root.cron installed-packages.txt fstab.txt; do
    [ -e "$PACK/$f" ] || warn "optional pack file missing: $f"
  done

  local bind_src
  printf '\n%s%-22s %s%s\n' "$C_BOLD" "Bind source" "Status" "$C_RST"
  for bind_src in /nas /media/jellyfin /nas/Wyatt/vids; do
    printf '%-22s %s\n' "$bind_src" "$(bind_status_text "$bind_src")"
    if [ "$REQUIRE_MOUNTS" -eq 1 ] && ! bind_on_data_disk "$bind_src"; then
      die "bind source not ready: $bind_src — mount the data disk first (or drop --require-mounts for staging)"
    fi
    if [ "$REQUIRE_MOUNTS" -eq 0 ] && ! bind_on_data_disk "$bind_src" && bind_device_present "$bind_src"; then
      warn "drive for $bind_src is attached but not mounted — mount it before using this host for real data"
    fi
  done
  if [ "$REQUIRE_MOUNTS" -eq 1 ]; then
    ok "mount checks: strict (--require-mounts)"
  else
    warn "mount checks: permissive — 'create' will make empty placeholder dirs for missing sources"
  fi

  TEMPLATE=$(resolve_template)
  [ -n "$TEMPLATE" ] || warn "no ubuntu-24.04 template found; run: pveam update && pveam download local ubuntu-24.04-standard_<ver>_amd64.tar.zst"

  local i ip
  for i in "${!ct_names[@]}"; do
    ip="${ct_ips[$i]}"
    if ping -c1 -W1 "$ip" >/dev/null 2>&1; then
      warn "IP $ip (${ct_names[$i]}) answers ping — confirm it is free"
    fi
    if pct status "${ct_ids[$i]}" >/dev/null 2>&1; then
      warn "CT ${ct_ids[$i]} (${ct_names[$i]}) already exists — create will ensure binds and start it if stopped"
    fi
  done

  print_plan
  confirm "Continue with preflight result?"
  ok "preflight complete"
}

# ---------------------------------------------------------------------------
# Phase: host
# ---------------------------------------------------------------------------
configure_ufw() {
  command -v ufw >/dev/null 2>&1 || { warn "ufw not installed"; return 0; }
  run ufw allow 22/tcp
  local p
  for p in 80 443 25 110 143 465 587 993 995 4190 8080; do
    run ufw allow "$p/tcp"
  done
  run ufw allow 51820/udp
  run ufw allow 139/tcp
  run ufw allow 445/tcp
  run ufw allow from 192.168.0.0/24 to any port 3306 proto tcp
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    ok "ufw rules applied (already active)"
  else
    warn "ufw is installed but NOT enabled — configure LXC forwarding before enabling it"
  fi
}

stage_crontabs() {
  local src="$PACK/root.cron" moved=0
  mkdir -p "$WORKDIR"
  if [ ! -f "$src" ]; then
    warn "root.cron not in pack; skipping cron staging"
    return 0
  fi
  grep -v '/var/www/' "$src" | sed '/^[[:space:]]*$/d' > "$WORKDIR/host.cron" || true
  grep '/var/www/' "$src" > "$WORKDIR/ct-web.cron" || true
  if [ -s "$WORKDIR/host.cron" ]; then
    run sh -c "crontab '$WORKDIR/host.cron'"
    moved=1
  else
    warn "no host cron lines found (expected the IP-Monitor entry)"
  fi
  [ -s "$WORKDIR/ct-web.cron" ] && ok "ct-web cron staged: $WORKDIR/ct-web.cron"
  [ "$moved" -eq 1 ] && ok "host cron installed from $WORKDIR/host.cron"
}

ensure_host_user() {
  local existing
  id wyatt >/dev/null 2>&1 && return 0
  if ! getent group www-data >/dev/null 2>&1; then
    run groupadd -g 33 www-data
  fi
  existing=$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)
  if [ -n "$existing" ] && [ "$existing" != wyatt ]; then
    warn "uid 1000 belongs to $existing; renaming it to wyatt"
    run usermod -g www-data -l wyatt "$existing"
    run usermod -d /home/wyatt -m wyatt
  else
    run useradd -u 1000 -g www-data -m -d /home/wyatt -s /bin/bash wyatt
  fi
}

restore_host_home() {
  if [ -f "$PACK/home-ssh-git.tar.gz" ]; then
    run tar -xzf "$PACK/home-ssh-git.tar.gz" -C /home/wyatt
  else
    warn "home-ssh-git.tar.gz not in pack; skipping /home/wyatt/.ssh + git files"
  fi
  if [ -f "$PACK/ip-monitor.tar.gz" ]; then
    run tar -xzf "$PACK/ip-monitor.tar.gz" -C /home/wyatt
  else
    warn "ip-monitor.tar.gz not in pack; host cron will not have IP-Monitor"
  fi
  run_sh "chown -R wyatt:www-data /home/wyatt 2>/dev/null || true"
  run_sh "chmod 700 /home/wyatt/.ssh 2>/dev/null || true"
  run_sh "find /home/wyatt/.ssh -type f -name 'id_*' -exec chmod 600 {} + 2>/dev/null || true"
  run_sh "chmod 600 /home/wyatt/.git-credentials /home/wyatt/IP-Monitor/.env 2>/dev/null || true"
}

prepare_host_network() {
  local def_if="" svc
  def_if=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}') || true
  if [ -n "$def_if" ] && [ -f /etc/wireguard/wg0.conf ]; then
    run sed -i "s/-o enp5s0/-o $def_if/g" /etc/wireguard/wg0.conf
  else
    warn "could not determine default-route interface; check wg0.conf PostUp/PostDown"
  fi
  if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" != "1" ]; then
    run_sh "printf '%s\n' 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard.conf && sysctl --system"
  fi
  for svc in postfix exim4 sendmail; do
    if systemctl cat "$svc" >/dev/null 2>&1; then
      run systemctl disable --now "$svc"
    fi
  done
}

retarget_stalwart_https() {
  local stamp=$1
  local config=/opt/stalwart/etc/config.toml
  if [ "$APPLY" -eq 0 ]; then
    printf '    %s[dry-run]%s retarget Stalwart https listener to :8443 in %s\n' "$C_YEL" "$C_RST" "$config"
    return 0
  fi
  [ -f "$config" ] || die "Stalwart config missing: $config"
  cp -a "$config" "/root/stalwart-config.bak-$stamp"
  local result
  result=$(python3 - "$config" <<'PY'
import re
import sys
import tomllib
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
out = []
in_https = False
changed = False
already = False

for line in text.splitlines(keepends=True):
    stripped = line.strip()
    if re.match(r'^\[server\.listener\.https(?:\..*)?\]', stripped):
        in_https = True
        out.append(line)
        continue
    if stripped.startswith('['):
        in_https = False
        out.append(line)
        continue

    target = bool(re.match(r'^server\.listener\.https\.bind\s*=', stripped))
    if re.match(r'^server\.listener\.https\s*=', stripped):
        target = True
    if in_https and re.match(r'^bind\s*=', stripped):
        target = True

    if target:
        if ':8443' in line:
            already = True
        elif ':443' in line:
            line = line.replace(':443', ':8443')
            changed = True
    out.append(line)

new_text = ''.join(out)
tomllib.loads(new_text)
if changed:
    path.write_text(new_text)
    print('retargeted')
elif already:
    print('already-8443')
else:
    print('no-https-bind')
PY
)
  case "$result" in
    retargeted) ok "Stalwart https listener retargeted to :8443" ;;
    already-8443) ok "Stalwart https listener already on :8443" ;;
    no-https-bind) warn "Stalwart https bind not found; config left unchanged" ;;
    *) die "unexpected Stalwart config result: $result" ;;
  esac
}

phase_host() {
  step "Host edge services"
  require_root
  require_pve
  [ -d "$PACK" ] || die "migration pack not found: $PACK"

  local stamp; stamp=$(date +%Y%m%d-%H%M%S)

  log "Installing host packages"
  configure_apt_repos
  apt_update_or_die
  run apt-get install -y nginx certbot python3-certbot-nginx wireguard-tools ufw curl \
    python3-requests python3-dotenv

  log "Backing up existing host configs to /root/*.bak-$stamp"
  local p
  for p in /etc/nginx /etc/letsencrypt /etc/wireguard /opt/stalwart; do
    [ -e "$p" ] && run cp -a "$p" "/root/$(basename "$p").bak-$stamp"
  done
  [ -d /home/wyatt ] && run cp -a /home/wyatt "/root/home-wyatt.bak-$stamp"
  run cp -a /etc/hosts "/root/hosts.bak-$stamp"
  run_sh "crontab -l > /root/crontab.bak-$stamp 2>/dev/null || true"

  getent group stalwart >/dev/null 2>&1 || run groupadd --system stalwart
  if ! id stalwart >/dev/null 2>&1; then
    log "Creating stalwart system user"
    run useradd --system --gid stalwart --home /opt/stalwart --shell /usr/sbin/nologin stalwart
  fi
  ensure_host_user

  log "Restoring configs from pack"
  run tar -xzf "$PACK/nginx.tar.gz" -C /
  run tar -xzf "$PACK/letsencrypt.tar.gz" -C /
  run tar -xzf "$PACK/wireguard.tar.gz" -C /
  run tar -xzf "$PACK/stalwart.tar.gz" -C /
  run chown -R stalwart:stalwart /opt/stalwart
  retarget_stalwart_https "$stamp"
  restore_host_home
  prepare_host_network

  log "Enabling services"
  run systemctl daemon-reload
  run systemctl enable --now wg-quick@wg0
  run systemctl enable stalwart
  run systemctl restart stalwart
  run systemctl enable --now certbot.timer
  run systemctl enable nginx
  run systemctl stop nginx || true

  if ! grep -q 'mail\.wyattjohnson\.net' /etc/hosts; then
    if [ "$APPLY" -eq 1 ]; then
      printf '127.0.0.1 mail.wyattjohnson.net mail\n' >> /etc/hosts
      ok "added mail.wyattjohnson.net to /etc/hosts"
    else
      printf '    %s[dry-run]%s append mail.wyattjohnson.net to /etc/hosts\n' "$C_YEL" "$C_RST"
    fi
  fi

  configure_ufw
  stage_crontabs

  warn "nginx config restored but NOT started — configure the CTs, then run 'nginx-rewrite'"
  ok "host phase complete"
}

# ---------------------------------------------------------------------------
# Phase: create
# ---------------------------------------------------------------------------
require_ct() {
  local id=$1
  if [ "$APPLY" -eq 0 ]; then
    printf '    %s[dry-run]%s require running CT %s\n' "$C_YEL" "$C_RST" "$id"
    return 0
  fi
  pct status "$id" >/dev/null 2>&1 || die "CT $id does not exist"
  pct status "$id" | grep -q running || die "CT $id is not running"
}

add_bind_mount() {
  local id=$1 mpn=$2 src=$3 dst=$4
  local conf="$PVE_LXC_DIR/${id}.conf"
  if grep -q "^mp${mpn}:" "$conf" 2>/dev/null; then
    warn "mp${mpn} already present in $conf; leaving it"
    return 0
  fi
  if [ "$APPLY" -eq 1 ]; then
    mkdir -p "$PVE_LXC_DIR"
    printf 'mp%s: %s,mp=%s\n' "$mpn" "$src" "$dst" >> "$conf"
    ok "added mp${mpn}: $src -> $dst"
  else
    printf '    %s[dry-run]%s append mp%s: %s,mp=%s to %s\n' \
      "$C_YEL" "$C_RST" "$mpn" "$src" "$dst" "$conf"
  fi
}

# Ensure a container's config has every expected bind, at the next free index.
ensure_ct_binds() {
  local id=$1 name=$2 binds entry src dst mpn
  binds=$(ct_binds "$name")
  [ -n "$binds" ] || return 0
  local -a entries
  IFS=',' read -ra entries <<< "$binds"
  for entry in "${entries[@]}"; do
    src=${entry%%:*}; dst=${entry##*:}
    if ct_has_bind "$id" "$src" "$dst"; then
      ok "CT $id already has bind $src -> $dst"
      continue
    fi
    mpn=$(next_mp_index "$id") || die "no free mp slot in $PVE_LXC_DIR/$id.conf"
    add_bind_mount "$id" "$mpn" "$src" "$dst"
  done
}

wait_for_ct() {
  local id=$1 ip=$2 n=0
  if [ "$APPLY" -eq 0 ]; then
    printf '    %s[dry-run]%s wait for CT %s at %s\n' "$C_YEL" "$C_RST" "$id" "$ip"
    return 0
  fi
  until pct exec "$id" -- true >/dev/null 2>&1; do
    sleep 2; n=$((n+1))
    [ "$n" -gt 40 ] && die "CT $id did not start"
  done
  n=0
  until ping -c1 -W1 "$ip" >/dev/null 2>&1; do
    sleep 2; n=$((n+1))
    if [ "$n" -gt 30 ]; then warn "CT $id does not answer ping at $ip"; break; fi
  done
}

test_binds() {
  local id=$1 binds=$2 entry src dst note
  [ -z "$binds" ] && return 0
  local -a entries
  IFS=',' read -ra entries <<< "$binds"
  for entry in "${entries[@]}"; do
    src=${entry%%:*}; dst=${entry##*:}
    note=""
    if [ -d "$src" ] && ! bind_on_data_disk "$src"; then
      note=" (placeholder — drive not mounted)"
    fi
    if [ "$APPLY" -eq 1 ]; then
      if pct exec "$id" -- bash -c "set -e; [ -d '$dst' ]; touch '$dst/.migration_rw_test'; rm '$dst/.migration_rw_test'"; then
        ok "bind rw OK: $id:$dst$note"
      else
        warn "bind rw FAILED: $id:$dst$note"
      fi
    else
      printf '    %s[dry-run]%s rw test %s:%s%s\n' "$C_YEL" "$C_RST" "$id" "$dst" "$note"
    fi
  done
}

phase_create() {
  step "Create LXC containers"
  require_root
  require_pve

  TEMPLATE=$(resolve_template)
  [ -n "$TEMPLATE" ] || die "no template selected; pass --template or download ubuntu-24.04"

  local base="${TEMPLATE##*/}"
  if ! pveam list local 2>/dev/null | awk '{print $1}' | grep -qF "$base"; then
    warn "template not present in local storage: $base"
    run pveam update
    run pveam download local "$base"
  fi
  local volid
  volid=$( { pveam list local 2>/dev/null || true; } | awk -v b="$base" 'index($1,b){print $1; exit}')
  [ -n "$volid" ] && TEMPLATE="$volid"

  local sshkeys="" pw="${CT_ROOT_PASSWORD:-}"
  [ -f /root/.ssh/authorized_keys ] && sshkeys=/root/.ssh/authorized_keys

  local i name id ip binds entry src
  local -a scope=() entries=()
  for i in "${!ct_names[@]}"; do
    name=${ct_names[$i]}
    if [ -n "$ONLY" ] && [ "$ONLY" != "$name" ]; then continue; fi
    scope+=("$i")
    binds=$(ct_binds "$name")
    [ -n "$binds" ] || continue
    IFS=',' read -ra entries <<< "$binds"
    for entry in "${entries[@]}"; do
      ensure_bind_source "${entry%%:*}"
    done
  done

  for i in "${scope[@]}"; do
    name=${ct_names[$i]}; id=${ct_ids[$i]}; ip=${ct_ips[$i]}
    binds=$(ct_binds "$name")

    if pct status "$id" >/dev/null 2>&1; then
      ok "CT $id ($name) already exists"
      ensure_ct_binds "$id" "$name"
      if pct status "$id" | grep -q running; then
        ok "CT $id ($name) is running"
      else
        confirm "Start existing container $id ($name)?"
        run pct start "$id"
        wait_for_ct "$id" "$ip"
      fi
      test_binds "$id" "$binds"
      continue
    fi

    local -a args=(pct create "$id" "$TEMPLATE"
      --hostname "$name"
      --ostype ubuntu
      --cores "${ct_cores[$i]}"
      --memory "${ct_ram[$i]}"
      --swap 512
      --rootfs "${STORAGE}:${ct_disk[$i]}"
      --net0 "name=eth0,bridge=$BRIDGE,ip=$ip/24,gw=$GATEWAY"
      --nameserver "$GATEWAY"
      --unprivileged 1
      --onboot 1
      --start 0)
    [ -n "${ct_features[$i]}" ] && args+=(--features "${ct_features[$i]}")
    if [ -n "$sshkeys" ]; then
      args+=(--ssh-public-keys "$sshkeys")
    elif [ -z "$pw" ]; then
      warn "no CT_ROOT_PASSWORD and no /root/.ssh/authorized_keys; set the root password manually"
    fi

    confirm "Create container $id ($name) at $ip?"
    run "${args[@]}"
    ensure_ct_binds "$id" "$name"

    run pct start "$id"
    wait_for_ct "$id" "$ip"
    if [ -n "$pw" ]; then
      if [ "$APPLY" -eq 1 ]; then
        printf 'root:%s\n' "$pw" | pct exec "$id" -- chpasswd
        ok "root password set for CT $id"
      else
        printf '    %s[dry-run]%s set root password for CT %s\n' "$C_YEL" "$C_RST" "$id"
      fi
    fi
    test_binds "$id" "$binds"
  done
  ok "create phase complete"
}

# ---------------------------------------------------------------------------
# Staging helpers
# ---------------------------------------------------------------------------
write_guide() {
  local name=$1
  mkdir -p "$WORKDIR"
  cat > "$WORKDIR/${name}.md"
  ok "guide written: $WORKDIR/${name}.md"
}

stage_push() {
  local id=$1 src=$2 dst=$3
  [ -e "$src" ] || { warn "missing staging source: $src"; return 1; }
  run pct push "$id" "$src" "$dst"
}

stage_mkdir() {
  local id=$1 dir=$2
  run pct exec "$id" -- mkdir -p "$dir"
}

require_named_ct() {
  local name=$1 id
  id=$(ct_field "$name" id) || die "unknown container: $name"
  if [ "$APPLY" -eq 0 ]; then
    printf '    %s[dry-run]%s stage %s (CT %s)\n' "$C_YEL" "$C_RST" "$name" "$id"
    return 0
  fi
  require_ct "$id"
}

# ---------------------------------------------------------------------------
# Restore: ct-db
# ---------------------------------------------------------------------------
restore_ct_db() {
  local id; id=$(ct_field ct-db id)
  step "ct-db: stage MySQL data"
  require_named_ct ct-db
  stage_mkdir "$id" /root/migration-stage
  stage_push "$id" "$PACK/all-databases.sql" /root/migration-stage/all-databases.sql
  [ -e "$PACK/mysql-grants.sql" ] && stage_push "$id" "$PACK/mysql-grants.sql" /root/migration-stage/mysql-grants.sql

  write_guide ct-db <<'EOF'
# ct-db restore (MySQL 8)

Staged in /root/migration-stage.

1. Install MySQL 8 (do not use MariaDB):
     apt update && apt install -y mysql-server
2. Bind to the container IP only:
     sed -i 's/^bind-address.*/bind-address = 192.168.0.70/' /etc/mysql/mysql.conf.d/mysqld.cnf
     systemctl restart mysql
3. Preferred: run the configure phase, which imports only the app DBs
   (excludes the mysql system DB) so the fresh root/debian accounts survive.
4. Manual restore (skip the mysql system DB):
     awk '/^-- Current Database: / { skip = ($0 ~ /Current Database: .mysql/); if (!skip) print; next } !skip { print }' \
       /root/migration-stage/all-databases.sql > /root/migration-stage/app-databases.sql
     mysql -u root < /root/migration-stage/app-databases.sql
   Do not use the pack's mysql-create-users.sql: it contains password hashes
   from the old server that MySQL 8 rejects (ERROR 1827).
5. Create public_user@% and roundcube@192.168.0.% with the passwords from
   DB_PUBLIC_USER_PASSWORD and DB_ROUNDCUBE_PASSWORD in
   /root/migration-secrets.env, then apply only their grants from
   mysql-grants.sql. The configure phase does this automatically.
6. Verify 13 app DBs:
     mysql -u root -e 'SHOW DATABASES;'
7. Firewall: allow 3306 only from 192.168.0.0/24, never from the WAN.
EOF
}

# ---------------------------------------------------------------------------
# Restore: ct-web
# ---------------------------------------------------------------------------
generate_ct_web_conf() {
  local out="$WORKDIR/ct-web-apps.conf"
  mkdir -p "$WORKDIR"
  {
    echo "# Generated by setup-from-migration-pack.sh"
    echo "# Copy to /etc/nginx/conf.d/apps.conf inside ct-web"
    echo
    while IFS='|' read -r names root; do
      [ -z "$names" ] && continue
      cat <<EOF
server {
    listen 80;
    server_name $names;
    root $root;
    index index.php index.html;
    client_max_body_size 100M;
    location / { try_files \$uri \$uri/ /index.php\$is_args\$args; }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
    }
    location ~ /\.ht { deny all; }
}

EOF
    done <<'MAP'
cardinal-surveying.com|/var/www/cardinal/public
admin.cardinal-surveying.com|/var/www/cardinal/public
www.cardinal-surveying.com|/var/www/cardinal/public
wyattjohnson.net www.wyattjohnson.net|/var/www/wyattjohnson/public
mycars.wyattjohnson.net|/var/www/gas-mileage/public_html
gsjohnson.art www.gsjohnson.art|/var/www/gsjohnson/public
money.wyattjohnson.net|/var/www/money/public
photos.wyattjohnson.net|/var/www/photos/public
classifieds.roundaboutperformance.com|/var/www/roundabout/public
suspicion.wyattjohnson.net|/var/www/suspicionGameBoard
sloppy-seconds.wyattjohnson.net|/var/www/sloppy-seconds/public
web-dev.wyattjohnson.net|/var/www/web-dev-examples
mail.wyattjohnson.net|/var/www/webmail
MAP
  } > "$out"
  ok "ct-web nginx config written: $out"
}

restore_ct_web() {
  local id; id=$(ct_field ct-web id)
  step "ct-web: stage /var/www, cron, nginx config"
  require_named_ct ct-web
  stage_push "$id" "$PACK/var-www.tar.gz" /root/var-www.tar.gz
  run pct exec "$id" -- tar -xzf /root/var-www.tar.gz -C /
  if [ -s "$WORKDIR/ct-web.cron" ]; then
    stage_push "$id" "$WORKDIR/ct-web.cron" /root/ct-web.cron
  fi
  generate_ct_web_conf
  stage_push "$id" "$WORKDIR/ct-web-apps.conf" /root/ct-web-apps.conf

  write_guide ct-web <<'EOF'
# ct-web restore (nginx + php-fpm 8.4)

Staged: /var/www, /root/ct-web.cron, /root/ct-web-apps.conf
Pack also has the original nginx configs if you need to compare.

1. Install nginx + PHP 8.4 (module list mirrors the current box):
     apt update
     apt install -y nginx php8.4-fpm php8.4-cli php8.4-mysql php8.4-mbstring \
       php8.4-xml php8.4-curl php8.4-zip php8.4-gd php8.4-intl php8.4-bcmath \
       php8.4-sqlite3 composer git unzip
2. Install the generated host-header routing:
     cp /root/ct-web-apps.conf /etc/nginx/conf.d/apps.conf
     rm -f /etc/nginx/sites-enabled/default
     nginx -t && systemctl reload nginx && systemctl enable nginx
3. Point every Laravel app at ct-db:
     grep -rl '^DB_HOST=' /var/www --include=.env | xargs -r sed -i 's/^DB_HOST=.*/DB_HOST=192.168.0.70/'
4. wyattjohnson and roundabout use public_user:
     copy DB_USERNAME=public_user and DB_PASSWORD from cardinal/.env into
     /var/www/wyattjohnson/.env and /var/www/roundabout/.env.
5. Roundcube: set the DB host to 192.168.0.70 in /var/www/webmail/config/config.inc.php
     ($config['db_dsnw'] = 'mysql://roundcube:<pw>@192.168.0.70/roundcubemail';)
   Set imap_host to 192.168.0.69:143 and resolve the mail host to the Proxmox host:
     grep -q 'mail.wyattjohnson.net' /etc/hosts || echo '192.168.0.69 mail.wyattjohnson.net' >> /etc/hosts
6. Per Laravel app: composer only when vendor is missing; storage link, permissions
     for d in cardinal wyattjohnson gas-mileage gsjohnson money photos roundabout sloppy-seconds; do
       ( cd /var/www/$d && [ -f vendor/autoload.php ] || composer install --no-dev --optimize-autoloader )
       ( cd /var/www/$d && php artisan storage:link >/dev/null 2>&1 || true )
     done
     chown -R www-data:www-data /var/www
7. Install the Laravel scheduler cron:
     crontab -u root /root/ct-web.cron
8. npm/node is only needed if you rebuild assets for a specific app.
EOF
}

# ---------------------------------------------------------------------------
# Restore: ct-docker-web
# ---------------------------------------------------------------------------
restore_ct_docker_web() {
  local id; id=$(ct_field ct-docker-web id)
  step "ct-docker-web: stage feelin-it + compatibility"
  require_named_ct ct-docker-web
  stage_push "$id" "$PACK/var-www.tar.gz" /root/var-www.tar.gz
  run pct exec "$id" -- tar -xzf /root/var-www.tar.gz -C / var/www/feelin-it var/www/compatibility
  stage_push "$id" "$PACK/feelin-it.db" /root/feelin-it.db
  for f in feelin-it.db-shm feelin-it.db-wal; do
    [ -e "$PACK/$f" ] && stage_push "$id" "$PACK/$f" "/root/$f" || true
  done

  write_guide ct-docker-web <<'EOF'
# ct-docker-web restore (Docker: feelin-it + compatibility)

Staged: /var/www/feelin-it, /var/www/compatibility, /root/feelin-it.db*

1. Install Docker (CT must have features: nesting=1,keyctl=1):
     apt update && apt install -y docker.io docker-compose-v2
     systemctl enable --now docker
2. Restore the Feelin' It SQLite DB into its named volume:
     docker volume create feelin-it_feelin-it-data
     cp -f /root/feelin-it.db /root/feelin-it.db-shm /root/feelin-it.db-wal \
       /var/lib/docker/volumes/feelin-it_feelin-it-data/_data/ 2>/dev/null || true
     chown -R 100:101 /var/lib/docker/volumes/feelin-it_feelin-it-data/_data
3. Bring up Feelin' It:
     cd /var/www/feelin-it && docker compose up -d --build
4. Bring up compatibility (its MySQL DB starts fresh by design):
     cd /var/www/compatibility && docker compose up -d --build
5. Verify locally:
     curl -sI http://127.0.0.1:3000 | head -1
     curl -sI http://127.0.0.1:8082 | head -1
6. Host nginx proxies feelin-it :3000 and compatible :8082 to 192.168.0.72.
EOF
}

# ---------------------------------------------------------------------------
# Restore: ct-jellyfin
# ---------------------------------------------------------------------------
restore_ct_jellyfin() {
  local id; id=$(ct_field ct-jellyfin id)
  step "ct-jellyfin: stage built-in backup archive"
  require_named_ct ct-jellyfin
  stage_push "$id" "$PACK/jellyfin.zip" /root/jellyfin.zip

  write_guide ct-jellyfin <<'EOF'
# ct-jellyfin restore

Staged: /root/jellyfin.zip (Jellyfin built-in backup archive)

The configure phase restores it in ct-jellyfin via pct exec:
  /usr/bin/jellyfin --restore-archive /var/lib/jellyfin/data/backups/jellyfin.zip

Jellyfin is pinned to 12.2 until the restore is verified. Media must be
visible at /media/jellyfin; plugin binaries/configs are not in the archive.

To upgrade later:
  apt-mark unhold jellyfin jellyfin-server jellyfin-web
  apt-get update && apt-get install -y jellyfin
EOF
  ok "ct-jellyfin restore guide complete"
}

# ---------------------------------------------------------------------------
# Restore: ct-surveillance
# ---------------------------------------------------------------------------
restore_ct_surveillance() {
  local id; id=$(ct_field ct-surveillance id)
  step "ct-surveillance: stage motionEye config/state"
  require_named_ct ct-surveillance
  stage_push "$id" "$PACK/motioneye.tar.gz" /root/motioneye.tar.gz

  write_guide ct-surveillance <<'EOF'
# ct-surveillance restore (motion + motionEye)

Staged: /root/motioneye.tar.gz (etc/motioneye, etc/motion, systemd unit, var/lib/motioneye)

1. Install motion and motionEye for your distro.
2. Restore configs and state:
     tar -xzf /root/motioneye.tar.gz -C /
     chown -R motion:motion /var/lib/motioneye /etc/motioneye 2>/dev/null || true
     systemctl daemon-reload
3. The bind mount /nas/Wyatt/vids is already attached; verify:
     ls -la /nas/Wyatt/vids | head
4. Enable and start:
     systemctl enable --now motioneye
5. Allow the UI/api ports: 8765, 9081, 9082.
6. Confirm both camera streams and that recordings land in /nas/Wyatt/vids/front.
EOF
}

# ---------------------------------------------------------------------------
# Restore: ct-files
# ---------------------------------------------------------------------------
restore_ct_files() {
  local id; id=$(ct_field ct-files id)
  step "ct-files: stage Samba config"
  require_named_ct ct-files
  stage_push "$id" "$PACK/smb.conf" /root/smb.conf

  write_guide ct-files <<'EOF'
# ct-files restore (Samba)

Staged: /root/smb.conf

1. Install Samba:
     apt update && apt install -y samba
2. Install the share config:
     cp /root/smb.conf /etc/samba/smb.conf
     testparm -s
3. Recreate the Samba user (passwords are not carried in smb.conf):
     wyatt: uid 1000, gid 33 (www-data)
     smbpasswd -a wyatt
     pdbedit -L
4. The bind mount /nas is attached; verify:
     ls -la /nas | head
   Files owned by the old smbuser (uid 997) must be chowned/chgrped to
   wyatt/www-data, or made group/world writable, for wyatt to modify them.
5. Enable and restart:
     systemctl enable --now smbd nmbd
6. Open 139/tcp and 445/tcp. LAN clients use \\192.168.0.75\nas
EOF
}

restore_one() {
  case "$1" in
    ct-db)           restore_ct_db ;;
    ct-web)          restore_ct_web ;;
    ct-docker-web)   restore_ct_docker_web ;;
    ct-jellyfin)     restore_ct_jellyfin ;;
    ct-surveillance) restore_ct_surveillance ;;
    ct-files)        restore_ct_files ;;
    all)
      restore_ct_db
      restore_ct_web
      restore_ct_docker_web
      restore_ct_jellyfin
      restore_ct_surveillance
      restore_ct_files
      ;;
    *) die "unknown container: $1 (use one of: ct-db ct-web ct-docker-web ct-jellyfin ct-surveillance ct-files all)" ;;
  esac
}

ct_exec() {
  local id=$1; shift
  run pct exec "$id" -- "$@"
}

ct_script() {
  local id=$1
  if [ "$APPLY" -eq 1 ]; then
    printf '    %s+ run configure script in CT %s%s\n' "$C_GRN" "$id" "$C_RST"
    pct exec "$id" -- bash -s
  else
    cat >/dev/null
    printf '    %s[dry-run]%s run configure script in CT %s\n' "$C_YEL" "$C_RST" "$id"
  fi
}

ct_stdin() {
  local id=$1; shift
  if [ "$APPLY" -eq 1 ]; then
    printf '    %s+ pct exec %s -- %s (stdin hidden)%s\n' "$C_GRN" "$id" "$*" "$C_RST"
    pct exec "$id" -- "$@"
  else
    printf '    %s[dry-run]%s pct exec %s -- %s (stdin hidden)\n' "$C_YEL" "$C_RST" "$id" "$*"
  fi
}

require_staged() {
  local id=$1 path=$2
  if [ "$APPLY" -eq 1 ]; then
    pct exec "$id" -- test -e "$path" || die "CT $id is missing $path — run the restore phase first"
  else
    printf '    %s[dry-run]%s require %s in CT %s\n' "$C_YEL" "$C_RST" "$path" "$id"
  fi
}

load_secrets() {
  if [ -f "$SECRETS_FILE" ]; then
    . "$SECRETS_FILE"
  fi
}

prompt_secret() {
  local var=$1 label=$2 val
  val="${!var:-}"
  [ -n "$val" ] && return 0
  [ -t 0 ] || die "$var is not set and there is no TTY for a prompt; add it to $SECRETS_FILE"
  read -r -s -p "$label: " val
  printf '\n'
  printf -v "$var" '%s' "$val"
}

configure_ct_db() {
  local id rc_pw pub_pw
  id=$(ct_field ct-db id)
  step "ct-db: install/configure MySQL 8"
  require_named_ct ct-db
  require_staged "$id" /root/migration-stage/all-databases.sql
  require_staged "$id" /root/migration-stage/mysql-grants.sql

  ct_script "$id" <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y mysql-server
grep -q '^bind-address' /etc/mysql/mysql.conf.d/mysqld.cnf || echo 'bind-address = 192.168.0.70' >> /etc/mysql/mysql.conf.d/mysqld.cnf
sed -i 's/^bind-address.*/bind-address = 192.168.0.70/' /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl enable mysql
systemctl restart mysql
for i in $(seq 1 30); do
  mysqladmin ping --silent && break
  sleep 2
done
mysqladmin ping --silent || { echo "MySQL did not start" >&2; exit 1; }
awk '/^-- Current Database: / { skip = ($0 ~ /Current Database: .mysql/); if (!skip) print; next } !skip { print }' \
  /root/migration-stage/all-databases.sql > /root/migration-stage/app-databases.sql
mysql -u root < /root/migration-stage/app-databases.sql
mysql -u root -e "DROP USER IF EXISTS 'public_user'@'%'; DROP USER IF EXISTS 'roundcube'@'localhost'; DROP USER IF EXISTS 'test'@'localhost';"
EOF

  if [ "$APPLY" -eq 1 ]; then
    load_secrets
    prompt_secret DB_ROUNDCUBE_PASSWORD "MySQL password for roundcube"
    prompt_secret DB_PUBLIC_USER_PASSWORD "MySQL password for public_user"
    rc_pw="$DB_ROUNDCUBE_PASSWORD"
    pub_pw="$DB_PUBLIC_USER_PASSWORD"
    mkdir -p "$WORKDIR"
    ( umask 077; ROUNDCUBE_PW="$rc_pw" PUBLIC_USER_PW="$pub_pw" GRANTS_FILE="$PACK/mysql-grants.sql" python3 - > "$WORKDIR/remote-users.sql" <<'PY'
import os
import re

def esc(value):
    return value.replace("\\", "\\\\").replace("'", "''")

rc = esc(os.environ["ROUNDCUBE_PW"])
pub = esc(os.environ["PUBLIC_USER_PW"])
grants_path = os.environ["GRANTS_FILE"]

USER_RE = re.compile(
    r"(?:`([^`]+)`|'([^']+)'|\"([^\"]+)\"|([A-Za-z0-9_.-]+))"
    r"\s*@\s*"
    r"(?:`([^`]+)`|'([^']+)'|\"([^\"]+)\"|([A-Za-z0-9_.%:/-]+))"
)

def first(*values):
    for value in values:
        if value is not None:
            return value
    return None

def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"--[^\n]*", " ", text)
    text = re.sub(r"#[^\n]*", " ", text)
    return text

def split_statements(text):
    statements = []
    buf = []
    quote = None
    i = 0
    while i < len(text):
        ch = text[i]
        if quote:
            buf.append(ch)
            if ch == quote:
                if i + 1 < len(text) and text[i + 1] == quote:
                    buf.append(text[i + 1])
                    i += 1
                elif i == 0 or text[i - 1] != "\\":
                    quote = None
        else:
            if ch in ("'", '"', '`'):
                quote = ch
                buf.append(ch)
            elif ch == ";":
                statements.append("".join(buf))
                buf = []
            else:
                buf.append(ch)
        i += 1
    if "".join(buf).strip():
        statements.append("".join(buf))
    return statements

def find_to(statement):
    quote = None
    i = 0
    n = len(statement)
    while i < n:
        ch = statement[i]
        if quote:
            if ch == quote:
                if i + 1 < n and statement[i + 1] == quote:
                    i += 1
                elif i == 0 or statement[i - 1] != "\\":
                    quote = None
        else:
            if ch in ("'", '"', '`'):
                quote = ch
            elif statement[i:i + 2].upper() == "TO":
                before = statement[i - 1] if i > 0 else " "
                after = statement[i + 2] if i + 2 < n else " "
                if not (before.isalnum() or before == "_") and not (after.isalnum() or after == "_"):
                    return i
        i += 1
    return -1

users = {
    ("public_user", "%"): pub,
    ("roundcube", "192.168.0.%"): rc,
}
grants = []

try:
    raw = open(grants_path).read()
except OSError:
    raw = ""

for statement in split_statements(strip_comments(raw)):
    statement = statement.strip()
    if not statement or not re.match(r"(?is)^GRANT\b", statement):
        continue
    if re.search(r"(?i)\bPROXY\b", statement):
        continue
    pos = find_to(statement)
    if pos < 0:
        continue
    prefix = statement[:pos]
    rest = statement[pos + 2:]
    matches = list(USER_RE.finditer(rest))
    if not matches:
        continue
    kept = []
    for match in matches:
        user = first(match.group(1), match.group(2), match.group(3), match.group(4))
        host = first(match.group(5), match.group(6), match.group(7), match.group(8))
        if user in ("public_user", "roundcube"):
            kept.append((user, host))
    if not kept:
        continue
    suffix = rest[matches[-1].end():]
    suffix = re.sub(r"(?is)\s+IDENTIFIED\b.*?(?=\s+WITH\s+GRANT\s+OPTION\b|$)", "", suffix)
    grantees = ", ".join("'%s'@'%s'" % (esc(user), esc(host)) for user, host in kept)
    grants.append(prefix.rstrip() + " TO " + grantees + suffix.rstrip() + ";")
    for user, host in kept:
        users.setdefault((user, host), pub if user == "public_user" else rc)

print("-- Generated by setup-from-migration-pack.sh")
for (user, host), password in sorted(users.items()):
    print("CREATE USER IF NOT EXISTS '%s'@'%s' IDENTIFIED BY '%s';" % (esc(user), esc(host), password))
    print("ALTER USER '%s'@'%s' IDENTIFIED BY '%s';" % (esc(user), esc(host), password))
for grant in grants:
    print(grant)
print("GRANT ALL PRIVILEGES ON `portfolio`.* TO 'public_user'@'%';")
print("GRANT ALL PRIVILEGES ON `nyoom`.* TO 'public_user'@'%';")
print("GRANT ALL PRIVILEGES ON `roundcubemail`.* TO 'roundcube'@'192.168.0.%';")
print("FLUSH PRIVILEGES;")
PY
    )
    chmod 600 "$WORKDIR/remote-users.sql"
    stage_push "$id" "$WORKDIR/remote-users.sql" /root/migration-stage/remote-users.sql || die "failed to push remote-users.sql"
    ct_script "$id" <<'EOF'
set -e
mysql -u root < /root/migration-stage/remote-users.sql
rm -f /root/migration-stage/remote-users.sql
count=$(mysql -u root -N -e 'SHOW DATABASES' | grep -Ev '^(information_schema|mysql|performance_schema|sys)$' | wc -l)
echo "application databases: $count"
mysql -u root -N -e "SELECT user, host FROM mysql.user WHERE user IN ('public_user','roundcube') ORDER BY user, host"
EOF
    rm -f "$WORKDIR/remote-users.sql"
  else
    printf '    %s[dry-run]%s create public_user/roundcube from %s and apply their grants from mysql-grants.sql\n' "$C_YEL" "$C_RST" "$SECRETS_FILE"
    printf '    %s[dry-run]%s verify application databases and remote users\n' "$C_YEL" "$C_RST"
  fi
  ok "ct-db configure complete"
}

configure_ct_web() {
  local id
  id=$(ct_field ct-web id)
  step "ct-web: install/configure nginx + PHP 8.4"
  require_named_ct ct-web
  require_staged "$id" /root/ct-web-apps.conf
  require_staged "$id" /var/www

  ct_script "$id" <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y software-properties-common
add-apt-repository -y ppa:ondrej/php
apt-get update
apt-get install -y nginx php8.4-fpm php8.4-cli php8.4-common php8.4-mysql \
  php8.4-mbstring php8.4-xml php8.4-curl php8.4-zip php8.4-gd php8.4-intl \
  php8.4-bcmath php8.4-sqlite3 php8.4-opcache php8.4-readline composer git unzip curl cron
update-alternatives --install /usr/bin/php php /usr/bin/php8.4 100 2>/dev/null || true
update-alternatives --set php /usr/bin/php8.4 2>/dev/null || true
install -m 0644 /root/ct-web-apps.conf /etc/nginx/conf.d/apps.conf
rm -f /etc/nginx/sites-enabled/default
grep -rl '^DB_HOST=' /var/www --include=.env | xargs -r sed -i 's/^DB_HOST=.*/DB_HOST=192.168.0.70/'
f=/var/www/webmail/config/config.inc.php
if [ -f "$f" ]; then
  sed -i 's|@localhost/roundcubemail|@192.168.0.70/roundcubemail|' "$f"
  sed -i "s|'localhost:143'|'192.168.0.69:143'|" "$f"
fi
grep -q 'mail.wyattjohnson.net' /etc/hosts || echo '192.168.0.69 mail.wyattjohnson.net' >> /etc/hosts
EOF

  ct_script "$id" <<'EOF'
set -e
for d in cardinal wyattjohnson gas-mileage gsjohnson money photos roundabout sloppy-seconds; do
  [ -d "/var/www/$d" ] || continue
  if [ ! -f "/var/www/$d/vendor/autoload.php" ]; then
    (cd "/var/www/$d" && composer install --no-dev --optimize-autoloader)
  fi
  (cd "/var/www/$d" && php artisan config:clear >/dev/null 2>&1 || true)
  (cd "/var/www/$d" && php artisan storage:link >/dev/null 2>&1 || true)
done
chown -R www-data:www-data /var/www
if [ -s /root/ct-web.cron ]; then
  crontab -u root /root/ct-web.cron
fi
nginx -t
systemctl enable --now php8.4-fpm
systemctl enable --now nginx
systemctl enable --now cron
EOF
  ok "ct-web configure complete"
}

configure_ct_docker_web() {
  local id
  id=$(ct_field ct-docker-web id)
  step "ct-docker-web: install Docker + start stacks"
  require_named_ct ct-docker-web
  require_staged "$id" /var/www/feelin-it
  require_staged "$id" /var/www/compatibility
  require_staged "$id" /root/feelin-it.db
  if [ "$APPLY" -eq 1 ] && ! pct config "$id" 2>/dev/null | grep -q 'features:.*nesting=1'; then
    warn "CT $id lacks nesting=1; Docker may fail (recreate or pct set, then restart)"
  fi

  ct_script "$id" <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker volume create feelin-it_feelin-it-data
d=/var/lib/docker/volumes/feelin-it_feelin-it-data/_data
install -d -m 755 "$d"
for f in feelin-it.db feelin-it.db-shm feelin-it.db-wal; do
  if [ -f "/root/$f" ]; then cp -f "/root/$f" "$d/$f"; fi
done
chown -R 100:101 "$d"
[ -f "$d/feelin-it.db" ] && chmod 644 "$d/feelin-it.db" || true
(cd /var/www/feelin-it && docker compose up -d --build)
(cd /var/www/compatibility && docker compose up -d --build)
EOF
  ok "ct-docker-web configure complete"
}

configure_ct_jellyfin() {
  local id
  id=$(ct_field ct-jellyfin id)
  step "ct-jellyfin: install Jellyfin 12.2 and restore jellyfin.zip"
  require_named_ct ct-jellyfin
  require_staged "$id" /root/jellyfin.zip

  ct_script "$id" <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg procps
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/jellyfin.gpg
chmod a+r /etc/apt/keyrings/jellyfin.gpg
. /etc/os-release
echo "deb [signed-by=/etc/apt/keyrings/jellyfin.gpg] https://repo.jellyfin.org/ubuntu $VERSION_CODENAME main" > /etc/apt/sources.list.d/jellyfin.list
apt-get update
jf_version=$(apt-cache madison jellyfin-server | awk 'index($3, "12.2+") == 1 { print $3; exit }')
[ -n "$jf_version" ] || { echo "ct-jellyfin: no jellyfin 12.2 package found" >&2; exit 1; }
apt-get install -y "jellyfin=$jf_version" "jellyfin-server=$jf_version" "jellyfin-web=$jf_version"
apt-mark hold jellyfin jellyfin-server jellyfin-web
mkdir -p /var/lib/jellyfin/data/backups /etc/jellyfin /var/log/jellyfin /var/cache/jellyfin
chown -R jellyfin:jellyfin /var/lib/jellyfin /etc/jellyfin /var/log/jellyfin /var/cache/jellyfin
[ -r /media/jellyfin ] || { echo "ct-jellyfin: /media/jellyfin is not readable" >&2; exit 1; }
systemctl stop jellyfin || true
install -o jellyfin -g jellyfin -m 0644 /root/jellyfin.zip /var/lib/jellyfin/data/backups/jellyfin.zip
if [ -f /etc/default/jellyfin ]; then
  set -a
  . /etc/default/jellyfin
  set +a
fi
kill_restore_process() {
  pkill -P "$1" 2>/dev/null || true
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}
nohup runuser -u jellyfin -- /usr/bin/jellyfin \
  $JELLYFIN_WEB_OPT $JELLYFIN_FFMPEG_OPT $JELLYFIN_SERVICE_OPT \
  $JELLYFIN_NOWEBAPP_OPT $JELLYFIN_ADDITIONAL_OPTS \
  --restore-archive /var/lib/jellyfin/data/backups/jellyfin.zip \
  >/var/log/jellyfin-restore.log 2>&1 &
jf_pid=$!
restore_ok=0
for _ in $(seq 1 900); do
  if grep -q 'Restored Jellyfin system from' /var/log/jellyfin-restore.log; then restore_ok=1; break; fi
  if grep -q 'Error while starting server' /var/log/jellyfin-restore.log; then break; fi
  kill -0 "$jf_pid" 2>/dev/null || break
  sleep 1
done
if [ "$restore_ok" -ne 1 ]; then
  tail -n 50 /var/log/jellyfin-restore.log || true
  kill_restore_process "$jf_pid"
  echo "ct-jellyfin: restore from jellyfin.zip failed" >&2
  exit 1
fi
sleep 2
kill_restore_process "$jf_pid"
chown -R jellyfin:jellyfin /var/lib/jellyfin /etc/jellyfin /var/log/jellyfin /var/cache/jellyfin
systemctl reset-failed jellyfin || true
systemctl enable --now jellyfin
for _ in $(seq 1 60); do
  systemctl is-active --quiet jellyfin && break
  sleep 1
done
if ! systemctl is-active --quiet jellyfin; then
  journalctl -u jellyfin -n 50 --no-pager || true
  exit 1
fi
for _ in $(seq 1 60); do
  timeout 2 bash -c '</dev/tcp/127.0.0.1/8096' && break
  sleep 1
done
if ! timeout 2 bash -c '</dev/tcp/127.0.0.1/8096'; then
  journalctl -u jellyfin -n 50 --no-pager || true
  exit 1
fi
EOF
  ok "ct-jellyfin configure complete"
}

configure_ct_surveillance() {
  local id
  id=$(ct_field ct-surveillance id)
  step "ct-surveillance: install motion + motionEye"
  require_named_ct ct-surveillance
  require_staged "$id" /root/motioneye.tar.gz

  ct_script "$id" <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y motion ffmpeg python3-pip python3-dev libjpeg-dev libssl-dev libcurl4-openssl-dev libz-dev
systemctl disable --now motion || true
pip3 install --break-system-packages --pre 'motioneye==0.43.1b4'
tar -xzf /root/motioneye.tar.gz -C /
chown -R motion:motion /var/lib/motioneye /etc/motioneye /etc/motion 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now motioneye
EOF
  ok "ct-surveillance configure complete"
}

configure_ct_files() {
  local id
  id=$(ct_field ct-files id)
  step "ct-files: install Samba + recreate users"
  require_named_ct ct-files
  require_staged "$id" /root/smb.conf

  ct_script "$id" <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y samba
install -m 0644 /root/smb.conf /etc/samba/smb.conf
testparm -s >/dev/null
systemctl enable smbd nmbd
EOF

  ct_script "$id" <<'EOF'
set -e
getent group www-data >/dev/null || groupadd -g 33 www-data
if ! id wyatt >/dev/null 2>&1; then
  existing=$(getent passwd 1000 | cut -d: -f1 || true)
  if [ -n "$existing" ]; then
    usermod -g www-data -l wyatt "$existing"
    usermod -d /home/wyatt -m wyatt 2>/dev/null || true
  else
    useradd -u 1000 -g www-data -m -d /home/wyatt -s /bin/bash wyatt
  fi
fi
EOF

  if [ "$APPLY" -eq 1 ]; then
    load_secrets
    prompt_secret SMB_WYATT_PASSWORD "Samba password for wyatt"
    printf '%s\n%s\n' "$SMB_WYATT_PASSWORD" "$SMB_WYATT_PASSWORD" | ct_stdin "$id" smbpasswd -a -s wyatt
    ct_script "$id" <<'EOF'
set -e
systemctl enable --now smbd nmbd
testparm -s >/dev/null
pdbedit -L
EOF
  else
    printf '    %s[dry-run]%s set Samba password for wyatt from %s or prompt\n' "$C_YEL" "$C_RST" "$SECRETS_FILE"
    printf '    %s[dry-run]%s start smbd/nmbd and list Samba users\n' "$C_YEL" "$C_RST"
  fi
  ok "ct-files configure complete"
}

configure_one() {
  case "$1" in
    ct-db)           configure_ct_db ;;
    ct-web)          configure_ct_web ;;
    ct-docker-web)   configure_ct_docker_web ;;
    ct-jellyfin)     configure_ct_jellyfin ;;
    ct-surveillance) configure_ct_surveillance ;;
    ct-files)        configure_ct_files ;;
    all)
      configure_ct_db
      configure_ct_web
      configure_ct_docker_web
      configure_ct_jellyfin
      configure_ct_surveillance
      configure_ct_files
      ;;
    *) die "unknown container: $1 (use one of: ct-db ct-web ct-docker-web ct-jellyfin ct-surveillance ct-files all)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Phase: nginx-rewrite
# ---------------------------------------------------------------------------
# Convert server blocks that use `root /var/www/...` into HTTP proxies to ct-web.
rewrite_php_vhosts() {
  local file=$1 target=$2
  if [ "$APPLY" -eq 0 ]; then
    printf '    %s[dry-run]%s php->proxy rewrite %s => %s\n' "$C_YEL" "$C_RST" "$file" "$target"
    return 0
  fi
  python3 - "$file" "$target" <<'PY'
import re, sys

path, target = sys.argv[1], sys.argv[2]
text = open(path).read()

def matching(s, open_idx):
    depth = 0
    i = open_idx
    while i < len(s):
        if s[i] == '{':
            depth += 1
        elif s[i] == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1

def server_blocks(s):
    out = []
    for m in re.finditer(r'server\s*\{', s):
        ob = m.end() - 1
        cb = matching(s, ob)
        if cb != -1:
            out.append((m.start(), cb + 1))
    return out

def location_slash_blocks(s):
    out = []
    for m in re.finditer(r'location\s+/\s*\{', s):
        ob = m.end() - 1
        cb = matching(s, ob)
        if cb != -1:
            out.append((m.start(), cb + 1))
    return out

def transform(block):
    block = re.sub(r'(?m)^[ \t]*root\s+[^;]+;\s*\n', '', block)
    block = re.sub(r'(?m)^[ \t]*index\s+[^;]+;\s*\n', '', block)
    block = re.sub(r'(?m)^[ \t]*include\s+/etc/nginx/conf\.d/global/php\.conf;\s*\n', '', block)
    locs = location_slash_blocks(block)
    while locs:
        s, e = locs[0]
        block = block[:s] + block[e:]
        locs = location_slash_blocks(block)
    proxy = (
        "    location / {\n"
        f"        proxy_pass {target};\n"
        "        proxy_set_header Host $host;\n"
        "        proxy_set_header X-Real-IP $remote_addr;\n"
        "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n"
        "        proxy_set_header X-Forwarded-Proto $scheme;\n"
        "    }\n"
    )
    idx = block.rfind('}')
    return block[:idx] + proxy + block[idx:]

out = []
last = 0
for s, e in server_blocks(text):
    out.append(text[last:s])
    b = text[s:e]
    if re.search(r'root\s+/var/www', b):
        b = transform(b)
    out.append(b)
    last = e
out.append(text[last:])
open(path, 'w').write(''.join(out))
PY
}

rewrite_proxy_vhost() {
  local file=$1 target=$2
  if [ "$APPLY" -eq 0 ]; then
    printf '    %s[dry-run]%s proxy rewrite %s => %s\n' "$C_YEL" "$C_RST" "$file" "$target"
    return 0
  fi
  python3 - "$file" "$target" <<'PY'
import re, sys
path, target = sys.argv[1], sys.argv[2]
text = open(path).read()
text = re.sub(r'proxy_pass\s+http://[^;]+;', f'proxy_pass {target};', text)
open(path, 'w').write(text)
PY
}

phase_nginx_rewrite() {
  step "Rewrite host nginx vhosts to container upstreams"
  require_root
  require_pve
  [ -d /etc/nginx/sites-enabled ] || die "/etc/nginx/sites-enabled missing — run the host phase first"

  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  run cp -a /etc/nginx "/root/nginx.pre-rewrite-$stamp"

  local php_target="http://192.168.0.71"
  local f base target
  for f in /etc/nginx/sites-enabled/*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    target=""
    case "$base" in
      feelin-it)   target="http://192.168.0.72:3000" ;;
      compatible)  target="http://192.168.0.72:8082" ;;
      movies)      target="http://192.168.0.73:8096" ;;
    esac
    if [ -n "$target" ]; then
      rewrite_proxy_vhost "$f" "$target"
    else
      rewrite_php_vhosts "$f" "$php_target"
    fi
  done

  run nginx -t
  run systemctl restart nginx
  run certbot renew --dry-run
  ok "nginx rewrite complete"
}

# ---------------------------------------------------------------------------
# Phase: verify
# ---------------------------------------------------------------------------
phase_verify() {
  step "Verification"
  require_root

  if command -v pct >/dev/null 2>&1; then
    local i id name
    for i in "${!ct_names[@]}"; do
      id=${ct_ids[$i]}; name=${ct_names[$i]}
      if pct status "$id" >/dev/null 2>&1; then
        ok "CT $id ($name): $(pct status "$id" | awk '{print $2}')"
        if pct status "$id" | grep -q running; then
          test_binds "$id" "$(ct_binds "$name")"
        fi
      else
        warn "CT $id ($name): missing"
      fi
    done
  fi

  if [ -d /etc/nginx ]; then
    if nginx -t >/dev/null 2>&1; then ok "host nginx config valid"; else warn "host nginx config invalid"; fi
  fi

  local svc
  for svc in nginx stalwart wg-quick@wg0; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      ok "host service active: $svc"
    else
      warn "host service not active: $svc"
    fi
  done
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    warn "ufw is active; verify forwarding rules before exposing containers"
  fi

  local bind_src
  for bind_src in /nas /media/jellyfin /nas/Wyatt/vids; do
    if [ -d "$bind_src" ] && ! bind_on_data_disk "$bind_src"; then
      warn "placeholder bind in use: $bind_src (real drive not mounted)"
    fi
  done

  if command -v pct >/dev/null 2>&1; then
    local db_id web_id docker_id jelly_id surv_id files_id count code
    db_id=$(ct_field ct-db id); web_id=$(ct_field ct-web id)
    docker_id=$(ct_field ct-docker-web id); jelly_id=$(ct_field ct-jellyfin id)
    surv_id=$(ct_field ct-surveillance id); files_id=$(ct_field ct-files id)

    if pct status "$db_id" 2>/dev/null | grep -q running; then
      if pct exec "$db_id" -- mysqladmin ping --silent >/dev/null 2>&1; then
        ok "ct-db: MySQL responding"
        count=0
        count=$(pct exec "$db_id" -- mysql -u root -N -e 'SHOW DATABASES' 2>/dev/null | grep -Ev '^(information_schema|mysql|performance_schema|sys)$' | wc -l) || count=0
        if [ "$count" -ge 13 ]; then ok "ct-db: $count app databases"; else warn "ct-db: only $count app databases"; fi
      else
        warn "ct-db: MySQL not responding"
      fi
    fi

    if pct status "$web_id" 2>/dev/null | grep -q running; then
      if pct exec "$web_id" -- systemctl is-active --quiet nginx >/dev/null 2>&1; then
        ok "ct-web: nginx active"
      else
        warn "ct-web: nginx not active"
      fi
      code=$(pct exec "$web_id" -- curl -s -o /dev/null -w '%{http_code}' -H 'Host: cardinal-surveying.com' http://127.0.0.1/ 2>/dev/null || echo 000)
      case "$code" in
        2*|3*|4*) ok "ct-web: local HTTP $code" ;;
        *)        warn "ct-web: local HTTP $code" ;;
      esac
    fi

    if pct status "$docker_id" 2>/dev/null | grep -q running; then
      if pct exec "$docker_id" -- docker ps --format '{{.Names}}' 2>/dev/null | grep -q feelin-it; then
        ok "ct-docker-web: feelin-it container present"
      else
        warn "ct-docker-web: feelin-it container missing"
      fi
      if pct exec "$docker_id" -- docker ps --format '{{.Names}}' 2>/dev/null | grep -Eq 'compatibility-(web|api|db)|compatibility_'; then
        ok "ct-docker-web: compatibility containers present"
      else
        warn "ct-docker-web: compatibility containers missing"
      fi
    fi

    if pct status "$jelly_id" 2>/dev/null | grep -q running; then
      if pct exec "$jelly_id" -- bash -c 'timeout 5 bash -c "</dev/tcp/127.0.0.1/8096"' >/dev/null 2>&1; then
        ok "ct-jellyfin: :8096 listening"
      else
        warn "ct-jellyfin: :8096 not listening"
      fi
    fi

    if pct status "$surv_id" 2>/dev/null | grep -q running; then
      if pct exec "$surv_id" -- systemctl is-active --quiet motioneye >/dev/null 2>&1; then
        ok "ct-surveillance: motioneye active"
      else
        warn "ct-surveillance: motioneye not active"
      fi
      if pct exec "$surv_id" -- bash -c 'timeout 5 bash -c "</dev/tcp/127.0.0.1/8765"' >/dev/null 2>&1; then
        ok "ct-surveillance: :8765 listening"
      else
        warn "ct-surveillance: :8765 not listening"
      fi
    fi

    if pct status "$files_id" 2>/dev/null | grep -q running; then
      if pct exec "$files_id" -- systemctl is-active --quiet smbd >/dev/null 2>&1; then
        ok "ct-files: smbd active"
      else
        warn "ct-files: smbd not active"
      fi
      if pct exec "$files_id" -- testparm -s >/dev/null 2>&1; then
        ok "ct-files: Samba config valid"
      else
        warn "ct-files: Samba config invalid"
      fi
    fi
  fi

  if [ "$VERIFY_LIVE" -eq 1 ]; then
    log "Live HTTPS checks"
    local host
    for host in \
      cardinal-surveying.com admin.cardinal-surveying.com www.cardinal-surveying.com \
      wyattjohnson.net www.wyattjohnson.net mycars.wyattjohnson.net \
      gsjohnson.art www.gsjohnson.art money.wyattjohnson.net photos.wyattjohnson.net \
      classifieds.roundaboutperformance.com suspicion.wyattjohnson.net \
      sloppy-seconds.wyattjohnson.net web-dev.wyattjohnson.net \
      mail.wyattjohnson.net mail-admin.wyattjohnson.net \
      movies.wyattjohnson.net feelin-it.wyattjohnson.net compatible.wyattjohnson.net; do
      local code
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$host" || echo "000")
      case "$code" in
        2*|3*) ok "$host -> $code" ;;
        *)     warn "$host -> $code" ;;
      esac
    done
  fi

  cat <<EOF

${C_BOLD}Remaining manual checks:${C_RST}
  - Confirm both camera streams and that recordings land in /nas/Wyatt/vids/front
  - Confirm Jellyfin playback/transcoding and the media library
  - Confirm mail delivery, WireGuard peers, Samba clients, and cert renewal
  - If UFW is enabled, verify container forwarding before exposing services
Guides: $WORKDIR/
Log:    $LOG
EOF
  ok "verify phase complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local -a pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply)       APPLY=1; shift ;;
      --dry-run)     APPLY=0; shift ;;
      --yes|-y)      ASSUME_YES=1; shift ;;
      --pack)        PACK=$2; shift 2 ;;
      --storage)     STORAGE=$2; shift 2 ;;
      --template)    TEMPLATE=$2; shift 2 ;;
      --bridge)      BRIDGE=$2; shift 2 ;;
      --only)        ONLY=$2; shift 2 ;;
      --log)         LOG=$2; shift 2 ;;
      --secrets)     SECRETS_FILE=$2; shift 2 ;;
      --verify-live) VERIFY_LIVE=1; shift ;;
      --require-mounts) REQUIRE_MOUNTS=1; shift ;;
      --apt-repos)   APT_REPOS=$2; shift 2 ;;
      --help|-h)     usage; exit 0 ;;
      --)            shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
      -*)            die "unknown option: $1 (see --help)" ;;
      *)             pos+=("$1"); shift ;;
    esac
  done

  CMD="${pos[0]:-help}"
  case "$CMD" in
    help) usage; exit 0 ;;
  esac
  if [ "$CMD" = "restore" ] || [ "$CMD" = "configure" ]; then
    ONLY="${ONLY:-${pos[1]:-all}}"
  fi

  require_root
  init_log

  case "$CMD" in
    preflight)     phase_preflight ;;
    fix-repos)     phase_fix_repos ;;
    host)          phase_host ;;
    create)        phase_create ;;
    restore)       restore_one "$ONLY" ;;
    configure)     configure_one "$ONLY" ;;
    nginx-rewrite) phase_nginx_rewrite ;;
    verify)        phase_verify ;;
    all)
      phase_preflight
      phase_host
      phase_create
      restore_one all
      configure_one all
      phase_nginx_rewrite
      phase_verify
      ;;
    *) die "unknown phase: $CMD (see --help)" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
