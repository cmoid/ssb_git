.PHONY: compile test checkout clean elisp
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

## Build against a local erlbutt checkout instead of the pinned branch.
checkout:
	@mkdir -p _checkouts
	ln -sfn $(ERLBUTT)/apps/ssb _checkouts/ssb
	@echo "_checkouts/ssb -> $(ERLBUTT)/apps/ssb"

clean:
	$(REBAR) clean
