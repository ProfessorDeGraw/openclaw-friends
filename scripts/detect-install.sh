#!/usr/bin/env bash
# ============================================================
# OpenClaw Install Detector — Wolf Goal
# ============================================================
#
# Scans for existing OpenClaw installations and recommends
# the correct action: fresh install, upgrade, or repair.
#
# Usage:
#   ./detect-install.sh              # interactive report
#   ./detect-install.sh --json       # machine-readable output
#   ./detect-install.sh --quiet      # exit code only (0=none, 1=found, 2=running)
#
# Exit codes:
#   0 — No existing install found (safe for fresh install)
#   1 — Existing install found (recommend upgrade)
#   2 — Existing install running (must stop or upgrade in-place)
#   3 — Detection error

set -uo pipefail

MODE="${1:-interactive}"

# ── Colors ──────────────────────────────────────────────────

if [ -t 1 ] && [ "$MODE" != "--json" ]; then
  R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m'
  B='\033[1;37m' DIM='\033[0;90m' NC='\033[0m'
else
  R='' G='' Y='' C='' B='' DIM='' NC=''
fi

# ── Detection state ─────────────────────────────────────────

FOUND_INSTALL=false
FOUND_RUNNING=false
INSTALL_DIR=""
INSTALL_METHOD=""       # compose | container | volume-only
CONTAINER_NAME=""
CONTAINER_STATUS=""
CONTAINER_IMAGE=""
CONTAINER_CREATED=""
OC_VERSION=""
NODE_VERSION=""
HAS_WORKSPACE=false
HAS_CONFIG=false
HAS_MEMORY=false
HAS_SOUL=false
WORKSPACE_FILES=0
VOLUME_LIST=""
CONFIG_TOKEN=""         # redacted
GATEWAY_PORT=""
COMPOSE_FILE=""
UPTIME=""

# ── Scan functions ──────────────────────────────────────────

scan_directories() {
  # Check common install locations
  local dirs=(
    "$HOME/openclaw"
    "$HOME/openclaw-friend"
    "$HOME/.openclaw"
    "/opt/openclaw"
    "/srv/openclaw"
  )

  # Also check for docker-compose.yml mentioning openclaw
  for d in "${dirs[@]}"; do
    if [ -d "$d" ]; then
      if [ -f "$d/docker-compose.yml" ]; then
        FOUND_INSTALL=true
        INSTALL_DIR="$d"
        INSTALL_METHOD="compose"
        COMPOSE_FILE="$d/docker-compose.yml"
        return
      elif [ -f "$d/config/openclaw.json" ]; then
        FOUND_INSTALL=true
        INSTALL_DIR="$d"
        INSTALL_METHOD="manual"
        return
      fi
    fi
  done

  # Check current directory
  if [ -f "./docker-compose.yml" ] && grep -q "openclaw" "./docker-compose.yml" 2>/dev/null; then
    FOUND_INSTALL=true
    INSTALL_DIR="$(pwd)"
    INSTALL_METHOD="compose"
    COMPOSE_FILE="./docker-compose.yml"
  fi
}

scan_containers() {
  if ! command -v docker >/dev/null 2>&1; then return; fi
  if ! docker ps >/dev/null 2>&1; then return; fi

  # Check running containers
  local running=$(docker ps --format '{{.Names}}|{{.Status}}|{{.Image}}|{{.Ports}}' 2>/dev/null | grep -i "openclaw" || true)

  if [ -n "$running" ]; then
    FOUND_INSTALL=true
    FOUND_RUNNING=true
    CONTAINER_NAME=$(echo "$running" | head -1 | cut -d'|' -f1)
    CONTAINER_STATUS=$(echo "$running" | head -1 | cut -d'|' -f2)
    CONTAINER_IMAGE=$(echo "$running" | head -1 | cut -d'|' -f3)

    # Extract port
    local ports=$(echo "$running" | head -1 | cut -d'|' -f4)
    GATEWAY_PORT=$(echo "$ports" | grep -oP '0\.0\.0\.0:\K\d+' | head -1 || echo "")

    # Get version from inside container
    OC_VERSION=$(docker exec "$CONTAINER_NAME" openclaw --version 2>/dev/null | head -1 || echo "unknown")
    NODE_VERSION=$(docker exec "$CONTAINER_NAME" node --version 2>/dev/null || echo "unknown")

    # Get creation date
    CONTAINER_CREATED=$(docker inspect --format '{{.Created}}' "$CONTAINER_NAME" 2>/dev/null | cut -dT -f1 || echo "unknown")

    # Get uptime
    UPTIME=$(docker inspect --format '{{.State.StartedAt}}' "$CONTAINER_NAME" 2>/dev/null || echo "")

    # Check workspace contents
    if docker exec "$CONTAINER_NAME" test -d /root/.openclaw/workspace 2>/dev/null; then
      HAS_WORKSPACE=true
      WORKSPACE_FILES=$(docker exec "$CONTAINER_NAME" find /root/.openclaw/workspace -type f 2>/dev/null | wc -l || echo 0)
    fi
    if docker exec "$CONTAINER_NAME" test -f /root/.openclaw/openclaw.json 2>/dev/null; then
      HAS_CONFIG=true
    fi
    if docker exec "$CONTAINER_NAME" test -f /root/.openclaw/workspace/MEMORY.md 2>/dev/null; then
      HAS_MEMORY=true
    fi
    if docker exec "$CONTAINER_NAME" test -f /root/.openclaw/workspace/SOUL.md 2>/dev/null; then
      HAS_SOUL=true
    fi
    return
  fi

  # Check stopped containers
  local stopped=$(docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null | grep -i "openclaw" || true)
  if [ -n "$stopped" ]; then
    FOUND_INSTALL=true
    CONTAINER_NAME=$(echo "$stopped" | head -1 | cut -d'|' -f1)
    CONTAINER_STATUS=$(echo "$stopped" | head -1 | cut -d'|' -f2)
    CONTAINER_IMAGE=$(echo "$stopped" | head -1 | cut -d'|' -f3)
  fi
}

scan_volumes() {
  if ! command -v docker >/dev/null 2>&1; then return; fi
  if ! docker volume ls >/dev/null 2>&1; then return; fi

  VOLUME_LIST=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -i "openclaw" || true)
  if [ -n "$VOLUME_LIST" ] && [ "$FOUND_INSTALL" = "false" ]; then
    FOUND_INSTALL=true
    INSTALL_METHOD="volume-only"
  fi
}

scan_config_files() {
  # Check local install dir for config details
  if [ -n "$INSTALL_DIR" ]; then
    if [ -f "$INSTALL_DIR/config/openclaw.json" ]; then
      HAS_CONFIG=true
    fi
    if [ -f "$INSTALL_DIR/CONNECTION-INFO.txt" ]; then
      CONFIG_TOKEN="present (redacted)"
      GATEWAY_PORT=${GATEWAY_PORT:-$(grep -oP 'localhost:\K\d+' "$INSTALL_DIR/CONNECTION-INFO.txt" 2>/dev/null | head -1 || echo "")}
    fi
  fi
}

# ── Recommendation engine ───────────────────────────────────

recommend() {
  local action="fresh-install"
  local reason=""
  local risk="low"
  local preserve=""

  if [ "$FOUND_RUNNING" = "true" ]; then
    action="upgrade"
    reason="OpenClaw is currently running. An in-place upgrade will preserve your data."
    risk="low"
    preserve="workspace, memory, config, SOUL.md"
    if [ "$HAS_MEMORY" = "true" ] || [ "$WORKSPACE_FILES" -gt 5 ]; then
      risk="medium"
      reason="$reason You have active data — backup recommended before upgrade."
    fi
  elif [ "$FOUND_INSTALL" = "true" ]; then
    if [ "$INSTALL_METHOD" = "volume-only" ]; then
      action="fresh-install-with-volumes"
      reason="Found Docker volumes from a previous install but no running container. Fresh install will reuse existing data."
      preserve="volumes (workspace, config)"
    elif [ -n "$CONTAINER_NAME" ]; then
      action="upgrade"
      reason="Found stopped OpenClaw container. Upgrade will update and restart it."
      preserve="workspace, config"
    else
      action="upgrade"
      reason="Found install directory at $INSTALL_DIR."
      preserve="config files, workspace"
    fi
  else
    action="fresh-install"
    reason="No existing OpenClaw installation detected. Safe for fresh install."
  fi

  echo "$action|$reason|$risk|$preserve"
}

# ── Run scans ───────────────────────────────────────────────

scan_directories
scan_containers
scan_volumes
scan_config_files

REC=$(recommend)
REC_ACTION=$(echo "$REC" | cut -d'|' -f1)
REC_REASON=$(echo "$REC" | cut -d'|' -f2)
REC_RISK=$(echo "$REC" | cut -d'|' -f3)
REC_PRESERVE=$(echo "$REC" | cut -d'|' -f4)

# ── Output ──────────────────────────────────────────────────

if [ "$MODE" = "--quiet" ]; then
  if [ "$FOUND_RUNNING" = "true" ]; then exit 2;
  elif [ "$FOUND_INSTALL" = "true" ]; then exit 1;
  else exit 0; fi
fi

if [ "$MODE" = "--json" ]; then
  cat << JSON
{
  "found": $FOUND_INSTALL,
  "running": $FOUND_RUNNING,
  "installDir": "$INSTALL_DIR",
  "installMethod": "$INSTALL_METHOD",
  "container": {
    "name": "$CONTAINER_NAME",
    "status": "$CONTAINER_STATUS",
    "image": "$CONTAINER_IMAGE",
    "created": "$CONTAINER_CREATED"
  },
  "versions": {
    "openclaw": "$OC_VERSION",
    "node": "$NODE_VERSION"
  },
  "data": {
    "hasWorkspace": $HAS_WORKSPACE,
    "hasConfig": $HAS_CONFIG,
    "hasMemory": $HAS_MEMORY,
    "hasSoul": $HAS_SOUL,
    "workspaceFiles": $WORKSPACE_FILES
  },
  "volumes": "$(echo $VOLUME_LIST | tr '\n' ' ')",
  "gatewayPort": "$GATEWAY_PORT",
  "recommendation": {
    "action": "$REC_ACTION",
    "reason": "$REC_REASON",
    "risk": "$REC_RISK",
    "preserve": "$REC_PRESERVE"
  }
}
JSON
  if [ "$FOUND_RUNNING" = "true" ]; then exit 2;
  elif [ "$FOUND_INSTALL" = "true" ]; then exit 1;
  else exit 0; fi
fi

# ── Interactive report ──────────────────────────────────────

echo ""
echo -e "${B}  🔍 OpenClaw Installation Detector${NC}"
echo -e "${DIM}  $(date -u +"%Y-%m-%d %H:%M:%S UTC")${NC}"
echo ""

if [ "$FOUND_INSTALL" = "false" ]; then
  echo -e "  ${G}✅ No existing installation found${NC}"
  echo -e "  ${DIM}Safe to proceed with fresh install.${NC}"
  echo ""
  exit 0
fi

echo -e "${C}┌──────────────────────────────────────┐${NC}"
echo -e "${C}│${B}  Existing Installation Found         ${C}│${NC}"
echo -e "${C}└──────────────────────────────────────┘${NC}"
echo ""

# Install location
[ -n "$INSTALL_DIR" ] && echo -e "  📁 Location:   ${B}$INSTALL_DIR${NC}"
[ -n "$INSTALL_METHOD" ] && echo -e "  📦 Method:     $INSTALL_METHOD"

# Container info
if [ -n "$CONTAINER_NAME" ]; then
  echo ""
  echo -e "  🐋 Container:  ${B}$CONTAINER_NAME${NC}"
  if [ "$FOUND_RUNNING" = "true" ]; then
    echo -e "     Status:     ${G}Running${NC} ($CONTAINER_STATUS)"
  else
    echo -e "     Status:     ${Y}Stopped${NC} ($CONTAINER_STATUS)"
  fi
  [ -n "$CONTAINER_IMAGE" ] && echo -e "     Image:      $CONTAINER_IMAGE"
  [ -n "$CONTAINER_CREATED" ] && echo -e "     Created:    $CONTAINER_CREATED"
  [ -n "$GATEWAY_PORT" ] && echo -e "     Port:       $GATEWAY_PORT"
fi

# Versions
if [ -n "$OC_VERSION" ] && [ "$OC_VERSION" != "unknown" ]; then
  echo ""
  echo -e "  📋 Versions"
  echo -e "     OpenClaw:   $OC_VERSION"
  echo -e "     Node.js:    $NODE_VERSION"
fi

# Data
echo ""
echo -e "  💾 Data"
echo -e "     Workspace:  $([ "$HAS_WORKSPACE" = "true" ] && echo "${G}Yes${NC} ($WORKSPACE_FILES files)" || echo "${DIM}No${NC}")"
echo -e "     Config:     $([ "$HAS_CONFIG" = "true" ] && echo "${G}Yes${NC}" || echo "${DIM}No${NC}")"
echo -e "     Memory:     $([ "$HAS_MEMORY" = "true" ] && echo "${G}Yes${NC}" || echo "${DIM}No${NC}")"
echo -e "     SOUL.md:    $([ "$HAS_SOUL" = "true" ] && echo "${G}Yes${NC}" || echo "${DIM}No${NC}")"

# Volumes
if [ -n "$VOLUME_LIST" ]; then
  echo ""
  echo -e "  🗄️  Docker Volumes"
  echo "$VOLUME_LIST" | while read -r vol; do
    SIZE=$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null | xargs du -sh 2>/dev/null | cut -f1 || echo "?")
    echo -e "     • $vol ($SIZE)"
  done
fi

# Recommendation
echo ""
echo -e "${C}┌──────────────────────────────────────┐${NC}"
echo -e "${C}│${B}  Recommendation                      ${C}│${NC}"
echo -e "${C}└──────────────────────────────────────┘${NC}"
echo ""

case "$REC_ACTION" in
  upgrade)
    echo -e "  ➡️  ${B}Upgrade recommended${NC}"
    ;;
  fresh-install-with-volumes)
    echo -e "  ➡️  ${B}Fresh install (will reuse volumes)${NC}"
    ;;
  fresh-install)
    echo -e "  ➡️  ${B}Fresh install${NC}"
    ;;
esac

echo -e "  ${DIM}$REC_REASON${NC}"

case "$REC_RISK" in
  low)    echo -e "  Risk: ${G}Low${NC}" ;;
  medium) echo -e "  Risk: ${Y}Medium${NC} — backup recommended" ;;
  high)   echo -e "  Risk: ${R}High${NC} — backup required" ;;
esac

[ -n "$REC_PRESERVE" ] && echo -e "  Preserved: $REC_PRESERVE"

echo ""
echo -e "  ${DIM}To upgrade:  ./scripts/upgrade.sh${NC}"
echo -e "  ${DIM}To backup:   docker cp $CONTAINER_NAME:/root/.openclaw ./openclaw-backup${NC}"
echo ""

if [ "$FOUND_RUNNING" = "true" ]; then exit 2;
elif [ "$FOUND_INSTALL" = "true" ]; then exit 1;
else exit 0; fi
