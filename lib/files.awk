# lib/files.awk
#
# Static files: index resolution, directory listing, ETag / 304,
# custom 404 page and MIME types.

function files_init() {
    MIME["html"] = "text/html; charset=utf-8"
    MIME["htm"] = "text/html; charset=utf-8"
    MIME["css"] = "text/css; charset=utf-8"
    MIME["js"] = "text/javascript; charset=utf-8"
    MIME["mjs"] = "text/javascript; charset=utf-8"
    MIME["json"] = "application/json; charset=utf-8"
    MIME["txt"] = "text/plain; charset=utf-8"
    MIME["md"] = "text/markdown; charset=utf-8"
    MIME["xml"] = "application/xml; charset=utf-8"
    MIME["csv"] = "text/csv; charset=utf-8"
    MIME["png"] = "image/png"
    MIME["jpg"] = "image/jpeg"
    MIME["jpeg"] = "image/jpeg"
    MIME["gif"] = "image/gif"
    MIME["svg"] = "image/svg+xml"
    MIME["ico"] = "image/x-icon"
    MIME["webp"] = "image/webp"
    MIME["avif"] = "image/avif"
    MIME["pdf"] = "application/pdf"
    MIME["zip"] = "application/zip"
    MIME["gz"] = "application/gzip"
    MIME["tar"] = "application/x-tar"
    MIME["bz2"] = "application/x-bzip2"
    MIME["xz"] = "application/x-xz"
    MIME["7z"] = "application/x-7z-compressed"
    MIME["woff"] = "font/woff"
    MIME["woff2"] = "font/woff2"
    MIME["ttf"] = "font/ttf"
    MIME["otf"] = "font/otf"
    MIME["eot"] = "application/vnd.ms-fontobject"
    MIME["wasm"] = "application/wasm"
    MIME["mp3"] = "audio/mpeg"
    MIME["ogg"] = "audio/ogg"
    MIME["wav"] = "audio/wav"
    MIME["mp4"] = "video/mp4"
    MIME["webm"] = "video/webm"
    MIME["bin"] = "application/octet-stream"
}

function files_join(root, path) {
    if (root == "/") return path
    return root path
}

function files_handle(svc, docroot, path, is_head,    full, st, ret, is_dir, idx, ies, i, cand, cst) {
    full = files_join(docroot, path)
    ret = stat(full, st)
    if (ret < 0) {
        files_not_found(svc, docroot)
        return
    }

    is_dir = 0
    if (st["type"] == "directory") {
        is_dir = 1
    } else if (st["type"] != "file") {
        http_error(svc, "403 Forbidden", "Special files are not served")
        return
    }

    if (is_dir) {
        if (substr(path, length(path), 1) != "/") {
            files_redirect_dir(svc)
            return
        }

        ies = files_indexes(g_host, idx)
        for (i = 1; i <= ies; i++) {
            cand = (full == "/" ? "" : full) "/" idx[i]
            if (stat(cand, cst) == 0 && cst["type"] == "file") {
                if (path_has_symlink(docroot, path idx[i])) {
                    http_error(svc, "403 Forbidden", "Symbolic links are not served")
                    return
                }
                files_send_file(svc, cand, cst)
                return
            }
        }

        if (is_dir) {
            if (files_listing_enabled(g_host))
                files_listing(svc, docroot, path, full)
            else
                http_error(svc, "403 Forbidden", "Directory listing is disabled")
            return
        }
    }

    files_send_file(svc, full, st)
}

function files_redirect_dir(svc,    loc, q, query) {
    loc = g_target
    q = index(loc, "?")
    query = ""
    if (q > 0) {
        query = substr(loc, q)
        loc = substr(loc, 1, q - 1)
    }
    if (substr(loc, length(loc), 1) != "/") loc = loc "/"
    http_redirect(svc, loc query)
}

function files_indexes(host, arr,    s, n, parts, i, v, c) {
    s = ""
    if ((host, "index") in VHOST_CONF) s = VHOST_CONF[host, "index"]
    if (s != "") {
        c = 0
        n = split(s, parts, ",")
        for (i = 1; i <= n; i++) {
            v = conf_trim(parts[i])
            if (v != "") arr[++c] = v
        }
        return c
    }
    for (i = 1; i <= INDEX_COUNT; i++) arr[i] = INDEXES[i]
    return INDEX_COUNT
}

function files_listing_enabled(host,    v) {
    if ((host, "directory_listing") in VHOST_CONF)
        v = VHOST_CONF[host, "directory_listing"]
    else
        v = CONF["server", "directory_listing"]
    return (v == "on")
}

function files_mime(ext) {
    ext = tolower(ext)
    if (ext in MIME) return MIME[ext]
    return "application/octet-stream"
}

function files_extension(name,    base, dot) {
    base = name
    sub(/.*\//, "", base)
    dot = 0
    if (base ~ /\./) {
        sub(/.*\./, "", base)
        return base
    }
    return ""
}

function files_send_file(svc, full, st,    etag, lm, body, ctype, ext) {
    etag = files_etag(st)
    lm = strftime("%a, %d %b %Y %H:%M:%S GMT", st["mtime"] + 0, 1)

    if (H["if-none-match"] != "") {
        if (files_etag_match(H["if-none-match"], etag)) {
            files_send_304(svc, etag, lm)
            return
        }
    } else if (files_ims_match(H["if-modified-since"], st["mtime"] + 0, lm)) {
        files_send_304(svc, etag, lm)
        return
    }

    ERRNO = ""
    body = readfile(full)
    if (body == "" && ERRNO != "") {
        http_error(svc, "500 Internal Server Error", "Could not read file")
        return
    }

    ext = files_extension(full)
    ctype = files_mime(ext)

    delete EXTRA
    EXTRA["ETag"] = etag
    EXTRA["Last-Modified"] = lm
    http_send(svc, "200 OK", ctype, body, EXTRA)
}

function files_etag(st) {
    return sprintf("\"%x-%x-%x\"", st["mtime"] + 0, st["size"] + 0, st["ino"] + 0)
}

function files_etag_match(header, etag,    n, parts, i, t) {
    if (header ~ /^[ \t]*\*[ \t]*$/) return 1
    n = split(header, parts, ",")
    for (i = 1; i <= n; i++) {
        t = parts[i]
        sub(/^[ \t]+/, "", t)
        sub(/[ \t]+$/, "", t)
        sub(/^W\//, "", t)
        if (t == etag) return 1
    }
    return 0
}

function files_ims_match(header, mtime, lm,    t, off) {
    if (header == "") return 0
    if (header == lm) return 1
    t = strptime(header, "%a, %d %b %Y %H:%M:%S GMT")
    if (t < 0) return 0
    off = files_tz_offset(mtime)
    return (mtime <= t + off)
}

function files_tz_offset(ts,    z, sign) {
    z = strftime("%z", ts)
    if (length(z) != 5) return 0
    sign = (substr(z, 1, 1) == "-") ? -1 : 1
    return sign * (substr(z, 2, 2) * 3600 + substr(z, 4, 2) * 60)
}

function files_send_304(svc, etag, lm) {
    g_status = "304 Not Modified"
    g_status_code = 304
    g_bytes = 0
    HTTP_SEND_FAILED = 0
    http_out(svc, "HTTP/1.1 304 Not Modified")
    http_out(svc, "Date: " http_date())
    http_out(svc, "ETag: " etag)
    http_out(svc, "Last-Modified: " lm)
    http_out(svc, "Connection: close")
    http_out(svc, "Server: " CONF["server", "server_header"])
    http_out(svc, "")
}

function files_not_found(svc, docroot,    p, st, body) {
    p = docroot "/404.html"
    if (docroot == "/") p = "/404.html"
    if (stat(p, st) == 0 && st["type"] == "file" &&
        !path_has_symlink(docroot, "/404.html")) {
        ERRNO = ""
        body = readfile(p)
        if (body != "" || ERRNO == "") {
            delete EXTRA
            http_send(svc, "404 Not Found", "text/html; charset=utf-8", body, EXTRA)
            return
        }
    }
    http_error(svc, "404 Not Found", "Not found")
}

function files_listing(svc, docroot, path, dir,    line, rc, f, n, name, t, size,
                       ent, st, body, title, ename, old, count, target, oldrs) {
    target = dir
    sub(/\/+$/, "", target)
    if (target == "") target = "/"

    delete ENT
    delete ESIZE
    oldrs = RS
    RS = "\n"
    while (1) {
        ERRNO = ""
        rc = (getline line < dir)
        if (rc <= 0) break
        # gawk 5.4.1 returns inode/name/type here (verified with and
        # without PROCINFO["readdir_override"]). Some builds/versions
        # are documented as name/type/inode, so accept both shapes.
        n = split(line, f, "/")
        if (n < 3) continue
        if (f[3] ~ /^[bcdflps]$/ && f[1] ~ /^[0-9]+$/) {
            name = f[2]
            t = f[3]
        } else if (f[2] ~ /^[bcdflps]$/) {
            name = f[1]
            t = f[2]
        } else {
            continue
        }
        if (name == "." || name == ".." || name == "") continue
        ENT[name] = t
        ESIZE[name] = ""
        if (t == "f") {
            if (stat(target "/" name, st) == 0) ESIZE[name] = st["size"] + 0
        }
    }
    RS = oldrs
    close(dir)
    if (rc < 0 && ERRNO != "") {
        http_error(svc, "403 Forbidden", "Cannot read directory")
        return
    }

    body = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>Index of "
    body = body http_html_escape(path) "</title></head>\n<body><h1>Index of "
    body = body http_html_escape(path) "</h1><hr><pre>\n"
    body = body "<a href=\"../\">../</a>\n"

    count = 0
    old = PROCINFO["sorted_in"]
    PROCINFO["sorted_in"] = "@ind_str_asc"
    for (name in ENT) {
        count++
        ename = urlencode(name)
        t = ENT[name]
        if (t == "l") {
            body = body http_html_escape(name) "\t[symlink - not served]\n"
        } else if (t == "d") {
            body = body "<a href=\"" ename "/\">" http_html_escape(name) "/</a>\n"
        } else {
            body = body "<a href=\"" ename "\">" http_html_escape(name) "</a>\t" ESIZE[name] " bytes\n"
        }
    }
    if (old == "") delete PROCINFO["sorted_in"]
    else PROCINFO["sorted_in"] = old

    if (count == 0) body = body "(empty directory)\n"
    body = body "</pre><hr></body></html>\n"

    delete EXTRA
    http_send(svc, "200 OK", "text/html; charset=utf-8", body, EXTRA)
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
