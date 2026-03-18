.DEFAULT_GOAL := help
SHELL         := /bin/bash -o pipefail

# PHP version to use inside the Warden container.
# Extend this later to pick automatically based on Magento version.
PHP_VERSION ?= 8.3

# ─── Positional-argument parsing ─────────────────────────────────────────────
# Allows: make create-magento app.mysite.test 2.4.8-p3
#
# Make treats "app.mysite.test" and "2.4.8-p3" as additional targets.
# The catch-all pattern rule (%:) at the bottom turns them into no-ops.
ifeq (create-magento,$(firstword $(MAKECMDGOALS)))
  _DOMAIN      := $(word 2,$(MAKECMDGOALS))
  _M2_VERSION  := $(word 3,$(MAKECMDGOALS))
  # Extract the middle segment: app.examplemagento.test → examplemagento
  _ENV_NAME    := $(shell echo "$(_DOMAIN)" | cut -d'.' -f2)
  _PROJECT_DIR := $(CURDIR)/$(_ENV_NAME)
  _CERT_DOMAIN := $(_ENV_NAME).test
endif

# Swallow the extra positional args so make does not complain
%:
	@:

# ─── Public targets ───────────────────────────────────────────────────────────

.PHONY: help
help:
	@printf "Magento 2 + Warden installer\n\n"
	@printf "Usage:\n"
	@printf "  make create-magento <domain> <magento-version>\n\n"
	@printf "Example:\n"
	@printf "  make create-magento app.myproject.test 2.4.8-p3\n\n"
	@printf "Variables (override on the command line):\n"
	@printf "  PHP_VERSION=%-6s  PHP version inside the container (default: 8.3)\n" "$(PHP_VERSION)"

.PHONY: create-magento
create-magento: _validate _create-dir _warden-init _warden-up _composer-install _magento-install _magento-configure _magento-dev-mode _magento-disable-extra-modules
	@echo ""
	@echo "=================================================================="
	@echo " Magento $(_M2_VERSION) is ready!"
	@echo " Store URL : https://app.$(_ENV_NAME).test"
	@echo " Admin URL : https://app.$(_ENV_NAME).test/admin"
	@echo " Username  : admin"
	@echo " Password  : password1"
	@echo "=================================================================="

# ─── Private steps (prefixed with _ to signal they are not meant to be called directly) ──

.PHONY: _validate
_validate:
	@[ -n "$(_DOMAIN)" ] || { \
		echo "Error: <domain> argument is missing."; \
		echo "Usage: make create-magento <domain> <magento-version>"; \
		exit 1; \
	}
	@[ -n "$(_M2_VERSION)" ] || { \
		echo "Error: <magento-version> argument is missing."; \
		echo "Usage: make create-magento <domain> <magento-version>"; \
		exit 1; \
	}
	@command -v warden >/dev/null 2>&1 || { \
		echo "Error: warden is not installed or not found in PATH."; \
		exit 1; \
	}
	@[ ! -d "$(_PROJECT_DIR)" ] || { \
		echo "Error: directory '$(_PROJECT_DIR)' already exists. Remove it first."; \
		exit 1; \
	}
	@echo "Domain      : $(_DOMAIN)"
	@echo "Env name    : $(_ENV_NAME)"
	@echo "Version     : $(_M2_VERSION)"
	@echo "PHP version : $(PHP_VERSION)"
	@echo "Project dir : $(_PROJECT_DIR)"
	@echo ""

.PHONY: _create-dir
_create-dir:
	@echo "→ [1/8] Creating project directory"
	@mkdir -p "$(_PROJECT_DIR)"

.PHONY: _warden-init
_warden-init:
	@echo "→ [2/8] Initialising Warden environment"
	@cd "$(_PROJECT_DIR)" && warden env-init "$(_ENV_NAME)" magento2
	@# Patch the PHP version that warden wrote into .env
	@sed -i.bak "s/^PHP_VERSION=.*/PHP_VERSION=$(PHP_VERSION)/" "$(_PROJECT_DIR)/.env"
	@rm -f "$(_PROJECT_DIR)/.env.bak"
	@echo "→       Signing TLS certificate for $(_CERT_DOMAIN)"
	@warden sign-certificate "$(_CERT_DOMAIN)"

.PHONY: _warden-up
_warden-up:
	@echo "→ [3/8] Starting Warden environment"
	@cd "$(_PROJECT_DIR)" && warden env up
	@echo "→       Waiting 10 seconds for Mutagen sync to initialise..."
	@sleep 10

.PHONY: _composer-install
_composer-install:
	@echo "→ [4/8] Installing Magento $(_M2_VERSION) via Composer (this may take several minutes)"
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm rm -rf /tmp/m2
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm composer create-project \
		--repository-url=https://repo.magento.com/ \
		magento/project-community-edition=$(_M2_VERSION) \
		/tmp/m2
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm cp -rT /tmp/m2 /var/www/html
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm rm -rf /tmp/m2

.PHONY: _magento-install
_magento-install:
	@echo "→ [5/8] Running Magento setup:install"
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento setup:install \
		--base-url=https://app.$(_ENV_NAME).test \
		--db-host=db \
		--db-name=magento \
		--db-user=magento \
		--db-password=magento \
		--search-engine=opensearch \
		--opensearch-host=opensearch \
		--opensearch-port=9200 \
		--opensearch-index-prefix=magento2 \
		--opensearch-enable-auth=0 \
		--opensearch-timeout=15 \
		--http-cache-hosts=varnish:80 \
		--session-save=redis \
		--session-save-redis-host=redis \
		--session-save-redis-port=6379 \
		--session-save-redis-db=2 \
		--session-save-redis-max-concurrency=20 \
		--cache-backend=redis \
		--cache-backend-redis-server=redis \
		--cache-backend-redis-db=0 \
		--cache-backend-redis-port=6379 \
		--page-cache=redis \
		--page-cache-redis-server=redis \
		--page-cache-redis-db=1 \
		--page-cache-redis-port=6379 \
		--admin-firstname=CustomGento \
		--admin-lastname=Support \
		--admin-email=info@customgento.com \
		--admin-user=admin \
		--admin-password=password1 \
		--backend-frontname=admin \
		--timezone=Europe/Berlin

.PHONY: _magento-configure
_magento-configure:
	@echo "→ [6/8] Applying environment configuration"
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set --lock-env web/secure/offloader_header X-Forwarded-Proto
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set --lock-env web/secure/use_in_frontend 1
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set --lock-env web/secure/use_in_adminhtml 1
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set --lock-env web/seo/use_rewrites 1
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set --lock-env system/full_page_cache/caching_application 2
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set --lock-env system/full_page_cache/ttl 604800
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set --lock-env catalog/search/enable_eav_indexer 1

.PHONY: _magento-dev-mode
_magento-dev-mode:
	@echo "→ [7/8] Enabling developer mode"
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento deploy:mode:set developer

.PHONY: _magento-disable-extra-modules
_magento-disable-extra-modules:
	@echo "→ [8/8] Disabling extra modules"
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento module:disable Magento_TwoFactorAuth Magento_AdminAdobeImsTwoFactorAuth