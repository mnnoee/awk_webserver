# lib/tls.awk
#
# TLS front-proxy configuration. The gawk server itself does not speak
# TLS; an external proxy (stunnel or socat) terminates TLS on
# tls.listen_port and forwards plain HTTP to 127.0.0.1:server.port.
#
# Only one public TLS port is supported. The internal plain-HTTP port
# (server.port) is still bound 0.0.0.0 by gawk; firewall it or pick a
# high port. This is a gawk /inet limitation, not ours.

function tls_init() {
    TLS_STATE = "off"
}

function tls_validate(    st) {
    TLS_STATE = "off"
    if (CONF["tls","enabled"] != "on") {
        CONF["server","public_port"] = CONF["server","port"]
        return
    }
    TLS_STATE = "on"
    CONF["server","public_port"] = CONF["tls","listen_port"]

    if (CONF["tls","listen_port"] !~ /^[0-9]+$/ ||
        CONF["tls","listen_port"] + 0 < 1 ||
        CONF["tls","listen_port"] + 0 > 65535)
        conf_error("tls.listen_port must be between 1 and 65535")
    else if (CONF["tls","listen_port"] + 0 == CONF["server","port"] + 0)
        conf_error("tls.listen_port must differ from server.port (" \
                   CONF["server","port"] "); gawk binds server.port for " \
                   "the internal plain-HTTP backend")

    if (CONF["tls","cert"] == "")
        conf_error("tls.cert is required when tls.enabled=on")
    else if (stat(CONF["tls","cert"], st) < 0 || st["type"] != "file")
        conf_error("tls.cert not a regular file: " CONF["tls","cert"])

    if (CONF["tls","key"] == "")
        conf_error("tls.key is required when tls.enabled=on")
    else if (stat(CONF["tls","key"], st) < 0 || st["type"] != "file")
        conf_error("tls.key not a regular file: " CONF["tls","key"])

    if (CONF["tls","ca"] != "" &&
        (stat(CONF["tls","ca"], st) < 0 || st["type"] != "file"))
        conf_error("tls.ca not a regular file: " CONF["tls","ca"])

    if (CONF["tls","verify_client"] !~ /^(off|optional|required)$/)
        conf_error("tls.verify_client must be off|optional|required")
    else if (CONF["tls","verify_client"] != "off" && CONF["tls","ca"] == "")
        conf_error("tls.ca is required when tls.verify_client is optional|required")

    if (CONF["tls","proxy"] !~ /^(auto|stunnel|socat)$/)
        conf_error("tls.proxy must be auto|stunnel|socat")

    if (CONF["tls","proxy"] == "socat" &&
        system("command -v socat >/dev/null 2>&1") != 0)
        conf_error("tls.proxy=socat but socat is not installed")
    if (CONF["tls","proxy"] == "stunnel" &&
        system("command -v stunnel >/dev/null 2>&1") != 0)
        conf_error("tls.proxy=stunnel but stunnel is not installed")
    if (CONF["tls","proxy"] == "auto" &&
        system("command -v stunnel >/dev/null 2>&1") != 0 &&
        system("command -v socat >/dev/null 2>&1") != 0)
        conf_error("tls.proxy=auto but neither stunnel nor socat is installed")

}

function tls_dump_vars(    ok) {
    ok = (CONF_ERRORS == 0)
    printf "TLS_ENABLED=%s\n",   shq(TLS_STATE)
    printf "TLS_LISTEN_PORT=%s\n", shq(CONF["tls","listen_port"])
    printf "TLS_CERT=%s\n",      shq(CONF["tls","cert"])
    printf "TLS_KEY=%s\n",       shq(CONF["tls","key"])
    printf "TLS_CA=%s\n",        shq(CONF["tls","ca"])
    printf "TLS_VERIFY=%s\n",    shq(CONF["tls","verify_client"])
    printf "TLS_PROTOCOLS=%s\n", shq(CONF["tls","protocols"])
    printf "TLS_CIPHERS=%s\n",   shq(CONF["tls","ciphers"])
    printf "TLS_PROXY=%s\n",     shq(CONF["tls","proxy"])
    printf "TLS_BACKEND_PORT=%s\n", shq(CONF["server","port"])
    return (ok ? 0 : 1)
}

function shq(s) {
    gsub(/'/, "'\\''", s)
    return "'" s "'"
}

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
