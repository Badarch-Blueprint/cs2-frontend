# CS2 LAN Tournament Orchestrator

Production-oriented Docker infrastructure for running multiple Counter-Strike 2 dedicated servers on a single Ubuntu host for LAN tournaments.

Servers are managed dynamically: start a match, get a server. When all slots are full, new matches queue automatically and start as soon as a slot frees up. No manual port juggling or service duplication needed.

> **Admin testing:** for a quick guide on promoting yourself to admin and driving the
> full tournament flow from the UI, see [`docs/admin-testing.md`](docs/admin-testing.md).

## What This Repository Contains

- `Dockerfile`
  Runtime image based on `debian:bullseye-slim` with CS2 runtime dependencies and the container entrypoint.
- `entrypoint.sh`
  Builds the per-container writable overlay and launches the CS2 dedicated server.
- `install_cs2.sh`
  Host-side installer for SteamCMD, CS2 dedicated server, Metamod:Source, CounterStrikeSharp, MatchZy, TBAntiCheat, WeaponPaints (+ its deps: MenuManager, PlayerSettings, AnyBaseLib), SSD swap, and optional CS2 AntiCheat Defense.
- `docker-compose.yml`
  Image build only. All server lifecycle is handled by `cs2-server-manager.sh`.
- `docker-compose.platform.yml`
  Persistent services that run on the **platform host** (same box as Postgres + NestJS) — currently the `weaponpaints-mysql` backing store for the skin-changer plugin.
- `sql/weaponpaints-catalog/`
  Postgres DDL + a generator script that builds a read-only catalog of every skin/glove/agent/music/keychain/sticker/collectible for the NestJS backend to consume.
- `cs2-server-manager.sh`
  Dynamic server pool manager. Allocates server slots on demand, enforces a configurable concurrency cap, queues excess matches, and auto-starts queued matches when running ones finish.
- `match-event-handler.py`
  Lightweight HTTP server that receives MatchZy webhook events from containers. Saves match results and triggers container cleanup when matches end.

## Architecture

```text
Mac dev machine
  -> edit files locally
  -> push to GitHub or copy to Ubuntu host

Ubuntu host PC
  -> install_cs2.sh        (one-time: SteamCMD + CS2 + plugins + swap)
  -> docker compose build   (one-time: build container image)
  -> cs2-server-manager.sh  (runtime: start/stop/status/watch)

/opt/cs2/
  -> shared/               (single CS2 install, read-only for containers)
  -> servers/slot-0..10/   (per-slot writable state: configs, logs, demos)
  -> orchestrator/         (slot tracking + match queue)
  -> steamcmd/

Dynamic pool (max 11 concurrent):
  Slot 0  -> game:27015  tv:27115
  Slot 1  -> game:27016  tv:27116
  ...
  Slot 10 -> game:27025  tv:27125
```

## Supported Host Environment

- Ubuntu 24.04 LTS (local PC or headless server)
- x86_64 hardware
- 32 GB or 48 GB RAM
- Docker Engine
- Docker Compose plugin
- Internet access for SteamCMD and release downloads

This project is not intended to run directly on macOS. Your Mac is the authoring machine; the Ubuntu host is the runtime machine.

## Step 1: Prepare The Repo On Your Mac

From your Mac:

```bash
cd "/Users/houtarou/Documents/private/cs2-tournament-backend"
git init
git add .
git commit -m "Initial CS2 LAN tournament infrastructure"
```

If this is already a git repository, skip `git init` and just commit normally.

## Step 2: Create And Push To GitHub

Create a new empty GitHub repository, then run one of the following on your Mac.

### HTTPS remote

```bash
git remote add origin https://github.com/YOUR_USERNAME/cs2-tournament-backend.git
git branch -M main
git push -u origin main
```

### SSH remote

```bash
git remote add origin git@github.com:YOUR_USERNAME/cs2-tournament-backend.git
git branch -M main
git push -u origin main
```

## Step 3: Prepare The Ubuntu Host

Open a terminal on your Ubuntu PC (or SSH in if it is headless).

Update the host:

```bash
sudo apt update && sudo apt upgrade -y
```

Install required packages:

```bash
sudo apt install -y docker.io docker-compose-plugin git
```

Enable Docker:

```bash
sudo systemctl enable --now docker
```

Optional: allow your user to run Docker without `sudo`:

```bash
sudo usermod -aG docker $USER
```

Then log out and back in so the group change takes effect.

Verify:

```bash
docker --version
docker compose version
```

## Step 4: Get The Project Onto The Host

### Option A: Clone from GitHub

```bash
mkdir -p ~/projects
cd ~/projects
git clone https://github.com/YOUR_USERNAME/cs2-tournament-backend.git
cd cs2-tournament-backend
```

### Option B: Copy directly from your Mac

Using rsync:

```bash
rsync -avz "/Users/houtarou/Documents/private/cs2-tournament-backend/" youruser@your-host-ip:~/projects/cs2-tournament-backend/
```

Or use a USB drive, shared folder, or any other transfer method.

## Step 5: Make Scripts Executable

On the Ubuntu host:

```bash
chmod +x install_cs2.sh entrypoint.sh cs2-server-manager.sh match-event-handler.py
```

## Step 6: Run The Host Installer

```bash
sudo bash install_cs2.sh
```

What it does:

- installs host dependencies (`curl`, `wget`, `lib32gcc-s1`, `unzip`, `tar`)
- installs SteamCMD into `/opt/cs2/steamcmd`
- downloads the CS2 dedicated server into `/opt/cs2/shared`
- downloads and extracts Metamod:Source, CounterStrikeSharp, MatchZy, and TBAntiCheat
- optionally installs CS2 AntiCheat Defense if `CS2_ACD_URL` is provided
- patches `gameinfo.gi` for Metamod
- creates a 16 GB SSD swap file and sets `vm.swappiness=10`
- creates 11 server slot directories under `/opt/cs2/servers/slot-{0..10}`
- creates orchestrator state directory at `/opt/cs2/orchestrator/`

### Optional: CS2 AntiCheat Defense

If you have a direct download URL for the plugin:

```bash
export CS2_ACD_URL="https://your-download-url/plugin.zip"
sudo -E bash install_cs2.sh
```

If you do not set `CS2_ACD_URL`, the script skips that plugin and prints the manual install path.

## Step 7: Build The Docker Image

```bash
docker compose build
```

This builds the `cs2-server-latest` image from the `Dockerfile`.

## Step 8: Manage Matches

All server lifecycle is handled by `cs2-server-manager.sh`.

### Start a match

```bash
./cs2-server-manager.sh start group-a-match-1
```

With a specific map:

```bash
./cs2-server-manager.sh start group-a-match-1 --map de_inferno
```

If there is a free slot, the server starts immediately. If all slots are occupied, the match is queued and starts automatically when a slot frees up.

### Stop a match

```bash
./cs2-server-manager.sh stop group-a-match-1
```

This stops the container, frees the slot, and auto-starts the next queued match if there is one.

### Check status

```bash
./cs2-server-manager.sh status
```

Shows all active servers (slot, match-id, ports, start time) and the queue.

### Run the watcher daemon

```bash
./cs2-server-manager.sh watch
```

Listens for container exit events. When a match ends (server process exits), it automatically frees the slot and starts the next queued match. Run this in a `tmux` or `screen` session during the tournament.

### Stop everything

```bash
./cs2-server-manager.sh stop-all
```

Stops all running servers and clears the queue.

## Tournament Day Workflow

A typical tournament day looks like this:

```bash
# 1. Start the watcher in a tmux session
tmux new -s cs2-watcher
./cs2-server-manager.sh watch
# (detach with Ctrl+B, D)

# 2. Start matches as needed
./cs2-server-manager.sh start ga-r1-m1 --map de_mirage
./cs2-server-manager.sh start ga-r1-m2 --map de_inferno
./cs2-server-manager.sh start gb-r1-m1 --map de_dust2
./cs2-server-manager.sh start gb-r1-m2 --map de_anubis
./cs2-server-manager.sh start gc-r1-m1 --map de_mirage
./cs2-server-manager.sh start gc-r1-m2 --map de_nuke
./cs2-server-manager.sh start gd-r1-m1 --map de_ancient
./cs2-server-manager.sh start gd-r1-m2 --map de_inferno
./cs2-server-manager.sh start gd-r1-m3 --map de_mirage

# 3. Check status anytime
./cs2-server-manager.sh status

# 4. If you need to manually stop a match
./cs2-server-manager.sh stop ga-r1-m1

# 5. Queue the next round -- if slots are full, they wait
./cs2-server-manager.sh start ga-r2-m1 --map de_vertigo
./cs2-server-manager.sh start ga-r2-m2 --map de_ancient

# 6. When matches end naturally, the watcher frees slots and
#    auto-starts queued matches. No manual intervention needed.
```

## Port Layout

Each server slot gets a unique game port and CSTV port with a 100-offset gap to avoid collisions:

| Slot | Game Port | CSTV Port |
| ---- | --------- | --------- |
| 0    | 27015     | 27115     |
| 1    | 27016     | 27116     |
| 2    | 27017     | 27117     |
| 3    | 27018     | 27118     |
| 4    | 27019     | 27119     |
| 5    | 27020     | 27120     |
| 6    | 27021     | 27121     |
| 7    | 27022     | 27122     |
| 8    | 27023     | 27123     |
| 9    | 27024     | 27124     |
| 10   | 27025     | 27125     |

Players connect with: `connect <host-ip>:<game-port>`

## Launch Parameters

Each server starts with:

```text
-dedicated -usercon -port <game-port>
+game_type 0 +game_mode 1 +map <map>
+sv_lan 1 +tv_port <tv-port> +tv_enable 1
```

- `+game_type 0 +game_mode 1` = competitive mode
- `+sv_lan 1` = LAN-only (no GSLT needed)
- `-usercon` = enable RCON
- no `-tickrate` flag (CS2 uses sub-tick)

## Match-End Detection (MatchZy Webhooks)

When a match finishes (regulation, overtime, surrender, or admin force-end), the server container is automatically stopped and the slot is recycled. This works via MatchZy's built-in webhook system:

```text
1. Match ends inside the CS2 server
2. MatchZy fires a POST to http://host.docker.internal:32500/events/<match-id>
3. match-event-handler.py receives the event, saves the result JSON, and
   runs `docker stop` on the container
4. The watcher daemon sees the container exit, frees the slot, and starts
   the next queued match
```

The event handler runs automatically when you start the watcher:

```bash
./cs2-server-manager.sh watch
```

Match results are saved to `/opt/cs2/orchestrator/results/<match-id>.json` and include the final scores, winning team, and map data.

### MatchZy Tournament Rules

Every container is configured with tournament-standard MatchZy settings:

| Setting                          | Value | Meaning                                    |
| -------------------------------- | ----- | ------------------------------------------ |
| `matchzy_allow_coaches`          | 0     | Coaches blocked                            |
| `matchzy_ready_enabled`          | 1     | `.ready` / `.unready` enabled              |
| `matchzy_max_pauses`             | 2     | 2 pauses per team                          |
| `matchzy_pause_duration`         | 60    | 60-second pause limit                      |
| `matchzy_tech_pause_enabled`     | 1     | `.tech` enabled                            |
| `matchzy_stop_command_available` | 1     | `.stop` (Match Medic) enabled              |
| `matchzy_stop_command_no_damage` | 1     | `.stop` only when no damage dealt in round |

These are generated by the container entrypoint from environment variables. To customize, edit the MatchZy config block in `entrypoint.sh`.

### Event Handler Port

The default port is 32500. To change it:

```bash
EVENT_HANDLER_PORT=9090 ./cs2-server-manager.sh watch
```

## Anti-Cheat (Layered)

The orchestrator uses a two-layer anti-cheat strategy: a server-side plugin that runs automatically in every container, and an optional client-side monitoring tool that players run on their PCs.

### Layer 1: TBAntiCheat (Server-Side, Automatic)

[TBAntiCheat](https://github.com/killerbigpoint/cs2-anticheat) is an open-source CounterStrikeSharp plugin installed by `install_cs2.sh`. It runs inside every server container with zero setup on player PCs.

**Detects:** aimbot, rapid-fire, untrusted angles, bunnyhop exploits.

**Discord alerts:** To receive real-time cheat detection alerts in a Discord channel, create a webhook in your Discord server (Server Settings > Integrations > Webhooks) and pass the URL when starting the watcher:

```bash
export ANTICHEAT_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123456789/your-token-here"
./cs2-server-manager.sh watch
```

Or per-command:

```bash
ANTICHEAT_DISCORD_WEBHOOK="https://discord.com/api/webhooks/..." \
  ./cs2-server-manager.sh start my-match --map de_mirage
```

Without this variable, TBAntiCheat still runs and detects cheats but only logs to the server console.

### Layer 2: MOSS (Client-Side, Player-Run)

[MOSS](https://nohope.eu/) (Multi Online Supervisor Software) is a free, portable anti-cheat monitoring tool that captures evidence for post-match review. It requires no installation (players just unzip and run it).

**What it captures:** random screenshots, running process list with SHA2 hashes, macro/timing detection, game file injection monitoring.

**Setup for players:**

1. Download MOSS from [https://nohope.eu/](https://nohope.eu/)
2. Extract the ZIP to any folder (desktop, USB stick, etc.)
3. Run `Mossx64.exe` as Administrator
4. Go to File > Parameters and select Counter-Strike 2
5. Click Capture > Start
6. Launch CS2 and play the match
7. After the match: Capture > Stop
8. Submit the generated ZIP file to the tournament admin

**Tournament rule (enforce this):** All players MUST run MOSS during their matches. Failure to submit a valid MOSS log file results in a default loss. The generated ZIP is tamper-proof (SHA2 sealed). If the file has been altered, it will be flagged on verification.

**For admins (verifying MOSS logs):**

1. Collect the ZIP file from each player after the match
2. Open MOSS and use the built-in log verifier to check integrity
3. Review screenshots for visual evidence of wallhacks or ESP
4. Review process lists for injected DLLs or known cheat signatures
5. Cross-reference with TBAntiCheat Discord alerts from the same match

### Layer 3 (Optional): Akros or CS2 AntiCheat Defense

For higher-stakes tournaments, you can add a third layer:

- **Akros** (from ~100 EUR/month): Kernel-level anti-cheat. Requires UEFI, Secure Boot, and TPM 2.0 on player PCs. Players launch CS2 through the Akros client. See [akros.ac](https://akros.ac/).
- **CS2 AntiCheat Defense** ($10, commercial): An additional server-side CounterStrikeSharp plugin. Set `CS2_ACD_URL` in `install_cs2.sh` to auto-install it alongside TBAntiCheat.

## Memory Limits And Swap Safety Net

Each container is started with:

- `--memory 2560m` -- hard RAM limit (2.5 GB)
- `--memory-swap 3072m` -- total RAM + swap ceiling (512 MB swap overflow)
- `--memory-swappiness 10` -- strongly prefer RAM; swap only under real pressure

### RAM Planning

| Servers | RAM needed | 32 GB host  | 48 GB host  |
| ------- | ---------- | ----------- | ----------- |
| 3       | ~7.5 GB    | Comfortable | Comfortable |
| 8       | ~20 GB     | Comfortable | Comfortable |
| 9       | ~22.5 GB   | Comfortable | Comfortable |
| 11      | ~27.5 GB   | Tight       | Comfortable |

The OS and Docker daemon also consume 2-4 GB.

### Concurrency Cap

The default cap is 11 servers. If the pool is full, new matches wait in a FIFO queue instead of being started. This prevents RAM exhaustion entirely -- the queue is the first line of defense, swap is the second.

To change the cap:

```bash
MAX_SERVERS=9 ./cs2-server-manager.sh start my-match
```

Or export it for the session:

```bash
export MAX_SERVERS=9
```

### SSD Swap

The `install_cs2.sh` script creates a 16 GB swap file at `/swapfile` with `vm.swappiness=10`. This is a secondary safety net that absorbs temporary memory spikes without the OOM Killer crashing your servers.

To customize swap size:

```bash
export SWAP_SIZE_GB=24
sudo -E bash install_cs2.sh
```

Verify swap:

```bash
swapon --show
free -h
cat /proc/sys/vm/swappiness
```

## Directory Layout After Installation

```text
/opt/cs2/
├── shared/                 (single CS2 install, ~35GB, read-only for containers)
│   └── game/
│       └── cs2/
├── servers/
│   ├── slot-0/             (writable state for slot 0)
│   ├── slot-1/
│   ├── ...
│   └── slot-10/
├── orchestrator/
│   ├── slots/              (one file per active slot: match-id + metadata)
│   └── queue/              (one file per queued match, FIFO ordered)
└── steamcmd/
```

## Verify The Deployment

Check running containers:

```bash
./cs2-server-manager.sh status
```

Or with Docker directly:

```bash
docker ps --filter label=cs2-tournament=true
```

Follow logs for a specific match:

```bash
docker logs -f cs2-match-group-a-match-1
```

Check memory usage:

```bash
docker stats --filter label=cs2-tournament=true
```

Check open ports:

```bash
ss -tulpn | grep -E '2701[5-9]|2702[0-5]|2711[5-9]|2712[0-5]'
```

## Updating Later

### When you change repo files on your Mac

On your Mac:

```bash
cd "/Users/houtarou/Documents/private/cs2-tournament-backend"
git add .
git commit -m "Describe your change"
git push
```

On the Ubuntu host:

```bash
cd ~/projects/cs2-tournament-backend
git pull
docker compose build
```

### When Valve or plugins release updates

```bash
cd ~/projects/cs2-tournament-backend
sudo bash install_cs2.sh --update
docker compose build
```

## Changing The Server Cap

The default maximum concurrent servers is 11. To change it:

- For a single command: `MAX_SERVERS=8 ./cs2-server-manager.sh start my-match`
- For the session: `export MAX_SERVERS=8`
- Permanently: edit the `MAX_SERVERS` variable at the top of `cs2-server-manager.sh`

If you increase above 11, also create the additional slot directories:

```bash
sudo mkdir -p /opt/cs2/servers/slot-{11,12,13}
sudo chown -R 1000:1000 /opt/cs2/servers/slot-{11,12,13}
```

## Troubleshooting

### `install_cs2.sh` fails on macOS

That is expected. The script is meant to run on the Ubuntu host, not your Mac.

### A server starts but exits immediately

Check the container logs:

```bash
docker logs cs2-match-<match-id>
```

Common causes:

- `/opt/cs2/shared` was not populated correctly
- the CS2 binary is missing
- a plugin archive changed structure upstream
- `gameinfo.gi` was overwritten by a CS2 update and needs repatching

### A plugin download fails

Upstream release URLs may change. Update the version/URL variables at the top of `install_cs2.sh` and rerun:

```bash
sudo bash install_cs2.sh --update
```

### CS2 AntiCheat Defense did not install

That is expected unless you provide `CS2_ACD_URL` or install the plugin manually.

### Stale slots after a crash

If the host crashes or Docker restarts, slot files may be stale. The `watch` command reconciles state on startup, or you can clean up manually:

```bash
./cs2-server-manager.sh stop-all
```

### Queue is not processing

Make sure the watcher daemon is running:

```bash
./cs2-server-manager.sh watch
```

Without the watcher, queued matches are only started when you manually `stop` a running match.

## Minimal End-To-End Setup

### On your Mac

```bash
cd "/Users/houtarou/Documents/private/cs2-tournament-backend"
git init
git add .
git commit -m "Initial CS2 LAN tournament infrastructure"
git remote add origin https://github.com/YOUR_USERNAME/cs2-tournament-backend.git
git branch -M main
git push -u origin main
```

### On your Ubuntu host

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y docker.io docker-compose-plugin git
sudo systemctl enable --now docker

mkdir -p ~/projects
cd ~/projects
git clone https://github.com/YOUR_USERNAME/cs2-tournament-backend.git
cd cs2-tournament-backend

chmod +x install_cs2.sh entrypoint.sh cs2-server-manager.sh match-event-handler.py
sudo bash install_cs2.sh
docker compose build

# Start the watcher (in tmux or screen)
./cs2-server-manager.sh watch &

# Start your first match
./cs2-server-manager.sh start test-match --map de_mirage
./cs2-server-manager.sh status
```

## System Integration & Environments

To ensure seamless bidirectional communication between the orchestrator (`cs2-tournament-backend`) and the API platform (`cs2-platform`), you must ensure your environment IPs and tokens align properly.

### 1. The Orchestrator (`cs2-tournament-backend`)

Configure these keys inside `cs2-server-manager.sh` (or securely export them) before running `./cs2-server-manager.sh watch`:

- `NESTJS_BACKEND_URL="http://<YOUR_LAN_IP>:3000"`: Points to where the NestJS API is hosted on your local network.
- `GAME_SERVER_API_KEY="your-secret-token"`: The auth token protecting endpoints.

### 2. The NestJS API (`cs2-platform/backend/.env`)

Set these values in your backend's `.env` file:

- `CS2_HOST_URL=http://<YOUR_LAN_IP>:32500`: The orchestrator's webhook listener (`match-event-handler.py` runs natively on port `32500`).
- `BACKEND_URL=http://<YOUR_LAN_IP>:3000`: Your own API's base LAN URL for auth redirects and webhook paths.
- `GAME_SERVER_API_KEY="your-secret-token"`: The same auth token configured in the orchestrator.

### 3. The Angular Client (`cs2-platform/frontend/src/environments/environment.ts`)

Set your base API URL so browsers running on other LAN devices reach the computer hosting the tournament backend instead of themselves (`localhost`):

- `apiUrl: 'http://<YOUR_LAN_IP>:3000/api'`

## Skin Changer (WeaponPaints)

Every CS2 match container ships with the
[`Nereziel/cs2-WeaponPaints`](https://github.com/Nereziel/cs2-WeaponPaints)
plugin (pinned to `build-414`) plus its three required helper plugins
(MenuManager, PlayerSettings, AnyBaseLib). Players use the in-chat menu to
pick skins, knives, gloves, agents, music kits, pins and stickers.

```
!ws       show website link
!knife    knife menu
!skins    weapon-skin menu
!gloves   glove menu
!agent    agent menu
!music    music-kit menu
!pins     pin / collectible menu
!wp       force re-sync with the database
```

### Database topology

All persistent state lives on the **platform host** (`192.168.10.221`),
co-located with Postgres and your NestJS backend. The CS2 game host stays
stateless and reaches out to the platform host across the LAN for any DB
work.

- **MySQL (player selections)** — `weaponpaints-mysql` service in
  [`docker-compose.platform.yml`](docker-compose.platform.yml), runs on the
  platform host (192.168.10.221:3306). The plugin auto-creates
  `wp_player_skins`, `wp_player_knife`, `wp_player_gloves`,
  `wp_player_agents`, `wp_player_music`, `wp_player_pins` on first player
  connect. Your custom skin-picker website (NestJS + frontend) writes here
  too — same tables, same Steam IDs.
- **Postgres (skin catalog)** — the existing `cs2tournament` database at
  `192.168.10.221:5432`. Seeded from the plugin's bundled JSON so the NestJS
  backend and the admin frontend can render the skin / glove / agent / etc.
  pickers without touching the game server filesystem. See
  `sql/weaponpaints-catalog/`.

```text
Platform host (192.168.10.221)            Game host (Ubuntu)
┌───────────────────────────────┐         ┌────────────────────────┐
│ Postgres :5432  cs2tournament │         │ /opt/cs2/shared (CS2)  │
│   wp_catalog_*  (read-only)   │ <──┐    │ docker-compose build   │
│                               │    │    │ cs2-server-manager.sh  │
│ MySQL :3306  weaponpaints     │ <──┼─── │ matches reach 211:3306 │
│   wp_player_* (R/W)           │    │    │ via WP_DB_HOST=192.168 │
│                               │    │    │           .10.211      │
│ NestJS :3000                  │ ───┘    └────────────────────────┘
│   reads catalog from PG       │
│   reads/writes selections     │
│     in MySQL on localhost     │
└───────────────────────────────┘
```

WeaponPaints is **MySQL-only**; Postgres cannot replace it. The plugin and
your website both speak to the same MySQL — your website just writes the
selection rows ahead of time, then the player joins and the plugin reads
them back.

### Bring-up — Step A: platform host (192.168.10.221)

```bash
# 1. Clone (or just scp) this repo onto the platform host so it has
#    docker-compose.platform.yml and sql/weaponpaints-catalog/.
git clone <this-repo> ~/projects/cs2-tournament-backend
cd ~/projects/cs2-tournament-backend

# 2. Pick strong credentials.
cat > .env <<'EOF'
WP_MYSQL_ROOT_PASSWORD=<strong-root>
WP_MYSQL_DATABASE=weaponpaints
WP_MYSQL_USER=weaponpaints
WP_MYSQL_PASSWORD=<strong-app>
EOF
chmod 600 .env

# 3. Start the MySQL backing store. Healthcheck reports "(healthy)" within ~20s.
docker compose -f docker-compose.platform.yml up -d
docker ps --filter name=weaponpaints-mysql

# 4. Lock down the MySQL port so only the game host can talk to it.
sudo ufw allow from <GAME_HOST_LAN_IP> to any port 3306 proto tcp

# 5. Seed the Postgres catalog (one-time + after every plugin bump).
psql -h 127.0.0.1 -p 5432 -U <pg_user> -d cs2tournament \
     -f sql/weaponpaints-catalog/schema.sql
psql -h 127.0.0.1 -p 5432 -U <pg_user> -d cs2tournament \
     -f sql/weaponpaints-catalog/seed.sql
```

### Bring-up — Step B: game host (Ubuntu)

```bash
# 1. (Re)run the host installer so the WeaponPaints plugin files land in
#    /opt/cs2/shared. Idempotent.
sudo bash install_cs2.sh --update
docker compose build

# 2. Tell cs2-server-manager.sh which MySQL on the platform host to use.
#    WP_DB_HOST defaults to 192.168.10.221 — override only if your platform
#    host moves.
export WP_DB_USER=weaponpaints
export WP_DB_PASSWORD=<same as WP_MYSQL_PASSWORD>
export WP_DB_NAME=weaponpaints

# 3. Start the watcher and your first match — entrypoint.sh rewrites
#    WeaponPaints.json on every container boot from the env vars above.
./cs2-server-manager.sh watch &
./cs2-server-manager.sh start test-match --map de_mirage
```

### Your custom skin-picker website

Your NestJS backend reads two databases on `localhost`:

- Postgres `cs2tournament.wp_catalog_*` — the menu of every skin / glove /
  agent / music kit / keychain / sticker / collectible the plugin knows about.
- MySQL `weaponpaints.wp_player_*` — read & write per-player selections for
  the logged-in Steam ID. Schema is auto-created by the game plugin; for
  reference the per-weapon row looks like:

  ```sql
  INSERT INTO wp_player_skins
    (steamid, weapon_team, weapon_defindex, weapon_paint_id,
     weapon_wear, weapon_seed, weapon_nametag, weapon_stattrak,
     weapon_stattrak_count, weapon_sticker_0, weapon_sticker_1,
     weapon_sticker_2, weapon_sticker_3, weapon_sticker_4, weapon_keychain)
  VALUES
    ('<STEAMID64>', 0, 7, 1207,
     0.000001, 0, NULL, 0,
     0, '0;0;0;0;0;0;0', '0;0;0;0;0;0;0',
     '0;0;0;0;0;0;0', '0;0;0;0;0;0;0', '0;0;0;0;0;0;0', '0;0;0;0;0')
  ON DUPLICATE KEY UPDATE
     weapon_paint_id = VALUES(weapon_paint_id),
     weapon_wear     = VALUES(weapon_wear),
     weapon_seed     = VALUES(weapon_seed);
  ```

  `weapon_team`: 0 = both, 2 = T, 3 = CT.
  `weapon_defindex` + `weapon_paint_id` map back to `wp_catalog_skins`.

Players will see the website-set selections the next time they connect to a
match (or when they type `!wp` in chat, which forces a refresh).

### Configuration knobs

Orchestrator-side env vars consumed by `cs2-server-manager.sh`:

| Variable          | Default            | Passed into each match container so `entrypoint.sh` can generate `WeaponPaints.json`. |
|-------------------|--------------------|---------------------------------------------------------------------------------------|
| `WP_DB_HOST`      | `192.168.10.221`   | Platform host running the MySQL service. Override only if it moves.                   |
| `WP_DB_PORT`      | `3306`             |                                                                                       |
| `WP_DB_USER`      | `weaponpaints`     |                                                                                       |
| `WP_DB_PASSWORD`  | `change-me`        | **Set this in production.**                                                           |
| `WP_DB_NAME`      | `weaponpaints`     |                                                                                       |

Compose-side vars that parametrise the MySQL container itself (respected by
[`docker-compose.platform.yml`](docker-compose.platform.yml), read on the
**platform host**):
`WP_MYSQL_ROOT_PASSWORD`, `WP_MYSQL_USER`, `WP_MYSQL_PASSWORD`,
`WP_MYSQL_DATABASE`.

### Refreshing the Postgres catalog

Whenever you bump `WEAPONPAINTS_BUILD` in `install_cs2.sh`, regenerate the
seed and re-apply:

```bash
python3 sql/weaponpaints-catalog/build_catalog.py --build build-414
psql -h 192.168.10.221 -p 5432 -U <pg_user> -d cs2tournament \
     -f sql/weaponpaints-catalog/seed.sql
```

`seed.sql` `TRUNCATE`s each catalog table before re-inserting, so reapplying
is idempotent.

## Backend (CS2 Platform)

This is a NestJS application providing the server-side APIs for the CS2 Platform.

### Project Setup

```bash
cd ../cs2-platform/backend
npm install
```

### Running the Backend

```bash
# development
npm run start

# watch mode
npm run start:dev

# production mode
npm run start:prod
```

### Running Tests

```bash
# unit tests
npm run test

# e2e tests
npm run test:e2e

# test coverage
npm run test:cov
```

## Frontend (CS2 Platform)

This project was generated using [Angular CLI](https://github.com/angular/angular-cli) version 21.2.7.

### Development Server

To start a local development server, run:

```bash
cd ../cs2-platform/frontend
npm install
ng serve
```

Once the server is running, open your browser and navigate to `http://localhost:4200/`. The application will automatically reload whenever you modify any of the source files.

### Building

To build the project for production, run:

```bash
ng build
```

This will compile your project and store the build artifacts in the `dist/` directory. By default, the production build optimizes your application for performance and speed.

### Running Tests

To execute unit tests with the Vitest test runner, use the following command:

```bash
ng test
```

For end-to-end (e2e) testing, run:

```bash
ng e2e
```
