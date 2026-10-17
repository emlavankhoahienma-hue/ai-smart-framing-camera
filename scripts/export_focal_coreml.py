"""Convert a pinned, released human-preference crop checkpoint; verify real images."""
from pathlib import Path
import hashlib
import json
import sys
import urllib.request

import numpy as np
import torch

REPOSITORY = "https://github.com/appwrite/focalnet"
REVISION = "f3c55aeb5827f302d1bbe9f0f41da38139f3dc36"
HUB_REVISION = "f114d602b055aa1955f23a591a161336517789c4"
WEIGHTS_SHA256 = "82c4d695310c220e5f3bcfbf5e64d315a5e826cfd77e945e61e032460014480a"
SOURCE_HASHES = {
    "__init__.py": "244726179ee2cc8f2081a6343d8e29e0818fbc3396243577d950f14ca5de3bce",
    "model.py": "bc23da1e3f3c5af666b11c3e2ff3bb1a4d9eccd3876fefe46b737ab146cc2989",
    "ranking.py": "d94c37d812861a2b5b38504bf39cf08ccfaf618fb3efba621f00dfda71de05a9",
    "imaging.py": "791b481afb200ba820a655b179f8408d697a9ed535afd13e65383c04c659062a",
    "candidates.py": "a4749ac79d59dad793087f6c4c26fe2c4ddce7809d9ed9e55198119daef015c6",
}


def verified_download(url, destination, expected):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        with urllib.request.urlopen(url, timeout=90) as response:
            destination.write_bytes(response.read())
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    if digest != expected:
        raise RuntimeError(f"Unverified model source: {destination.name}, {digest}")
    return destination


def load_reference(cache=Path(".model-cache/focal")):
    package = cache / "source/focalnet"
    for name, digest in SOURCE_HASHES.items():
        verified_download(f"https://raw.githubusercontent.com/appwrite/focalnet/{REVISION}/src/focalnet/{name}",
                          package / name, digest)
    license_path = verified_download(f"https://raw.githubusercontent.com/appwrite/focalnet/{REVISION}/LICENSE",
        cache / "FocalNet-LICENSE.txt", "cc37246c63757e98e3fe4460892a44d25088c8493eeb0e6858aab149e1177a05")
    checkpoint = verified_download(f"https://huggingface.co/appwrite/focalnet/resolve/{HUB_REVISION}/focalnet-human.pt",
                                  cache / "focalnet-human.pt", WEIGHTS_SHA256)
    sys.path.insert(0, str(package.parent.resolve()))
    from focalnet.ranking import HumanCropInference, load_human_checkpoint
    network, metadata = load_human_checkpoint(checkpoint)
    if network.parameter_count() != 4_757_694 or metadata.get("dataset_name") != "GAICD journal version":
        raise RuntimeError("Unexpected released crop ranker")
    return HumanCropInference(network).eval(), license_path


def main():
    import coremltools as ct
    torch.set_num_threads(2)
    model, license_path = load_reference()
    from focalnet.imaging import open_image, prepare_image
    from focalnet.candidates import generate_candidates, letterbox_content
    regions = generate_candidates(800, 600, 4 / 3)
    boxes = np.tile(np.asarray([0, 0, 1, 1], np.float32), (1, 128, 1))
    boxes[0, :len(regions)] = regions
    arguments = (torch.zeros(1, 3, 256, 256), torch.from_numpy(boxes), torch.tensor([[0., .125, 1., .875]]))
    with torch.inference_mode():
        traced = torch.jit.trace(model, arguments, strict=True)
    converted = ct.convert(traced, inputs=[ct.TensorType(name="image", shape=(1, 3, 256, 256)),
        ct.TensorType(name="boxes", shape=(1, 128, 4)), ct.TensorType(name="content", shape=(1, 4))],
        outputs=[ct.TensorType(name="importance"), ct.TensorType(name="cropScores")],
        minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT32,
        convert_to="mlprogram")
    converted.author = "Appwrite; released CPC to GAICD crop-preference checkpoint"
    converted.license = "MIT; see FocalNet-LICENSE.txt"
    converted.short_description = "RepViT source-image importance and human crop preferences; compare scores only within one image"
    converted.save("FocalCrop.mlpackage")
    fixture_dir = Path("validation/focal")
    fixture_dir.mkdir(parents=True, exist_ok=True)
    photo_manifest = json.loads(Path("validation/photos/manifest.json").read_text())
    fixtures = []
    preference_error = map_error = 0.0
    for row in photo_manifest["images"][:32]:
        path = Path("validation/photos/source") / row["file"]
        image = open_image(path)
        tensor, letterbox = prepare_image(image)
        crops = generate_candidates(image.width, image.height, image.width / image.height)
        boxes = np.tile(np.asarray([0, 0, 1, 1], np.float32), (1, 128, 1))
        boxes[0, :len(crops)] = crops
        inputs = {"image": tensor, "boxes": boxes, "content": letterbox_content(letterbox)[None]}
        with torch.inference_mode():
            importance, scores = model(*(torch.from_numpy(inputs[k]) for k in ["image", "boxes", "content"]))
        actual = converted.predict(inputs)
        np.testing.assert_allclose(actual["importance"], importance.numpy(), atol=0.004, rtol=0.001)
        np.testing.assert_allclose(actual["cropScores"], scores.numpy(), atol=0.04, rtol=0.001)
        map_error = max(map_error, float(np.max(np.abs(actual["importance"] - importance.numpy()))))
        preference_error = max(preference_error, float(np.max(np.abs(actual["cropScores"] - scores.numpy()))))
        fixtures.append({"file": row["file"], "regions": crops.tolist(),
            "scores": scores[0, :len(crops)].tolist(), "importance": importance[0, 0].flatten().tolist()})
    (fixture_dir / "pytorch-parity.json").write_text(json.dumps(fixtures), encoding="utf-8")
    manifest = dict(model="Appwrite FocalNet human crop ranker", repository=REPOSITORY, revision=REVISION,
        hubRevision=HUB_REVISION, weightsSHA256=WEIGHTS_SHA256, sourceSHA256=SOURCE_HASHES,
        parameters=4_757_694, precision="float32", inputProfile="Pillow bilinear letterbox 256; ImageNet RGB normalization; normalized zero padding",
        semantics="Relative crop preferences within one source image; not detector confidence or an absolute photo rating",
        parity=dict(images=len(fixtures), maxPreferenceError=preference_error, maxImportanceError=map_error))
    Path("FocalModelManifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    Path("models").mkdir(exist_ok=True)
    Path("models/FocalNet-LICENSE.txt").write_bytes(license_path.read_bytes())
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
