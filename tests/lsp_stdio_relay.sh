#!/usr/bin/env bash
set -eu

base=$(mktemp -d "${TMPDIR:-/tmp}/ipynb-lsp-relay.XXXXXX")
in_fifo="$base/in"
out_fifo="$base/out"
mkfifo "$in_fifo" "$out_fifo"

cleanup() {
  rm -f "$in_fifo" "$out_fifo"
  rmdir "$base"
}

trap cleanup EXIT

cat <&0 > "$in_fifo" &
cat "$out_fifo" >&1 &

exec "$@" < "$in_fifo" > "$out_fifo"
