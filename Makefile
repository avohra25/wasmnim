NIM ?= nim
FLAGS ?= -d:release --hints:off --warnings:off
TESTS := $(wildcard tests/test_*.nim)

.PHONY: test build clean

test:
	@set -e; for t in $(TESTS); do echo "== $$t"; $(NIM) c -r $(FLAGS) $$t; done

build:
	@mkdir -p bin
	$(NIM) c $(FLAGS) -o:bin/wasmnim src/wasmnim.nim

clean:
	rm -rf bin nimcache $(basename $(TESTS))
