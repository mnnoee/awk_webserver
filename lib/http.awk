# lib/http.awk
#
# HTTP request parsing, responses, common headers and logging.
# Uses RS="\n" consistently throughout the connection.

function http_init() {
    # table of all byte values (for ord() / urlencode())
    BYTESTR = ""
    for (bi = 1; bi <= 255; bi++) BYTESTR = BYTESTR sprintf("%c", bi)
    # A client may disappear while we are writing. Do not let that kill
    # the whole server process; http_out() checks ERRNO instead.
    PROCINFO["NONFATAL"] = 1
}

function http_out(svc, s) {
    if (HTTP_SEND_FAILED) return
    ERRNO = ""
    print s |& svc
    if (ERRNO != "") HTTP_SEND_FAILED = 1
}

function http_arm_timeout(svc, timeout_ms) {
    PROCINFO[svc, "RETRY"] = 1
    PROCINFO[svc, "READ_TIMEOUT"] = timeout_ms + 0
}

function http_handle(svc,    req, parts, n, method, target, version, path, q, h, hcount, hbytes, deadline, hn, hv, hvt, ns, segs, si, host, docroot, cgi_prefix, script_rel, script_full, clen, te, expect, route, pr, rc) {
    req = $0
    sub(/\r$/, "", req)
    if (req ~ /[[:cntrl:]]/) {
        http_error(svc, "400 Bad Request", "Control character in request line")
        return
    }
    g_method = "?"
    g_target = "?"
    g_path = "/"
    g_query = ""
    g_status = ""
    g_status_code = 0
    g_bytes = 0
    g_is_head = 0
    g_vhost = ""
    g_host = ""
    g_protocol = "HTTP/1.1"
    g_body_err = 0
    g_send_len = -1
    delete H
    BODY = ""

    n = split(req, parts, " ")
    if (n < 3) {
        http_error(svc, "400 Bad Request", "Malformed request line")
        return
    }
    method = parts[1]
    target = parts[2]
    version = parts[3]
    if (version != "HTTP/1.0" && version != "HTTP/1.1") {
        http_error(svc, "505 HTTP Version Not Supported", "Only HTTP/1.0 and HTTP/1.1 are supported")
        return
    }
    g_method = method
    g_target = target
    g_protocol = version
    g_is_head = (method == "HEAD")

    if (length(req) > CONF["http","max_request_line"] + 0) {
        http_error(svc, "414 URI Too Long", "Request line too long")
        return
    }

    # headers: read lines, strip CR, lowercase names, enforce limits
    hcount = 0
    hbytes = 0
    deadline = (CONF["http","request_timeout"] + 0 > 0) ? systime() + CONF["http","request_timeout"] : 0
    while (1) {
        ERRNO = ""
        rc = (svc |& getline)
        if (rc == -2) {
            http_error(svc, "408 Request Timeout", "Timed out while reading headers")
            return
        }
        if (rc <= 0) break
        sub(/\r$/, "", $0)
        if ($0 == "") break
        hcount++
        hbytes += length($0) + 1
        if (hcount > CONF["http","max_headers"] + 0 ||
            hbytes > CONF["http","max_header_bytes"] + 0) {
            http_error(svc, "431 Request Header Fields Too Large", "Too many or too large headers")
            return
        }
        if (deadline > 0 && systime() > deadline) {
            http_error(svc, "408 Request Timeout", "Headers took too long")
            return
        }
        h = index($0, ":")
        if (h == 0) {
            http_error(svc, "400 Bad Request", "Malformed header line")
            return
        }
        hn = tolower(substr($0, 1, h - 1))
        hv = substr($0, h + 1)
        sub(/^[ \t]+/, "", hv)
        sub(/[ \t]+$/, "", hv)

        # RFC 7230 token; reject obs-fold, CR/LF and other controls in
        # values (HTAB is allowed). This closes header injection into
        # CGI HTTP_* variables and the reverse proxy.
        if (hn !~ /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/) {
            http_error(svc, "400 Bad Request", "Invalid header name")
            return
        }
        hvt = hv
        gsub(/\t/, "", hvt)
        if (hvt ~ /[[:cntrl:]]/) {
            http_error(svc, "400 Bad Request", "Invalid control character in header value")
            return
        }

        if (hn in H) {
            if (hn == "host" && H[hn] != hv) {
                http_error(svc, "400 Bad Request", "Conflicting Host headers")
                return
            }
            if (hn == "content-length" && H[hn] != hv) {
                http_error(svc, "400 Bad Request", "Conflicting Content-Length headers")
                return
            }
            if (hn == "cookie") H[hn] = H[hn] "; " hv
            else H[hn] = hv
        } else {
            H[hn] = hv
        }
    }

    if (method != "GET" && method != "HEAD" && method != "POST" &&
        method != "PUT" && method != "PATCH" && method != "DELETE" &&
        method != "OPTIONS") {
        http_error(svc, "405 Method Not Allowed", "Method not allowed")
        return
    }

    # split target into path and query
    path = target
    q = index(path, "?")
    if (q > 0) {
        g_query = substr(path, q + 1)
        path = substr(path, 1, q - 1)
    }
    q = index(path, "#")
    if (q > 0) path = substr(path, 1, q - 1)
    if (path == "") path = "/"
    g_path = http_normalize(urldecode(path))
    if (g_path == "") {
        http_error(svc, "403 Forbidden", "Path traversal not allowed")
        return
    }
    if (g_path ~ /[[:cntrl:]]/) {
        http_error(svc, "400 Bad Request", "Control character in path")
        return
    }

    host = H["host"]
    if (host != "" && !http_valid_host(host)) {
        http_error(svc, "400 Bad Request", "Invalid Host header")
        return
    }
    if (host == "") host = CONF["server","host"]
    g_host = http_host_only(host)
    docroot = (g_host in VHOST_ROOT) ? VHOST_ROOT[g_host] : CONF["server","root"]

    # Choose the route before reading a body: proxy -> CGI -> static.
    route = "static"
    pr = ""
    if (PROXY_ENABLED == "on") {
        pr = proxy_match(g_host, g_path)
        if (pr != "") route = "proxy"
    }
    cgi_prefix = CONF["cgi","prefix"]
    if (route == "static" &&
        (g_path == cgi_prefix || index(g_path, cgi_prefix "/") == 1)) {
        if (CONF["cgi","enabled"] != "on") {
            http_error(svc, "404 Not Found", "Not found")
            return
        }
        route = "cgi"
    }

    # Static files accept no request body.
    if (route == "static" && method != "GET" && method != "HEAD") {
        http_error(svc, "405 Method Not Allowed", method " is not allowed for static files")
        return
    }

    # Read the body for CGI and proxy routes.
    if (route != "static" && method != "GET" && method != "HEAD") {
        te = tolower(H["transfer-encoding"])
        if (te ~ /chunked/) {
            http_error(svc, "501 Not Implemented", "Chunked request bodies are not supported")
            return
        }
        clen = H["content-length"]
        if (clen == "") {
            if (method == "POST" || method == "PUT" || method == "PATCH") {
                http_error(svc, "411 Length Required", "Content-Length is required")
                return
            }
            clen = 0
        } else if (clen !~ /^[0-9]+$/) {
            http_error(svc, "400 Bad Request", "Invalid Content-Length")
            return
        }
        clen += 0
        if (clen > CONF["http","max_body_bytes"] + 0) {
            http_error(svc, "413 Payload Too Large", "Request body is too large")
            return
        }
        expect = tolower(H["expect"])
        if (expect ~ /100-continue/) {
            print "HTTP/1.1 100 Continue" |& svc
            print "" |& svc
        }
        BODY = http_read_body(svc, clen)
        if (g_body_err) {
            http_error(svc, g_body_err == 408 ? "408 Request Timeout" : "400 Bad Request", "Could not read request body")
            return
        }
    }

    if (route == "proxy") {
        proxy_handle(svc, pr, method, g_path, g_query)
        return
    }

    if (route == "cgi") {
        script_rel = substr(g_path, length(cgi_prefix) + 2)
        if (script_rel == "") {
            http_error(svc, "404 Not Found", "Not found")
            return
        }
        script_full = CONF["cgi","root"] "/" script_rel
        if (path_has_symlink(CONF["cgi","root"], "/" script_rel)) {
            http_error(svc, "403 Forbidden", "Symbolic links are not served")
            return
        }
        cgi_handle(svc, script_full, g_path, g_query, docroot)
        return
    }

    if (path_has_symlink(docroot, g_path)) {
        http_error(svc, "403 Forbidden", "Symbolic links are not served")
        return
    }
    files_handle(svc, docroot, g_path, g_is_head)
}

function http_read_body(svc, clen,    body, rc, oldto, bt) {
    g_body_err = 0
    if (clen <= 0) return ""

    oldto = PROCINFO[svc, "READ_TIMEOUT"] + 0
    bt = CONF["http","body_read_timeout"] + 0
    if (bt > 0) PROCINFO[svc, "READ_TIMEOUT"] = bt

    # RS="\n" gives whole lines. $0 excludes the trailing newline, RT holds
    # it (or "" for the final line). Reconstruct exactly, then clip to
    # Content-Length. See README for the newline/Connection: close limit.
    body = ""
    while (length(body) < clen) {
        ERRNO = ""
        rc = (svc |& getline)
        if (rc > 0) {
            body = body $0 RT
            continue
        }
        if (rc == -2) {
            g_body_err = 408
            break
        }
        if (rc == 0) break
        g_body_err = 400
        break
    }

    if (bt > 0 && oldto > 0) PROCINFO[svc, "READ_TIMEOUT"] = oldto
    if (g_body_err) return ""
    if (length(body) < clen) {
        g_body_err = 400
        return ""
    }
    return substr(body, 1, clen)
}

function http_normalize(path,    ns, segs, i) {
    while (index(path, "//") > 0) gsub(/\/\//, "/", path)
    while (index(path, "/./") > 0) gsub(/\/\.\//, "/", path)
    sub(/\/\.$/, "/", path)
    ns = split(path, segs, "/")
    for (i = 1; i <= ns; i++)
        if (segs[i] == "..") return ""
    if (substr(path, 1, 1) != "/") path = "/" path
    return path
}

function http_valid_host(h) {
    if (h == "") return 1
    if (h ~ /[[:cntrl:] \t]/) return 0
    if (h ~ /^\[[0-9A-Fa-f:.]+\](:[0-9]+)?$/) return 1
    if (h ~ /^[A-Za-z0-9._-]+(:[0-9]+)?$/) return 1
    return 0
}

function http_host_only(h,    i) {
    h = tolower(h)
    if (substr(h, 1, 1) == "[") {
        i = index(h, "]")
        if (i > 0) h = substr(h, 2, i - 2)
    } else {
        sub(/:[0-9]+$/, "", h)
    }
    sub(/\.$/, "", h)
    if (h == "" || h == "0.0.0.0" || h == "*") return "localhost"
    return h
}

function http_date() {
    return strftime("%a, %d %b %Y %H:%M:%S GMT", systime(), 1)
}

function http_send(svc, status, ctype, body, extra,    len, h, v, vt) {
    len = length(body)
    if (g_send_len >= 0) {
        len = g_send_len
        g_send_len = -1
    }
    g_status = status
    g_status_code = substr(status, 1, 3) + 0
    g_bytes = g_is_head ? 0 : len
    HTTP_SEND_FAILED = 0

    http_out(svc, "HTTP/1.1 " status)
    http_out(svc, "Date: " http_date())
    if (ctype != "") http_out(svc, "Content-Type: " ctype)
    for (h in extra) {
        if (h !~ /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/) continue
        v = extra[h]
        gsub(/[\r\n]/, "", v)
        vt = v
        gsub(/\t/, "", vt)
        if (vt ~ /[[:cntrl:]]/) gsub(/[[:cntrl:]]/, "?", v)
        http_out(svc, h ": " v)
    }
    http_out(svc, "Content-Length: " len)
    http_out(svc, "Connection: close")
    http_out(svc, "Server: " CONF["server","server_header"])
    http_out(svc, "")
    if (!g_is_head && !HTTP_SEND_FAILED) {
        ERRNO = ""
        printf "%s", body |& svc
        if (ERRNO != "") HTTP_SEND_FAILED = 1
    }
    if (HTTP_SEND_FAILED) g_bytes = 0
}

function http_send_simple(svc, status, ctype, body) {
    delete EXTRA
    http_send(svc, status, ctype, body, EXTRA)
}

function http_error(svc, code, msg,    body) {
    delete EXTRA
    body = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>" code "</title></head>\n"
    body = body "<body><h1>" code "</h1><p>" http_html_escape(msg) "</p></body></html>\n"
    http_send(svc, code, "text/html; charset=utf-8", body, EXTRA)
}

function http_redirect(svc, location,    body) {
    delete EXTRA
    EXTRA["Location"] = location
    body = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>301 Moved Permanently</title></head>\n"
    body = body "<body><h1>301 Moved Permanently</h1><p><a href=\"" http_html_escape(location) "\">" http_html_escape(location) "</a></p></body></html>\n"
    http_send(svc, "301 Moved Permanently", "text/html; charset=utf-8", body, EXTRA)
}

function http_log_access(dur,    target, line, ts, ip, bytes) {
    target = g_target
    gsub(/[[:cntrl:]]/, "?", target)
    gsub(/"/, "'", target)
    if (length(target) > 200) target = substr(target, 1, 200) "..."
    ts = strftime("%d/%b/%Y:%H:%M:%S %z", systime())
    ip = http_client_ip()
    bytes = (g_bytes + 0 == 0) ? "-" : g_bytes ""
    line = ip " - - [" ts "] \"" g_method " " target " " g_protocol "\" " g_status_code " " bytes " " sprintf("%.3f", dur)
    if (CONF["logging","access_log"] == "-" || CONF["logging","access_log"] == "")
        print line > "/dev/stderr"
    else {
        print line >> CONF["logging","access_log"]
        fflush(CONF["logging","access_log"])
    }
}

function http_client_ip(    xff, xri) {
    # gawk /inet/tcp exposes no peer address. Forwarded headers are only
    # trusted when http.trust_forwarded=on (set it only behind a trusted
    # proxy that overwrites them).
    if (CONF["http","trust_forwarded"] != "on") return "-"
    xff = H["x-forwarded-for"]
    if (xff != "") {
        sub(/,.*$/, "", xff)
        sub(/^[ \t]+/, "", xff)
        sub(/[ \t]+$/, "", xff)
        if (xff ~ /^[0-9a-fA-F:.]+$/) return xff
    }
    xri = H["x-real-ip"]
    if (xri ~ /^[0-9a-fA-F:.]+$/) return xri
    return "-"
}

function http_log_error(msg,    line, ts) {
    gsub(/[[:cntrl:]]/, "?", msg)
    ts = strftime("%d/%b/%Y:%H:%M:%S", systime())
    line = "[" ts "] " msg
    if (CONF["logging","error_log"] == "-" || CONF["logging","error_log"] == "")
        print line > "/dev/stderr"
    else {
        print line >> CONF["logging","error_log"]
        fflush(CONF["logging","error_log"])
    }
}

function http_html_escape(s,    r) {
    r = s
    gsub(/&/, "\\&amp;", r)
    gsub(/</, "\\&lt;", r)
    gsub(/>/, "\\&gt;", r)
    gsub(/"/, "\\&quot;", r)
    gsub(/'/, "\\&#39;", r)
    return r
}

function urldecode(s,    r, i, c, hex) {
    r = ""
    i = 1
    while (i <= length(s)) {
        c = substr(s, i, 1)
        if (c == "%" && substr(s, i + 1, 2) ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) {
            hex = substr(s, i + 1, 2)
            r = r sprintf("%c", strtonum("0x" hex))
            i += 3
        } else {
            r = r c
            i++
        }
    }
    return r
}

function ord(c) {
    if (c == "") return 0
    return index(BYTESTR, c)
}

function urlencode(s,    r, i, c, code) {
    r = ""
    i = 1
    while (i <= length(s)) {
        c = substr(s, i, 1)
        if (c ~ /[A-Za-z0-9_.~-]/) {
            r = r c
        } else {
            code = ord(c)
            if (code <= 0) code = 0
            r = r "%" sprintf("%02X", code)
        }
        i++
    }
    return r
}

function path_has_symlink(docroot, path,    segs, n, i, prefix, st) {
    n = split(path, segs, "/")
    prefix = docroot
    for (i = 1; i <= n; i++) {
        if (segs[i] == "" || segs[i] == ".") continue
        prefix = prefix "/" segs[i]
        if (stat(prefix, st) < 0) return 0
        if (st["type"] == "symlink") return 1
    }
    return 0
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
