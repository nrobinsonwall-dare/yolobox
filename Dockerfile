# Stage: Go source
FROM golang:1.25.5 AS go-source

# Stage: Claude Code installer
FROM ubuntu:24.04 AS claude-installer

RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://claude.ai/install.sh | bash

# Main image
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Install system packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Essentials
    bash \
    ca-certificates \
    curl \
    wget \
    git \
    sudo \
    # Build tools
    build-essential \
    make \
    cmake \
    pkg-config \
    # Python
    python3 \
    python3-pip \
    python3-venv \
    # Common utilities
    jq \
    ripgrep \
    fd-find \
    fzf \
    tree \
    htop \
    vim \
    nano \
    less \
    openssh-client \
    gnupg \
    unzip \
    zip \
    # For native node modules
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install global npm packages and AI CLIs
RUN npm install -g \
    typescript \
    ts-node \
    yarn \
    pnpm \
    @google/gemini-cli \
    @openai/codex \
    opencode-ai \
    @github/copilot

# Install Go (from official image)
COPY --from=go-source /usr/local/go /usr/local/go
ENV PATH="/usr/local/go/bin:$PATH"

# Install uv (fast Python package manager)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Delete ubuntu user (UID 1000) so yolo gets UID 1000
# Ubuntu 24.04 includes this user by default
RUN userdel -r ubuntu 2>/dev/null || true && \
    groupdel ubuntu 2>/dev/null || true

# Create yolo user with passwordless sudo (will get UID 1000 now)
RUN useradd -m -s /bin/bash yolo \
    && echo "yolo ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/yolo \
    && chmod 0440 /etc/sudoers.d/yolo

# Set up directories
RUN mkdir -p /workspace /output /secrets \
    && chown yolo:yolo /workspace /output

# Copy Claude Code from installer stage
COPY --from=claude-installer /root/.local/bin/claude /usr/local/bin/claude

USER yolo

# Create symlink for Claude at ~/.local/bin (host config expects it there)
# Then run `claude install` to register installation metadata so `claude update` works
RUN mkdir -p /home/yolo/.local/bin && \
    ln -s /usr/local/bin/claude /home/yolo/.local/bin/claude && \
    claude install || true
WORKDIR /home/yolo

# Set up a fun prompt and aliases
RUN echo 'PS1="\\[\\033[35m\\]yolo\\[\\033[0m\\]:\\[\\033[36m\\]\\w\\[\\033[0m\\] 🎲 "' >> ~/.bashrc \
    && echo 'alias ll="ls -la"' >> ~/.bashrc \
    && echo 'alias la="ls -A"' >> ~/.bashrc \
    && echo 'alias l="ls -CF"' >> ~/.bashrc \
    && echo 'alias yeet="rm -rf"' >> ~/.bashrc

# AI CLI wrappers in yolo mode - these find the real binary dynamically,
# so they survive updates (npm update -g, claude upgrade, etc.)
USER root
RUN mkdir -p /opt/yolobox/bin

# Generic wrapper template that finds real binary by excluding wrapper dir from PATH
RUN echo '#!/bin/bash' > /opt/yolobox/wrapper-template \
    && echo 'WRAPPER_DIR=/opt/yolobox/bin' >> /opt/yolobox/wrapper-template \
    && echo 'CMD=$(basename "$0")' >> /opt/yolobox/wrapper-template \
    && echo 'CLEAN_PATH=$(echo "$PATH" | tr ":" "\n" | grep -v "^$WRAPPER_DIR$" | tr "\n" ":" | sed "s/:$//" )' >> /opt/yolobox/wrapper-template \
    && echo 'REAL_BIN=$(PATH="$CLEAN_PATH" which "$CMD" 2>/dev/null)' >> /opt/yolobox/wrapper-template \
    && echo 'if [ -z "$REAL_BIN" ]; then echo "Error: $CMD not found" >&2; exit 1; fi' >> /opt/yolobox/wrapper-template \
    && echo 'if [ "$NO_YOLO" = "1" ]; then exec "$REAL_BIN" "$@"; fi' >> /opt/yolobox/wrapper-template

# Claude wrapper
RUN cp /opt/yolobox/wrapper-template /opt/yolobox/bin/claude \
    && echo 'exec "$REAL_BIN" --dangerously-skip-permissions "$@"' >> /opt/yolobox/bin/claude \
    && chmod +x /opt/yolobox/bin/claude

# Codex wrapper
RUN cp /opt/yolobox/wrapper-template /opt/yolobox/bin/codex \
    && echo 'exec "$REAL_BIN" --dangerously-bypass-approvals-and-sandbox "$@"' >> /opt/yolobox/bin/codex \
    && chmod +x /opt/yolobox/bin/codex

# Gemini wrapper
RUN cp /opt/yolobox/wrapper-template /opt/yolobox/bin/gemini \
    && echo 'exec "$REAL_BIN" --yolo "$@"' >> /opt/yolobox/bin/gemini \
    && chmod +x /opt/yolobox/bin/gemini

# OpenCode wrapper (no yolo flag yet, passthrough for now)
RUN cp /opt/yolobox/wrapper-template /opt/yolobox/bin/opencode \
    && echo 'exec "$REAL_BIN" "$@"' >> /opt/yolobox/bin/opencode \
    && chmod +x /opt/yolobox/bin/opencode

# Copilot wrapper
RUN cp /opt/yolobox/wrapper-template /opt/yolobox/bin/copilot \
    && echo 'exec "$REAL_BIN" --yolo "$@"' >> /opt/yolobox/bin/copilot \
    && chmod +x /opt/yolobox/bin/copilot


# Add wrapper dir and ~/.local/bin to PATH (wrappers take priority)
ENV PATH="/opt/yolobox/bin:/home/yolo/.local/bin:$PATH"

USER yolo

# Welcome message
RUN echo 'echo ""' >> ~/.bashrc \
    && echo 'echo -e "\\033[1;35m  Welcome to yolobox!\\033[0m"' >> ~/.bashrc \
    && echo 'echo -e "\\033[33m  Your home directory is safe. Go wild.\\033[0m"' >> ~/.bashrc \
    && echo 'echo ""' >> ~/.bashrc

# Create entrypoint script
USER root
RUN mkdir -p /host-claude /host-git && \
    printf '%s\n' \
    '#!/bin/bash' \
    '' \
    '#' \
    '# ============================================================================' \
    '# MATCH HOST UID/GID (--match-host-uid flag)' \
    '# ============================================================================' \
    '# Purpose: Remap the container yolo user UID/GID to match the host user so' \
    '#          files created in /workspace are owned by the host user, not root.' \
    '#' \
    '# How it works:' \
    '#   - Docker: yolobox passes YOLOBOX_HOST_UID/GID env vars, we remap here' \
    '#   - Podman: uses native --userns=keep-id, no remapping needed' \
    '#' \
    '# Why this is complex:' \
    '#   1. UID conflicts: Another user (e.g., ubuntu UID 1000) may already exist' \
    '#   2. GID conflicts: System groups exist at low GIDs (e.g., dialout=20)' \
    '#   3. macOS quirk: macOS uses UID 501 / GID 20 (staff), which maps to dialout' \
    '#   4. Process identity: After usermod, current process still has OLD UID' \
    '#      - This causes "you do not exist in passwd database" errors' \
    '#      - Solution: Create placeholder old-yolo user, then re-exec as new yolo' \
    '#' \
    '# Strategy:' \
    '#   1. Run all user/group mutations in a root subshell (avoids identity issues)' \
    '#   2. Delete any conflicting user that has our target UID' \
    '#   3. For GID < 1000: add yolo as supplementary member (don'"'"'t delete system groups)' \
    '#   4. For GID >= 1000: delete conflicting group and take over the GID' \
    '#   5. Create old-yolo placeholder so current process can still resolve its UID' \
    '#   6. Re-exec the entrypoint as the new yolo user' \
    '# ============================================================================' \
    '#' \
    'if [ -n "$YOLOBOX_HOST_UID" ] && [ "$YOLOBOX_HOST_UID" != "0" ]; then' \
    '    CURRENT_UID=$(id -u yolo)' \
    '    CURRENT_GID=$(id -g yolo)' \
    '    if [ "$YOLOBOX_HOST_UID" != "$CURRENT_UID" ]; then' \
    '        echo -e "\033[33m→ Matching container UID/GID to host ($YOLOBOX_HOST_UID:$YOLOBOX_HOST_GID)\033[0m" >&2' \
    '        ' \
    '        # Run UID/GID mutation as root in a subshell' \
    '        # Why subshell? After usermod changes yolo'"'"'s UID, the current shell (running' \
    '        # as yolo with UID 1000) can'"'"'t resolve itself in /etc/passwd anymore.' \
    '        # Running in a root subshell avoids this identity crisis.' \
    '        sudo -n bash -c '"'"'' \
    '            YOLOBOX_HOST_UID='"'"'"$YOLOBOX_HOST_UID"'"'"'' \
    '            YOLOBOX_HOST_GID='"'"'"$YOLOBOX_HOST_GID"'"'"'' \
    '            CURRENT_UID='"'"'"$CURRENT_UID"'"'"'' \
    '            CURRENT_GID='"'"'"$CURRENT_GID"'"'"'' \
    '            ' \
    '            # Step 1: Remove any user with our target UID (e.g., ubuntu at UID 1000)' \
    '            CONFLICT_USER=$(getent passwd "$YOLOBOX_HOST_UID" | cut -d: -f1)' \
    '            if [ -n "$CONFLICT_USER" ] && [ "$CONFLICT_USER" != "yolo" ]; then' \
    '                userdel -r "$CONFLICT_USER" 2>/dev/null || true' \
    '            fi' \
    '            ' \
    '            # Step 2: Change yolo to the new UID' \
    '            usermod -u "$YOLOBOX_HOST_UID" yolo' \
    '            ' \
    '            # Step 3: Handle GID changes (more complex due to system groups)' \
    '            if [ -n "$YOLOBOX_HOST_GID" ] && [ "$YOLOBOX_HOST_GID" != "$CURRENT_GID" ]; then' \
    '                CONFLICT_GROUP=$(getent group "$YOLOBOX_HOST_GID" | cut -d: -f1)' \
    '                if [ -n "$CONFLICT_GROUP" ] && [ "$CONFLICT_GROUP" != "yolo" ]; then' \
    '                    if [ "$YOLOBOX_HOST_GID" -lt 1000 ]; then' \
    '                        # System group conflict (e.g., macOS GID 20 = dialout in Ubuntu)' \
    '                        # Cannot delete system groups, so add yolo as supplementary member' \
    '                        # Files will still be accessible via group membership' \
    '                        usermod -a -G "$CONFLICT_GROUP" yolo 2>/dev/null || true' \
    '                    else' \
    '                        # Non-system group (GID >= 1000) - safe to delete and replace' \
    '                        groupdel "$CONFLICT_GROUP" 2>/dev/null || true' \
    '                        groupmod -g "$YOLOBOX_HOST_GID" yolo 2>/dev/null || true' \
    '                    fi' \
    '                else' \
    '                    # No conflict or already the yolo group - just change the GID' \
    '                    groupmod -g "$YOLOBOX_HOST_GID" yolo 2>/dev/null || true' \
    '                fi' \
    '            fi' \
    '            ' \
    '            # Step 4: Create placeholder user for old UID' \
    '            # After usermod, our current shell process still runs with the OLD UID (e.g., 1000)' \
    '            # but /etc/passwd no longer has an entry for it. This causes:' \
    '            #   - "you do not exist in passwd database" errors' \
    '            #   - sudo failing to resolve the current user' \
    '            # Solution: Create a dummy user that maps the old UID so lookups work' \
    '            useradd -u "$CURRENT_UID" -g yolo -M -N -s /bin/false old-yolo 2>/dev/null || true' \
    '            # Grant old-yolo sudo access so the re-exec below can run' \
    '            echo "old-yolo ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/old-yolo' \
    '            chmod 0440 /etc/sudoers.d/old-yolo' \
    '        '"'"'' \
    '        ' \
    '        # Step 5: Re-exec as the updated yolo user' \
    '        # This starts a fresh shell with the new UID/GID identity' \
    '        exec sudo -u yolo -- "$0" "$@"' \
    '    else' \
    '        echo -e "\033[32m✓ Container UID already matches host ($CURRENT_UID:$CURRENT_GID)\033[0m" >&2' \
    '    fi' \
    'fi' \
    '' \
    '# Fix ownership of yolo-owned directories after UID/GID switch' \
    '# These directories may have been created with the old UID (1000) and need updating' \
    'sudo chown -R yolo:yolo /home/yolo 2>/dev/null || true' \
    'sudo chown -R yolo:yolo /var/cache 2>/dev/null || true' \
    'sudo chown -R yolo:yolo /output 2>/dev/null || true' \
    '' \
    '' \
    '# Copy Claude config from host staging area if present' \
    'if [ -d /host-claude/.claude ] || [ -f /host-claude/.claude.json ]; then' \
    '    echo -e "\033[33m→ Copying host Claude config to container\033[0m" >&2' \
    'fi' \
    'if [ -d /host-claude/.claude ]; then' \
    '    sudo rm -rf /home/yolo/.claude' \
    '    sudo cp -a /host-claude/.claude /home/yolo/.claude' \
    '    sudo chown -R yolo:yolo /home/yolo/.claude' \
    'fi' \
    'if [ -f /host-claude/.claude.json ]; then' \
    '    sudo rm -f /home/yolo/.claude.json' \
    '    sudo cp -a /host-claude/.claude.json /home/yolo/.claude.json' \
    '    sudo chown yolo:yolo /home/yolo/.claude.json' \
    'fi' \
    '' \
    '# Copy git config from host staging area if present' \
    'if [ -f /host-git/.gitconfig ]; then' \
    '    echo -e "\033[33m→ Copying host git config to container\033[0m" >&2' \
    '    sudo rm -f /home/yolo/.gitconfig' \
    '    sudo cp -a /host-git/.gitconfig /home/yolo/.gitconfig' \
    '    sudo chown yolo:yolo /home/yolo/.gitconfig' \
    'fi' \
    '' \
    '# Auto-trust /workspace for Claude Code (this is yolobox after all)' \
    'CLAUDE_JSON="/home/yolo/.claude.json"' \
    'if [ ! -f "$CLAUDE_JSON" ]; then' \
    '    echo '"'"'{"projects":{}}'"'"' > "$CLAUDE_JSON"' \
    'fi' \
    '# Add /workspace as trusted project' \
    'if command -v jq &> /dev/null; then' \
    '    TMP=$(mktemp)' \
    '    jq '"'"'.projects["/workspace"] = (.projects["/workspace"] // {}) + {"hasTrustDialogAccepted": true}'"'"' "$CLAUDE_JSON" > "$TMP" && mv "$TMP" "$CLAUDE_JSON"' \
    '    chown yolo:yolo "$CLAUDE_JSON"' \
    'fi' \
    '' \
    'exec "$@"' \
    > /usr/local/bin/yolobox-entrypoint.sh && \
    chmod +x /usr/local/bin/yolobox-entrypoint.sh
USER yolo

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/yolobox-entrypoint.sh"]
CMD ["bash"]
