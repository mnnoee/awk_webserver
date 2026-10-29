#!/bin/sh
# Verify the gawk readdir record shape used by lib/files.awk.
#
# gawk 5.4.1 returns inode/name/type. Some builds/versions are documented
# as name/type/inode; the listing parser accepts both. This test records
# which one is present and fails only on an unexpected shape.

set -eu

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/sub"
: > "$tmp/a.txt"
ln -s /etc/passwd "$tmp/link"

out=$(gawk '@load "readdir"; BEGIN {
    while ((getline line < ARGV[1]) > 0) print line
}' "$tmp")

printf '%s\n' "$out"

if printf '%s\n' "$out" | grep -Eq '^[0-9]+/[^/]+/[bcdflps]$'; then
    echo "readdir: inode/name/type"
elif printf '%s\n' "$out" | grep -Eq '^[^/]+/[bcdflps]/[0-9]+$'; then
    echo "readdir: name/type/inode"
else
    echo "readdir: unexpected record shape" >&2
    exit 1
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
