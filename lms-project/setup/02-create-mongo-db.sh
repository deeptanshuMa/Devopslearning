#!/usr/bin/env bash
# Creates the MongoDB user + database used by the notification service.
# Usage: bash 02-create-mongo-db.sh <mongo_password>
set -euo pipefail

MONGO_PASSWORD="${1:?Usage: 02-create-mongo-db.sh <mongo_password>}"

mongosh <<-EOF
  use admin
  db.createUser({
    user: "admin",
    pwd: "${MONGO_PASSWORD}",
    roles: [ { role: "readWrite", db: "notifications" } ]
  })
EOF

echo "==> MongoDB user 'admin' created with access to the 'notifications' database."
echo "==> Set DB_URL=\"mongodb://admin:${MONGO_PASSWORD}@localhost:27017/notifications?authSource=admin\" in the notification service's .env"
