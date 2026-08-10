#!/bin/bash
# Auto-detected quality gate — run before committing. Exits 0 if no stack matched.
set -e
if [ -f pubspec.yaml ]; then
    grep -q flutter pubspec.yaml && flutter analyze || dart analyze
elif [ -f package.json ]; then
    if grep -q '"lint"' package.json; then npm run -s lint
    elif [ -f tsconfig.json ]; then npx --yes tsc --noEmit
    else echo "no linter configured"; fi
elif [ -f Cargo.toml ]; then cargo clippy -q -- -D warnings
elif [ -f go.mod ]; then go vet ./...
elif [ -f pyproject.toml ] || [ -f setup.py ]; then
    command -v ruff >/dev/null && ruff check . || python3 -m compileall -q .
else echo "no known stack — add your project's checks to .claude/quality-check.sh"; fi
