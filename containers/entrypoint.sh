#!/bin/bash
# Start virtual framebuffer for GUI applications
Xvfb :99 -screen 0 1280x720x24 -ac +extension GLX +render -noreset &
sleep 1
echo "Xvfb started on display :99 (1280x720)"

# Configure SSH for git if keys are mounted
if [ -d "$HOME/.ssh" ]; then
  mkdir -p /tmp/.ssh
  chmod 700 /tmp/.ssh

  # Find the bot key
  KEY=""
  for k in id_ed25519 id_rsa; do
    if [ -f "$HOME/.ssh/$k" ]; then
      cp "$HOME/.ssh/$k" /tmp/.ssh/
      chmod 600 "/tmp/.ssh/$k"
      KEY="/tmp/.ssh/$k"
      break
    fi
  done

  if [ -n "$KEY" ]; then
    cp $HOME/.ssh/known_hosts /tmp/.ssh/ 2>/dev/null
    export GIT_SSH_COMMAND="ssh -i $KEY -o UserKnownHostsFile=/tmp/.ssh/known_hosts -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o IdentitiesOnly=yes 2>/dev/null"
    echo "GIT_SSH_COMMAND='$GIT_SSH_COMMAND'" >> $HOME/.bashrc
    echo "SSH configured for git (using $(basename $KEY))"
  fi
fi

# Configure git identity if provided
[ -n "$GIT_USER" ]  && git config --global user.name "$GIT_USER"
[ -n "$GIT_EMAIL" ] && git config --global user.email "$GIT_EMAIL"

# Keep container running
exec sleep infinity
