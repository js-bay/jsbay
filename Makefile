PAWL ?= pawl
CHECKS ?=
PLATFORMS ?=

.PHONY: check format benchmark-interop

# Each pawl dimension runs a hard check; no generated baseline is needed.
check:
	@$(PAWL) measure $(if $(CHECKS),--only "$(CHECKS)")

format:
	bash scripts/quality/format.sh $(PLATFORMS)

.PHONY: test262
test262:
	@bash tests/test262/run.sh --backend $(or $(BACKEND),quickjs_ng)

# Runs a public C-ABI benchmark by default.  RUNNER selects an SDK runner. The runner writes its build products under a temporary directory, never zig-out.
benchmark-interop:
	@bash bench/interop/run.sh $(RUNNER)
