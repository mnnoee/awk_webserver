# lib/cgi.awk
#
# CGI/1.1 support. Runs only scripts from cgi.root whose shebang
# interpreter is explicitly allowed. Execution goes through
# lib/cgi_runner.sh, which applies timeout and output-size limits.

function cgi_init() {
    CGI_MAX_HEADER = 16384
}

function cgi_handle(svc, script_full, script_name, query, docroot,    st, argc, argv, tmpdir,
                    bodyfile, outfile, errfile, statusfile, cmd, sysrc, status, errtext,
                    outtext, outsize, maxout, hdr, cbody, hpos, npos, cgi_status, ctype, i, oldrs) {
    if (stat(script_full, st) < 0) {
        http_error(svc, "404 Not Found", "CGI script not found")
        return
    }
    if (st["type"] != "file") {
        http_error(svc, "403 Forbidden", "CGI path is not a regular file")
        return
    }

    argc = cgi_read_shebang(script_full, argv)
    if (argc < 1) {
        http_error(svc, "502 Bad Gateway", "CGI script has no shebang line")
        return
    }
    if (!cgi_interpreter_allowed(argv, argc)) {
        http_error(svc, "403 Forbidden", "CGI interpreter is not allowed")
        return
    }

    cgi_prepare_env(docroot, script_full, script_name, query)

    cmd = "mktemp -d"
    tmpdir = ""
    oldrs = RS
    RS = "\n"
    cmd | getline tmpdir
    RS = oldrs
    close(cmd)
    sub(/\r$/, "", tmpdir)
    sub(/\n$/, "", tmpdir)
    if (tmpdir == "" || substr(tmpdir, 1, 1) != "/") {
        cgi_clear_env()
        http_error(svc, "500 Internal Server Error", "Could not create CGI temp directory")
        return
    }

    bodyfile = tmpdir "/body"
    outfile = tmpdir "/out"
    errfile = tmpdir "/err"
    statusfile = tmpdir "/status"

    ERRNO = ""
    printf "%s", BODY > bodyfile
    close(bodyfile)
    if (ERRNO != "") {
        cgi_cleanup(tmpdir)
        http_error(svc, "500 Internal Server Error", "Could not write CGI request body")
        return
    }

    maxout = CONF["cgi", "max_output_bytes"] + 0
    cmd = "/bin/sh " cgi_shell_quote(CONF["cgi", "runner"])
    cmd = cmd " " cgi_shell_quote(maxout "") " " cgi_shell_quote(outfile)
    cmd = cmd " " cgi_shell_quote(errfile) " " cgi_shell_quote(statusfile)
    cmd = cmd " " cgi_shell_quote(bodyfile) " " cgi_shell_quote(CONF["cgi", "timeout"])
    for (i = 1; i <= argc; i++) cmd = cmd " " cgi_shell_quote(argv[i])
    cmd = cmd " " cgi_shell_quote(script_full)

    sysrc = system(cmd)

    status = ""
    oldrs = RS
    RS = "\n"
    if ((getline status < statusfile) <= 0) status = ""
    RS = oldrs
    close(statusfile)
    sub(/\r$/, "", status)
    sub(/\n$/, "", status)

    ERRNO = ""
    outtext = readfile(outfile)
    outsize = length(outtext)
    ERRNO = ""
    errtext = readfile(errfile)
    cgi_cleanup(tmpdir)
    cgi_clear_env()

    if (errtext != "") {
        sub(/\n+$/, "", errtext)
        if (length(errtext) > 1000) errtext = substr(errtext, 1, 1000) "..."
        gsub(/[[:cntrl:]]/, " ", errtext)
        http_log_error("cgi " script_name " exit=" (status == "" ? "?" : status) ": " errtext)
    }

    if (status == "") {
        http_error(svc, "500 Internal Server Error", "CGI runner did not report an exit status")
        return
    }
    if (outsize > maxout) {
        http_error(svc, "502 Bad Gateway", "CGI output exceeds the configured limit")
        return
    }
    if (status + 0 == 124 || status + 0 == 137) {
        http_error(svc, "504 Gateway Timeout", "CGI script timed out")
        return
    }
    if (status + 0 == 141) {
        http_error(svc, "502 Bad Gateway", "CGI output was truncated (SIGPIPE)")
        return
    }
    if (status + 0 != 0) {
        http_error(svc, "502 Bad Gateway", "CGI script exited with status " status)
        return
    }

    hpos = index(outtext, "\r\n\r\n")
    npos = index(outtext, "\n\n")
    if (hpos > 0 && (npos == 0 || hpos < npos)) {
        hdr = substr(outtext, 1, hpos - 1)
        cbody = substr(outtext, hpos + 4)
    } else if (npos > 0) {
        hdr = substr(outtext, 1, npos - 1)
        cbody = substr(outtext, npos + 2)
    } else {
        http_error(svc, "502 Bad Gateway", "CGI response has no header block")
        return
    }

    if (length(hdr) > CGI_MAX_HEADER) {
        http_error(svc, "502 Bad Gateway", "CGI response headers are too large")
        return
    }

    CGI_STATUS = ""
    CGI_CTYPE = ""
    if (!cgi_parse_headers(svc, hdr)) return
    cgi_status = CGI_STATUS
    ctype = CGI_CTYPE
    if (cgi_status == "") {
        if (("Location" in EXTRA) && EXTRA["Location"] != "")
            cgi_status = "302 Found"
        else
            cgi_status = "200 OK"
    }
    if (ctype == "" && !(("Location" in EXTRA) && EXTRA["Location"] != "")) {
        http_error(svc, "502 Bad Gateway", "CGI response has no Content-Type")
        return
    }

    http_send(svc, cgi_status, ctype, cbody, EXTRA)
}

function cgi_read_shebang(script, argv,    line, rc, n, parts, i, c, oldrs) {
    oldrs = RS
    RS = "\n"
    rc = (getline line < script)
    close(script)
    RS = oldrs
    if (rc <= 0 || substr(line, 1, 2) != "#!") return 0
    sub(/^#![ \t]*/, "", line)
    sub(/\r$/, "", line)
    if (line == "") return 0
    n = split(line, parts, /[ \t]+/)
    c = 0
    for (i = 1; i <= n; i++)
        if (parts[i] != "") argv[++c] = parts[i]
    return c
}

function cgi_interpreter_allowed(argv, argc,    interp, base, target, tbase, idx) {
    interp = argv[1]
    if (index(interp, "/") == 0) return 0       # direct interpreter must be a path
    if (!(interp in INTERP_OK)) return 0

    base = interp
    sub(/.*\//, "", base)
    if (base != "env") return 1

    idx = 2
    if (idx <= argc && argv[idx] == "-S") idx++
    if (idx > argc) return 0
    target = argv[idx]
    if (substr(target, 1, 1) == "-") return 0
    tbase = target
    sub(/.*\//, "", tbase)
    if (!(target in INTERP_OK) && !(tbase in INTERP_OK)) return 0
    return 1
}

function cgi_prepare_env(docroot, script_full, script_name, query,    k, name) {
    cgi_clear_env()
    cgi_setenv("GATEWAY_INTERFACE", "CGI/1.1")
    cgi_setenv("SERVER_PROTOCOL", g_protocol)
    cgi_setenv("SERVER_SOFTWARE", CONF["server", "server_header"])
    cgi_setenv("REQUEST_METHOD", g_method)
    cgi_setenv("REQUEST_URI", g_target)
    cgi_setenv("QUERY_STRING", query)
    cgi_setenv("SCRIPT_NAME", script_name)
    cgi_setenv("SCRIPT_FILENAME", script_full)
    cgi_setenv("DOCUMENT_ROOT", docroot)
    cgi_setenv("SERVER_NAME", (g_host != "" ? g_host : "localhost"))
    cgi_setenv("SERVER_PORT", CONF["server", "public_port"])
    if (TLS_STATE == "on") {
        cgi_setenv("HTTPS", "on")
        cgi_setenv("HTTP_X_FORWARDED_PROTO", "https")
    }
    cgi_setenv("REMOTE_ADDR", http_client_ip())

    if (g_method != "GET" && g_method != "HEAD") {
        cgi_setenv("CONTENT_LENGTH", length(BODY) "")
        if (H["content-type"] != "") cgi_setenv("CONTENT_TYPE", H["content-type"])
    }

    for (k in H) {
        if (k == "content-length" || k == "content-type") continue
        name = "HTTP_" toupper(k)
        gsub(/-/, "_", name)
        if (name !~ /^HTTP_[A-Z0-9_]+$/) continue
        cgi_setenv(name, H[k])
    }
}

function cgi_setenv(name, value) {
    ENVIRON[name] = value
    CGI_ENV_KEYS[name] = 1
}

function cgi_clear_env(k) {
    for (k in CGI_ENV_KEYS) delete ENVIRON[k]
    delete CGI_ENV_KEYS
}

function cgi_parse_headers(svc, hdr,    lines, n, i, line, colon,
                           name, value, lname, vtest) {
    delete EXTRA
    CGI_STATUS = ""
    CGI_CTYPE = ""
    n = split(hdr, lines, "\n")
    for (i = 1; i <= n; i++) {
        line = lines[i]
        sub(/\r$/, "", line)
        if (line == "") continue
        colon = index(line, ":")
        if (colon == 0) {
            http_error(svc, "502 Bad Gateway", "Malformed CGI response header")
            return 0
        }
        name = substr(line, 1, colon - 1)
        value = substr(line, colon + 1)
        sub(/^[ \t]+/, "", value)
        sub(/[ \t]+$/, "", value)
        vtest = value
        gsub(/\t/, "", vtest)
        if (name !~ /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/ ||
            vtest ~ /[[:cntrl:]]/) {
            http_error(svc, "502 Bad Gateway", "Malformed CGI response header")
            return 0
        }
        lname = tolower(name)
        if (lname == "status") {
            CGI_STATUS = cgi_status_line(value)
            if (CGI_STATUS == "") {
                http_error(svc, "502 Bad Gateway", "Invalid CGI Status header")
                return 0
            }
        } else if (lname == "content-type") {
            CGI_CTYPE = value
        } else if (lname == "content-length" || lname == "connection" ||
                   lname == "server" || lname == "transfer-encoding" ||
                   lname == "date") {
            continue
        } else {
            EXTRA[name] = value
        }
    }
    return 1
}

function cgi_status_line(value,    code, reason) {
    value = conf_trim(value)
    if (value !~ /^[0-9][0-9][0-9]([ \t]|$)/) return ""
    code = substr(value, 1, 3) + 0
    if (code < 100 || code > 599) return ""
    reason = substr(value, 5)
    sub(/^[ \t]+/, "", reason)
    if (reason == "") reason = (code == 200 ? "OK" : "CGI")
    return code " " reason
}

function cgi_shell_quote(s,    r) {
    r = s
    gsub(/'/, "'\\''", r)
    return "'" r "'"
}

function cgi_cleanup(tmpdir) {
    system("rm -rf -- " cgi_shell_quote(tmpdir))
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
