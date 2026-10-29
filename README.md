## HAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHAHA

Thank you for trusting us! We appreciate it and declare that this project can be used in production!

Your ad could be here, but all that's here is a lot of wasted time (years), useless manipulations (years), and something else....

Web server in GNU gawk, tested only on:
```
GNU Awk 5.4.1, API 4.1, PMA Avon 8-g1, (GNU MPFR 4.2.2, GNU MP 6.3.0)
Copyright (C) 1989, 1991-2026 Free Software Foundation.
```

There are configs, static files, virtual hosts, TLS (not mandatory, can be omitted, requires socat/stunnel).

## What it can do, supposedly...

- `GET`, `HEAD`, `POST`... in a truncated format
- static files!!! and hardcoded `Content-Type`!!!
- Configurable list of index files
- Directory listing with enable/disable toggle
- `301` redirect to `/directory/`
- `ETag`, `Last-Modified`, `304 Not Modified`, `If-None-Match`,
  `If-Modified-Since`... pew-pew-pew....
- !!custom `404.html` page in the root, including for vhosts!!
- Some kind of protection against directory traversal, normalization of `//`, `/./`
- No symbolic links.............
- There are timeouts, stupid logic, lists, query strings, headers, body, socket reading
- Basic CGI/1.1 via a separate module, interpreter allowlist, !!timeout!!, output limitation, environment variables, body in stdin
- VHOST
- Reverse proxy!!! `[proxy:NAME]` with routes !!!
- CLF-like access+error.log journals
- TLS... via... `socat`/`stunnel`, certificates, yada yada, to make it cool, yada yada, if necessary you can even use nginx, yada yada
- `--check-config`, I don't think I need to say what it does, right?

## Requirements

- Linux/Unix (Windows is completely unsuitable, keep that in mind)
- gawk (GNU awk)
- gawk extensions `filefuncs`, `readfile`, `readdir`, `time`
- for CGI: `timeout`, `head`, `mktemp`, `coreutils`
- for TLS: `socat` or `stunnel`

## Quick start? Are you really sure you want this?
```sh
cd awk_web_server

mkdir -p www/files
printf '<h1>hello</h1>\n' > www/index.html
printf 'hello from awk\n' > www/about.txt
printf 'listing demo\n' > www/files/notes.txt
printf '<h1>custom 404</h1>\n' > www/404.html

./run.sh --check-config
./run.sh
```

## Examples of using this spawn of hell:

```sh
curl http://127.0.0.1:8080/about.txt
curl http://127.0.0.1:8080/files/
curl http://127.0.0.1:8080/nope
curl -I http://127.0.0.1:8080/about.txt
```

## Configuration

More details in `server.conf.example`

### Environment variables

`AWKWS_CONFIG`, `AWKWS_PORT`, `AWKWS_ROOT`, `AWKWS_HOST`, `AWKWS_INDEX`,
`AWKWS_DIRECTORY_LISTING`, `AWKWS_CGI`, `AWKWS_PROXY`,
`AWKWS_ACCESS_LOG`, `AWKWS_ERROR_LOG`, `AWKWS_MAX_REQUEST_LINE`, `AWKWS_MAX_HEADER_BYTES`,
`AWKWS_MAX_HEADERS`, `AWKWS_REQUEST_TIMEOUT`, `AWKWS_READ_TIMEOUT`,
`AWKWS_BODY_READ_TIMEOUT`, `AWKWS_TRUST_FORWARDED`,
`AWKWS_MAX_BODY_BYTES`.
Legacy `PORT` and `ROOT` are also supported.

CLI has the highest priority. The old form `./run.sh 9090 ./www` works.

## Virtual hosts

The `[vhost:NAME]` section maps the exact name from `Host` (without port, in lowercase) to the root. An unknown `Host` is served from `server.root`.

```ini
[vhost:example.local]
root = ./sites/example
index = index.html
directory_listing = off
```

Create `sites/example/index.html` and pass `Host: example.local`.

For a vhost, you can override `root`, `index`, `directory_listing`.
If `root` is not specified, `server.root` is inherited.
A custom `404.html` in the vhost root is picked up automatically.

## CGI

Built-in value is `off`;
Enabled via `[cgi] enabled = on` or `--cgi on|off`. Before enabling, create `cgi.root` (default `./cgi-bin`) and scripts.

- scripts reside only in `cgi.root`;
- URL starts with `cgi.prefix` (default `/cgi-bin`)
- symbolic links in the script path are rejected with `403`
- shebang is mandatory; the interpreter must be in `cgi.interpreters`, or a basename for `/usr/bin/env`
- the script doesn't have to be executable: the interpreter reads it as a file
- `POST` body is passed to stdin, `CONTENT_LENGTH`/`CONTENT_TYPE` in env
- CGI response: headers, empty line, body; `Status:` and `Location:` are supported
- `timeout` and `max_output_bytes` are applied via `lib/cgi_runner.sh` (`timeout -k`, `head -c`)
- when the output limit is exceeded, the size is checked first, so the response is `output exceeds`/`502`, instead of `exited with status 141`
- shebang `#!/usr/bin/env -S python3 -u` is supported
- timeout → `504`, non-zero code/broken response/output exceeded → `502`

CGI variables: `GATEWAY_INTERFACE`, `SERVER_PROTOCOL`, `SERVER_SOFTWARE`, `REQUEST_METHOD`, `REQUEST_URI`, `QUERY_STRING`, `SCRIPT_NAME`, `SCRIPT_FILENAME`, `DOCUMENT_ROOT`, `SERVER_NAME`, `SERVER_PORT`, `REMOTE_ADDR`, `CONTENT_LENGTH`, `CONTENT_TYPE`
`HTTP_*` for the rest of the headers.

`REMOTE_ADDR` is taken from `X-Forwarded-For`/`X-Real-IP` only when `http.trust_forwarded = on`; otherwise `-`: gawk `/inet` API does not return the client address, and `socat`/`stunnel` from the repository do not add headers.
If the client did not send `Host`, `SERVER_NAME` equals `localhost`, not `0.0.0.0`.

### Now for the sad POST

`getline` in gawk reads lines. Therefore, the POST body must end with a newline:

```sh
mkdir -p cgi-bin
cat > cgi-bin/echo.sh <<'EOF'
#!/bin/sh
printf 'Content-Type: text/plain\r\n\r\n'
printf 'Method: %s\n' "$REQUEST_METHOD"
cat
EOF
chmod +x cgi-bin/echo.sh

printf 'a=1&b=2\n' | curl -X POST --data-binary @- \
    http://127.0.0.1:8080/cgi-bin/echo.sh    # after [cgi] enabled = on
```

`curl -d 'a=1&b=2'` without `\n`, HTTP/1.1 will get `408` via
`body_read_timeout`: gawk waits for `\n`, and partial data is unavailable on timeout. This is a language limitation, not a configuration one. For arbitrary binary bodies, an external frontend `socat`/`nginx` is needed, which will read exactly `Content-Length` bytes.

## TLS

gawk doesn't know TLS. The `socat` or `stunnel` frontend terminates TLS on `tls.listen_port` and passes plain HTTP to `server.port`.
```ini
[tls]
enabled = on
listen_port = 8443
cert = ./certs/server.crt
key = ./certs/server.key
ca = ./certs/root_ca.crt
verify_client = off
protocols = TLSv1.2,TLSv1.3
ciphers =
proxy = auto
```

- `proxy = auto` chooses `stunnel` if it is installed, otherwise `socat`.
- Tested with `socat` and `stunnel 5.82`.
- `verify_client = off|optional|required`; `socat` doesn't know `optional` and treats it as `required`; for `optional|required`, `tls.ca` is needed.
- `tls.listen_port` must not match `server.port`.
- when `enabled = on`, `run.sh` starts the frontend and passes parameters to it via `-v dump_vars=1`; `--check-config` does not start the frontend.
- CGI receives the public port's `SERVER_PORT`, `HTTPS=on`, and `HTTP_X_FORWARDED_PROTO=https`.

## Reverse proxy

Routes are defined by `[proxy:NAME]` sections; the proxy itself is enabled in `[proxy] enabled = on` or via `--proxy on`.

```ini
[proxy]
enabled = on

[proxy:api]
host = *
path = /api/
upstream = http://127.0.0.1:3000
strip_prefix = /api
timeout = 10
max_response_bytes = 1048576
x_forwarded = on
rewrite_location = on
```

`GET /api/users?x=1` will go to `http://127.0.0.1:3000/users?x=1`.
The route is chosen *before* CGI and static files: first proxy, then CGI, then files.

- `host` - exact `Host` name or `*`; exact name wins.
- `path` - path prefix; longer prefix wins.
  `/api/` also matches exactly `/api`.
- `strip_prefix` - what to remove from the path before sending to upstream.
- `set_host` - `upstream` (default), `client`, or custom Host.
- `timeout` - upstream response read timeout, in seconds.
- `max_response_bytes` - upstream response body limit.
- `x_forwarded` - add `X-Forwarded-For`, `X-Forwarded-Host`, `X-Forwarded-Proto`.
- `rewrite_location` - rewrite absolute upstream `Location` to a relative path. This is safer than the absolute variant: the result does not depend on the client's `Host` and does not cause open redirect.
- if upstream declared `Content-Length: N`, but closed the connection earlier, the client will get `502`, not a short body with an incorrect `Content-Length`.

`GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS` are supported; request body is passed with `Content-Length`.

Proxy limitations:

- upstream is only `http://`; HTTPS to upstream is not supported;
- IPv6 literals in upstream are not supported;
- chunked upstream responses and `Content-Encoding` (gzip) → `502`;
- duplicate response headers (`Set-Cookie`) are collapsed into one;
- POST body from the client still requires a trailing `\n` or connection closure (gawk `getline` limitation);
- upstream response without `Content-Length` is read until connection closure, so the upstream must close the connection (we send `Connection: close`).

## Logs

Access log is written to `logging.access_log` (`-` = stderr), format:

```
- - - [29/Oct/2026:20:40:14 +0300] "GET /about.txt HTTP/1.1" 200 27 0.000
```

Client IP is taken from `X-Forwarded-For` or `X-Real-IP` only when `http.trust_forwarded = on`.
By default, this is `off`, because otherwise any client can spoof the IP in logs and CGI. Enable it only behind a controlled reverse proxy that overwrites these headers. `socat`/`stunnel` from the repository do not add them, so with a normal TLS launch, the log will have `-`. 
Next is time, request, code, body size (`-` for zero), duration in seconds.
Error log is a separate file, where CGI errors and other messages go.

## Static

- `ETag` is built from `mtime`, `size`, `inode`
- `If-None-Match` and `If-Modified-Since` yield `304`
- `HEAD` returns the same headers, but without the body
- directory listing escapes HTML and URL-encodes names
- symbolic links in the listing are marked and do not become links
- `404.html` in the root/vhost is used for `404`
- listing uses gawk `readdir`: on gawk 5.4.1 the record looks like `inode/name/type`); the parser also understands `name/type/inode`
- `Date` is added by the server; `Date` from upstream/CGI is discarded to avoid duplication
- `Range` is not supported

## Limitations

- one connection at a time at the gawk level;
- TLS is terminated by an external socat/stunnel; 
- HTTP/2 and ALPN `h2` are not supported, only HTTP/1.1
- no keep-alive, compression, `Range`, chunked requests
- reverse proxy does not support chunked/gzip from upstream, HTTPS and IPv6 upstream, duplicate response headers
- plain-HTTP backend listens on `0.0.0.0` (gawk `/inet` limitation)
- large file is read into memory entirely (`readfile`)
- POST body without trailing `\n` - see above
- timeout limits reading, but not writing: a very slow receiver of a large file can delay the server
- between `close(service)` and reopening the port, there is a microscopic window when the port is not listening; with extremely frequent new connections, a rare `connection refused` is possible
- `server.host` does not affect bind: gawk `/inet` always listens on `0.0.0.0`
- symbolic links are not supported: they are rejected with `403`
- TOCTOU: between symlink check and file reading, the link can theoretically be substituted.

## Security

- `..` and encoded variants are rejected
- header names are checked against RFC 7230 token; values with CR/LF and other CTLs are rejected with `400`;
- control characters in request line, path, and `%00` are rejected; `Host` is checked against host[:port] grammar, values with `/`, `@`, spaces, and CTLs yield `400`
- `X-Forwarded-For`/`X-Real-IP` are not trusted by default;
- `Location` during proxy rewrite becomes relative, so `Host` spoofing does not cause open redirect
- duplicate `Cookie`s are joined via `; `; 
- conflicting `Content-Length`s yield `400`
- each path component is checked for symlinks
- CGI is enabled explicitly and runs only allowed interpreters
- CGI scripts are limited to `cgi.root`, symlink scripts are forbidden
- CGI body and output are limited in size and time
- everything that comes from the client does not reach the shell without quoting
- if you release a TLS key, keep it in `600` mode and do not commit it to a public repository

## Tests

```sh
./tests/readdir.sh
./tests/smoke.sh
```

`smoke.sh` starts the server on a random high port and kills it via trap.

Something like that, I dunno what else to add lol.

Thank you for trusting us! We appreciate it and declare that this project.. well, how to say, probably shouldn't be used in production...
But if you do use it, please, share the code :3

---

## Known issues


19. Unknown config keys are ignored silently. A typo in `[vhost:NAME]`
    (for example `directory_listng` or `rrot`) produces no warning; the
    vhost just inherits `server.root`. Vhost validation only checks `root`
    (`lib/config.awk:260-276`); `index` and `directory_listing` in a vhost
    are not validated.
20. `server.port` is validated through `+0` (`lib/config.awk:215-217`):
    a value such as `8080abc` is accepted as 8080.
21. TLS `protocols` does not limit the maximum version. Both stunnel
    (`lib/tls_launcher.sh:60-64,77`) and socat (`:106-108`) only set the
    minimum version; with `protocols=TLSv1.2`, TLS 1.3 is still available.
    The list of values is not validated.
22. `verify_client = optional` in stunnel expands to
    `verifyChain=yes` + `verifyPeer=no`. According to stunnel, a client
    certificate is requested only with `verifyPeer=yes`, so "optional" may
    not actually request one.
23. TLS startup race: `sleep 0.3` before the PID check (`run.sh:216`);
    the front end may start accepting before the backend.
24. `eval "$tls_dump"` (`run.sh:182`): values are quoted with `shq()`, so
    injection is unlikely, but `eval` over configuration is unnecessary
    surface.
25. Log write errors are swallowed because of
    `PROCINFO["NONFATAL"] = 1` (`lib/http.awk:12,398`): an unwritable
    access-log path neither stops the server nor reports an explicit error.
26. Relative paths are resolved from the repository directory
    (`run.sh:14` does `cd`), not from the user's current directory. This can
    surprise with `--config`, `--root`, and `cert`/`key`.
27. Repository housekeeping: the project is licensed under
    GPL-3.0-or-later (see `LICENSE`), but there is still no `.gitignore`;
    CI/CD is intentionally not used.
28. `www/` is empty and `server.conf` is absent: the server starts after
    `--check-config`, but serves an empty directory listing.
29. `server.conf.example:65` references `CERTS.md`, which does not exist.
30. Help/README mismatch for environment variables: `run.sh` does not
    list `AWKWS_MAX_REQUEST_LINE`, `AWKWS_MAX_HEADER_BYTES`,
    `AWKWS_MAX_HEADERS`, `AWKWS_REQUEST_TIMEOUT`, `AWKWS_MAX_BODY_BYTES` in
    its environment list (`run.sh:42-45`), although the code and
    `README.md:72-77` support them.

## License

Copyright (C) 2026 awk_web_server contributors

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see <https://www.gnu.org/licenses/>.

SPDX-License-Identifier: GPL-3.0-or-later
