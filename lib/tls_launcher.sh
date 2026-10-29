#!/bin/sh
# lib/tls_launcher.sh
#
# Foreground TLS front proxy for awk_web_server. run.sh backgrounds
# this, captures $!, and kills it on exit. stunnel is preferred
# (it has a clean per-connection fork and signals well); socat works
# but its fork children exit only when their connection ends.
#
# Environment consumed (set by run.sh from the dumped config):
#   TLS_PROXY        auto | stunnel | socat
#   TLS_LISTEN_PORT  0.0.0.0:<port>
#   TLS_BACKEND_PORT <port> on 127.0.0.1
#   TLS_CERT, TLS_KEY, TLS_CA
#   TLS_VERIFY       off | optional | required
#   TLS_PROTOCOLS    comma list, e.g. TLSv1.2,TLSv1.3
#   TLS_CIPHERS      OpenSSL cipher list (optional)
#   TLS_STATE_DIR    private temp dir for stunnel.conf (optional)

set -eu

log() { printf '%s\n' "tls: $*" >&2; }
die() { log "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

: "${TLS_PROXY:=auto}"
: "${TLS_LISTEN_PORT:=443}"
: "${TLS_BACKEND_PORT:=8080}"
: "${TLS_VERIFY:=off}"
: "${TLS_PROTOCOLS:=TLSv1.2,TLSv1.3}"
: "${TLS_CIPHERS:=}"
: "${TLS_CA:=}"
: "${TLS_STATE_DIR:=}"

[ -n "${TLS_CERT:-}" ] || die "TLS_CERT not set"
[ -n "${TLS_KEY:-}"  ] || die "TLS_KEY not set"
[ -r "$TLS_CERT" ]     || die "cannot read $TLS_CERT"
[ -r "$TLS_KEY"  ]     || die "cannot read $TLS_KEY"
[ -z "$TLS_CA"   ] || [ -r "$TLS_CA" ] || die "cannot read $TLS_CA"

choose_proxy() {
    case "$TLS_PROXY" in
        socat)   have socat   || die "socat not found"; echo socat ;;
        stunnel) have stunnel || die "stunnel not found"; echo stunnel ;;
        auto)
            if have stunnel; then echo stunnel
            elif have socat; then echo socat
            else die "need stunnel or socat"
            fi ;;
        *) die "unknown TLS_PROXY=$TLS_PROXY" ;;
    esac
}

# ---- stunnel ----
run_stunnel() {
    confdir=${TLS_STATE_DIR:-$(mktemp -d)}
    conf=$confdir/stunnel.conf

    # min-version: stunnel accepts TLSv1.2 / TLSv1.3 only.
    case "$TLS_PROTOCOLS" in
        *TLSv1.3*) minver=TLSv1.2 ;;
        *TLSv1.2*) minver=TLSv1.2 ;;
        *)         minver=TLSv1.2 ;;
    esac

    {
        echo "foreground = yes"
        echo "debug = notice"
        echo
        echo "[awkws]"
        echo "accept  = 0.0.0.0:${TLS_LISTEN_PORT}"
        echo "connect = 127.0.0.1:${TLS_BACKEND_PORT}"
        echo "cert = ${TLS_CERT}"
        echo "key  = ${TLS_KEY}"
        [ -n "$TLS_CA" ] && [ "$TLS_VERIFY" != "off" ] && echo "CAfile = ${TLS_CA}"
        [ -n "$TLS_CIPHERS" ] && echo "ciphers = ${TLS_CIPHERS}"
        echo "sslVersionMin = ${minver}"
        case "$TLS_VERIFY" in
            off)      echo "verifyChain = no"  ;;
            optional) echo "verifyChain = yes"; echo "verifyPeer = no"  ;;
            required) echo "verifyChain = yes"; echo "verifyPeer = yes" ;;
        esac
    } > "$conf"

    log "stunnel :${TLS_LISTEN_PORT} -> 127.0.0.1:${TLS_BACKEND_PORT} (conf=$conf)"
    exec stunnel "$conf"
}

# ---- socat ----
# Note: socat has no "optional client cert" mode; we map optional->required.
run_socat() {
    [ -n "$TLS_CIPHERS" ] && log "warning: socat cipher selection not supported; ignoring tls.ciphers"
    if [ "$TLS_VERIFY" = "optional" ]; then
        log "warning: socat has no 'optional' verify mode; treating as 'required'"
        TLS_VERIFY=required
    fi

    opts="reuseaddr,fork,cert=${TLS_CERT},key=${TLS_KEY}"
    case "$TLS_VERIFY" in
        required)
            opts="${opts},verify=1"
            [ -n "$TLS_CA" ] && opts="${opts},cafile=${TLS_CA}"
            ;;
        off) opts="${opts},verify=0" ;;
    esac
    case "$TLS_PROTOCOLS" in
        *TLSv1.3*|*TLSv1.2*) opts="${opts},min-version=TLS1.2" ;;
    esac

    log "socat   :${TLS_LISTEN_PORT} -> 127.0.0.1:${TLS_BACKEND_PORT}"
    exec socat "OPENSSL-LISTEN:${TLS_LISTEN_PORT},${opts}" \
               "TCP:127.0.0.1:${TLS_BACKEND_PORT}"
}

case "$(choose_proxy)" in
    stunnel) run_stunnel ;;
    socat)   run_socat   ;;
esac

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
