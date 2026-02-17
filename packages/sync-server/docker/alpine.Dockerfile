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
RUN yarn install

FROM deps AS builder

WORKDIR /app

# Copy all packages and root config files so we can build web and server artifacts
COPY tsconfig.json eslint.config.mjs vite.config.mts vitest.config.ts lage.config.js ./
COPY packages ./packages

# Build loot-core first (required by web)
RUN yarn workspace loot-core build:web

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

# Copy root config and all package.json files for production install
COPY package.json yarn.lock .yarnrc.yml ./
COPY .yarn ./.yarn
COPY packages/api/package.json packages/api/package.json
COPY packages/component-library/package.json packages/component-library/package.json
COPY packages/crdt/package.json packages/crdt/package.json
COPY packages/desktop-client/package.json packages/desktop-client/package.json
COPY packages/desktop-electron/package.json packages/desktop-electron/package.json
COPY packages/eslint-plugin-actual/package.json packages/eslint-plugin-actual/package.json
COPY packages/loot-core/package.json packages/loot-core/package.json
COPY packages/sync-server/package.json packages/sync-server/package.json
COPY packages/plugins-service/package.json packages/plugins-service/package.json

# Install production dependencies only
RUN yarn workspaces focus @actual-app/sync-server --production

# Copy built sync-server artifacts
COPY --from=builder /app/packages/sync-server/build ./

# Copy built web UI to expected location
COPY --from=builder /app/packages/desktop-client/build /app/node_modules/@actual-app/web/build

# Add entrypoint script to handle migrations and permissions
COPY packages/sync-server/docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/sbin/tini","-g",  "--"]
EXPOSE 5006
CMD ["/app/entrypoint.sh"]
