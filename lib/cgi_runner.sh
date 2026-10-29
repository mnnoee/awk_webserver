#!/bin/sh
# lib/cgi_runner.sh
#
# Usage:
#   cgi_runner.sh MAX_OUT BYTE OUTFILE ERRFILE STATUSFILE BODYFILE TIMEOUT \
#                 INTERPRETER [ARGS...] SCRIPT
#
# Runs the script with stdin from BODYFILE, captures stdout (capped at
# MAX_OUT bytes), stderr (capped at 64 KiB) and the exit status in
# STATUSFILE. The wrapper itself always exits 0 when it could run; the
# real status is read from STATUSFILE by the awk process.

set -u

if [ "$#" -lt 7 ]; then
    echo "cgi_runner: usage: cgi_runner.sh MAX_OUT OUTFILE ERRFILE STATUSFILE BODYFILE TIMEOUT INTERPRETER [ARGS...] SCRIPT" >&2
    exit 2
fi

max_out=$1
out=$2
err=$3
status=$4
body=$5
timeout_s=$6
shift 6

case "$max_out" in
    ''|*[!0-9]*) max_out=1048576 ;;
esac
case "$timeout_s" in
    ''|*[!0-9]*) timeout_s=10 ;;
esac

: > "$status"
: > "$out"
: > "$err"

# timeout(1) sends TERM after timeout_s and KILL 2s later. Its exit
# status (124/137 on timeout) is recorded in STATUSFILE. head(1) caps
# the response; one extra byte lets awk detect an oversized response.
( timeout -k 2 "$timeout_s" "$@" < "$body" 2> "$err"; printf '%s\n' "$?" > "$status" ) \
    | head -c "$((max_out + 1))" > "$out"

# Keep stderr bounded even if the child was noisy.
if [ -s "$err" ]; then
    head -c 65536 "$err" > "$err.tmp"
    mv "$err.tmp" "$err"
fi

exit 0

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
