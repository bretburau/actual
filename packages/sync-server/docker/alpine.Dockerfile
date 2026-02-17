FROM node:22-alpine AS deps

# Install required packages
RUN apk add --no-cache python3 openssl build-base
RUN corepack enable

WORKDIR /app

# Copy only the files needed for installing dependencies
COPY .yarn ./.yarn
COPY yarn.lock package.json .yarnrc.yml ./
COPY packages/api/package.json packages/api/package.json
COPY packages/component-library/package.json packages/component-library/package.json
COPY packages/crdt/package.json packages/crdt/package.json
COPY packages/desktop-client/package.json packages/desktop-client/package.json
COPY packages/desktop-electron/package.json packages/desktop-electron/package.json
COPY packages/eslint-plugin-actual/package.json packages/eslint-plugin-actual/package.json
COPY packages/loot-core/package.json packages/loot-core/package.json
COPY packages/sync-server/package.json packages/sync-server/package.json
COPY packages/plugins-service/package.json packages/plugins-service/package.json

# Avoiding memory issues with ARMv7
RUN if [ "$(uname -m)" = "armv7l" ]; then yarn config set taskPoolConcurrency 2; yarn config set networkConcurrency 5; fi

# Install all dependencies (including dev deps) so we can build the web UI
RUN yarn install --network-concurrency 6

FROM deps AS builder

WORKDIR /app

# Copy source so we can build web and server artifacts inside the image
COPY packages/desktop-client ./packages/desktop-client
COPY packages/sync-server ./packages/sync-server

# Build web UI and server
RUN yarn workspace @actual-app/web build
RUN yarn workspace @actual-app/sync-server build

FROM alpine:3.22 AS prod

# Minimal runtime dependencies
RUN apk add --no-cache nodejs tini su-exec

# Create a non-root user
ARG USERNAME=actual
ARG USER_UID=1001
ARG USER_GID=$USER_UID
RUN addgroup -S ${USERNAME} -g ${USER_GID} && adduser -S ${USERNAME} -G ${USERNAME} -u ${USER_UID}
RUN mkdir /data && chown -R ${USERNAME}:${USERNAME} /data

WORKDIR /app
ENV NODE_ENV=production

# Pull in only the necessary artifacts (built node_modules, server files, etc.)
COPY --from=builder /app/node_modules /app/node_modules
COPY --from=builder /app/packages/sync-server/package.json ./
COPY --from=builder /app/packages/sync-server/build ./

# Add entrypoint script to handle migrations and permissions
COPY ./entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/sbin/tini","-g",  "--"]
EXPOSE 5006
CMD ["/app/entrypoint.sh"]
