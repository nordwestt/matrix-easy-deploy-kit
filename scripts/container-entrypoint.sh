#!/usr/bin/env sh
set -eu

if [ "${1:-}" = "" ]; then
  set -- bash matrix-wizard.sh
fi

exec "$@"
