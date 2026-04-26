#!/bin/bash
# Runs live tests (requires kask, midway, cmux)

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

PASS=0 FAIL=0
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== Running tests ==="
for t in tests/test-hook-injection.sh tests/test-cr-detection.sh tests/test-titler.sh tests/test-notifier.sh; do
    if [ -f "$t" ]; then
        echo ""
        if bash "$t"; then
            echo -e "${GREEN}✓${NC} $t"
            ((PASS++)) || true
        else
            echo -e "${RED}✗${NC} $t"
            ((FAIL++)) || true
        fi
    fi
done

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1
