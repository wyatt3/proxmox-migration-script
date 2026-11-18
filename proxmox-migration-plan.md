# Proxmox Migration Runbook — Wyatt's Home Server ("arceus")

**Goal:** Rebuild the bare-metal Ubuntu 24.04 server (`wyattjohnson.net`, 192.168.0.69) as a Proxmox VE host with LXC containers, reaching **full feature parity** with the current setup. Nothing is changed on the live box until you're ready to cut over.

## 0. Decisions to confirm (all marked as the working assumptions)

- [ ] **Networking — Design A:** containers are bridged to the LAN (`vmbr0`) with real IPs `192.168.0.70–.75`. Host keeps `.69`.
- [ ] **Samba** runs in container `ct-files` at `192.168.0.75`; LAN clients re-point `\\192.168.0.69\nas` → `\\192.168.0.75\nas`. Samba passwords are **not** in the pack; supply them via `/root/migration-secrets.env` or the configure prompt.
- [ ] **UFW:** add host rules only; leave UFW disabled until LXC forwarding/NAT is configured.
- [ ] **Database users:** `public_user` is the shared app user; `wyattjohnson` → `portfolio`, `roundabout` → `nyoom`. The dump’s `mysql` system DB is filtered out on import.
- [ ] **2 router port-forwards** change to container IPs: `8096→.73`, `8765→.74`. All other forwards stay at `.69`.
- [ ] **All LXC containers run privileged** on an **Ubuntu 24.04 template** (matches PHP 8.4 / MySQL 8 and keeps bind-mount ownership 1:1). `.76` is left free.
- [ ] **`ct-docker-web` (.72)** hosts both Docker stacks: Feelin' It (`:3000`) and compatibility (`:8082`, internal API `:3005`).
- [ ] **No local DNS resolver** — dnsmasq is not running on the current box, so none is migrated; router/DNS behavior stays as today.
- [ ] **Decommission:** TF2 + Minecraft containers (and `/home/wyatt/mc` data), LXD snap. **Keep everything else** (incl. all 13 app MySQL DBs; the `mysql` system DB is filtered out during import).
- [ ] `Camera3` recordings are deleted manually before migration (motionEye recreates the dir).

## 1. Current state (the parity baseline)

### Services
| Service | Ports | Where it lives today | Move to |
|---|---|---|---|
| nginx (TLS reverse proxy, 17 vhosts) + certbot | 80/443 | host | **Proxmox host** |
| WireGuard VPN (6 peers, `10.0.0.1/24`) | 51820/udp | host | **Proxmox host** |
| Stalwart mail (`mail.wyattjohnson.net`) | 25,110,143,465,587,993,995,4190,8080 | host `/opt/stalwart` | **Proxmox host** |
| MySQL 8 (13 app DBs + system DB) | 3306 | host | `ct-db` (.70), LAN-only |
| PHP-FPM 8.4 + nginx (Laravel apps, Roundcube, static) | — | host | `ct-web` (.71) |
| Feelin' It (Nuxt, SQLite) | 3000 | Docker | `ct-docker-web` (.72) |
| Compatibility (Docker: web/api/MySQL 8) | 8082, 3005 | Docker | `ct-docker-web` (.72) |
| Jellyfin | 8096 | host | `ct-jellyfin` (.73) |
| motionEye + motion (2 IP cameras) | 8765, 9081, 9082 | host | `ct-surveillance` (.74) |
| Samba `[nas]` | 139/445 | host | `ct-files` (.75) |
| SSH | 22 | host | Proxmox host |

### Web apps ↔ DB ↔ repo
| Site | App dir | DB | Git remote (rebuild source) |
|---|---|---|---|
| cardinal-surveying.com / admin / www | `/var/www/cardinal` | `cardinal` | `github.com/wyatt3/cardinal` |
| wyattjohnson.net | `/var/www/wyattjohnson` | `portfolio` (`public_user`) | `github.com/wyatt3/portfolio` |
| mycars.wyattjohnson.net | `/var/www/gas-mileage` | `GMR` | **no remote — copy manually** |
| gsjohnson.art | `/var/www/gsjohnson` | `gsjohnson` | `github.com/wyatt3/gs-johnson` |
| money.wyattjohnson.net | `/var/www/money` | `spending_money` | `github.com/wyatt3/spending-money` |
| photos.wyattjohnson.net | `/var/www/photos` | `photos` | `github.com/wyatt3/photo-portfolio` |
| classifieds.roundaboutperformance.com | `/var/www/roundabout` | `nyoom` (`public_user`) | `github.com/Roundabout-Performance/roundabout_classifieds` |
| suspicion.wyattjohnson.net | `/var/www/suspicionGameBoard` | — | `github.com/wyatt3/suspicionGameBoard` |
| sloppy-seconds.wyattjohnson.net | `/var/www/sloppy-seconds` | `sloppy` | `github.com/wyatt3/SloppySeconds` |
| web-dev.wyattjohnson.net | `/var/www/web-dev-examples` | — | copy manually |
| mail.wyattjohnson.net | `/var/www/webmail` (Roundcube) | `roundcubemail` | copy manually |
| mail-admin.wyattjohnson.net | → Stalwart :8080 | — | host |
| movies.wyattjohnson.net | → Jellyfin :8096 | — | ct-jellyfin |
| compatible.wyattjohnson.net | `/var/www/compatibility` (Docker) | own MySQL container | `github.com/wyatt3/compatibility` |
| feelin-it.wyattjohnson.net | Docker Nuxt | `feelin-it.db` | `github.com/wyatt3/Feelin-It` |

### Crontabs (must survive)
Host (`IP-Monitor`):
```
0 * * * *  python3 /home/wyatt/IP-Monitor/main.py >> /dev/null 2>&1
```
`ct-web` (Laravel schedulers):
```
* * * * * php /var/www/roundabout/artisan schedule:run >> /dev/null 2>&1
* * * * * php /var/www/money/artisan schedule:run >> /dev/null 2>&1
```

## 2. Target architecture

```
Internet
   │ (public IPv4 136.59.2.86 → router NAT)
   │
Router 192.168.0.1 ── forwards: 80,443,25,110,143,465,587,993,995,4190,8080,51820 → 192.168.0.69
   │                    8096 → .73 · 8765 → .74
   │
vmbr0 (bridged, enp5s0)
   ├── Proxmox host 192.168.0.69   ← nginx+certbot, wireguard, stalwart, ssh, crontab
   ├── ct-db         192.168.0.70  ← MySQL
   ├── ct-web        192.168.0.71  ← nginx+php-fpm, all PHP apps + Roundcube
   ├── ct-docker-web 192.168.0.72  ← Docker: feelin-it :3000, compatibility :8082
   ├── ct-jellyfin   192.168.0.73  ← Jellyfin (bind /media/jellyfin)
   ├── ct-surveillance 192.168.0.74 ← motionEye (bind /nas/Wyatt/vids)
   └── ct-files      192.168.0.75  ← Samba (bind /nas)

Storage:
   NVMe 256G  → Proxmox root + container root disks (lvm-thin)
   sda 1T     → /nas        bind: ct-files (rw), ct-surveillance (rw)
   sdb 2T     → /media/jellyfin  bind: ct-jellyfin (rw)
```

## 3. Resource budget (16GB RAM / 12 threads)
| Guest | RAM | Cores | Disk | Notes |
|---|---|---|---|---|
| Proxmox host | ~2.5G | 2 | 40G | nginx/stalwart/wg/cron |
| ct-db | 1.5G | 2 | 4G | MySQL |
| ct-web | 1.5G | 2 | 8G | php apps + Roundcube |
| ct-docker-web | 2G | 2 | 10G | Docker: feelin-it + compatibility |
| ct-jellyfin | 2G | 4 | 4G | software transcode |
| ct-surveillance | 1G | 3 | 4G | 2 cams @1080p30 (~56% core) |
| ct-files | 0.25G | 1 | 1G | Samba |
| **Total** | **~10.8G** | | | ~5.2G freed headroom |

Peak-risk: Jellyfin transcode + 2 camera streams simultaneously can saturate 12 threads — CPU limits above are deliberate.

## 4. Phase 1 — Build the migration pack (on the live box)

Create `/nas/migration-pack` on the 1T drive (`create-migration-pack.sh`). Copy:
- [ ] `/var/www/*` (all app dirs, incl. `.env`, `storage/`) — for gas-mileage, web-dev-examples, webmail, suspicion this is the **only** source
- [ ] MySQL: `mysqldump -u root -p --all-databases > all-databases.sql` (preserves users + all 13 app DBs; the restore/configure scripts skip the `mysql` system DB)
- [ ] `/etc/nginx/` (sites-available, sites-enabled, conf.d, snippets)
- [ ] `/etc/letsencrypt/` (live, archive, renewal, accounts)
- [ ] `/etc/wireguard/` (wg0.conf, server_*.key, clients/)
- [ ] `/opt/stalwart/` (bin, etc, data, logs)
- [ ] `/etc/samba/smb.conf`
- [ ] `/var/lib/motioneye/` (Camera1, Camera2 — Camera3 excluded) + `/etc/motioneye/`
- [ ] `/var/lib/jellyfin/` (metadata, config, data — optional but preserves libraries/plugins)
- [ ] `/home/wyatt/.ssh/`, `/home/wyatt/.git-credentials`, `/var/www/.ssh/` (deploy keys for `wyatt3` repos)
- [ ] `/home/wyatt/IP-Monitor/` + crontab: `sudo crontab -l > root.cron`
- [ ] `/var/lib/docker/volumes/feelin-it_feelin-it-data/_data/` (feelin-it.db)
- [ ] `/etc/hosts`, `/etc/fstab` (reference), `.env` files, notes

> The compatibility MySQL volume (`compatibility_mysql-data`) is **intentionally not backed up** — that stack starts with a fresh DB after migration.

## 5. Phase 2 — Install Proxmox VE

1. Create Proxmox VE 8.x installer USB.
2. Boot it; **install ONLY to the NVMe (256GB)** — double-check the installer targets `nvme0n1`, never `sda`/`sdb` (data disks stay untouched).
3. Layout on NVMe: ext4/xfs root (~40–60G) + `lvm-thin` (or ZFS) for container images.
4. Hostname `arceus` (must match `/etc/hosts`), static IP `192.168.0.69/24`, gw `192.168.0.1`.
5. Post-install: `apt update && apt dist-upgrade`, set timezone, join DNS (`/etc/resolv.conf` → 8.8.8.8).

## 6. Phase 3 — Host edge services (on Proxmox, keeps .69)

### Networking & storage
- [ ] `/etc/network/interfaces`: create `vmbr0` bridging `enp5s0` (host keeps `.69`).
- [ ] Mount data disks in `/etc/fstab` (same UUIDs as today):
  - `UUID=bdb80da4-0405-431c-8248-619ec5c04273 /nas ext4 rw 0 2`
  - `UUID=12751a0b-1f43-47f9-b09c-f975a449f74d /media/jellyfin ext4 defaults,nofail 0 2`
- [ ] Proxmox → Datacenter → Storage: add `/nas` and `/media/jellyfin` as **Directory** storages (used later for bind mounts).

### Packages & services
```bash
apt install nginx certbot python3-certbot-nginx wireguard-tools curl \
  python3-requests python3-dotenv
```
- [ ] **nginx + certs:** restore `/etc/nginx/` + `/etc/letsencrypt/` from migration pack. Enable and start `certbot.timer`; do not start nginx until the CTs are configured and `nginx-rewrite` runs.
- [ ] **DNS:** no local resolver exists today (systemd-resolved listens only on loopback); nothing to restore — LAN DNS stays on the router.
- [ ] **WireGuard:** restore `/etc/wireguard/`, rewrite `-o enp5s0` in `wg0.conf` to the detected default interface, ensure `net.ipv4.ip_forward=1`, then `systemctl enable --now wg-quick@wg0` (verify 6 peers).
- [ ] **Stalwart:** restore `/opt/stalwart/`, create system user `stalwart`, and extract the systemd unit from `stalwart.tar.gz` (`etc/systemd/system/stalwart.service`). Enable on boot. Disable `postfix`/`exim4`/`sendmail` if present. Preserves IPv6 mail listeners too.
- [ ] **Samba** runs in `ct-files` — do not install it on the host.
- [ ] **Host user/home:** create `wyatt` with uid 1000/gid 33 (`www-data`), no automatic sudo; restore `/home/wyatt/.ssh`, `.gitconfig`, `.git-credentials`, and `IP-Monitor/` from the pack. Set `.ssh` to 700 and private keys/credential files to 600.
- [ ] **crontab:** split `root.cron` — keep only the `IP-Monitor` line on the host; stage the two `/var/www/...` scheduler lines for `ct-web`. Verify `IP-Monitor/main.py` path + `.env`.
- [ ] **`/etc/hosts`:** add `127.0.0.1 mail.wyattjohnson.net` (as today).
- [ ] **UFW** (host, `192.168.0.69`): add rules for `22, 80, 443, 25, 110, 143, 465, 587, 993, 995, 4190, 8080, 51820/udp, 139/445`, plus `3306/tcp` only from `192.168.0.0/24`. **Leave UFW disabled** until LXC forwarding/NAT is configured; enabling default-deny forwarding will break container traffic.
- [ ] **Bind sources:** mount `/nas` (1T) and `/media/jellyfin` (2T) with the same UUIDs; use `--require-mounts` on the real host.

## 7. Phase 4 — Create the LXC containers

Proxmox → local (lvm-thin) → CTs, **Ubuntu 24.04 template, all privileged** (simple 1:1 bind-mount ownership). IPs must be reserved/free on the LAN.

| CT | IP | RAM | Cores | Disk | Extra |
|---|---|---|---|---|---|
| ct-db | .70 | 1.5G | 2 | 4G | — |
| ct-web | .71 | 1.5G | 2 | 8G | — |
| ct-docker-web | .72 | 2G | 2 | 10G | `features: nesting=1,keyctl=1` (Docker) |
| ct-jellyfin | .73 | 2G | 4 | 4G | bind `/media/jellyfin` |
| ct-surveillance | .74 | 1G | 3 | 4G | bind `/nas/Wyatt/vids` |
| ct-files | .75 | 0.25G | 1 | 1G | bind `/nas` (rw) |

Bind mounts via `/etc/pve/lxc/<id>.conf` `mp0:` entries. All containers are privileged, so file ownership under `/nas`, `/media/jellyfin`, etc. maps 1:1. Still test a read/write on each mount before going further.

**Data disks / staging:** `setup-from-migration-pack.sh` defaults to *permissive* mounts — if `/nas`, `/media/jellyfin`, or `/nas/Wyatt/vids` is missing it creates an empty placeholder directory and skips the mount, so the full create run can be rehearsed on a staging PVE host without the 1T/2T disks attached (use `--pack` if `/nas/migration-pack` isn't there). On the real host, run `preflight`/`create` with `--require-mounts` to fail unless the disks are actually mounted. Mount the real disks before storing data; placeholder binds write to the NVMe root instead.

Each CT: set DNS to the router (`192.168.0.1`) and allow SSH.

### Automated path

`setup-from-migration-pack.sh` has two per-container phases:
- `restore <ct|all>` — stage the pack inside the CT and write a manual guide.
- `configure <ct|all>` — install packages, import data, rewrite configs, enable services.

One-shot on the real host:
```bash
sudo ./setup-from-migration-pack.sh all --apply --require-mounts \
  --secrets /root/migration-secrets.env
```
`all` runs `preflight → host → create → restore all → configure all → nginx-rewrite → verify`. Use `--dry-run` (default) first, and omit `--require-mounts` on a staging host without the data disks.

Samba passwords are not in the pack. Put them in `/root/migration-secrets.env`:
```bash
SMB_WYATT_PASSWORD='...'
SMB_SMBUSER_PASSWORD='...'
```
(`chmod 600`). `configure ct-files` prompts securely if the file/values are missing.

## 8. Phase 5 — Restore and configure services per container

### ct-db (.70) — MySQL 8
- Install `mysql-server` 8 (the dump uses MySQL 8 auth; do **not** use MariaDB).
- Bind to `192.168.0.70` (not `*`): `bind-address=192.168.0.70` in mysqld.cnf. Restrict `3306` to the LAN.
- The configure phase filters `all-databases.sql` so the `mysql` system DB (and the fresh root/debian accounts) is **not** overwritten, imports the 13 app DBs, then applies `mysql-create-users.sql` / `mysql-grants.sql` (minus `GRANT PROXY` and the stale `iworq` grants).
- `public_user@%` is the shared app user. `configure` resets it to the password in `cardinal/.env` and grants ALL on `portfolio` and `nyoom`.
- Create remote `roundcube@192.168.0.%` from the password in `webmail/config/config.inc.php`; `roundcube@localhost` remains for old-host compatibility.
- Verify all 13 app DBs: `GMR`, `cardinal`, `gasMileage`, `gsjohnson`, `laravel_final`, `nyoom`, `photos`, `portfolio`, `roundcubemail`, `sloppy`, `spending_money`, `vintagetreasures`, `young_ward`.

### ct-web (.71) — nginx + php-fpm 8.4 + apps
- Apt installs nginx, PHP 8.4 from `ppa:ondrej/php` (mysql/mbstring/xml/curl/zip/gd/intl/bcmath/sqlite3/opcache/readline), composer, git, unzip, curl.
- `/var/www` is restored from the pack; composer runs only when `vendor/autoload.php` is missing. Then `config:clear`, `storage:link`, `chown -R www-data:www-data /var/www`, install `ct-web.cron`, and start php8.4-fpm + nginx.
- **.env change for every Laravel app:** `DB_HOST=192.168.0.70` (was `127.0.0.1`). Includes `sloppy-seconds` (DB `sloppy`).
- **wyattjohnson / roundabout:** switch `DB_USERNAME` to `public_user` and copy the exact `DB_PASSWORD` line from `cardinal/.env`.
- nginx inside ct-web serves each app on its server_name over `:80` (generated `server_name → root → fastcgi` blocks); host nginx proxies to it.
- **Roundcube:** set `$config['db_dsnw']` host → `192.168.0.70`; set `imap_host` `localhost:143` → `192.168.0.69:143`; in ct-web `/etc/hosts` add `192.168.0.69 mail.wyattjohnson.net` so Roundcube reaches Stalwart on the host.
- Static sites (web-dev-examples, suspicion, html) served from ct-web.

### ct-docker-web (.72) — Docker: Feelin' It + compatibility
- LXC `features: nesting=1,keyctl=1`; install Docker CE + compose plugin.
- Stage `/var/www/feelin-it` and `/var/www/compatibility`; create volume `feelin-it_feelin-it-data`, copy `feelin-it.db`, `-shm`, and `-wal`, then `chown -R 100:101` (the app runs as uid 100/gid 101).
- `docker compose up -d --build` for feelin-it (`:3000`) and compatibility (web `:8082`, api `:3005`).
- Compatibility MySQL starts fresh (no data backup by design).

### ct-jellyfin (.73)
- Install Jellyfin; restore `/var/lib/jellyfin` (libraries, plugins, metadata); ensure bind mount `/media/jellyfin` visible; service runs as `jellyfin` (privileged CT, so the bind owner maps 1:1).

### ct-surveillance (.74) — motionEye
- Install motion + ffmpeg + pip build deps; install `motioneye==0.43.1b4` with pip. Disable the distro `motion.service` to avoid camera conflicts.
- Restore `/etc/motioneye/` (camera-1, camera-2, masks), `/etc/motion/`, `/var/lib/motioneye/`, and the `motioneye.service` unit **inside the CT**.
- Bind mount `/nas/Wyatt/vids` (camera-2 target `.../vids/front`).
- Cameras are network RTSP — only LAN reachability needed.
- Open `8765, 9081, 9082` on the container's firewall.
- Restart service; confirm live streams + recordings.

### ct-files (.75) — Samba
- Install samba; restore `smb.conf` (`[nas]` share → `/nas`).
- Recreate users: `wyatt` uid 1000/gid 33 and `smbuser` uid 997/gid 997 (nologin). Set Samba passwords from `/root/migration-secrets.env` or a secure prompt; the pack does not contain them.
- Open `139, 445`.

## 9. Phase 6 — Rewrite host nginx vhosts to container upstreams

Host nginx stays the TLS/ACME edge (certs unchanged). Per vhost, swap upstreams:

| vhost | today | new target |
|---|---|---|
| feelin-it | `proxy_pass http://127.0.0.1:3000` | `http://192.168.0.72:3000` |
| compatible | `proxy_pass http://127.0.0.1:8082` | `http://192.168.0.72:8082` |
| movies | `proxy_pass http://192.168.0.69:8096` | `http://192.168.0.73:8096` |
| mail-admin | `proxy_pass http://127.0.0.1:8080` | unchanged (stalwart on host) |
| all PHP apps (cardinal, wyattjohnson, mycars, gsjohnson, money, photos, roundabout, suspicion, sloppy-seconds, web-dev, mail/Roundcube) | local root + `fastcgi_pass unix:...php8.4-fpm.sock` | `proxy_pass http://192.168.0.71` (per server_name) |
| default /.well-known | `proxy_pass http://127.0.0.1:8080` | unchanged (or switch to webroot) |

- [ ] `nginx -t && systemctl reload nginx` (the script restarts nginx)
- [ ] Run `certbot renew --dry-run` to confirm renewal still works from host.
- [ ] Automated equivalent: `sudo ./setup-from-migration-pack.sh nginx-rewrite --apply`
- [ ] Then run `sudo ./setup-from-migration-pack.sh verify --apply --verify-live` (or just `verify --verify-live`; it is read-only).

## 10. Phase 7 — Router & LAN changes
- [ ] Reserve `.70–.75` in router DHCP (static leases).
- [ ] Port-forwards: keep everything → `.69`; change only `8096 → 192.168.0.73`, and (if used) `8765 → 192.168.0.74`.
- [ ] (Optional) reconfigure LAN clients: `\\192.168.0.69\nas` → `\\192.168.0.75\nas`. DNS stays on the router (unchanged).

## 11. Phase 8 — Feature-parity verification checklist

**Web (each of the 17 vhosts over https, valid cert):**
- [ ] cardinal-surveying.com, admin.cardinal-surveying.com, www.cardinal-surveying.com
- [ ] wyattjohnson.net / www
- [ ] mycars, money, photos, suspicion, sloppy-seconds, web-dev, feelin-it, compatible, movies
- [ ] gsjohnson.art / www
- [ ] classifieds.roundaboutperformance.com
- [ ] mail.wyattjohnson.net (Roundcube login) + mail-admin.wyattjohnson.net

**Mail:** [ ] send+receive via SMTP/IMAP, [ ] Roundcube, [ ] Stalwart admin, [ ] Sieve 4190
**LAN/network:** [ ] router DNS resolves hosts as today, [ ] Samba share works, [ ] all 6 WireGuard peers connect
**Apps/data:** [ ] every Laravel app CRUD against ct-db, [ ] all 13 app DBs, [ ] Feelin' It + push notifications, [ ] compatibility stack (fresh DB)
**Media:** [ ] Jellyfin plays media, [ ] movies.wyattjohnson.net
**Cameras:** [ ] both live streams (9081/9082), [ ] motion recording to `/nas/Wyatt/vids/front` + Camera1 dir
**Cron:** [ ] `ip.txt` updates hourly, [ ] roundabout + money schedulers run

## 12. Decommission (after verification)
- [ ] Stop/remove TF2 + Minecraft (`mc-mc-1`) containers + images, delete `/home/wyatt/mc` on old box
- [ ] Remove LXD snap (`snap remove lxd` then core20/core22)
- [ ] Camera3 files already deleted by you; ensure they don't come back via motionEye (no config exists)

## 13. Notes & risks
- **16GB RAM is the ceiling** — watch swap; disabling Jellyfin 4K transcodes if needed. (Removing Minecraft frees ~5G.)
- **No GPU** — Jellyfin transcodes on CPU (i7-5820K).
- **Bind mounts** are simple here (all CTs privileged, 1:1 ownership) — still test before trusting any mount.
- **gas-mileage / web-dev-examples / webmail / suspicion** have no git remote (or aren't redeployable from GitHub) — the migration pack is their only source; back them up twice.
- **Compatibility DB is not migrated** (no backup by design); its Docker stack starts with an empty database.
- **No local DNS resolver** today (no dnsmasq); the plan intentionally does not add one.
- Old cruft not carried over: open-vm-tools, vgauth, cloud-init, masked NetworkManager/irqbalance, php8.1/8.2 masks, wpa_supplicant.
- MySQL gains a real security improvement: bound to ct-db and restricted to the LAN (was `*:3306`).
- Rollback: Proxmox lives only on the NVMe; the two HDDs are never modified, so reverting to the old disk state is always possible via the safety image in §4.
