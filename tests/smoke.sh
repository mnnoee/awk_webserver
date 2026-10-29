#!/bin/sh
# Small live smoke test: config, listing, Date, header-injection reject.
# Creates a temporary document root, so the repository can stay content-free.

set -eu
cd "$(dirname "$0")/.."

./run.sh --check-config >/dev/null

ROOT=$(mktemp -d)
mkdir -p "$ROOT/files"
printf 'smoke about\n' > "$ROOT/about.txt"
printf 'smoke notes\n' > "$ROOT/files/notes.txt"

PORT=$((20000 + ($$ % 20000)))
LOG=$(mktemp)
BODY=$(mktemp)
./run.sh --port "$PORT" --root "$ROOT" >"$LOG" 2>&1 &
PID=$!
cleanup() {
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    rm -f "$LOG" "$BODY"
    rm -rf "$ROOT"
}
trap cleanup EXIT

i=0
while [ "$i" -lt 30 ]; do
    if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/files/" >"$BODY" 2>/dev/null; then
        break
    fi
    i=$((i + 1))
    sleep 0.1
done

grep -q 'notes.txt' "$BODY" || {
    echo "listing test failed" >&2
    cat "$BODY" >&2 || true
    exit 1
}

curl -sI --max-time 2 "http://127.0.0.1:$PORT/about.txt" | tr -d '\r' | grep -qi '^Date:'

expect400() {
    resp=$(printf '%b' "$1" | nc -w 2 127.0.0.1 "$PORT" 2>/dev/null || true)
    printf '%s' "$resp" | grep -q '400 Bad Request' || {
        echo "expected 400 for: $1" >&2
        printf '%s\n' "$resp" >&2
        exit 1
    }
}

expect400 'GET /about.txt HTTP/1.1\r\nHost: x\r\nX-Foo: a\rInject: evil\r\n\r\n'
expect400 'GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n'
expect400 'GET / HTTP/1.1\r\nHost: evil.com/path\r\n\r\n'
expect400 'GET /sub?x=\rInjected: 1 HTTP/1.1\r\nHost: x\r\n\r\n'
expect400 'GET /about.txt%00x HTTP/1.1\r\nHost: x\r\n\r\n'

echo "smoke: OK"

# ---------------------------------------------------------------------------
# Copyright (C) 2026 awk_web_server contributors
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
# Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program. If not, see <https://www.gnu.org/licenses/>.
# ---------------------------------------------------------------------------
