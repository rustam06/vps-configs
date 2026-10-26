#!/usr/bin/env python3
"""Convert VLESS share links to Remnawave/Xray outbounds (Xray 26.7.28).

Python 3.8+, standard library only. No network calls, package installation,
or profile changes. Run without URI arguments for hidden interactive input.
"""
from __future__ import annotations

import argparse
import base64
import getpass
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid as uuidlib
from urllib.parse import parse_qsl, unquote, urlsplit

VERSION = "2.0"
TARGET_XRAY = "26.7.28"
TRANSPORTS = {"tcp": "tcp", "raw": "tcp", "ws": "ws", "websocket": "ws",
              "grpc": "grpc", "xhttp": "xhttp", "splithttp": "xhttp",
              "httpupgrade": "httpupgrade"}
FLOWS = {"", "xtls-rprx-vision", "xtls-rprx-vision-udp443"}
FINGERPRINTS = set("""chrome firefox safari ios android edge 360 qq random
randomized randomizednoalpn unsafe hellogolang hellorandomized
hellorandomizedalpn hellorandomizednoalpn hellofirefox_auto hellofirefox_55
hellofirefox_56 hellofirefox_63 hellofirefox_65 hellofirefox_99 hellofirefox_102
hellofirefox_105 hellofirefox_120 hellofirefox_148 hellochrome_auto hellochrome_58 hellochrome_62
hellochrome_70 hellochrome_72 hellochrome_83 hellochrome_87 hellochrome_96
hellochrome_100 hellochrome_102 hellochrome_106_shuffle hellochrome_120
hellochrome_131 hellochrome_133 helloios_auto helloios_11_1 helloios_12_1
helloios_13 helloios_14 helloandroid_11_okhttp helloedge_85 helloedge_106
helloedge_auto hellosafari_16_0 hellosafari_26_3 hellosafari_auto hello360_auto hello360_7_5
hello360_11_0 helloqq_auto helloqq_11_1 hellochrome_100_psk
hellochrome_112_psk_shuf hellochrome_114_padding_psk_shuf hellochrome_115_pq
hellochrome_115_pq_psk hellochrome_120_pq""".split())
PRIVATE_NETWORKS = tuple(ipaddress.ip_network(x) for x in """0.0.0.0/8
10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15
198.51.100.0/24 203.0.113.0/24 224.0.0.0/3 ::/127 fc00::/7 fe80::/10
ff00::/8""".split())


class ConfigError(ValueError):
    """A user-facing error that must not include a secret share URI."""


def warn(message):
    print("Предупреждение: " + message, file=sys.stderr)


def slugify(name: str, maxlen: int = 80) -> str:
    # Input has already been URL-decoded. Do not decode fragments twice.
    safe = re.sub(r"[^0-9A-Za-zА-Яа-яЁё._\-]", "", name or "").strip(".")
    safe = (safe or "outbound")[:maxlen]
    if safe.split(".")[0].upper() in {"CON", "PRN", "AUX", "NUL"} | {
            "COM" + str(i) for i in range(1, 10)} | {"LPT" + str(i) for i in range(1, 10)}:
        safe = "outbound-" + safe
    return safe


def to_bool(value: str) -> bool:
    if value.lower() in {"1", "true", "yes", "on"}:
        return True
    if value.lower() in {"0", "false", "no", "off"}:
        return False
    raise ConfigError("Boolean-параметр должен содержать true/false или 1/0.")


def guess_port(security: str, network: str) -> int:
    return 80 if security == "none" and network in {"ws", "grpc", "xhttp", "httpupgrade"} else 443


def clean_text(value, label):
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ConfigError(label + ": управляющие символы недопустимы.")
    return value


def normalize_address(value):
    clean_text(value, "Адрес")
    if not value or any(c.isspace() for c in value) or any(c in value for c in "/\\@?#%"):
        raise ConfigError("Некорректный адрес сервера или SNI.")
    if value.endswith(".."):
        raise ConfigError("Некорректное доменное имя: несколько завершающих точек.")
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        if ":" in value:
            raise ConfigError("Некорректный IPv6-адрес.") from None
    try:
        ascii_name = value.encode("idna").decode("ascii").lower()
    except UnicodeError:
        raise ConfigError("Некорректное доменное имя.") from None
    if len(ascii_name) > 253 or any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", x)
                                     for x in ascii_name.rstrip(".").split(".")):
        raise ConfigError("Некорректное доменное имя.")
    return ascii_name


def is_private_address(address):
    try:
        ip = ipaddress.ip_address(address)
        return any(ip.version == net.version and ip in net for net in PRIVATE_NETWORKS)
    except ValueError:
        name = address.lower().rstrip(".")
        suffixes = {"lan", "localdomain", "example", "invalid", "localhost", "test", "local", "home.arpa", "internal"}
        return (bool(re.fullmatch(r"[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?", name))
                or any(name == s or name.endswith("." + s) for s in suffixes))


def normalize_sni(value):
    if value.startswith("[") and value.endswith("]"):
        try:
            return "[" + str(ipaddress.IPv6Address(value[1:-1])) + "]"
        except ValueError:
            raise ConfigError("Некорректный IPv6 в SNI.") from None
    address = normalize_address(value)
    return "[" + address + "]" if ":" in address else address


def check_base64url(value, sizes, label):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise ConfigError(label + ": требуется base64url без знаков '='.")
    try:
        raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except (ValueError, base64.binascii.Error):
        raise ConfigError(label + ": некорректное base64url-значение.") from None
    if len(raw) not in sizes or base64.urlsafe_b64encode(raw).decode().rstrip("=") != value:
        raise ConfigError(label + ": неверная длина или кодировка ключа.")


def check_identifier(value):
    clean_text(value, "ID")
    if not value:
        raise ConfigError("Отсутствует UUID/ID перед @.")
    if re.fullmatch(r"(?:[0-9A-Fa-f]{32}|[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})", value):
        return str(uuidlib.UUID(value))
    if len(value.encode("utf-8")) <= 30:
        return value  # Xray maps short custom strings to UUIDv5 itself.
    raise ConfigError("ID должен быть UUID или строкой до 30 байтов UTF-8.")


def check_encryption(value):
    if value == "none":
        return
    blocks = value.split(".")
    if (len(blocks) < 4 or blocks[0] != "mlkem768x25519plus"
            or blocks[1] not in {"native", "xorpub", "random"}
            or blocks[2] not in {"0rtt", "1rtt"}):
        raise ConfigError("Неподдерживаемый encryption: нужен none или полный параметр VLESS Encryption.")
    keys = 0
    padding = []
    for block in blocks[3:]:
        if len(block) >= 20:
            check_base64url(block, {32, 1184}, "encryption")
            keys += 1
        else:
            # Core removes padding as one prefix before parsing the key chain.
            if keys:
                raise ConfigError("В encryption блоки padding должны находиться перед всеми ключами.")
            if not re.fullmatch(r"[0-9]+-[0-9]+-[0-9]+", block):
                raise ConfigError("Некорректный блок padding в encryption.")
            dimensions = tuple(int(part) for part in block.split("-"))
            if any(part > (1 << 63) - 1 for part in dimensions):
                raise ConfigError("Число в padding превышает диапазон Xray.")
            padding.append(dimensions)
    if not keys or len(blocks[-1]) < 20:
        raise ConfigError("В encryption отсутствует завершающий ключ сервера.")
    if padding:
        probability, minimum, maximum = padding[0]
        if probability < 100 or minimum < 35 or maximum < 35:
            raise ConfigError("Первый padding в encryption требует вероятность не менее 100 и обе длины не менее 35 байтов.")
        # Even blocks are padding lengths; odd blocks are delays in milliseconds.
        if sum(max(item[1], item[2]) for item in padding[::2]) > 65553:
            raise ConfigError("Суммарная максимальная длина padding в encryption не должна превышать 65553 байта.")
    # With no explicit padding, Xray supplies its own default length/delay blocks.


def json_object(value, label):
    def pairs(items):
        obj = {}
        for key, val in items:
            if key in obj:
                raise ValueError("duplicate")
            obj[key] = val
        return obj
    def invalid_constant(_):
        raise ValueError("nonfinite")
    try:
        result = json.loads(value, object_pairs_hook=pairs, parse_constant=invalid_constant)
    except (ValueError, RecursionError):
        raise ConfigError(label + ": требуется корректный JSON без повторных полей.") from None
    if not isinstance(result, dict):
        raise ConfigError(label + ": требуется JSON-объект.")
    return result


class Params:
    def __init__(self, pairs):
        self.values = {}
        self.used = set()
        for key, val in pairs:
            clean_text(key, "Параметр")
            clean_text(val, "Значение параметра")
            if key in self.values:
                raise ConfigError("Параметры ссылки не должны повторяться.")
            self.values[key] = val

    def get(self, *names, default="", empty=True):
        found = [name for name in names if name in self.values]
        self.used.update(found)
        values = [self.values[name] for name in found]
        if len(set(values)) > 1:
            raise ConfigError("Конфликт значений параметров-синонимов: " + "/".join(names) + ".")
        value = values[0] if values else default
        if not empty and not value:
            raise ConfigError("Параметр " + names[0] + " не может быть пустым.")
        return value

    def finish(self, ignore_unknown, warning):
        unused = sorted(self.values.keys() - self.used)
        if not unused:
            return
        names = ", ".join(re.sub(r"[^a-zA-Z0-9_.-]", "?", x)[:40] for x in unused)
        message = "Неподдерживаемые или неприменимые параметры: " + names + "."
        if not ignore_unknown:
            raise ConfigError(message + " Удалите их или явно укажите --ignore-unknown.")
        warning(message + " Значения пропущены по --ignore-unknown.")


def build_stream_settings(params, security, network, address="", warning=warn):
    """Accept a Params object or the old dict-of-lists API."""
    if not isinstance(params, Params):
        params = Params((key, val) for key, values in params.items() for val in values)
    ss = {"network": network, "security": security}
    if security in {"tls", "reality"}:
        sni = normalize_sni(params.get("sni", "serverName", default=address, empty=False))
        fp = (params.get("fp", "fingerprint", default="chrome") or "chrome").lower()
        if fp not in FINGERPRINTS or (security == "reality" and fp in {"unsafe", "hellogolang"}):
            raise ConfigError("Неподдерживаемый fingerprint для выбранной защиты.")
        options = {"serverName": sni, "fingerprint": fp}
        if security == "tls":
            alpn = params.get("alpn")
            if alpn:
                parts = [x.strip() for x in alpn.split(",")]
                if any(not x or len(x.encode("utf-8")) > 255 for x in parts):
                    raise ConfigError("Некорректный список alpn.")
                options["alpn"] = parts
            insecure = params.get("insecure", "allowInsecure")
            if insecure and to_bool(insecure):
                raise ConfigError("allowInsecure=true удалён из Xray 26.7.28. Укажите доверенный сертификат или параметры pcs/vcn.")
            pcs = params.get("pcs", "pinnedPeerCertSha256")
            if pcs:
                pins = [x.strip().replace(":", "") for x in pcs.split(",")]
                if any(not re.fullmatch(r"[a-fA-F0-9]{64}", x) for x in pins):
                    raise ConfigError("pcs: требуется SHA-256 сертификата в hex (64 символа).")
                options["pinnedPeerCertSha256"] = ",".join(pins)
            for uri_field, json_field in (("vcn", "verifyPeerCertByName"), ("ech", "echConfigList")):
                value = params.get(uri_field, json_field)
                if value:
                    options[json_field] = value
            ss["tlsSettings"] = options
        else:
            key = params.get("pbk", "publicKey", "password", empty=False)
            check_base64url(key, {32}, "pbk/password")
            sid = params.get("sid", "shortId")
            if not re.fullmatch(r"(?:[a-fA-F0-9]{2}){0,8}", sid):
                raise ConfigError("sid: нужно чётное число hex-символов, максимум 16; пустое значение допустимо.")
            options.update(password=key, shortId=sid)
            spx = params.get("spx", "spiderX")
            if spx:
                if not spx.startswith("/"):
                    raise ConfigError("spx должен начинаться с '/'.")
                options["spiderX"] = spx
            pqv = params.get("pqv", "mldsa65Verify")
            if pqv:
                check_base64url(pqv, {1952}, "pqv")
                options["mldsa65Verify"] = pqv
            ss["realitySettings"] = options
    if network in {"ws", "httpupgrade", "xhttp"}:
        path = params.get("path", default="/", empty=False)
        if not path.startswith("/"):
            raise ConfigError("path должен начинаться с '/'.")
        options = {"path": path}
        host = params.get("host", "hostHeader")
        if host:
            if any(x.isspace() for x in host) or any(x in host for x in "/\\@?#"):
                raise ConfigError("Некорректный HTTP Host.")
            options["host"] = host
        if network == "xhttp":
            mode = params.get("mode", default="auto", empty=False)
            if mode not in {"auto", "packet-up", "stream-up", "stream-one"}:
                raise ConfigError("XHTTP mode должен быть auto, packet-up, stream-up или stream-one.")
            options["mode"] = mode
            extra = params.get("extra")
            if extra:
                obj = json_object(extra, "extra")
                # These fields are overridden by Xray when nested under extra.
                if {"host", "path", "mode", "extra"} & obj.keys():
                    raise ConfigError("extra не должен содержать host/path/mode/extra: задайте их параметрами ссылки.")
                if isinstance(obj.get("headers"), dict) and any(x.lower() == "host" for x in obj["headers"]):
                    raise ConfigError("extra.headers не должен содержать Host: используйте параметр host.")
                if mode == "stream-one" and "downloadSettings" in obj:
                    raise ConfigError("XHTTP stream-one несовместим с downloadSettings.")
                options["extra"] = obj
        ss[{"ws": "wsSettings", "httpupgrade": "httpupgradeSettings", "xhttp": "xhttpSettings"}[network]] = options
    elif network == "grpc":
        options = {}
        service = params.get("serviceName", "path")
        if service:
            options["serviceName"] = service
        authority = params.get("authority")
        if authority:
            options["authority"] = authority
        mode = params.get("mode", default="gun", empty=False)
        if mode not in {"gun", "multi"}:
            raise ConfigError("gRPC mode должен быть gun или multi.")
        options["multiMode"] = mode == "multi"
        ss["grpcSettings"] = options
    elif network == "tcp":
        header = params.get("headerType", default="none", empty=False)
        if header != "none":
            raise ConfigError("RAW headerType поддерживается только none; HTTP-обфускацию этот генератор не преобразует.")
    fm = params.get("fm")
    if fm:
        ss["finalmask"] = json_object(fm, "fm")
    return ss


def convert_vless_to_json(vless_link: str, *, ignore_unknown=False, warning=warn, allow_advanced=False) -> dict:
    link = vless_link.strip()
    clean_text(link, "Ссылка")
    if re.search(r"%(?![0-9a-fA-F]{2})", link):
        raise ConfigError("Некорректное percent-кодирование в ссылке.")
    try:
        parsed = urlsplit(link)
        if parsed.scheme.lower() != "vless":
            raise ConfigError("Ссылка должна начинаться с vless://.")
        if parsed.password is not None:
            raise ConfigError("Формат ID:password@host для VLESS не поддерживается.")
        identifier = check_identifier(unquote(parsed.username or "", errors="strict"))
        address = normalize_address(parsed.hostname or "")
        explicit_port = parsed.port
        if parsed.netloc.endswith(":"):
            raise ConfigError("После ':' должен быть указан порт.")
        if parsed.path not in {"", "/"}:
            raise ConfigError("Путь после адреса не поддерживается; используйте query-параметр path.")
        params = Params(parse_qsl(parsed.query, keep_blank_values=True, errors="strict", max_num_fields=256))
        tag = clean_text(unquote(parsed.fragment, errors="strict"), "Имя подключения")
    except ConfigError:
        raise
    except (ValueError, UnicodeError):
        raise ConfigError("Некорректная ссылка: проверьте адрес, порт и UTF-8-кодирование.") from None
    requested_network = params.get("type", default="tcp", empty=False).lower()
    if requested_network in {"http", "h2", "h3", "quic"}:
        raise ConfigError("Этот транспорт удалён из Xray 26.7.28. Нужны новая ссылка и соответствующая настройка сервера; замена на XHTTP автоматически невозможна.")
    if requested_network not in TRANSPORTS:
        raise ConfigError("Неподдерживаемый транспорт. Доступны tcp/raw, ws, grpc, xhttp и httpupgrade.")
    network = TRANSPORTS[requested_network]
    if any(key in params.values for key in ("extra", "fm")):
        if not allow_advanced:
            raise ConfigError("Вложенные настройки extra/fm требуют проверки ядром: укажите --check-xray PATH.")
        if any(not params.values[key] for key in ("extra", "fm") if key in params.values):
            raise ConfigError("extra/fm не могут быть пустой строкой: нужен JSON-объект.")
    security = params.get("security", default="none", empty=False).lower()
    if security not in {"none", "tls", "reality"}:
        raise ConfigError("security должен быть none, tls или reality.")
    if security == "reality" and network not in {"tcp", "grpc", "xhttp"}:
        raise ConfigError("REALITY совместим только с tcp/raw, grpc и xhttp.")
    port = explicit_port if explicit_port is not None else guess_port(security, network)
    if not 1 <= port <= 65535:
        raise ConfigError("Порт должен быть от 1 до 65535.")
    if explicit_port is None:
        warning("Порт отсутствует в ссылке; для совместимости выбран " + str(port) + ". Лучше указывать его явно.")
    encryption = params.get("encryption", default="none", empty=False)
    check_encryption(encryption)
    flow = params.get("flow")
    if flow not in FLOWS:
        raise ConfigError("Поддерживаются flow xtls-rprx-vision, xtls-rprx-vision-udp443 или пустой.")
    if flow and encryption == "none" and (network != "tcp" or security not in {"tls", "reality"}):
        raise ConfigError("Vision без VLESS Encryption требует tcp/raw с TLS или REALITY.")
    if security == "none" and encryption == "none" and not is_private_address(address):
        raise ConfigError("Для публичного VLESS-адреса требуется TLS/REALITY или VLESS Encryption.")
    user = {"id": identifier, "encryption": encryption}
    if flow:
        user["flow"] = flow
    stream = build_stream_settings(params, security, network, address, warning)
    params.finish(ignore_unknown, warning)
    display_address = "[" + address + "]" if ":" in address else address
    return {"protocol": "vless", "tag": tag or display_address + ":" + str(port),
            "settings": {"vnext": [{"address": address, "port": port, "users": [user]}]},
            "streamSettings": stream}


def serialize(value):
    return json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n"


def validate_with_xray(outbounds, executable):
    # A temporary complete envelope is only for -test, never for deployment.
    with tempfile.TemporaryDirectory(prefix="genconf-check-") as directory:
        path = Path(directory) / "config.json"
        fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(serialize({"log": {"loglevel": "warning"}, "outbounds": outbounds}))
        try:
            result = subprocess.run([executable, "run", "-test", "-config", str(path)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            raise ConfigError("Не удалось запустить проверку Xray; проверьте путь к исполняемому файлу.") from None
        if result.returncode:
            # Core errors may print credentials (including keys nested in extra).
            # Do not dump those logs into a possibly shared terminal.
            raise ConfigError("Xray отклонил конфиг. Проверьте версию ядра и дополнительные поля extra/fm; JSON не сохранён.")


def save_json(directory, stem, text, force=False):
    index = 1
    while True:
        name = stem if index == 1 else stem + "-" + str(index)
        destination = directory / (name + ".json")
        if not destination.exists() or (force and index == 1):
            break
        index += 1
    fd, temporary = tempfile.mkstemp(prefix=".genconf-", dir=str(directory))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        if force:
            os.replace(temporary, destination)
        else:
            # Publish without overwriting an existing path, including races.
            while True:
                try:
                    os.link(temporary, destination)
                    break
                except FileExistsError:
                    index += 1
                    destination = directory / (stem + "-" + str(index) + ".json")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return destination


def main(argv=None):
    parser = argparse.ArgumentParser(description="VLESS URI → outbound JSON для Remnawave / Xray " + TARGET_XRAY)
    parser.add_argument("uri", nargs="*", help="Ссылки vless:// (в кавычках)")
    parser.add_argument("-o", "--outdir", default=".", help="Каталог JSON-файлов")
    parser.add_argument("--stdout", action="store_true", help="Только JSON в stdout")
    parser.add_argument("-i", "--input", action="append", default=[], metavar="FILE", help="Файл ссылок, по одной на строку; можно повторять")
    parser.add_argument("--stdin", action="store_true", help="Прочитать ссылки из stdin")
    formats = parser.add_mutually_exclusive_group()
    formats.add_argument("--outbounds", action="store_true", help="Объект {outbounds: [...]} вместо отдельных outbound")
    formats.add_argument("--snippet", action="store_true", help="Массив [...] для Remnawave Outbound Snippet, даже для одной ссылки")
    parser.add_argument("--tag", help="Задать стабильный tag для одной ссылки (для routing.outboundTag)")
    parser.add_argument("--check-xray", metavar="PATH", help="Дополнительно проверить ядром: PATH run -test; соединение не проверяется")
    parser.add_argument("--force", action="store_true", help="Разрешить замену существующих JSON-файлов")
    parser.add_argument("--ignore-unknown", action="store_true", help="Пропускать неизвестные/неприменимые query-параметры с предупреждением")
    parser.add_argument("--version", action="version", version="genconf " + VERSION + " (target Xray " + TARGET_XRAY + ")")
    args = parser.parse_args(argv)
    try:
        links = list(args.uri)
        for filename in args.input:
            if filename == "-":
                raise ConfigError("Для stdin используйте --stdin; --input ожидает имя файла.")
            links.extend(x.strip() for x in Path(filename).read_text(encoding="utf-8-sig").splitlines()
                         if x.strip() and not x.lstrip().startswith("#"))
        if args.stdin or (not links and not sys.stdin.isatty()):
            links.extend(x.strip() for x in sys.stdin.read().splitlines() if x.strip() and not x.lstrip().startswith("#"))
        if not links and sys.stdin.isatty():
            # Prompt goes to stderr; the actual URI is hidden and stays out of argv.
            links = [getpass.getpass("Вставьте VLESS-ссылку и нажмите Enter (ввод скрыт): ")]
        if not links:
            raise ConfigError("Нет ссылок: передайте URI, --input FILE или --stdin.")
        if args.tag is not None and len(links) != 1:
            raise ConfigError("--tag применяется только к одной ссылке.")
        outbounds = []
        for index, link in enumerate(links, 1):
            try:
                outbound = convert_vless_to_json(link, ignore_unknown=args.ignore_unknown,
                                                 allow_advanced=bool(args.check_xray))
            except (ValueError, RecursionError):
                # Keep the intentional validation message, never a raw URL-parser exception.
                exc = sys.exc_info()[1]
                message = str(exc) if isinstance(exc, ConfigError) else "Слишком сложные или некорректные параметры."
                raise ConfigError("Ссылка №" + str(index) + ": " + message) from None
            if args.tag is not None:
                outbound["tag"] = clean_text(args.tag.strip(), "tag")
                if not outbound["tag"]:
                    raise ConfigError("tag не может быть пустым.")
            outbounds.append(outbound)
        tags = [outbound["tag"] for outbound in outbounds]
        if len(set(tags)) != len(tags):
            raise ConfigError("Повторяются tag подключений. Задайте уникальные имена после # в ссылках.")
        if args.check_xray:
            validate_with_xray(outbounds, args.check_xray)
            print("Проверка Xray пройдена; доступность соединения не проверялась.", file=sys.stderr)
        if args.outbounds:
            result = {"outbounds": outbounds}
        elif args.snippet or len(outbounds) > 1:
            result = outbounds
        else:
            result = outbounds[0]
        # Serialize all inputs before writing any file or partial stdout.
        combined = serialize(result)
        if args.stdout:
            sys.stdout.write(combined)
        else:
            directory = Path(args.outdir).expanduser()
            directory.mkdir(parents=True, exist_ok=True)
            jobs = [("outbounds", combined)] if args.outbounds or args.snippet else [
                (slugify(item["tag"]), serialize(item)) for item in outbounds]
            # --force may replace old files but must not merge two names in this run.
            used = set()
            for stem, text in jobs:
                base, number = stem, 1
                while stem in used:
                    number += 1
                    stem = base + "-" + str(number)
                used.add(stem)
                path = save_json(directory, stem, text, args.force)
                print("Сохранено: " + str(path))
        return 0
    except (ConfigError, OSError, UnicodeError) as exc:
        message = str(exc) if isinstance(exc, ConfigError) else "Не удалось прочитать вход или сохранить результат; проверьте путь и права доступа."
        print("Ошибка: " + message, file=sys.stderr)
        return 1
    except (KeyboardInterrupt, EOFError):
        print("\nВвод отменён.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
