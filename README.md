# Magento 2 + Warden Installer

A single `make` command that bootstraps a fully configured Magento 2 development environment using [Warden](https://docs.warden.dev).

## Prerequisites

| Tool | Purpose |
|------|---------|
| [Warden](https://docs.warden.dev/installing.html) | Docker-based dev environment manager |
| [Docker Desktop](https://www.docker.com/products/docker-desktop/) | Container runtime |
| Magento Marketplace credentials | Downloading Magento via Composer |

Before running the installer, make sure your Magento Marketplace credentials are present in `~/.composer/auth.json`:

```json
{
    "http-basic": {
        "repo.magento.com": {
            "username": "<your-public-key>",
            "password": "<your-private-key>"
        }
    }
}
```

You can generate keys at [commercemarketplace.adobe.com](https://commercemarketplace.adobe.com/customer/accessKeys/).

Warden must also be running before you start:

```bash
warden svc up
```

## Usage

```bash
make create-magento <domain> <magento-version>
```

### Example

```bash
make create-magento app.examplemagento.test 2.4.8-p3
```

This creates a new project directory `./examplemagento/` relative to the Makefile, installs Magento `2.4.8-p3`, and makes it available at `https://app.examplemagento.test`.

## Domain convention

The domain argument follows the pattern `app.<project-name>.test`. The middle segment becomes the Warden environment name and the project directory name.

| Argument | Result |
|----------|--------|
| `app.examplemagento.test` | env name: `examplemagento`, project dir: `./examplemagento/` |
| `app.myshop.test` | env name: `myshop`, project dir: `./myshop/` |

## Variables

Override any variable directly on the command line:

| Variable | Default | Description |
|----------|---------|-------------|
| `PHP_VERSION` | `8.3` | PHP version used inside the Warden container |

```bash
# Use a different PHP version
make create-magento app.myshop.test 2.4.7-p5 PHP_VERSION=8.2
```

## What it does

Before the numbered steps begin, the installer runs a **pre-flight validation**: it checks that both arguments are provided, that `warden` is available in `$PATH`, and that the target project directory does not already exist.

The 8 numbered steps are:

### 1. Create project directory
Creates `<project-name>/` next to the Makefile. All Magento files will live here.

### 2. Initialise Warden environment
- Runs `warden env-init` with environment type `magento2`
- Patches `PHP_VERSION` in the generated `.env` file
- Signs a local TLS certificate for `<project-name>.test`

### 3. Start Warden environment
- Brings up all Docker services (PHP-FPM, Nginx, MySQL, Redis, OpenSearch, RabbitMQ, Varnish)
- Waits 10 seconds for Mutagen file sync to initialise

### 4. Install Magento via Composer
Downloads `magento/project-community-edition` at the requested version from `repo.magento.com` and installs it into the container webroot.

### 5. Run Magento setup:install
Installs Magento with the following service configuration:

| Service | Host | Notes |
|---------|------|-------|
| Database | `db` | database: `magento`, user: `magento` |
| OpenSearch | `opensearch:9200` | index prefix: `magento2` |
| Redis (sessions) | `redis:6379` | db: `2` |
| Redis (cache) | `redis:6379` | db: `0` |
| Redis (full-page cache) | `redis:6379` | db: `1` |
| RabbitMQ | `rabbitmq:5672` | user: `guest` |
| Varnish | `varnish:80` | full-page cache |

### 6. Apply environment configuration
Locks the following settings via `--lock-env` (they cannot be changed from the admin panel):

| Config path | Value | Purpose |
|-------------|-------|---------|
| `web/secure/offloader_header` | `X-Forwarded-Proto` | SSL termination via Varnish/Traefik |
| `web/secure/use_in_frontend` | `1` | Force HTTPS on storefront |
| `web/secure/use_in_adminhtml` | `1` | Force HTTPS on admin |
| `web/seo/use_rewrites` | `1` | Enable URL rewrites |
| `system/full_page_cache/caching_application` | `2` | Use Varnish for full-page cache |
| `system/full_page_cache/ttl` | `604800` | FPC TTL: 7 days |
| `catalog/search/enable_eav_indexer` | `1` | Enable EAV indexer for search |

### 7. Enable developer mode
Sets Magento to developer mode so errors are shown and static content is generated on the fly.

### 8. Disable extra modules
Disables two modules that are not needed in a local development environment:

| Module | Why disabled |
|--------|-------------|
| `Magento_TwoFactorAuth` | 2FA on the admin login blocks access during local development |
| `Magento_AdminAdobeImsTwoFactorAuth` | Adobe IMS-based 2FA, also blocks admin access locally |

## Credentials

| | Value |
|-|-------|
| Admin URL | `https://app.<project-name>.test/admin` |
| Admin user | `admin` |
| Admin password | `password1` |
| Database | host `db`, name `magento`, user `magento`, password `magento` |

## Troubleshooting

**`warden is not installed or not found in PATH`**
Install Warden from [docs.warden.dev/installing.html](https://docs.warden.dev/installing.html) and make sure `warden svc up` has been run.

**`directory already exists`**
The project directory from a previous run is still there. Remove it and try again:
```bash
cd examplemagento && warden env down && cd .. && rm -rf examplemagento
```

**Composer authentication error**
Your Magento Marketplace keys are missing or wrong. Check `~/.composer/auth.json` and verify the keys at [commercemarketplace.adobe.com](https://commercemarketplace.adobe.com/customer/accessKeys/).

**Certificate not trusted in browser**
Run `warden trust-ca` once to add Warden's root CA to your system trust store.