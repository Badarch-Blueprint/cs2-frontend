#!/usr/bin/env bash
###############################################################################
# CS2 LAN Tournament Orchestrator - Host Installation Script
# ============================================================================
# Run this script on the HOST MACHINE (Ubuntu 24.04) to:
#   1. Install SteamCMD
#   2. Download the CS2 dedicated server (App ID 730)
#   3. Download and install Metamod:Source, CounterStrikeSharp, MatchZy,
#      and (optionally) CS2 AntiCheat Defense
#   4. Patch gameinfo.gi for Metamod
#   5. Configure SSD-backed swap as an OOM safety net (32GB or 48GB hosts)
#   6. Set correct ownership for the Docker container user (UID 1000)
#
# Usage:
#   sudo bash install_cs2.sh              # Full install
#   sudo bash install_cs2.sh --update     # Update CS2 + re-apply plugins
#
# The script populates a single shared directory that all Docker containers
# bind-mount read-only, saving ~35GB of SSD space per additional server.
###############################################################################

set -euo pipefail

# ===========================================================================
# VERSION CONFIGURATION
# Update these variables when new releases are available.
# ===========================================================================

# CS2 Dedicated Server (Valve App ID)
readonly CS2_APP_ID="730"

# Metamod:Source — https://github.com/alliedmodders/metamod-source/releases
# Build 1396 is the first release compiled against the Apr 2026 hl2sdk-cs2
# bump. Earlier builds (e.g. 1391) silently break on the current CS2 build:
# engine->GetGameDir() returns "", mod_path becomes empty, and Metamod tries
# to scan "/addons/metamod" instead of "<modroot>/addons/metamod". Pin to 1396
# or newer to avoid the "[META] Loaded 0 plugins" zombie state.
readonly METAMOD_VERSION="2.0.0-git1396"
readonly METAMOD_URL="https://github.com/alliedmodders/metamod-source/releases/download/2.0.0.1396/mmsource-${METAMOD_VERSION}-linux.tar.gz"

# CounterStrikeSharp — https://github.com/roflmuffin/CounterStrikeSharp/releases
readonly CSS_VERSION="365"
readonly CSS_URL="https://github.com/roflmuffin/CounterStrikeSharp/releases/download/v1.0.${CSS_VERSION}/counterstrikesharp-with-runtime-linux-1.0.${CSS_VERSION}.zip"

# AG2 HOTFIX OVERLAY (temporary — remove once CSSharp 1.0.366 ships officially)
# ----------------------------------------------------------------------------
# The Apr 21 2026 CS2 "AnimGraph2" update changed tier0 symbol exports, which
# breaks the 1.0.365 native plugin with:
#     undefined symbol: _Z21ThreadAtomicNotifyOnePj
# Fix lives in the still-draft PR #1279 (branch fix/ag2-update). Its GitHub
# Actions CI publishes two artifacts per push: the Linux native build and the
# managed .NET 8 API assemblies. nightly.link fronts them without auth.
# We keep 1.0.365 as the baseline (for the .NET runtime at addons/counterstrikesharp/dotnet/
# and the layout) and overlay the 1.0.366 native .so + managed API DLLs on top.
# When upstream tags v1.0.366 on GitHub Releases, bump CSS_VERSION above and set
# CSS_AG2_OVERLAY_ENABLE=0 to skip this block.
readonly CSS_AG2_OVERLAY_ENABLE="${CSS_AG2_OVERLAY_ENABLE:-1}"
readonly CSS_AG2_RUN_ID="24721783723"    # workflow run id for PR #1279 build .6
readonly CSS_AG2_BUILD_TAG="1.0.366-PullRequest1279.6"
readonly CSS_AG2_LINUX_URL="https://nightly.link/roflmuffin/CounterStrikeSharp/actions/runs/${CSS_AG2_RUN_ID}/counterstrikesharp-linux-${CSS_AG2_BUILD_TAG}.zip"
readonly CSS_AG2_API_URL="https://nightly.link/roflmuffin/CounterStrikeSharp/actions/runs/${CSS_AG2_RUN_ID}/counterstrikesharp-api-${CSS_AG2_BUILD_TAG}.zip"

# MatchZy — https://github.com/shobhit-pathak/MatchZy/releases
readonly MATCHZY_VERSION="0.8.15"
readonly MATCHZY_URL="https://github.com/shobhit-pathak/MatchZy/releases/download/${MATCHZY_VERSION}/MatchZy-${MATCHZY_VERSION}.zip"

# TBAntiCheat (open-source server-side AC) — https://github.com/killerbigpoint/cs2-anticheat/releases
readonly TBAC_VERSION="0.4.1"
readonly TBAC_URL="https://github.com/killerbigpoint/cs2-anticheat/releases/download/${TBAC_VERSION}/TBAntiCheat.zip"

# WeaponPaints (skin-changer) — https://github.com/Nereziel/cs2-WeaponPaints/releases
readonly WEAPONPAINTS_BUILD="build-414"
readonly WEAPONPAINTS_URL="https://github.com/Nereziel/cs2-WeaponPaints/releases/download/${WEAPONPAINTS_BUILD}/WeaponPaints.zip"

# MenuManagerCS2 (WeaponPaints dep) — https://github.com/NickFox007/MenuManagerCS2/releases
readonly MENUMGR_VERSION="1.4.1"
readonly MENUMGR_URL="https://github.com/NickFox007/MenuManagerCS2/releases/download/${MENUMGR_VERSION}/MenuManager.zip"

# PlayerSettingsCS2 (WeaponPaints dep, via MenuManager) — https://github.com/NickFox007/PlayerSettingsCS2/releases
readonly PLAYERSETTINGS_VERSION="0.9.4"
readonly PLAYERSETTINGS_URL="https://github.com/NickFox007/PlayerSettingsCS2/releases/download/${PLAYERSETTINGS_VERSION}/PlayerSettings.zip"

# AnyBaseLibCS2 (WeaponPaints dep, via PlayerSettings) — https://github.com/NickFox007/AnyBaseLibCS2/releases
readonly ANYBASELIB_VERSION="0.9.4"
readonly ANYBASELIB_URL="https://github.com/NickFox007/AnyBaseLibCS2/releases/download/${ANYBASELIB_VERSION}/AnyBaseLib.zip"

# CS2 AntiCheat Defense (commercial plugin — set URL if you have it)
# Leave empty to skip. The script will print manual installation instructions.
# Example: CS2_ACD_URL="https://example.com/cs2-anticheat-defense-v1.1.0-linux.zip"
readonly CS2_ACD_URL="${CS2_ACD_URL:-}"

# ===========================================================================
# SWAP CONFIGURATION
# Safety net for 32GB or 48GB RAM hosts running many containers.
# Swap on the SSD prevents the OOM Killer from crashing the machine when
# memory pressure spikes. The kernel only pages out to swap when RAM is
# nearly full (swappiness=10), so normal operation stays in RAM.
# ===========================================================================

# Size of the swap file in gigabytes. 16GB is a safe default.
#   32GB host: 16 servers * 2.5GB = 40GB needed, swap covers the ~8GB gap
#   48GB host: swap acts as emergency overflow only
readonly SWAP_SIZE_GB="${SWAP_SIZE_GB:-16}"

# Swappiness: 10 means the kernel strongly prefers RAM and only swaps under
# real pressure. Default Linux is 60 which is way too aggressive for gameservers.
readonly SWAPPINESS="${SWAPPINESS:-10}"

# Path to the swap file on the SSD
readonly SWAP_FILE="/swapfile"

# ===========================================================================
# DIRECTORY CONFIGURATION
# ===========================================================================

# Root directory for all CS2 data on the host
readonly CS2_ROOT="/opt/cs2"

# Shared game files (mounted read-only by all containers)
readonly SHARED_DIR="${CS2_ROOT}/shared"

# Per-server writable directories (one per container)
readonly SERVERS_DIR="${CS2_ROOT}/servers"

# Temporary directory for downloads
readonly TMP_DIR="/tmp/cs2-install"

# SteamCMD installation directory
readonly STEAMCMD_DIR="${CS2_ROOT}/steamcmd"

# Convenience paths
readonly GAME_DIR="${SHARED_DIR}/game"
# CS2 dedicated server content path on disk (Valve uses the folder name "cs2" under game/).
readonly CS2_GAME_DATA_DIR="${GAME_DIR}/csgo"

# UID/GID of the "steam" user inside containers (must match Dockerfile)
readonly STEAM_UID=1000
readonly STEAM_GID=1000

# ===========================================================================
# LOGGING
# ===========================================================================
log_info()  { echo -e "\033[0;32m[install]\033[0m INFO  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "\033[0;33m[install]\033[0m WARN  $(date '+%H:%M:%S') $*" >&2; }
log_error() { echo -e "\033[0;31m[install]\033[0m ERROR $(date '+%H:%M:%S') $*" >&2; }

# ===========================================================================
# PRE-FLIGHT CHECKS
# ===========================================================================

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (or with sudo)."
    exit 1
fi

# Parse flags
UPDATE_MODE=false
if [[ "${1:-}" == "--update" ]]; then
    UPDATE_MODE=true
    log_info "Running in UPDATE mode (CS2 update + plugin refresh)"
fi

# ===========================================================================
# STEP 1: Install system dependencies and SteamCMD
# ===========================================================================
log_info "=== Step 1/9: Installing system dependencies ==="

apt-get update -qq
apt-get install -y --no-install-recommends \
    curl \
    wget \
    lib32gcc-s1 \
    ca-certificates \
    unzip \
    tar \
    python3

mkdir -p "${STEAMCMD_DIR}" "${SHARED_DIR}" "${SERVERS_DIR}" "${TMP_DIR}"

if [[ ! -f "${STEAMCMD_DIR}/steamcmd.sh" ]]; then
    log_info "Downloading SteamCMD..."
    curl -sSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
        | tar -xz -C "${STEAMCMD_DIR}"
    log_info "SteamCMD installed to ${STEAMCMD_DIR}"
else
    log_info "SteamCMD already installed at ${STEAMCMD_DIR}"
fi

# ===========================================================================
# STEP 2: Download / Update CS2 Dedicated Server (App ID 730)
# ===========================================================================
log_info "=== Step 2/9: CS2 dedicated server (App ${CS2_APP_ID}) ==="

if [[ -f "${GAME_DIR}/bin/linuxsteamrt64/cs2" ]] && [[ "${UPDATE_MODE}" == false ]]; then
    log_info "CS2 binary already present at ${GAME_DIR}/bin/linuxsteamrt64/cs2"
    log_info "Skipping SteamCMD download/validation. Use --update to force re-validation."
else
    log_info "Install directory: ${SHARED_DIR}"
    if [[ "${UPDATE_MODE}" == true ]]; then
        log_info "UPDATE mode: re-validating existing installation..."
    else
        log_info "This may take 20-40 minutes on first install (~35GB download)."
    fi

    "${STEAMCMD_DIR}/steamcmd.sh" \
        +force_install_dir "${SHARED_DIR}" \
        +login anonymous \
        +app_update "${CS2_APP_ID}" validate \
        +quit

    if [[ ! -f "${GAME_DIR}/bin/linuxsteamrt64/cs2" ]]; then
        log_error "CS2 binary not found after installation. SteamCMD may have failed."
        log_error "Check the output above for errors and retry."
        exit 1
    fi

    log_info "CS2 dedicated server installed successfully."
fi

# ===========================================================================
# STEP 3: Install Metamod:Source
# ===========================================================================
log_info "=== Step 3/9: Installing Metamod:Source (${METAMOD_VERSION}) ==="

METAMOD_ARCHIVE="${TMP_DIR}/metamod.tar.gz"
curl -sSL -o "${METAMOD_ARCHIVE}" --fail "${METAMOD_URL}" || {
    log_error "Failed to download Metamod:Source from ${METAMOD_URL}"
    log_error "Check that the version (${METAMOD_VERSION}) exists at:"
    log_error "  https://github.com/alliedmodders/metamod-source/releases"
    exit 1
}

# Metamod extracts into CS2 game data dir (game/cs2/ on Linux DS).
tar -xzf "${METAMOD_ARCHIVE}" -C "${CS2_GAME_DATA_DIR}"

log_info "Metamod:Source extracted to ${CS2_GAME_DATA_DIR}/addons/metamod/"

# Verify key file
if [[ ! -f "${CS2_GAME_DATA_DIR}/addons/metamod/bin/linuxsteamrt64/server.so" ]] && \
   [[ ! -f "${CS2_GAME_DATA_DIR}/addons/metamod.vdf" ]]; then
    log_warn "Metamod files may not have extracted correctly. Verify manually."
fi

# ===========================================================================
# STEP 4: Install CounterStrikeSharp
# ===========================================================================
log_info "=== Step 4/9: Installing CounterStrikeSharp (build ${CSS_VERSION}) ==="

CSS_ARCHIVE="${TMP_DIR}/counterstrikesharp.zip"
curl -sSL -o "${CSS_ARCHIVE}" --fail "${CSS_URL}" || {
    log_error "Failed to download CounterStrikeSharp from ${CSS_URL}"
    exit 1
}

# CounterStrikeSharp → CS2 game data directory (game/cs2/).
unzip -o -q "${CSS_ARCHIVE}" -d "${CS2_GAME_DATA_DIR}"

log_info "CounterStrikeSharp extracted to ${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/"

if [[ ! -d "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp" ]]; then
    log_warn "CounterStrikeSharp directory not found after extraction. Verify the archive."
fi

# ---------------------------------------------------------------------------
# CounterStrikeSharp AG2 hotfix overlay (see CSS_AG2_* block at top of file).
# Replaces counterstrikesharp.so + api/*.dll with the PR #1279 CI build so the
# plugin loads against the Apr 21 2026 CS2 engine. Harmless to re-run.
# ---------------------------------------------------------------------------
if [[ "${CSS_AG2_OVERLAY_ENABLE}" == "1" ]]; then
    log_info "=== Step 4b: Applying CSSharp AG2 hotfix overlay (${CSS_AG2_BUILD_TAG}) ==="

    CSS_AG2_LINUX_ZIP="${TMP_DIR}/css-ag2-linux.zip"
    CSS_AG2_API_ZIP="${TMP_DIR}/css-ag2-api.zip"
    CSS_AG2_API_STAGE="${TMP_DIR}/css-ag2-api-stage"

    curl -sSL --fail -o "${CSS_AG2_LINUX_ZIP}" "${CSS_AG2_LINUX_URL}" || {
        log_error "Failed to download CSSharp AG2 linux overlay from ${CSS_AG2_LINUX_URL}"
        log_error "If nightly.link is down, set CSS_AG2_OVERLAY_ENABLE=0 and wait for v1.0.366."
        exit 1
    }
    curl -sSL --fail -o "${CSS_AG2_API_ZIP}" "${CSS_AG2_API_URL}" || {
        log_error "Failed to download CSSharp AG2 api overlay from ${CSS_AG2_API_URL}"
        exit 1
    }

    # The linux zip already has addons/counterstrikesharp/... prefix, so it
    # drops straight onto CS2_GAME_DATA_DIR and rewrites the native .so in place.
    unzip -o -q "${CSS_AG2_LINUX_ZIP}" -d "${CS2_GAME_DATA_DIR}"

    # The api zip is flat (net8.0/*.dll at root). Stage and overlay onto api/.
    rm -rf "${CSS_AG2_API_STAGE}"
    mkdir -p "${CSS_AG2_API_STAGE}"
    unzip -o -q "${CSS_AG2_API_ZIP}" -d "${CSS_AG2_API_STAGE}"
    if [[ -d "${CSS_AG2_API_STAGE}/net8.0" ]]; then
        mkdir -p "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/api"
        cp -af "${CSS_AG2_API_STAGE}/net8.0/." "${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/api/"
    else
        log_warn "AG2 api zip had no net8.0/ dir — layout may have changed upstream"
    fi
    rm -rf "${CSS_AG2_API_STAGE}"

    log_info "CSSharp AG2 overlay applied (native .so + managed api/ replaced)"
else
    log_info "CSS_AG2_OVERLAY_ENABLE=0 — skipping AG2 hotfix overlay"
fi

# ===========================================================================
# STEP 5: Install MatchZy
# ===========================================================================
log_info "=== Step 5/9: Installing MatchZy (v${MATCHZY_VERSION}) ==="

MATCHZY_ARCHIVE="${TMP_DIR}/matchzy.zip"
curl -sSL -o "${MATCHZY_ARCHIVE}" --fail "${MATCHZY_URL}" || {
    log_error "Failed to download MatchZy from ${MATCHZY_URL}"
    exit 1
}

# MatchZy → CS2 game data directory.
unzip -o -q "${MATCHZY_ARCHIVE}" -d "${CS2_GAME_DATA_DIR}"

log_info "MatchZy extracted to ${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/plugins/MatchZy/"

# ===========================================================================
# STEP 6: Install TBAntiCheat (open-source server-side anti-cheat)
# ===========================================================================
log_info "=== Step 6/10: Installing TBAntiCheat (v${TBAC_VERSION}) ==="

TBAC_ARCHIVE="${TMP_DIR}/tbanticheat.zip"
curl -sSL -o "${TBAC_ARCHIVE}" --fail "${TBAC_URL}" || {
    log_error "Failed to download TBAntiCheat from ${TBAC_URL}"
    log_error "Check that version ${TBAC_VERSION} exists at:"
    log_error "  https://github.com/killerbigpoint/cs2-anticheat/releases"
    exit 1
}

TBAC_PLUGINS_DIR="${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/plugins"
mkdir -p "${TBAC_PLUGINS_DIR}"
unzip -o -q "${TBAC_ARCHIVE}" -d "${TBAC_PLUGINS_DIR}"

if [[ -d "${TBAC_PLUGINS_DIR}/TBAntiCheat" ]]; then
    log_info "TBAntiCheat extracted to ${TBAC_PLUGINS_DIR}/TBAntiCheat/"
else
    log_warn "TBAntiCheat directory not found after extraction. Verify the archive."
fi

# ===========================================================================
# STEP 7: Install WeaponPaints skin-changer + its dependencies
# ----------------------------------------------------------------------------
# The Nereziel cs2-WeaponPaints plugin needs three helper plugins (MenuManager,
# PlayerSettings, AnyBaseLib) plus a game-data patch and the core.json
# "FollowCS2ServerGuidelines" flag flipped to false. All four release zips
# already wrap their payload in the correct directory layout so extracting
# into the plugins folder places them at:
#   addons/counterstrikesharp/plugins/WeaponPaints/
#   addons/counterstrikesharp/plugins/MenuManagerCore/ (and MenuManagerApi)
#   addons/counterstrikesharp/plugins/PlayerSettings/
#   addons/counterstrikesharp/plugins/AnyBaseLib/
#
# Per-server WeaponPaints.json (with MySQL creds) is generated by
# entrypoint.sh at container start — we don't write it here.
# ===========================================================================
log_info "=== Step 7/10: Installing WeaponPaints stack (${WEAPONPAINTS_BUILD}) ==="

CSS_PLUGINS_DIR="${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/plugins"
CSS_GAMEDATA_DIR="${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/gamedata"
CSS_CORE_JSON="${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/configs/core.json"
mkdir -p "${CSS_PLUGINS_DIR}" "${CSS_GAMEDATA_DIR}"

# Scrub any nested leftovers from older install_cs2.sh runs that extracted
# these zips directly into CSS_PLUGINS_DIR without flattening the
# "addons/counterstrikesharp/..." prefix. Those leftovers are dead weight
# (CSS never scans them) and also confuse later diff-checks.
if [[ -d "${CSS_PLUGINS_DIR}/addons" ]]; then
    log_info "Cleaning stale nested dir ${CSS_PLUGINS_DIR}/addons"
    rm -rf "${CSS_PLUGINS_DIR}/addons"
fi
if [[ -d "${CSS_PLUGINS_DIR}/gamedata" ]]; then
    log_info "Cleaning stale nested dir ${CSS_PLUGINS_DIR}/gamedata"
    rm -rf "${CSS_PLUGINS_DIR}/gamedata"
fi

install_css_zip() {
    # Robust CSS plugin installer: tolerates zips packaged either as
    #   (a) addons/counterstrikesharp/plugins/<Plugin>/...  (nested style)
    #   (b) <Plugin>/...                                    (flat style)
    #   (c) gamedata/*.json at archive root                 (WeaponPaints)
    # by extracting into a temp dir and moving content into the right place.
    # $1 = friendly name, $2 = download URL
    local name="$1"
    local url="$2"
    local archive="${TMP_DIR}/$(basename "${url}")"
    local stage
    stage="$(mktemp -d -p "${TMP_DIR}" extract.XXXXXX)"

    curl -sSL -o "${archive}" --fail "${url}" || {
        log_error "Failed to download ${name} from ${url}"
        rm -rf "${stage}"
        exit 1
    }

    unzip -o -q "${archive}" -d "${stage}" || {
        log_error "Failed to unzip ${name}"
        rm -rf "${stage}"
        exit 1
    }

    # (a) / (c): if the zip contains an addons/ tree, merge it straight
    # into CS2_GAME_DATA_DIR so addons/counterstrikesharp/plugins/... lands
    # exactly where CSS expects. cp -a preserves perms + symlinks.
    if [[ -d "${stage}/addons" ]]; then
        mkdir -p "${CS2_GAME_DATA_DIR}/addons"
        cp -a "${stage}/addons/." "${CS2_GAME_DATA_DIR}/addons/"
    fi

    # (b): handle any plugin folder placed at the zip root (WeaponPaints.zip
    # extracts `WeaponPaints/` at top). Anything that isn't the already-handled
    # addons/ tree is treated as a drop-in plugin folder.
    shopt -s nullglob
    for entry in "${stage}"/*/; do
        local base
        base="$(basename "${entry}")"
        [[ "${base}" == "addons" ]] && continue
        cp -a "${entry}" "${CSS_PLUGINS_DIR}/"
    done
    shopt -u nullglob

    rm -rf "${stage}"
    log_info "  ${name} installed"
}

install_css_zip "AnyBaseLib v${ANYBASELIB_VERSION}" "${ANYBASELIB_URL}"
install_css_zip "PlayerSettings v${PLAYERSETTINGS_VERSION}" "${PLAYERSETTINGS_URL}"
install_css_zip "MenuManager v${MENUMGR_VERSION}" "${MENUMGR_URL}"
install_css_zip "WeaponPaints ${WEAPONPAINTS_BUILD}" "${WEAPONPAINTS_URL}"

# Copy the plugin-provided gamedata file into CSSharp's shared gamedata/ dir.
# Without this the plugin fails with "You need to upload weaponpaints.json".
# Depending on the zip layout the source can live in either of two places.
WP_GAMEDATA_CANDIDATES=(
    "${CSS_PLUGINS_DIR}/WeaponPaints/gamedata/weaponpaints.json"
    "${CSS_GAMEDATA_DIR}/weaponpaints.json"
)
WP_GAMEDATA_FOUND=""
for cand in "${WP_GAMEDATA_CANDIDATES[@]}"; do
    if [[ -f "${cand}" ]]; then
        WP_GAMEDATA_FOUND="${cand}"
        break
    fi
done
if [[ -n "${WP_GAMEDATA_FOUND}" ]]; then
    cp -f "${WP_GAMEDATA_FOUND}" "${CSS_GAMEDATA_DIR}/weaponpaints.json"
    log_info "WeaponPaints gamedata present at ${CSS_GAMEDATA_DIR}/weaponpaints.json"
else
    log_warn "WeaponPaints gamedata file not found — plugin will refuse to load"
fi

# Patch CounterStrikeSharp core.json: FollowCS2ServerGuidelines must be false,
# otherwise custom skins are silently stripped by the engine.
if [[ -f "${CSS_CORE_JSON}" ]]; then
    python3 - "${CSS_CORE_JSON}" <<'PYEOF'
import json, sys
p = sys.argv[1]
try:
    with open(p) as f:
        data = json.load(f)
except Exception:
    data = {}
before = data.get("FollowCS2ServerGuidelines")
data["FollowCS2ServerGuidelines"] = False
with open(p, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"[install] core.json FollowCS2ServerGuidelines: {before} -> false")
PYEOF
else
    log_warn "core.json not found at ${CSS_CORE_JSON} — CounterStrikeSharp may be misinstalled"
fi

# ===========================================================================
# STEP 8: Install CS2 AntiCheat Defense (optional)
# ===========================================================================
log_info "=== Step 8/10: CS2 AntiCheat Defense ==="

if [[ -n "${CS2_ACD_URL}" ]]; then
    log_info "Downloading CS2 AntiCheat Defense from configured URL..."

    ACD_ARCHIVE="${TMP_DIR}/cs2-anticheat-defense.zip"
    curl -sSL -o "${ACD_ARCHIVE}" --fail "${CS2_ACD_URL}" || {
        log_error "Failed to download CS2 AntiCheat Defense from ${CS2_ACD_URL}"
        exit 1
    }
    unzip -o -q "${ACD_ARCHIVE}" -d "${CS2_GAME_DATA_DIR}"

    log_info "CS2 AntiCheat Defense installed."
else
    log_warn "CS2_ACD_URL is not set — skipping CS2 AntiCheat Defense auto-install."
    log_warn ""
    log_warn "  To install manually, download the plugin and extract it to:"
    log_warn "    ${CS2_GAME_DATA_DIR}/addons/counterstrikesharp/plugins/"
    log_warn ""
    log_warn "  To enable auto-install, set the CS2_ACD_URL environment variable:"
    log_warn "    export CS2_ACD_URL=\"https://your-download-url/cs2-acd.zip\""
    log_warn "    sudo -E bash install_cs2.sh"
    log_warn ""
fi

# ===========================================================================
# STEP 9: Patch gameinfo.gi for Metamod
# ===========================================================================
log_info "=== Step 9/10: Patching gameinfo.gi for Metamod ==="

GAMEINFO_FILE="${CS2_GAME_DATA_DIR}/gameinfo.gi"

if [[ ! -f "${GAMEINFO_FILE}" ]]; then
    log_error "gameinfo.gi not found at ${GAMEINFO_FILE}"
    log_error "CS2 installation may be incomplete."
    exit 1
fi

# Check if the Metamod entry already exists (idempotent)
if grep -q "cs2/addons/metamod" "${GAMEINFO_FILE}"; then
    log_info "Metamod entry already present in gameinfo.gi — no patch needed."
else
    # Insert the Metamod Game path entry right after the Game_LowViolence line.
    # This is the required position for Source 2 engine mod loading.
    sed -i '/Game_LowViolence/a\\t\t\tGame\tcs2/addons/metamod' "${GAMEINFO_FILE}"

    if grep -q "cs2/addons/metamod" "${GAMEINFO_FILE}"; then
        log_info "Successfully patched gameinfo.gi with Metamod entry."
    else
        log_error "Failed to patch gameinfo.gi. You may need to add the following manually:"
        log_error "  Under SearchPaths, after Game_LowViolence line, add:"
        log_error "    Game    cs2/addons/metamod"
        exit 1
    fi
fi

# ===========================================================================
# STEP 10: Configure SSD swap as OOM safety net
# ===========================================================================
log_info "=== Step 10/10: Configuring swap (${SWAP_SIZE_GB}GB, swappiness=${SWAPPINESS}) ==="

if swapon --show | grep -q "${SWAP_FILE}"; then
    log_info "Swap file ${SWAP_FILE} is already active — skipping creation."
else
    if [[ -f "${SWAP_FILE}" ]]; then
        log_info "Swap file exists but is not active. Activating..."
    else
        log_info "Creating ${SWAP_SIZE_GB}GB swap file at ${SWAP_FILE}..."
        dd if=/dev/zero of="${SWAP_FILE}" bs=1G count="${SWAP_SIZE_GB}" status=progress
        chmod 600 "${SWAP_FILE}"
        mkswap "${SWAP_FILE}"
    fi

    swapon "${SWAP_FILE}"
    log_info "Swap activated."
fi

# Make swap persistent across reboots via /etc/fstab
if ! grep -q "${SWAP_FILE}" /etc/fstab; then
    echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
    log_info "Swap entry added to /etc/fstab for persistence."
else
    log_info "Swap entry already present in /etc/fstab."
fi

# Set swappiness (runtime)
sysctl vm.swappiness="${SWAPPINESS}"

# Make swappiness persistent across reboots
SYSCTL_CONF="/etc/sysctl.d/99-cs2-swap.conf"
echo "vm.swappiness=${SWAPPINESS}" > "${SYSCTL_CONF}"
log_info "Swappiness set to ${SWAPPINESS} (persisted in ${SYSCTL_CONF})."

# Report current swap status
log_info "Swap status:"
swapon --show
free -h | grep -i swap

# ===========================================================================
# FINAL: Set ownership, create server slot dirs, and orchestrator state
# ===========================================================================
log_info "=== Setting file ownership (UID:GID = ${STEAM_UID}:${STEAM_GID}) ==="

chown -R "${STEAM_UID}:${STEAM_GID}" "${SHARED_DIR}"
chown -R "${STEAM_UID}:${STEAM_GID}" "${SERVERS_DIR}"

# Number of server slots to pre-create (matches MAX_SERVERS default in
# cs2-server-manager.sh). Each slot gets its own writable directory.
MAX_SLOTS="${MAX_SLOTS:-11}"

for (( slot=0; slot<MAX_SLOTS; slot++ )); do
    mkdir -p "${SERVERS_DIR}/slot-${slot}"
    chown -R "${STEAM_UID}:${STEAM_GID}" "${SERVERS_DIR}/slot-${slot}"
done
log_info "Created ${MAX_SLOTS} server slot directories: ${SERVERS_DIR}/slot-{0..$(( MAX_SLOTS - 1 ))}"

# Create orchestrator state directories used by cs2-server-manager.sh
ORCHESTRATOR_DIR="${CS2_ROOT}/orchestrator"
mkdir -p "${ORCHESTRATOR_DIR}/slots" "${ORCHESTRATOR_DIR}/queue"
chown -R "${STEAM_UID}:${STEAM_GID}" "${ORCHESTRATOR_DIR}"
log_info "Created orchestrator state directory: ${ORCHESTRATOR_DIR}"

# Clean up temp files
rm -rf "${TMP_DIR}"

# ===========================================================================
# SUMMARY
# ===========================================================================
log_info ""
log_info "========================================="
log_info " CS2 LAN Tournament Orchestrator"
log_info " Installation Complete"
log_info "========================================="
log_info ""
log_info " Shared game files : ${SHARED_DIR}"
log_info " Server slot dirs  : ${SERVERS_DIR}/slot-{0..$(( MAX_SLOTS - 1 ))}"
log_info " Orchestrator      : ${ORCHESTRATOR_DIR}"
log_info " SteamCMD          : ${STEAMCMD_DIR}"
log_info ""
log_info " Swap             : ${SWAP_SIZE_GB}GB at ${SWAP_FILE} (swappiness=${SWAPPINESS})"
log_info ""
log_info " Installed components:"
log_info "   - CS2 Dedicated Server (App ${CS2_APP_ID})"
log_info "   - Metamod:Source ${METAMOD_VERSION}"
log_info "   - CounterStrikeSharp build ${CSS_VERSION}"
log_info "   - MatchZy v${MATCHZY_VERSION}"
log_info "   - TBAntiCheat v${TBAC_VERSION} (server-side anti-cheat)"
log_info "   - WeaponPaints ${WEAPONPAINTS_BUILD} (skin-changer)"
log_info "     + MenuManager v${MENUMGR_VERSION}, PlayerSettings v${PLAYERSETTINGS_VERSION}, AnyBaseLib v${ANYBASELIB_VERSION}"
if [[ -n "${CS2_ACD_URL}" ]]; then
    log_info "   - CS2 AntiCheat Defense (auto-installed)"
else
    log_warn "   - CS2 AntiCheat Defense (NOT installed — set CS2_ACD_URL)"
fi
log_info ""
log_info " Next steps:"
log_info "   1. Review configs in ${CS2_GAME_DATA_DIR}/cfg/"
log_info "   2. Build image: docker compose build"
log_info "   3. Start matches: ./cs2-server-manager.sh start <match-id>"
log_info "   4. Run watcher:   ./cs2-server-manager.sh watch"
log_info ""
