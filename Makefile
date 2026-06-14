WORKSPACE := workspace

REPOS := \
	git@github.com:unowned-22/api.git \
	git@github.com:unowned-22/panel.git

.PHONY: help init clone pull up down restart api-ssh

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "%-25s %s\n", $$1, $$2}'

init: clone up ## Clone repositories and start containers

restart: down up ## Restart all containers

clone: ## Clone repositories
	@mkdir -p $(WORKSPACE)
	@for repo in $(REPOS); do \
		name=$$(basename $$repo .git); \
		if [ ! -d "$(WORKSPACE)/$$name" ]; then \
			echo "Cloning $$name..."; \
			git clone $$repo $(WORKSPACE)/$$name; \
		else \
			echo "$$name already exists"; \
		fi; \
	done

pull: ## Pull latest changes
	@for dir in $(WORKSPACE)/*; do \
		if [ -d "$$dir/.git" ]; then \
			echo "Updating $$(basename $$dir)"; \
			git -C $$dir pull; \
		fi; \
	done

up: ## Start docker containers
	docker compose up -d

down: ## Stop docker containers
	docker compose down

api-ssh: ## Open shell inside api container
	docker compose exec -it api sh
