#!/usr/bin/env python3
"""Строки интерфейса приложения: сбор и сверка с переводом.

SwiftUI берёт русский текст как ключ и ищет перевод в Localizable.strings.
Здесь мы собираем ключи по местам вызова (Text, Button, Toggle…), а не по
всем строкам подряд: в коде хватает строк для журнала и самопроверки,
переводить их незачем.

    tools/i18n-scan.py --list            все ключи
    tools/i18n-scan.py --check           чего не хватает в en.lproj (код 1)
    tools/i18n-scan.py --update          дописать недостающие с пометкой TODO
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
CALLS = [
    "Text", "Button", "Toggle", "Picker", "Section", "LabeledContent",
    "Footnote", "Label", "TextField", "navigationTitle", "field", "sourceRow",
    "MenuRow", "pageTitle", "help", "accessibilityLabel",
]
UNWRAPPED_RE = re.compile(r"(?<![\w.])(?:" + "|".join(CALLS) + r")\(\s*\"((?:[^\"\\]|\\.)*)\"")
def keys(report_unwrapped: bool = False) -> list[str]:
    found: dict[str, None] = {}
    unwrapped: list[str] = []
    for root in SOURCES:
        for path in sorted(root.rglob("*.swift")):
            if path.name in {"SelfTest.swift", "SelfTestAudit.swift", "Stage.swift"}:
                continue  # самопроверка и витрина человеку не показываются
            for line in path.read_text(encoding="utf-8").split("\n"):
                if line.lstrip().startswith("//"):
                    continue
                for raw in KEY_RE.findall(line):
                    if not CYRILLIC.search(raw):
                        continue
                    found.setdefault(raw.replace('\\"', '"'), None)
                for raw in UNWRAPPED_RE.findall(line):
                    if CYRILLIC.search(raw) and 'L("' not in line:
                        unwrapped.append(f"{path.name}: {raw}")
    if report_unwrapped:
        for u in unwrapped:
            print("без перевода в коде: " + u)
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
    return 1 if missing or todo or extra else 0


if __name__ == "__main__":
    sys.exit(main())
