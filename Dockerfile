FROM node:20-slim

# System deps
RUN apt-get update && apt-get install -y \
    git curl jq python3 python3-pip \
    chromium chromium-sandbox \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Create non-root worker user
RUN useradd -m -s /bin/bash worker
WORKDIR /home/worker

# Copy entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Worker API port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

USER worker
ENV HOME=/home/worker
ENV CHROME_PATH=/usr/bin/chromium

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
