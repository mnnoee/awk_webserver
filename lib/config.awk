# lib/config.awk
#
# Configuration: defaults -> config file -> environment -> -v/CLI.
# The caller sets check_config=1 to validate and exit without binding.

function conf_defaults() {
    delete CONF
    CONF["server","host"] = "0.0.0.0"
    CONF["server","port"] = "8080"
    CONF["server","root"] = "./www"
    CONF["server","index"] = "index.html,index.htm"
    CONF["server","directory_listing"] = "on"
    CONF["server","server_header"] = "awk-web-server"
    CONF["server","public_port"] = "8080"

    CONF["http","max_request_line"] = "8192"
    CONF["http","max_header_bytes"] = "32768"
    CONF["http","max_headers"] = "100"
    CONF["http","request_timeout"] = "30"
    CONF["http","read_timeout"] = "10000"
    CONF["http","max_body_bytes"] = "1048576"
    CONF["http","body_read_timeout"] = "10000"
    CONF["http","trust_forwarded"] = "off"

    CONF["logging","access_log"] = "-"
    CONF["logging","error_log"] = "-"

    CONF["proxy","enabled"] = "off"

    CONF["cgi","enabled"] = "off"
    CONF["cgi","prefix"] = "/cgi-bin"
    CONF["cgi","root"] = "./cgi-bin"
    CONF["cgi","runner"] = "./lib/cgi_runner.sh"
    CONF["cgi","timeout"] = "10"
    CONF["cgi","max_output_bytes"] = "1048576"
    CONF["cgi","interpreters"] = "/bin/sh,/bin/bash,/usr/bin/env,sh,bash,python3,perl,gawk,/usr/bin/python3,/usr/bin/perl,/usr/bin/gawk"

    CONF["tls","enabled"] = "off"
    CONF["tls","listen_port"] = "443"
    CONF["tls","cert"] = ""
    CONF["tls","key"] = ""
    CONF["tls","ca"] = ""
    CONF["tls","verify_client"] = "off"
    CONF["tls","protocols"] = "TLSv1.2,TLSv1.3"
    CONF["tls","ciphers"] = ""
    CONF["tls","proxy"] = "auto"
}

function conf_trim(s) {
    sub(/^[ \t]+/, "", s)
    sub(/[ \t]+$/, "", s)
    return s
}

function conf_error(msg) {
    print "config: error: " msg > "/dev/stderr"
    CONF_ERRORS++
}

function conf_warn(msg) {
    print "config: warning: " msg > "/dev/stderr"
}

function conf_load(file,    line, section, eq, key, val, ln, oldrs) {
    section = "server"
    ln = 0
    oldrs = RS
    RS = "\n"
    while ((getline line < file) > 0) {
        ln++
        sub(/\r$/, "", line)
        if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*[#;]/) continue

        if (line ~ /^[ \t]*\[.*\][ \t]*$/) {
            section = line
            sub(/^[ \t]*\[/, "", section)
            sub(/\][ \t]*$/, "", section)
            section = conf_trim(section)
            if (section ~ /^vhost:/) VHOST_SECTIONS[section] = 1
            if (section ~ /^proxy:/) PROXY_SECTIONS[section] = 1
            continue
        }

        eq = index(line, "=")
        if (eq == 0) {
            conf_error(file ":" ln ": expected 'key = value'")
            continue
        }
        key = conf_trim(substr(line, 1, eq - 1))
        if (eq >= length(line)) val = ""
        else val = conf_trim(substr(line, eq + 1))
        if (key == "") {
            conf_error(file ":" ln ": empty key")
            continue
        }
        CONF[section, key] = val
    }
    RS = oldrs
    close(file)
}

function conf_env_value(name, legacy,    v) {
    v = ENVIRON[name]
    if (v == "" && legacy != "") v = ENVIRON[legacy]
    return v
}

function conf_apply_overrides(    v) {
    # Environment is lower priority than -v values already present.
    if (port == "") port = conf_env_value("AWKWS_PORT", "PORT")
    if (host == "") host = conf_env_value("AWKWS_HOST", "")
    if (root == "") root = conf_env_value("AWKWS_ROOT", "ROOT")
    if (index_files == "") index_files = conf_env_value("AWKWS_INDEX", "")
    if (directory_listing == "") directory_listing = conf_env_value("AWKWS_DIRECTORY_LISTING", "")
    if (cgi_enabled == "") cgi_enabled = conf_env_value("AWKWS_CGI", "")
    if (access_log == "") access_log = conf_env_value("AWKWS_ACCESS_LOG", "")
    if (error_log == "") error_log = conf_env_value("AWKWS_ERROR_LOG", "")
    if (max_request_line == "") max_request_line = conf_env_value("AWKWS_MAX_REQUEST_LINE", "")
    if (max_header_bytes == "") max_header_bytes = conf_env_value("AWKWS_MAX_HEADER_BYTES", "")
    if (max_headers == "") max_headers = conf_env_value("AWKWS_MAX_HEADERS", "")
    if (request_timeout == "") request_timeout = conf_env_value("AWKWS_REQUEST_TIMEOUT", "")
    if (read_timeout == "") read_timeout = conf_env_value("AWKWS_READ_TIMEOUT", "")
    if (max_body_bytes == "") max_body_bytes = conf_env_value("AWKWS_MAX_BODY_BYTES", "")
    if (body_read_timeout == "") body_read_timeout = conf_env_value("AWKWS_BODY_READ_TIMEOUT", "")
    if (trust_forwarded == "") trust_forwarded = conf_env_value("AWKWS_TRUST_FORWARDED", "")
    if (proxy_enabled == "") proxy_enabled = conf_env_value("AWKWS_PROXY", "")

    if (port != "") CONF["server","port"] = port
    if (host != "") CONF["server","host"] = host
    if (root != "") CONF["server","root"] = root
    if (index_files != "") CONF["server","index"] = index_files
    if (directory_listing != "") CONF["server","directory_listing"] = directory_listing
    if (cgi_enabled != "") CONF["cgi","enabled"] = cgi_enabled
    if (access_log != "") CONF["logging","access_log"] = access_log
    if (error_log != "") CONF["logging","error_log"] = error_log
    if (max_request_line != "") CONF["http","max_request_line"] = max_request_line
    if (max_header_bytes != "") CONF["http","max_header_bytes"] = max_header_bytes
    if (max_headers != "") CONF["http","max_headers"] = max_headers
    if (request_timeout != "") CONF["http","request_timeout"] = request_timeout
    if (read_timeout != "") CONF["http","read_timeout"] = read_timeout
    if (max_body_bytes != "") CONF["http","max_body_bytes"] = max_body_bytes
    if (body_read_timeout != "") CONF["http","body_read_timeout"] = body_read_timeout
    if (trust_forwarded != "") CONF["http","trust_forwarded"] = trust_forwarded
    if (proxy_enabled != "") CONF["proxy","enabled"] = proxy_enabled
}

function conf_norm_dir(p) {
    sub(/\/+$/, "", p)
    if (p == "") p = "/"
    return p
}

function conf_finalize(    i, n, parts, v, base, sec, host) {
    CONF["server","root"] = conf_norm_dir(CONF["server","root"])
    CONF["cgi","root"] = conf_norm_dir(CONF["cgi","root"])

    v = CONF["cgi","prefix"]
    if (substr(v, 1, 1) != "/") v = "/" v
    sub(/\/+$/, "", v)
    if (v == "") v = "/cgi-bin"
    CONF["cgi","prefix"] = v

    delete INDEXES
    INDEX_COUNT = 0
    n = split(CONF["server","index"], parts, ",")
    for (i = 1; i <= n; i++) {
        v = conf_trim(parts[i])
        if (v != "") INDEXES[++INDEX_COUNT] = v
    }

    delete INTERP_OK
    n = split(CONF["cgi","interpreters"], parts, ",")
    for (i = 1; i <= n; i++) {
        v = conf_trim(parts[i])
        if (v == "") continue
        INTERP_OK[v] = 1
        base = v
        sub(/.*\//, "", base)
        if (base != "") INTERP_OK[base] = 1
    }

    delete VHOST_ROOT
    delete VHOST_CONF
    for (sec in VHOST_SECTIONS) {
        host = tolower(substr(sec, 7))
        sub(/\.$/, "", host)
        if (host == "") continue
        if ((sec, "root") in CONF && CONF[sec, "root"] != "")
            VHOST_ROOT[host] = conf_norm_dir(CONF[sec, "root"])
        else
            VHOST_ROOT[host] = CONF["server", "root"]
        if ((sec, "index") in CONF)
            VHOST_CONF[host, "index"] = CONF[sec, "index"]
        if ((sec, "directory_listing") in CONF)
            VHOST_CONF[host, "directory_listing"] = CONF[sec, "directory_listing"]
    }
}

function conf_check_pos(section, key) {
    if (CONF[section, key] !~ /^[0-9]+$/ || (CONF[section, key] + 0) < 1)
        conf_error(section "." key " must be a positive integer")
}

function conf_check_nonneg(section, key) {
    if (CONF[section, key] !~ /^[0-9]+$/)
        conf_error(section "." key " must be a non-negative integer")
}

function conf_check_bool(section, key) {
    if (CONF[section, key] != "on" && CONF[section, key] != "off")
        conf_error(section "." key " must be 'on' or 'off'")
}

function conf_validate(    st, v, sec, host, root) {
    v = CONF["server","port"] + 0
    if (v < 1 || v > 65535)
        conf_error("server.port must be between 1 and 65535")

    if (stat(CONF["server","root"], st) < 0)
        conf_error("server.root not found: " CONF["server","root"])
    else if (st["type"] != "directory")
        conf_error("server.root is not a directory: " CONF["server","root"])

    if (INDEX_COUNT < 1)
        conf_error("server.index must list at least one file name")

    conf_check_bool("server", "directory_listing")
    conf_check_bool("cgi", "enabled")

    conf_check_pos("http", "max_request_line")
    conf_check_pos("http", "max_header_bytes")
    conf_check_pos("http", "max_headers")
    conf_check_nonneg("http", "request_timeout")
    conf_check_nonneg("http", "read_timeout")
    conf_check_pos("http", "max_body_bytes")
    conf_check_nonneg("http", "body_read_timeout")
    conf_check_bool("http", "trust_forwarded")
    conf_check_pos("cgi", "timeout")
    conf_check_pos("cgi", "max_output_bytes")

    if (CONF["cgi","enabled"] == "on") {
        if (stat(CONF["cgi","root"], st) < 0)
            conf_error("cgi.root not found: " CONF["cgi","root"])
        else if (st["type"] != "directory")
            conf_error("cgi.root is not a directory: " CONF["cgi","root"])
        if (stat(CONF["cgi","runner"], st) < 0)
            conf_error("cgi.runner not found: " CONF["cgi","runner"])
        else if (st["type"] != "file")
            conf_error("cgi.runner is not a file: " CONF["cgi","runner"])
        if (CONF["cgi","interpreters"] == "")
            conf_error("cgi.interpreters must not be empty")
        if (system("command -v timeout >/dev/null 2>&1") != 0)
            conf_error("CGI requires the 'timeout' command (coreutils)")
        if (system("command -v head >/dev/null 2>&1") != 0)
            conf_error("CGI requires the 'head' command")
        if (system("command -v mktemp >/dev/null 2>&1") != 0)
            conf_error("CGI requires the 'mktemp' command")
    }

    for (sec in VHOST_SECTIONS) {
        host = tolower(substr(sec, 7))
        sub(/\.$/, "", host)
        if (host == "") {
            conf_error("empty virtual host name in [" sec "]")
            continue
        }
        if (!(host in VHOST_ROOT)) {
            conf_error("vhost " host " has no root")
            continue
        }
        root = VHOST_ROOT[host]
        if (stat(root, st) < 0)
            conf_error("vhost " host " root not found: " root)
        else if (st["type"] != "directory")
            conf_error("vhost " host " root is not a directory: " root)
    }

    if (CONF["server","host"] != "0.0.0.0" &&
        CONF["server","host"] != "*" &&
        CONF["server","host"] != "")
        conf_warn("gawk always binds 0.0.0.0; server.host=" CONF["server","host"] " is advisory only")

    return CONF_ERRORS
}

function conf_init(    file, explicit, st) {
    CONF_ERRORS = 0
    delete CONF
    delete VHOST_SECTIONS
    delete PROXY_SECTIONS
    conf_defaults()

    file = config_file
    if (file == "") file = conf_env_value("AWKWS_CONFIG", "")
    if (file == "") file = "server.conf"
    explicit = (config_file != "" || ENVIRON["AWKWS_CONFIG"] != "" || config_required == "1")
    config_file = file

    if (stat(file, st) == 0 && st["type"] == "file")
        conf_load(file)
    else if (explicit)
        conf_error("cannot read config file: " file)

    conf_apply_overrides()
    conf_finalize()
    proxy_finalize()
    conf_validate()
    proxy_validate()
    tls_validate()
    if (check_config == "1") conf_print()
    return CONF_ERRORS
}

function conf_print(    h, sec) {
    print "configuration: " (CONF_ERRORS > 0 ? "ERRORS" : "OK")
    print "  bind: " CONF["server","host"] ":" CONF["server","port"] " (gawk binds 0.0.0.0)"
    print "  root: " CONF["server","root"]
    print "  index: " CONF["server","index"]
    print "  directory_listing: " CONF["server","directory_listing"]
    print "  cgi: " CONF["cgi","enabled"] " prefix=" CONF["cgi","prefix"] " root=" CONF["cgi","root"]
    print "  access_log: " CONF["logging","access_log"]
    print "  error_log: " CONF["logging","error_log"]
    print "  tls: " CONF["tls","enabled"] " listen_port=" CONF["tls","listen_port"] \
          " cert=" CONF["tls","cert"]
    proxy_print()
    for (h in VHOST_ROOT)
        print "  vhost: " h " -> " VHOST_ROOT[h]
    if (CONF_ERRORS > 0)
        print "  errors: " CONF_ERRORS
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
