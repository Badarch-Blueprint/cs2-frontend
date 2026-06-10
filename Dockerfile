###############################################################################
# CS2 LAN Tournament Orchestrator - Server Container
# ============================================================================
# Lightweight runtime image for Counter-Strike 2 dedicated servers.
#
# This container does NOT include SteamCMD or the CS2 game files. Instead,
# the host runs install_cs2.sh once to populate a shared directory, and every
# container bind-mounts that directory read-only. A per-container writable
# overlay handles logs, configs, and plugin state.
#
# Build:  docker build -t cs2-server .
# Base:   debian:bullseye-slim (~80 MB, minimal attack surface)
###############################################################################

FROM ubuntu:24.04

# Use Korean Ubuntu mirror
RUN if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        sed -i 's|http://archive.ubuntu.com|http://kr.archive.ubuntu.com|g' /etc/apt/sources.list.d/ubuntu.sources && \
        sed -i 's|http://security.ubuntu.com|http://kr.archive.ubuntu.com|g' /etc/apt/sources.list.d/ubuntu.sources; \
    else \
        sed -i 's|http://archive.ubuntu.com|http://kr.archive.ubuntu.com|g' /etc/apt/sources.list && \
        sed -i 's|http://security.ubuntu.com|http://kr.archive.ubuntu.com|g' /etc/apt/sources.list; \
    fi
    

LABEL maintainer="CS2 LAN Tournament Orchestrator"
LABEL description="CS2 dedicated server runtime (shared-volume architecture)"

# ---------------------------------------------------------------------------
# 1. Install runtime dependencies required by the CS2 srcds binary.
#    - lib32gcc-s1, lib32stdc++6 : 32-bit runtime libraries (Source engine)
#    - ca-certificates           : TLS root certs for Steam auth / downloads
#    - locales                   : UTF-8 locale support (plugin log output)
#    - curl                      : health-check probe / debugging
# ---------------------------------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        lib32gcc-s1 \
        lib32stdc++6 \
        ca-certificates \
        locales \
        curl \
        libv8-dev \
    && locale-gen en_US.UTF-8 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get install -y --no-install-recommends nodejs


ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# ---------------------------------------------------------------------------
# 2. Create a non-root "steam" user (UID 1000).
#    Matches the ownership set by install_cs2.sh on the host volume.
# ---------------------------------------------------------------------------
RUN userdel -r ubuntu 2>/dev/null || true && \
    useradd -m -u 1000 -s /bin/bash steam

# ---------------------------------------------------------------------------
# 3. Create mount-point directories.
#    /opt/cs2/shared  : read-only bind mount of the shared game files
#    /home/steam/server : writable per-server overlay (configs, logs, demos)
# ---------------------------------------------------------------------------
RUN mkdir -p /opt/cs2/shared /home/steam/server \
    && chown -R steam:steam /home/steam/server

# ---------------------------------------------------------------------------
# 4. Copy the entrypoint script that handles the overlay setup and launches
#    the CS2 dedicated server binary.
# ---------------------------------------------------------------------------
COPY --chown=steam:steam entrypoint.sh /home/steam/entrypoint.sh
RUN chmod +x /home/steam/entrypoint.sh

# ---------------------------------------------------------------------------
# 5. Switch to the unprivileged steam user for all runtime operations.
# ---------------------------------------------------------------------------
USER steam
WORKDIR /home/steam

# ---------------------------------------------------------------------------
# 6. Default environment variables (overridden per-service in compose).
#    CS2_PORT    : Game traffic port
#    CS2_TV_PORT : CSTV spectator port
#    CS2_ARGS    : Full launch argument string
# ---------------------------------------------------------------------------
ENV CS2_PORT=27015 \
    CS2_TV_PORT=27020 \
    CS2_ARGS=""

# ---------------------------------------------------------------------------
# 7. Expose default ports (documentation only; actual mapping in compose).
#    27015/tcp+udp : Game traffic
#    27015/udp     : Steam query
#    27020/udp     : CSTV
# ---------------------------------------------------------------------------
EXPOSE 27015/tcp 27015/udp 27020/udp

ENTRYPOINT ["/home/steam/entrypoint.sh"]
