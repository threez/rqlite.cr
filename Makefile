.PHONY: all clean fmt fmtcheck lint fix docs spec rqlited e2e version tag

RQLITE_URL ?= http://localhost:4001

all: clean fmt lint docs spec

fmt:
	crystal tool format

fmtcheck:
	crystal tool format --check

spec:
	crystal spec -v

lib/ameba/bin/ameba:
	shards install
	crystal build lib/ameba/src/cli.cr -o lib/ameba/bin/ameba

lint: lib/ameba/bin/ameba
	lib/ameba/bin/ameba

fix: lib/ameba/bin/ameba
	lib/ameba/bin/ameba --fix

docs:
	crystal docs

clean:
	rm -rf docs/

# Start a single-node rqlite instance with a project-local data dir
# (foreground; Ctrl-C to stop). Listens on :4001 by default.
rqlited:
	mkdir -p tmp/rqlite-node1
	rqlited -node-id=1 tmp/rqlite-node1

# Run HTTP e2e tests against a live rqlited node
e2e:
	RQLITE_URL=$(RQLITE_URL) crystal spec spec/connection_http_spec.cr -v

# Sync the VERSION constant in src/ to match shard.yml's version field.
# Bump shard.yml's version first, then run `make version`.
version:
	@V=$$(grep '^version:' shard.yml | sed -E 's/^version:[[:space:]]*//'); \
	for f in $$(grep -rl '^[[:space:]]*VERSION[[:space:]]*=[[:space:]]*"[^"]*"' src/ 2>/dev/null); do \
		sed -E "s/^([[:space:]]*VERSION[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\\1\"$$V\"/" "$$f" > "$$f.tmp" && mv "$$f.tmp" "$$f"; \
		echo "updated $$f to $$V"; \
	done

# Create an annotated git tag "vX.Y.Z" from shard.yml's version field.
tag:
	@V=$$(grep '^version:' shard.yml | sed -E 's/^version:[[:space:]]*//'); \
	git tag -a "v$$V" -m "Release v$$V"; \
	echo "tagged v$$V"
