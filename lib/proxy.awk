# lib/proxy.awk
#
# Reverse proxy: match (host, path-prefix) -> upstream, forward the
# request, relay the response. Supports GET/HEAD/POST/PUT/PATCH/DELETE/
# OPTIONS; request bodies are forwarded with Content-Length.
# Upstream responses must be Content-Length or EOF-terminated; chunked
# and compressed responses are rejected (see README).

function proxy_init() {
    PROXY_ENABLED = "off"
    PROXY_COUNT = 0
    PROXY_SEND_FAILED = 0
}

# "http://host:port/path" -> out["scheme"|"host"|"port"|"path"]
function proxy_parse_upstream(url, out,    scheme, rest, slash, hostport, i, colon, host, port, path) {
    scheme = "http"
    rest = url
    if (match(rest, /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)) {
        scheme = tolower(substr(rest, 1, RLENGTH - 3))
        rest = substr(rest, RLENGTH + 1)
    }
    slash = index(rest, "/")
    if (slash > 0) {
        hostport = substr(rest, 1, slash - 1)
        path = substr(rest, slash)
    } else {
        hostport = rest
        path = "/"
    }
    # IPv6 literal [::1]:80 -- набросок не поддерживает, только пометим
    if (substr(hostport, 1, 1) == "[") {
        out["scheme"] = scheme
        out["host"] = ""
        out["port"] = ""
        out["path"] = path
        return
    }
    colon = 0
    for (i = length(hostport); i >= 1; i--) {
        if (substr(hostport, i, 1) == ":") { colon = i; break }
    }
    if (colon > 0) {
        host = substr(hostport, 1, colon - 1)
        port = substr(hostport, colon + 1)
    } else {
        host = hostport
        port = (scheme == "https" ? "443" : "80")
    }
    out["scheme"] = scheme
    out["host"] = host
    out["port"] = port
    out["path"] = path
}

function proxy_finalize(    sec, name, url, out, i) {
    delete PROXY_RULES
    PROXY_COUNT = 0
    PROXY_ENABLED = CONF["proxy","enabled"]

    for (sec in PROXY_SECTIONS) {
        name = substr(sec, 7)
        if (name == "") continue
        url = CONF[sec, "upstream"]

        # Defaults for optional route keys.
        if (CONF[sec, "host"] == "")              CONF[sec, "host"] = "*"
        if (CONF[sec, "path"] == "")              CONF[sec, "path"] = "/"
        if (CONF[sec, "strip_prefix"] == "")      CONF[sec, "strip_prefix"] = ""
        if (CONF[sec, "set_host"] == "")          CONF[sec, "set_host"] = "upstream"
        if (CONF[sec, "timeout"] == "")           CONF[sec, "timeout"] = "10"
        if (CONF[sec, "max_response_bytes"] == "") CONF[sec, "max_response_bytes"] = "1048576"
        if (CONF[sec, "x_forwarded"] == "")       CONF[sec, "x_forwarded"] = "on"
        if (CONF[sec, "rewrite_location"] == "")  CONF[sec, "rewrite_location"] = "on"

        delete out
        proxy_parse_upstream(url, out)

        PROXY_RULES[++PROXY_COUNT] = name
        PROXY_CONF[name, "host"]              = tolower(CONF[sec, "host"])
        PROXY_CONF[name, "path"]              = CONF[sec, "path"]
        PROXY_CONF[name, "strip_prefix"]      = CONF[sec, "strip_prefix"]
        PROXY_CONF[name, "set_host"]          = CONF[sec, "set_host"]
        PROXY_CONF[name, "timeout"]           = CONF[sec, "timeout"]
        PROXY_CONF[name, "max_response_bytes"]= CONF[sec, "max_response_bytes"]
        PROXY_CONF[name, "x_forwarded"]       = CONF[sec, "x_forwarded"]
        PROXY_CONF[name, "rewrite_location"]  = CONF[sec, "rewrite_location"]
        PROXY_CONF[name, "upstream_scheme"]   = out["scheme"]
        PROXY_CONF[name, "upstream_host"]     = out["host"]
        PROXY_CONF[name, "upstream_port"]     = out["port"]
        PROXY_CONF[name, "upstream_path"]     = out["path"]
    }
}

function proxy_validate(    i, sec, name, out, v) {
    if (CONF["proxy","enabled"] != "on" && CONF["proxy","enabled"] != "off") {
        conf_error("proxy.enabled must be on|off")
        return
    }
    if (CONF["proxy","enabled"] != "on") return

    if (PROXY_COUNT == 0) {
        conf_error("proxy.enabled=on but no [proxy:NAME] sections")
        return
    }

    for (i = 1; i <= PROXY_COUNT; i++) {
        name = PROXY_RULES[i]
        sec = "proxy:" name
        delete out
        proxy_parse_upstream(CONF[sec, "upstream"], out)

        if (out["host"] == "")
            conf_error("[" sec "] upstream has no host (IPv6 literals are not supported)")
        if (out["scheme"] != "http")
            conf_error("[" sec "] upstream scheme must be http; https to upstream is not supported")
        if (out["port"] !~ /^[0-9]+$/ || out["port"] + 0 < 1 || out["port"] + 0 > 65535)
            conf_error("[" sec "] upstream port must be 1..65535")

        if (CONF[sec, "host"] == "")
            conf_error("[" sec "] host is required (use * to match any host)")
        if (CONF[sec, "path"] == "" || substr(CONF[sec, "path"], 1, 1) != "/")
            conf_error("[" sec "] path must start with / (use / for catch-all)")
        if (CONF[sec, "strip_prefix"] != "" && substr(CONF[sec, "strip_prefix"], 1, 1) != "/")
            conf_error("[" sec "] strip_prefix must start with /")

        v = CONF[sec, "timeout"]
        if (v !~ /^[0-9]+$/ || v + 0 < 1)
            conf_error("[" sec "] timeout must be a positive integer")
        v = CONF[sec, "max_response_bytes"]
        if (v !~ /^[0-9]+$/ || v + 0 < 1)
            conf_error("[" sec "] max_response_bytes must be a positive integer")

        v = CONF[sec, "x_forwarded"]
        if (v != "" && v != "on" && v != "off")
            conf_error("[" sec "] x_forwarded must be on|off")
        v = CONF[sec, "rewrite_location"]
        if (v != "" && v != "on" && v != "off")
            conf_error("[" sec "] rewrite_location must be on|off")
    }
}

# Длиннее path + точный host выигрывают; * -- слабее точного host.
function proxy_match(host, path,    i, name, h, p, score, best, best_score) {
    best = ""
    best_score = -1
    for (i = 1; i <= PROXY_COUNT; i++) {
        name = PROXY_RULES[i]
        h = PROXY_CONF[name, "host"]
        p = PROXY_CONF[name, "path"]
        if (h != "*" && h != host) continue
        if (index(path, p) != 1 &&
            path != substr(p, 1, length(p) - 1)) continue
        score = length(p) * 2 + (h == "*" ? 0 : 1)
        if (score > best_score) {
            best_score = score
            best = name
        }
    }
    return best
}

function proxy_canon_header(h,    n, parts, i, r) {
    n = split(h, parts, "-")
    r = ""
    for (i = 1; i <= n; i++) {
        if (i > 1) r = r "-"
        r = r toupper(substr(parts[i], 1, 1)) tolower(substr(parts[i], 2))
    }
    return r
}

function proxy_send(sock, s) {
    if (PROXY_SEND_FAILED) return
    ERRNO = ""
    print s |& sock
    if (ERRNO != "") PROXY_SEND_FAILED = 1
}

function proxy_sendf(sock, s) {
    if (PROXY_SEND_FAILED) return
    ERRNO = ""
    printf "%s", s |& sock
    if (ERRNO != "") PROXY_SEND_FAILED = 1
}

function proxy_handle(svc, name, method, path, query,    up_host, up_port, up_path, req_path, req_query,
                      sock, timeout, max_out, status_line, status, line, rc, h, hname, hval, clen, te,
                      i, body, deadline, bytes, ctype, loc, old, xff, ce, pub,
                      uhcount, uhbytes, hvt, clv) {

    pub = H["host"]
    if (pub == "") pub = g_host

    up_host = PROXY_CONF[name, "upstream_host"]
    up_port = PROXY_CONF[name, "upstream_port"]
    up_path = PROXY_CONF[name, "upstream_path"]
    timeout = PROXY_CONF[name, "timeout"] + 0;             if (timeout <= 0) timeout = 10
    max_out = PROXY_CONF[name, "max_response_bytes"] + 0;  if (max_out <= 0) max_out = 1048576

    # путь к upstream: strip_prefix, потом склейка с upstream_path
    req_path = path
    if (PROXY_CONF[name, "strip_prefix"] != "" &&
        index(req_path, PROXY_CONF[name, "strip_prefix"]) == 1) {
        req_path = substr(req_path, length(PROXY_CONF[name, "strip_prefix"]) + 1)
        if (substr(req_path, 1, 1) != "/") req_path = "/" req_path
    }
    if (up_path != "/" && up_path != "") {
        sub(/\/+$/, "", up_path)
        req_path = up_path req_path
    }
    req_query = (query != "" ? "?" query : "")

    sock = "/inet/tcp/0/" up_host "/" up_port
    PROCINFO[sock, "RETRY"] = 1
    PROCINFO[sock, "READ_TIMEOUT"] = timeout * 1000
    PROCINFO[sock, "NONFATAL"] = 1
    PROXY_SEND_FAILED = 0

    # --- запрос ---
    proxy_send(sock, method " " req_path req_query " HTTP/1.1")

    h = PROXY_CONF[name, "set_host"]
    if (h == "" || h == "upstream")
        proxy_send(sock, "Host: " up_host (up_port == "80" ? "" : ":" up_port))
    else if (h == "client")
        proxy_send(sock, "Host: " pub)
    else
        proxy_send(sock, "Host: " h)

    if (PROXY_CONF[name, "x_forwarded"] == "on") {
        xff = http_client_ip()
        if (xff == "-") xff = "unknown"
        proxy_send(sock, "X-Forwarded-For: " xff)
        proxy_send(sock, "X-Forwarded-Host: " pub)
        proxy_send(sock, "X-Forwarded-Proto: " (TLS_STATE == "on" ? "https" : "http"))
    }

    for (i in H) {
        if (i == "host" || i == "connection" || i == "keep-alive" ||
            i == "proxy-connection" || i == "te" || i == "trailer" ||
            i == "transfer-encoding" || i == "upgrade" || i == "accept-encoding" ||
            i == "content-length" || i == "expect" ||
            i == "x-forwarded-for" || i == "x-forwarded-host" ||
            i == "x-forwarded-proto")
            continue
        proxy_send(sock, proxy_canon_header(i) ": " H[i])
    }
    proxy_send(sock, "Accept-Encoding: identity")
    if (method != "GET" && method != "HEAD")
        proxy_send(sock, "Content-Length: " length(BODY))
    proxy_send(sock, "Connection: close")
    proxy_send(sock, "")
    if (method != "GET" && method != "HEAD" && length(BODY) > 0)
        proxy_sendf(sock, BODY)

    if (PROXY_SEND_FAILED) {
        close(sock)
        http_error(svc, "502 Bad Gateway", "Cannot reach upstream")
        return
    }

    # --- статус ---
    ERRNO = ""
    rc = (sock |& getline)
    if (rc == -2) { close(sock); http_error(svc, "504 Gateway Timeout", "Upstream status line timed out"); return }
    if (rc <= 0)  { close(sock); http_error(svc, "502 Bad Gateway", "Cannot reach upstream"); return }
    status_line = $0
    sub(/\r$/, "", status_line)
    if (status_line ~ /[[:cntrl:]]/ ||
        status_line !~ /^HTTP\/1\.[01] [0-9][0-9][0-9]/) {
        close(sock)
        http_error(svc, "502 Bad Gateway", "Upstream returned a malformed status line")
        return
    }
    status = substr(status_line, 10)

    # --- заголовки ---
    delete UP_H
    clen = -1
    te = ""
    ce = ""
    uhcount = 0
    uhbytes = 0
    deadline = systime() + timeout
    while (1) {
        ERRNO = ""
        rc = (sock |& getline)
        if (rc == -2) { close(sock); http_error(svc, "504 Gateway Timeout", "Upstream headers timed out"); return }
        if (rc < 0)  { close(sock); http_error(svc, "502 Bad Gateway", "Upstream read error"); return }
        if (rc == 0) break
        line = $0
        sub(/\r$/, "", line)
        if (line == "") break
        uhcount++
        uhbytes += length(line) + 1
        if (uhcount > CONF["http","max_headers"] + 0 ||
            uhbytes > CONF["http","max_header_bytes"] + 0) {
            close(sock)
            http_error(svc, "502 Bad Gateway", "Upstream headers are too large")
            return
        }
        h = index(line, ":")
        if (h == 0) continue
        hname = tolower(substr(line, 1, h - 1))
        hval = substr(line, h + 1)
        sub(/^[ \t]+/, "", hval)
        sub(/[ \t\r]+$/, "", hval)
        if (hname !~ /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/) {
            close(sock)
            http_error(svc, "502 Bad Gateway", "Malformed upstream header name")
            return
        }
        hvt = hval
        gsub(/\t/, "", hvt)
        if (hvt ~ /[[:cntrl:]]/) {
            close(sock)
            http_error(svc, "502 Bad Gateway", "Invalid control character in upstream header")
            return
        }
        if (hname == "content-length") {
            if (hval !~ /^[0-9]+$/) {
                close(sock)
                http_error(svc, "502 Bad Gateway", "Invalid upstream Content-Length")
                return
            }
            clv = hval + 0
            if (clen >= 0 && clen != clv) {
                close(sock)
                http_error(svc, "502 Bad Gateway", "Conflicting upstream Content-Length")
                return
            }
            clen = clv
        }
        else if (hname == "transfer-encoding") te = tolower(hval)
        else if (hname == "content-encoding") ce = tolower(hval)
        else UP_H[hname] = hval
        if (systime() > deadline) {
            close(sock)
            http_error(svc, "504 Gateway Timeout", "Upstream headers took too long")
            return
        }
    }

    if (te ~ /chunked/) {
        close(sock)
        http_error(svc, "502 Bad Gateway", "Chunked upstream responses are not supported")
        return
    }
    if (ce != "" && ce != "identity") {
        close(sock)
        http_error(svc, "502 Bad Gateway", "Compressed upstream responses are not supported")
        return
    }

    # --- тело ---
    body = ""
    if (method == "HEAD") {
        body = ""
    } else if (clen >= 0) {
        while (length(body) < clen) {
            ERRNO = ""
            rc = (sock |& getline)
            if (rc == -2) { close(sock); http_error(svc, "504 Gateway Timeout", "Upstream body timed out"); return }
            if (rc < 0)  { close(sock); http_error(svc, "502 Bad Gateway", "Upstream read error"); return }
            if (rc == 0) break
            body = body $0 RT
            if (length(body) > max_out + 1) {
                close(sock)
                http_error(svc, "502 Bad Gateway", "Upstream response exceeds proxy.max_response_bytes")
                return
            }
        }
        if (length(body) < clen) {
            close(sock)
            http_error(svc, "502 Bad Gateway", "Upstream closed before sending the full body")
            return
        }
        body = substr(body, 1, clen)
    } else {
        while (1) {
            ERRNO = ""
            rc = (sock |& getline)
            if (rc == -2) { close(sock); http_error(svc, "504 Gateway Timeout", "Upstream body timed out"); return }
            if (rc < 0)  { close(sock); http_error(svc, "502 Bad Gateway", "Upstream read error"); return }
            if (rc == 0) break
            body = body $0 RT
            if (length(body) > max_out + 1) {
                close(sock)
                http_error(svc, "502 Bad Gateway", "Upstream response exceeds proxy.max_response_bytes")
                return
            }
        }
        sub(/\n$/, "", body)   # лишний \n от последнего getline
    }
    close(sock)

    # --- ответ клиенту ---
    delete EXTRA
    ctype = ""
    for (h in UP_H) {
        if (h == "connection" || h == "keep-alive" || h == "server" ||
            h == "transfer-encoding" || h == "content-length" ||
            h == "proxy-authenticate" || h == "proxy-authorization" ||
            h == "content-encoding" || h == "date")
            continue
        if (h == "content-type") { ctype = UP_H[h]; continue }
        EXTRA[proxy_canon_header(h)] = UP_H[h]
    }

    if (PROXY_CONF[name, "rewrite_location"] == "on" && ("location" in UP_H)) {
        loc = UP_H["location"]
        old = PROXY_CONF[name, "upstream_scheme"] "://" PROXY_CONF[name, "upstream_host"] \
              (PROXY_CONF[name, "upstream_port"] == "80" ? "" : ":" PROXY_CONF[name, "upstream_port"])
        if (index(loc, old) == 1) {
            # Relative Location avoids Host-header open redirects.
            loc = substr(loc, length(old) + 1)
            if (substr(loc, 1, 1) != "/") loc = "/" loc
            EXTRA["Location"] = loc
        } else {
            EXTRA["Location"] = loc
        }
    }

    if (method == "HEAD" && clen >= 0)
        g_send_len = clen
    http_send(svc, status, ctype, body, EXTRA)
}

function proxy_print(    i, name) {
    if (PROXY_ENABLED != "on") { print "  proxy: off"; return }
    print "  proxy: on"
    for (i = 1; i <= PROXY_COUNT; i++) {
        name = PROXY_RULES[i]
        print "    [" name "] " PROXY_CONF[name,"host"] PROXY_CONF[name,"path"] \
              " -> " PROXY_CONF[name,"upstream_scheme"] "://" \
              PROXY_CONF[name,"upstream_host"] ":" PROXY_CONF[name,"upstream_port"] \
              PROXY_CONF[name,"upstream_path"]
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
