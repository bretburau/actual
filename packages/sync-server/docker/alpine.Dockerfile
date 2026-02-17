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

# Copy root config files so we can build web and server artifacts
COPY tsconfig.json lage.config.js ./
COPY packages ./packages

# Build loot-core browser artifacts (inline the build-browser script logic)
# This creates the kcab worker files in desktop-client/public/kcab/ with hash in filename
RUN cd packages/loot-core && \
    mkdir -p ../desktop-client/public/data && \
    node bin/copy-migrations ../desktop-client/public/data && \
    cd ../desktop-client/public/data && \
    find * -type f | sort > ../data-file-index.txt && \
    cd ../../../loot-core && \
    rm -rf lib-dist/browser && \
    rm -rf ../desktop-client/public/kcab && \
    NODE_ENV=production yarn vite build --config ./vite.browser.config.ts && \
    cd ../..

# Build web UI with IS_GENERIC_BROWSER=1 and backend worker hash
# Extract the worker hash from the built filename
RUN sh -c 'export IS_GENERIC_BROWSER=1 && \
    WORKER_HASH=$(ls packages/desktop-client/public/kcab/kcab.worker.*.js 2>/dev/null | head -1 | sed "s/.*kcab\.worker\.\(.*\)\.js/\1/") && \
    echo "Found worker hash: $WORKER_HASH" && \
    export REACT_APP_BACKEND_WORKER_HASH=$WORKER_HASH && \
    yarn workspace @actual-app/web build'

# Build sync-server
RUN yarn workspace @actual-app/sync-server build

# Clean prod node_modules from builder (corepack is available here)
RUN yarn workspaces focus @actual-app/sync-server --production

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

# Copy pre-built production node_modules from builder
COPY --from=builder /app/node_modules /app/node_modules

# Copy built sync-server artifacts
COPY --from=builder /app/packages/sync-server/package.json ./
COPY --from=builder /app/packages/sync-server/build ./

# Copy built web UI (package.json and build directory) to expected node_modules location
COPY --from=builder /app/packages/desktop-client/package.json /app/node_modules/@actual-app/web/package.json
COPY --from=builder /app/packages/desktop-client/build /app/node_modules/@actual-app/web/build

# Add entrypoint script to handle migrations and permissions
COPY packages/sync-server/docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/sbin/tini","-g",  "--"]
EXPOSE 5006
CMD ["/app/entrypoint.sh"]
