#!/usr/bin/env sh
set -e

# --- Required hostnames (set via App Settings or env vars) ---
: "${ADMIN_HOST:=admin.gophish.fairplay-digital.com}"
: "${PHISH_HOST:=gophish.fairplay-digital.com}"

# --- Ports inside the container ---
: "${FRONT_PORT:=80}"    # Nginx external (exposed via Azure)
: "${ADMIN_PORT:=3333}"  # GoPhish admin internal
: "${PHISH_PORT:=8081}"  # GoPhish phishing page internal

# --- TLS termination settings ---
: "${ADMIN_USE_TLS:=false}"
: "${PHISH_USE_TLS:=false}"

# --- Database logic: fallback to SQLite if MySQL not fully configured ---
DB_DRIVER="sqlite3"
DB_PATH="gophish.db"

if [ -n "${DB_HOST}" ] && [ -n "${DB_USERNAME}" ] && [ -n "${DB_PASSWORD}" ] && [ -n "${DB_DATABASE}" ]; then
  echo "MySQL configuration detected — using MySQL as database."
  DB_DRIVER="mysql"
  : "${DB_PORT:=3306}"
  DB_PATH="${DB_USERNAME}:${DB_PASSWORD}@(${DB_HOST}:${DB_PORT})/${DB_DATABASE}?charset=utf8mb4&parseTime=True&loc=UTC&tls=true"
else
  echo "No MySQL configuration provided — falling back to SQLite (default)."
fi

# Optional: If using GoPhish version > v0.10.1, you can provide initial admin password
# via environment variable GOPHISH_INITIAL_ADMIN_PASSWORD

# --- Write config.json for GoPhish ---
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

# --- Nginx virtual host configuration ---
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

# --- Launch supervisor to run Nginx + GoPhish ---
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
