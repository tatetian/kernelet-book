# Short-cuts for working on the book. Run from the repository root.

MDBOOK ?= mdbook
PYTHON ?= python3
XREF    = $(PYTHON) tools/xref.py

.PHONY: all build serve check renumber render install_browser clean

all: check build          ## check the cross-references, then build the HTML (default)

build:                    ## build the HTML into book/
	$(MDBOOK) build

serve:                    ## live preview with reload
	$(MDBOOK) serve --hostname 0.0.0.0

check:                    ## links resolve, no bare §, no orphan or missing chapter
	$(XREF) check

renumber:                 ## rewrite every § link text from SUMMARY.md order
	$(XREF) renumber

assets/mermaid.min.js assets/mermaid-init.js:
	@cd assets && cargo --locked install mdbook-mermaid@0.17.0

render: build             ## screenshot book/$(PAGE) and check its Mermaid blocks rendered; fetches a browser on first use
	tools/render.sh $(PAGE) $(OUT)

install_browser:          ## fetch a headless Chrome into .cache/ ahead of time (render does this on demand)
	tools/render.sh --install

clean:                    ## remove the built HTML
	$(MDBOOK) clean
	rm -rf tools/__pycache__ .cache/render
