#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json, pathlib, re, sys

root = pathlib.Path('Sources/Winstripe')
paths = sorted(root.glob('*.swift'))
files = {}
for path in paths:
    files[path] = path.read_text(encoding='utf-8')

def load(path):
    text = path.read_text(encoding='utf-8')
    values = {}
    pattern = re.compile(r'^\s*"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;', re.M)
    for match in pattern.finditer(text):
        key = json.loads('"' + match.group(1) + '"')
        value = json.loads('"' + match.group(2) + '"')
        values[key] = value
    return values

expected_locales = ['en', 'zh-Hans', 'zh-Hant', 'fr', 'es', 'pt-BR', 'pt', 'ja', 'ko', 'de']
tables = {}
failures = []
for locale in expected_locales:
    path = root / f'Resources/{locale}.lproj/Localizable.strings'
    if not path.exists():
        failures.append(f'{locale}: missing {path}')
        continue
    tables[locale] = load(path)
for path in sorted((root / 'Resources').glob('*.lproj')):
    if path.stem not in expected_locales: failures.append(f'{path.stem}: unexpected lproj not in expected list')
en = tables.get('en', {})
zh = tables.get('zh-Hans', {})
spec = re.compile(r'%(?:[0-9]+\$)?[-+#0-9. ]*(?:lld|@|d)')
for locale, table in tables.items():
    for key in sorted(set(en) - set(table)): failures.append(f'{locale}: missing key {key!r}')
    for key in sorted(set(table) - set(en)): failures.append(f'{locale}: extra key {key!r}')
    for key, value in table.items():
        if value == '': failures.append(f'{locale}: empty value for {key!r}')
        if key in en and spec.findall(value) != spec.findall(en[key]):
            failures.append(f'{locale}: format specifiers differ for {key!r}')
        if 'Windows' in value and key != 'Windows and previews' and locale == 'en':
            failures.append(f'{locale}: trademark in value {key!r}')
bundle = pathlib.Path('scripts/bundle.sh').read_text(encoding='utf-8')
for locale in expected_locales:
    if f'<string>{locale}</string>' not in bundle: failures.append(f'bundle.sh: CFBundleLocalizations lacks {locale}')

key_pattern = re.compile(r'(?<![A-Za-z0-9_])(?:L\.)?t\("((?:\\.|[^"\\])*)"')
for path, text in files.items():
    for match in key_pattern.finditer(text):
        key = json.loads('"' + match.group(1) + '"')
        if key not in en or key not in zh:
            line = text.count('\n', 0, match.start()) + 1
            failures.append(f'{path}:{line}: missing localization key {key!r}')

# User-visible literal checks. Fixtures and empty control titles are explicit exceptions.
allow = {'', 'Safari', 'Notes'}
literal_patterns = [
    re.compile(r'\bText\("((?:\\.|[^"\\])*)"'),
    re.compile(r'\bButton\("((?:\\.|[^"\\])*)"'),
    re.compile(r'NSMenuItem\(title:\s*"((?:\\.|[^"\\])*)"'),
    re.compile(r'\.title\s*=\s*"((?:\\.|[^"\\])*)"'),
    re.compile(r'\bmessageText\s*=\s*"((?:\\.|[^"\\])*)"'),
    re.compile(r'Retro\.drawText\("((?:\\.|[^"\\])*)"'),
]
for path, text in files.items():
    for pattern in literal_patterns:
        for match in pattern.finditer(text):
            literal = json.loads('"' + match.group(1) + '"')
            if literal in allow:
                continue
            line = text.count('\n', 0, match.start()) + 1
            failures.append(f'{path}:{line}: hardcoded user-visible literal {literal!r}')

if failures:
    for failure in failures:
        print('FAIL', failure)
    sys.exit(1)
print(f'PASS l10n source check ({len(en)} keys x {len(tables)} locales, {len(paths)} Swift files)')
PY
