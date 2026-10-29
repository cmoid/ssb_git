.PHONY: compile test checkout clean elisp plugin info info_install
## erlbutt vendors rebar3; use that one unless told otherwise.
ERLBUTT ?= $(HOME)/code/erlbutt
REBAR   ?= $(ERLBUTT)/rebar3

compile:
	$(REBAR) compile

test:
	$(REBAR) eunit

## Byte-compile elisp/ to check it (the .elc is not kept: Emacs compiles
## it where it is installed).  Needs maxbutt's elisp and markdown-mode.
MAXBUTT      ?= $(HOME)/code/maxbutt
MARKDOWN_DIR ?= $(firstword $(wildcard $(HOME)/.emacs.d/elpa/markdown-mode-*))
ERLANG_EMACS := $(shell erl -noshell -eval 'io:format("~s/emacs",[code:lib_dir(tools)])' -s init stop 2>/dev/null)

elisp:
	emacs -Q --batch -L "$(ERLANG_EMACS)" -L "$(MAXBUTT)/elisp" -L "$(MARKDOWN_DIR)" \
	    --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile elisp/*.el
	rm -f elisp/*.elc

## The Emacs manual, for C-h i.  info_install puts it where maxbutt's goes,
## e.g. `make info_install prefix=/usr/local/share/emacs/site-lisp`; a
## copy also ships in the plugin's info/, which ssb-git.el adds to Info's
## path when it loads.
prefix  ?= $(HOME)/.emacs.d
infodir  = $(prefix)/info

info: doc/ssb-git.info

doc/ssb-git.info: doc/ssb-git.texi
	makeinfo -o $@ $<

info_install: info
	install -m 755 -d $(infodir)
	cp doc/ssb-git.info $(infodir)
	install-info --info-dir=$(infodir) --section Emacs $(infodir)/ssb-git.info

## Build against a local erlbutt checkout instead of the pinned branch.
checkout:
	@mkdir -p _checkouts
	ln -sfn $(ERLBUTT)/apps/ssb _checkouts/ssb
	@echo "_checkouts/ssb -> $(ERLBUTT)/apps/ssb"

## A drop-in copy of the plugin, built against $(ERLBUTT): _build/plugin/ssb_git/
## holds ebin/, bin/ and elisp/, ready to copy to <data>/plugins/ on a node
## running that erlbutt (it refuses to start on a different plugin API).
PLUGIN_DIR = _build/plugin/ssb_git

plugin: checkout compile info
	rm -rf $(PLUGIN_DIR)
	mkdir -p $(PLUGIN_DIR)/elisp $(PLUGIN_DIR)/info
	cp -RL _build/default/lib/ssb_git/ebin $(PLUGIN_DIR)/ebin
	cp -R bin $(PLUGIN_DIR)/bin
	cp elisp/*.el $(PLUGIN_DIR)/elisp/
	cp doc/ssb-git.info $(PLUGIN_DIR)/info/
	install-info --info-dir=$(PLUGIN_DIR)/info $(PLUGIN_DIR)/info/ssb-git.info
	@echo "$(PLUGIN_DIR): copy it to <data>/plugins/ and restart the node"

clean:
	$(REBAR) clean
	rm -f doc/ssb-git.info
