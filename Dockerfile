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

# create nginx runtime + temp dirs and make them writable by 'app'
RUN mkdir -p /var/cache/nginx /var/log/nginx /run/nginx \
    /var/lib/nginx/body /var/lib/nginx/fastcgi /var/lib/nginx/proxy \
    /var/lib/nginx/scgi /var/lib/nginx/uwsgi && \
    chown -R app:app /var/cache/nginx /var/log/nginx /run/nginx /var/lib/nginx && \
    chown -R app:app /etc/nginx/conf.d

# copy built app + static assets
COPY --from=build-go /src/ /opt/gophish/
COPY --from=build-js  /build/static/js/dist/  /opt/gophish/static/js/dist/
COPY --from=build-js  /build/static/css/dist/ /opt/gophish/static/css/dist/

# entrypoint
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# run nginx as non-root: comment 'user' directive and allow bind(:80)
RUN sed -i 's/^\s*user\s\+\S\+;/# user disabled for non-root container;/' /etc/nginx/nginx.conf || true && \
    setcap 'cap_net_bind_service=+ep' /usr/sbin/nginx

# ensure 'app' owns the app dir (for config.json + gophish.db)
RUN chown -R app:app /opt/gophish

USER app

# ACA ingress targets port 8080 (nginx)
EXPOSE 8080
ENV FRONT_PORT=8080 ADMIN_PORT=3333 PHISH_PORT=8081 ADMIN_USE_TLS=false PHISH_USE_TLS=false

ENTRYPOINT ["/entrypoint.sh"]
