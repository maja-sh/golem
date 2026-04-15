#!/bin/bash
# Start the golem-vm container with persistent storage.
# Agent's home directory survives container restarts.

if command -v podman &>/dev/null; then
  RUNTIME=podman
elif command -v docker &>/dev/null; then
  RUNTIME=docker
else
  echo "Error: neither podman nor docker found" >&2
  exit 1
fi

CONTAINER_NAME="${1:-golem-vm}"
IMAGE="${2:-golem-vm:latest}"

# Check if container already exists
if $RUNTIME container inspect "$CONTAINER_NAME" &>/dev/null; then
  # Check if it's running
  STATUS=$($RUNTIME inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
  if [ "$STATUS" = "running" ]; then
    echo "Container $CONTAINER_NAME is already running."
    exit 0
  else
    echo "Starting existing container $CONTAINER_NAME..."
    $RUNTIME start "$CONTAINER_NAME"
    exit 0
  fi
fi

echo "Creating container $CONTAINER_NAME with persistent volume..."

# Mount bot SSH keys if available (for git push/pull)
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH_MOUNT=""
if [ -d "$SCRIPT_DIR/ssh" ]; then
  SSH_MOUNT="-v $SCRIPT_DIR/ssh:/home/agent/.ssh:ro"
  echo "Mounting SSH keys from $SCRIPT_DIR/ssh"
fi

# Forward git identity
GIT_ENV=""
[ -n "$GIT_USER" ]  && GIT_ENV="$GIT_ENV -e GIT_USER=$GIT_USER"
[ -n "$GIT_EMAIL" ] && GIT_ENV="$GIT_ENV -e GIT_EMAIL=$GIT_EMAIL"

$RUNTIME run -d \
  --name "$CONTAINER_NAME" \
  --privileged \
  -v golem-data:/home/agent \
  $SSH_MOUNT \
  $GIT_ENV \
  "$IMAGE"

echo "Container $CONTAINER_NAME started."
echo "Data persisted in volume: golem-data"
