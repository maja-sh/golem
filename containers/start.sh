#!/bin/bash
# Start the golem-vm container with persistent storage.
# Agent's home directory survives container restarts.

CONTAINER_NAME="${1:-golem-vm}"
IMAGE="${2:-golem-vm:latest}"

# Check if container already exists
if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
  # Check if it's running
  STATUS=$(podman inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
  if [ "$STATUS" = "running" ]; then
    echo "Container $CONTAINER_NAME is already running."
    exit 0
  else
    echo "Starting existing container $CONTAINER_NAME..."
    podman start "$CONTAINER_NAME"
    exit 0
  fi
fi

echo "Creating container $CONTAINER_NAME with persistent volume..."
podman run -d \
  --name "$CONTAINER_NAME" \
  --privileged \
  -v golem-data:/home/agent \
  "$IMAGE"

echo "Container $CONTAINER_NAME started."
echo "Data persisted in volume: golem-data"
