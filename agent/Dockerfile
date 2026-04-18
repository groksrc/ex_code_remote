# Claude Remote Agent - Sandboxed Execution Environment
#
# This Dockerfile creates a secure, sandboxed environment for running
# the Claude Remote agent. It includes common development tools and
# runs as a non-root user for security.
#
# Build:
#   docker build -t claude-remote-agent .
#
# Run:
#   docker run -d \
#     -e AUTH_TOKEN=your-token \
#     -e RELAY_URL=wss://your-server/ws/agent \
#     -v $(pwd)/workspace:/home/agent/workspace \
#     claude-remote-agent

FROM python:3.11-slim

# Install development tools and utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Essential tools
    curl \
    wget \
    git \
    jq \
    vim \
    nano \
    # Build tools
    build-essential \
    # Network tools
    netcat-openbsd \
    dnsutils \
    iputils-ping \
    # Process tools
    htop \
    procps \
    # File tools
    tree \
    zip \
    unzip \
    # Text processing
    ripgrep \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN useradd -m -s /bin/bash -u 1000 agent

# Set up workspace directory
RUN mkdir -p /home/agent/workspace && \
    chown -R agent:agent /home/agent

WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy agent code
COPY agent.py .

# Switch to non-root user
USER agent
WORKDIR /home/agent/workspace

# Environment defaults (override at runtime)
ENV RELAY_URL=""
ENV AUTH_TOKEN=""

CMD ["python", "/app/agent.py"]
