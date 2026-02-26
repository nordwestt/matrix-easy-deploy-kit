# matrix-easy-deploy

A no-nonsense, beginner-friendly way to run your own [Matrix](https://matrix.org) homeserver.

One script. A few questions. Your own corner of the internet.

---

## What you get

After running `setup.sh` you'll have a working Matrix homeserver — the whole stack, containerised and wired together:

| Service | What it does |
|---------|-------------|
| **[Synapse](https://github.com/element-hq/synapse)** | The Matrix homeserver. Handles federation, rooms, messages. |
| **[Element Web](https://github.com/element-hq/element-web)** | The web client. Served at your domain so anyone can log in from a browser. |
| **[Caddy](https://caddyserver.com)** | Reverse proxy. Handles TLS automatically via Let's Encrypt. |
| **PostgreSQL 16** | Database for Synapse. Considerably more robust than SQLite for anything beyond a toy. |

Everything runs in Docker Compose. Caddy manages your TLS certificate without you lifting a finger.

---

## Why does this exist?

Self-hosting Matrix is genuinely powerful — you own your conversations, your data, your server rules. But the official documentation assumes you already know what a reverse proxy is and why you might need one, and a fair bit of patience for YAML.

This project makes the first step easier. It doesn't abstract away the details — it sets things up correctly and then gets out of your way, so you can see exactly what's running and why.

---

## Requirements

- **A Linux server** with a public IP address (a cheap VPS works fine)
- **A domain name** pointed at that server (e.g. `matrix.example.com` → your server's IP)
- **Docker** (Engine 24+ recommended) — [install guide](https://docs.docker.com/engine/install/)
- **Docker Compose v2** — comes bundled with recent Docker Desktop and Docker Engine
- `curl`, `openssl`, `python3` — standard on most distributions

> **DNS first.** Make sure your DNS A record is live before running setup. Caddy needs to reach Let's Encrypt to issue your certificate, and that requires your domain to already be resolving.

---

## Quick start

```bash
git clone https://github.com/yourname/matrix-easy-deploy
cd matrix-easy-deploy
bash setup.sh
```

The wizard will ask you:

1. **Your Matrix domain** — something like `matrix.example.com`
2. **Your server name** — appears in Matrix IDs like `@you:example.com` (defaults to the base domain)
3. **Admin username and password**
4. Whether to allow public registration
5. Whether to enable federation

Everything else — database passwords, signing keys, internal secrets — is generated automatically.

---

## Project layout

```
matrix-easy-deploy/
│
├── setup.sh                      # The wizard. Start here.
├── start.sh                      # Bring everything back up
├── stop.sh                       # Bring everything down (data is preserved)
│
├── caddy/
│   ├── docker-compose.yml        # Caddy service definition
│   ├── Caddyfile.template        # Routing template (rendered during setup)
│   └── Caddyfile                 # Generated — do not edit by hand
│
├── modules/
│   └── core/                     # The core Matrix stack
│       ├── docker-compose.yml    # Synapse + Element + PostgreSQL
│       ├── synapse/
│       │   ├── homeserver.yaml.template
│       │   ├── homeserver.yaml   # Generated during setup
│       │   └── log.config
│       └── element/
│           ├── config.json.template
│           └── config.json       # Generated during setup
│
└── scripts/
    ├── lib.sh                    # Shared shell utilities
    └── create-admin.sh           # Admin user registration helper
```

Modules live in `modules/`. The core stack is itself a module — bridges, bots, and other additions will each have their own directory under `modules/` with their own `docker-compose.yml` and `setup.sh`.

---

## Common operations

**View logs**
```bash
docker logs -f matrix_synapse
docker logs -f caddy
docker logs -f matrix_element
docker logs -f matrix_postgres
```

**Stop all services** (data stays intact in Docker volumes)
```bash
bash stop.sh
```

**Start all services**
```bash
bash start.sh
```

**Update images to the latest release**
```bash
bash stop.sh
docker pull matrixdotorg/synapse:latest
docker pull vectorim/element-web:latest
docker pull caddy:2-alpine
docker pull postgres:16-alpine
bash start.sh
```

**Reload Caddy after editing the Caddyfile**
```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

---

## Re-running setup

If you need to change your domain or reconfigure anything, you can re-run `setup.sh`. It will regenerate all config files and restart services. If you already have data you want to preserve, stop first:

```bash
bash stop.sh
bash setup.sh
```

> Secrets (database password, signing keys, etc.) are re-generated each time you run setup. If you want to preserve an existing database, back it up first, or manually edit `.env` and the config files instead of re-running setup.

---

## Adding modules

The project is designed to grow. Each optional component (a bridge to Discord, a Telegram bridge, a bot framework) lives in its own module under `modules/`. When a module is ready, you enable it with:

```bash
bash setup.sh --module <module-name>
```

This calls the module's own `setup.sh`, which can ask its own questions, pull its own images, and register itself with the rest of the stack without touching the core configuration.

More modules coming. Watch this space.

---

## Troubleshooting

**Caddy can't get a certificate**

Usually a DNS issue. Check that your domain resolves to your server's IP:
```bash
dig +short matrix.example.com
```
If it doesn't match, wait for DNS to propagate and try again. Caddy logs all certificate activity:
```bash
docker logs caddy
```

**Synapse takes a long time to start**

On first boot, Synapse runs database migrations. If your VPS is modest, give it a minute or two. The setup wizard polls every 5 seconds and will wait up to 3 minutes.

**The admin user wasn't created**

If Synapse wasn't responding in time, the wizard prints the manual command:
```bash
bash scripts/create-admin.sh \
    https://matrix.example.com \
    <your_registration_shared_secret> \
    admin \
    <your_password>
```
The `REGISTRATION_SHARED_SECRET` is in your `.env` file.

**Synapse reports database connection errors**

Make sure the `matrix_postgres` container is healthy before Synapse tries to connect. You can check:
```bash
docker inspect matrix_postgres | grep -A 5 Health
```

---

## Security notes

- Your `.env` file contains database credentials and internal secrets. It's in `.gitignore` — keep it that way.
- Public registration is off by default. Think carefully before turning it on; an open Matrix server is a spam target.
- Federation is on by default. If you want a private, islands-only server, disable it during setup.
- The Synapse admin API (`/_synapse/admin/`) is accessible via Caddy. It requires a valid admin access token to use — the setup just exposes the routing; auth is Synapse's business.

---

## Contributing

Issues, fixes, and module contributions are welcome. If you're adding a new module, follow the pattern in `modules/core/` — a `docker-compose.yml` for services and a `setup.sh` that sources `scripts/lib.sh` for prompts and helpers.

---

## Licence

MIT. Do what you like with it.
