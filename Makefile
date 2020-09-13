REBAR = $(shell pwd)/rebar3
COVERPATH = ./_build/test/cover

.PHONY: compile-no-deps test docs xref dialyzer \

all: compile

compile:
	${REBAR} compile

clean:
	${REBAR} clean

lint:
	${REBAR} as lint lint

test: compile
	${REBAR} eunit

proper:
	${REBAR} proper -n 1000

format:
	${REBAR} format

coverage: compile
	cp _build/proper+test/cover/eunit.coverdata ${COVERPATH}/proper.coverdata ;\
	${REBAR} cover --verbose

shell:
	${REBAR} shell --apps antidote_crdt

docs:
	${REBAR} doc

xref: compile
	${REBAR} xref

dialyzer: compile
	${REBAR} dialyzer

typer:
	typer --annotate -I ../ --plt $(PLT) -r src
