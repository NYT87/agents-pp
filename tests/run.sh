#!/usr/bin/env bash
# Run the test suite, plus shellcheck when it is installed.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RC=0
if command -v shellcheck > /dev/null 2>&1; then
  echo "== shellcheck"
  shellcheck -x "$HERE"/../plugins/review-loop/skills/review-loop/scripts/*.sh \
    "$HERE"/../plugins/review-loop/skills/review-loop/scripts/backends/*.sh "$HERE"/*.sh || RC=1
else
  echo "== shellcheck not installed, skipping (brew install shellcheck)"
fi
echo "== tests"
bash "$HERE/test_loop.sh" || RC=1
exit $RC
