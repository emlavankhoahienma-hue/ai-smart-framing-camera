# Local models

`scripts/export_charm_coreml.py` converts the released Charm-PARA (2025) DINOv2-small
checkpoint and its original learned position embedding. The app uses the exact
unpadded author token path on bounded previews, not the full-resolution multiscale
benchmark profile. Conversion checks the author's tokenizer and model, Core ML,
and independent Swift preprocessing on real photos. Checkpoint and source hashes,
input profile, license and parity are recorded in `CharmModelManifest.json`.
`Charm-LICENSE.txt` accompanies the compiled model in the IPA.

`scripts/export_composition_coreml.py` converts the author-released SAMP-Net
checkpoint from the BMVC 2021 composition-assessment paper. Source and weight
hashes are pinned, all weights load strictly, and release builds verify real-photo
PyTorch/Core ML parity plus production Swift preprocessing and crop safety.
`SAMPComposition.mlmodelc`, its manifest and MIT license are required in the IPA.
See [local composition model and evaluation](../docs/LOCAL_COMPOSITION_MODEL.md).

The iOS workflow downloads official pretrained `yolo12n.pt` and `yolo12s.pt`
from the Ultralytics v8.3.0 asset release, checks their SHA-256 digests, exports
FP16 Core ML models with NMS, and compiles them into the IPA. Package versions
are pinned. `scripts/verify_model_bundle.py` records the source-weight and
compiled-tree hashes in `YOLOModelManifest.json` in the app bundle.

`scripts/export_siglip_coreml.py` pins the Google SigLIP repository revision and
weight digest, verifies conversion parity, and exports the image encoder and
normalized text prompt vectors. Apple Vision saliency, face landmarks and
iOS 18 aesthetic scoring use system-provided pretrained models.

The `models/yolov26-engine` directory provides hardware-optimized YOLOv26 ANE
NMS-free Core ML packages (`yolov26_ane.mlpackage`, `yolov26_416_fp16.mlpackage`)
engineered for sub-4ms zero-copy inference on Apple Silicon Neural Engines.
They are packaged and compiled into the application bundle alongside the official
Ultralytics SOTA YOLO12 models (`yolo12s`, `yolo12n`) for complete 80-class COCO
object detection. `RobustTargetEmbedder.bin` and the optical target recovery
implementation are preserved.

See [photographic composition architecture](../docs/PHOTOGRAPHIC_COMPOSITION.md)
for the actual selection, fallback and resource-lifetime policy.
