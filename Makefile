NVIM ?= nvim
DEPS_DIR ?= .deps
CODECOMPANION_REF ?= main

export DEPS_DIR

.PHONY: test e2e e2e-errors deps

deps:
	@mkdir -p $(DEPS_DIR)
	@test -d $(DEPS_DIR)/plenary.nvim || git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(DEPS_DIR)/plenary.nvim
	@test -d $(DEPS_DIR)/codecompanion.nvim || git clone https://github.com/olimorris/codecompanion.nvim $(DEPS_DIR)/codecompanion.nvim
	@git -C $(DEPS_DIR)/codecompanion.nvim checkout -q $(CODECOMPANION_REF)

test: deps
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests { minimal_init = 'tests/minimal_init.lua', sequential = true }"

e2e: deps
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -l scripts/e2e.lua

e2e-errors: deps
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -l scripts/e2e_errors.lua
