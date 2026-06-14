# Architecture Guidelines for AI Agents (Clean Architecture)

This document defines the strict architectural rules and constraints that all AI agents must follow when adding new features, modifying existing code, or performing refactoring.

---

## Agent Workspace Index

To reduce repeated directory scanning, agents may consult this short index describing the repository layout and where to find key concerns.

- `cmd/` — application entrypoints and composition root (`cmd/app/main.go`).
- `internal/transport/http/` — HTTP handlers, router, DTOs and response helpers.

- `cmd/` — application entrypoints (`cmd/app/main.go`) (thin entrypoint; composition root moved to `internal/bootstrap/`).
- `internal/bootstrap/` — composition root and dependency wiring (`internal/bootstrap/app.go`, `internal/bootstrap/worker.go`).

 - `internal/transport/http/` — HTTP handlers, router, DTOs and response helpers.
- `internal/service/` — business logic / services.
- `internal/repository/postgres/` — raw SQL repository implementations (pgx).
- `internal/domain/` — domain entities and interfaces (contracts).
- `internal/infrastructure/` — integrations (mailer, queue, storage).
- `internal/middleware/` — HTTP middleware (auth, rate limiting, tracing).
- `internal/worker/` — background workers and message handlers.
- `migrations/` — SQL migrations (apply when updating schema).
- `internal/docs/openapi.yaml` — canonical OpenAPI spec for HTTP endpoints.

Agents should prefer this index for quick navigation before doing deep recursive scans.

## 1. Layer Dependency Rules

Dependencies must always flow in a single direction:

```text
HTTP / CLI -> Service -> Repository -> PostgreSQL
```

* Outer layers are allowed to know about inner layers.
* Inner layers must **never** know implementation details of outer layers.
* Communication between layers must occur exclusively through interfaces defined in the **Domain** layer.

---

## 2. Layer Responsibilities

### Domain Layer (`internal/domain/`)

The Domain layer contains only business entities and interfaces (contracts). It is split into four focused packages — each owns exactly one concept:

| Package | Contents |
|---|---|
| `internal/domain/user` | `User` entity · `UserRepository` · `UserService` |
| `internal/domain/role` | `Role` entity · `RoleRepository` |
| `internal/domain/permission` | `Permission` entity · `PermissionRepository` · `PermissionService` |
| `internal/domain/token` | `RefreshToken` entity · `RefreshTokenRepository` · `Manager` · `ManagerExtended` |

Cross-domain references use plain scalar types (`int64`, `string`) instead of importing sibling packages. This keeps the dependency graph acyclic — no domain package imports another domain package.

**STRICTLY FORBIDDEN** to import in any domain package:

* Any database libraries (`pgx`, `sql`, `gorm`, etc.)
* Routers and HTTP packages (`chi`, `http`, `gin`)
* Logging frameworks (`logrus`, `zap`)
* Infrastructure authentication packages (`jwt`, `oauth`)

The Domain layer must depend only on the Go standard library (e.g. `time`, `context`).

---

### Service Layer (`internal/service/`)

Contains the application's business logic.

Requirements:

* Must interact with repositories and authentication managers exclusively through Domain interfaces.
* Must remain independent of JWT implementation details.
* Must remain independent of PostgreSQL implementation details.
* Passwords must only be stored and processed as hashes using:

```go
golang.org/x/crypto/bcrypt
```

* Plain-text password storage is strictly prohibited.

---

### Repository Layer (`internal/repository/`)

Responsible for data persistence.

Requirements:

* Must use:

```go
github.com/jackc/pgx/v5/pgxpool
```

* **ORMs are STRICTLY PROHIBITED**:

  * GORM
  * Ent
  * Bun
  * Any other ORM

Only raw SQL with pgx is allowed.

Additional requirements:

* Repository implementations must translate database-specific errors into domain-level errors.
* Example: PostgreSQL unique constraint violation (`23505`) should be converted into an appropriate application error from:

```text
internal/errs
```

* Repository layer must not contain business logic.

---

### HTTP / Transport Layer (`internal/transport/http/`)

Responsible for:

* Receiving requests
* Request validation
* Calling services
* Returning responses

Requirements:

* Routing must be implemented using:

```go
github.com/go-chi/chi/v5
```

* Direct usage of:

```go
http.Error(...)
```

is prohibited.

All responses must be returned through the centralized response package and follow a unified JSON format.

Success response:

```json
{
  "data": {}
}
```

Error response:

```json
{
  "error": {
    "code": "ERR_CODE",
    "message": "readable message"
  }
}
```

### Response Types
All handler responses must use typed DTO structs. Anonymous maps (`map[string]string`)
are strictly prohibited in handler responses.

Response structs must be declared in:

```text
internal/transport/http/dto/
```

Simple message responses must use:

```go
dto.MessageResponse{Message: "..."}
```

Business logic inside handlers is strictly prohibited.

---

### CLI / CMD Layer (`cmd/`)

Application entry point and bootstrap layer based on:

```go
github.com/spf13/cobra
```

Responsibilities:

* Configuration loading
* Dependency injection
* Application startup
* Graceful shutdown

### Dependency Injection

All dependencies must be assembled manually in a single composition root.

Initialization order:

```text
Config
    ↓
Logger
    ↓
Database
    ↓
Repositories
    ↓
TokenManager
    ↓
Services
    ↓
Handlers
    ↓
Router
    ↓
HTTP Server
```

Global variables for business logic are prohibited.

---

### Graceful Shutdown

Every HTTP server must support graceful shutdown.

Requirements:

* Handle:

  * `SIGINT`
  * `SIGTERM`

* Shutdown timeout:

```go
5 * time.Second
```

Shutdown sequence:

1. Stop accepting new requests
2. Complete active requests
3. Close PostgreSQL connection pool
4. Write shutdown logs

---

## 3. Authentication

Authentication must be implemented through the `token.Manager` abstraction defined in `internal/domain/token`.

### Domain Contract

`internal/domain/token/token.go` defines the token Manager contracts.

```go
// Manager is the primary contract — used by services and middleware.
type Manager interface {
  Generate(userID int64) (string, error)
  Parse(token string) (int64, error)
}

// ManagerExtended embeds Manager and adds role + version-aware token support.
// Used by AuthService and JWTAuth middleware.
// Note: access tokens now include a `ver` claim representing the user's
// current `token_version` value. Implementations MUST surface the token
// version during generation and parsing so middleware can reject stale JWTs.
type ManagerExtended interface {
  Manager
  // GenerateWithRole creates a token embedding role and the user's token version.
  GenerateWithRole(userID int64, role string, tokenVersion int) (string, error)
  // ParseWithRole returns userID, role, and tokenVersion extracted from the token.
  ParseWithRole(token string) (int64, string, int, error)
}
```

The same file also defines `RefreshToken` and `RefreshTokenRepository` — keeping all token-related domain contracts in one place.

Important notes:
- Access tokens include a `ver` claim mirroring `users.token_version`. When a user's `token_version` increments, previously issued JWTs become invalid.
- Services must call the `UserRepository` contract to increment `token_version` when performing global session invalidation events (e.g. password change, logout-all, admin force logout).
- The JWT middleware (`internal/middleware/jwt.go`) MUST use a `UserService` or `UserRepository` to compare the token's `ver` claim with the current `token_version` and return `401 Unauthorized` on mismatch.

`RefreshToken` now tracks lifecycle state (`active`, `revoked`, `expired`) and stores only a hashed refresh token value (`token_hash`). Refresh rotation must invalidate a refresh token immediately after it is used.

### Infrastructure Implementation

JWT implementation belongs exclusively to the infrastructure layer.

Location:

```text
internal/auth/jwt.go
```

`JWTManager` satisfies both `token.Manager` and `token.ManagerExtended`. Compile-time checks are enforced with `var _ token.Manager = (*JWTManager)(nil)`.

Requirements:

* JWTManager must emit and validate standard registered claims: `iss`, `aud`, `sub`, `jti`, `iat`, `nbf`, and `exp`.
* Services must depend only on `token.Manager` or `token.ManagerExtended`.
* Services must never import JWT packages directly.
* JWT implementation must be replaceable without changing business logic.

Possible future replacements:

* Redis Sessions
* OAuth2
* Keycloak
* OpenID Connect

## Password Reset Flow

The application includes a secure password reset flow implemented according to the same Clean Architecture rules.

- Persistence: a new table `password_reset_tokens` stores one-time reset tokens with fields: `id`, `user_id`, `token`, `expires_at`, `used_at`, `created_at`.
- Domain: new domain package `internal/domain/passwordreset` defines `Token` and the `Repository` interface (Create, GetByToken, MarkUsed, DeleteByUserID).
- Repository: implementations live in `internal/repository/postgres` and perform raw SQL against the `password_reset_tokens` table. Repositories translate DB errors into `internal/errs` values.
- Service: `PasswordResetService` (in `internal/service`) is responsible for:
  - creating a single active reset token per user (old tokens are deleted),
  - generating cryptographically secure tokens,
  - rendering and sending the reset email via the `domain/mailer` contract,
  - validating tokens (expiry and used-state),
  - updating the user's hashed password, marking the token used, and revoking all refresh tokens for the user.
- Transport: HTTP handlers expose two endpoints:
  - `POST /api/v1/auth/forgot-password` — accepts `{"email": "..."}` and always responds 200 with a generic message (prevents account enumeration).
  - `POST /api/v1/auth/reset-password` — accepts `{"token": "...", "new_password": "..."}` and performs the reset.

Security notes:
- Reset tokens are short-lived and single-use; services must check `expires_at` and `used_at`.
- On successful password reset, all refresh tokens are revoked using the `RefreshTokenRepository` contract to force re-authentication.
- Email sending failures during token creation are logged but do not cause the API to reveal token state to callers.
 - Administrators may also deactivate accounts (set `deactivated_at`); deactivated accounts must be denied login and token refresh and all sessions/tokens must be revoked.

### Refresh token reuse detection

The system detects reuse of revoked refresh tokens (an indicator of stolen tokens). When detected, services must:

- Immediately revoke all user sessions (`UserSessionRepository.RevokeAllByUserID`).
- Revoke all refresh tokens for the user (`RefreshTokenRepository.RevokeAllByUserID`).
- Publish an audit event named `audit.refresh_token_reuse_detected` containing `user_id`, `ip_address`, `user_agent`, and `token_hash`.
- Optionally send a notification email to the affected user.

Consumers handling audit events should persist `audit.refresh_token_reuse_detected` entries to `audit_logs` for security investigation.

## Transactional Outbox Pattern

The application uses a Transactional Outbox to reliably publish domain events to external brokers (RabbitMQ) while keeping domain state changes and event persistence atomic.

- Persist events into `outbox_events` within the same DB transaction as domain changes.
- A background worker reads `pending` events (using `FOR UPDATE SKIP LOCKED`), marks them `processing`, republishes to the broker, and then marks them `processed` or `failed`.
- Supported statuses: `pending`, `processing`, `processed`, `failed`.
- Use an `OutboxPublisher` adapter in `internal/infrastructure/outbox` to write events into the outbox instead of publishing directly to AMQP from services.
- The worker lives in `internal/worker/outbox` and republishes using the existing AMQP publisher (`internal/infrastructure/queue`).
- Implement an in‑proc bridge (`internal/infrastructure/outbox/bridge.go`) that lets the in‑process event bus write events to outbox for durability.
- Use `retry_count` and a configurable retry policy; consider adding `next_attempt_at` for backoff in the future.
- For strong guarantees across services consider implementing an Outbox drain/dispatcher with idempotence keys and an explicit deduplication strategy.

Location:

- Outbox domain contract: `internal/domain/outbox`
- Postgres repo: `internal/repository/postgres/outbox`
- Worker: `internal/worker/outbox`
- Outbox publisher adapter: `internal/infrastructure/outbox`

Usage guidance:

- Services should write events via the `event.Publisher` abstraction which can be backed by the OutboxPublisher during normal operation.
- The worker republishes to RabbitMQ so existing downstream consumers continue to work without changes.


## Rate Limiting

The application protects critical authentication endpoints against brute-force and credential stuffing attacks using endpoint-specific rate limiting implemented in the middleware layer.

### Design

Rate limiting is implemented through two mechanisms:

1. **Global Rate Limiter** (`middleware.RateLimit`): A shared token bucket limiter using `golang.org/x/time/rate` applied to all endpoints by default. Configured via `RATE_LIMIT` (requests) and `RATE_LIMIT_WINDOW` (duration).

2. **Auth Endpoint Rate Limiter** (`middleware.AuthRateLimiter`): Custom in-memory rolling window tracker for authentication endpoints with per-IP and per-email tracking. Separate limits and windows per endpoint.

### Location

Rate limiting middleware is defined in:

```text
internal/middleware/ratelimit.go
internal/middleware/auth_ratelimit.go
```

### Implementation Requirements

**AuthRateLimiter Interface:**

- `Allow(identifier string) (allowed bool, remaining int)`: Check if a request is allowed; return remaining attempts in current window
- `Stop()`: Gracefully shutdown the limiter, stopping cleanup goroutine

**Endpoint-Specific Configuration:**

| Endpoint | Limiter | Tracking | Config Variables |
|---|---|---|---|
| `POST /api/v1/auth/login` | `AuthRateLimiter` | Per IP + Email | `LOGIN_RATE_LIMIT`, `LOGIN_RATE_LIMIT_WINDOW` |
| `POST /api/v1/auth/register` | `AuthRateLimiter` | Per IP + Email | `REGISTER_RATE_LIMIT`, `REGISTER_RATE_LIMIT_WINDOW` |
| `POST /api/v1/auth/forgot-password` | `AuthRateLimiter` | Per IP + Email | `FORGOT_PASSWORD_RATE_LIMIT`, `FORGOT_PASSWORD_RATE_LIMIT_WINDOW` |
| `POST /api/v1/auth/resend-verification` | `AuthRateLimiter` | Per IP + Email | `RESEND_VERIFICATION_RATE_LIMIT`, `RESEND_VERIFICATION_RATE_LIMIT_WINDOW` |
| `POST /api/v1/auth/verify-email` | Global | Per IP | `RATE_LIMIT`, `RATE_LIMIT_WINDOW` |
| `POST /api/v1/auth/reset-password` | Global | Per IP | `RATE_LIMIT`, `RATE_LIMIT_WINDOW` |
| `POST /api/v1/auth/refresh` | Global | Global | `RATE_LIMIT`, `RATE_LIMIT_WINDOW` |
| `POST /api/v1/auth/logout` | Global | Global | `RATE_LIMIT`, `RATE_LIMIT_WINDOW` |
| `POST /api/v1/auth/logout-all` | Authenticated | Global | `RATE_LIMIT`, `RATE_LIMIT_WINDOW` |

### Middleware Helpers

**`AuthRateLimitByIP(limiter)`**: Middleware that extracts client IP and calls `limiter.Allow(ip)`. Used for endpoints requiring only IP-based limiting.

**`AuthRateLimitByEmail(limiter, emailExtractor)`**: Middleware that extracts client IP and email from request (via custom function), creates combined identifier `"ip:email"`, and calls `limiter.Allow()`. Used for endpoints where email is the user identifier.

The `emailExtractor` function reads the request body, parses JSON to extract the email field, and restores the body for the next handler. Example:

```go
emailExtractorFunc := func(r *http.Request) (string, error) {
  var req struct {
    Email string `json:"email"`
  }
  body, _ := io.ReadAll(r.Body)
  r.Body = io.NopCloser(bytes.NewBuffer(body))
  json.Unmarshal(body, &req)
  return req.Email, nil
}
```

### Dependency Injection

In `cmd/app/main.go`, create one `AuthRateLimiter` instance per endpoint:

```go
loginLimiter := middleware.NewAuthRateLimiter(
  config.LoginRateLimit,
  config.LoginRateLimitWindow,
)
defer loginLimiter.Stop()

// ... create 3 more limiters for register, forgot-password, resend-verification

router := http.NewRouter(loginLimiter, registerLimiter, forgotPasswordLimiter, resendVerificationLimiter)
```

### Housekeeping

- Each `AuthRateLimiter` runs a cleanup goroutine that removes expired request records every minute to prevent memory leaks.
- Always call `limiter.Stop()` in graceful shutdown sequence to ensure goroutines terminate cleanly.
- Stale records are automatically cleaned when their time window expires.

### Error Response

When rate limit is exceeded, middleware responds with HTTP 429:

```json
{
  "error": {
    "code": "RATE_LIMITED",
    "message": "too many requests, please try again later"
  }
}
```

With header:

```http
X-RateLimit-Remaining: 0
```

### Future Considerations

- **Distributed Deployments**: For horizontal scaling, consider replacing in-memory `AuthRateLimiter` with Redis-based implementation. Interface remains unchanged; only `internal/middleware/auth_ratelimit.go` needs modification.
- **Custom Policies**: Add per-user or per-role rate limiting without architectural changes.
- **Metrics**: Expose rate limit violations via Prometheus for monitoring and alerts.

---

## 5. Logging and Error Handling

### Logging

Logging must be implemented using a singleton `logrus` logger configured with JSON formatting.

Requirements:

* Structured logging
* Request logging middleware
* Panic recovery logging
* Error logging

Example:

```json
{
  "level": "info",
  "method": "POST",
  "path": "/api/v1/auth/login",
  "status": 200,
  "duration_ms": 14
}
```

---

### Request Tracing

A Request ID middleware is mandatory.

Requirements:

* Generate a unique request ID for every request
* Expose it through the `X-Request-Id` header
* Include it in logs whenever possible

---

### Error Management

Application errors must be declared in:

```text
internal/errs/errors.go
```

Example:

```go
var (
ErrUserNotFound       = errors.New("user not found")
ErrInvalidCredentials = errors.New("invalid credentials")
ErrUserAlreadyExists  = errors.New("user already exists")
)
```

Requirements:

* Domain and service layers return domain errors.
* Transport layer maps errors to:

  * HTTP status codes
  * API error codes
  * Human-readable messages

Error mapping must be centralized in:

```text
internal/transport/http/response/response.go
```

No duplicated error handling logic is allowed across handlers.

---

## 6. API Documentation (OpenAPI / Swagger)

The API specification is maintained as a single source of truth in:

```text
internal/docs/openapi.yaml
```

The file is embedded into the binary at compile time via `internal/docs/openapi.go` using `//go:embed`.

The interactive Swagger UI is served at:

```
GET /swagger/index.html
GET /swagger/openapi.yaml   ← raw spec consumed by the UI
```

Routes are only registered when `APP_ENV != production`.

### Mandatory rule: keep the spec in sync

**Every time you add, remove, or change an HTTP endpoint you must update `internal/docs/openapi.yaml` in the same commit/PR.**

Checklist for any endpoint change:

- [ ] New path + HTTP method added under `paths:`.
- [ ] Request body schema added/updated in `components/schemas/`.
- [ ] All possible response codes documented (including `400`, `401`, `403`, `422`, `429`, `500` where applicable).
- [ ] `operationId` is unique and matches the handler name in snake_case (e.g. `authLogin`, `usersMe`).
- [ ] `tags:` matches one of the existing tag groups (`auth`, `password-reset`, `users`, `admin`, `uploads`, `health`) or a new tag is added to the top-level `tags:` list.
- [ ] `security: - BearerAuth: []` is present on every protected endpoint.
- [ ] The `servers:` block still points to the correct local development URL.

### What must NOT be done

* Do not add swaggo/swag annotations (`// @Summary`, `// @Router`, etc.) — the project uses a hand-maintained YAML spec, not code-generated docs.
* Do not create a separate `docs/swagger.json` or `docs/swagger.yaml` at the project root — the single source is `internal/docs/openapi.yaml`.
* Do not remove or rename existing `operationId` values without updating all references.

---

## 7. Non-Negotiable Rules

The following rules are mandatory and must never be violated:

* Follow Clean Architecture principles.
* Use Dependency Injection.
* Pass `context.Context` through all layers.
* Use Repository Pattern.
* Keep business logic inside services only.
* Keep SQL inside repositories only.
* Keep JWT implementation behind `TokenManager`.
* Use PostgreSQL via pgx only.
* Use Chi for HTTP routing.
* Use Cobra for CLI commands.
* Use Logrus for logging.
* Use golang-migrate for migrations.
* Do not use ORM libraries.
* Do not use global state for business logic.
* Do not place business logic inside HTTP handlers.
* Do not introduce layer dependency violations.
* **Keep `internal/docs/openapi.yaml` in sync with every endpoint change.**

Any code generated by an AI agent must comply with these rules.
