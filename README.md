# Local Development Environment

This repository contains the local development infrastructure for the project.

The environment includes:

* Caddy (reverse proxy)
* PostgreSQL
* RabbitMQ
* MinIO
* Mailpit
* Adminer

Application repositories are cloned automatically into the `workspace` directory using the provided Makefile.

## Requirements

* Docker
* Docker Compose
* Git
* GNU Make

## Project Structure

```text
localenv/
├── docker-compose.yml
├── Caddyfile
├── Makefile
└── workspace/
    ├── api/
    └── unowned/
```

## Initial Setup

Clone this repository:

```bash
git clone <repository-url>
cd localenv
```

Clone all project repositories and start the environment:

```bash
make init
```

This command will:

1. Create the `workspace` directory.
2. Clone all configured repositories.
3. Start all Docker services.

## Available Commands

### Clone repositories

```bash
make clone
```

### Update repositories

```bash
make pull
```

### Start infrastructure

```bash
make up
```

### Stop infrastructure

```bash
make down
```

### Restart infrastructure

```bash
make restart
```

### View logs

```bash
make logs
```

### Check container status

```bash
make status
```

### Remove containers and volumes

```bash
make clean
```

## Hosts Configuration

Custom local domains are used by Caddy.

Add the following entries to your hosts file.

### Linux / macOS

Edit:

```text
/etc/hosts
```

### Windows

Edit:

```text
C:\Windows\System32\drivers\etc\hosts
```

Add:

```text
127.0.0.1 app.localhost
127.0.0.1 api.localhost
127.0.0.1 db.localhost
127.0.0.1 queue.localhost
127.0.0.1 storage.localhost
127.0.0.1 s3.localhost
127.0.0.1 mailpit.localhost
```

## Services

| Service             | URL                       |
| ------------------- | ------------------------- |
| Frontend            | https://app.localhost     |
| API                 | https://api.localhost     |
| Adminer             | https://db.localhost      |
| RabbitMQ Management | https://queue.localhost   |
| MinIO Console       | https://storage.localhost |
| MinIO S3 API        | https://s3.localhost      |
| Mailpit             | https://mailpit.localhost |

## PostgreSQL

Default credentials:

```text
Host: postgres
Port: 5432
Database: unnamed_db
Username: postgres
Password: postgres
```

## RabbitMQ

Default credentials:

```text
Username: rbmq
Password: rbmq
```

## MinIO

Default credentials:

```text
Username: studio-minio
Password: studio-minio
```

## Notes

* All services are available through Caddy.
* Application repositories are mounted into containers from the local `workspace` directory.
* Docker volumes are used to persist PostgreSQL data.
* HTTPS certificates are automatically handled by Caddy for local development.
