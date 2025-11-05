#!/usr/bin/env sh
set -e

# --- Required hostnames (env or ACA app settings) ---
: "${ADMIN_HOST:=admin.gophish.fairplay-digital.com}"
: "${PHISH_HOST:=gophish.fairplay-digital.com}"

# --- Ports ---
: "${FRONT_PORT:=80}"     # Nginx external
: "${ADMIN_PORT:=3333}"   # GoPhish admin internal
: "${PHISH_PORT:=8081}"   # GoPhish phish internal

# --- TLS flags for GoPhish (TLS terminates at ACA/Frontdoor) ---
: "${ADMIN_USE_TLS:=false}"
: "${PHISH_USE_TLS:=false}"

# --- DB: use MySQL only if fully configured; otherwise SQLite (GoPhish default) ---
DB_DRIVER="sqlite3"
DB_PATH="gophish.db"
if [ -n "${DB_HOST}" ] && [ -n "${DB_USERNAME}" ] && [ -n "${DB_PASSWORD}" ] && [ -n "${DB_DATABASE}" ]; then
  echo "MySQL configuration detected — using MySQL."
  DB_DRIVER="mysql"
  : "${DB_PORT:=3306}"
  DB_PATH="${DB_USERNAME}:${DB_PASSWORD}@(${DB_HOST}:${DB_PORT})/${DB_DATABASE}?charset=utf8mb4&parseTime=True&loc=UTC&tls=true"
else
  echo "No MySQL configuration provided — falling back to SQLite (default)."
fi

# --- Generate GoPhish config.json ---
ADMIN_ORIGIN="https://${ADMIN_HOST}"
PHISH_ORIGIN="https://${PHISH_HOST}"
cat > /opt/gophish/config.json <<EOF_CONFIG
{
  "admin_server": {
    "listen_url": "0.0.0.0:${ADMIN_PORT}",
    "use_tls": ${ADMIN_USE_TLS},
    "trusted_origins": ["${ADMIN_ORIGIN}"]
  },
  "phish_server": {
    "listen_url": "0.0.0.0:${PHISH_PORT}",
    "use_tls": ${PHISH_USE_TLS},
    "trusted_origins": ["${PHISH_ORIGIN}"]
  },
  "db_name": "${DB_DRIVER}",
  "db_path": "${DB_PATH}"
}
EOF_CONFIG

# --- Generate Nginx vhost (host-based routing to admin/phish) ---
mkdir -p /etc/nginx/conf.d
cat > /etc/nginx/conf.d/gophish.conf <<EOF_NGINX
server {
  listen ${FRONT_PORT};
  server_name ${PHISH_HOST};
  location / {
    proxy_pass http://127.0.0.1:${PHISH_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Port 443;
    proxy_set_header X-Real-IP \$remote_addr;
  }
}
server {
  listen ${FRONT_PORT};
  server_name ${ADMIN_HOST};
  location / {
    proxy_pass http://127.0.0.1:${ADMIN_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Port 443;
    proxy_set_header X-Real-IP \$remote_addr;
  }
}
EOF_NGINX

# --- Start processes without supervisord ---
# Graceful shutdown handler
_term() {
  echo "Received TERM, stopping Nginx and GoPhish..."
  kill -TERM "$GOPHISH_PID" 2>/dev/null || true
  kill -TERM "$NGINX_PID" 2>/dev/null || true
  wait
}
trap _term INT TERM

# 1) start GoPhish in background
/opt/gophish/gophish -config /opt/gophish/config.json &
GOPHISH_PID=$!

# 2) start Nginx in foreground (preferred to keep it as the monitored process)
nginx -g "daemon off;" &
NGINX_PID=$!

# Wait for Nginx to exit; then stop GoPhish and exit with same code
wait "$NGINX_PID"
code=$?
kill -TERM "$GOPHISH_PID" 2>/dev/null || true
wait || true
exit "$code"
