FROM node:20-alpine

WORKDIR /app

# Install TMAS CLI — resolve version from metadata.json (same logic as tmas-scan-action)
RUN apk add --no-cache curl tar && \
    TMAS_VER=$(curl -fsSL https://ast-cli.xdr.trendmicro.com/tmas-cli/metadata.json \
      | grep -o '"latestVersion":"[^"]*"' | sed 's/.*":"//;s/"//;s/^v//') && \
    curl -fSL --retry 3 --retry-delay 2 \
      "https://ast-cli.xdr.trendmicro.com/tmas-cli/${TMAS_VER}/tmas-cli_Linux_x86_64.tar.gz" \
      -o /tmp/tmas.tar.gz && \
    tar -xzf /tmp/tmas.tar.gz -C /tmp && \
    find /tmp -maxdepth 4 \( -name "tmas" -o -name "tmas-cli" \) -type f | head -1 | xargs -I{} mv {} /usr/local/bin/tmas && \
    chmod +x /usr/local/bin/tmas && \
    rm /tmp/tmas.tar.gz

COPY package*.json ./
RUN npm ci --only=production

COPY dgbank.html .
COPY server.js .

EXPOSE 3000

CMD ["node", "server.js"]
