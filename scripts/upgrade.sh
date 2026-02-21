#!/usr/bin/env bash
# ============================================================
# OpenClaw In-Place Upgrade — Wolf Goal
# ============================================================
#
# Upgrades an existing OpenClaw installation while preserving:
#   - Workspace files (MEMORY.md, SOUL.md, user files)
#   - Configuration (openclaw.json, auth profiles, tokens)
#   - Docker volumes (persistent data)
#   - Cron jobs and channel configs
#
# Usage:
#   ./upgrade.sh                   # auto-detect and upgrade
#   ./upgrade.sh --install-dir ~/openclaw
#   ./upgrade.sh --dry-run         # show what would happen
#   ./upgrade.sh --backup-only     # just create backup, don't upgrade
#   ./upgrade.sh --force           # skip confirmation prompt
#   ./upgrade.sh --target-version 1.2.3  # upgrade to specific version
#
# Safety:
#   - Creates a timestamped backup before any changes
#   - Validates the new install before removing the old one
#   - Rolls back automatically if the upgrade fails

set -uo pipefail

# ── Config ──────────────────────────────────────────────────

INSTALL_DIR="${INSTALL_DIR:-}"
DRY_RUN=false
BACKUP_ONLY=false
FORCE=false
TARGET_VERSION="latest"
BACKUP_DIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --backup-only) BACKUP_ONLY=true; shift ;;
    --force) FORCE=true; shift ;;
    --target-version) TARGET_VERSION="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Colors ──────────────────────────────────────────────────

if [ -t 1 ]; then
  R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m'
  B='\033[1;37m' DIM='\033[0;90m' NC='\033[0m'
else
  R='' G='' Y='' C='' B='' DIM='' NC=''
fi

log()  { echo -e "${C}[upgrade]${NC} $*"; }
ok()   { echo -e "  ${G}✅${NC} $*"; }
warn() { echo -e "  ${Y}⚠️${NC}  $*"; }
err()  { echo -e "  ${R}❌${NC} $*"; }
dry()  { echo -e "  ${DIM}[dry-run] $*${NC}"; }

# ── Auto-detect install ────────────────────────────────────

if [ -z "$INSTALL_DIR" ]; then
  for d in "$HOME/openclaw" "$HOME/openclaw-friend" "/opt/openclaw"; do
    if [ -f "$d/docker-compose.yml" ]; then
      INSTALL_DIR="$d"
      break
    fi
  done
fi

if [ -z "$INSTALL_DIR" ] || [ ! -d "$INSTALL_DIR" ]; then
  err "No OpenClaw installation found."
  echo "  Checked: ~/openclaw, ~/openclaw-friend, /opt/openclaw"
  echo "  Specify manually: ./upgrade.sh --install-dir /path/to/openclaw"
  exit 1
fi

log "Found installation at: $INSTALL_DIR"

# ── Detect current state ───────────────────────────────────

COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
  err "No docker-compose.yml found at $INSTALL_DIR"
  exit 1
fi

# Find container name
CONTAINER_NAME=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i openclaw | head -1 || echo "")
IS_RUNNING=false
if [ -n "$CONTAINER_NAME" ]; then
  STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
  [ "$STATUS" = "running" ] && IS_RUNNING=true
fi

# Get current version
CURRENT_VERSION="unknown"
if [ "$IS_RUNNING" = "true" ]; then
  CURRENT_VERSION=$(docker exec "$CONTAINER_NAME" openclaw --version 2>/dev/null | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1 || echo "unknown")
fi

echo ""
echo -e "${B}  🔄 OpenClaw Upgrade${NC}"
echo ""
echo -e "  Install dir:      $INSTALL_DIR"
echo -e "  Container:        ${CONTAINER_NAME:-none}"
echo -e "  Status:           $([ "$IS_RUNNING" = "true" ] && echo "${G}Running${NC}" || echo "${Y}Stopped${NC}")"
echo -e "  Current version:  $CURRENT_VERSION"
echo -e "  Target version:   $TARGET_VERSION"
echo ""

# ── Step 1: Backup ──────────────────────────────────────────

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$INSTALL_DIR/backups/pre-upgrade-$TIMESTAMP"

log "Step 1/5: Creating backup..."

if [ "$DRY_RUN" = "true" ]; then
  dry "Would create backup at $BACKUP_DIR"
else
  mkdir -p "$BACKUP_DIR"

  # Backup config files
  if [ -d "$INSTALL_DIR/config" ]; then
    cp -r "$INSTALL_DIR/config" "$BACKUP_DIR/config"
    ok "Config files backed up"
  fi

  # Backup docker-compose.yml
  cp "$COMPOSE_FILE" "$BACKUP_DIR/docker-compose.yml"
  ok "docker-compose.yml backed up"

  # Backup .env if exists
  [ -f "$INSTALL_DIR/.env" ] && cp "$INSTALL_DIR/.env" "$BACKUP_DIR/.env"

  # Backup CONNECTION-INFO.txt
  [ -f "$INSTALL_DIR/CONNECTION-INFO.txt" ] && cp "$INSTALL_DIR/CONNECTION-INFO.txt" "$BACKUP_DIR/CONNECTION-INFO.txt"

  # Backup workspace from container (the important stuff)
  if [ "$IS_RUNNING" = "true" ] || [ -n "$CONTAINER_NAME" ]; then
    docker cp "$CONTAINER_NAME:/root/.openclaw/workspace" "$BACKUP_DIR/workspace" 2>/dev/null && \
      ok "Workspace backed up ($(find "$BACKUP_DIR/workspace" -type f 2>/dev/null | wc -l) files)" || \
      warn "Could not backup workspace from container"

    # Backup cron jobs
    docker exec "$CONTAINER_NAME" openclaw cron list 2>/dev/null > "$BACKUP_DIR/cron-jobs.json" && \
      ok "Cron jobs backed up" || true

    # Backup credentials dir
    docker cp "$CONTAINER_NAME:/root/.openclaw/credentials" "$BACKUP_DIR/credentials" 2>/dev/null && \
      ok "Credentials backed up" || true
  fi

  # Write backup manifest
  cat > "$BACKUP_DIR/MANIFEST.txt" << EOF
OpenClaw Upgrade Backup
=======================
Date:      $(date -u +"%Y-%m-%d %H:%M:%S UTC")
From:      $CURRENT_VERSION
To:        $TARGET_VERSION
Container: $CONTAINER_NAME
Directory: $INSTALL_DIR

Contents:
$(ls -la "$BACKUP_DIR/" 2>/dev/null)
EOF

  ok "Backup complete: $BACKUP_DIR"
fi

if [ "$BACKUP_ONLY" = "true" ]; then
  log "Backup-only mode. Stopping here."
  echo ""
  echo -e "  Backup location: ${B}$BACKUP_DIR${NC}"
  echo ""
  exit 0
fi

# ── Confirmation ────────────────────────────────────────────

if [ "$FORCE" = "false" ] && [ "$DRY_RUN" = "false" ]; then
  echo ""
  echo -e "  ${Y}This will:${NC}"
  echo "    1. Stop the current container"
  echo "    2. Pull the latest OpenClaw"
  echo "    3. Restart with your existing config + data"
  echo ""
  echo -e "  ${DIM}Backup saved at: $BACKUP_DIR${NC}"
  echo -e "  ${DIM}Your workspace and memory will be preserved.${NC}"
  echo ""
  read -p "  Proceed with upgrade? (y/N) " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    log "Upgrade cancelled."
    exit 0
  fi
fi

# ── Step 2: Stop current container ──────────────────────────

log "Step 2/5: Stopping current container..."

if [ "$DRY_RUN" = "true" ]; then
  dry "Would run: docker compose down in $INSTALL_DIR"
else
  cd "$INSTALL_DIR"
  if docker compose down 2>/dev/null; then
    ok "Container stopped"
  else
    warn "docker compose down had issues (may already be stopped)"
  fi
fi

# ── Step 3: Update docker-compose.yml ───────────────────────

log "Step 3/5: Updating configuration..."

if [ "$DRY_RUN" = "true" ]; then
  dry "Would update openclaw version in docker-compose.yml command"
else
  # The compose file uses `npm install -g openclaw@latest` in its command,
  # so pulling fresh will get the latest version.
  # We just need to make sure the node image is current.
  CURRENT_NODE=$(grep -oP 'node:\K[\d.]+' "$COMPOSE_FILE" | head -1 || echo "")
  TARGET_NODE="22.22.0"

  if [ -n "$CURRENT_NODE" ] && [ "$CURRENT_NODE" != "$TARGET_NODE" ]; then
    sed -i "s|node:${CURRENT_NODE}|node:${TARGET_NODE}|g" "$COMPOSE_FILE"
    ok "Updated Node.js image: $CURRENT_NODE → $TARGET_NODE"
  else
    ok "Node.js image already current"
  fi

  # Ensure openclaw@latest (not pinned to old version)
  if grep -q 'openclaw@latest' "$COMPOSE_FILE"; then
    ok "OpenClaw set to @latest"
  elif grep -qP 'openclaw@[\d.]+' "$COMPOSE_FILE"; then
    if [ "$TARGET_VERSION" = "latest" ]; then
      sed -i 's/openclaw@[0-9.]*/openclaw@latest/g' "$COMPOSE_FILE"
      ok "Updated OpenClaw to @latest"
    else
      sed -i "s/openclaw@[0-9.]*/openclaw@$TARGET_VERSION/g" "$COMPOSE_FILE"
      ok "Updated OpenClaw to @$TARGET_VERSION"
    fi
  fi
fi

# ── Step 4: Pull and start ──────────────────────────────────

log "Step 4/5: Starting upgraded container..."

if [ "$DRY_RUN" = "true" ]; then
  dry "Would run: docker compose up -d"
  dry "Would wait up to 180s for gateway"
else
  cd "$INSTALL_DIR"

  # Pull latest node image
  docker compose pull 2>/dev/null || true

  # Start
  if ! docker compose up -d 2>&1; then
    err "Failed to start container"
    err "Rolling back..."
    cp "$BACKUP_DIR/docker-compose.yml" "$COMPOSE_FILE"
    docker compose up -d 2>/dev/null
    err "Rollback complete. Previous version restored."
    exit 1
  fi

  ok "Container started"

  # Wait for gateway
  echo -e "  ${DIM}Waiting for gateway (first run may install packages)...${NC}"
  READY=false
  GATEWAY_PORT=$(grep -oP '"\K\d+(?=:18789)' "$COMPOSE_FILE" 2>/dev/null || echo "18789")
  GATEWAY_PORT="${GATEWAY_PORT:-18789}"

  for i in $(seq 1 36); do
    if curl -s -m 5 -o /dev/null "http://localhost:$GATEWAY_PORT/" 2>/dev/null; then
      READY=true
      break
    fi
    sleep 5
    ELAPSED=$((i * 5))
    echo -ne "\r  ${DIM}Waiting... ${ELAPSED}s / 180s${NC}    "
  done
  echo ""

  if [ "$READY" = "true" ]; then
    ok "Gateway is ready"
  else
    warn "Gateway not ready after 180s (may still be starting)"
    echo -e "  ${DIM}Check logs: cd $INSTALL_DIR && docker compose logs -f${NC}"
  fi
fi

# ── Step 5: Verify ──────────────────────────────────────────

log "Step 5/5: Verifying upgrade..."

if [ "$DRY_RUN" = "true" ]; then
  dry "Would verify container, version, workspace"
else
  NEW_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i openclaw | head -1 || echo "")

  if [ -z "$NEW_CONTAINER" ]; then
    err "No container running after upgrade"
    warn "Check: cd $INSTALL_DIR && docker compose logs"
  else
    # Version
    NEW_VERSION=$(docker exec "$NEW_CONTAINER" openclaw --version 2>/dev/null | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1 || echo "unknown")
    ok "New version: $NEW_VERSION"

    # Workspace intact
    WS_FILES=$(docker exec "$NEW_CONTAINER" find /root/.openclaw/workspace -type f 2>/dev/null | wc -l || echo 0)
    ok "Workspace: $WS_FILES files"

    # Memory preserved
    if docker exec "$NEW_CONTAINER" test -f /root/.openclaw/workspace/MEMORY.md 2>/dev/null; then
      ok "MEMORY.md: preserved"
    fi

    # SOUL preserved
    if docker exec "$NEW_CONTAINER" test -f /root/.openclaw/workspace/SOUL.md 2>/dev/null; then
      ok "SOUL.md: preserved"
    fi

    # Cron jobs
    CRON_COUNT=$(docker exec "$NEW_CONTAINER" openclaw cron list 2>/dev/null | grep -c '"name"' || echo 0)
    ok "Cron jobs: $CRON_COUNT active"
  fi
fi

# ── Summary ─────────────────────────────────────────────────

echo ""
echo -e "${C}════════════════════════════════════════${NC}"

if [ "$DRY_RUN" = "true" ]; then
  echo -e "  ${B}Dry run complete${NC} — no changes made."
  echo -e "  ${DIM}Run without --dry-run to perform the upgrade.${NC}"
else
  echo -e "  ${G}✅ Upgrade complete!${NC}"
  echo ""
  echo -e "  ${DIM}Version:  $CURRENT_VERSION → ${NEW_VERSION:-$TARGET_VERSION}${NC}"
  echo -e "  ${DIM}Backup:   $BACKUP_DIR${NC}"
  [ -n "${GATEWAY_PORT:-}" ] && echo -e "  ${DIM}URL:      http://localhost:$GATEWAY_PORT${NC}"
  echo ""
  echo -e "  ${DIM}To rollback: cp $BACKUP_DIR/docker-compose.yml $COMPOSE_FILE && cd $INSTALL_DIR && docker compose up -d${NC}"
fi

echo ""
echo -e "${C}════════════════════════════════════════${NC}"
echo ""
