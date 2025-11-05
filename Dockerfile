# syntax=docker/dockerfile:1

# Stage 1: Build JS assets (optional, if you have web assets to build)
FROM node:latest AS build-js
WORKDIR /build
COPY . .
RUN npm install --only=dev && \
    npm install gulp gulp-cli -g && \
    gulp

# Stage 2: Build Go binary with CGO support for SQLite (optional MySQL fallback)
FROM golang:1.22-bullseye AS build-go
WORKDIR /src

# Install C toolchain + sqlite dev libs (for SQLite support)
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*

COPY go.mod go.sum ./
RUN go mod download

COPY . .
# Enable CGO (for sqlite driver) and build for linux/amd64
ENV CGO_ENABLED=1
RUN GOOS=linux GOARCH=amd64 go build -o gophish

# Stage 3: Runtime image
FROM debian:stable-slim
WORKDIR /opt/gophish

# Create user (official Dockerfile uses user app)
RUN useradd -m -d /opt/gophish -s /bin/bash app

# Install runtime dependencies, including sqlite3 library, Nginx, supervisor
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates tzdata nginx supervisor libsqlite3-0 jq libcap2-bin && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/nginx/sites-enabled/default

# Copy built artifacts
COPY --from=build-go /src/ /opt/gophish/
COPY --from=build-js  /build/static/js/dist/  ./static/js/dist/
COPY --from=build-js  /build/static/css/dist/ ./static/css/dist/

# Copy your custom configs
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker/entrypoint.sh /entrypoint.sh

# Fix permissions
RUN chown -R app:app /opt/gophish && \
    mkdir -p /etc/nginx/conf.d && \
    chown -R app:app /etc/nginx /var/lib/nginx /var/log/nginx && \
    chmod +x /entrypoint.sh && \
    setcap 'cap_net_bind_service=+ep' /opt/gophish/gophish

USER app

# Expose port 80 to align with Azure App Service or your Nginx frontend
EXPOSE 80

# Environment variables (defaults)
ENV FRONT_PORT=80 \
    ADMIN_PORT=3333 \
    PHISH_PORT=8081 \
    ADMIN_USE_TLS=false \
    PHISH_USE_TLS=false

ENTRYPOINT ["/entrypoint.sh"]
