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
    "__init__.py": "5258b1c2b4dbf112e4b84dec1395850d265709ed65cbf8e977f6364217b26066",
    "model.py": "c20a0e301099fb88f626b3064ce08902304a02a0d0d1b729f870f10600ecfa1a",
    "ranking.py": "7729cc9ac02ee0f9636457e80271d3b32d9b2a85cd3591e6e56086d199ad2b4b",
    "imaging.py": "a473f6063dddbe151bc41b9da115fc378461f62b205a82b88bb73606edd6eed6",
    "candidates.py": "962628bba952594831f34d6e4f8487caec3e620749019b097dfb1f2759e9527b",
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
        cache / "FocalNet-LICENSE.txt", "14344218b1fea7cd26df0e463d4ecadd5209d348f7ecf287bdb01f5623ece5a6")
    checkpoint = verified_download(f"https://huggingface.co/appwrite/focalnet/resolve/{HUB_REVISION}/focalnet-human.pt",
                                  cache / "focalnet-human.pt", WEIGHTS_SHA256)
    sys.path.insert(0, str(package.parent.resolve()))
    from focalnet.ranking import HumanCropInference, load_human_checkpoint
    network, metadata = load_human_checkpoint(checkpoint)
    if network.parameter_count() != 4_757_694 or metadata.get("dataset_name") != "GAICD journal version":
        raise RuntimeError("Unexpected released crop ranker")
    return HumanCropInference(network).eval(), license_path


def export_trace(model, arguments):
    with torch.inference_mode():
        traced = torch.jit.trace(model, arguments, strict=True)
    graph = traced.graph
    torch._C._jit_pass_inline(graph)
    # PyTorch promotes the author's integer clamp bounds to the float tensor.
    # Core ML's importer requires that scalar promotion to be explicit.
    for node in list(graph.nodes()):
        if node.kind() != "aten::clamp_min":
            continue
        inputs = list(node.inputs())
        bound = inputs[1].toIValue()
        if isinstance(bound, int) and inputs[0].type().scalarType() == "Float":
            promoted = graph.insertConstant(float(bound))
            promoted.node().moveBefore(node)
            node.replaceInput(1, promoted)
    torch._C._jit_pass_lint(graph)
    with torch.inference_mode():
        for expected, actual in zip(model(*arguments), traced(*arguments), strict=True):
            torch.testing.assert_close(actual, expected, atol=0, rtol=0)
    return traced


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
    traced = export_trace(model, arguments)
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
