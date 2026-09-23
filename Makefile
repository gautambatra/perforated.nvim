NVIM      ?= nvim
DEPS      := .deps
P4_REL    ?= r25.2
UNAME_S   := $(shell uname -s)
UNAME_M   := $(shell uname -m)

ifeq ($(UNAME_S),Darwin)
  P4_PLAT := bin.macosx12arm64
else
  P4_PLAT := bin.linux26x86_64
endif
P4_URL := https://cdist2.perforce.com/perforce/$(P4_REL)/$(P4_PLAT)

.PHONY: test bench deps lint fmt clean dev-workspace

deps: $(DEPS)/mini.nvim $(DEPS)/p4bin/p4 $(DEPS)/p4bin/p4d

$(DEPS)/mini.nvim:
	git clone --depth 1 https://github.com/nvim-mini/mini.nvim $@

$(DEPS)/p4bin/%:
	mkdir -p $(DEPS)/p4bin
	curl -fsSL -o $@ $(P4_URL)/$*
	chmod +x $@

# Run the whole suite, or one file: make test FILE=tests/test_parse.lua
test: deps
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua require('tests.run')('$(FILE)')"

bench: deps
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "luafile bench/run.lua"

STYLUA ?= $(shell command -v stylua || echo $(DEPS)/stylua)
SELENE ?= $(shell command -v selene || echo $(DEPS)/selene)

lint:
	$(STYLUA) --check lua plugin tests bench
	$(SELENE) lua plugin

fmt:
	$(STYLUA) lua plugin tests bench

# Persistent local Perforce sandbox in .dev/ (gitignored) for trying the plugin by hand.
dev-workspace: deps
	scripts/dev-workspace.sh

clean:
	rm -rf $(DEPS)
