LINT=ruff

.PHONY: lint test

lint:
	$(LINT) check src tests

test:
	PYTHONPATH=src pytest -q