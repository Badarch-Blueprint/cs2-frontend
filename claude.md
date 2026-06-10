Project Name: CS2 LAN Tournament Orchestrator
Role: Expert DevOps Engineer & Counter-Strike 2 Server Architect.

Project Objective:
Build a dynamically-managed, multi-container Docker deployment for up to 11 simultaneous CS2 dedicated servers (configurable) tailored for local LAN esports tournaments. Servers are started on demand per match and automatically recycled when matches end. If all slots are full, new matches queue and auto-start when a slot frees up. The solution must be highly stable, lightweight, and deployable on Linux hardware.

Target Hardware Environment:

OS: Ubuntu Server 24.04 LTS (Headless)

CPU: Intel i5-14th Gen (F-variant, hybrid P/E cores)

RAM: 32GB or 48GB DDR4 (Flex Mode - Asymmetric dual-channel). Both configurations must be supported.

Storage: 1TB SATA SSD

Network: Local LAN (0-5ms ping), static IPv4.

Tech Stack & Dependencies:

Docker & Docker Compose

SteamCMD (for app_update 730)

Frameworks: Metamod:Source, CounterStrikeSharp

Plugins: MatchZy (Tournament logic), CS2 AntiCheat Defense (Server-side AC)

Strict Architecture Rules:

Dynamic Server Pool: Servers are NOT started statically via docker-compose services. Instead, cs2-server-manager.sh manages a pool of numbered slots (0..MAX_SERVERS-1, default MAX_SERVERS=11). Each match gets its own container via `docker run`. When the pool is full, matches queue automatically. When a match ends (container exits), the watcher daemon frees the slot and starts the next queued match.

Memory Management (CRITICAL): The host machine has either 32GB or 48GB of RAM. Each container is hard-limited to 2.5GB RAM (--memory 2560m) with 512MB swap overflow (--memory-swap 3072m) and low swappiness (--memory-swappiness 10). An SSD-backed swap file (default 16GB) is configured on the host as a secondary safety net.

Storage Efficiency: Do not download separate 35GB installations per server. A single shared copy lives at /opt/cs2/shared, bind-mounted read-only into every container. Each slot has its own writable directory under /opt/cs2/servers/slot-N.

Network Mapping: Game ports use sequential mapping from 27015 (slot N = 27015+N). CSTV ports use a 100-offset base from 27115 (slot N = 27115+N). This prevents any overlap between game and TV port ranges across all 11 slots.

Engine Constraints: CS2 utilizes a 64-tick sub-tick architecture. Do not use legacy CS:GO commands like -tickrate 128.

Tournament Logic: MatchZy must be configured for standard esports rules: .ready / .unready enabled, 60-second .pause limit, .tech enabled, .stop (Match Medic) enabled. Coaches must be blocked (matchzy_allow_coaches 0).

Developer Workflow:
Development and orchestration are handled via a Mac (darwin-arm64). The target Ubuntu machine is a local physical PC (not a remote server), so all commands run directly in a terminal on that machine. Files are transferred via GitHub clone or direct copy (USB, rsync, etc.).