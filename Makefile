WORKSPACE := workspace

REPOS := \
	git@github.com:unowned-22/api.git \
	git@github.com:unowned-22/panel.git

.PHONY: init clone pull up down restart api-ssh

init: clone up

restart: down up

clone:
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

pull:
	@for dir in $(WORKSPACE)/*; do \
		if [ -d "$$dir/.git" ]; then \
			echo "Updating $$(basename $$dir)"; \
			git -C $$dir pull; \
		fi; \
	done

up:
	docker compose up -d

down:
	docker compose down

api-ssh:
	docker compose exec -it api sh
