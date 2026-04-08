#!/bin/bash
# Start virtual framebuffer for GUI applications
Xvfb :99 -screen 0 1280x720x24 -ac +extension GLX +render -noreset &
sleep 1
echo "Xvfb started on display :99 (1280x720)"
# Keep container running
exec sleep infinity
