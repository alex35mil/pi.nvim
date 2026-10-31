# Pi in a container for pi.nvim's workspace descriptor example.
# Build: docker build -t pi-sandbox examples/container
FROM node:24-bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends bash ca-certificates git ripgrep \
  && rm -rf /var/lib/apt/lists/*
# Pin the Pi version pi.nvim is validated against (see :checkhealth pi).
ARG PI_VERSION=1.3.0
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@${PI_VERSION}

WORKDIR /workspace
