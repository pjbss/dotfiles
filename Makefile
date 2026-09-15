# Makefile
#
# The one entrypoint every automated gate in this repo calls. `make test` is
# deliberately the contract rather than a repo-specific runner path: the Claude
# Code Stop hook and the autonomous issue loop (bin/pj-run-issues) shell out to
# it, so the same machinery works against any project that honors the target.
#
# The real logic lives in test/run.sh and test/lint.sh -- these targets are thin
# wrappers, so the scripts stay runnable directly (and testable) without make.

.DEFAULT_GOAL := help
.PHONY: help test lint install sync

help: ## Show this help
	@grep -E '^[a-z][a-zA-Z0-9_-]*:.*## ' $(MAKEFILE_LIST) | \
		awk -F':.*## ' '{ printf "  %-10s %s\n", $$1, $$2 }'

test: ## Run every *_test.sh (optionally: make test PATTERN=ssh)
	@test/run.sh $(PATTERN)

lint: ## Syntax-check every shell source (plus shellcheck, if installed)
	@test/lint.sh

install: ## Symlink the dotfiles into $HOME and render agent skills
	@./install.sh

sync: ## Re-render agent skills/subagents/hooks without a full install
	@bin/dotfiles-sync-agents
