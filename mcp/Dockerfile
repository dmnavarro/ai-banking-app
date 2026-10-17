FROM node:20-alpine

WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY server.js data.js ./

# Numeric UID of the image's "node" user, so Kubernetes runAsNonRoot can verify it
USER 1000:1000
EXPOSE 8080
CMD ["node", "server.js"]
