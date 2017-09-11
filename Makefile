CORE = rel/epoch/bin/epoch
VER = 0.1.0


local-build: KIND=local
local-build: config/sys.config internal-build

local-start: KIND=local
local-start: internal-start

local-stop: KIND=local
local-stop: internal-stop

local-attach: KIND=local
local-attach: internal-attach

prod-build: KIND=prod
prod-build: config/sys.config internal-build

prod-start: KIND=prod
prod-start: internal-start

prod-stop: KIND=prod
prod-stop: internal-stop

prod-attach: KIND=prod
prod-attach: internal-attach

multi-start:
	@make dev1-start
	@make dev2-start
	@make dev3-start

multi-stop:
	@make dev1-stop
	@make dev2-stop
	@make dev3-stop

multi-clean:
	@make dev1-clean
	@make dev2-clean
	@make dev3-clean

dev1-build: KIND=dev1
dev1-build: internal-build

dev1-start: KIND=dev1
dev1-start: internal-start

dev1-stop: KIND=dev1
dev1-stop: internal-stop

dev1-attach: KIND=dev1
dev1-attach: internal-attach

dev1-clean: KIND=dev1
dev1-clean: internal-clean

dev2-start: KIND=dev2
dev2-start: internal-start

dev2-stop: KIND=dev2
dev2-stop: internal-stop

dev2-attach: KIND=dev2
dev2-attach: internal-attach

dev2-clean: KIND=dev2
dev2-clean: internal-clean

dev3-start: KIND=dev3
dev3-start: internal-start

dev3-stop: KIND=dev3
dev3-stop: internal-stop

dev3-attach: KIND=dev3
dev3-attach: internal-attach

dev3-clean: KIND=dev3
dev3-clean: internal-clean

dialyzer:
	@./rebar3 dialyzer

test:
	@./rebar3 do eunit,ct


kill:
	@echo "Kill all beam processes only from this directory tree"
	$(shell pkill -9 -f ".*/beam.*-boot `pwd`" || true)

killall:
	@echo "Kill all beam processes from this host"
	@pkill -9 beam || true

clean:
	@./rebar3 clean

multi-build: config/dev1/sys.config config/dev2/sys.config config/dev3/sys.config dev1-build 
	@rm -rf _build/dev2 _build/dev3
	@for x in dev2 dev3; do \
		cp -R _build/dev1 _build/$$x; \
		cp config/$$x/sys.config _build/$$x/rel/epoch/releases/$(VER)/sys.config; \
		cp config/$$x/vm.args _build/$$x/rel/epoch/releases/$(VER)/vm.args; \
	done


config/dev1/sys.config: config/sys.config.tmpl
	sed -e "\
	s:%% comment:\
	%% dev1 conf\
	:\
    " $< > $@

config/dev2/sys.config: config/sys.config.tmpl
	sed -e "\
	s:%% comment:\
	%% dev2 conf\
	:\
    " $< > $@

config/dev3/sys.config: config/sys.config.tmpl
	sed -e "\
	s:%% comment:\
	%% dev3 conf\
	:\
    " $< > $@

config/sys.config: config/sys.config.tmpl
	sed -e "\
	s:%% comment:\
	%% conf\
	:\
	" $< > $@

#
# Build rules
#

.SECONDEXPANSION:

internal-build: $$(KIND)
	@./rebar3 as $(KIND) release

internal-start: $$(KIND)
	@./_build/$(KIND)/$(CORE) start

internal-stop: $$(KIND)
	@./_build/$(KIND)/$(CORE) stop

internal-attach: $$(KIND)
	@./_build/$(KIND)/$(CORE) attach
	
internal-clean: $$(KIND)
	@rm -rf ./_build/$(KIND)/rel/epoch/data/*
	@rm -rf ./_build/$(KIND)/rel/epoch/blocks/*
	@rm -rf ./config/$(KIND)/sys.config
	@rm -rf ./_build/$(KIND)/rel/*/log/*



.PHONY: \
	local-build local-start local-stop local-attach \
	prod-build prod-start prod-stop prod-attach \
	multi-build, multi-start, multi-stop, multi-clean \
	dev1-start, dev1-stop, dev1-attach, dev1-clean \
	dev2-start, dev2-stop, dev2-attach, dev2-clean \
	dev3-start, dev3-stop, dev3-attach, dev3-clean \
	dialyzer \
	test \
	kill killall \
