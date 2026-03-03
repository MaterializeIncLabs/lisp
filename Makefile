.PHONY: test setup

setup:
	uv sync --dev

test:
	uv run pytest tests/ -v
