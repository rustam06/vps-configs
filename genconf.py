#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
import uuid as uuidlib
from urllib.parse import urlparse, parse_qs, unquote

def slugify(name: str, maxlen: int = 80) -> str:
    name = unquote(name or "").strip().replace(" ", "")
    # Разрешим буквы/цифры + базовые символы; остальное заменим на _
    safe = re.sub(r"[^0-9A-Za-zА-Яа-яЁё._\-]", "", name)
    return (safe or "outbound")[:maxlen]

def to_bool(v: str) -> bool:
    return str(v).lower() in {"1", "true", "yes", "on"}

def guess_port(security: str, network: str) -> int:
    if security in {"tls", "reality"}:
        return 443
    if network in {"ws", "h2", "http", "grpc"}:
        return 80
    return 443

def build_stream_settings(params: dict, security: str, network: str) -> dict:
    ss = {"network": network, "security": security}

    # TLS
    if security == "tls":
        tls = {}
        sni = params.get("sni", [""])[0]
        if sni:
            tls["serverName"] = sni
        alpn = params.get("alpn", [""])[0]
        if alpn:
            tls["alpn"] = [x.strip() for x in alpn.split(",") if x.strip()]
        fp = params.get("fp", [""])[0]
        if fp:
            tls["fingerprint"] = fp
        insecure = params.get("insecure", params.get("allowInsecure", [""]))[0]
        if insecure != "":
            tls["allowInsecure"] = to_bool(insecure)
        if tls:
            ss["tlsSettings"] = tls

    # Reality
    elif security == "reality":
        reality = {
            "serverName": params.get("sni", [""])[0],
            "publicKey": params.get("pbk", [""])[0],
        }
        fp = params.get("fp", [""])[0]
        if fp:
            reality["fingerprint"] = fp
        sid = params.get("sid", [""])[0]
        if sid:
            reality["shortId"] = sid
        spx = params.get("spx", [""])[0]
        if spx:
            reality["spiderX"] = spx
        ss["realitySettings"] = reality

    # Сетевые настройки
    if network == "ws":
        ws = {}
        path = params.get("path", [""])[0]
        if path:
            ws["path"] = path
        host = params.get("host", [""])[0] or params.get("hostHeader", [""])[0]
        if host:
            ws["headers"] = {"Host": host}
        if ws:
            ss["wsSettings"] = ws

    elif network in {"h2", "http"}:
        http = {}
        path = params.get("path", [""])[0]
        if path:
            http["path"] = path
        host = params.get("host", [""])[0]
        if host:
            http["host"] = [h.strip() for h in host.split(",") if h.strip()]
        if http:
            ss["httpSettings"] = http

    elif network == "grpc":
        grpc = {}
        service = params.get("serviceName", [""])[0] or params.get("path", [""])[0]
        if service:
            grpc["serviceName"] = service
        mode = params.get("mode", [""])[0]
        if mode:
            grpc["multiMode"] = (mode.lower() != "gun")
        if grpc:
            ss["grpcSettings"] = grpc

    return ss

def convert_vless_to_json(vless_link: str) -> dict:
    parsed = urlparse(vless_link)
    if parsed.scheme.lower() != "vless":
        raise ValueError("Ссылка должна начинаться с vless://")

    uuid = parsed.username
    if not uuid:
        raise ValueError("Отсутствует UUID (часть перед @)")
    try:
        uuidlib.UUID(uuid)
    except Exception:
        # Не останавливаем — встречаются нестандартные ID, но это повод предупредить
        pass

    address = parsed.hostname
    if not address:
        raise ValueError("Отсутствует hostname")

    params = parse_qs(parsed.query)
    network = params.get("type", ["tcp"])[0].lower()
    security = params.get("security", ["none"])[0].lower()
    port = parsed.port or guess_port(security, network)

    encryption = params.get("encryption", ["none"])[0]
    user_cfg = {"id": uuid, "encryption": encryption}
    flow = params.get("flow", [""])[0]
    if flow:
        user_cfg["flow"] = flow

    outbound = {
        "protocol": "vless",
        "tag": unquote(parsed.fragment) or f"{address}:{port}",
        "settings": {
            "vnext": [
                {
                    "address": address,
                    "port": port,
                    "users": [user_cfg],
                }
            ]
        },
        "streamSettings": build_stream_settings(params, security, network),
    }
    return outbound

def main():
    parser = argparse.ArgumentParser(description="VLESS URI -> Xray outbound JSON")
    parser.add_argument("uri", nargs="+", help='Строка(и) вида "vless://..."')
    parser.add_argument("-o", "--outdir", default=".", help="Каталог для сохранения")
    parser.add_argument("--stdout", action="store_true", help="Печатать JSON в stdout вместо файлов")
    args = parser.parse_args()

    for link in args.uri:
        try:
            outbound = convert_vless_to_json(link)
            if args.stdout:
                print(json.dumps(outbound, ensure_ascii=False, indent=2))
            else:
                alias = slugify(outbound["tag"])
                os.makedirs(args.outdir, exist_ok=True)
                path = os.path.join(args.outdir, f"{alias}.json")
                with open(path, "w", encoding="utf-8") as f:
                    json.dump(outbound, f, ensure_ascii=False, indent=2)
                print(f"Сохранено: {path}")
        except Exception as e:
            print(f"Ошибка: {e}", file=sys.stderr)
            sys.exit(1)

if __name__ == "__main__":
    main()
