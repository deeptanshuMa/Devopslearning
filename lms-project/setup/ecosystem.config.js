// PM2 process list for the whole LMS stack on a single VPS.
//
// EDIT THE `cwd` PATHS below to wherever you copied each repo's `app/`
// directory on the server, then run:
//
//   pm2 start setup/ecosystem.config.js
//   pm2 save
//   pm2 startup   # follow the printed instructions to survive reboots
//
// Each service reads its own DB/JWT/etc config from the `app/.env` file in
// its `cwd` (via dotenv) — see setup/env-templates/ for what belongs there.
// lms-notification connects to MongoDB, not Postgres — see
// setup/02-create-mongo-db.sh.

module.exports = {
  apps: [
    {
      name: "lms-gateway",
      cwd: "/opt/lms/api-gateway/app",
      script: "server.js",
      env: { NODE_ENV: "production" },
    },
    {
      name: "lms-usermgmt",
      cwd: "/opt/lms/usermgmt/app",
      script: "bin/www",
      env: { NODE_ENV: "production" },
    },
    {
      name: "lms-superadmin",
      cwd: "/opt/lms/superadmin/app",
      script: "bin/www",
      env: { NODE_ENV: "production" },
    },
    {
      name: "lms-org",
      cwd: "/opt/lms/org/app",
      script: "bin/www",
      env: { NODE_ENV: "production" },
    },
    {
      name: "lms-ticket",
      cwd: "/opt/lms/ticket/app",
      script: "bin/www",
      env: { NODE_ENV: "production" },
    },
    {
      name: "lms-notification",
      cwd: "/opt/lms/notification/app",
      script: "bin/www",
      env: { NODE_ENV: "production" },
    },
    {
      name: "lms-superadmin-frontend",
      cwd: "/opt/lms/superadmin-frontend/app",
      script: "node_modules/.bin/next",
      args: "start",
      env: { NODE_ENV: "production" },
    },
    {
      name: "lms-org-frontend",
      cwd: "/opt/lms/org-frontend/app",
      script: "node_modules/.bin/next",
      args: "start",
      env: { NODE_ENV: "production" },
    },
  ],
};
