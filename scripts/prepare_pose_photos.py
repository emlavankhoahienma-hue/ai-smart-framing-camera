"""All 342 human-scene photos from the official CADB test split."""
import hashlib
import json
from pathlib import Path
import urllib.request
import zipfile

archive = Path('.model-cache/CADB_Dataset.zip')
from prepare_composition_photos import DATA_URL, DATA_SHA256
if not archive.exists():
    archive.parent.mkdir(parents=True, exist_ok=True)
    urllib.request.urlretrieve(DATA_URL, archive)
with archive.open('rb') as stream:
    assert hashlib.file_digest(stream, 'sha256').hexdigest() == DATA_SHA256
output = Path('validation/pose/photos')
output.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(archive) as dataset:
    test = json.loads(dataset.read('CADB_Dataset/split.json'))['test']
    categories = json.loads(dataset.read('CADB_Dataset/scene_categories.json'))
    names = sorted(n for n in test if categories[n] == 'human')
    assert len(names) == 342
    for name in names:
        (output / name).write_bytes(dataset.read('CADB_Dataset/images/' + name))
print('Prepared all', len(names), 'human test photos')
