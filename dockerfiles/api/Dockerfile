FROM golang:1.26 AS builder

ARG VERSION=dev
ARG COMMIT=unknown
ARG BUILD_DATE=unknown

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download
COPY . .

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
    -ldflags="-s -w \
    -X main.Version=${VERSION} \
    -X main.Commit=${COMMIT} \
    -X main.BuildDate=${BUILD_DATE}" \
    -o app \
    ./cmd/app

# =========================
# Runtime
# =========================

FROM alpine:3.22

RUN apk add --no-cache ca-certificates tzdata

WORKDIR /app

COPY --from=builder /src/app .
COPY --from=builder /src/migrations ./migrations

EXPOSE 8080

ENTRYPOINT ["./app"]
CMD ["serve"]



# FROM golang:1.26

# WORKDIR /app

# RUN go install github.com/githubnemo/CompileDaemon@latest

# COPY go.mod go.sum ./
# RUN go mod download

# CMD ["CompileDaemon", "--build=go build -o app ./cmd/app", "--command=./app serve"]