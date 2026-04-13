FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    # Build essentials
    build-essential git curl wget vim nano \
    # Languages
    python3 python3-pip python3-venv nodejs npm \
    # Networking & security tools
    nmap netcat-openbsd dnsutils iputils-ping iproute2 \
    openssh-client whois traceroute \
    # System utilities
    sudo jq tree htop unzip zip \
    ca-certificates gnupg lsb-release \
    # For potential web work
    sqlite3 libsqlite3-dev \
    # Virtual display and GUI tools
    xvfb scrot xdotool imagemagick x11-utils \
    # Browser for testing web UIs
    firefox \
    && rm -rf /var/lib/apt/lists/*

# Create agent user with passwordless sudo
RUN useradd -m -s /bin/bash agent && \
    echo "agent ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

COPY entrypoint.sh /entrypoint.sh
COPY scaffold-tauri2.sh /usr/local/bin/scaffold-tauri2
RUN chmod +x /entrypoint.sh /usr/local/bin/scaffold-tauri2

USER agent
WORKDIR /home/agent
ENV DISPLAY=:99

ENTRYPOINT ["/entrypoint.sh"]
