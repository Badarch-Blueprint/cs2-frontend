#!/usr/bin/env bash
###############################################################################
# CS2 LAN Tournament Orchestrator - Container Entrypoint
# ============================================================================
# Counter-Strike 2 (CS2) dedicated server — not legacy CS:GO. This script runs
# inside each container at startup, bridges the read-only shared game volume
# with a per-server writable overlay, then execs the CS2 binary (linuxsteamrt64/cs2).
#
# Valve still ships CS2 server content under the directory name "cs2" below
# game/ (SearchPaths, gameinfo.gi, VPK layout). That folder name is historical;
# the game is CS2.
#
# Architecture:
#   /opt/cs2/shared        (bind mount, READ-ONLY)  - shared CS2 game files
#   /home/steam/server     (bind mount, READ-WRITE) - per-server writable data
#   /home/steam/cs2-run    (runtime working dir)    - merged symlink tree
#
# The symlink tree in cs2-run mirrors the shared volume structure, but
# directories that need write access (cfg, logs, demos, plugin configs) are
# real directories in the writable mount instead of symlinks.
#
# Env: CS2_GAME_CONTENT_SUBDIR — on the host, which folder under shared .../game/
# holds CS2 data (VPKs, gameinfo.gi, addons). Default "cs2" matches Valve's
# usual CS2 DS layout; set to e.g. cs2 if your install uses that name instead.
###############################################################################

set -euo pipefail
shopt -s nullglob

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly SHARED_DIR="/opt/cs2/shared"
readonly WRITABLE_DIR="/home/steam/server"
readonly RUN_DIR="/home/steam/cs2-run"

readonly GAME_DIR="${RUN_DIR}/game"
# Source tree on the host: .../shared/game/<subdir>/ (Valve default for CS2 DS: csgo).
CONTENT_SUBDIR="${CS2_GAME_CONTENT_SUBDIR:-csgo}"
CONTENT_SUBDIR="${CONTENT_SUBDIR#/}"
CONTENT_SUBDIR="${CONTENT_SUBDIR%/}"
CONTENT_SUBDIR="$(basename "${CONTENT_SUBDIR}")"

# Runtime path must match CONTENT_SUBDIR — required by CS2 engine / gameinfo.
readonly CS2_GAME_DATA_DIR="${GAME_DIR}/${CONTENT_SUBDIR}"
readonly SHARED_GAME_CONTENT="${SHARED_DIR}/game/${CONTENT_SUBDIR}"

# Add near the top of entrypoint.sh, before the CS2 launch
mkdir -p /home/steam/.steam/sdk64
ln -sf /opt/cs2/steamcmd/linux64/steamclient.so /home/steam/.steam/sdk64/steamclient.so

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()  { echo "[entrypoint] INFO  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo "[entrypoint] WARN  $(date '+%H:%M:%S') $*" >&2; }
log_error() { echo "[entrypoint] ERROR $(date '+%H:%M:%S') $*" >&2; }

# ---------------------------------------------------------------------------
# Validation: ensure the shared volume is mounted and contains game files
# ---------------------------------------------------------------------------
if [[ ! -d "${SHARED_GAME_CONTENT}" ]]; then
    log_error "Shared game content not found at ${SHARED_GAME_CONTENT}"
    log_error "Set CS2_GAME_CONTENT_SUBDIR to the folder name under ${SHARED_DIR}/game/ (default: cs2). Example: export CS2_GAME_CONTENT_SUBDIR=cs2"
    exit 1
fi

if [[ ! -f "${SHARED_DIR}/game/bin/linuxsteamrt64/cs2" ]]; then
    log_error "CS2 binary not found at ${SHARED_DIR}/game/bin/linuxsteamrt64/cs2"
    log_error "The shared volume may be incomplete. Re-run install_cs2.sh with validate."
    exit 1
fi

log_info "Shared volume verified: ${SHARED_DIR} (content: ${SHARED_GAME_CONTENT})"

# ---------------------------------------------------------------------------
# Step 1: Create the writable directory structure.
# These directories hold per-server state that must survive restarts and
# must be writable by the running CS2 process.
# ---------------------------------------------------------------------------
log_info "Preparing writable overlay at ${WRITABLE_DIR}"

WRITABLE_DIRS=(
    "game/${CONTENT_SUBDIR}/cfg"
    "game/${CONTENT_SUBDIR}/logs"
    "game/${CONTENT_SUBDIR}/addons/counterstrikesharp/configs"
    "game/${CONTENT_SUBDIR}/addons/counterstrikesharp/configs/plugins/WeaponPaints"
    "game/${CONTENT_SUBDIR}/addons/counterstrikesharp/data"
    "game/${CONTENT_SUBDIR}/addons/counterstrikesharp/logs"
    "game/${CONTENT_SUBDIR}/addons/counterstrikesharp/plugins/TBAntiCheat/Config"
    "game/${CONTENT_SUBDIR}/MatchZy"
)

for dir in "${WRITABLE_DIRS[@]}"; do
    mkdir -p "${WRITABLE_DIR}/${dir}"
done

# ---------------------------------------------------------------------------
# Step 2: Build the merged symlink tree.
# We create a fresh tree each startup to pick up any updates to the shared
# volume (e.g., after a CS2 update + plugin refresh on the host).
# ---------------------------------------------------------------------------
log_info "Building merged symlink tree at ${RUN_DIR}"

rm -rf "${RUN_DIR}"
mkdir -p "${RUN_DIR}"

# Symlink top-level entries from the shared volume
for item in "${SHARED_DIR}"/*; do
    item_name=$(basename "${item}")
    ln -sf "${item}" "${RUN_DIR}/${item_name}"
done

# ---------------------------------------------------------------------------
# Step 3: Overlay writable directories on top of the symlink tree.
# We break the symlink chain at specific points and replace them with
# real directories that map to the writable volume.
# ---------------------------------------------------------------------------
log_info "Overlaying writable directories"

# The "game" directory needs to be a real directory (not a symlink) so we
# can selectively override children within it.
rm -f "${RUN_DIR}/game"
mkdir -p "${GAME_DIR}"

# Symlink all game/ children from shared, except the content subdir and bin.
# We must fully COPY 'bin' because the CS2 engine natively traces its root path
# from the physical location of the executable (/proc/self/exe), which would
# bypass our overlay entirely if bin/ was just a symlink.
for item in "${SHARED_DIR}/game"/*; do
    item_name=$(basename "${item}")
    if [[ "${item_name}" == "${CONTENT_SUBDIR}" ]]; then
        continue
    fi
    if [[ "${item_name}" == "bin" ]]; then
        cp -R "${item}" "${GAME_DIR}/${item_name}"
        continue
    fi
    ln -sf "${item}" "${GAME_DIR}/${item_name}"
done

# CS2 game data lives under game/cs2/ at runtime (Valve path); overlay writable children here.
mkdir -p "${CS2_GAME_DATA_DIR}"

# Symlink all content from shared (e.g. game/cs2/* or game/cs2/*) into runtime game/cs2/
for item in "${SHARED_GAME_CONTENT}"/*; do
    item_name=$(basename "${item}")
    ln -sf "${item}" "${CS2_GAME_DATA_DIR}/${item_name}"
done

# Now replace specific symlinks with writable directories.
# cfg/ - server configs (server.cfg, gamemode_competitive.cfg, etc.)
rm -f "${CS2_GAME_DATA_DIR}/cfg"
mkdir -p "${CS2_GAME_DATA_DIR}/cfg"

# Copy base configs from shared on first run, preserve local edits after
if [[ -d "${SHARED_GAME_CONTENT}/cfg" ]]; then
    # Only copy files that don't already exist in the writable layer
    for cfg_file in "${SHARED_GAME_CONTENT}/cfg"/*; do
        cfg_name=$(basename "${cfg_file}")
        if [[ ! -e "${WRITABLE_DIR}/game/${CONTENT_SUBDIR}/cfg/${cfg_name}" ]]; then
            cp -a "${cfg_file}" "${WRITABLE_DIR}/game/${CONTENT_SUBDIR}/cfg/${cfg_name}" 2>/dev/null || true
        fi
    done
fi
# Symlink from run dir to writable
rm -rf "${CS2_GAME_DATA_DIR}/cfg"
ln -sf "${WRITABLE_DIR}/game/${CONTENT_SUBDIR}/cfg" "${CS2_GAME_DATA_DIR}/cfg"

# logs/ - server log output
rm -f "${CS2_GAME_DATA_DIR}/logs"
ln -sf "${WRITABLE_DIR}/game/${CONTENT_SUBDIR}/logs" "${CS2_GAME_DATA_DIR}/logs"

# addons/ - needs partial overlay (CounterStrikeSharp configs/data are writable)
rm -f "${CS2_GAME_DATA_DIR}/addons"
mkdir -p "${CS2_GAME_DATA_DIR}/addons"

# Symlink all addon children from shared
if [[ -d "${SHARED_GAME_CONTENT}/addons" ]]; then
    for item in "${SHARED_GAME_CONTENT}/addons"/*; do
        item_name=$(basename "${item}")
        ln -sf "${item}" "${CS2_GAME_DATA_DIR}/addons/${item_name}"
    done
fi

# Overlay CounterStrikeSharp with partial writes
if [[ -d "${SHARED_GAME_CONTENT}/addons/counterstrikesharp" ]]; then
    rm -f "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp"
    mkdir -p "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp"

    for item in "${SHARED_GAME_CONTENT}/addons/counterstrikesharp"/*; do
        item_name=$(basename "${item}")
        ln -sf "${item}" "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/${item_name}"
    done

    # Replace configs, data, and logs with writable directories
    for writable_sub in configs data logs; do
        rm -f "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/${writable_sub}"
        ln -sf "${WRITABLE_DIR}/game/${CONTENT_SUBDIR}/addons/counterstrikesharp/${writable_sub}" \
               "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/${writable_sub}"
    done

    # Copy default CSS configs on first run
    if [[ -d "${SHARED_GAME_CONTENT}/addons/counterstrikesharp/configs" ]]; then
        for cfg_file in "${SHARED_GAME_CONTENT}/addons/counterstrikesharp/configs"/*; do
            cfg_name=$(basename "${cfg_file}")
            target="${WRITABLE_DIR}/game/${CONTENT_SUBDIR}/addons/counterstrikesharp/configs/${cfg_name}"
            if [[ ! -e "${target}" ]]; then
                cp -a "${cfg_file}" "${target}" 2>/dev/null || true
            fi
        done
    fi

    # Break the plugins symlink into per-plugin symlinks so individual plugins
    # (like TBAntiCheat) can have writable config overlays.
    shared_plugins="${SHARED_GAME_CONTENT}/addons/counterstrikesharp/plugins"
    if [[ -d "${shared_plugins}" ]]; then
        rm -f "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/plugins"
        mkdir -p "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/plugins"

        for plugin_dir in "${shared_plugins}"/*; do
            plugin_name=$(basename "${plugin_dir}")
            ln -sf "${plugin_dir}" "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/plugins/${plugin_name}"
        done

        # TBAntiCheat: overlay its Config/ directory as writable so the plugin
        # can persist ban lists and runtime state across rounds.
        if [[ -d "${shared_plugins}/TBAntiCheat" ]]; then
            rm -f "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/plugins/TBAntiCheat"
            mkdir -p "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/plugins/TBAntiCheat"

            for item in "${shared_plugins}/TBAntiCheat"/*; do
                item_name=$(basename "${item}")
                if [[ "${item_name}" != "Config" ]]; then
                    ln -sf "${item}" "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/plugins/TBAntiCheat/${item_name}"
                fi
            done

            tbac_writable="${WRITABLE_DIR}/game/${CONTENT_SUBDIR}/addons/counterstrikesharp/plugins/TBAntiCheat/Config"
            ln -sf "${tbac_writable}" \
                   "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/plugins/TBAntiCheat/Config"

            # Seed default configs from shared on first run
            if [[ -d "${shared_plugins}/TBAntiCheat/Config" ]]; then
                for cfg_file in "${shared_plugins}/TBAntiCheat/Config"/*; do
                    cfg_name=$(basename "${cfg_file}")
                    if [[ ! -e "${tbac_writable}/${cfg_name}" ]]; then
                        cp -a "${cfg_file}" "${tbac_writable}/${cfg_name}" 2>/dev/null || true
                    fi
                done
            fi

            log_info "TBAntiCheat overlay ready (Config/ is writable)"
        fi
    fi
fi

# MatchZy data directory (match configs, stats, demos)
rm -f "${CS2_GAME_DATA_DIR}/MatchZy"
ln -sf "${WRITABLE_DIR}/game/${CONTENT_SUBDIR}/MatchZy" "${CS2_GAME_DATA_DIR}/MatchZy"

# ---------------------------------------------------------------------------
# Step 4: Patch gameinfo.gi for Metamod in the writable overlay.
# Shared gameinfo.gi is read-only; CS2 expects it under game/cs2/ — copy into run tree.
# ---------------------------------------------------------------------------
GAMEINFO_SRC="${SHARED_GAME_CONTENT}/gameinfo.gi"
GAMEINFO_DST="${CS2_GAME_DATA_DIR}/gameinfo.gi"

if [[ -f "${GAMEINFO_SRC}" ]]; then
    # Remove the symlink and create a real writable copy
    rm -f "${GAMEINFO_DST}"
    cp "${GAMEINFO_SRC}" "${GAMEINFO_DST}"

    # Verify Metamod entry exists; inject if missing (defensive — install_cs2.sh
    # should have already patched it, but CS2 updates can overwrite the file)
    if grep -q "cs2/addons/metamod" "${GAMEINFO_DST}"; then
        # Replace the hardcoded 'cs2' from install_cs2.sh with the proper subdir
        sed -i "s#cs2/addons/metamod#${CONTENT_SUBDIR}/addons/metamod#g" "${GAMEINFO_DST}"
    fi

    if ! grep -q "${CONTENT_SUBDIR}/addons/metamod" "${GAMEINFO_DST}"; then
        log_warn "Metamod entry missing from gameinfo.gi — injecting now"
        # Match 'Game csgo' and insert Metamod right above it, or fallback
        sed -i "/Game[[:space:]]*csgo/i\\t\t\tGame\t${CONTENT_SUBDIR}/addons/metamod" "${GAMEINFO_DST}"
    fi

    log_info "gameinfo.gi ready (Metamod entry present)"
else
    log_warn "gameinfo.gi not found in shared volume — Metamod may not load"
fi

# ---------------------------------------------------------------------------
# Step 5: Configure MatchZy (tournament rules + match-end webhook).
# The config is written on every startup so it always reflects the current
# environment variables passed by cs2-server-manager.sh.
# ---------------------------------------------------------------------------
MATCHZY_CFG_DIR="${CS2_GAME_DATA_DIR}/cfg/MatchZy"
mkdir -p "${MATCHZY_CFG_DIR}"

{
    echo "// MatchZy tournament configuration — generated by entrypoint.sh"
    echo "// Regenerated on every container start. Manual edits will be overwritten."
    echo ""

    # Match-end webhook: lets the orchestrator detect when the game finishes
    if [[ -n "${MATCHZY_REMOTE_LOG_URL:-}" ]]; then
        echo "matchzy_remote_log_url \"${MATCHZY_REMOTE_LOG_URL}\""
        log_info "MatchZy webhook: ${MATCHZY_REMOTE_LOG_URL}"
    else
        log_warn "MATCHZY_REMOTE_LOG_URL not set — match-end auto-detection disabled"
    fi

    echo ""
    echo "// Tournament rules"
    echo "matchzy_allow_coaches 0"
    echo "matchzy_pause_on_veto 0"
    echo "matchzy_ready_enabled 1"
    echo "matchzy_unready_enabled 1"
    echo "matchzy_max_pauses 2"
    echo "matchzy_pause_duration 60"
    echo "matchzy_tech_pause_enabled 1"
    echo "matchzy_stop_command_available 1"
    echo "matchzy_stop_command_no_damage 1"
    echo ""
    echo "// Core stability"
    echo "sv_hibernate_when_empty 0"
    echo ""
    echo "// RCON setup (for orchestrator control)"
    echo "sv_rcon_minfailures 0"
    echo "sv_rcon_minfailuretime 0"
} > "${MATCHZY_CFG_DIR}/config.cfg"

log_info "MatchZy config written to cfg/MatchZy/config.cfg"

# ---------------------------------------------------------------------------
# Step 5a: Configure Native Server (RCON + Stability)
# ---------------------------------------------------------------------------
{
    echo "// Native CS2 server configuration — generated by entrypoint.sh"
    echo "rcon_password \"${RCON_PASSWORD:-}\""
    echo "sv_rcon_minfailures 0"
    echo "sv_rcon_minfailuretime 0"
    echo "sv_rcon_maxfailures 0"
    echo "sv_hibernate_when_empty 0"
    echo "sv_lan 1"
} > "${CS2_GAME_DATA_DIR}/cfg/server.cfg"

log_info "Native server config written to cfg/server.cfg"

# ---------------------------------------------------------------------------
# Step 5b: WeaponPaints skin-changer setup.
# ---------------------------------------------------------------------------
# 1. Ensure the plugin's config directory exists (in the writable overlay).
# 2. Regenerate WeaponPaints.json on every boot from WP_DB_* env vars so the
#    plugin always points at the orchestrator-managed MySQL.
# 3. Defensively re-patch core.json's FollowCS2ServerGuidelines=false in case
#    a CS2 update re-seeded the file from the shared volume.
# ---------------------------------------------------------------------------
WP_CONFIG_DIR="${WRITABLE_DIR}/game/${CONTENT_SUBDIR}/addons/counterstrikesharp/configs/plugins/WeaponPaints"
mkdir -p "${WP_CONFIG_DIR}"

WP_DB_HOST_VAL="${WP_DB_HOST:-192.168.10.221}"
WP_DB_PORT_VAL="${WP_DB_PORT:-3306}"
WP_DB_USER_VAL="${WP_DB_USER:-weaponpaints}"
WP_DB_PASSWORD_VAL="${WP_DB_PASSWORD:-}"
WP_DB_NAME_VAL="${WP_DB_NAME:-weaponpaints}"

# JSON-escape the password (only \ and " are problematic inside a JSON string
# generated by bash). Anything exotic should be set via a proper secret anyway.
wp_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "${s}"
}
WP_DB_PASSWORD_ESC="$(wp_json_escape "${WP_DB_PASSWORD_VAL}")"

cat > "${WP_CONFIG_DIR}/WeaponPaints.json" <<WPJSON
{
  "ConfigVersion": 10,
  "SkinsLanguage": "en",
  "DatabaseHost": "${WP_DB_HOST_VAL}",
  "DatabasePort": ${WP_DB_PORT_VAL},
  "DatabaseUser": "${WP_DB_USER_VAL}",
  "DatabasePassword": "${WP_DB_PASSWORD_ESC}",
  "DatabaseName": "${WP_DB_NAME_VAL}",
  "CmdRefreshCooldownSeconds": 60,
  "Website": "",
  "MenuType": "selectable",
  "Additional": {
    "KnifeEnabled": true,
    "SkinEnabled": true,
    "GloveEnabled": true,
    "AgentEnabled": true,
    "MusicEnabled": true,
    "PinsEnabled": true,
    "CommandWpEnabled": true,
    "CommandKillEnabled": true,
    "CommandKnife": ["knife"],
    "CommandMusic": ["music"],
    "CommandPin": ["pin", "pins", "coin", "coins"],
    "CommandGlove": ["gloves"],
    "CommandAgent": ["agents"],
    "CommandStattrak": ["stattrak", "st"],
    "CommandSkin": ["ws"],
    "CommandSkinSelection": ["skins"],
    "CommandRefresh": ["wp"],
    "CommandKill": ["kill"],
    "GiveRandomKnife": false,
    "GiveRandomSkin": false,
    "ShowSkinImage": true
  }
}
WPJSON

# CSSharp resolves its config root by following symlinks on its .NET assembly
# directories (api/, dotnet/), which physically live in the shared volume.
# This means CSSharp reads plugin configs from /opt/cs2/shared/.../configs/,
# NOT from the writable overlay. Write the config to both locations so the
# plugin finds it regardless of which path CSSharp resolves.
SHARED_WP_CONFIG="${SHARED_GAME_CONTENT}/addons/counterstrikesharp/configs/plugins/WeaponPaints"
mkdir -p "${SHARED_WP_CONFIG}" 2>/dev/null || true
cp -f "${WP_CONFIG_DIR}/WeaponPaints.json" "${SHARED_WP_CONFIG}/WeaponPaints.json" 2>/dev/null || \
    log_warn "Could not copy WeaponPaints config to shared volume (read-only?)"

log_info "WeaponPaints config written: db=${WP_DB_HOST_VAL}:${WP_DB_PORT_VAL}/${WP_DB_NAME_VAL} user=${WP_DB_USER_VAL}"

# Defensive: ensure core.json has FollowCS2ServerGuidelines=false (required
# so custom skins/paints are not stripped by the engine). install_cs2.sh has
# already patched the shared copy; this handles the case where the writable
# overlay was seeded from a stale shared copy or re-seeded after a CS2 update.
CORE_JSON="${WRITABLE_DIR}/game/${CONTENT_SUBDIR}/addons/counterstrikesharp/configs/core.json"
if [[ -f "${CORE_JSON}" ]]; then
    if grep -q '"FollowCS2ServerGuidelines"[[:space:]]*:[[:space:]]*true' "${CORE_JSON}"; then
        sed -i 's/"FollowCS2ServerGuidelines"[[:space:]]*:[[:space:]]*true/"FollowCS2ServerGuidelines": false/' "${CORE_JSON}"
        log_info "core.json patched: FollowCS2ServerGuidelines -> false"
    elif ! grep -q '"FollowCS2ServerGuidelines"' "${CORE_JSON}"; then
        log_warn "core.json exists but has no FollowCS2ServerGuidelines key — skins may be stripped"
    else
        log_info "core.json OK (FollowCS2ServerGuidelines=false)"
    fi
else
    log_warn "core.json not present yet at ${CORE_JSON} — will be created by CSSharp on first run"
fi

# Writes General.json with the Discord webhook if provided. Detection
# modules (Aimbot, RapidFire, UntrustedAngles) use their shipped defaults.
# ---------------------------------------------------------------------------
TBAC_CONFIG_DIR="${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/plugins/TBAntiCheat/Config"

if [[ -d "${TBAC_CONFIG_DIR}" ]] || [[ -L "${TBAC_CONFIG_DIR}" ]]; then
    if [[ -n "${ANTICHEAT_DISCORD_WEBHOOK:-}" ]]; then
        # Parse webhook ID and token from a full Discord webhook URL:
        # https://discord.com/api/webhooks/<id>/<token>
        WEBHOOK_ID=$(echo "${ANTICHEAT_DISCORD_WEBHOOK}" | grep -oP 'webhooks/\K[0-9]+')
        WEBHOOK_TOKEN=$(echo "${ANTICHEAT_DISCORD_WEBHOOK}" | grep -oP 'webhooks/[0-9]+/\K[A-Za-z0-9_-]+')

        if [[ -n "${WEBHOOK_ID}" && -n "${WEBHOOK_TOKEN}" ]]; then
            cat > "${TBAC_CONFIG_DIR}/General.json" << EOJSON
{
  "DiscordWebhookID": ${WEBHOOK_ID},
  "DiscordWebhookToken": "${WEBHOOK_TOKEN}",
  "DiscordWebhookStartMessage": true
}
EOJSON

            # Enable Discord alerts on all detection modules
            for module_cfg in Aimbot.json RapidFire.json UntrustedAngles.json; do
                cfg_path="${TBAC_CONFIG_DIR}/${module_cfg}"
                if [[ -f "${cfg_path}" ]]; then
                    # Flip AlertDiscord from false to true
                    sed -i 's/"AlertDiscord": false/"AlertDiscord": true/' "${cfg_path}"
                fi
            done

            log_info "TBAntiCheat Discord webhook configured"
        else
            log_warn "ANTICHEAT_DISCORD_WEBHOOK is set but could not parse webhook ID/token"
        fi
    else
        log_info "TBAntiCheat using default config (no Discord webhook)"
    fi
else
    log_info "TBAntiCheat not installed — skipping config"
fi

# ---------------------------------------------------------------------------
# Step 7: Prepare MatchZy Configuration for RCON Loading
# ---------------------------------------------------------------------------
MATCH_JSON="/home/steam/matches/${CS2_MATCH_ID}.json"
if [[ -n "${CS2_MATCH_ID:-}" ]] && [[ -f "${MATCH_JSON}" ]]; then
    # Copy host-generated matching file into the overlay
    # This will be loaded by the orchestrator via RCON once the server is ready.
    cp -f "${MATCH_JSON}" "${CS2_GAME_DATA_DIR}/match.json"
    log_info "Prepared MatchZy team configuration for ${CS2_MATCH_ID} (waiting for RCON trigger)"
else
    log_info "No explicit MatchZy team configuration found for ${CS2_MATCH_ID}"
fi

# ---------------------------------------------------------------------------
# Step 8: Launch the CS2 dedicated server.
# The binary is at game/bin/linuxsteamrt64/cs2 and must be invoked from the
# game/ directory context. We use exec to replace the shell process so that
# Docker signal handling (SIGTERM for graceful shutdown) works correctly.
# ---------------------------------------------------------------------------
log_info "Launching CS2 dedicated server"
log_info "  Port: ${CS2_PORT:-27015} | TV Port: ${CS2_TV_PORT:-27020}"
log_info "  Match: ${CS2_MATCH_ID:-<unset>}"
log_info "  Args: ${CS2_ARGS:-<none>}"

cd "${RUN_DIR}/game"

# shellcheck disable=SC2086
exec ./bin/linuxsteamrt64/cs2 ${CS2_ARGS}
