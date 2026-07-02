FROM node:20-alpine

WORKDIR /app

COPY package*.json ./
RUN npm ci --only=production

COPY trend-bank.html .
COPY server.js .

EXPOSE 3000

CMD ["node", "server.js"]
