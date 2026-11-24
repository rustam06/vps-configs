#!/usr/bin/env bash
# update-site-v4.sh — объединённая версия для выделенного статического сайта.
# Debian 11+ / Ubuntu 20.04+: Bash, Python 3.8+, curl, ss, nginx,
# coreutils, findutils и util-linux. Запуск: sudo bash ./update-site-v4.sh
# Атомарная смена каталога статики Nginx. Публичная проверка: --verify-public ДОМЕН.
# После успешной проверки удаляет резервные копии выбранного сайта.

set -Eeuo pipefail

if [[ "${1-}" == --build-only ]]; then
    shift
else
    command -v python3 >/dev/null || { printf 'Требуется Python 3.8 или новее.\n' >&2; exit 1; }
    exec python3 /dev/fd/3 "$0" "$@" 3<<'PY_DEPLOY'
import argparse
from contextlib import contextmanager, nullcontext
import ctypes
from dataclasses import dataclass
import errno
import fcntl
import glob
import hashlib
from html.parser import HTMLParser
import ipaddress
import json
import os
from pathlib import Path
import posixpath
import re
import resource
import secrets
import signal
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile


class DeploymentError(Exception):
    pass


DOMAIN_RE = re.compile(r"(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+", re.I | re.ASCII)
CONFIG_HEADER = re.compile(r"^# configuration file ([^\r\n]+):\r?$", re.M)
CONFIG_TOKEN = re.compile(
    r"""(?P<comment>\#[^\r\n]*)|(?P<punct>[;{}])|(?P<space>\s+)|"""
    r"""(?P<word>(?:\\[\s\S]|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|"""
    r"""\$\{[^}\s]+\}|[^\s;{}"'\\#])+)|(?P<invalid>[\s\S])"""
)
SITE_DIR = "site"
BACKUP_INFO = "rollback.json"
CHECK_LIMIT = 2 * 1024 * 1024
REDIRECTS = {"301", "302", "303", "307", "308"}


@dataclass
class Directive:
    name: str
    args: tuple
    children: object
    file: str


@dataclass(frozen=True)
class Endpoint:
    domain: str
    address: str
    port: int
    tls: bool
    proxy_protocol: bool


@dataclass(frozen=True)
class Response:
    status: str
    media_type: str
    redirect: str
    body: bytes
    error: str


@dataclass(frozen=True)
class Target:
    endpoint: Endpoint
    index: str
    status: str
    redirect: str


@dataclass
class Site:
    endpoint: Endpoint
    root: Path
    index: str
    file: str
    identity: list
    targets: tuple


def log(message):
    print(message, flush=True)


def stage(label, detail=""):
    display = f"[{label}]"
    if (sys.stdout.isatty() and "NO_COLOR" not in os.environ and not os.getenv("SITE_PLAIN")
            and os.getenv("TERM", "dumb") != "dumb"):
        display = f"\033[1;36m{display}\033[0m"
    log(f"\n{display}" + (f" {detail}" if detail else ""))


def nginx_config():
    run = subprocess.run(
        ["nginx", "-T"], capture_output=True, text=True, errors="replace", timeout=15
    )
    if run.returncode:
        raise DeploymentError(f"Не удалось прочитать конфигурацию Nginx.\n{run.stderr.strip()}")
    headers = list(CONFIG_HEADER.finditer(run.stdout))
    if not headers:
        raise DeploymentError("Nginx не показал файлы конфигурации.")
    files = {}
    for i, header in enumerate(headers):
        end = headers[i + 1].start() if i + 1 < len(headers) else len(run.stdout)
        files[header[1]] = run.stdout[header.end():end]
    main = headers[0][1]
    tree = config_tree(main, files, posixpath.dirname(main))
    signature = hashlib.sha256(run.stdout.encode()).digest()
    return tree, signature


def config_word(word):
    if len(word) >= 2 and word[0] == word[-1] and word[0] in ('"', "'"):
        word = word[1:-1]
    return re.sub(r"""\\([\\"'])""", r"\1", word)


def config_tree(filename, files, conf_prefix, ancestors=()):
    if filename in ancestors:
        raise DeploymentError(f"Циклический include в {filename}.")
    stack = [[]]
    words = []
    for token in CONFIG_TOKEN.finditer(files[filename]):
        kind = token.lastgroup
        value = token[0]
        if kind in ("space", "comment"):
            continue
        if kind == "word":
            words.append(config_word(value))
            continue
        if kind == "invalid":
            raise DeploymentError(f"Не удалось разобрать конфигурацию {filename}.")
        if value == "}":
            if len(stack) == 1 or words:
                raise DeploymentError(f"Не удалось разобрать вложение в {filename}.")
            stack.pop()
            continue
        if not words:
            raise DeploymentError(f"Неподдерживаемая директива в {filename}.")
        name, *args = words
        words = []
        if name == "include" and value == ";" and len(args) == 1:
            mask = posixpath.normpath(posixpath.join(conf_prefix, args[0]))
            included_paths = sorted(glob.glob(mask)) if glob.has_magic(mask) else [mask]
            for included in included_paths:
                if included not in files:
                    raise DeploymentError(f"Include отсутствует в nginx -T: {included}")
                stack[-1].extend(config_tree(included, files, conf_prefix, (*ancestors, filename)))
            continue
        children = [] if value == "{" else None
        stack[-1].append(Directive(name, tuple(args), children, filename))
        if children is not None:
            stack.append(children)
    if len(stack) != 1 or words:
        raise DeploymentError(f"Незавершённая директива в {filename}.")
    return stack[0]


def first_arg(directives, name, default=""):
    return next((d.args[0] for d in directives if d.name == name and d.args), default)


def server_names(block):
    return tuple(
        name.rstrip(".").lower()
        for directive in block.children
        if directive.name == "server_name"
        for name in directive.args
    )


def literal_path(value):
    if value.startswith("/") and "$" not in value:
        path = Path(posixpath.normpath(value))
        if path.resolve() == path:
            return path
    return None


def under(path, root):
    return path == root or root in path.parents


def root_location(block):
    for args in (("=", "/"), ("^~", "/"), ("/",)):
        for directive in block.children:
            if directive.name == "location" and directive.args == args:
                return directive.children
    return []


def ordered_index(http, server, location):
    for scope in (location, server, http):
        for item in scope:
            if item.name == "index":
                return tuple(value for value in item.args if re.fullmatch(r"[\w.-]+\.html?", value))
    return ("index.html", "index.htm")


def address_port(value, default_port=None):
    if value.isdecimal():
        return "*", int(value)
    if value.startswith("unix:"):
        return None
    if value.startswith("["):
        host, _, port = value[1:].partition("]")
        port = port[1:] if port.startswith(":") else port
    elif ":" in value:
        host, port = value.rsplit(":", 1)
    else:
        host, port = value, ""
    if host in ("", "*", "0.0.0.0"):
        host = "*"
    else:
        try:
            host = str(ipaddress.ip_address(host))
        except ValueError:
            return None
    if port.isdecimal():
        return host, int(port)
    return (host, default_port) if not port and default_port else None


def nginx_sockets():
    run = subprocess.run(["ss", "-H", "-ltnp"], capture_output=True, text=True, timeout=10)
    if run.returncode:
        raise DeploymentError("Не удалось проверить, какие порты слушает Nginx.")
    sockets = set()
    for line in run.stdout.splitlines():
        fields = line.split(maxsplit=5)
        if len(fields) == 6 and re.search(r'\("nginx",', fields[-1]):
            endpoint = address_port(fields[3])
            if endpoint:
                sockets.add(endpoint)
    return sockets


def server_endpoints(block, domain, sockets, options_by_address):
    listeners = [item.args for item in block.children if item.name == "listen"] or [("80",)]
    for address, *options in listeners:
        if "quic" in options:
            continue
        target = address_port(address, 80)
        if not target:
            raise DeploymentError(f"У {domain} неподдерживаемый слушатель Nginx: {address}.")
        host, port = target
        if target in sockets:
            # Wildcard listeners can be reached via their local loopback address.
            address = {"*": "127.0.0.1", "::": "::1"}.get(host, host)
        elif ("*", port) in sockets and host != "*":
            address = "::1" if host == "::" else host
        elif ("::", port) in sockets and ":" in host:
            address = host
        else:
            raise DeploymentError(f"У {domain} нет активного TCP-слушателя Nginx для {address}.")
        flags = set(options) | options_by_address.get(target, set())
        tls = "ssl" in flags or first_arg(block.children, "ssl") == "on"
        yield Endpoint(domain, address, port, tls, "proxy_protocol" in flags)


def limit_check_response(limit):
    soft, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
    maximum = min(value for value in (limit, soft, hard) if value != resource.RLIM_INFINITY)
    resource.setrlimit(resource.RLIMIT_FSIZE, (maximum, hard))


def request(url, options=(), byte_range=None, limit=CHECK_LIMIT):
    with tempfile.NamedTemporaryFile() as body:
        args = [
            "curl", "-q", "--noproxy", "*", "--silent", "--show-error",
            "--proto", "=http,https", "--globoff", "--connect-timeout", "3",
            "--max-time", "10", "--max-filesize", str(limit),
            "--output", body.name, "--write-out", "%{http_code}\n%{content_type}\n%{redirect_url}",
            *options,
        ]
        if byte_range:
            args.extend(["--range", byte_range])
        try:
            result = subprocess.run(
                [*args, "--", url], capture_output=True, timeout=12,
                preexec_fn=lambda: limit_check_response(limit),
            )
        except subprocess.TimeoutExpired:
            return Response("", "", "", b"", "истекло время ожидания")
        if result.returncode:
            return Response("", "", "", b"", result.stderr.decode(errors="replace").strip())
        status, media_type, location = result.stdout.decode(errors="replace").split("\n", 2)
        return Response(status, media_type.split(";", 1)[0].strip().lower(), location,
                        body.read(limit + 1), "")


def fetch(endpoint, path, byte_range=None, limit=CHECK_LIMIT):
    address = endpoint.address
    if ":" in address:
        address = f"[{address}]"
    options = [
        "--insecure", "--resolve", f"{endpoint.domain}:{endpoint.port}:{address}",
        "--header", f"Host: {endpoint.domain}",
    ]
    if endpoint.proxy_protocol:
        options.append("--haproxy-protocol")
    scheme = "https" if endpoint.tls else "http"
    return request(f"{scheme}://{endpoint.domain}:{endpoint.port}{path}", options, byte_range, limit)


def endpoint_label(endpoint):
    scheme = "HTTPS" if endpoint.tls else "HTTP"
    return f"{scheme} {endpoint.domain}:{endpoint.port}"


def report_error(response):
    return f"HTTP {response.status}" if response.status else (response.error or "ответ отсутствует")


def static_index(path):
    if (path.is_file() and under(path.resolve(), path.parent)
            and 0 < path.stat().st_size <= CHECK_LIMIT):
        return path.read_bytes()
    return None


def aliases(directives):
    for directive in directives:
        if directive.name in ("root", "alias") and directive.args:
            value = directive.args[0]
            if value.startswith("/") and "$" not in value:
                yield Path(value).resolve()
        if directive.children:
            yield from aliases(directive.children)


def safe_root(root):
    protected = {
        Path("/"), Path("/var/www"), Path("/srv/www"), Path("/usr/share"),
        Path("/usr/share/nginx"), Path("/usr/local"), Path("/usr/local/share"),
        Path("/var/lib"), Path("/var/log"), Path("/mnt"), Path("/opt"),
        Path("/srv"), Path("/home"), Path("/root"), Path("/tmp"), Path("/var/tmp"),
    }
    if len(root.parts) < 3 or root in protected or root.parts[1] in {
        "bin", "boot", "dev", "etc", "lib", "lib64", "proc", "run", "sbin", "sys",
    }:
        raise DeploymentError(f"Каталог {root} слишком общий для замены сайта.")
    allowed = (Path("/var/www"), Path("/srv"), Path("/opt"), Path("/usr/share/nginx/html"), Path("/usr/local/share"))
    if not any(under(root, base) for base in allowed):
        raise DeploymentError(f"{root}: поддерживаются только выделенные каталоги статики в /var/www, /srv, /opt, /usr/share/nginx/html, /usr/local/share.")
    trusted_directory(root)


def trusted_directory(root):
    if not root.is_dir() or root.is_symlink() or root.resolve() != root:
        raise DeploymentError(f"Каталог сайта {root} недоступен или является ссылкой.")
    for parent in (root, *root.parents):
        info = parent.stat()
        if info.st_uid != 0 or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise DeploymentError(f"Каталог {parent} не принадлежит root или доступен для записи другим пользователям.")
    for record in Path("/proc/self/mountinfo").read_text().splitlines():
        mount = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), record.split()[4])
        if under(Path(mount), root):
            raise DeploymentError(f"В {root} есть точка монтирования. Замена каталога невозможна.")


# Только известные служебные файлы переносим в новую версию. Неизвестные
# скрытые файлы и признаки приложения — причина остановки, а не удаления.
SERVICE_NAMES = {".well-known", ".htaccess", ".nojekyll", "BingSiteAuth.xml"}
SERVER_SUFFIXES = {".php", ".php3", ".php4", ".php5", ".php7", ".php8", ".phtml", ".phar", ".cgi", ".fcgi", ".aspx", ".asp", ".jsp", ".jspx", ".py", ".rb", ".pl", ".sh", ".sql", ".sqlite", ".db", ".pem", ".key"}
APP_NAMES = {"package.json", "composer.json", "wp-config.php", "Dockerfile", "docker-compose.yml", "requirements.txt", "manage.py", "node_modules", "vendor", "cgi-bin"}


def service_name(name):
    return name in SERVICE_NAMES or bool(re.fullmatch(r"(?:google[a-zA-Z0-9_-]+|yandex_[a-zA-Z0-9_-]+)\.html", name))


def scan_static(root):
    for folder, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(folder) / name
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise DeploymentError(f"Обнаружена символическая ссылка: {path}. Автозамена остановлена.")
            if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
                raise DeploymentError(f"Специальный файл: {path}.")
            if (name.startswith(".") and not (Path(folder) == root and service_name(name))
                    and not under(path, root / ".well-known")):
                raise DeploymentError(f"Неизвестный скрытый файл/каталог: {path}. Требуется ручная проверка.")
            if name in APP_NAMES or path.suffix.lower() in SERVER_SUFFIXES:
                raise DeploymentError(f"В каталоге найден серверный код или служебные данные: {path}.")
            if info.st_uid != 0 or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                raise DeploymentError(f"Файл или каталог может изменяться другим пользователем: {path}.")


def configured_paths(block, inherited):
    paths = set(aliases(block.children))
    raw = first_arg(block.children, "root", inherited)
    if raw.startswith("/") and "$" not in raw:
        paths.add(Path(raw).resolve())
    return paths


def variable_paths(items):
    return any((d.name in {"root", "alias"} and d.args and "$" in d.args[0])
               or (d.children and variable_paths(d.children)) for d in items)


def related_names(left, right):
    return (left and right and all(DOMAIN_RE.fullmatch(name) for name in left | right)
            and (left <= right or right <= left))


def shared_root(root, selected, inherited, blocks):
    names = set(server_names(selected))
    for block in blocks:
        paths = configured_paths(block, inherited)
        if block is selected:
            if any(path != root and under(path, root) and not under(path, root / ".well-known")
                   for path in paths):
                return True
            continue
        same_site = related_names(names, set(server_names(block)))
        for path in paths:
            if not (under(path, root) or under(root, path)):
                continue
            if same_site and (path == root or under(path, root / ".well-known")):
                continue
            return True
        if variable_paths(block.children) or "$" in first_arg(block.children, "root", inherited):
            return True
    return False


def is_dynamic(items):
    return any(d.name in {"fastcgi_pass", "uwsgi_pass", "scgi_pass", "grpc_pass", "memcached_pass"}
               or (d.name in {"root", "alias"} and d.args and "$" in d.args[0])
               or (d.name == "try_files" and any(".php" in value.lower() for value in d.args))
               or (d.children and is_dynamic(d.children)) for d in items)


def listen_options(blocks):
    by_address = {}
    for block in blocks:
        for entry in block.children:
            if entry.name != "listen" or not entry.args or "quic" in entry.args:
                continue
            key = address_port(entry.args[0], 80)
            if key:
                by_address.setdefault(key, set()).update(entry.args[1:])
    return by_address


def site_targets(root, http, blocks, inherited, sockets):
    targets = {}
    options = listen_options(blocks)
    for block in blocks:
        if root not in configured_paths(block, inherited):
            continue
        location = root_location(block)
        active_root = first_arg(location, "root", first_arg(block.children, "root", inherited))
        if not active_root.startswith("/") or "$" in active_root or Path(active_root).resolve() != root:
            raise DeploymentError("Тот же каталог используется другим маршрутом Nginx.")
        if is_dynamic(block.children) or any(d.name in {"alias", "proxy_pass"} for d in location):
            raise DeploymentError("У одного из связанных блоков динамическая главная страница.")
        names = server_names(block)
        if not names or any(not DOMAIN_RE.fullmatch(name) for name in names):
            raise DeploymentError("У связанного блока Nginx нет проверяемого точного server_name.")
        indexes = {
            name: data for name in ordered_index(http, block.children, location)
            if (data := static_index(root / name)) is not None
        }
        redirects = any(d.name == "return" and d.args and d.args[0] in REDIRECTS
                        for d in [*block.children, *location])
        for domain in names:
            endpoints = tuple(server_endpoints(block, domain, sockets, options))
            if not endpoints:
                raise DeploymentError(f"У {domain} нет доступного слушателя Nginx.")
            for endpoint in endpoints:
                if endpoint in targets:
                    raise DeploymentError(f"{endpoint_label(endpoint)} указан в нескольких связанных блоках.")
                response = fetch(endpoint, "/")
                index = next((name for name, data in indexes.items() if response.body == data), None)
                if response.status == "200" and index:
                    targets[endpoint] = Target(endpoint, index, "", "")
                elif redirects and response.status in REDIRECTS and response.redirect:
                    targets[endpoint] = Target(endpoint, "", response.status, response.redirect)
                else:
                    raise DeploymentError(f"{endpoint_label(endpoint)}: главная из {root} не подтверждена ({report_error(response)}).")
    return tuple(targets.values())


def discover(tree, sockets):
    sites = {}
    for http in (directive.children for directive in tree if directive.name == "http"):
        inherited = first_arg(http, "root")
        blocks = [item for item in http if item.name == "server" and item.children is not None]
        for block in blocks:
            names = server_names(block)
            if not names or any(not DOMAIN_RE.fullmatch(name) for name in names):
                continue
            location = root_location(block)
            root = literal_path(first_arg(location, "root", first_arg(block.children, "root", inherited)))
            if not root or not root.is_dir() or root in sites:
                continue
            try:
                safe_root(root)
                scan_static(root)
                if shared_root(root, block, inherited, blocks):
                    raise DeploymentError(f"каталог {root} пересекается с другим сайтом или маршрутом.")
                targets = site_targets(root, http, blocks, inherited, sockets)
                static = [target for target in targets if target.index]
                if not static:
                    continue
                primary = max(static, key=lambda target: target.endpoint.tls)
                sites[root] = Site(primary.endpoint, root, primary.index, block.file, file_identity(root), targets)
            except DeploymentError as error:
                log(f"Пропускаю {names[0]} — {error}")
    return list(sites.values())


def select_site(sites):
    if not sites:
        raise DeploymentError(
            "Действующий статический сайт Nginx не найден. Поддерживается явный server_name "
            "и обычный root с HTML-страницей, которую отдаёт запущенный Nginx на хосте."
        )
    if len(sites) == 1:
        return sites[0]
    log("Найдено несколько сайтов:")
    for index, site in enumerate(sites, 1):
        log(f"  {index}. {site.endpoint.domain} (порт {site.endpoint.port}) → {site.root}")
    while True:
        choice = input("Номер сайта (Enter — выход): ").strip()
        if not choice:
            return None
        if choice.isascii() and choice.isdecimal() and len(choice) <= len(str(len(sites))):
            index = int(choice)
            if 1 <= index <= len(sites):
                return sites[index - 1]
        log("Укажите номер из списка.")


def ask(label, default, allowed=None):
    while True:
        value = input(f"{label} [{default}]: ").strip() or default
        if allowed is None or value in allowed:
            return value
        log("Допустимые значения: " + ", ".join(allowed))


def ask_number(label, default, low, high):
    while True:
        value = input(f"{label} [{default}]: ").strip() or str(default)
        if re.fullmatch(r"[0-9]{1,5}", value) and low <= int(value) <= high:
            return str(int(value))
        log(f"Введите целое число от {low} до {high}.")


@contextmanager
def lock_parent(root):
    fd = os.open(root.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise DeploymentError("В этом каталоге уже выполняется установка или откат.") from error
        yield
    finally:
        os.close(fd)


def file_identity(path):
    info = path.lstat()
    return [info.st_dev, info.st_ino]


def replace_dirs(left, right):
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        exchange = libc.renameat2
    except AttributeError as error:
        raise DeploymentError("Эта система не поддерживает атомарный обмен каталогов.") from error
    exchange.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    exchange.restype = ctypes.c_int
    if exchange(-100, os.fsencode(left), -100, os.fsencode(right), 2):
        code = ctypes.get_errno()
        if code in {errno.EXDEV, errno.ENOSYS, errno.EINVAL, errno.EOPNOTSUPP}:
            raise DeploymentError("Файловая система не поддерживает атомарный обмен каталогов.")
        raise OSError(code, os.strerror(code), str(left))


def preserve_services(source, staged, only_acme=False):
    for old in source.iterdir():
        if not (old.name == ".well-known" if only_acme else service_name(old.name)):
            continue
        if old.is_symlink() or not (old.is_dir() or old.is_file()):
            raise DeploymentError(f"Небезопасный служебный файл: {old}")
        if old.name == ".well-known" and not old.is_dir():
            raise DeploymentError(f"Ожидался каталог: {old}")
        dest = staged / old.name
        with tempfile.TemporaryDirectory(prefix=".site-services-", dir=staged.parent) as temporary:
            copy = Path(temporary) / old.name
            subprocess.run(["cp", "-a", "--", str(old), str(copy)], check=True)
            if dest.exists() or dest.is_symlink():
                replace_dirs(dest, copy)
            else:
                copy.rename(dest)


def check_redirect(target):
    response = fetch(target.endpoint, "/")
    if (response.status, response.redirect) != (target.status, target.redirect):
        raise DeploymentError(f"{endpoint_label(target.endpoint)}: ответ редиректа изменился ({report_error(response)}).")
    return response.status


def confirm_mapping(site):
    with tempfile.NamedTemporaryFile(prefix="gallery-check-", suffix=".html", dir=site.root) as probe:
        token = secrets.token_hex(24).encode()
        probe.write(token)
        probe.flush()
        os.fchmod(probe.fileno(), 0o644)
        probe_path = "/" + Path(probe.name).name
        for target in site.targets:
            if not target.index:
                check_redirect(target)
                continue
            response = fetch(target.endpoint, "/")
            if response.status != "200" or response.body != static_index(site.root / target.index):
                raise DeploymentError(f"{endpoint_label(target.endpoint)}: главная изменилась во время сборки.")
            response = fetch(target.endpoint, probe_path)
            if response.status != "200" or response.body != token:
                raise DeploymentError(f"{endpoint_label(target.endpoint)}: файлы из выбранного каталога не отдаются напрямую.")


def local_link(value):
    # Проверяем только обычные ссылки на файлы этой галереи.
    return value if value and re.fullmatch(r"/(?!/)[A-Za-z0-9_./-]*(?:\?v=[A-Za-z0-9]+)?", value) else None


class GalleryLinks(HTMLParser):
    def __init__(self):
        super().__init__()
        self.css = []
        self.pages = []
        self.posters = []
        self.videos = []
        self.in_nav = False

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == "nav":
            self.in_nav = True
        if self.in_nav and tag == "a":
            if (path := local_link(attrs.get("href"))) and path not in self.pages:
                self.pages.append(path)
        if tag == "link" and attrs.get("rel") == "stylesheet":
            if path := local_link(attrs.get("href")):
                self.css.append(path)
        if tag == "video":
            if path := local_link(attrs.get("poster")):
                self.posters.append(path)
        if tag == "source" and attrs.get("type") == "video/mp4":
            if path := local_link(attrs.get("src")):
                self.videos.append(path)

    def handle_endtag(self, tag):
        if tag == "nav":
            self.in_nav = False


def gallery_links(body):
    parser = GalleryLinks()
    parser.feed(body.decode("utf-8"))
    if not parser.css or not parser.videos:
        raise DeploymentError("На главной отсутствует локальный CSS или MP4.")
    return parser


def check_gallery(site):
    expected = (site.root / "index.html").read_bytes()
    links = gallery_links(expected)
    css = links.css[0]
    video = links.videos[0]
    css_bytes = (site.root / css.lstrip("/")).read_bytes()
    pages = [(path, (site.root / path.lstrip("/")).read_bytes()) for path in links.pages if path != "/"]
    with (site.root / video.split("?", 1)[0].lstrip("/")).open("rb") as media:
        video_bytes = media.read(1024)
    for target in site.targets:
        label = endpoint_label(target.endpoint)
        if not target.index:
            log(f"  [OK] {label} · редирект {check_redirect(target)}")
            continue
        response = fetch(target.endpoint, "/")
        if response.status != "200" or response.body != expected or response.media_type != "text/html":
            raise DeploymentError(f"{label}: главная новой галереи не подтверждена ({report_error(response)}).")
        response = fetch(target.endpoint, css)
        if response.status != "200" or response.body != css_bytes or response.media_type != "text/css":
            raise DeploymentError(f"{label}: CSS новой галереи не подтверждён ({report_error(response)}).")
        for path, body in pages:
            response = fetch(target.endpoint, path)
            if response.status != "200" or response.body != body or response.media_type != "text/html":
                raise DeploymentError(f"{label}: страница {path} не подтверждена ({report_error(response)}).")
        response = fetch(target.endpoint, video, "0-1023")
        if response.status != "206" or response.media_type != "video/mp4" or response.body != video_bytes:
            raise DeploymentError(f"{label}: ожидался фрагмент MP4 с кодом 206 и типом video/mp4 ({report_error(response)}).")
        log(f"  [OK] {label} · главная 200 · CSS 200 · страниц {len(pages)} · MP4 206")


def verify_public(domain):
    domain = domain.lower().rstrip(".")
    if not DOMAIN_RE.fullmatch(domain):
        raise DeploymentError("Укажите публичный домен галереи без схемы, порта и пути.")
    origin = f"https://{domain}"
    failures = []

    def check(path, status, media_type="", byte_range=None, limit=CHECK_LIMIT):
        response = request(origin + path, byte_range=byte_range, limit=limit)
        prefix = media_type.endswith("/")
        valid_type = not media_type or (response.media_type.startswith(media_type)
                                        if prefix else response.media_type == media_type)
        if response.status == status and valid_type and (status == "404" or response.body):
            log(f"  [OK] {path} · {status}{' · ' + response.media_type if response.media_type else ''}")
        else:
            detail = f"{path} · {report_error(response)}"
            if response.media_type:
                detail += f" · {response.media_type}"
            log(f"  [ОШИБКА] {detail}")
            failures.append(path)
        return response

    stage("Публичный HTTPS", origin)
    page = check("/", "200", "text/html")
    if failures:
        raise DeploymentError("Публичная главная не прошла проверку TLS или HTTP.")
    links = gallery_links(page.body)
    for url in links.pages:
        if url != "/":
            check(url, "200", "text/html")
    for url in links.css:
        check(url, "200", "text/css")
    if links.posters:
        check(links.posters[0], "200", "image/", limit=8 * 1024 * 1024)
    else:
        log("  [ПРОПУСК] На главной нет постеров.")
    check(links.videos[0], "206", "video/mp4", byte_range="0-1023")
    check(f"/gallery-check-missing-{secrets.token_hex(10)}.html", "404")
    if failures:
        raise DeploymentError(f"Публичная проверка: не прошли {len(failures)} из проверенных адресов.")
    log("Публичный HTTPS прошёл проверку.")


def backup_prefix(root):
    return f".{root.name}.dest-backup-"


@contextmanager
def lock_legacy_backups():
    # Старый update-site.sh использует отдельную блокировку установки и отката.
    try:
        fd = os.open("/run/lock/update-static-site.lock", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        yield
        return
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise DeploymentError("Небезопасный файл блокировки старого установщика.")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def backup_matches(backup, root):
    saved = backup / SITE_DIR
    try:
        saved_info = saved.lstat()
    except FileNotFoundError:
        # При прерванной очистке каталог с файлами мог уже удалиться.
        saved_info = None
    if saved_info is not None and not stat.S_ISDIR(saved_info.st_mode):
        return False

    if backup.name.startswith(backup_prefix(root)):
        marker = backup / BACKUP_INFO
        if marker.is_symlink() or not marker.is_file():
            return False
        record = json.loads(marker.read_text())
        return (isinstance(record, dict) and record.get("root") == str(root)
                and (saved_info is None or [saved_info.st_dev, saved_info.st_ino]
                     in (record.get("original"), record.get("installed"))))

    # Старый update-site.sh сохранял путь в rollback.sh с экранированием printf %q.
    marker = backup / "rollback.sh"
    exchange = backup / "exchange.py"
    if marker.is_symlink() or not marker.is_file() or exchange.is_symlink() or not exchange.is_file():
        return False
    with marker.open() as script:
        if script.readline().strip() != "#!/usr/bin/env bash" or script.readline().strip() != "set -Eeuo pipefail":
            return False
        values = [word.split("=", 1) for word in shlex.split(script.readline())]
    if any(len(value) != 2 for value in values):
        return False
    values = dict(values)
    return (values.get("ROOT") == str(root) and values.get("BACKUP") == str(saved)
            and re.fullmatch(r"[0-9]+:[0-9]+", values.get("EXPECTED", "")) is not None)


def prune_site_backups(root, current_backup, active, tree):
    try:
        candidates = [
            entry for entry in root.parent.iterdir()
            if entry != root and (
                entry.name.startswith(backup_prefix(root)) or re.fullmatch(r"\.site-update\.[A-Za-z0-9]{8}", entry.name)
            )
        ]
        configured = tuple(aliases(tree))
    except (OSError, RuntimeError) as error:
        log(f"[ВНИМАНИЕ] Не удалось подготовить очистку копий: {error}")
        return

    removed = 0
    # Свежую копию удаляем последней. Файл привязки удаляем после файлов сайта.
    for backup in sorted(candidates, key=lambda path: (path == current_backup, path.name)):
        try:
            if file_identity(root) != active:
                log("[ВНИМАНИЕ] Активный каталог изменился во время очистки.")
                break
            info = backup.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
                continue
            lock = lock_legacy_backups() if backup.name.startswith(".site-update.") else nullcontext()
            with lock:
                if not backup_matches(backup, root):
                    continue
                if any(under(path, backup) for path in configured):
                    log(f"[ВНИМАНИЕ] Копия используется в конфигурации Nginx: {backup}")
                    continue
                trusted_directory(backup)
                saved = backup / SITE_DIR
                if saved.is_dir():
                    shutil.rmtree(saved)
                shutil.rmtree(backup)
                removed += 1
        except (DeploymentError, OSError, ValueError) as error:
            log(f"[ВНИМАНИЕ] Не удалось удалить копию {backup}: {error}")
    log(f"Удалено резервных копий сайта: {removed}")


def deploy(script, site, signature, settings):
    root = site.root
    with lock_parent(root):
        safe_root(root)
        scan_static(root)
        original = file_identity(root)
        if original != site.identity:
            raise DeploymentError("Каталог изменился после выбора сайта. Запустите скрипт заново.")
        backup = Path(tempfile.mkdtemp(prefix=backup_prefix(root), dir=root.parent))
        staged = backup / SITE_DIR
        keep_backup = False
        try:
            subprocess.run(
                ["bash", str(script), "--build-only", site.endpoint.domain, str(staged)],
                env={**os.environ, **settings}, check=True,
            )
            for index in sorted({target.index for target in site.targets} - {"", "index.html"}):
                if (staged / index).exists() or service_name(index):
                    raise DeploymentError(f"Имя старой главной страницы конфликтует с новой: {index}")
                shutil.copy2(staged / "index.html", staged / index)
            tree, current_signature = nginx_config()
            if file_identity(root) != original or current_signature != signature:
                raise DeploymentError("Каталог сайта или конфигурация изменились во время сборки.")
            safe_root(root)
            scan_static(root)
            stage("5/5", "Публикация и проверка")
            confirm_mapping(site)
            preserve_services(root, staged)
            previous = root.stat()
            os.chown(staged, previous.st_uid, previous.st_gid)
            shutil.copystat(root, staged)
            expected = file_identity(staged)
            record = {"root": str(root), "original": original, "installed": expected}
            with (backup / BACKUP_INFO).open("x") as metadata:
                json.dump(record, metadata)
                metadata.flush()
                os.fsync(metadata.fileno())
            rollback_script = backup / "update-site-v4.sh"
            shutil.copyfile(script, rollback_script)
            command = shlex.join(["sudo", "bash", str(rollback_script), "--rollback", str(backup)])
            log(f"Откат при прерванной установке: {command}")
            keep_backup = True
            try:
                replace_dirs(root, staged)
                check_gallery(site)
            except (DeploymentError, OSError, KeyboardInterrupt, ValueError, subprocess.SubprocessError) as error:
                if file_identity(root) == original and file_identity(staged) == expected:
                    raise DeploymentError(f"Публикация не выполнена: {error}. Старый сайт на месте.") from error
                if file_identity(root) != expected or file_identity(staged) != original:
                    raise DeploymentError(f"Не удалось проверить галерею ({error}). Каталоги изменились, используйте резервную копию {backup}.") from error
                try:
                    preserve_services(root, staged, only_acme=True)
                except (DeploymentError, OSError, subprocess.SubprocessError) as acme_error:
                    log(f"[ВНИМАНИЕ] При откате восстановлена прежняя копия .well-known: {acme_error}")
                replace_dirs(root, staged)
                raise DeploymentError(f"{error} Прежние файлы восстановлены в {root}.") from error
            log(f"Галерея опубликована: {site.endpoint.domain} → {root}")
            log(f"Проверено адресов: {len(site.targets)}")
            prune_site_backups(root, backup, expected, tree)
            log(f"Для проверки с другого устройства: bash {shlex.quote(script.name)} --verify-public {site.endpoint.domain}")
        finally:
            if not keep_backup:
                shutil.rmtree(backup)


def rollback(backup):
    if backup.is_symlink():
        raise DeploymentError("Укажите исходный каталог резервной копии.")
    backup = backup.resolve(strict=True)
    info = backup.stat()
    if not backup.is_dir() or info.st_uid != 0 or info.st_mode & 0o077:
        raise DeploymentError("У каталога резервной копии неверный владелец или права.")
    metadata = backup / BACKUP_INFO
    if metadata.is_symlink() or not metadata.is_file():
        raise DeploymentError("Отсутствует файл сведений о резервной копии.")
    record = json.loads(metadata.read_text())
    root, saved = Path(record["root"]), backup / SITE_DIR
    if root.resolve() != root or root.parent != backup.parent or not backup.name.startswith(backup_prefix(root)):
        raise DeploymentError("Резервная копия не соответствует каталогу сайта.")
    with lock_parent(root):
        safe_root(root)
        if saved.is_symlink() or not saved.is_dir() or saved.resolve() != saved:
            raise DeploymentError("Резервный каталог повреждён или заменён ссылкой.")
        trusted_directory(saved)
        live_identity, saved_identity = file_identity(root), file_identity(saved)
        if live_identity == record["original"] and saved_identity == record["installed"]:
            log("Прежний сайт уже находится на месте.")
            return
        if (live_identity, saved_identity) != (record["installed"], record["original"]):
            raise DeploymentError("Каталог сайта изменился после установки. Автоматический откат остановлен.")
        preserve_services(root, saved, only_acme=True)
        replace_dirs(root, saved)
        log(f"Прежний сайт восстановлен в {root}. Снятая галерея хранится в {saved}.")


def main(script):
    parser = argparse.ArgumentParser(prog=script.name, description="Заменить действующую статику Nginx видеогалереей.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="проверить сайт и локальные HTTP/HTTPS-адреса")
    mode.add_argument("--verify-public", metavar="ДОМЕН", help="проверить публичный HTTPS с этого устройства")
    parser.add_argument("--plain", action="store_true", help="строки без цвета и перерисовки")
    mode.add_argument("--rollback", metavar="КАТАЛОГ_КОПИИ", type=Path, help="вернуть прежние файлы сайта")
    args = parser.parse_args(sys.argv[2:])
    if args.plain:
        os.environ["SITE_PLAIN"] = "1"
    if args.verify_public is not None:
        if not shutil.which("curl"):
            raise DeploymentError("Для проверки публичного сайта требуется curl.")
        verify_public(args.verify_public)
        return
    if not args.check and not os.isatty(sys.stdin.fileno()):
        raise DeploymentError("Запустите скрипт в интерактивном терминале.")
    if os.geteuid() != 0:
        raise DeploymentError(f"Запустите с правами администратора: sudo bash {shlex.quote(str(script))}")
    if args.rollback:
        rollback(args.rollback)
        return
    for tool in ("nginx", "ss", "curl"):
        if not shutil.which(tool):
            raise DeploymentError(f"Не найдена команда {tool}.")
    stage("1/5", "Поиск сайта")
    sockets = nginx_sockets()
    if not sockets:
        raise DeploymentError("Запущенный Nginx с TCP-портом на хосте не найден.")
    tree, signature = nginx_config()
    sites = discover(tree, sockets)
    if args.check and not os.isatty(sys.stdin.fileno()) and len(sites) > 1:
        for candidate in sites:
            log(f"Действующий сайт: {candidate.endpoint.domain} → {candidate.root}")
        return
    site = select_site(sites)
    if site is None:
        return
    log(f"Действующий сайт: {site.endpoint.domain}")
    log(f"Каталог: {site.root}")
    log(f"Конфигурация: {site.file}")
    for target in site.targets:
        mode = f"главная: {target.index}" if target.index else f"редирект {target.status} → {target.redirect}"
        log(f"  {endpoint_label(target.endpoint)} · {mode}")
    if args.check:
        log("Режим проверки: файлы сайта не изменены.")
        return
    log("Копии этого сайта будут удалены после успешной проверки. При сбое проверки скрипт вернёт прежние файлы.")
    log("Не запускайте во время ACME-проверки.")
    confirmed = input("Заменить файлы сайта видеогалереей? [д/Н]: ").strip().lower()
    if confirmed not in {"д", "да", "y", "yes"}:
        log("Замена отменена.")
        return
    stage("2/5", "Настройки галереи")
    name = ask("Название сайта", site.endpoint.domain.split(".")[0].capitalize())
    language = ask("Язык сайта", "en", ("ru", "en"))
    settings = {
        "STUDIO_NAME": name,
        "SITE_LANG": language,
        "VIDEO_COUNT": ask_number("Число клипов", os.getenv("VIDEO_COUNT", "6"), 1, 24),
        "MIN_SIZE_MB": ask_number("Минимальный размер клипа, МиБ", os.getenv("MIN_SIZE_MB", "1"), 0, 256),
        "VIDEO_QUALITY": ask("Качество (auto/large/medium/small/tiny)", os.getenv("VIDEO_QUALITY", "auto"),
                             ("auto", "large", "medium", "small", "tiny")),
        "MIN_DURATION": ask_number("Минимальная длительность, с", os.getenv("MIN_DURATION", "15"), 0, 99999),
        "SITE_SCHEME": "https" if site.endpoint.tls else "http",
    }
    deploy(script, site, signature, settings)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        main(Path(sys.argv[1]).resolve())
    except (EOFError, KeyboardInterrupt):
        log("\nРабота прервана.")
        sys.exit(130)
    except (DeploymentError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"Ошибка: {error}", file=sys.stderr)
        sys.exit(1)
PY_DEPLOY
fi

# Сборщик статической видеогалереи
set -Eeuo pipefail
umask 077

GREEN=''; YELLOW=''; RED=''; CYAN=''; NC=''
if [[ -t 1 && -z "${NO_COLOR+x}" && -z "${SITE_PLAIN:-}" && "${TERM:-dumb}" != dumb ]]; then
    GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'
    CYAN=$'\033[1;36m'; NC=$'\033[0m'
fi
log() { printf '%s[+]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die() { printf '%sОшибка:%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
hdr() { printf '\n%s[%s]%s\n' "$CYAN" "$*" "$NC"; }
mib() { LC_ALL=C awk -v bytes="$1" 'BEGIN {printf "%.2f", bytes / 1048576}'; }

if (( $# != 2 )); then
    die 'Запуск: bash update-site-v4.sh --build-only ДОМЕН НОВЫЙ_КАТАЛОГ'
fi

DOMAIN="${1,,}"
OUTPUT="${2%/}"
[[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || die 'Укажите домен без https://, пути и порта.'
[[ -n "$OUTPUT" && ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] \
    || die 'Выберите новый каталог для сборки.'
PARENT=$(dirname -- "$OUTPUT")
[[ -d "$PARENT" && -w "$PARENT" ]] \
    || die "Родительский каталог должен существовать и быть доступен для записи: $PARENT"

for tool in curl python3 flock sha256sum; do
    command -v "$tool" >/dev/null || die "Требуется $tool."
done
SITE_LANG="${SITE_LANG:-en}"
SITE_SCHEME="${SITE_SCHEME:-https}"
[[ "$SITE_SCHEME" == https || "$SITE_SCHEME" == http ]] || die 'SITE_SCHEME должен быть https или http.'
VIDEO_COUNT="${VIDEO_COUNT:-6}"
VIDEO_QUALITY="${VIDEO_QUALITY:-auto}"
MIN_DURATION="${MIN_DURATION:-15}"
MIN_SIZE_MB="${MIN_SIZE_MB:-1}"
RESERVE_MB="${RESERVE_MB:-1024}"
[[ "$RESERVE_MB" =~ ^[1-9][0-9]{0,5}$ ]] && (( RESERVE_MB >= 512 )) || die "RESERVE_MB: минимум 512 МиБ."
RESERVE_KIB=$(( RESERVE_MB * 1024 ))
FETCH_POOL=200

[[ "$SITE_LANG" == en || "$SITE_LANG" == ru ]] || die 'SITE_LANG должен быть en или ru.'
[[ "$VIDEO_COUNT" =~ ^[1-9][0-9]?$ ]] && (( VIDEO_COUNT <= 24 )) \
    || die 'VIDEO_COUNT должен быть целым числом от 1 до 24.'
case "$VIDEO_QUALITY" in
    auto|large|medium|small|tiny) ;;
    *) die 'VIDEO_QUALITY должен быть auto, large, medium, small или tiny.' ;;
esac
[[ "$MIN_DURATION" =~ ^(0|[1-9][0-9]{0,4})$ && "$MIN_SIZE_MB" =~ ^(0|[1-9][0-9]{0,4})$ ]] \
    || die 'MIN_DURATION и MIN_SIZE_MB должны быть целыми неотрицательными числами без ведущих нулей.'
(( MIN_SIZE_MB <= 256 )) || die 'Минимальный размер не может превышать максимальный (256 МиБ).'

esc() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' \
                            -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

SEED_BASE=$(printf '%s' "$DOMAIN" | sha256sum | cut -c1-32)

seed_idx() {
    local hash
    hash=$(printf '%s|%s' "$SEED_BASE" "$1" | sha256sum | cut -c1-6)
    printf '%s\n' "$(( 16#$hash ))"
}

pick() {
    local salt="$1"
    shift
    local -a choices=("$@")
    printf '%s\n' "${choices[$(( $(seed_idx "$salt") % ${#choices[@]} ))]}"
}

BRAND_DEFAULT="${DOMAIN%%.*}"
STUDIO_RAW="${STUDIO_NAME:-${BRAND_DEFAULT^} $(pick brandword Studio Films Motion Works Picture)}"
STUDIO_NAME=$(esc "$STUDIO_RAW")
BRAND_INITIAL=$(printf '%s' "$STUDIO_RAW" | cut -c1 | tr '[:lower:]' '[:upper:]')
[[ "$BRAND_INITIAL" =~ ^[A-Za-zА-Яа-я0-9]$ ]] || BRAND_INITIAL=M

TMP_DIR=""
CACHE_TEMP=""
STAGE=""
cleanup() {
    [[ -z "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"
    [[ -z "$CACHE_TEMP" ]] || rm -f -- "$CACHE_TEMP"
    [[ -z "$STAGE" ]] || rm -rf -- "$STAGE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "Сборка прервана на строке %s.\n" "$LINENO" >&2' ERR

TMP_DIR=$(mktemp -d)
STAGE=$(mktemp -d -- "$PARENT/.dest-gallery.XXXXXXXX")
MEDIA_VERSION="${STAGE##*.}"
mkdir -p -- "$STAGE"/assets/{video,img,css}
FREE_KIB=$(df -Pk -- "$STAGE" | awk 'NR == 2 {print $4}')
(( FREE_KIB > RESERVE_KIB )) || die "Недостаточно места: резерв ${RESERVE_MB} МиБ."
(( FREE_KIB >= RESERVE_KIB + VIDEO_COUNT * MIN_SIZE_MB * 1024 )) || die "Недостаточно места даже для минимального размера всех запрошенных клипов и резерва."

# Оформление и страницы исходного шаблона.
PALETTE=$(pick palette 1 2 3 4 5 6)
case "$PALETTE" in
  1) C_INK="#1b1f24"; C_SOFT="#5d666e"; C_LINE="#dde2e7"; C_BG="#f7f8f9"; C_PANEL="#ffffff"; C_ACC="#2f4b7c" ;;
  2) C_INK="#22201d"; C_SOFT="#6b645c"; C_LINE="#e3ded6"; C_BG="#faf8f4"; C_PANEL="#ffffff"; C_ACC="#4a6b45" ;;
  3) C_INK="#151b1a"; C_SOFT="#57635f"; C_LINE="#d9e2df"; C_BG="#f4f7f6"; C_PANEL="#ffffff"; C_ACC="#1f6b6b" ;;
  4) C_INK="#1d1a22"; C_SOFT="#635d6b"; C_LINE="#e0dce5"; C_BG="#f8f6fa"; C_PANEL="#ffffff"; C_ACC="#5a3f88" ;;
  5) C_INK="#181818"; C_SOFT="#5f5f5f"; C_LINE="#e0e0e0"; C_BG="#f5f5f5"; C_PANEL="#ffffff"; C_ACC="#8a4a2a" ;;
  6) C_INK="#12181f"; C_SOFT="#556270"; C_LINE="#d7dee6"; C_BG="#f3f6f9"; C_PANEL="#ffffff"; C_ACC="#1f5f96" ;;
esac

FONT_STACK=$(pick font \
  '-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif' \
  'system-ui,"Segoe UI",Roboto,Helvetica,Arial,sans-serif' \
  '"Helvetica Neue",Helvetica,Arial,"Liberation Sans",sans-serif' \
  'ui-sans-serif,system-ui,-apple-system,"Segoe UI",Arial,sans-serif' \
  'Georgia,"Times New Roman",Times,serif')
BASE_SIZE=$(pick fsize 16 16.5 17 17.5)
BASE_LH=$(pick flh 1.55 1.6 1.65)
RADIUS=$(pick radius 0 2 3 4 6)
MEASURE=$(pick measure 64 68 70 74)
CARD_MIN=$(pick cardmin 280 300 320 340)
GAP_ROW=$(pick gaprow 2 2.4 2.8 3.2)
MAXW=$(pick maxw 1000 1040 1080 1140)

# Имена классов тоже входят в хеш файла — берём их из пулов.
K_WRAP=$(pick k1 wrap container shell inner bound)
K_HEAD=$(pick k2 site-head topbar masthead header-bar page-head)
K_BRAND=$(pick k3 brand logo wordmark title-mark)
K_NAV=$(pick k4 nav menu links topnav)
K_LEDE=$(pick k5 lede intro hero-copy opening)
K_EYE=$(pick k6 eyebrow kicker label overline)
K_GRID=$(pick k7 grid works reel gallery listing)
K_CARD=$(pick k8 work item entry piece tile)
K_BODY=$(pick k9 work-body item-body caption card-text)
K_META=$(pick k10 meta credits subline detail)
K_PROSE=$(pick k11 prose text page-copy article)
K_FOOT=$(pick k12 site-foot footer page-foot colophon)
CSS_NAME=$(pick cssname site.css main.css style.css app.css layout.css base.css)

# Четвёртая страница: её наличие, адрес и заголовок тоже различаются.
P4_SLUG=$(pick p4slug process approach services studio notes)

# ---------------------------------------------------------------------------
# ТЕКСТЫ
# ---------------------------------------------------------------------------
if [[ "$SITE_LANG" == "ru" ]]; then
  HTML_LANG="ru"
  T_BRAND_SUFFIX="видео"
  T_NAV_WORKS="Галерея"; T_NAV_ABOUT="О галерее"; T_NAV_CONTACT="Контакты"
  T_NAV_P4="Подборка"; T_P4_TITLE="Как собрана подборка"
  T_EYEBROW=$(pick teye "Избранное" "Витрина" "Из архива" "Работы")
  T_H1=$(pick th1 "Короткие формы: свет, движение и композиция" "Избранные короткие видео" "Визуальные этюды и фоновые лупы" "Кадры, движение и ритм")
  T_LEDE=$(pick tlede "Подборка видео с Pixabay: разные подходы к свету, ритму и композиции." "В этой галерее собраны короткие видео из каталога Pixabay." "Избранные кадры из Pixabay — для просмотра и вдохновения.")
  T_VIDEO_FALLBACK="Ваш браузер не умеет проигрывать это видео."
  T_ABOUT_DESC="О подборке видео и её источниках."
  T_CONTACT_DESC="Как найти авторов роликов."
  T_INDEX_DESC="$T_LEDE"
  T_404_TITLE="Страница не найдена"
  T_404_DESC="Такой страницы нет."
  T_404_BODY="Возможно, работу убрали из витрины. Вернитесь к <a href=\"/\">списку работ</a>."
  T_ERR_TITLE="Сервис временно недоступен"
  T_ERR_DESC="Страница сейчас недоступна."
  T_ERR_BODY="Запрос не удалось обработать. Попробуйте обновить страницу через минуту."
  T_FOOT1="видеогалерея."
  T_FOOT2="Материалы витрины — по лицензии Pixabay Content License."
  about_body() {
    cat <<EOF
<h1>О галерее</h1>
<p>$T_LEDE</p>
<p>На карточке каждого видео указаны источник и автор, если он указан в каталоге Pixabay. Ссылка ведёт на страницу оригинала.</p>
EOF
  }

  contact_body() {
    echo '<h1>Контакты</h1>'
    echo '<p>По вопросам о конкретном видео перейдите к оригиналу по ссылке на его карточке.</p>'
  }

  page4_body() {
    cat <<EOF
<h1>$T_P4_TITLE</h1>
<p>$T_LEDE</p>
<p>Ролики отбираются из открытого каталога Pixabay. Нажмите кнопку воспроизведения на карточке, чтобы посмотреть видео. Другие работы автора доступны на странице источника.</p>
EOF
  }
else
  HTML_LANG="en"
  T_BRAND_SUFFIX="video"
  T_NAV_WORKS="Gallery"; T_NAV_ABOUT="About"; T_NAV_CONTACT="Contact"
  T_NAV_P4="Collection"; T_P4_TITLE="How the collection is put together"
  T_EYEBROW=$(pick teye "Selected" "Recent work" "From the archive" "Showreel")
  T_H1=$(pick th1 "Short-form video: light, motion and composition" "Selected short films" "Visual studies and background loops" "Frames, movement and rhythm")
  T_LEDE=$(pick tlede "A selection of Pixabay footage exploring light, rhythm and composition." "This gallery collects short videos from the Pixabay catalogue." "Selected footage from Pixabay, for viewing and inspiration.")
  T_VIDEO_FALLBACK="Your browser cannot play this video."
  T_ABOUT_DESC="About the video collection and its sources."
  T_CONTACT_DESC="Find the original creators."
  T_INDEX_DESC="$T_LEDE"
  T_404_TITLE="Page not found"
  T_404_DESC="No such page."
  T_404_BODY="The video may have been removed. Return to the <a href=\"/\">gallery</a>."
  T_ERR_TITLE="Temporarily unavailable"
  T_ERR_DESC="This page is not available right now."
  T_ERR_BODY="The request could not be completed. Try reloading the page in a minute."
  T_FOOT1="video gallery."
  T_FOOT2="Reel footage licensed under the Pixabay Content License."
  about_body() {
    cat <<EOF
<h1>About the gallery</h1>
<p>$T_LEDE</p>
<p>Each video links to its original page on Pixabay, with the creator's name where it is listed in the catalogue.</p>
EOF
  }

  contact_body() {
    echo '<h1>Contact</h1>'
    echo '<p>For questions about an individual video, follow the source link on its card.</p>'
  }

  page4_body() {
    cat <<EOF
<h1>$T_P4_TITLE</h1>
<p>$T_LEDE</p>
<p>The videos are selected from the Pixabay catalogue. Use the controls on each card to play a clip, or follow its source link to see more from the creator.</p>
EOF
  }
fi

# Поисковый ответ хранится 24 часа вне каталога сайта.
if (( EUID == 0 )); then CACHE_DIR=/root/.cache/dest-gallery; else CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dest-gallery"; fi
mkdir -p -- "$CACHE_DIR"
python3 - "$CACHE_DIR" <<'PY_CACHE'
import os, stat, sys
from pathlib import Path
p = Path(sys.argv[1])
for d in (p, *p.parents):
    st = d.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid not in (0, os.geteuid()) or st.st_mode & 0o022:
        sys.exit(f"Небезопасный каталог кэша: {d}")
for child in p.iterdir():
    st = child.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & 0o077 or st.st_nlink != 1:
        sys.exit(f"Небезопасный файл кэша: {child}")
os.chmod(p, 0o700)
PY_CACHE
# Кэшируем страницы общего каталога по порядку и номеру.
api_json_valid() {
    python3 - "$1" 2>/dev/null <<'PY_JSON'
import json, sys
with open(sys.argv[1], encoding="utf-8") as file:
    response = json.load(file)
sys.exit(not (isinstance(response, dict) and isinstance(response.get("hits"), list)
              and type(response.get("totalHits")) is int and response["totalHits"] >= 0))
PY_JSON
}

api_key="${PIXABAY_API_KEY:-}"
unset PIXABAY_API_KEY
KEY_CONFIRMED=0
PAGE_FILES=()
MIN_SIZE_BYTES=$(( MIN_SIZE_MB * 1024 * 1024 ))

fetch_page() {
    local order="$1" page="$2" CACHE_ID CACHE_FILE CACHE_LOCK HTTP_CODE escaped
    # Пустое поле темы сохраняет совместимость с прежним кэшем общего каталога.
    CACHE_ID=$(printf '%s\n' 'https://pixabay.com/api/videos/' 'all' 'safesearch=true' "$FETCH_POOL" "$order" "$page" '' | sha256sum | cut -d ' ' -f1)
    CACHE_FILE="$CACHE_DIR/$CACHE_ID.json"
    exec {CACHE_LOCK}>"$CACHE_FILE.lock"
    flock "$CACHE_LOCK"
    if [[ -r "$CACHE_FILE" ]] && (( $(date +%s) - $(stat -c %Y -- "$CACHE_FILE") >= 0 && $(date +%s) - $(stat -c %Y -- "$CACHE_FILE") < 86400 )) && api_json_valid "$CACHE_FILE"; then
        cached_pages=$(( cached_pages + 1 ))
        log "Pixabay · $order · страница $page из кэша."
    else
        if [[ -z "$api_key" ]]; then
            IFS= read -rs -p 'Ключ Pixabay API: ' api_key || die 'Введите ключ Pixabay API в терминале.'
            printf '\n'
        fi
        [[ -n "$api_key" && "$api_key" != *$'\r'* && "$api_key" != *$'\n'* ]] || die 'Некорректный ключ Pixabay API.'
        # Для curl --config; ключ не передаётся в argv и не сохраняется в файле.
        escaped=${api_key//\\/\\\\}
        escaped=${escaped//\"/\\\"}
        escaped=${escaped//$'\t'/\\t}
        CACHE_TEMP=$(mktemp -- "$CACHE_DIR/.pixabay.XXXXXXXX")
        if (( ! KEY_CONFIRMED )); then log 'Проверяю ключ Pixabay API…'; fi
        api_pages=$(( api_pages + 1 ))
        log "Pixabay · $order · запрашиваю страницу $page…"
        HTTP_CODE=$(
            ulimit -f 8192
            printf 'data-urlencode = "key=%s"\n' "$escaped" |
            curl -q -s --max-filesize 8388608 --proto '=https' --get --config - \
                --data-urlencode 'video_type=all' --data-urlencode "order=$order" \
                --data-urlencode "page=$page" --data-urlencode "per_page=$FETCH_POOL" \
                --data-urlencode 'safesearch=true' \
                --connect-timeout 15 --max-time 60 \
                --dump-header "$TMP_DIR/api.headers" --output "$CACHE_TEMP" --write-out '%{http_code}' \
                'https://pixabay.com/api/videos/'
        ) || HTTP_CODE=000
        if grep -Eqi '^cf-mitigated:[[:space:]]*challenge' "$TMP_DIR/api.headers" 2>/dev/null || grep -Eqi '<title>[[:space:]]*Just a moment|/cdn-cgi/challenge-platform/|_cf_chl_opt' "$CACHE_TEMP"; then
            die 'Pixabay вернул страницу проверки Cloudflare. Это не означает неверный ключ.'
        fi
        case "$HTTP_CODE" in
            200) api_json_valid "$CACHE_TEMP" || die 'Pixabay вернул ответ без каталога видео.' ;;
            400|401) die "Pixabay отклонил запрос (HTTP $HTTP_CODE). Проверьте ключ." ;;
            403) die 'Pixabay запретил доступ (HTTP 403).' ;;
            429) die 'Pixabay вернул HTTP 429. Повторите сборку позже.' ;;
            000) die 'Не удалось установить соединение с Pixabay.' ;;
            *) die "Pixabay вернул HTTP $HTTP_CODE." ;;
        esac
        if (( ! KEY_CONFIRMED )); then
            log 'Ключ Pixabay API рабочий — каталог успешно получен.'
            KEY_CONFIRMED=1
        fi
        mv -Tf -- "$CACHE_TEMP" "$CACHE_FILE"
        CACHE_TEMP=""
    fi
    # Копия под блокировкой: параллельная сборка не меняет нашу выборку.
    local snapshot="$TMP_DIR/catalog-${#PAGE_FILES[@]}.json"
    cp -- "$CACHE_FILE" "$snapshot"
    PAGE_FILES+=("$snapshot")
    exec {CACHE_LOCK}>&-
}

page_count() {
    python3 - "$1" "$FETCH_POOL" <<'PY_PAGES'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    n = min(500, json.load(f)["totalHits"])
size = int(sys.argv[2])
print((n + size - 1) // size)
PY_PAGES
}

make_pool() {
    python3 - "$VIDEO_QUALITY" "$MIN_DURATION" "$MIN_SIZE_BYTES" "${PAGE_FILES[@]}" <<'PY_POOL' > "$TMP_DIR/pool.tsv"
import json
import random
import re
import sys

quality, min_duration, min_size, *filenames = sys.argv[1:]
min_duration, min_size = int(min_duration), int(min_size)

def media_url(value):
    if isinstance(value, str) and re.fullmatch(r"https://([A-Za-z0-9-]+\.)*pixabay\.com/[^\s\x00-\x1f\x7f]+", value):
        return value
    return "-"

def text(value):
    if not isinstance(value, str):
        return ""
    return " ".join(re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", value).split())

seen = set()
groups = []
for filename in filenames:
    with open(filename, encoding="utf-8") as file:
        hits = json.load(file)["hits"]
    for hit in hits:
        if not isinstance(hit, dict):
            continue
        duration, identifier = hit.get("duration"), hit.get("id")
        if (type(duration) is not int or not min_duration <= duration < 10**8
                or type(identifier) is not int or not 0 < identifier < 10**15 or identifier in seen):
            continue
        versions = hit.get("videos")
        if not isinstance(versions, dict):
            continue
        page = media_url(hit.get("pageURL"))
        if page == "-":
            page = f"https://pixabay.com/videos/id-{identifier}/"
        variants = ("medium", "small", "large", "tiny") if quality == "auto" else (quality,)
        rows = []
        for variant in variants:
            video = versions.get(variant)
            if not isinstance(video, dict):
                continue
            url, size = media_url(video.get("url")), video.get("size")
            if url == "-" or type(size) is not int or not min_size <= size <= 256 * 1024 * 1024:
                continue
            thumb = media_url(video.get("thumbnail"))
            width, height = video.get("width"), video.get("height")
            resolution = f"{width}×{height}" if type(width) is int and type(height) is int and width > 0 and height > 0 else "-"
            rows.append((identifier, url, thumb, page, duration, text(hit.get("tags")) or "Pixabay",
                         text(hit.get("user")) or "-", variant, size, resolution))
        if rows:
            seen.add(identifier)
            groups.append(rows)
random.shuffle(groups)
for rows in groups:
    for row in rows:
        print(*row, sep="\t")
PY_POOL
}

download_media() (
    local max_time="$1" maximum_kib="$2" destination="$3" url="$4" purpose="$5"
    local free_kib
    local -a display=(--silent --show-error)
    local -a stats=()
    free_kib=$(df -Pk -- "$STAGE" | awk 'NR == 2 {print $4}')
    [[ "$free_kib" =~ ^[0-9]+$ ]] || return 1
    (( free_kib > RESERVE_KIB )) || return 1
    if (( free_kib - RESERVE_KIB < maximum_kib )); then
        maximum_kib=$(( free_kib - RESERVE_KIB ))
    fi
    if [[ "$purpose" == video ]]; then
        stats=(--write-out '%{time_total} %{speed_download}')
        if [[ -t 2 && "${TERM:-dumb}" != dumb && -z "${SITE_PLAIN:-}" ]]; then
            display=(--progress-bar --show-error)
        fi
    fi
    ulimit -f "$maximum_kib" || return 1
    curl -q --fail "${display[@]}" --globoff --proto '=https' --connect-timeout 15 --max-time "$max_time" \
        --max-filesize "$(( maximum_kib * 1024 ))" "${stats[@]}" --output "$destination" -- "$url"
)

check_video() {
    python3 - "$1" "$MIN_DURATION" "$2" "$3" <<'PY_VIDEO'
import struct
import sys

def inspect(media, file_size, catalogue_duration, catalogue_resolution):
    remaining = 100000

    def fields(start, end, fmt):
        size = struct.calcsize(fmt)
        if end - start < size:
            raise ValueError("неполное поле MP4")
        media.seek(start)
        return struct.unpack(fmt, media.read(size))

    def boxes(start, end):
        nonlocal remaining
        while start < end:
            remaining -= 1
            if remaining < 0:
                raise ValueError("слишком много блоков MP4")
            size, name = fields(start, end, ">I4s")
            header = 8
            if size == 1:
                size, = fields(start + 8, end, ">Q")
                header = 16
            elif size == 0:
                size = end - start
            if name == b"uuid":
                header += 16
            if not header <= size <= end - start:
                raise ValueError("неполный блок MP4")
            yield name, start + header, start + size
            start += size

    def headers(start, end, names):
        return {name: (data, stop) for name, data, stop in boxes(start, end) if name in names}

    layout = set()
    movie = None
    for name, start, end in boxes(0, file_size):
        if name == b"ftyp" and end - start >= 8:
            layout.add(b"ftyp")
        elif name == b"mdat" and end > start:
            layout.add(b"mdat")
        elif name == b"moof":
            layout.add(b"moof")
        elif name == b"moov" and movie is None:
            movie = (start, end)
    if movie is None or not {b"ftyp", b"mdat"} <= layout:
        raise ValueError("отсутствуют обязательные блоки MP4")

    duration, resolution = 0, catalogue_resolution
    has_video = False
    for name, start, end in boxes(*movie):
        if name != b"trak":
            continue
        track = headers(start, end, {b"tkhd", b"mdia"})
        if not {b"tkhd", b"mdia"} <= track.keys():
            continue
        info = headers(*track[b"mdia"], {b"hdlr", b"mdhd", b"minf"})
        if not {b"hdlr", b"mdhd", b"minf"} <= info.keys():
            continue
        start, end = info[b"hdlr"]
        if fields(start + 8, end, "4s") != (b"vide",):
            continue
        media_info = headers(*info[b"minf"], {b"stbl"})
        if b"stbl" not in media_info:
            continue
        samples = headers(*media_info[b"stbl"], {b"stsd"})
        if b"stsd" not in samples:
            continue
        start, end = samples[b"stsd"]
        entries, = fields(start + 4, end, ">I")
        if not entries or sum(1 for _ in boxes(start + 8, end)) != entries:
            continue

        has_video = True
        start, end = info[b"mdhd"]
        version, = fields(start, end, "B")
        if version not in (0, 1):
            raise ValueError("неподдерживаемый заголовок дорожки")
        # В версии 1 время создания, изменения и длительность занимают 64 бита.
        scale, ticks = fields(start + (12 if version == 0 else 20), end, ">II" if version == 0 else ">IQ")
        if not scale:
            raise ValueError("некорректный масштаб времени")
        seconds = 0 if ticks == (1 << (32 if version == 0 else 64)) - 1 else ticks / scale
        if seconds >= duration:
            duration = seconds
            start, end = track[b"tkhd"]
            version, = fields(start, end, "B")
            if version in (0, 1):
                # Ширина и высота в tkhd записаны в формате 16.16.
                width, height = fields(start + (76 if version == 0 else 88), end, ">II")
                if width >> 16 and height >> 16:
                    resolution = f"{width >> 16}×{height >> 16}"
    if not has_video:
        raise ValueError("в MP4 нет видеодорожки")
    if not duration and b"moof" in layout:
        duration = catalogue_duration
    return duration, resolution

try:
    path, minimum, api_duration, api_resolution = sys.argv[1:]
    with open(path, "rb") as media:
        file_size = media.seek(0, 2)
        duration, resolution = inspect(media, file_size, int(api_duration), api_resolution)
    if duration <= 0 or duration < int(minimum):
        raise ValueError("слишком короткая видеодорожка")
    print(f"{resolution} {round(duration)}")
except (OSError, ValueError, struct.error):
    sys.exit(1)
PY_VIDEO
}

hdr "3/5 · Pixabay и видео"
log "Случайная выборка из общего каталога · Ролики: $VIDEO_COUNT · Качество: $VIDEO_QUALITY."
declare -a V_FILE V_POSTER V_TITLE V_TAGS V_DUR V_DESC
declare -A attempted accepted
ok=0; total_bytes=0; video_bytes=0; attempts=0; cached_pages=0; api_pages=0
for order in popular latest; do
    pages=1
    for (( page_no=1; page_no<=pages && ok<VIDEO_COUNT; page_no++ )); do
        fetch_page "$order" "$page_no"
        if (( page_no == 1 )); then pages=$(page_count "${PAGE_FILES[-1]}"); fi
        make_pool
        while IFS=$'\t' read -r identifier url thumb page duration tags author quality expected_bytes resolution && (( ok < VIDEO_COUNT )); do
            [[ -z "${accepted[$identifier]:-}" && -z "${attempted[$identifier:$quality]:-}" ]] || continue
            attempted[$identifier:$quality]=1
            attempts=$(( attempts + 1 ))
            slot=$(( ok + 1 ))
            video_file="assets/video/clip-$slot.mp4"
            printf '  [%d/%d · %d-я попытка] %s · %s · %s с · ≈%s МиБ\n' \
                "$slot" "$VIDEO_COUNT" "$attempts" "${tags:0:85}" "$resolution" "$duration" "$(mib "$expected_bytes")"
            if ! transfer=$(download_media 1800 262144 "$STAGE/$video_file" "$url" video); then
                warn "Ролик $identifier: загрузка не завершилась или не хватило места."
                rm -f -- "$STAGE/$video_file"
                continue
            fi
            actual_bytes=$(stat -c %s -- "$STAGE/$video_file")
            if (( actual_bytes < MIN_SIZE_BYTES || actual_bytes > 256 * 1024 * 1024 )) \
                || ! details=$(check_video "$STAGE/$video_file" "$duration" "$resolution"); then
                warn "Ролик $identifier: размер, длительность или структура MP4 не прошли проверку."
                rm -f -- "$STAGE/$video_file"
                continue
            fi
            duration="${details##* }"
            total_bytes=$(( total_bytes + actual_bytes ))
            video_bytes=$(( video_bytes + actual_bytes ))
            accepted[$identifier]=1
            rate=""
            if [[ "$transfer" =~ ^([0-9]+([.][0-9]+)?)[[:space:]]+([0-9]+([.][0-9]+)?)$ ]]; then
                rate=" · ${BASH_REMATCH[1]} с · $(mib "${BASH_REMATCH[3]}") МиБ/с"
            fi
            log "Готово $slot/$VIDEO_COUNT · ${details% *} · $(mib "$actual_bytes") МиБ$rate"

            poster_file=""
            if [[ "$thumb" != "-" ]]; then
                poster_file="assets/img/poster-$slot.jpg"
                if download_media 60 8192 "$STAGE/$poster_file" "$thumb" poster \
                    && python3 -c 'import sys; sys.exit(open(sys.argv[1], "rb").read(3) != b"\xff\xd8\xff")' "$STAGE/$poster_file"; then
                    total_bytes=$(( total_bytes + $(stat -c %s -- "$STAGE/$poster_file") ))
                else
                    rm -f -- "$STAGE/$poster_file"
                    poster_file=""
                fi
            fi

            [[ "$author" != "-" ]] || author=""
            title="${tags%%,*}"
            byline="Pixabay${author:+ · $author}"
            V_FILE+=("$video_file")
            V_POSTER+=("$poster_file")
            V_TITLE+=("$(esc "${title^}")")
            V_TAGS+=("$(esc "$tags")")
            V_DUR+=("$duration")
            V_DESC+=("<a href=\"$(esc "$page")\">$(esc "$byline")</a>")
            ok=$(( ok + 1 ))
        done < "$TMP_DIR/pool.tsv"
    done
done
unset api_key
log "Pixabay: страниц из кэша $cached_pages · загрузок API $api_pages."
(( ok > 0 )) || die 'Нет роликов, прошедших фильтры и проверку. Проверьте доступ к Pixabay и свободное место на диске.'
log "Видео: $ok · $(mib "$video_bytes") МиБ · все файлы медиа $(mib "$total_bytes") МиБ."
if (( ok < VIDEO_COUNT )); then
    if [[ -t 0 ]]; then
        read -rp "Готово $ok из $VIDEO_COUNT. Продолжить с этим количеством? [д/Н]: " partial
        [[ "$partial" =~ ^([yY]|[дД]|да|yes)$ ]] || die 'Сборка отменена.'
    else
        die 'Подготовлено меньше запрошенного количества роликов.'
    fi
fi

hdr "4/5 · Сборка страниц"
# --------------------------- CSS ---------------------------------------------
cat > "$STAGE/assets/css/$CSS_NAME" <<CSS
:root{
  --ink:$C_INK; --ink-soft:$C_SOFT; --line:$C_LINE;
  --paper:$C_BG; --panel:$C_PANEL; --accent:$C_ACC; --measure:${MEASURE}ch;
}
*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--paper);color:var(--ink);
  font:400 ${BASE_SIZE}px/${BASE_LH} $FONT_STACK;}
img,video{display:block;max-width:100%}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
a:focus-visible,button:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
.$K_WRAP{width:min(${MAXW}px,92vw);margin-inline:auto}
.$K_HEAD{border-bottom:1px solid var(--line);background:var(--panel)}
.$K_HEAD .$K_WRAP{display:flex;align-items:baseline;gap:2rem;padding:1.1rem 0;flex-wrap:wrap}
.$K_BRAND{font-weight:700;letter-spacing:-.02em;font-size:1.05rem;color:var(--ink)}
.$K_BRAND span{color:var(--ink-soft);font-weight:400}
.$K_NAV{margin-left:auto;display:flex;gap:1.4rem;font-size:.93rem}
.$K_NAV a{color:var(--ink-soft)}
.$K_NAV a[aria-current="page"]{color:var(--ink);font-weight:600}
.$K_LEDE{padding:4.5rem 0 3rem;border-bottom:1px solid var(--line)}
.$K_EYE{font-size:.75rem;letter-spacing:.14em;text-transform:uppercase;
  color:var(--ink-soft);margin:0 0 1rem}
.$K_LEDE h1{font-size:clamp(1.9rem,4.6vw,3rem);line-height:1.12;letter-spacing:-.03em;
  margin:0 0 1rem;max-width:20ch;font-weight:700}
.$K_LEDE p{margin:0;max-width:54ch;color:var(--ink-soft)}
.$K_GRID{display:grid;gap:${GAP_ROW}rem 2rem;padding:3rem 0;
  grid-template-columns:repeat(auto-fill,minmax(${CARD_MIN}px,1fr))}
.$K_CARD{background:var(--panel);border:1px solid var(--line);border-radius:${RADIUS}px;
  overflow:hidden;display:flex;flex-direction:column}
.$K_CARD video{width:100%;aspect-ratio:16/9;background:#0d0f10;object-fit:cover}
.$K_BODY{padding:1.15rem 1.25rem 1.4rem}
.$K_BODY h2{font-size:1.08rem;margin:0 0 .2rem;letter-spacing:-.01em}
.$K_META{font-size:.78rem;color:var(--ink-soft);margin:0 0 .7rem}
.$K_BODY p{margin:0;font-size:.93rem;color:var(--ink-soft)}
.$K_PROSE{padding:3.5rem 0;max-width:var(--measure)}
.$K_PROSE h1{font-size:2rem;letter-spacing:-.025em;margin:0 0 1.2rem}
.$K_PROSE h2{font-size:1.15rem;margin:2.2rem 0 .6rem}
.$K_PROSE dl{display:grid;grid-template-columns:9rem 1fr;gap:.5rem 1rem;margin:1.5rem 0}
.$K_PROSE dt{color:var(--ink-soft);font-size:.9rem}
.$K_PROSE dd{margin:0}
.$K_FOOT{border-top:1px solid var(--line);margin-top:2rem;padding:2.2rem 0 3rem;
  font-size:.85rem;color:var(--ink-soft)}
.$K_FOOT p{margin:.25rem 0}
@media (prefers-reduced-motion:no-preference){
  .$K_CARD{transition:border-color .2s ease}
  .$K_CARD:hover{border-color:var(--ink-soft)}
}
@media (max-width:520px){
  .$K_HEAD .$K_WRAP{gap:.8rem}
  .$K_NAV{width:100%;margin-left:0;gap:1.1rem}
  .$K_LEDE{padding:3rem 0 2.2rem}
  .$K_PROSE dl{grid-template-columns:1fr;gap:.15rem}
}
CSS

# --------------------------- ФАВИКОН -----------------------------------------
ACC_R=$(( 16#${C_ACC:1:2} )); ACC_G=$(( 16#${C_ACC:3:2} )); ACC_B=$(( 16#${C_ACC:5:2} ))
GLYPH_ID=$(( $(seed_idx glyph) % 4 ))
SVG_RADIUS=$(pick svgr 0 3 5 8)

cat > "$STAGE/assets/img/favicon.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <rect width="32" height="32" rx="$SVG_RADIUS" fill="$C_ACC"/>
  <text x="16" y="23" font-family="Helvetica,Arial,sans-serif" font-size="20"
        font-weight="700" text-anchor="middle" fill="$C_BG">$BRAND_INITIAL</text>
</svg>
SVG

python3 - "$STAGE/favicon.ico" "$ACC_R" "$ACC_G" "$ACC_B" "$GLYPH_ID" <<'PY' \
    && log "favicon.ico создан" || die "Не удалось создать favicon.ico."
import struct, sys
path = sys.argv[1]
r, g, b, gid = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
W = H = 16
bg = (b, g, r, 255)            # BMP хранит цвет как BGRA
fg = (0xF7, 0xF7, 0xF5, 255)
GLYPHS = [
 # M
 ["................","................","..#..........#..","..##........##..",
  "..#.#......#.#..","..#..#....#..#..","..#...#..#...#..","..#....##....#..",
  "..#..........#..","..#..........#..","..#..........#..","..#..........#..",
  "................","................","................","................"],
 # шеврон
 ["................","................","................",".....##.........",
  "......##........",".......##.......","........##......",".........##.....",
  "........##......",".......##.......","......##........",".....##.........",
  "................","................","................","................"],
 # кольцо
 ["................","................",".....####.......","...##....##.....",
  "..##......##....","..#........#....","..#........#....","..#........#....",
  "..#........#....","..##......##....","...##....##.....",".....####.......",
  "................","................","................","................"],
 # рамка кадра
 ["................","................","..##########....","..#........#....",
  "..#........#....","..#........#....","..#........#....","..#........#....",
  "..#........#....","..#........#....","..##########....","................",
  "................","................","................","................"],
]
glyph = GLYPHS[gid % len(GLYPHS)]
xor = b"".join(bytes(fg if glyph[y][x] == "#" else bg)
               for y in range(H - 1, -1, -1) for x in range(W))
and_mask = b"\x00" * (H * 4)
dib = struct.pack("<IiiHHIIiiII", 40, W, H * 2, 1, 32, 0, len(xor), 0, 0, 0, 0)
img = dib + xor + and_mask
ico = struct.pack("<HHH", 0, 1, 1) + \
      struct.pack("<BBBBHHII", W, H, 0, 0, 1, 32, len(img), 22) + img
open(path, "wb").write(ico)
PY

# --------------------------- СТРАНИЦЫ ----------------------------------------
YEAR=$(date +%Y); TODAY=$(date +%F)

emit_head() {
cat <<EOF
<!DOCTYPE html>
<html lang="$HTML_LANG">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$1 — ${STUDIO_NAME}</title>
<meta name="description" content="$2">
<link rel="canonical" href="${SITE_SCHEME}://${DOMAIN}$3">
<link rel="icon" href="/favicon.ico" sizes="32x32">
<link rel="icon" href="/assets/img/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/assets/css/${CSS_NAME}">
</head>
<body>
<header class="$K_HEAD"><div class="$K_WRAP">
  <a class="$K_BRAND" href="/">${STUDIO_NAME} <span>/ ${T_BRAND_SUFFIX}</span></a>
  <nav class="$K_NAV">
    <a href="/"$([[ "$3" == "/" ]] && echo ' aria-current="page"')>${T_NAV_WORKS}</a>
    <a href="/${P4_SLUG}.html"$([[ "$3" == "/${P4_SLUG}.html" ]] && echo ' aria-current="page"')>${T_NAV_P4}</a>
    <a href="/about.html"$([[ "$3" == "/about.html" ]] && echo ' aria-current="page"')>${T_NAV_ABOUT}</a>
    <a href="/contact.html"$([[ "$3" == "/contact.html" ]] && echo ' aria-current="page"')>${T_NAV_CONTACT}</a>
  </nav>
</div></header>
EOF
}

emit_foot() {
cat <<EOF
<footer class="$K_FOOT"><div class="$K_WRAP">
  <p>${STUDIO_NAME} — ${T_FOOT1}</p>
  <p>© ${YEAR}. ${T_FOOT2}</p>
</div></footer>
</body>
</html>
EOF
}

{
emit_head "${T_NAV_WORKS}" "$T_INDEX_DESC" "/"
cat <<EOF
<main>
<section class="$K_LEDE"><div class="$K_WRAP">
  <p class="$K_EYE">${T_EYEBROW} · ${YEAR}</p>
  <h1>${T_H1}</h1>
  <p>${T_LEDE}</p>
</div></section>
<div class="$K_WRAP"><div class="$K_GRID">
EOF
for i in "${!V_FILE[@]}"; do
    dur="${V_DUR[$i]}"; dur_txt=""
    (( dur > 0 )) && dur_txt=" · $(printf '%d:%02d' $((dur/60)) $((dur%60)))"
    poster_attr=""
    [[ -n "${V_POSTER[$i]}" ]] && poster_attr=" poster=\"/${V_POSTER[$i]}?v=$MEDIA_VERSION\""
    # Видео загружается при воспроизведении, до этого виден постер.
cat <<EOF
  <article class="$K_CARD">
    <video controls preload="none" playsinline$poster_attr>
      <source src="/${V_FILE[$i]}?v=$MEDIA_VERSION" type="video/mp4">
      ${T_VIDEO_FALLBACK}
    </video>
    <div class="$K_BODY">
      <h2>${V_TITLE[$i]}</h2>
      <p class="$K_META">${V_TAGS[$i]}${dur_txt}</p>
      <p>${V_DESC[$i]}</p>
    </div>
  </article>
EOF
done
echo "</div></div></main>"
emit_foot
} > "$STAGE/index.html"

{
emit_head "$T_NAV_ABOUT" "$T_ABOUT_DESC" "/about.html"
echo "<main class=\"$K_WRAP\"><div class=\"$K_PROSE\">"
about_body
echo "</div></main>"
emit_foot
} > "$STAGE/about.html"

{
emit_head "$T_NAV_CONTACT" "$T_CONTACT_DESC" "/contact.html"
echo "<main class=\"$K_WRAP\"><div class=\"$K_PROSE\">"
contact_body
echo "</div></main>"
emit_foot
} > "$STAGE/contact.html"

{
emit_head "$T_NAV_P4" "$T_P4_TITLE" "/${P4_SLUG}.html"
echo "<main class=\"$K_WRAP\"><div class=\"$K_PROSE\">"
page4_body
echo "</div></main>"
emit_foot
} > "$STAGE/${P4_SLUG}.html"

{
emit_head "$T_404_TITLE" "$T_404_DESC" "/404.html"
cat <<EOF
<main class="$K_WRAP"><div class="$K_PROSE">
<h1>${T_404_TITLE}</h1>
<p>${T_404_BODY}</p>
</div></main>
EOF
emit_foot
} > "$STAGE/404.html"

{
emit_head "$T_ERR_TITLE" "$T_ERR_DESC" "/error.html"
cat <<EOF
<main class="$K_WRAP"><div class="$K_PROSE">
<h1>${T_ERR_TITLE}</h1>
<p>${T_ERR_BODY}</p>
</div></main>
EOF
emit_foot
} > "$STAGE/error.html"

cat > "$STAGE/robots.txt" <<EOF
User-agent: *
Allow: /
Disallow: /error.html

Sitemap: ${SITE_SCHEME}://${DOMAIN}/sitemap.xml
EOF

cat > "$STAGE/sitemap.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>${SITE_SCHEME}://${DOMAIN}/</loc><lastmod>${TODAY}</lastmod><priority>1.0</priority></url>
  <url><loc>${SITE_SCHEME}://${DOMAIN}/${P4_SLUG}.html</loc><lastmod>${TODAY}</lastmod><priority>0.7</priority></url>
  <url><loc>${SITE_SCHEME}://${DOMAIN}/about.html</loc><lastmod>${TODAY}</lastmod><priority>0.6</priority></url>
  <url><loc>${SITE_SCHEME}://${DOMAIN}/contact.html</loc><lastmod>${TODAY}</lastmod><priority>0.6</priority></url>
</urlset>
EOF

# Готовая сборка появляется под заданным именем после записи всех файлов.
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
mv -Tn -- "$STAGE" "$OUTPUT"
[[ ! -d "$STAGE" ]] || die "За время сборки появился каталог $OUTPUT. Выберите другой путь."
STAGE=""
log "Готово · $ok роликов · $(du -sh -- "$OUTPUT" | cut -f1) · $OUTPUT"
