"""Fail if the target/capture implementation differs from the reviewed baseline."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'tests/TrackingBoundary.json').read_text(encoding='utf-8'))
for entry in manifest['protected']:
    text = (root / entry['path']).read_text(encoding='utf-8').replace('\r\n', '\n')
    if 'start' in entry:
        text = text[text.index(entry['start']):text.index(entry['end']) if entry['end'] else len(text)]
    actual = hashlib.sha256(text.encode('utf-8')).hexdigest()
    if actual != entry['sha256']:
        raise SystemExit(f"Protected target/capture code changed: {entry['path']} {entry.get('start', '')}")
print(f"PASS: {len(manifest['protected'])} target/capture boundaries unchanged from {manifest['base']}")
