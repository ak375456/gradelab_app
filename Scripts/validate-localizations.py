#!/usr/bin/env python3
"""Check a string catalog's locale coverage and printf argument compatibility."""
import argparse
import json
import re
from collections import Counter
from pathlib import Path

# Space is deliberately excluded from flags: prose such as '100% or more'
# must not be mistaken for an octal argument. GradeLab uses no space flags.
FORMAT = re.compile(r'%(?:(\d+)\$)?([-+#0]*)(\d+)?(?:\.(\d+))?(hh|ll|h|l|q|z|t|j)?([@diuoxXfFeEgGaAcCsSp%])')

def arguments(text):
    result = Counter()
    implicit = 0
    for match in FORMAT.finditer(text):
        position, flags, width, precision, length, kind = match.groups()
        if kind == '%':
            continue
        implicit += 1
        result[(int(position) if position else implicit, flags, width, precision, length, kind)] += 1
    return result

def units(value):
    if isinstance(value, dict):
        if 'stringUnit' in value:
            yield value['stringUnit']
        for key, child in value.items():
            if key != 'stringUnit':
                yield from units(child)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--locale', default='ja')
    parser.add_argument('catalogs', nargs='*', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    catalogs = args.catalogs or [root / 'dummy name/Localizable.xcstrings', root / 'dummy name/InfoPlist.xcstrings']
    failures = []
    total = 0
    for path in catalogs:
        catalog = json.loads(path.read_text())
        count = 0
        for key, entry in catalog['strings'].items():
            if entry.get('shouldTranslate') is False:
                continue
            localization = entry.get('localizations', {}).get(args.locale)
            if localization is None:
                failures.append(f'{path.name}: missing {args.locale}: {key!r}')
                continue
            source = entry.get('localizations', {}).get(catalog['sourceLanguage'], {})
            source_units = list(units(source))
            expected = arguments(source_units[0]['value'] if source_units else key)
            localized_units = list(units(localization))
            if not localized_units:
                failures.append(f'{path.name}: no translation unit: {key!r}')
            for unit in localized_units:
                if unit.get('state') != 'translated' or not unit.get('value'):
                    failures.append(f'{path.name}: unfinished translation: {key!r}')
                if arguments(unit.get('value', '')) != expected:
                    failures.append(f'{path.name}: incompatible format arguments: {key!r}')
            count += 1
        total += count
        print(f'{path.name}: {count} {args.locale} entries checked')
    if failures:
        raise SystemExit('\n'.join(failures))
    print(f'PASS: {total} localized entries; all format arguments match.')

if __name__ == '__main__':
    main()
