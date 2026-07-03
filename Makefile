# ramgate Makefile -- the zero-config front door. ONE job: get you to `just`.
#
#   make            first run: install just + every dep, live splash, hand over
#                   to just. Later runs: deps already present, so it's instant.
#   make <target>   sugar for `just <target>` -- goals forwarded verbatim, once.
#
# ramgate has NO compiler (pure GNU Bash, macOS-only): the build/test targets
# below delegate to the Justfile's build-less recipes (check = bash -n, etc.).
# The install target is LOCAL to $HOME (~/.local/bin symlinks) -- never root.
# Everything real lives in the Justfile + .just/helpers/. This is a
# bootstrapper, not a build system.
.POSIX:

# bare `make`: bootstrap (ensure just + deps), then hand over to just.
all: ; @.just/helpers/bootstrap.bash

# `make <target...>` -> `just <target...>`: the first goal carries the whole
# list to a single `just` invocation; the remaining goals become no-ops so the
# command runs EXACTLY once. A plain `.DEFAULT` rule would re-run `just <goals>`
# once PER goal (GNU make fires .DEFAULT for every unmatched target) -- so
# `make ci check` would run the pair twice (house-style gotcha #25).
ifneq ($(MAKECMDGOALS),)
$(firstword $(MAKECMDGOALS)): ; @just $(MAKECMDGOALS)
$(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS)): ; @:
endif
