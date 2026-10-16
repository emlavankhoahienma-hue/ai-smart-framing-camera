# Runtime model provenance

The iOS workflow downloads official pretrained `yolo12n.pt` and `yolo12s.pt`
from the Ultralytics v8.3.0 asset release, checks their SHA-256 digests, exports
FP16 Core ML models with NMS, and compiles them into the IPA. Package versions
are pinned. `scripts/verify_model_bundle.py` records the source-weight and
compiled-tree hashes in `YOLOModelManifest.json` in the app bundle.

`scripts/export_siglip_coreml.py` pins the Google SigLIP repository revision and
weight digest, verifies conversion parity, and exports the image encoder and
normalized text prompt vectors. Apple Vision saliency, face landmarks and
iOS 18 aesthetic scoring use system-provided pretrained models.

The obsolete synthetic four-class `yolov26-engine` assets, example training and
export scripts, and unsupported performance claims have been removed. They were
already excluded by the old runtime loader. They are unrelated to official
Ultralytics YOLO26 pretrained models. No synthetic detector is packaged or
decoded by this app. `RobustTargetEmbedder.bin` and the existing target recovery
implementation are preserved.

See [photographic composition architecture](../docs/PHOTOGRAPHIC_COMPOSITION.md)
for the actual selection, fallback and resource-lifetime policy.
