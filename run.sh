#!/bin/sh
# Run the gawk web server.
#
#   ./run.sh
#   ./run.sh --check-config
#   ./run.sh --config server.conf --port 9090 --root ./public
#   ./run.sh 9090 ./public          # old positional form
#
# Priority: built-in defaults < server.conf < AWKWS_* environment < CLI.
# gawk always binds 0.0.0.0; server.host is advisory.

set -eu

cd "$(dirname "$0")"

usage() {
    cat <<'EOF'
Usage: ./run.sh [options] [PORT] [ROOT]

Options:
  --config FILE          config file (default: server.conf, if present)
  --check-config         validate config and exit without binding
  --port N               TCP port
  --host ADDR            advisory bind address (gawk binds 0.0.0.0)
  --root DIR             document root
  --index LIST           comma-separated index files
  --autoindex on|off     directory listing
  --cgi on|off           enable CGI
  --proxy on|off         enable reverse proxy
  --access-log FILE      access log ("-" = stderr)
  --error-log FILE       error log ("-" = stderr)
  --read-timeout MS      per-read socket timeout, 0 disables
  --body-read-timeout MS timeout for reading a request body
  --request-timeout SEC  total header-read deadline
  --max-body BYTES       maximum POST body for CGI
  --trust-forwarded on|off trust X-Forwarded-For/X-Real-IP
  -h, --help             this help

TLS is configured in server.conf: [tls] enabled/listen_port/cert/key.
When enabled, run.sh starts socat or stunnel as a TLS front-end.

Environment: AWKWS_PORT, AWKWS_ROOT, AWKWS_HOST, AWKWS_INDEX,
AWKWS_DIRECTORY_LISTING, AWKWS_CGI, AWKWS_PROXY, AWKWS_ACCESS_LOG,
AWKWS_ERROR_LOG, AWKWS_CONFIG. Legacy PORT and ROOT are also accepted.
AWKWS_BODY_READ_TIMEOUT and AWKWS_TRUST_FORWARDED are accepted as well.
EOF
}

CONFIG=""
CHECK=0
PORT=""
ROOT=""
HOST=""
CGI=""
PROXY=""
AUTOINDEX=""
INDEX=""
ACCESS_LOG=""
ERROR_LOG=""
READ_TIMEOUT=""
BODY_READ_TIMEOUT=""
REQUEST_TIMEOUT=""
MAX_BODY=""
TRUST_FORWARDED=""

need_value() {
    if [ "$#" -lt 2 ]; then
        echo "error: $1 requires a value" >&2
        exit 2
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)       need_value "$@"; CONFIG=$2; shift 2 ;;
        --config=*)     CONFIG=${1#*=}; shift ;;
        --check-config) CHECK=1; shift ;;
        --port)         need_value "$@"; PORT=$2; shift 2 ;;
        --port=*)       PORT=${1#*=}; shift ;;
        --host)         need_value "$@"; HOST=$2; shift 2 ;;
        --host=*)       HOST=${1#*=}; shift ;;
        --root)         need_value "$@"; ROOT=$2; shift 2 ;;
        --root=*)       ROOT=${1#*=}; shift ;;
        --index)        need_value "$@"; INDEX=$2; shift 2 ;;
        --index=*)      INDEX=${1#*=}; shift ;;
        --autoindex)    need_value "$@"; AUTOINDEX=$2; shift 2 ;;
        --autoindex=*)  AUTOINDEX=${1#*=}; shift ;;
        --cgi)          need_value "$@"; CGI=$2; shift 2 ;;
        --cgi=*)        CGI=${1#*=}; shift ;;
        --proxy)        need_value "$@"; PROXY=$2; shift 2 ;;
        --proxy=*)      PROXY=${1#*=}; shift ;;
        --access-log)   need_value "$@"; ACCESS_LOG=$2; shift 2 ;;
        --access-log=*) ACCESS_LOG=${1#*=}; shift ;;
        --error-log)    need_value "$@"; ERROR_LOG=$2; shift 2 ;;
        --error-log=*)  ERROR_LOG=${1#*=}; shift ;;
        --read-timeout) need_value "$@"; READ_TIMEOUT=$2; shift 2 ;;
        --read-timeout=*) READ_TIMEOUT=${1#*=}; shift ;;
        --body-read-timeout) need_value "$@"; BODY_READ_TIMEOUT=$2; shift 2 ;;
        --body-read-timeout=*) BODY_READ_TIMEOUT=${1#*=}; shift ;;
        --request-timeout) need_value "$@"; REQUEST_TIMEOUT=$2; shift 2 ;;
        --request-timeout=*) REQUEST_TIMEOUT=${1#*=}; shift ;;
        --max-body)     need_value "$@"; MAX_BODY=$2; shift 2 ;;
        --max-body=*)   MAX_BODY=${1#*=}; shift ;;
        --trust-forwarded) need_value "$@"; TRUST_FORWARDED=$2; shift 2 ;;
        --trust-forwarded=*) TRUST_FORWARDED=${1#*=}; shift ;;
        -h|--help)      usage; exit 0 ;;
        --)             shift; break ;;
        -*)             echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)              break ;;
    esac
done

# Old form: ./run.sh [PORT] [ROOT]
if [ "$#" -gt 0 ] && [ -z "$PORT" ]; then
    case "$1" in
        ''|*[!0-9]*) ;;
        *) PORT=$1; shift ;;
    esac
fi
if [ "$#" -gt 0 ] && [ -z "$ROOT" ]; then
    ROOT=$1; shift
fi
if [ "$#" -gt 0 ]; then
    echo "error: unexpected argument: $1" >&2
    usage >&2
    exit 2
fi

case "$CGI" in
    ''|on|off) ;;
    *) echo "error: --cgi must be 'on' or 'off'" >&2; exit 2 ;;
esac
case "$PROXY" in
    ''|on|off) ;;
    *) echo "error: --proxy must be 'on' or 'off'" >&2; exit 2 ;;
esac
case "$TRUST_FORWARDED" in
    ''|on|off) ;;
    *) echo "error: --trust-forwarded must be 'on' or 'off'" >&2; exit 2 ;;
esac
case "$AUTOINDEX" in
    ''|on|off) ;;
    *) echo "error: --autoindex must be 'on' or 'off'" >&2; exit 2 ;;
esac

if ! command -v gawk >/dev/null 2>&1; then
    echo "error: gawk is required (GNU awk, not mawk/busybox awk)" >&2
    exit 1
fi

# awk strings are byte strings; C locale keeps length()/readfile() binary-safe
# and gives English month names for HTTP dates.
export LC_ALL=C

set --
if [ -n "$CONFIG" ]; then            set -- "$@" -v "config_file=$CONFIG"; fi
if [ -n "$PORT" ]; then              set -- "$@" -v "port=$PORT"; fi
if [ -n "$HOST" ]; then              set -- "$@" -v "host=$HOST"; fi
if [ -n "$ROOT" ]; then              set -- "$@" -v "root=$ROOT"; fi
if [ -n "$INDEX" ]; then             set -- "$@" -v "index_files=$INDEX"; fi
if [ -n "$AUTOINDEX" ]; then         set -- "$@" -v "directory_listing=$AUTOINDEX"; fi
if [ -n "$CGI" ]; then               set -- "$@" -v "cgi_enabled=$CGI"; fi
if [ -n "$PROXY" ]; then             set -- "$@" -v "proxy_enabled=$PROXY"; fi
if [ -n "$ACCESS_LOG" ]; then        set -- "$@" -v "access_log=$ACCESS_LOG"; fi
if [ -n "$ERROR_LOG" ]; then         set -- "$@" -v "error_log=$ERROR_LOG"; fi
if [ -n "$READ_TIMEOUT" ]; then      set -- "$@" -v "read_timeout=$READ_TIMEOUT"; fi
if [ -n "$BODY_READ_TIMEOUT" ]; then set -- "$@" -v "body_read_timeout=$BODY_READ_TIMEOUT"; fi
if [ -n "$REQUEST_TIMEOUT" ]; then   set -- "$@" -v "request_timeout=$REQUEST_TIMEOUT"; fi
if [ -n "$MAX_BODY" ]; then          set -- "$@" -v "max_body_bytes=$MAX_BODY"; fi
if [ -n "$TRUST_FORWARDED" ]; then   set -- "$@" -v "trust_forwarded=$TRUST_FORWARDED"; fi

if [ "$CHECK" = 1 ]; then
    set -- "$@" -v "check_config=1"
    exec gawk --characters-as-bytes "$@" -f ./awk_web_server.awk
fi

# Let awk resolve TLS settings and validation once, then reuse them here.
if ! tls_dump="$(gawk --characters-as-bytes "$@" -v dump_vars=1 -f ./awk_web_server.awk)"; then
    echo "error: configuration validation failed (run --check-config)" >&2
    exit 2
fi
eval "$tls_dump"

if [ "${TLS_ENABLED:-off}" = "on" ]; then
    TLS_STATE_DIR="${TMPDIR:-/tmp}/awkws-tls.$$"
    mkdir -p "$TLS_STATE_DIR"
    chmod 700 "$TLS_STATE_DIR"

    TLS_PROXY="${TLS_PROXY:-auto}" \
    TLS_LISTEN_PORT="${TLS_LISTEN_PORT:-443}" \
    TLS_BACKEND_PORT="${TLS_BACKEND_PORT:-8080}" \
    TLS_CERT="${TLS_CERT:-}" \
    TLS_KEY="${TLS_KEY:-}" \
    TLS_CA="${TLS_CA:-}" \
    TLS_VERIFY="${TLS_VERIFY:-off}" \
    TLS_PROTOCOLS="${TLS_PROTOCOLS:-TLSv1.2,TLSv1.3}" \
    TLS_CIPHERS="${TLS_CIPHERS:-}" \
    TLS_STATE_DIR="$TLS_STATE_DIR" \
    /bin/sh ./lib/tls_launcher.sh &
    TLS_PID=$!
    APP_PID=""

    cleanup() {
        if [ -n "$APP_PID" ]; then
            kill -TERM "$APP_PID" 2>/dev/null || true
        fi
        kill -TERM "$TLS_PID" 2>/dev/null || true
        if [ -n "$APP_PID" ]; then
            wait "$APP_PID" 2>/dev/null || true
        fi
        wait "$TLS_PID" 2>/dev/null || true
        rm -rf "$TLS_STATE_DIR"
    }
    trap cleanup EXIT INT TERM HUP

    sleep 0.3
    if ! kill -0 "$TLS_PID" 2>/dev/null; then
        echo "error: TLS front proxy failed to start" >&2
        exit 1
    fi

    gawk --characters-as-bytes "$@" -f ./awk_web_server.awk &
    APP_PID=$!
    status=0
    wait "$APP_PID" || status=$?
    cleanup
    trap - EXIT INT TERM HUP
    exit "$status"
else
    exec gawk --characters-as-bytes "$@" -f ./awk_web_server.awk
fi

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
