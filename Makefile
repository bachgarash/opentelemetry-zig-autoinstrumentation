# Build and inspect the instrumentation targets.
#
# Recipes use ">" instead of a leading tab (GNU make >= 3.82).

.RECIPEPREFIX = >
.DEFAULT_GOAL := debug

ZIG     ?= zig
OUT     ?= zig-out
SRC     ?= examples/http-minimal.zig
NAME    := http-minimal
PORT    ?= 8080
# Function to inspect in the syms/dwarf targets.
FUNC    ?= handleRequest

# Build mode -> output binary
MODES   := Debug ReleaseSafe ReleaseFast ReleaseSmall
BINS    := $(foreach m,$(MODES),$(OUT)/$(NAME)-$(m))

.PHONY: debug safe fast small all run syms dwarf modes clean help

debug: $(OUT)/$(NAME)-Debug
safe:  $(OUT)/$(NAME)-ReleaseSafe
fast:  $(OUT)/$(NAME)-ReleaseFast
small: $(OUT)/$(NAME)-ReleaseSmall

## all: build every optimisation mode side by side
all: $(BINS)

$(OUT)/$(NAME)-%: $(SRC) | $(OUT)
> $(ZIG) build-exe -O $* -femit-bin=$@ $<

$(OUT):
> mkdir -p $(OUT)

## run: build Debug and serve on $(PORT)
run: debug
> $(OUT)/$(NAME)-Debug

## syms: where $(FUNC) lives in each mode, and whether it survived at all
syms: all
> @for b in $(BINS); do \
>   echo "== $$b"; \
>   nm $$b | grep -i '$(FUNC)' || echo "   (no symbol matching $(FUNC))"; \
> done

## dwarf: the DWARF entry for $(FUNC) in the Debug build
dwarf: debug
> readelf --debug-dump=info $(OUT)/$(NAME)-Debug | grep -A 30 '$(FUNC)' | head -60

## modes: size of each build, for comparison
modes: all
> @ls -l $(BINS) | awk '{ printf "%-40s %10d bytes\n", $$9, $$5 }'

clean:
> rm -rf $(OUT) .zig-cache

help:
> @grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
