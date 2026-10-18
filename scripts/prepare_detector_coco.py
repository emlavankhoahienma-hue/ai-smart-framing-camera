"""Download a fixed labelled COCO val2017 subset from the author's S3 bucket.

Only the validation annotation ZIP member is fetched with verified HTTP ranges.
No inference result is consulted when selecting the 96 source image IDs.
"""
from __future__ import annotations

import hashlib
import json
import struct
import time
import urllib.error
import urllib.request
import zlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = "https://s3.amazonaws.com/images.cocodataset.org/annotations/annotations_trainval2017.zip"
MEMBER = "annotations/instances_val2017.json"
REVISION = "COCO val2017 author annotations; immutable subset v1"


def request_bytes(url: str, byte_range: str | None = None) -> tuple[bytes, str | None]:
    headers = {"User-Agent": "AlignAI labelled detector validation/1.0"}
    if byte_range is not None:
        headers["Range"] = byte_range
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
                if byte_range is not None and response.status != 206:
                    raise RuntimeError("COCO server did not honor a bounded annotation range")
                return response.read(), response.headers.get("Content-Range")
        except (urllib.error.URLError, TimeoutError):
            if attempt == 2:
                raise
            time.sleep(1 + attempt)
    raise RuntimeError("Unreachable download state")


def validation_annotations() -> bytes:
    tail, content_range = request_bytes(ARCHIVE, "bytes=-65557")
    if content_range is None:
        raise RuntimeError("COCO annotation range has no total length")
    total = int(content_range.rsplit("/", 1)[1])
    eocd = tail.rfind(b"PK\x05\x06")
    if eocd < 0:
        raise RuntimeError("COCO annotation archive has no ZIP directory")
    directory_size, directory_offset = struct.unpack_from("<II", tail, eocd + 12)
    start = directory_offset - total + len(tail)
    if start < 0 or start + directory_size > len(tail):
        raise RuntimeError("COCO ZIP directory exceeds bounded metadata range")
    directory = tail[start:start + directory_size]
    position = 0
    while position < len(directory):
        values = struct.unpack_from("<4s6H3I5H2I", directory, position)
        if values[0] != b"PK\x01\x02":
            raise RuntimeError("Invalid COCO ZIP directory record")
        name_size, extra_size, comment_size = values[10:13]
        name = directory[position + 46:position + 46 + name_size].decode("utf-8")
        if name == MEMBER:
            method, crc, compressed, expanded, offset = values[4], values[7], values[8], values[9], values[16]
            header, _ = request_bytes(ARCHIVE, f"bytes={offset}-{offset + 29}")
            if header[:4] != b"PK\x03\x04" or method != 8 or expanded > 32 * 1024 * 1024:
                raise RuntimeError("Unexpected COCO annotation ZIP member")
            local_name, local_extra = struct.unpack_from("<HH", header, 26)
            body = offset + 30 + local_name + local_extra
            payload, _ = request_bytes(ARCHIVE, f"bytes={body}-{body + compressed - 1}")
            data = zlib.decompress(payload, -15)
            if len(data) != expanded or zlib.crc32(data) != crc:
                raise RuntimeError("COCO validation annotation ZIP checksum mismatch")
            return data
        position += 46 + name_size + extra_size + comment_size
    raise RuntimeError("COCO validation annotation member not found")


def prepare() -> dict:
    destination = ROOT / "validation/detection/coco"
    destination.mkdir(parents=True, exist_ok=True)
    subset = json.loads((ROOT / "tests/COCODetectionSubset.json").read_text(encoding="utf-8"))
    cache = ROOT / ".model-cache/instances_val2017.json"
    cache.parent.mkdir(parents=True, exist_ok=True)
    if not cache.exists():
        cache.write_bytes(validation_annotations())
    data = cache.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != subset["annotationSHA256"]:
        raise RuntimeError(f"COCO author annotation checksum differs: {digest}")
    annotations = json.loads(data)
    images = {image["id"]: image for image in annotations["images"]}
    selected = subset["imageIDs"]
    if len(selected) < 80 or len(set(selected)) != len(selected):
        raise RuntimeError("Labelled COCO test requires at least 80 distinct fixed IDs")
    photos = destination / "photos"
    photos.mkdir(exist_ok=True)

    def download(image_id: int) -> dict:
        source = images[image_id]
        url = "https://s3.amazonaws.com/images.cocodataset.org/val2017/" + source["file_name"]
        path = photos / source["file_name"]
        if not path.exists():
            content, _ = request_bytes(url)
            path.write_bytes(content)
        content = path.read_bytes()
        image_digest = hashlib.sha256(content).hexdigest()
        if image_digest != subset["imageSHA256"].get(source["file_name"]):
            raise RuntimeError("Official COCO image bytes differ from the frozen subset: " + source["file_name"])
        return {**source, "sourceURL": url, "sourceSHA256": image_digest}

    with ThreadPoolExecutor(max_workers=4) as executor:
        records = list(executor.map(download, selected))
    selected_ids = set(selected)
    result = {"dataset": REVISION, "source": ARCHIVE, "member": MEMBER,
              "annotationSHA256": digest, "selection": subset["selection"],
              "images": records, "categories": annotations["categories"],
              "annotations": [item for item in annotations["annotations"] if item["image_id"] in selected_ids]}
    (destination / "ground-truth.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    (destination / "classes.json").write_text(json.dumps(
        {str(item["id"]): item["name"] for item in result["categories"]}, indent=2), encoding="utf-8")
    print(f"Prepared {len(records)} fixed COCO val2017 photos and {len(result['annotations'])} author boxes")
    return result


if __name__ == "__main__":
    prepare()
