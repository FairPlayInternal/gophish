# syntax=docker/dockerfile:1

### Stage 1: (optional) build JS assets
FROM node:latest AS build-js
WORKDIR /build
COPY . .
RUN npm install --only=dev && \
    npm install gulp gulp-cli -g && \
    gulp

### Stage 2: build Go binary with CGO (sqlite support)
FROM golang:1.22-bullseye AS build-go
WORKDIR /src
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*

COPY go.mod go.sum ./
RUN go mod download
COPY . .
ENV CGO_ENABLED=1
RUN GOOS=linux GOARCH=amd64 go build -o gophish

### Stage 3: runtime
FROM debian:stable-slim
WORKDIR /opt/gophish

# non-root user
RUN useradd -m -d /opt/gophish -s /bin/bash app

# runtime deps: nginx + sqlite runtime + certs + caps
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates tzdata nginx libsqlite3-0 jq libcap2-bin && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/nginx/sites-enabled/default

# make nginx runtime dirs and allow 'app' to write them + conf.d
RUN mkdir -p /var/cache/nginx /var/log/nginx /run/nginx && \
    chown -R app:app /var/cache/nginx /var/log/nginx /run/nginx && \
    chown -R app:app /etc/nginx/conf.d

# copy built app + static assets
COPY --from=build-go /src/ /opt/gophish/
COPY --from=build-js  /build/static/js/dist/  ./static/js/dist/
COPY --from=build-js  /build/static/css/dist/ ./static/css/dist/

# entrypoint
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# allow nginx (running as 'app') to bind to :80
RUN sed -i 's/^\s*user\s\+\S\+;/user app;/' /etc/nginx/nginx.conf || true && \
    setcap 'cap_net_bind_service=+ep' /usr/sbin/nginx

# ensure app owns app dir (for config.json + gophish.db)
RUN chown -R app:app /opt/gophish

USER app

# App Service / ACA: expose 80 (Nginx)
EXPOSE 80
ENV FRONT_PORT=80 ADMIN_PORT=3333 PHISH_PORT=8081 ADMIN_USE_TLS=false PHISH_USE_TLS=false

ENTRYPOINT ["/entrypoint.sh"]
