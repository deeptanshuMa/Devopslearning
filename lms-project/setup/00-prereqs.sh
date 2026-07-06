#!/usr/bin/env bash
# Installs Node 18, PostgreSQL, RabbitMQ, and PM2 on a fresh Ubuntu/Debian VPS.
# Run once as a user with sudo access: bash 00-prereqs.sh
set -euo pipefail

echo "==> Updating apt cache"
sudo apt-get update -y

echo "==> Installing base build tools"
sudo apt-get install -y build-essential curl gnupg2 ca-certificates lsb-release

echo "==> Installing Node.js 18.x (matches the Dockerfiles: node:18.13.0-bullseye-slim)"
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v)" != v18* ]]; then
  curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi
node -v
npm -v

echo "==> Installing PostgreSQL"
sudo apt-get install -y postgresql postgresql-contrib
sudo systemctl enable postgresql
sudo systemctl start postgresql

echo "==> Installing RabbitMQ"
sudo apt-get install -y rabbitmq-server
sudo systemctl enable rabbitmq-server
sudo systemctl start rabbitmq-server

echo "==> Installing PM2 globally"
sudo npm install -g pm2

echo "==> Done. Next: run 01-create-databases.sh"
