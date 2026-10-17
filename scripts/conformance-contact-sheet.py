#!/usr/bin/env python3
"""Tile conformance screenshots side by side, one row per cell, one column per app.

Each checkpoint screenshot is named `<app>-<device>-<orientation>-<scenario>-<checkpoint>.png`
(`ConformanceTest.checkpoint` on Android, `SharedAppUITestCase.checkpoint` on iOS; the iOS
attachments are exported from the result bundle first, for example with
`xcrun xcresulttool export attachments`). The page links the images where they are, so keep it
next to (or above) the directories it was made from.

usage: conformance-contact-sheet.py --out sheet.html DIR [DIR ...]
"""
import argparse
import html
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

NAME = re.compile(
    r'^(?P<app>[A-Za-z0-9]+)-(?P<device>[^-]+)-(?P<orientation>portrait|landscape)-'
    r'(?P<scenario>[A-Za-z0-9]+)-(?P<checkpoint>.+)\.png$')


def cells(directories):
    found = defaultdict(dict)
    for directory in directories:
        for path in sorted(Path(directory).rglob('*.png')):
            match = NAME.match(path.name)
            if not match:
                continue
            key = (match['device'], match['scenario'], match['checkpoint'], match['orientation'])
            # Android evidence names the app `PocketCine`, iOS `OpenPocketCine`: one column each.
            found[key][re.sub(r'^Open', '', match['app'])] = path
    return found


def device_class(device):
    if device.startswith('tablet') or device.startswith('iPad'):
        return 'tablet'
    return 'phone'


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('directories', nargs='+')
    args = parser.parse_args(argv)
    found = cells(args.directories)
    if not found:
        print('No conformance screenshots found', file=sys.stderr)
        return 1
    apps = sorted({app for row in found.values() for app in row})
    out = args.out.resolve()
    rows = []
    for (device, scenario, checkpoint, orientation) in sorted(
            found, key=lambda k: (device_class(k[0]), k[0], k[1], k[2], k[3] != 'portrait')):
        shots = found[(device, scenario, checkpoint, orientation)]
        tiles = []
        for app in apps:
            path = shots.get(app)
            if path is None:
                tiles.append('<td class="missing">missing</td>')
                continue
            link = html.escape(os.path.relpath(path.resolve(), out.parent))
            tiles.append(f'<td><a href="{link}"><img loading="lazy" src="{link}" alt="{html.escape(path.name)}"></a></td>')
        label = html.escape(f'{device_class(device)} {device} {orientation} {scenario} {checkpoint}')
        rows.append(f'<tr><th>{label}</th>{"".join(tiles)}</tr>')
    missing = sum(1 for row in found.values() for app in apps if app not in row)
    head = ''.join(f'<th>{html.escape(app)}</th>' for app in apps)
    out.write_text(f'''<!doctype html>
<meta charset="utf-8"><title>Conformance contact sheet</title>
<style>
body{{font:13px system-ui;margin:16px;background:#111;color:#ddd}}
table{{border-collapse:collapse}} th,td{{border:1px solid #333;padding:4px;vertical-align:top}}
th{{text-align:left;max-width:180px}} img{{max-width:360px;max-height:360px;display:block}}
.missing{{color:#f66}}
</style>
<p>{len(found)} cells, {len(apps)} apps, {missing} missing tiles.</p>
<table><tr><th>cell</th>{head}</tr>
{chr(10).join(rows)}
</table>
''')
    print(f'{out}: {len(found)} cells, {len(apps)} apps, {missing} missing tiles')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
