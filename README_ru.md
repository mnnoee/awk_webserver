## АХАХАХАХАХАХАХАХАХАХАХХАХАХАХАХАХХАХАХАХАХАХАХАХХАХАХАХАХАХАХАХХАХА

Спасибо, что доверяете нам! Мы ценим это и заявляем, этот проект можно использовать на продакшене!

Тут могла бы быть ваша реклама, но всё что тут есть это много потраченного времени (годы), бесполезных махинаций (годы) и что-то ещё....

Веб сервер на GNU gawk, проверялся только на:
```
GNU Awk 5.4.1, API 4.1, PMA Avon 8-g1, (GNU MPFR 4.2.2, GNU MP 6.3.0)
Copyright (C) 1989, 1991-2026 Free Software Foundation.
```

Есть конфиги, статика, виртуальные хосты, TLS (не обязательно, можно не использовать, необходим socat/stunel)

## Что оно может, вроде как...

- `GET`, `HEAD`, `POST`... в урезанном формате
- статика!!! и захардкоженный `Content-Type`!!!
- Настраиваемый список index-файлов
- Есть листинг каталогов с включением/выключением
- редирект `301` на `/каталог/`
- `ETag`, `Last-Modified`, `304 Not Modified`, `If-None-Match`,
  `If-Modified-Since`... пу-пу-пу....
- !!пользовательская страница `404.html` в корне, в том числе для vhost!!
- Кое какая защита от убегания из каталога, нормализация `//`, `/./`
- Никаких символические ссылок.............
- Там, таймауты, глупая логика, лиситы, строка запроса, заголовки, тело, чтение сокета
- Базовый CGI/1.1 через отдельный модуль, allowlist интерпретаторов, !!таймаут!!,
  ограничение вывода, переменные окружения, тело в stdin
- VHOST
- Обратный прокси!!! `[proxy:NAME]` с маршрутами !!!
- CLF-подобные журналы access+error.log
- TLS... через... `socat`/`stunnel`, сертификаты, дада, чтобы было классно, дада, по необходимости можно и nginx использовать, дада
- `--check-config`, думаю не нужно говорить что оно делает, верно?

## Требования

- Linux/Unix (Windows вообще не подходит, учтите)
- gawk (GNU awk)
- расширения gawk `filefuncs`, `readfile`, `readdir`, `time`
- для CGI: `timeout`, `head`, `mktemp`, `coreutils`
- для TLS: `socat` или `stunnel`

## Быстрый старт? А ты точно хочешь этого?
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

## Примеры юзанья этого исчадья ада:

```sh
curl http://127.0.0.1:8080/about.txt
curl http://127.0.0.1:8080/files/
curl http://127.0.0.1:8080/nope
curl -I http://127.0.0.1:8080/about.txt
```

## Конфигурация

Подробнее в `server.conf.example`

### Переменные окружения

`AWKWS_CONFIG`, `AWKWS_PORT`, `AWKWS_ROOT`, `AWKWS_HOST`, `AWKWS_INDEX`,
`AWKWS_DIRECTORY_LISTING`, `AWKWS_CGI`, `AWKWS_PROXY`,
`AWKWS_ACCESS_LOG`, `AWKWS_ERROR_LOG`, `AWKWS_MAX_REQUEST_LINE`, `AWKWS_MAX_HEADER_BYTES`,
`AWKWS_MAX_HEADERS`, `AWKWS_REQUEST_TIMEOUT`, `AWKWS_READ_TIMEOUT`,
`AWKWS_BODY_READ_TIMEOUT`, `AWKWS_TRUST_FORWARDED`,
`AWKWS_MAX_BODY_BYTES`.
Устаревшие `PORT` и `ROOT` тоже поддерживаются.

CLI имеет наивысший приоритет. Старая форма `./run.sh 9090 ./www` работает.

## Виртуальные хосты

Секция `[vhost:ИМЯ]` сопоставляет точное имя из `Host` (без порта, в
нижнем регистре) с корнем. Неизвестный `Host` обслуживается из
`server.root`.

```ini
[vhost:example.local]
root = ./sites/example
index = index.html
directory_listing = off
```

Создайте `sites/example/index.html` и передайте `Host: example.local`.

Для vhost можно переопределить `root`, `index`, `directory_listing`.
Если `root` не указан, наследуется `server.root`.
Своя `404.html` в корне vhost подхватывается автоматически.

## CGI

Встроенное значение - `off`;
Включается через `[cgi] enabled = on` или `--cgi on|off`. Перед включением создайте `cgi.root` (по умолчанию `./cgi-bin`) и скрипты.

- скрипты лежат только в `cgi.root`;
- URL начинается с `cgi.prefix` (по умолчанию `/cgi-bin`)
- символические ссылки в пути скрипта отклоняются с `403`
- shebang обязателен; интерпретатор должен быть в `cgi.interpreters`, либо basename для `/usr/bin/env`
- скрипт не обязан быть исполняемым: интерпретатор читает его как файл
- тело `POST` передаётся в stdin, `CONTENT_LENGTH`/`CONTENT_TYPE` в env
- ответ CGI: заголовки, пустая строка, тело; поддерживаются `Status:` и `Location:`
- `timeout` и `max_output_bytes` применяются через `lib/cgi_runner.sh` (`timeout -k`, `head -c`)
- при превышении лимита вывода сначала проверяется размер, поэтому ответ - `output exceeds`/`502`, вместо `exited with status 141`
- shebang `#!/usr/bin/env -S python3 -u` поддерживается
- таймаут → `504`, ненулевой код/битый ответ/превышение вывода → `502`

Переменные CGI: `GATEWAY_INTERFACE`, `SERVER_PROTOCOL`, `SERVER_SOFTWARE`, `REQUEST_METHOD`, `REQUEST_URI`, `QUERY_STRING`, `SCRIPT_NAME`, `SCRIPT_FILENAME`, `DOCUMENT_ROOT`, `SERVER_NAME`, `SERVER_PORT`, `REMOTE_ADDR`,`CONTENT_LENGTH`, `CONTENT_TYPE`
`HTTP_*` для остальных заголовков.

`REMOTE_ADDR` берётся из `X-Forwarded-For`/`X-Real-IP` только при `http.trust_forwarded = on`; иначе `-`: API gawk `/inet` не отдаёт адрес клиента, а `socat`/`stunnel` из репозитория заголовки не добавляют.
Если клиент не прислал `Host`, `SERVER_NAME` равен `localhost`, а не `0.0.0.0`.

### Типерь к печальному POST

`getline` в gawk читает строки. Поэтому тело POST должно заканчиваться переводом строки:

```
mkdir -p cgi-bin
cat > cgi-bin/echo.sh <<'EOF'
#!/bin/sh
printf 'Content-Type: text/plain\r\n\r\n'
printf 'Method: %s\n' "$REQUEST_METHOD"
cat
EOF
chmod +x cgi-bin/echo.sh

printf 'a=1&b=2\n' | curl -X POST --data-binary @- \
    http://127.0.0.1:8080/cgi-bin/echo.sh    # после [cgi] enabled = on
```

`curl -d 'a=1&b=2'` без `\n`, HTTP/1.1 получит `408` через
`body_read_timeout`: gawk ждёт `\n`, а частичные данные при таймауте недоступны. Это ограничение языка, а не конфигурации. Для произвольных бинарных тел нужен внешний фронт `socat`/`nginx`, который прочитает ровно `Content-Length` байт.

## TLS

gawk не умеет TLS. Фронт `socat` или `stunnel` терминирует TLS на `tls.listen_port` и передаёт обычный HTTP на `server.port`.
```
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

- `proxy = auto` выбирает `stunnel`, если он установлен, иначе `socat`.
- Проверено с `socat` и `stunnel 5.82`.
- - `verify_client = off|optional|required`; `socat` не умеет `optional` и трактует его как `required`; при `optional|required` нужен `tls.ca`.
- `tls.listen_port` не должен совпадать с `server.port`.
- при `enabled = on` `run.sh` поднимает фронт и передаёт ему параметры через `-v dump_vars=1`; `--check-config` фронт не запускает.
- CGI получает `SERVER_PORT` публичного порта, `HTTPS=on` и `HTTP_X_FORWARDED_PROTO=https`.

## Reverse proxy

Маршруты задаются секциями `[proxy:NAME]`; сам прокси включается в `[proxy] enabled = on` или через `--proxy on`.

```
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

`GET /api/users?x=1` уйдёт на `http://127.0.0.1:3000/users?x=1`.
Маршрут выбирается*до CGI и статики: сначала proxy, потом CGI, потом файлы.

- `host` - точное имя `Host` или `*`; точное имя выигрывает.
- `path` - префикс пути; более длинный префикс выигрывает.
  `/api/` также матчит ровно `/api`.
- `strip_prefix` - что убрать из пути перед отправкой upstream.
- `set_host` - `upstream` (по умолчанию), `client` или свой Host.
- `timeout` - таймаут чтения ответа upstream, секунды.
- `max_response_bytes` - предел тела ответа upstream.
- `x_forwarded` - добавить `X-Forwarded-For`, `X-Forwarded-Host`,
  `X-Forwarded-Proto`.
- `rewrite_location` - переписать absolute `Location` upstream на относительный путь. Это безопаснее absolute-варианта: результат не зависит от клиентского `Host` и не даёт open redirect.
- если upstream заявил `Content-Length: N`, но закрыл соединение раньше, клиент получит `502`, а не короткое тело с неверным `Content-Length`.

Поддерживаются `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`; тело запроса передаётся с `Content-Length`.

Ограничения прокси:

- upstream только `http://`; HTTPS к upstream не поддерживается;
- IPv6-литералы в upstream не поддерживаются;
- chunked-ответы upstream и `Content-Encoding` (gzip) → `502`;
- дублирующиеся заголовки ответа (`Set-Cookie`) схлопываются в один;
- тело POST от клиента по-прежнему требует завершающего `\n` или закрытия соединения (ограничение gawk `getline`);
- upstream-ответ без `Content-Length` читается до закрытия соединения, поэтому upstream должен закрыть соединение (мы отправляем `Connection: close`).


## Логи

Access log пишется в `logging.access_log` (`-` = stderr), формат:

```
- - - [29/Oct/2026:20:40:14 +0300] "GET /about.txt HTTP/1.1" 200 27 0.000
```

IP клиента берётся из `X-Forwarded-For` или `X-Real-IP` только при `http.trust_forwarded = on`.
По умолчанию это `off`, потому что иначе любой клиент может подделать IP в логах и CGI. Включайте только за контролируемым обратным прокси, который перезаписывает эти заголовки. `socat`/`stunnel` из репозитория их не добавляют, поэтому при обычном TLS-запуске в логе будет `-`. 
Дальше время, запрос, код, размер тела `-` для нуля, длительность в секундах.
Error log - отдельный файл, туда попадают ошибки CGI и прочие сообщения.

## Статика

- `ETag` строится из `mtime`, `size`, `inode`
- `If-None-Match` и `If-Modified-Since` дают `304`
- `HEAD` отдаёт те же заголовки, но без тела
- листинг каталога экранирует HTML и URL-кодирует имена
- symbolic links в листинге помечаются и не становятся ссылками
- `404.html` в корне/vhost используется для `404`
- листинг использует gawk `readdir`: на gawk 5.4.1 запись имеет вид `inode/name/type`); парсер понимает и `name/type/inode`
- `Date` добавляется сервером; `Date` из upstream/CGI отбрасывается, чтобы не было дубля
- `Range` не поддерживается

## Ограничения

- одно соединение за раз на уровне gawk;
- TLS терминируется внешним socat/stunnel; 
- HTTP/2 и ALPN `h2` не поддерживаются, только HTTP/1.1
- нет keep-alive, сжатия, `Range`, chunked-запросов
- reverse proxy не поддерживает chunked/gzip от upstream, HTTPS и IPv6 upstream, дублирующиеся заголовки ответа
- plain-HTTP backend слушает `0.0.0.0` (ограничение gawk `/inet`)
- большой файл читается в память целиком (`readfile`)
- тело POST без завершающего `\n` - см. выше
- таймаут ограничивает чтение, но не запись: очень медленный получатель большого файла может задержать сервер
- между `close(service)` и повторным открытием порта есть микроскопическое окно, когда порт не слушает; при экстремально частых новых подключениях возможен редкий `connection refused`
- `server.host` не влияет на bind: gawk `/inet` всегда слушает `0.0.0.0`
- символические ссылки не поддерживаются: они отклоняются с `403`
- TOCTOU: между проверкой symlink и чтением файла ссылку теоретически можно подменить.

## Безопасность

- `..` и закодированные варианты отклоняются
- имена заголовков проверяются по RFC 7230 token; значения с CR/LF и другими CTL отклоняются с `400`;
- управляющие символы в request line, path и `%00` отклоняются; `Host` проверяется по грамматике host[:port], значения с `/`, `@`, пробелами и CTL дают `400`
- `X-Forwarded-For`/`X-Real-IP` по умолчанию не доверяются;
- `Location` при proxy rewrite становится относительным, поэтому подмена `Host` не даёт open redirect
- дублирующиеся `Cookie` склеиваются через `; `; 
- конфликтующие`Content-Length` дают `400`
- каждый компонент пути проверяется на symlink
- CGI включается явно и запускает только разрешённые интерпретаторы
- CGI-скрипты ограничены `cgi.root`, symlink-скрипты запрещены
- тело и вывод CGI ограничены по размеру и времени
- всё, что приходит от клиента, не попадает в shell без quoting
- если выпустите TLS-ключ, держите его в режиме `600` и не коммитьте
  в публичный репозиторий

## Тесты

```sh
./tests/readdir.sh
./tests/smoke.sh
```

`smoke.sh` поднимает сервер на случайном высоком порту и убивает его
через trap.

Как-то так, я хз что ещё дополнить лол.

Спасибо, что доверяете нам! Мы ценим это и заявляем, этот проект.. ну, как сказать, наверно не нужно юзать на продакшене...
Но если вы используете его, то, пожалуйста, делитесь кодом:3

---

## Известные проблемы

19. Неизвестные ключи конфигурации молча игнорируются. Опечатка в
    `[vhost:NAME]` (например, `directory_listng` или `rrot`) не даёт
    предупреждения; vhost просто наследует `server.root`. Валидация vhost
    проверяет только `root` (`lib/config.awk:260-276`), `index` и
    `directory_listing` у vhost не валидируются.
20. `server.port` проверяется через `+0` (`lib/config.awk:215-217`):
    значение вида `8080abc` пройдёт как 8080.
21. TLS `protocols` фактически не ограничивает максимум. И stunnel
    (`lib/tls_launcher.sh:60-64,77`), и socat (`:106-108`) выставляют только
    минимальную версию; при `protocols=TLSv1.2` TLS 1.3 останется доступен.
    Список значений не валидируется.
22. `verify_client = optional` в stunnel раскрывается как
    `verifyChain=yes` + `verifyPeer=no`. По документации stunnel клиентский
    сертификат запрашивается при `verifyPeer=yes`, так что «optional» может
    фактически не запрашивать сертификат.
23. Гонка при старте TLS: `sleep 0.3` перед проверкой PID (`run.sh:216`);
    фронтенд может начать принимать раньше бэкенда.
24. `eval "$tls_dump"` (`run.sh:182`): значения экранируются `shq()`, так
    что инъекция маловероятна, но `eval` от конфига — лишняя поверхность.
25. Ошибки записи в лог молча глотаются из-за
    `PROCINFO["NONFATAL"] = 1` (`lib/http.awk:12,398`): недоступный путь
    access-log не остановит сервер и не даст явной ошибки.
26. Относительные пути считаются от каталога репозитория (`run.sh:14`
    делает `cd`), а не от текущего каталога пользователя. Может удивить при
    `--config`, `--root`, `cert`/`key`.
27. Хозяйство репозитория: проект под GPL-3.0-or-later (см. `LICENSE`),
    но `.gitignore` по-прежнему нет; CI/CD намеренно не используется.
28. `www/` пуст, `server.conf` отсутствует: после `--check-config` сервер
    поднимется, но отдавать будет пустой листинг.
29. `server.conf.example:65` ссылается на `CERTS.md`, которого нет.
30. Расхождение справки и README по env: в `run.sh` в списке окружения
    нет `AWKWS_MAX_REQUEST_LINE`, `AWKWS_MAX_HEADER_BYTES`,
    `AWKWS_MAX_HEADERS`, `AWKWS_REQUEST_TIMEOUT`, `AWKWS_MAX_BODY_BYTES`
    (`run.sh:42-45`), хотя код и `README.md:72-77` их поддерживают.

## Лицензия

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
