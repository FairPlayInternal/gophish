# Gophish Codebase Technical Overview

This document describes how the Gophish application is structured, how core services interact, and which packages are responsible for the major features of the platform. Use it as a map when onboarding to the project or when planning significant changes.

## Runtime entry point and process lifecycle

Gophish ships as a single Go binary. The `main` function (in `gophish.go`) registers CLI flags, reads the `VERSION` file for build metadata, loads the JSON configuration, and wires together long-lived services before serving requests.【F:gophish.go†L28-L144】 The binary supports three modes: running both the administrative UI and phishing endpoint (`all`), only the admin UI (`admin`), or only the phishing endpoint (`phish`). Command-line switches also allow selecting an alternate `config.json` and disabling the internal mailer for multi-node deployments.【F:gophish.go†L47-L118】

During startup the application:

- Loads `config.json` through `config.LoadConfig`, which resolves server settings, database connection info, logging preferences, and the migrations directory.【F:config/config.go†L10-L67】
- Configures outbound network access by constraining HTTP clients and other dialers to an allowlist.【F:gophish.go†L85-L90】【F:dialer/dialer.go†L10-L158】
- Initializes logging, database connectivity, migrations, and the default administrator user via `models.Setup`, then ensures orphaned mail logs are unlocked so campaigns can resume.【F:gophish.go†L92-L110】【F:models/models.go†L24-L254】
- Builds the administrative HTTP server, the phishing server, and the background IMAP monitor; depending on the selected mode, each server is started in its own goroutine. Shutdown handlers ensure clean termination for all components when SIGINT is received.【F:gophish.go†L111-L143】

## Configuration and logging

The `config` package mirrors `config.json`, providing typed access to admin and phishing server settings, TLS certificates, database parameters, logging, and support contact metadata.【F:config/config.go†L10-L67】 Logging is centralized through the `logger` package, which wraps `logrus`, supports configurable log levels, and can tee output to both stderr and a file when requested.【F:logger/logger.go†L11-L112】 These facilities are activated early in `main` so subsequent packages can rely on a fully configured logger.

## Persistence layer

Database access is encapsulated in the `models` package. On initialization `models.Setup` applies migrations (using Goose), registers TLS roots for MySQL connections, and seeds the RBAC schema as well as the initial admin user and API token. It retries database connections, sets conservative pooling defaults, and logs generated credentials for first-time installs.【F:models/models.go†L24-L254】

The package defines the status constants that drive campaign lifecycles and user-facing dashboards (for example `CampaignQueued`, `CampaignInProgress`, `EventClicked`, etc.), ensuring consistent string usage across controllers, workers, and the API.【F:models/models.go†L42-L61】 RBAC primitives (`Role`, `Permission`, and the `HasPermission` helper) live alongside the user model and enforce the permission checks performed by middleware and controllers.【F:models/rbac.go†L3-L88】

## HTTP services

### Administrative server

`controllers.NewAdminServer` composes the admin HTTP server, injecting a background worker and configuring TLS defaults (TLS 1.2+, curated cipher suites) before binding to the configured listen address.【F:controllers/route.go†L31-L113】 Route registration wires UI endpoints (dashboard, campaign management, landing pages, sending profiles, settings, etc.), mounts the REST API under `/api/`, and serves the pre-built static frontend assets. Middleware layers enforce login, CSRF protection (with exceptions for API routes), rate limiting, security headers, request logging, and gzip compression.【F:controllers/route.go†L121-L172】

### REST API

The API server is packaged as an `http.Handler` that the admin server mounts. It shares the worker instance so API-triggered campaigns and test emails reuse the same infrastructure as the UI. Route registration enables CRUD endpoints for campaigns, groups, templates, landing pages, SMTP profiles, webhooks, IMAP settings, and user management, while applying middleware to enforce API key authentication, view-only restrictions, and permission checks.【F:controllers/api/server.go†L16-L94】【F:middleware/middleware.go†L14-L197】

### Phishing server

The phishing server handles recipient-facing traffic: pixel tracking, credential submission, and transparency requests. Like the admin server, it enforces modern TLS defaults and can self-generate certificates when none exist. Route registration serves static assets for landing pages, tracks opens and clicks, accepts user reports, and logs phishing events. Responses are proxied through gzip and access logs for observability.【F:controllers/phish.go†L28-L166】 The `TrackHandler` checks for preview and transparency requests, records email opens, and returns the tracking pixel, illustrating how campaign events feed back into the data model.【F:controllers/phish.go†L168-L199】

## Authentication, authorization, and middleware

`middleware` centralizes request preprocessing. It attaches session and user context to every admin request, redirects unauthenticated users to the login page, and enforces password resets when required. API routes require either a query-string or Bearer API key, set CORS headers, and attach the authenticated user to the request context. Dedicated helpers enforce RBAC permissions for mutating operations and apply security headers to resist clickjacking. CSRF protection is applied by default with explicit exemptions for API routes.【F:middleware/middleware.go†L14-L197】 Request-scoped data is stored using the lightweight wrapper in `context`, which decorates `http.Request` with strongly typed keys while remaining compatible with Go’s standard context package.【F:context/context.go†L1-L27】 Password hashing, policy validation, and secure key generation are implemented in the `auth` package and reused by models and controllers wherever credentials are handled.【F:auth/auth.go†L12-L103】

## Campaign execution pipeline

Campaign sending and tracking is orchestrated asynchronously. The admin server injects a `worker.Worker` implementation (`DefaultWorker`) that polls the database every minute for queued mail logs, locks each batch, groups messages by campaign to maximize SMTP reuse, and forwards them to the mailer.【F:controllers/route.go†L31-L113】【F:worker/worker.go†L13-L117】 When a campaign is launched or test emails are requested, the worker generates the appropriate mail entries and pushes them through the same queue, ensuring consistent handling of backoff, retries, and status updates.【F:worker/worker.go†L118-L198】

The mailer maintains a channel of message batches destined for a single SMTP profile. For each batch it builds an SMTP dialer, handles connection retries with bounded backoff, and iterates through messages, generating personalized content, selecting the correct envelope sender, and interpreting SMTP response codes to decide whether to retry, reset the connection, or mark the message as permanently failed.【F:mailer/mailer.go†L14-L200】 SMTP dialers themselves are typically sourced from the sending profiles stored in the database, and benefit from the outbound network restrictions enforced by the `dialer` package when using HTTP transports or other external connections.【F:dialer/dialer.go†L10-L158】

## Event tracking and reporting

Campaign events (opens, clicks, submissions, and reports) are processed by the phishing controllers. `TrackHandler` logs opens, honours transparency lookups (appending `+` to a result ID), and returns a tracking pixel. Related handlers record reported emails and credential submissions, updating the result records through model helpers so dashboards and exports remain accurate.【F:controllers/phish.go†L168-L199】

Webhook delivery extends event distribution to external systems. The `webhook` package signs payloads with an HMAC SHA-256 signature, rejects redirect responses, and enforces timeouts. Multiple endpoints can be configured, each receiving asynchronous delivery attempts via goroutines, with errors logged through the shared logger.【F:webhook/webhook.go†L17-L113】

## IMAP monitoring for reported emails

For organizations that integrate user report mailboxes, the `imap` package runs a manager goroutine per user account. The monitor polls configured IMAP inboxes, authenticates, retrieves unread messages, extracts campaign result IDs, and updates the associated results as reported. It also handles non-campaign emails (logging them for manual review), can delete processed messages, and marks failures for retry. The manager reacts to new users being added by spawning new goroutines and respects per-account polling intervals.【F:imap/monitor.go†L29-L195】

## Utilities and supporting packages

The `util` package aggregates helpers used across the application. Examples include CSV parsing for target uploads (with column autodetection), mail parsing, and automatic generation of long-lived self-signed TLS certificates when administrators have not supplied their own. These utilities are relied on by controllers and setup routines to simplify user workflows.【F:util/util.go†L33-L194】

## Frontend assets and build tooling

While the Go backend serves HTML templates and APIs, most UI assets are precompiled. `gulpfile.js` orchestrates minification and bundling for vendor libraries, core application scripts, and stylesheets, generating files under `static/js/dist` and `static/css/dist`. Tasks can be run individually or via the default parallel `build` target.【F:gulpfile.js†L1-L103】 Webpack complements this by transpiling ES6 modules for selected screens (password reset flows, user management, webhook configuration) using Babel loaders.【F:webpack.config.js†L1-L23】 JavaScript tooling dependencies are tracked in `package.json` alongside runtime libraries like `zxcvbn` for password strength estimation.【F:package.json†L1-L36】

## Directory overview

- `controllers/` – HTTP handlers for the admin UI, phishing endpoints, and REST API.【F:controllers/route.go†L31-L172】【F:controllers/phish.go†L83-L166】【F:controllers/api/server.go†L16-L94】
- `models/` – ORM models, migrations bootstrap, and domain logic for campaigns, targets, results, RBAC, and more.【F:models/models.go†L24-L254】【F:models/rbac.go†L3-L88】
- `worker/` and `mailer/` – Background processing for campaign execution and SMTP delivery.【F:worker/worker.go†L13-L198】【F:mailer/mailer.go†L14-L200】
- `imap/`, `webhook/`, `dialer/`, `util/`, `auth/`, `logger/` – Supporting services for inbound reports, outbound event delivery, network safety, shared helpers, credential management, and logging infrastructure.【F:imap/monitor.go†L29-L195】【F:webhook/webhook.go†L17-L113】【F:dialer/dialer.go†L10-L158】【F:util/util.go†L33-L194】【F:auth/auth.go†L12-L103】【F:logger/logger.go†L11-L112】

Together, these packages form a cohesive phishing simulation platform: configuration flows into models and services, the admin server exposes management interfaces and APIs, the worker and mailer execute campaigns, and the phishing server plus IMAP/webhook integrations capture recipient interactions for reporting.
