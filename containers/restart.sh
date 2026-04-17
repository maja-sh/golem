#!/bin/bash
# Restart the golem-vm container (picks up mount/env changes).
# Data volume is preserved.

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

$RUNTIME stop "$CONTAINER_NAME" 2>/dev/null
$RUNTIME rm "$CONTAINER_NAME" 2>/dev/null
"$SCRIPT_DIR/start.sh" "$CONTAINER_NAME"
