#!/bin/sh
set -euo pipefail

# Ensure /data exists and has correct ownership (best effort)
if [ -d "/data" ]; then
  chown -R actual:actual /data || true
fi

# Run DB migrations if migration script exists
if [ -f "/app/build/src/scripts/run-migrations.js" ]; then
  echo "Running migrations..."
  node /app/build/src/scripts/run-migrations.js up || echo "Migrations failed or no-op"
fi

echo "Starting Actual sync-server as user 'actual'"
exec su-exec actual node /app/app.js
