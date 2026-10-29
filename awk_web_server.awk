#!/usr/bin/gawk -f
# awk_web_server.awk -- small HTTP/1.1 server in GNU awk.
#
# Layout:
#   lib/config.awk  defaults, server.conf, env and CLI overrides
#   lib/http.awk    request parsing, responses, logging
#   lib/files.awk   static files, index, listing, ETag/304
#   lib/cgi.awk     CGI/1.1 dispatcher
#
# Run it through ./run.sh; that script sets LC_ALL=C and passes options.

@load "filefuncs"
@load "readfile"
@load "readdir"
@load "time"

@include "lib/config.awk"
@include "lib/tls.awk"
@include "lib/proxy.awk"
@include "lib/http.awk"
@include "lib/files.awk"
@include "lib/cgi.awk"

BEGIN {
    RS = "\n"
    ORS = "\r\n"

    http_init()
    files_init()
    cgi_init()
    tls_init()
    proxy_init()

    conf_errors = conf_init()
    if (dump_vars == "1")
        exit tls_dump_vars()
    if (check_config == "1")
        exit (conf_errors > 0 ? 1 : 0)
    if (conf_errors > 0) {
        print "config: refusing to start; fix the errors above" > "/dev/stderr"
        exit 2
    }

    port = CONF["server", "port"]
    service = "/inet/tcp/" port "/0/0"
    http_arm_timeout(service, CONF["http", "read_timeout"])

    if (TLS_STATE == "on") {
        print "awk web server listening on https://0.0.0.0:" \
              CONF["tls", "listen_port"] \
              "  (plain backend http://0.0.0.0:" port \
              ", root=" CONF["server", "root"] ")" > "/dev/stderr"
    } else {
        print "awk web server listening on http://0.0.0.0:" port \
              "  (root=" CONF["server", "root"] ")" > "/dev/stderr"
    }
    if (CONF["cgi", "enabled"] == "on")
        print "cgi enabled: " CONF["cgi", "prefix"] " -> " CONF["cgi", "root"] \
              " (timeout=" CONF["cgi", "timeout"] "s, max_output=" \
              CONF["cgi", "max_output_bytes"] " bytes)" > "/dev/stderr"
    for (vh in VHOST_ROOT)
        print "vhost " vh " -> " VHOST_ROOT[vh] > "/dev/stderr"

    while (1) {
        ERRNO = ""
        rc = (service |& getline)
        if (rc == -2) {
            close(service)
            service = "/inet/tcp/" port "/0/0"
            http_arm_timeout(service, CONF["http", "read_timeout"])
            continue
        }
        if (rc <= 0) {
            close(service)
            service = "/inet/tcp/" port "/0/0"
            http_arm_timeout(service, CONF["http", "read_timeout"])
            continue
        }

        started = gettimeofday()
        http_handle(service)
        http_log_access(gettimeofday() - started)

        close(service)
        service = "/inet/tcp/" port "/0/0"
        http_arm_timeout(service, CONF["http", "read_timeout"])
    }
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
