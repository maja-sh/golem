#!/bin/bash
# Rebuild the golem-vm image and recreate the container.
# The persistent volume (golem-data) is preserved.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

echo "Building $IMAGE..."
$RUNTIME build -t "$IMAGE" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"

if $RUNTIME container inspect "$CONTAINER_NAME" &>/dev/null; then
  echo "Removing old container..."
  $RUNTIME stop "$CONTAINER_NAME" 2>/dev/null || true
  $RUNTIME rm "$CONTAINER_NAME"
fi

echo "Starting fresh container..."
"$SCRIPT_DIR/start.sh" "$CONTAINER_NAME" "$IMAGE"
