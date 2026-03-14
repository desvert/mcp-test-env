FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Scanning & enumeration
    nmap \
    nikto \
    # Brute force
    hydra \
    # HTTP / protocol clients
    curl \
    wget \
    netcat-openbsd \
    # DNS tools
    dnsutils \
    # General utilities
    iputils-ping \
    python3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY wordlists/ /wordlists/
COPY attacks.sh /attacks.sh
RUN chmod +x /attacks.sh

ENTRYPOINT ["/attacks.sh"]
