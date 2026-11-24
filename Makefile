.PHONY: all highlight pdf clean test
all: pdf
highlight:
	python3 scripts/extract-capstone.py
	python3 scripts/highlight.py
pdf: highlight
	latexmk -pdf -interaction=nonstopmode -halt-on-error -file-line-error guide.tex
clean:
	latexmk -C guide.tex
test:
	./run-tests.sh

.PHONY: tidy tidy-check tidy-rebuild
tidy:
	python3 scripts/tidy-perl.py
tidy-check:
	python3 scripts/tidy-perl.py --check
tidy-rebuild: tidy
	$(MAKE) tidy-check
	$(MAKE) test
	$(MAKE) pdf
