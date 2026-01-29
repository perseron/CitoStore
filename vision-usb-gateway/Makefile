LINT=ruff

.PHONY: lint test test-functional

lint:
	$(LINT) check src tests

test:
	PYTHONPATH=src pytest -q

test-functional:
	sudo ./tests/functional/server/vision-functional.sh
