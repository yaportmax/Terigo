#!/bin/zsh
set -euo pipefail

ROOT="/Users/myaport/Documents/test-repo/dev2"
DENO_BIN="${DENO_BIN:-$HOME/.deno/bin/deno}"

if [[ ! -x "$DENO_BIN" ]]; then
  if command -v deno >/dev/null 2>&1; then
    DENO_BIN="$(command -v deno)"
  else
    echo "Deno is not installed. Install it first, then rerun this script." >&2
    exit 1
  fi
fi

set -a
source "$ROOT/.env"
set +a

exec "$DENO_BIN" run \
  --allow-net \
  --allow-env \
  --allow-read \
  --allow-write \
  "$ROOT/supabase/local-functions-server.ts"
