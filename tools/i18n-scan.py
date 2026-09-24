#!/usr/bin/env python3
"""Строки интерфейса приложения и окон ocbar-auth: сбор и сверка с переводом.

SwiftUI берёт русский текст как ключ и ищет перевод в Localizable.strings.
Здесь мы собираем ключи по местам вызова (Text, Button, Toggle…), а не по
всем строкам подряд: в коде хватает строк для журнала и самопроверки,
переводить их незачем.

    tools/i18n-scan.py --list            все ключи
    tools/i18n-scan.py --check           чего не хватает в en.lproj (код 1)
    tools/i18n-scan.py --update          дописать недостающие с пометкой TODO

ocbar-auth — голый файл без бандла: перевод у него в коде, словарём
auth/Sources/ocbar-auth/Translations.swift; --check сверяет и его (--update
туда не пишет — пары добавляются руками).

Клиент bin/ocbar переводится при выводе, по шаблонам libexec/ocbar-en.tsv
(«русский<TAB>английский», {} — подстановка, {1}, {2}… — если порядок
другой); --check сверяет и его.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "app/Sources/ocbar-app"]
STRINGS = ROOT / "app/Resources/en.lproj/Localizable.strings"

# Строки интерфейса помечены вызовом L("…") — он же делает перевод. Здесь
# собираются ключи и ищутся места, где перевод забыли.
CYRILLIC = re.compile(r"[а-яА-ЯёЁ]")
KEY_RE = re.compile(r'(?<![\w.])L\(\s*"((?:[^"\\]|\\.)*)"')
# Строка интерфейса без L() остаётся русской и в английском интерфейсе. До
# 0.17.6 скан искал её только в вызовах из списка (Text, Button…) и молчал о
# подписях действий, ошибках, подсказках редактора и заголовках окон — а
# найденное печатал, не останавливая сборку. Теперь любой кириллический
# литерал вне L() — ошибка, кроме того, что человек не видит:
UI_SKIP_FILES = {"SelfTest.swift", "SelfTestAudit.swift", "MenuProbe.swift"}
# журнал и печать; сравнение с выводом клиента (он переводит сам);
# строка, помеченная комментарием «i18n: не интерфейс».
NOT_UI_LINE = re.compile(r"AppLog\.write|\bprint\(|fatalError\(|i18n: не интерфейс")
COMPARE_BEFORE = re.compile(r"(?:contains|hasPrefix|hasSuffix|range\(of:|components\(separatedBy:|==|!=)\s*\(?\s*$")


def swift_literals(line: str) -> list[tuple[int, str]]:
    """Строковые литералы строки кода с позицией открывающей кавычки,
    включая вложенные в интерполяцию \\( … ). Комментарий // — конец."""
    out: list[tuple[int, str]] = []

    def code(i: int, inner: bool) -> int:
        # inner — внутри интерполяции \\( … ): её закрывающая скобка выходит.
        depth = 1 if inner else 0
        while i < len(line):
            c = line[i]
            if c == '"':
                i = string(i)
                continue
            if line.startswith("//", i) and not inner:
                return len(line)
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if inner and depth == 0:
                    return i + 1
            i += 1
        return i

    def string(i: int) -> int:
        start, j, buf = i, i + 1, ""
        while j < len(line):
            c = line[j]
            if c == "\\" and j + 1 < len(line) and line[j + 1] == "(":
                j = code(j + 2, True)
                buf += "{}"
                continue
            if c == "\\":
                buf += line[j:j + 2]; j += 2; continue
            if c == '"':
                out.append((start, buf))
                return j + 1
            buf += c; j += 1
        out.append((start, buf))
        return j

    code(0, False)
    return out


def keys(report_unwrapped: bool = False) -> list[str]:
    found: dict[str, None] = {}
    unwrapped: list[str] = []
    for root in SOURCES:
        for path in sorted(root.rglob("*.swift")):
            if path.name in {"SelfTest.swift", "SelfTestAudit.swift"}:
                continue  # самопроверка человеку не показывается; витрина — да: из неё кадры README
            for n, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
                if line.lstrip().startswith("//"):
                    continue
                for raw in KEY_RE.findall(line):
                    if not CYRILLIC.search(raw):
                        continue
                    found.setdefault(raw.replace('\\"', '"'), None)
                if path.name in UI_SKIP_FILES or NOT_UI_LINE.search(line):
                    continue
                for pos, text in swift_literals(line):
                    if not CYRILLIC.search(text):
                        continue
                    before = line[:pos].rstrip()
                    if before.endswith("L(") or COMPARE_BEFORE.search(before):
                        continue
                    unwrapped.append(f"{path.name}:{n}: {text}")
    if report_unwrapped:
        for u in unwrapped:
            print("без перевода в коде: " + u)
    keys.unwrapped = unwrapped
    return list(found)


def translations() -> dict[str, str]:
    if not STRINGS.exists():
        return {}
    out: dict[str, str] = {}
    for line in STRINGS.read_text(encoding="utf-8").split("\n"):
        m = re.match(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', line)
        if m:
            out[m.group(1).replace('\\"', '"')] = m.group(2)
    return out


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    ks, tr = keys(report_unwrapped=mode == "--check"), translations()
    missing = [k for k in ks if k not in tr]
    extra = [k for k in tr if k not in ks]
    if mode == "--list":
        print("\n".join(ks))
        return 0
    if mode == "--update":
        with STRINGS.open("a", encoding="utf-8") as f:
            for k in missing:
                f.write('"%s" = "TODO: %s";\n' % (k.replace('"', '\\"'), k.replace('"', '\\"')))
        print(f"дописано: {len(missing)}")
        return 0
    todo = [k for k, v in tr.items() if v.startswith("TODO")]
    for k in missing:
        print(f"нет перевода: {k}")
    for k in todo:
        print(f"не переведено: {k}")
    for k in extra:
        print(f"лишний перевод (строки в коде нет): {k}")
    print(f"строк интерфейса: {len(ks)}, переведено: {len(ks) - len(missing) - len(todo)}")
    return 1 if missing or todo or extra or getattr(keys, "unwrapped", []) else 0


# --- ocbar-auth ------------------------------------------------------------
AUTH = ROOT / "auth/Sources/ocbar-auth"
AUTH_TABLE = AUTH / "Translations.swift"
AUTH_SKIP = {"SelfTest.swift", "LearnCheck.swift", "Translations.swift", "Localization.swift"}
# Текст окна AppKit, который забыли обернуть: заголовки, подписи, подсказки.
AUTH_UNWRAPPED = re.compile(
    r'(?:title|labelWithString|checkboxWithTitle|withTitle|messageText|informativeText|'
    r'placeholderString|toolTip|stringValue|message)\s*[:=]\s*"((?:[^"\\]|\\.)*)"')


def auth_check() -> int:
    found: dict[str, None] = {}
    unwrapped: list[str] = []
    for path in sorted(AUTH.glob("*.swift")):
        if path.name in AUTH_SKIP:
            continue
        for line in path.read_text(encoding="utf-8").split("\n"):
            if line.lstrip().startswith("//"):
                continue
            for raw in KEY_RE.findall(line):
                if CYRILLIC.search(raw):
                    found.setdefault(raw.replace('\\"', '"'), None)
            for raw in AUTH_UNWRAPPED.findall(line):
                if CYRILLIC.search(raw):
                    unwrapped.append(f"{path.name}: {raw}")
    table: dict[str, str] = {}
    for line in AUTH_TABLE.read_text(encoding="utf-8").split("\n"):
        m = re.match(r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"\s*,\s*$', line)
        if m:
            table[m.group(1).replace('\\"', '"')] = m.group(2)
    missing = [k for k in found if k not in table]
    extra = [k for k in table if k not in found]
    for u in unwrapped:
        print("ocbar-auth: без перевода в коде: " + u)
    for k in missing:
        print(f"ocbar-auth: нет перевода: {k}")
    for k in extra:
        print(f"ocbar-auth: лишний перевод (строки в коде нет): {k}")
    print(f"строк окон ocbar-auth: {len(found)}, переведено: {len(found) - len(missing)}")
    return 1 if missing or extra or unwrapped else 0


# --- клиент (bin/ocbar) ------------------------------------------------------
# Сообщения человеку идут через ok/warn/bad/skip/info/die; перевод — по
# шаблонам libexec/ocbar-en.tsv (подстановки $var, ${…}, $(…) — это {}).
CLI = ROOT / "bin/ocbar"
CLI_TABLE = ROOT / "libexec/ocbar-en.tsv"


def cli_template(s: str) -> str:
    out, i = "", 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            out += s[i + 1]; i += 2; continue
        if c == "$" and i + 1 < len(s) and s[i + 1] == "(":
            depth, j = 0, i + 1
            while j < len(s):
                depth += {"(": 1, ")": -1}.get(s[j], 0)
                if depth == 0:
                    break
                j += 1
            out += "{}"; i = j + 1; continue
        if c == "$" and i + 1 < len(s) and s[i + 1] == "{":
            out += "{}"; i = s.index("}", i) + 1; continue
        m = re.match(r"\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9#@*?]", s[i:])
        if m:
            out += "{}"; i += len(m.group(0)); continue
        out += c; i += 1
    return out


CLI_NAME = re.compile(r'(?:^|[;&|{(\s])(?:die|info|ok|warn|bad|skip)\s+(?=")')


def cli_quoted(line: str, i: int) -> tuple[str, int]:
    """Строка в двойных кавычках с позиции i (там кавычка): внутри $( … )
    свои кавычки не закрывают внешнюю. Возвращает содержимое и позицию за ней."""
    j, depth, inner = i + 1, 0, False
    while j < len(line):
        c = line[j]
        if c == "\\":
            j += 2; continue
        if depth and c == '"':
            inner = not inner
        elif not inner and line.startswith("$(", j):
            depth += 1; j += 2; continue
        elif depth and not inner and c == ")":
            depth -= 1
        elif not depth and c == '"':
            return line[i + 1:j], j + 1
        j += 1
    return line[i + 1:], len(line)


# Сообщение целиком из переменной скан не видит, и оно остаётся русским
# (так было с «Каталог копии openconnect» в doctor до 0.17.3).
CLI_VAR_MSG = re.compile(r'"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"(?:\s|;|$)')


def cli_var_messages() -> list[str]:
    out = []
    for n, line in enumerate(CLI.read_text(encoding="utf-8").split("\n"), 1):
        if line.lstrip().startswith("#"):
            continue
        for m in CLI_NAME.finditer(line):
            if CLI_VAR_MSG.match(line, m.end()):
                out.append(f"bin/ocbar:{n}: {line.strip()}")
    return out


def cli_keys() -> list[str]:
    found: dict[str, None] = {}
    for line in CLI.read_text(encoding="utf-8").split("\n"):
        if line.lstrip().startswith("#"):
            continue
        for m in CLI_NAME.finditer(line):
            pos = m.end()
            while pos < len(line) and line[pos] == '"':
                raw, pos = cli_quoted(line, pos)
                t = cli_template(raw)
                if CYRILLIC.search(t) and t.strip("{} "):
                    found.setdefault(t, None)
                while pos < len(line) and line[pos] == " ":
                    pos += 1
    return list(found)


def cli_check() -> int:
    keys = cli_keys()
    table: dict[str, str] = {}
    bad: list[str] = []
    if CLI_TABLE.exists():
        for line in CLI_TABLE.read_text(encoding="utf-8").split("\n"):
            if not line or line.startswith("#") or "\t" not in line:
                continue
            ru, en = line.split("\t", 1)
            table[ru] = en
            n = ru.count("{}")
            idx = re.findall(r"\{(\d+)\}", en)
            if idx:
                if "{}" in en or sorted(set(int(x) for x in idx)) != list(range(1, n + 1)):
                    bad.append(ru)
            elif en.count("{}") != n:
                bad.append(ru)
            if CYRILLIC.search(re.sub(r"\{\d*\}", "", en)):
                bad.append(ru)
    missing = [k for k in keys if k not in table]
    extra = [k for k in table if k not in keys]
    for k in missing:
        print(f"ocbar: нет перевода: {k}")
    for k in extra:
        print(f"ocbar: лишний перевод (сообщения в коде нет): {k}")
    for k in bad:
        print(f"ocbar: перевод не сходится с шаблоном (подстановки или кириллица): {k}")
    var_msgs = cli_var_messages()
    for v in var_msgs:
        print(f"ocbar: сообщение из переменной — скан его не видит, пишите литерал: {v}")
    print(f"сообщений клиента: {len(keys)}, переведено: {len(keys) - len(missing)}")
    return 1 if missing or extra or bad or var_msgs else 0


if __name__ == "__main__":
    rc = main()
    if (sys.argv[1] if len(sys.argv) > 1 else "--check") == "--check":
        rc = max(rc, auth_check(), cli_check())
    sys.exit(rc)
