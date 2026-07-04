FROM node:20-alpine

WORKDIR /app

# Install latest TMAS CLI — version resolved from metadata.json at build time
RUN apk add --no-cache curl tar && \
    curl -fsL --retry 3 --retry-delay 2 \
      "https://ast-cli.xdr.trendmicro.com/tmas-cli/metadata.json" \
      -o /tmp/tmas-meta.json && \
    TMAS_VER=$(node -p "require('/tmp/tmas-meta.json').latestVersion.replace(/^v/,'')") && \
    [ -n "$TMAS_VER" ] || { echo "ERROR: could not resolve TMAS version from metadata.json"; exit 1; } && \
    echo "Installing TMAS CLI v${TMAS_VER}" && \
    curl -fSL --retry 3 --retry-delay 2 \
      "https://ast-cli.xdr.trendmicro.com/tmas-cli/${TMAS_VER}/tmas-cli_Linux_x86_64.tar.gz" \
      -o /tmp/tmas.tar.gz && \
    tar -xzf /tmp/tmas.tar.gz -C /tmp && \
    find /tmp -maxdepth 4 \( -name "tmas" -o -name "tmas-cli" \) -type f | head -1 | xargs -I{} mv {} /usr/local/bin/tmas && \
    chmod +x /usr/local/bin/tmas && \
    rm /tmp/tmas.tar.gz /tmp/tmas-meta.json

COPY package*.json ./
RUN npm ci --only=production

COPY dgbank.html .
COPY server.js .

EXPOSE 3000

CMD ["node", "server.js"]
