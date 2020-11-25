SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euc
.DELETE_ON_ERROR:
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

version: upgrade clean compile check test edoc
.PHONY: version

shell:
	@rebar3 shell
.PHONY: shell

upgrade: upgrade-rebar3_lint
.PHONY: upgrade

upgrade-rebar3_lint:
	@rebar3 plugins upgrade rebar3_lint
.PHONY: upgrade-rebar3_lint

clean:
	@rebar3 clean -a
.PHONY: clean

compile:
	@rebar3 compile
.PHONY: compile

check: xref dialyzer elvis-rock
.PHONY: check

xref:
	@rebar3 as test xref
.PHONY: xref

dialyzer:
	@rebar3 as test dialyzer
.PHONY: dialyzer

elvis-rock:
	@rebar3 lint
.PHONY: elvis-rock

test: eunit ct cover
.PHONY: test

eunit:
	@rebar3 eunit
.PHONY: eunit

ct:
	@rebar3 ct
.PHONY: ct

cover:
	@rebar3 cover
.PHONY: cover

edoc:
	@rebar3 edoc
.PHONY: edoc
