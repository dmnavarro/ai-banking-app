FROM node:20-alpine

WORKDIR /app

# Install TMAS CLI
RUN apk add --no-cache curl tar && \
    curl -L https://cli.artifactscan.cloudone.trendmicro.com/tmas-cli/latest/tmas-linux-amd64.tar.gz \
      -o /tmp/tmas.tar.gz && \
    tar -xzf /tmp/tmas.tar.gz -C /tmp && \
    mv /tmp/tmas /usr/local/bin/tmas && \
    chmod +x /usr/local/bin/tmas && \
    rm /tmp/tmas.tar.gz

COPY package*.json ./
RUN npm ci --only=production

COPY dgbank.html .
COPY server.js .

EXPOSE 3000

CMD ["node", "server.js"]
