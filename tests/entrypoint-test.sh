#!/bin/bash
# entrypoint-test.sh — Start Docker daemon, then run test harness
set -e

# Start dockerd in background
dockerd --storage-driver=vfs > /var/log/dockerd.log 2>&1 &

# Wait for Docker daemon
echo "  ⏳ Waiting for Docker daemon..."
for i in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then
    echo "  ✅ Docker daemon ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "  ❌ Docker daemon failed to start"
    cat /var/log/dockerd.log | tail -20
    exit 1
  fi
  sleep 1
done

# Run harness
exec bash /opt/openclaw-friends/tests/test-harness.sh "$@"
