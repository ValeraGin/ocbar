#!/usr/bin/env python3
"""Состояние ocbar в JSON: разбирает вывод `ocbar status --short` со stdin.

Один источник истины — сам `--short`; здесь только типы. Машинный разбор
key=value с полями через «|» ломался от каждого нового поля: «|» в названии
профиля сдвигал колонки, а пятое поле пришлось выносить отдельной строкой.
"""
import json
import sys

INTS = {"since", "access_at", "proxy_port", "link_lost", "woke_after_connect"}
BOOLS = {"paused", "needs_login", "foreign", "supervisor", "socks_up"}
LISTS = {"dns", "system_socks"}


def main() -> int:
    out: dict = {"routes": [], "zones": [], "profiles": []}
    urls: dict = {}
    for raw in sys.stdin.read().split("\n"):
        line = raw.rstrip("\r")
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key == "route":
            # «сеть интерфейс on|off»; «-» — маршрута нет.
            parts = value.split()
            if len(parts) >= 3:
                out["routes"].append({"net": parts[0],
                                      "via": None if parts[1] == "-" else parts[1],
                                      "on": parts[2] == "on"})
        elif key == "zone":
            parts = value.split()
            if len(parts) >= 4:
                out["zones"].append({"zone": parts[0], "dns": parts[1],
                                     "applied": parts[2] == "applied", "on": parts[3] == "on"})
        elif key == "profile_list":
            # «имя|название|вход|описание»: «|» внутри поля клиент уже заменил.
            f = (value.split("|") + ["", "", ""])[:4]
            out["profiles"].append({"name": f[0], "title": f[1],
                                    "auth": f[2] if f[2] == "password" else "", "descr": f[3]})
        elif key == "profile_url":
            name, _, url = value.partition("|")
            urls[name] = url
        elif key in INTS:
            try:
                out[key] = int(value)
            except ValueError:
                pass
        elif key in BOOLS:
            out[key] = value == "1"
        elif key in LISTS:
            out[key] = [v for v in value.replace(",", " ").split() if v]
        else:
            out[key] = value
    for p in out["profiles"]:
        p["url"] = urls.get(p["name"], "")
    out["profiles"] = [p for p in out["profiles"] if p["name"]]
    json.dump(out, sys.stdout, ensure_ascii=False, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
