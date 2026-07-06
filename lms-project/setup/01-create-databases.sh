#!/usr/bin/env bash
# Creates the postgres role + 3 databases used by the LMS backends.
# Usage: sudo -u postgres bash 01-create-databases.sh <new_postgres_password>
set -euo pipefail

DB_PASSWORD="${1:?Usage: 01-create-databases.sh <postgres_password>}"

DATABASES=("user_management" "super_admin" "organization" "tickets")
# The notification service uses MongoDB, not Postgres — see
# 02-create-mongo-db.sh for that one instead.

echo "==> Setting password for role 'postgres'"
psql -v ON_ERROR_STOP=1 --username postgres <<-EOSQL
  ALTER USER postgres WITH PASSWORD '${DB_PASSWORD}';
EOSQL

for db in "${DATABASES[@]}"; do
  echo "==> Creating database '${db}' (skipping if it already exists)"
  psql -v ON_ERROR_STOP=1 --username postgres <<-EOSQL
    SELECT 'CREATE DATABASE ${db}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db}')\gexec
EOSQL

  # All models across these repos use UUID primary keys
  # (DataTypes.UUIDV4 or gen_random_uuid()). gen_random_uuid() is built into
  # Postgres 13+, but enabling pgcrypto is a harmless no-op if so and
  # required if the server is older.
  echo "==> Ensuring pgcrypto extension on '${db}'"
  psql -v ON_ERROR_STOP=1 --username postgres -d "${db}" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS pgcrypto;
EOSQL
done

echo "==> Databases ready: ${DATABASES[*]}"
echo "==> Set DB_HOST=localhost, DB_PORT=5432, DB_USER=postgres, DB_PASSWORD=${DB_PASSWORD} in each service's .env"
