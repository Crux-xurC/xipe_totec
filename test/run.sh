#!/usr/bin/env bash
# test/run.sh -- ExUnit for Xipe Totec's pure logic.
#
# Not a mix project (main.exs + Code.require_file, the same convention as
# tezcatl), so each test/*_test.exs is a standalone `elixir` script: it
# starts ExUnit, pulls in the module(s) under test with Code.require_file,
# and ExUnit's at_exit hook runs the cases and sets the exit status.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.."

shopt -s nullglob
files=(test/*_test.exs)
if [ ${#files[@]} -eq 0 ]; then
  echo "run.sh: no test/*_test.exs found" >&2
  exit 1
fi

# LSP scanning off: a tezcatl /lsp relay running on this machine must not
# change what the suite sees (Scanner.Lsp's own tests use a fake transport)
export XIPE_TOTEC_LSP=off

status=0
for f in "${files[@]}"; do
  echo "=== $f ==="
  elixir "$f" || status=1
done

exit "$status"
