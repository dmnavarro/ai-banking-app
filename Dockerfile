FROM node:20-alpine

WORKDIR /app

# Install TMAS CLI
RUN apk add --no-cache curl tar && \
    curl -fSL --retry 3 --retry-delay 2 \
      "https://ast-cli.xdr.trendmicro.com/tmas-cli/latest/tmas-cli_Linux_x86_64.tar.gz" \
      -o /tmp/tmas.tar.gz && \
    tar -xzf /tmp/tmas.tar.gz -C /tmp && \
    mv /tmp/tmas-cli_Linux_x86_64/tmas /usr/local/bin/tmas && \
    chmod +x /usr/local/bin/tmas && \
    rm /tmp/tmas.tar.gz

COPY package*.json ./
RUN npm ci --only=production

COPY dgbank.html .
COPY server.js .

EXPOSE 3000

CMD ["node", "server.js"]
