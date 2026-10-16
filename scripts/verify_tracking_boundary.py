"""Fail if the target/capture implementation differs from the reviewed baseline."""
import hashlib
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
for name in ('TrackingBoundary.json', 'PhotographicDetectionBoundary.json'):
    manifest = json.loads((root / 'tests' / name).read_text(encoding='utf-8'))
    for entry in manifest['protected']:
        text = (root / entry['path']).read_text(encoding='utf-8').replace('\r\n', '\n')
        if 'start' in entry:
            text = text[text.index(entry['start']):text.index(entry['end']) if entry.get('end') else len(text)]
        actual = hashlib.sha256(text.encode('utf-8')).hexdigest()
        if actual != entry['sha256']:
            sys.exit(f"Protected code changed: {entry['path']} {entry.get('start', '')}")
    print(f"PASS: {len(manifest['protected'])} boundaries in {name} unchanged from {manifest['base']}")
