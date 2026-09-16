# syntax=docker/dockerfile:1.7
FROM node:22.19.0-bookworm-slim@sha256:4973262386dc1cb70f7d6fc48a855027d8f12d2d3b1fe559b9db9a4fcb74668f AS build

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM node:22.19.0-bookworm-slim@sha256:4973262386dc1cb70f7d6fc48a855027d8f12d2d3b1fe559b9db9a4fcb74668f

ENV NODE_ENV=production PORT=8080
WORKDIR /app
COPY --from=build --chown=node:node /app/package.json /app/package-lock.json ./
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist/src ./dist/src
USER node
EXPOSE 8080
CMD ["node", "dist/src/index.js"]
