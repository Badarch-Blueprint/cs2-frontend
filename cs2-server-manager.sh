#!/usr/bin/env bash
###############################################################################
# CS2 LAN Tournament Orchestrator - Dynamic Server Pool Manager
# ============================================================================
# Manages a pool of CS2 dedicated server containers dynamically. Instead of
# running all servers statically, this script starts/stops containers on
# demand with a configurable concurrency cap. When the pool is full, new
# match requests are queued and automatically started when a slot frees up.
#
# Usage:
#   ./cs2-server-manager.sh start <match-id> [--map de_mirage]
#   ./cs2-server-manager.sh stop  <match-id>
#   ./cs2-server-manager.sh status
#   ./cs2-server-manager.sh watch
#   ./cs2-server-manager.sh stop-all
#
# Prerequisites:
#   1. Run install_cs2.sh on the host first
#   2. Build the image: docker compose build
###############################################################################

set -euo pipefail

# ===========================================================================
# CONFIGURATION
# All values can be overridden via environment variables.
# Credentials live in a gitignored .env next to this script — copy
# .env.example to .env and fill in real values before first run.
# ===========================================================================

_ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
if [[ -f "${_ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${_ENV_FILE}"
    set +a
fi

# Maximum number of concurrent server containers.
# Default 11: 9 group-stage matches + 2 showmatches.
readonly MAX_SERVERS="${MAX_SERVERS:-11}"

# Port bases. Slot N gets game port BASE+N and TV port TV_BASE+N.
# The 100-offset gap prevents any overlap between game and TV port ranges.
readonly GAME_PORT_BASE="${GAME_PORT_BASE:-27015}"
readonly TV_PORT_BASE="${TV_PORT_BASE:-27115}"

# Docker resource limits per container
readonly MEMORY_LIMIT="${MEMORY_LIMIT:-2560m}"
readonly MEMSWAP_LIMIT="${MEMSWAP_LIMIT:-3072m}"
readonly MEM_SWAPPINESS="${MEM_SWAPPINESS:-10}"

# Docker image name (built by docker compose build)
readonly IMAGE_NAME="${IMAGE_NAME:-cs2-server-latest}"

# Host directories
readonly SHARED_DIR="${SHARED_DIR:-/opt/cs2/shared}"
readonly STEAMCMD_DIR="${STEAMCMD_DIR:-/opt/cs2/steamcmd}"
readonly SERVERS_DIR="${SERVERS_DIR:-/opt/cs2/servers}"

# Orchestrator state directory (slots + queue)
readonly STATE_DIR="${STATE_DIR:-/opt/cs2/orchestrator}"
readonly SLOTS_DIR="${STATE_DIR}/slots"
readonly QUEUE_DIR="${STATE_DIR}/queue"

# Default map for new matches
readonly DEFAULT_MAP="${DEFAULT_MAP:-de_mirage}"

# After `docker run`, wait this many seconds and verify the container is still
# running before claiming the slot. Catches instant CS2 crashes (bad map, OOM, etc.).
readonly CS2_START_VERIFY_SECS="${CS2_START_VERIFY_SECS:-4}"

# If set to 1, log docker inspect + last logs whenever a managed container dies (watch mode).
readonly CS2_MANAGER_DEBUG="${CS2_MANAGER_DEBUG:-0}"

# MatchZy event handler port (match-end webhook receiver on the host)
readonly EVENT_HANDLER_PORT="${EVENT_HANDLER_PORT:-32500}"

# Path to the event handler script (co-located with this script)
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly EVENT_HANDLER_SCRIPT="${SCRIPT_DIR}/match-event-handler.py"

# TBAntiCheat Discord webhook URL for cheat detection alerts (optional).
# Format: https://discord.com/api/webhooks/<id>/<token>
readonly ANTICHEAT_DISCORD_WEBHOOK="${ANTICHEAT_DISCORD_WEBHOOK:-}"

# NestJS Platform Backend Config
readonly NESTJS_BACKEND_URL="${NESTJS_BACKEND_URL:-http://192.168.10.50:3000}"
readonly GAME_SERVER_API_KEY="${GAME_SERVER_API_KEY:-}"

# RCON password for every server container. No default on purpose — set it
# in .env (see .env.example).
readonly RCON_PASSWORD="${RCON_PASSWORD:-}"
if [[ -z "${RCON_PASSWORD}" ]]; then
    echo "ERROR: RCON_PASSWORD is not set. Copy .env.example to .env and fill in credentials." >&2
    exit 1
fi

# WeaponPaints (skin-changer) MySQL connection — consumed by entrypoint.sh
# inside each server container to generate WeaponPaints.json. The MySQL
# instance runs on the platform host (same box as Postgres / NestJS), see
# docker-compose.platform.yml. Default points at 192.168.10.221:3306 so the
# game host reaches it across the LAN; override via env if your platform
# host moves.
readonly WP_DB_HOST="${WP_DB_HOST:-192.168.10.50}"
readonly WP_DB_PORT="${WP_DB_PORT:-3306}"
readonly WP_DB_USER="${WP_DB_USER:-weaponpaints}"
readonly WP_DB_PASSWORD="${WP_DB_PASSWORD:-}"
readonly WP_DB_NAME="${WP_DB_NAME:-weaponpaints}"

# CS2 dedicated server: folder under ${SHARED_DIR}/game/ with VPKs + gameinfo.gi.
# Valve default is "cs2" (CS2 content, legacy directory name). Override if your tree differs.
readonly CS2_GAME_CONTENT_SUBDIR="${CS2_GAME_CONTENT_SUBDIR:-csgo}"

# Docker label used to identify our managed containers
readonly LABEL_KEY="cs2-tournament"
readonly LABEL_VAL="true"

# ===========================================================================
# LOGGING
# ===========================================================================
log_info()  { echo -e "\033[0;32m[manager]\033[0m INFO  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "\033[0;33m[manager]\033[0m WARN  $(date '+%H:%M:%S') $*" >&2; }
log_error() { echo -e "\033[0;31m[manager]\033[0m ERROR $(date '+%H:%M:%S') $*" >&2; }

# ===========================================================================
# HELPERS
# ===========================================================================

ensure_dirs() {
    mkdir -p "${SLOTS_DIR}" "${QUEUE_DIR}"
}

# Returns the game port for a given slot number
game_port_for_slot() {
    echo $(( GAME_PORT_BASE + $1 ))
}

# Returns the TV port for a given slot number
tv_port_for_slot() {
    echo $(( TV_PORT_BASE + $1 ))
}

# Container name for a given match-id
container_name() {
    echo "cs2-match-${1}"
}

# UI / shorthand names → CS2 `+map` ids (must be `de_*` etc. or the server exits immediately).
normalize_match_map() {
    local raw="$1"
    local r
    r=$(echo "${raw}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "${r}" in
        de_*) echo "${r}" ;;
        ancient) echo "de_ancient" ;;
        anubis) echo "de_anubis" ;;
        dust2) echo "de_dust2" ;;
        inferno) echo "de_inferno" ;;
        mirage) echo "de_mirage" ;;
        nuke) echo "de_nuke" ;;
        overpass) echo "de_overpass" ;;
        vertigo) echo "de_vertigo" ;;
        *)
            echo "${raw}"
            ;;
    esac
}

# Print inspect summary + recent container logs (stderr) for debugging crashes.
dump_container_exit_debug() {
    local cname="$1"
    local reason="${2:-container exit}"
    log_error "--- debug (${reason}): ${cname} ---"
    if docker container inspect "${cname}" >/dev/null 2>&1; then
        local state_line
        state_line=$(docker container inspect -f \
            'Status={{.State.Status}} ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}} Error={{.State.Error}} FinishedAt={{.State.FinishedAt}}' \
            "${cname}" 2>/dev/null || echo "inspect failed")
        log_error "Docker state: ${state_line}"
        log_error "Recent container logs (last 120 lines):"
        docker logs --tail 120 "${cname}" 2>&1 | sed 's/^/[container] /' | while IFS= read -r line || [[ -n "${line}" ]]; do
            log_error "${line}"
        done
    else
        log_error "Container '${cname}' is gone (docker rm already?); cannot fetch logs."
    fi
    log_error "--- end debug ---"
}

# Find the first free slot (0..MAX_SERVERS-1). Prints the slot number or
# returns 1 if all slots are occupied.
find_free_slot() {
    for (( slot=0; slot<MAX_SERVERS; slot++ )); do
        if [[ ! -f "${SLOTS_DIR}/${slot}" ]]; then
            echo "${slot}"
            return 0
        fi
    done
    return 1
}

# Count currently occupied slots
count_running() {
    local count=0
    for (( slot=0; slot<MAX_SERVERS; slot++ )); do
        if [[ -f "${SLOTS_DIR}/${slot}" ]]; then
            count=$(( count + 1 ))
        fi
    done
    echo "${count}"
}

# Check if a match-id is already running (in any slot)
is_match_running() {
    local match_id="$1"
    for slot_file in "${SLOTS_DIR}"/*; do
        [[ -f "${slot_file}" ]] || continue
        if [[ "$(cat "${slot_file}" | cut -d'|' -f1)" == "${match_id}" ]]; then
            return 0
        fi
    done
    return 1
}

# Check if a match-id is already in the queue
is_match_queued() {
    local match_id="$1"
    for queue_file in "${QUEUE_DIR}"/*; do
        [[ -f "${queue_file}" ]] || continue
        if [[ "$(cat "${queue_file}" | cut -d'|' -f1)" == "${match_id}" ]]; then
            return 0
        fi
    done
    return 1
}

# Get the slot number for a running match-id
get_slot_for_match() {
    local match_id="$1"
    for (( slot=0; slot<MAX_SERVERS; slot++ )); do
        if [[ -f "${SLOTS_DIR}/${slot}" ]]; then
            if [[ "$(cat "${SLOTS_DIR}/${slot}" | cut -d'|' -f1)" == "${match_id}" ]]; then
                echo "${slot}"
                return 0
            fi
        fi
    done
    return 1
}

# Dequeue the oldest queued match. Prints "match-id|map" or returns 1.
dequeue_next() {
    local oldest
    oldest=$(ls -1 "${QUEUE_DIR}" 2>/dev/null | sort | head -n1)
    if [[ -z "${oldest}" ]]; then
        return 1
    fi
    cat "${QUEUE_DIR}/${oldest}"
    rm -f "${QUEUE_DIR}/${oldest}"
}

# ===========================================================================
# COMMAND: start <match-id> [--map <map_name>]
# ===========================================================================
cmd_start() {
    local match_id=""
    local map="${DEFAULT_MAP}"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --map)
                map="$2"
                shift 2
                ;;
            *)
                if [[ -z "${match_id}" ]]; then
                    match_id="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${match_id}" ]]; then
        log_error "Usage: $0 start <match-id> [--map <map_name>]"
        exit 1
    fi

    # Guard: already running?
    if is_match_running "${match_id}"; then
        log_warn "Match '${match_id}' is already running."
        return 0
    fi

    # Guard: already queued?
    if is_match_queued "${match_id}"; then
        log_warn "Match '${match_id}' is already in the queue."
        return 0
    fi

    # Try to find a free slot
    local slot
    if slot=$(find_free_slot); then
        if ! launch_server "${slot}" "${match_id}" "${map}"; then
            log_error "Launch failed for match '${match_id}' (see messages above)."
            return 1
        fi
    else
        # Pool is full — queue the match
        local queue_file="${QUEUE_DIR}/$(date '+%s%N')-${match_id}"
        echo "${match_id}|${map}" > "${queue_file}"
        local running
        running=$(count_running)
        log_warn "Pool is full (${running}/${MAX_SERVERS}). Match '${match_id}' queued."
        log_warn "It will start automatically when a slot frees up."
    fi
}

# Launch a server container in a specific slot
# Returns 0 only after the container survives CS2_START_VERIFY_SECS; otherwise 1.
launch_server() {
    local slot="$1"
    local match_id="$2"
    local raw_map="$3"
    local map
    map=$(normalize_match_map "${raw_map}")
    if [[ "${map}" != "${raw_map}" ]]; then
        log_warn "Normalized map '${raw_map}' -> '${map}' (use de_* names for +map)"
    fi
    if [[ ! "${map}" =~ ^de_[a-z0-9_]+$ ]]; then
        log_warn "Map '${map}' does not look like a standard CS2 map id (de_*); startup may fail."
    fi

    if ! command -v docker &>/dev/null; then
        log_error "docker CLI not found in PATH."
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        log_error "Cannot talk to the Docker daemon (permission denied? try: newgrp docker or log out/in)."
        return 1
    fi
    if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then
        log_error "Docker image '${IMAGE_NAME}' is missing. From this repo run: docker compose build"
        return 1
    fi

    local gport
    gport=$(game_port_for_slot "${slot}")
    local tport
    tport=$(tv_port_for_slot "${slot}")
    local cname
    cname=$(container_name "${match_id}")
    local server_dir="${SERVERS_DIR}/slot-${slot}"

    # Ensure writable directory exists
    mkdir -p "${server_dir}"

    # Clean up any leftover container with the same name
    docker rm -f "${cname}" >/dev/null 2>&1 || true

    log_info "Starting match '${match_id}' on slot ${slot} (game:${gport} tv:${tport} map:${map})"

    local matchzy_url="http://host.docker.internal:${EVENT_HANDLER_PORT}/events/${match_id}"

    local cid=""
    # Capture stdout+stderr so permission denied / missing image messages appear in logs.
    if ! cid="$(docker run -d -i -t \
        --name "${cname}" \
        --hostname "cs2-slot-${slot}" \
        --add-host=host.docker.internal:host-gateway \
        --label "${LABEL_KEY}=${LABEL_VAL}" \
        --label "cs2-slot=${slot}" \
        --label "cs2-match=${match_id}" \
        --memory "${MEMORY_LIMIT}" \
        --memory-swap "${MEMSWAP_LIMIT}" \
        --memory-swappiness "${MEM_SWAPPINESS}" \
        --restart no \
        -v "${SHARED_DIR}:/opt/cs2/shared" \
        -v "${STEAMCMD_DIR}:/opt/cs2/steamcmd:ro" \
        -v "${STATE_DIR}/matches:/home/steam/matches:ro" \
        -v "${server_dir}:/home/steam/server" \
        -p "${gport}:${gport}/tcp" \
        -p "${gport}:${gport}/udp" \
        -p "${tport}:${tport}/udp" \
        -e LD_LIBRARY_PATH="/opt/cs2/shared/game/bin/linuxsteamrt64" \
        -e CS2_PORT="${gport}" \
        -e CS2_TV_PORT="${tport}" \
        -e CS2_MATCH_ID="${match_id}" \
        -e MATCHZY_REMOTE_LOG_URL="${matchzy_url}" \
        -e ANTICHEAT_DISCORD_WEBHOOK="${ANTICHEAT_DISCORD_WEBHOOK}" \
        -e CS2_GAME_CONTENT_SUBDIR="${CS2_GAME_CONTENT_SUBDIR}" \
        -e WP_DB_HOST="${WP_DB_HOST}" \
        -e WP_DB_PORT="${WP_DB_PORT}" \
        -e WP_DB_USER="${WP_DB_USER}" \
        -e WP_DB_PASSWORD="${WP_DB_PASSWORD}" \
        -e WP_DB_NAME="${WP_DB_NAME}" \
        -e RCON_PASSWORD="${RCON_PASSWORD}" \
        -e CS2_ARGS="-dedicated -usercon -port ${gport} +game_type 0 +game_mode 1 +map ${map} +sv_lan 1 +tv_port ${tport} +tv_enable 1 +rcon_password ${RCON_PASSWORD} +ip 0.0.0.0" \
        "${IMAGE_NAME}" 2>&1)"; then
        log_error "docker run failed for '${cname}' — output: ${cid}"
        return 1
    fi
    cid="$(echo "${cid}" | tr -d '\r' | head -n1)"
    if [[ "${#cid}" -lt 12 ]]; then
        log_error "docker run returned unexpected id for '${cname}': '${cid}'"
        return 1
    fi
    log_info "docker run OK: ${cname} -> ${cid}"

    log_info "Waiting ${CS2_START_VERIFY_SECS}s to verify container stays up..."
    sleep "${CS2_START_VERIFY_SECS}"

    if ! docker ps -q --filter "name=^${cname}$" | grep -q .; then
        log_error "Container '${cname}' exited during startup grace period (${CS2_START_VERIFY_SECS}s)."
        dump_container_exit_debug "${cname}" "startup grace period"
        docker rm -f "${cname}" >/dev/null 2>&1 || true
        return 1
    fi

    # Record the slot only after the process survived the grace window
    echo "${match_id}|${map}|$(date '+%Y-%m-%d %H:%M:%S')" > "${SLOTS_DIR}/${slot}"

    local running
    running=$(count_running)
    log_info "Match '${match_id}' is LIVE on slot ${slot}. (${running}/${MAX_SERVERS} servers active)"
    log_info "  Connect: connect <host-ip>:${gport}"
    return 0
}

# ===========================================================================
# COMMAND: stop <match-id>
# ===========================================================================
cmd_stop() {
    local match_id="${1:-}"

    if [[ -z "${match_id}" ]]; then
        log_error "Usage: $0 stop <match-id>"
        exit 1
    fi

    # Remove from queue if queued (not yet started)
    if is_match_queued "${match_id}"; then
        for queue_file in "${QUEUE_DIR}"/*; do
            [[ -f "${queue_file}" ]] || continue
            if [[ "$(cat "${queue_file}" | cut -d'|' -f1)" == "${match_id}" ]]; then
                rm -f "${queue_file}"
                log_info "Match '${match_id}' removed from queue."
                return 0
            fi
        done
    fi

    # Find the slot
    local slot
    if ! slot=$(get_slot_for_match "${match_id}"); then
        log_error "Match '${match_id}' is not running."
        return 1
    fi

    local cname
    cname=$(container_name "${match_id}")

    log_info "Stopping match '${match_id}' on slot ${slot}..."

    docker stop "${cname}" >/dev/null 2>&1 || true
    docker rm -f "${cname}" >/dev/null 2>&1 || true

    # Free the slot
    rm -f "${SLOTS_DIR}/${slot}"

    local running
    running=$(count_running)
    log_info "Match '${match_id}' stopped. Slot ${slot} freed. (${running}/${MAX_SERVERS} servers active)"

    # Process queue: start the next waiting match
    process_queue
}

# ===========================================================================
# COMMAND: console <match-id>
# Attach to the server console (interactive stdin) 
# ===========================================================================
cmd_console() {
    local match_id="${1:-}"

    if [[ -z "${match_id}" ]]; then
        log_error "Usage: $0 console <match-id>"
        exit 1
    fi

    local cname
    cname=$(container_name "${match_id}")

    if ! docker ps -q --filter "name=^${cname}$" | grep -q .; then
        log_error "Match '${match_id}' is not currently running."
        return 1
    fi

    echo ""
    echo -e "\033[0;33m>>> ATTACHING TO CS2 CONSOLE: ${match_id}\033[0m"
    echo -e "\033[0;32m>>> WARNING: DO NOT PRESS Ctrl+C! It will KILL the server!\033[0m"
    echo -e "\033[0;32m>>> Press 'Ctrl+P' then 'Ctrl+Q' to safely detach and keep it running.\033[0m"
    echo ""
    sleep 2

    docker attach --detach-keys "ctrl-p,ctrl-q" "${cname}"
}

# Try to start the next queued match if there is a free slot
process_queue() {
    local next_entry
    if next_entry=$(dequeue_next); then
        local next_match
        next_match=$(echo "${next_entry}" | cut -d'|' -f1)
        local next_map
        next_map=$(echo "${next_entry}" | cut -d'|' -f2)

        log_info "Dequeuing match '${next_match}' (map: ${next_map})..."
        if ! cmd_start "${next_match}" --map "${next_map}"; then
            log_error "Queued match '${next_match}' failed to start (already removed from queue). Re-queue with: $0 start ${next_match} --map ${next_map}"
        fi
    fi
}

# ===========================================================================
# COMMAND: status
# ===========================================================================
cmd_status() {
    local running
    running=$(count_running)
    local queued=0
    for f in "${QUEUE_DIR}"/*; do
        [[ -f "${f}" ]] && queued=$(( queued + 1 ))
    done

    echo ""
    echo "========================================"
    echo " CS2 Server Pool Status"
    echo " Running: ${running}/${MAX_SERVERS}  |  Queued: ${queued}"
    echo "========================================"
    echo ""

    # Active servers
    local has_active=false
    printf "  %-6s  %-20s  %-10s  %-10s  %-20s\n" "SLOT" "MATCH" "GAME PORT" "TV PORT" "STARTED"
    printf "  %-6s  %-20s  %-10s  %-10s  %-20s\n" "----" "-----" "---------" "-------" "-------"

    for (( slot=0; slot<MAX_SERVERS; slot++ )); do
        if [[ -f "${SLOTS_DIR}/${slot}" ]]; then
            has_active=true
            local data
            data=$(cat "${SLOTS_DIR}/${slot}")
            local mid mmap mtime
            mid=$(echo "${data}" | cut -d'|' -f1)
            mmap=$(echo "${data}" | cut -d'|' -f2)
            mtime=$(echo "${data}" | cut -d'|' -f3)
            local gp tp
            gp=$(game_port_for_slot "${slot}")
            tp=$(tv_port_for_slot "${slot}")
            printf "  %-6s  %-20s  %-10s  %-10s  %-20s\n" "${slot}" "${mid}" "${gp}" "${tp}" "${mtime}"
        fi
    done

    if [[ "${has_active}" == "false" ]]; then
        echo "  (no active servers)"
    fi

    # Queue
    echo ""
    if [[ ${queued} -gt 0 ]]; then
        echo "  Queued matches (FIFO order):"
        local pos=1
        for queue_file in $(ls -1 "${QUEUE_DIR}" 2>/dev/null | sort); do
            local qdata
            qdata=$(cat "${QUEUE_DIR}/${queue_file}")
            local qmatch qmap
            qmatch=$(echo "${qdata}" | cut -d'|' -f1)
            qmap=$(echo "${qdata}" | cut -d'|' -f2)
            echo "    ${pos}. ${qmatch} (map: ${qmap})"
            pos=$(( pos + 1 ))
        done
    else
        echo "  Queue is empty."
    fi
    echo ""
}

# ===========================================================================
# COMMAND: watch
# Daemon mode: listens for Docker container exit events and automatically
# frees slots and starts queued matches. Event-driven, not polling.
# Run this in a tmux/screen session or as a systemd service.
# ===========================================================================
cmd_watch() {
    log_info "Starting watch daemon. Listening for container exit events..."
    log_info "Press Ctrl+C to stop."
    echo ""

    # Start the MatchZy event handler (receives match-end webhooks from
    # containers and triggers docker stop, which we then pick up below)
    start_event_handler

    # Reconcile state on startup: clean up any stale slot files whose
    # containers are no longer running
    reconcile_state

    # Listen for container die events, filtered to our managed containers
    docker events \
        --filter "event=die" \
        --filter "label=${LABEL_KEY}=${LABEL_VAL}" \
        --format '{{index .Actor.Attributes "cs2-match"}} {{index .Actor.Attributes "cs2-slot"}}' \
    | while read -r match_id slot; do
        if [[ -z "${match_id}" || -z "${slot}" ]]; then
            continue
        fi

        log_info "Detected exit: match '${match_id}' on slot ${slot}"

        # Clean up the container
        local cname
        cname=$(container_name "${match_id}")
        if [[ "${CS2_MANAGER_DEBUG}" == "1" ]]; then
            dump_container_exit_debug "${cname}" "watch: container die event"
        fi
        docker rm -f "${cname}" >/dev/null 2>&1 || true

        # Free the slot
        rm -f "${SLOTS_DIR}/${slot}"

        local running
        running=$(count_running)
        log_info "Slot ${slot} freed. (${running}/${MAX_SERVERS} servers active)"

        # Auto-start next queued match
        process_queue
    done
}

# Start the MatchZy event handler as a background process. The handler
# receives webhook POSTs from MatchZy when matches end and calls
# `docker stop` on the container, which generates the die event that the
# watch loop above picks up.
start_event_handler() {
    if [[ ! -f "${EVENT_HANDLER_SCRIPT}" ]]; then
        log_warn "Event handler not found at ${EVENT_HANDLER_SCRIPT}"
        log_warn "Match-end auto-detection will NOT work. Containers must be stopped manually."
        return 0
    fi

    if ! command -v python3 &>/dev/null; then
        log_warn "python3 not found. Match-end auto-detection will NOT work."
        return 0
    fi

    # Kill any previous event handler on this port
    local existing_pid
    existing_pid=$(lsof -ti "tcp:${EVENT_HANDLER_PORT}" 2>/dev/null || true)
    if [[ -n "${existing_pid}" ]]; then
        log_warn "Killing existing process on port ${EVENT_HANDLER_PORT} (PID ${existing_pid})"
        kill "${existing_pid}" 2>/dev/null || true
        sleep 1
    fi

    env EVENT_HANDLER_PORT="${EVENT_HANDLER_PORT}" \
        STATE_DIR="${STATE_DIR}" \
        NESTJS_BACKEND_URL="${NESTJS_BACKEND_URL}" \
        GAME_SERVER_API_KEY="${GAME_SERVER_API_KEY}" \
        RCON_PASSWORD="${RCON_PASSWORD}" \
        python3 "${EVENT_HANDLER_SCRIPT}" &
    local handler_pid=$!

    # Give it a moment to bind the port
    sleep 1
    if kill -0 "${handler_pid}" 2>/dev/null; then
        log_info "MatchZy event handler started (PID ${handler_pid}, port ${EVENT_HANDLER_PORT})"
    else
        log_warn "Event handler failed to start. Match-end auto-detection disabled."
        return 0
    fi

    # Ensure the handler is killed when the watch daemon exits
    trap "kill ${handler_pid} 2>/dev/null; exit" EXIT INT TERM
}

# Reconcile on-disk state with actual Docker containers. Cleans up stale
# slot files left behind if a container was removed outside of this script.
reconcile_state() {
    local cleaned=0
    for (( slot=0; slot<MAX_SERVERS; slot++ )); do
        if [[ -f "${SLOTS_DIR}/${slot}" ]]; then
            local data
            data=$(cat "${SLOTS_DIR}/${slot}")
            local mid
            mid=$(echo "${data}" | cut -d'|' -f1)
            local cname
            cname=$(container_name "${mid}")

            # Check if the container is actually running
            if ! docker ps -q --filter "name=^${cname}$" | grep -q .; then
                log_warn "Stale slot ${slot} (match '${mid}'): container not running. Cleaning up."
                rm -f "${SLOTS_DIR}/${slot}"
                cleaned=$(( cleaned + 1 ))
            fi
        fi
    done

    if [[ ${cleaned} -gt 0 ]]; then
        log_info "Reconciled ${cleaned} stale slot(s). Processing queue..."
        for (( i=0; i<cleaned; i++ )); do
            process_queue
        done
    else
        log_info "State is clean. No stale slots found."
    fi
}

# ===========================================================================
# COMMAND: stop-all
# ===========================================================================
cmd_stop_all() {
    log_info "Stopping ALL managed servers..."

    local stopped=0
    for (( slot=0; slot<MAX_SERVERS; slot++ )); do
        if [[ -f "${SLOTS_DIR}/${slot}" ]]; then
            local data
            data=$(cat "${SLOTS_DIR}/${slot}")
            local mid
            mid=$(echo "${data}" | cut -d'|' -f1)
            local cname
            cname=$(container_name "${mid}")

            docker stop "${cname}" >/dev/null 2>&1 || true
            docker rm -f "${cname}" >/dev/null 2>&1 || true
            rm -f "${SLOTS_DIR}/${slot}"
            stopped=$(( stopped + 1 ))
            log_info "  Stopped: ${mid} (slot ${slot})"
        fi
    done

    # Clear the queue
    local queue_count=0
    for queue_file in "${QUEUE_DIR}"/*; do
        if [[ -f "${queue_file}" ]]; then
            rm -f "${queue_file}"
            queue_count=$(( queue_count + 1 ))
        fi
    done

    log_info "Stopped ${stopped} server(s). Cleared ${queue_count} queued match(es)."
}

# ===========================================================================
# COMMAND: debug-wp <match-id>
# Run diagnostic checks on the WeaponPaints plugin inside a running match
# container. Covers: config files, gamedata, core.json, plugin loading,
# MySQL connectivity, and relevant container log lines.
# ===========================================================================
cmd_debug_wp() {
    local match_id="${1:-}"

    if [[ -z "${match_id}" ]]; then
        log_error "Usage: $0 debug-wp <match-id>"
        exit 1
    fi

    local cname
    cname=$(container_name "${match_id}")

    if ! docker ps -q --filter "name=^${cname}$" | grep -q .; then
        log_error "Match '${match_id}' is not currently running."
        return 1
    fi

    local subdir="${CS2_GAME_CONTENT_SUBDIR}"

    echo ""
    echo -e "\033[1;35m============================================================\033[0m"
    echo -e "\033[1;35m  WeaponPaints Debug Report — match: ${match_id}\033[0m"
    echo -e "\033[1;35m============================================================\033[0m"
    echo ""

    # --- Check 1: WeaponPaints.json config ---
    echo -e "\033[1;36m[1/7] WeaponPaints.json config\033[0m"
    local wp_cfg="/home/steam/cs2-run/game/${subdir}/addons/counterstrikesharp/configs/plugins/WeaponPaints/WeaponPaints.json"
    docker exec "${cname}" sh -c "
        if [ -f '${wp_cfg}' ]; then
            echo '  ✓ File exists: ${wp_cfg}'
            echo '  --- contents (DB credentials redacted) ---'
            cat '${wp_cfg}' | sed 's/\"DatabasePassword\": \"[^\"]*\"/\"DatabasePassword\": \"****\"/'
            echo ''
        else
            echo '  ✗ NOT FOUND: ${wp_cfg}'
            echo '    → entrypoint.sh should have generated this from WP_DB_* env vars.'
        fi
    " 2>&1
    echo ""

    # --- Check 2: weaponpaints.json gamedata ---
    echo -e "\033[1;36m[2/7] Gamedata file\033[0m"
    local gd_file="/home/steam/cs2-run/game/${subdir}/addons/counterstrikesharp/gamedata/weaponpaints.json"
    docker exec "${cname}" sh -c "
        if [ -f '${gd_file}' ]; then
            echo '  ✓ Gamedata file exists: ${gd_file}'
            echo \"  Size: \$(wc -c < '${gd_file}') bytes\"
        else
            echo '  ✗ NOT FOUND: ${gd_file}'
            echo '    → Plugin will refuse to load. Re-run: sudo bash install_cs2.sh --update'
        fi
    " 2>&1
    echo ""

    # --- Check 3: core.json FollowCS2ServerGuidelines ---
    echo -e "\033[1;36m[3/7] core.json — FollowCS2ServerGuidelines\033[0m"
    local core_json="/home/steam/cs2-run/game/${subdir}/addons/counterstrikesharp/configs/core.json"
    docker exec "${cname}" sh -c "
        if [ -f '${core_json}' ]; then
            val=\$(grep -oP '\"FollowCS2ServerGuidelines\"\\s*:\\s*\\K(true|false)' '${core_json}' 2>/dev/null || echo 'NOT_FOUND')
            if [ \"\${val}\" = 'false' ]; then
                echo '  ✓ FollowCS2ServerGuidelines = false (correct)'
            elif [ \"\${val}\" = 'true' ]; then
                echo '  ✗ FollowCS2ServerGuidelines = true (WRONG — skins will be stripped!)'
                echo '    → entrypoint.sh should have patched this. Check the entrypoint logs.'
            else
                echo '  ⚠ Key not found in core.json'
                echo '    → CSSharp may not have initialized yet. Try again after warmup.'
            fi
        else
            echo '  ⚠ core.json not found at ${core_json}'
            echo '    → CSSharp may not be installed or has not run yet.'
        fi
    " 2>&1
    echo ""

    # --- Check 4: WeaponPaints plugin DLL + dependency plugins ---
    echo -e "\033[1;36m[4/7] WeaponPaints plugin files\033[0m"
    local wp_plugin_dir="/home/steam/cs2-run/game/${subdir}/addons/counterstrikesharp/plugins/WeaponPaints"
    docker exec "${cname}" sh -c "
        if [ -d '${wp_plugin_dir}' ]; then
            echo '  ✓ Plugin directory exists'
            echo '  Files:'
            ls -la '${wp_plugin_dir}/' 2>&1 | sed 's/^/    /'
        else
            echo '  ✗ Plugin directory NOT FOUND: ${wp_plugin_dir}'
            echo '    → Re-run: sudo bash install_cs2.sh --update'
        fi
        echo ''
        echo '  Dependency plugins:'
        for dep in MenuManagerCore MenuManagerApi PlayerSettings AnyBaseLib; do
            dep_dir=\"/home/steam/cs2-run/game/${subdir}/addons/counterstrikesharp/plugins/\${dep}\"
            if [ -d \"\${dep_dir}\" ]; then
                echo \"    ✓ \${dep}\"
            else
                echo \"    ✗ \${dep} — MISSING\"
            fi
        done
    " 2>&1
    echo ""

    # --- Check 5: Metamod + CSS loaded plugins (console hints) ---
    echo -e "\033[1;36m[5/7] Metamod + CounterStrikeSharp plugin status\033[0m"
    echo "  Use the server console to verify plugin loading:"
    echo "    ./cs2-server-manager.sh console ${match_id}"
    echo "    → Type: meta list                     (should show CounterStrikeSharp)"
    echo "    → Type: css_plugins list               (should show WeaponPaints + deps)"
    echo ""
    echo "  Checking container logs for 'meta list' / plugin load messages..."
    docker logs --tail 300 "${cname}" 2>&1 \
        | grep -iE '\[META\]|\[CounterStrikeSharp\]|Loaded plugin|plugin.*load|css_plugins' \
        | tail -20 \
        | sed 's/^/    /' \
        || echo "    (no matching log lines found)"
    echo ""

    # --- Check 6: MySQL connectivity ---
    echo -e "\033[1;36m[6/7] MySQL connectivity test\033[0m"
    docker exec "${cname}" sh -c "
        DB_HOST=\${WP_DB_HOST:-192.168.10.50}
        DB_PORT=\${WP_DB_PORT:-3306}
        DB_USER=\${WP_DB_USER:-weaponpaints}
        DB_PASS=\${WP_DB_PASSWORD:-change-me}
        DB_NAME=\${WP_DB_NAME:-weaponpaints}

        echo \"  Target: \${DB_USER}@\${DB_HOST}:\${DB_PORT}/\${DB_NAME}\"

        # Check basic TCP connectivity
        if command -v nc >/dev/null 2>&1; then
            if nc -z -w3 \${DB_HOST} \${DB_PORT} 2>/dev/null; then
                echo '  ✓ TCP connection to MySQL port succeeded'
            else
                echo '  ✗ TCP connection to MySQL port FAILED'
                echo '    → Is weaponpaints-mysql running on the platform host?'
                echo '    → Is the firewall allowing port 3306 from this host?'
            fi
        elif command -v bash >/dev/null 2>&1; then
            if timeout 3 bash -c \"echo >/dev/tcp/\${DB_HOST}/\${DB_PORT}\" 2>/dev/null; then
                echo '  ✓ TCP connection to MySQL port succeeded'
            else
                echo '  ✗ TCP connection to MySQL port FAILED'
                echo '    → Is weaponpaints-mysql running on the platform host?'
                echo '    → Is the firewall allowing port 3306 from this host?'
            fi
        else
            echo '  ⚠ No nc or bash available — cannot test TCP connectivity'
        fi

        # Check if mysql client is available for a real query test
        if command -v mysql >/dev/null 2>&1; then
            result=\$(mysql -h\${DB_HOST} -P\${DB_PORT} -u\${DB_USER} -p\${DB_PASS} \${DB_NAME} \
                -e \"SELECT COUNT(*) as table_count FROM information_schema.TABLES WHERE TABLE_SCHEMA='\${DB_NAME}';\" \
                --skip-column-names 2>&1)
            if [ \$? -eq 0 ]; then
                echo \"  ✓ MySQL auth + query succeeded — \${result} table(s) in \${DB_NAME}\"
                tables=\$(mysql -h\${DB_HOST} -P\${DB_PORT} -u\${DB_USER} -p\${DB_PASS} \${DB_NAME} \
                    -e 'SHOW TABLES;' --skip-column-names 2>/dev/null || true)
                if [ -n \"\${tables}\" ]; then
                    echo '  Tables:'
                    echo \"\${tables}\" | sed 's/^/    /'
                fi
            else
                echo \"  ✗ MySQL query FAILED: \${result}\"
            fi
        else
            echo '  ⚠ mysql client not in container — TCP test only (above)'
            echo '    → Plugin uses its own MySQL driver; TCP connectivity is the key check.'
        fi
    " 2>&1
    echo ""

    # --- Check 7: Recent container logs related to WeaponPaints ---
    echo -e "\033[1;36m[7/7] Container log scan (WeaponPaints / errors)\033[0m"
    echo "  Scanning last 500 log lines for relevant keywords..."
    echo ""
    docker logs --tail 500 "${cname}" 2>&1 \
        | grep -iE 'weaponpaint|weapon_paint|\[WP\]|CounterStrikeSharp|metamod|FollowCS2Server|gamedata|MenuManager|PlayerSettings|AnyBaseLib|mysql|database|exception|error|fail' \
        | grep -viE 'sv_rcon_maxfailure|minfailure' \
        | tail -80 \
        | sed 's/^/  /' \
        || echo "  (no matching log lines found)"
    echo ""

    echo -e "\033[1;35m============================================================\033[0m"
    echo -e "\033[1;35m  Debug Checklist Summary\033[0m"
    echo -e "\033[1;35m============================================================\033[0m"
    echo ""
    echo "  If WeaponPaints is not working, check in order:"
    echo ""
    echo "    1. WeaponPaints.json exists with correct MySQL credentials"
    echo "    2. weaponpaints.json gamedata present in gamedata/"
    echo "    3. core.json FollowCS2ServerGuidelines = false"
    echo "    4. Plugin DLLs + all dependencies present"
    echo "    5. Metamod loaded → CSS loaded → WeaponPaints in css_plugins list"
    echo "    6. MySQL reachable from container (TCP + auth)"
    echo "    7. No errors in container logs"
    echo ""
    echo "  Player commands to test in-game:"
    echo "    !ws       — show website link"
    echo "    !knife    — knife menu"
    echo "    !skins    — weapon skin menu"
    echo "    !gloves   — glove menu"
    echo "    !agents   — agent menu"
    echo "    !music    — music kit menu"
    echo "    !pins     — pins / collectibles menu"
    echo "    !wp       — force re-sync with database"
    echo ""
}

# ===========================================================================
# MAIN: Dispatch subcommand
# ===========================================================================

ensure_dirs


case "${1:-}" in
    start)
        shift
        cmd_start "$@"
        ;;
    stop)
        shift
        cmd_stop "$@"
        ;;
    status)
        cmd_status
        ;;
    watch)
        cmd_watch
        ;;
    stop-all)
        cmd_stop_all
        ;;
    console)
        shift
        cmd_console "$@"
        ;;
    debug-wp)
        shift
        cmd_debug_wp "$@"
        ;;
    *)
        echo "CS2 LAN Tournament Orchestrator - Server Pool Manager"
        echo ""
        echo "Usage:"
        echo "  $0 start <match-id> [--map <map_name>]   Start a match (or queue if pool is full)"
        echo "  $0 stop <match-id>                       Stop a match and free its slot"
        echo "  $0 console <match-id>                    Attach to the game server console as admin"
        echo "  $0 debug-wp <match-id>                   Diagnose WeaponPaints plugin issues"
        echo "  $0 status                                Show running servers and queue"
        echo "  $0 watch                                 Daemon: auto-recycle slots on match end"
        echo "  $0 stop-all                              Stop all servers and clear the queue"
        echo ""
        echo "Configuration (env vars):"
        echo "  MAX_SERVERS=${MAX_SERVERS}  GAME_PORT_BASE=${GAME_PORT_BASE}  TV_PORT_BASE=${TV_PORT_BASE}"
        echo "  MEMORY_LIMIT=${MEMORY_LIMIT}  IMAGE_NAME=${IMAGE_NAME}"
        echo "  CS2_START_VERIFY_SECS=${CS2_START_VERIFY_SECS}  CS2_MANAGER_DEBUG=${CS2_MANAGER_DEBUG} (set to 1 for logs on every container exit in watch)"
        echo "  CS2_GAME_CONTENT_SUBDIR=${CS2_GAME_CONTENT_SUBDIR} (CS2 data under shared .../game/; Valve default cs2)"
        echo ""
        exit 1
        ;;
esac
