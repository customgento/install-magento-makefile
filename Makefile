.DEFAULT_GOAL := help
SHELL         := /bin/bash -o pipefail

# PHP version to use inside the Warden container.
# Extend this later to pick automatically based on Magento version.
PHP_VERSION ?= 8.3

# Set to "true" to install Magento sample data (Luma catalog) after installation.
SAMPLE_DATA ?= false

# Set to "true" to install the open-source Hyvä theme and make it the active theme.
HYVA_THEME ?= false

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
	@printf "  SAMPLE_DATA=%-6s  Install Magento sample data (default: false)\n" "$(SAMPLE_DATA)"
	@printf "  HYVA_THEME=%-7s  Install and activate the Hyvä theme (default: false)\n" "$(HYVA_THEME)"

.PHONY: create-magento
create-magento: _validate _create-dir _warden-init _warden-up _composer-install _magento-install _magento-configure _magento-dev-mode _magento-disable-extra-modules _magento-sample-data _magento-hyva-theme
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
	@echo "→ [1/10] Creating project directory"
	@mkdir -p "$(_PROJECT_DIR)"

.PHONY: _warden-init
_warden-init:
	@echo "→ [2/10] Initialising Warden environment"
	@cd "$(_PROJECT_DIR)" && warden env-init "$(_ENV_NAME)" magento2
	@# Patch the PHP version that warden wrote into .env
	@sed -i.bak "s/^PHP_VERSION=.*/PHP_VERSION=$(PHP_VERSION)/" "$(_PROJECT_DIR)/.env"
	@rm -f "$(_PROJECT_DIR)/.env.bak"
	@echo "→       Signing TLS certificate for $(_CERT_DOMAIN)"
	@warden sign-certificate "$(_CERT_DOMAIN)"
	@# warden sign-certificate skips its own Traefik reload (its docker compose check runs
	@# without WARDEN_DOCKER_SOCK and fails silently), so load the new certificate explicitly.
	@echo "→       Loading certificate into Traefik"
	@warden svc up traefik
	@warden svc restart traefik

.PHONY: _warden-up
_warden-up:
	@echo "→ [3/10] Starting Warden environment"
	@cd "$(_PROJECT_DIR)" && warden env up
	@echo "→       Waiting 10 seconds for Mutagen sync to initialise..."
	@sleep 10

.PHONY: _composer-install
_composer-install:
	@echo "→ [4/10] Installing Magento $(_M2_VERSION) via Composer (this may take several minutes)"
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm rm -rf /tmp/m2
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm composer create-project \
		--repository-url=https://repo.magento.com/ \
		magento/project-community-edition=$(_M2_VERSION) \
		/tmp/m2
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm cp -rT /tmp/m2 /var/www/html
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm rm -rf /tmp/m2

.PHONY: _magento-install
_magento-install:
	@echo "→ [5/10] Running Magento setup:install"
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
	@echo "→ [6/10] Applying environment configuration"
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set --lock-env web/secure/offloader_header X-Forwarded-Proto
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set --lock-env web/secure/use_in_frontend 1
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set --lock-env web/secure/use_in_adminhtml 1
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set --lock-env web/seo/use_rewrites 1
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set --lock-env system/full_page_cache/caching_application 2
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set --lock-env system/full_page_cache/ttl 604800
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set --lock-env catalog/search/enable_eav_indexer 1

.PHONY: _magento-dev-mode
_magento-dev-mode:
	@echo "→ [7/10] Enabling developer mode"
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento deploy:mode:set developer

.PHONY: _magento-disable-extra-modules
_magento-disable-extra-modules:
	@echo "→ [8/10] Disabling extra modules"
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento module:disable Magento_TwoFactorAuth Magento_AdminAdobeImsTwoFactorAuth

.PHONY: _magento-sample-data
_magento-sample-data:
ifeq ($(SAMPLE_DATA),true)
	@echo "→ [9/10] Installing sample data (this may take several minutes)"
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento sampledata:deploy
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento setup:upgrade
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento indexer:reindex
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento cache:flush
else
	@echo "→ [9/10] Skipping sample data (pass SAMPLE_DATA=true to install it)"
endif

# Hyvä's documented keyless install route: packages come from GitHub as "git" repositories
# (plain clones, not the GitHub API, so no rate limit and no Hyvä account key needed).
# See https://github.com/hyva-themes/magento2-default-theme#installation
_HYVA_REPOS := magento2-theme-module magento2-default-theme magento2-default-theme-csp \
	magento2-base-layout-reset magento2-compat-module-fallback magento2-mollie-theme-bundle \
	magento2-luma-checkout magento2-theme-fallback magento2-order-cancellation-webapi magento2-email-module

.PHONY: _magento-hyva-theme
_magento-hyva-theme:
ifeq ($(HYVA_THEME),true)
	@echo "→ [10/10] Installing Hyvä theme (this may take several minutes)"
	@cd "$(_PROJECT_DIR)" && for repo in $(_HYVA_REPOS); do \
		warden env exec -T php-fpm composer config repositories.hyva-themes/$$repo git https://github.com/hyva-themes/$$repo.git; \
	done
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm composer require hyva-themes/magento2-default-theme
	@# setup:upgrade also registers the new theme in the "theme" table (Magento_Theme recurring data)
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento setup:upgrade
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set customer/captcha/enable 0
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento config:set design/theme/theme_id \
		"$$(warden env exec -T db mysql -umagento -pmagento magento -sNe "SELECT theme_id FROM theme WHERE theme_path = 'Hyva/default'" 2>/dev/null)"
	@cd "$(_PROJECT_DIR)" && warden env exec -T php-fpm bin/magento cache:flush
else
	@echo "→ [10/10] Skipping Hyvä theme (pass HYVA_THEME=true to install it)"
endif
