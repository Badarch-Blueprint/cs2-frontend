#!/usr/bin/env python3
###############################################################################
# CS2 LAN Tournament Orchestrator - MatchZy Event Handler
# ============================================================================
# Lightweight HTTP server that receives webhook events from MatchZy running
# inside CS2 server containers. When a match ends (map_result or series_end),
# it saves the result and stops the container — triggering the watcher daemon
# to free the slot and auto-start the next queued match.
#
# Also exposes a bridge API for the NestJS tournament platform:
#   POST /api/start   — Start a match server
#   POST /api/stop    — Stop a match server
#   GET  /api/status  — Get slot/queue status
#   POST /events/<id> — MatchZy webhook (original)
#   GET  /health      — Health check
#
# Each container's MatchZy is configured with a unique webhook URL:
#   http://host.docker.internal:<port>/events/<match-id>
#
# Usage (standalone):
#   python3 match-event-handler.py
#
# Normally started automatically by: ./cs2-server-manager.sh watch
#
# Configuration (env vars):
#   EVENT_HANDLER_PORT  - Listen port (default: 32500)
#   STATE_DIR           - Orchestrator state dir (default: /opt/cs2/orchestrator)
#   MANAGER_SCRIPT      - Path to cs2-server-manager.sh (default: auto-detect)
#   NESTJS_BACKEND_URL  - URL to forward results to (optional)
###############################################################################

import http.server
from http.server import ThreadingHTTPServer
import json
import os
import signal
import subprocess
import sys
import socket
import struct
import threading
import time
import urllib.request
import urllib.error
from datetime import datetime

RCON_PASSWORD = os.environ.get("RCON_PASSWORD", "")

EVENT_HANDLER_PORT = int(os.environ.get("EVENT_HANDLER_PORT", "32500"))
STATE_DIR = os.environ.get("STATE_DIR", "/opt/cs2/orchestrator")
RESULTS_DIR = os.path.join(STATE_DIR, "results")
SLOTS_DIR = os.path.join(STATE_DIR, "slots")
QUEUE_DIR = os.path.join(STATE_DIR, "queue")
NESTJS_BACKEND_URL = os.environ.get("NESTJS_BACKEND_URL", "")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MANAGER_SCRIPT = os.environ.get(
    "MANAGER_SCRIPT",
    os.path.join(SCRIPT_DIR, "cs2-server-manager.sh"),
)
MAX_SERVERS = int(os.environ.get("MAX_SERVERS", "11"))

MATCH_END_EVENTS = frozenset({"map_result", "series_end"})


def log_info(msg):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"\033[0;32m[events]\033[0m INFO  {ts} {msg}", flush=True)


def log_warn(msg):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"\033[0;33m[events]\033[0m WARN  {ts} {msg}", file=sys.stderr, flush=True)


def log_error(msg):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"\033[0;31m[events]\033[0m ERROR {ts} {msg}", file=sys.stderr, flush=True)


def forward_to_backend(match_id, event_data):
    """Forward match results to the NestJS backend if configured."""
    if not NESTJS_BACKEND_URL:
        return
    api_key = os.environ.get("GAME_SERVER_API_KEY", "")
    url = f"{NESTJS_BACKEND_URL.rstrip('/')}/api/integrations/game-server/match-results"
    
    # Safely extract scores
    t1 = event_data.get("team1", {})
    t2 = event_data.get("team2", {})
    
    scoreA = t1.get("series_score", t1.get("score", 0))
    scoreB = t2.get("series_score", t2.get("score", 0))
    
    if not isinstance(scoreA, int) and str(scoreA).isdigit():
        scoreA = int(scoreA)
    elif not isinstance(scoreA, int):
        scoreA = 0
        
    if not isinstance(scoreB, int) and str(scoreB).isdigit():
        scoreB = int(scoreB)
    elif not isinstance(scoreB, int):
        scoreB = 0

    try:
        data = json.dumps({
            "matchId": match_id,
            "scoreA": scoreA,
            "scoreB": scoreB
        }).encode("utf-8")
        req = urllib.request.Request(
            url, data=data,
            headers={
                "Content-Type": "application/json",
                "X-Game-Server-Token": api_key
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            log_info(f"[{match_id}] Forwarded event to backend ({resp.status})")
    except (urllib.error.URLError, OSError) as e:
        log_warn(f"[{match_id}] Failed to forward to backend: {e}")


def get_server_status():
    """Read slot and queue state from the filesystem."""
    slots = []
    if os.path.isdir(SLOTS_DIR):
        for fname in sorted(os.listdir(SLOTS_DIR)):
            filepath = os.path.join(SLOTS_DIR, fname)
            try:
                with open(filepath) as f:
                    content = f.read().strip()
                parts = content.split("|")
                slots.append({
                    "slot": int(fname),
                    "matchId": parts[0] if len(parts) > 0 else "",
                    "map": parts[1] if len(parts) > 1 else "",
                    "startedAt": parts[2] if len(parts) > 2 else "",
                })
            except (IOError, ValueError):
                pass

    queue = []
    if os.path.isdir(QUEUE_DIR):
        for fname in sorted(os.listdir(QUEUE_DIR)):
            filepath = os.path.join(QUEUE_DIR, fname)
            try:
                with open(filepath) as f:
                    content = f.read().strip()
                parts = content.split("|")
                queue.append({
                    "matchId": parts[0] if len(parts) > 0 else "",
                    "map": parts[1] if len(parts) > 1 else "",
                })
            except IOError:
                pass

    return {"slots": slots, "queue": queue, "maxSlots": MAX_SERVERS}


def run_manager(args):
    """Run cs2-server-manager.sh with given arguments.

    Child stdout/stderr are mirrored to this process (so `watch` + tmux shows
    [manager] lines and docker debug). Full text is still returned for API JSON.
    """
    if not os.path.isfile(MANAGER_SCRIPT):
        msg = f"MANAGER_SCRIPT not found: {MANAGER_SCRIPT}"
        log_error(msg)
        return 127, "", msg
    cmd = ["/bin/bash", MANAGER_SCRIPT] + list(args)
    log_info(f"Running: {' '.join(cmd)}")
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=int(os.environ.get("MANAGER_SCRIPT_TIMEOUT", "180")),
        )
    except subprocess.TimeoutExpired as exc:
        log_error(f"cs2-server-manager.sh timed out: {exc}")
        return 124, "", str(exc)
    # Mirror captured output to the terminal (otherwise nothing appears under watch).
    if result.stdout:
        for line in result.stdout.splitlines():
            log_info(line)
    if result.stderr:
        for line in result.stderr.splitlines():
            log_warn(line)
    return result.returncode, result.stdout, result.stderr


class SourceRCON:
    """Minimal Source RCON client for sending commands to CS2 servers."""

    def __init__(self, host, port, password):
        self.host = host
        self.port = port
        self.password = password
        self.sock = None

    def __enter__(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.settimeout(3)
        self.sock.connect((self.host, self.port))
        if not self._authenticate():
            raise Exception("RCON Authentication failed")
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self.sock:
            self.sock.close()

    def _authenticate(self):
        # Type 3 = SERVERDATA_AUTH
        # Use a unique ID to distinguish from potential background packets
        req_id = 1234
        self._send_packet(3, self.password, id=req_id)
        
        # The server might send a SERVERDATA_RESPONSE_VALUE packet before 
        # the SERVERDATA_AUTH_RESPONSE. We must loop until we see our ID.
        for _ in range(5):  # Try reading up to 5 packets
            id, type, body = self._read_packet()
            if type == 2:  # SERVERDATA_AUTH_RESPONSE or SERVERDATA_RESPONSE_VALUE
                if id == req_id:
                    return True
                if id == -1:
                    return False
        return False

    def command(self, cmd):
        # Type 2 = SERVERDATA_EXECCOMMAND
        self._send_packet(2, cmd)
        id, type, body = self._read_packet()
        return body

    def _send_packet(self, type, body, id=0):
        # Packet: ID(4) | Type(4) | Body(N) | 0x00 | 0x00
        packet = struct.pack("<ii", id, type) + body.encode("utf-8") + b"\x00\x00"
        size = struct.pack("<i", len(packet))
        self.sock.sendall(size + packet)

    def _read_packet(self):
        def recv_all(n):
            data = b""
            while len(data) < n:
                packet = self.sock.recv(n - len(data))
                if not packet:
                    raise Exception("RCON Connection closed")
                data += packet
            return data

        size_data = recv_all(4)
        size = struct.unpack("<i", size_data)[0]
        data = recv_all(size)
        id, type = struct.unpack("<ii", data[:8])
        body = data[8:-2].decode("utf-8", errors="replace")
        return id, type, body


def bootstrap_match(match_id, gport):
    """Wait for server to boot and load MatchZy config via RCON."""
    log_info(f"[{match_id}] RCON bootstrapper started (waiting for port {gport})...")
    
    # Wait for TCP port to open
    max_wait = 120  # 2 minutes
    start_ts = time.time()
    while time.time() - start_ts < max_wait:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(1)
            if s.connect_ex(("127.0.0.1", gport)) == 0:
                break
        time.sleep(2)
    else:
        log_error(f"[{match_id}] RCON Error: Server port {gport} never opened.")
        return

    log_info(f"[{match_id}] Server port reached. Waiting 10s for plugin init...")
    time.sleep(10)

    # Attempt RCON commands
    try:
        with SourceRCON("127.0.0.1", gport, RCON_PASSWORD) as rcon:
            log_info(f"[{match_id}] RCON: Checking if plugin is ready...")
            rcon.command("css_plugins list")  # Warmup the engine awareness
            
            log_info(f"[{match_id}] RCON: Sending matchzy_loadmatch...")
            resp = rcon.command("matchzy_loadmatch match.json")
            log_info(f"[{match_id}] RCON Response: {resp.strip() or '<empty>'}")
            
            log_info(f"[{match_id}] RCON Bootstrap complete.")
            return True
    except Exception as e:
        log_warn(f"[{match_id}] RCON Failure: {e}")
        return False



class MatchEventHandler(http.server.BaseHTTPRequestHandler):
    """Handles POST /events/<match-id> from MatchZy and bridge API."""

    def do_POST(self):
        path = self.path.rstrip("/")
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b"{}"

        # Bridge API: start match
        if path == "/api/start":
            self._handle_api_start(body)
            return

        # Bridge API: stop match
        if path == "/api/stop":
            self._handle_api_stop(body)
            return

        # Original MatchZy webhook
        path_parts = path.strip("/").split("/")
        if len(path_parts) >= 2 and path_parts[0] == "events":
            self._handle_matchzy_event(path_parts[1], body)
            return

        self._send_json(404, {"error": "not found"})

    def do_GET(self):
        path = self.path.rstrip("/")

        if path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return

        if path == "/api/status":
            status = get_server_status()
            self._send_json(200, status)
            return

        self._send_json(404, {"error": "not found"})

    def _handle_api_start(self, body):
        try:
            data = json.loads(body)
            log_info(f"Incoming /api/start payload: {json.dumps(data)}")
        except json.JSONDecodeError:
            self._send_json(400, {"error": "invalid json"})
            return

        match_id = data.get("matchId", "")
        map_name = data.get("map", "")
        if not match_id:
            self._send_json(400, {"error": "matchId required"})
            return

        team1 = data.get("team1")
        team2 = data.get("team2")
        is_decider = data.get("isDecider", False)
        
        if team1 and team2:
            # MatchZy requires matchid to be an integer
            try:
                numeric_match_id = abs(hash(match_id)) % (10**9)
            except Exception:
                numeric_match_id = 1
                
            matches_dir = os.path.join(STATE_DIR, "matches")
            os.makedirs(matches_dir, exist_ok=True)
            match_file = os.path.join(matches_dir, f"{match_id}.json")
            # NOTE on `cvars`:
            #   Do NOT push `sv_disable_teamselect_menu 1` here.
            #   In CS2 that cvar gates ALL ChangeTeam() calls through the same
            #   engine-side filter — including MatchZy's server-side auto-placement
            #   (player.ChangeTeam(CsTeam.Terrorist/CounterTerrorist)). With it set,
            #   assigned players drop into spec and then have no way to join a
            #   side because the VGUI is disabled. Let MatchZy enforce teams via
            #   its own steamid → team mapping; it already kicks players back to
            #   their correct side if they try to switch. Likewise `mp_humanteam`
            #   is a CS:GO bot cvar with no effect in CS2, so it's dropped too.
            match_config = {
                "matchid": numeric_match_id,
                "num_maps": 1,
                "maplist": [map_name] if map_name else [],
                "team1": team1,
                "team2": team2,
                "cvars": {
                    "matchzy_knife_enabled_default": "true" if is_decider else "false",
                },
            }
            try:
                serialized = json.dumps(match_config, indent=2)
                with open(match_file, "w") as f:
                    f.write(serialized)
                log_info(f"[{match_id}] Generated MatchZy config at {match_file}")
                log_info(f"[{match_id}] Config Content: {serialized}")
            except IOError as e:
                log_error(f"[{match_id}] Failed to write match config: {e}")

        args = ["start", match_id]
        if map_name:
            args += ["--map", map_name]

        # Launch server
        code, stdout, stderr = run_manager(args)
        
        # If successfully launched, wait for RCON bootstrap
        bootstrapped = False
        if code == 0:
            try:
                import re
                port_match = re.search(r"game:(\d+)", stdout) or re.search(r":(\d{5})", stdout)
                if port_match:
                    gport = int(port_match.group(1))
                    # Wait for bootstrap synchronously
                    bootstrapped = bootstrap_match(match_id, gport)
                else:
                    log_warn(f"[{match_id}] Could not parse port from launcher output, RCON bootstrap skipped.")
            except Exception as e:
                log_error(f"[{match_id}] Failed during RCON bootstrap: {e}")

        merged = (stdout or "").strip() + ("\n" + stderr.strip() if stderr and stderr.strip() else "")
        if code == 0:
            self._send_json(
                200,
                {
                    "status": "started",
                    "matchId": match_id,
                    "bootstrap": bootstrapped,
                    "output": stdout.strip(),
                    "log": merged[-8000:] if merged else "",
                }
            )
        else:
            self._send_json(
                500,
                {
                    "status": "error",
                    "matchId": match_id,
                    "error": stderr.strip() or stdout.strip() or f"exit code {code}",
                    "log": merged[-8000:] if merged else "",
                },
            )

    def _handle_api_stop(self, body):
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self._send_json(400, {"error": "invalid json"})
            return

        match_id = data.get("matchId", "")
        if not match_id:
            self._send_json(400, {"error": "matchId required"})
            return

        code, stdout, stderr = run_manager(["stop", match_id])
        merged = (stdout or "").strip() + ("\n" + stderr.strip() if stderr and stderr.strip() else "")
        if code == 0:
            self._send_json(200, {"status": "stopped", "matchId": match_id, "log": merged[-4000:] if merged else ""})
        else:
            self._send_json(
                500,
                {
                    "status": "error",
                    "matchId": match_id,
                    "error": stderr.strip() or stdout.strip() or f"exit code {code}",
                    "log": merged[-4000:] if merged else "",
                },
            )

    def _handle_matchzy_event(self, match_id, body):
        try:
            event = json.loads(body)
        except json.JSONDecodeError:
            log_warn(f"[{match_id}] Invalid JSON payload")
            self._send_json(400, {"error": "invalid json"})
            return

        event_type = event.get("event", "unknown")
        log_info(f"[{match_id}] Event: {event_type}")

        if event_type in MATCH_END_EVENTS:
            self._handle_match_end(match_id, event)

        self._send_json(200, {"ok": True})

    def _handle_match_end(self, match_id, event):
        event_type = event.get("event", "unknown")
        winner_info = self._format_winner(event)
        log_info(f"[{match_id}] Match ended ({event_type}){winner_info}")

        os.makedirs(RESULTS_DIR, exist_ok=True)
        result_file = os.path.join(RESULTS_DIR, f"{match_id}.json")
        try:
            with open(result_file, "w") as f:
                json.dump(event, f, indent=2)
            log_info(f"[{match_id}] Result saved to {result_file}")
        except IOError as e:
            log_error(f"[{match_id}] Failed to save result: {e}")
            
        # Send to platform backend now that match is ended successfully locally
        forward_to_backend(match_id, event)

        container_name = f"cs2-match-{match_id}"
        log_info(f"[{match_id}] Stopping container '{container_name}'...")
        result = subprocess.run(
            ["docker", "stop", "-t", "10", container_name],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            log_info(f"[{match_id}] Container stopped successfully")
        else:
            log_warn(
                f"[{match_id}] docker stop returned code {result.returncode}: "
                f"{result.stderr.strip()}"
            )

    def _send_json(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode("utf-8"))

    @staticmethod
    def _format_winner(event):
        """Extract a human-readable score summary from the event payload."""
        try:
            t1 = event.get("team1", {})
            t2 = event.get("team2", {})
            t1_name = t1.get("name", "Team1")
            t2_name = t2.get("name", "Team2")
            t1_score = t1.get("series_score", t1.get("score", "?"))
            t2_score = t2.get("series_score", t2.get("score", "?"))
            return f" — {t1_name} {t1_score} : {t2_score} {t2_name}"
        except Exception:
            return ""

    def log_message(self, format, *args):
        pass


def main():
    os.makedirs(RESULTS_DIR, exist_ok=True)

    server = ThreadingHTTPServer(("0.0.0.0", EVENT_HANDLER_PORT), MatchEventHandler)

    def shutdown_handler(signum, frame):
        log_info("Shutting down event handler")
        server.server_close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    log_info(f"MatchZy event handler listening on port {EVENT_HANDLER_PORT}")
    log_info(f"Match results saved to {RESULTS_DIR}")
    if NESTJS_BACKEND_URL:
        log_info(f"Forwarding events to {NESTJS_BACKEND_URL}")
    server.serve_forever()


if __name__ == "__main__":
    main()
