# Local pretrained photographic composition assessment

This upgrade changes composition and zoom recommendation. The YOLO loader,
weights, object labels, person/animal/object inference, face association, hero
ranking and coherent-group construction remain unchanged from `8ee6d56`.
The existing target tracker and original reticle remain protected against the
earlier baseline `49f3ef3`. CI verifies both sets of source hashes.

## Model and provenance

**SAMP-Net**, by Bo Zhang, Li Niu and Liqing Zhang, is the composition assessment
network in [Image Composition Assessment with Saliency-augmented Multi-pattern
Pooling, BMVC 2021](https://arxiv.org/abs/2104.03133).
The [author repository](https://github.com/bcmi/Image-Composition-Assessment-Dataset-CADB)
publishes both code and the pretrained checkpoint. CADB contains 9,497 photos
rated for composition on a 1–5 scale by five raters with fine-art expertise.
SAMP-Net combines a ResNet-18 backbone, eight spatial pooling patterns,
spectral-residual saliency and composition-relevant attribute features.

This project converts the author checkpoint; it does not claim to have trained
a new model. Source revision, source hashes, checkpoint hash, paper, input
profile and numerical conversion results are pinned in the export script and
`SAMPModelManifest.json`. MIT attribution is included in the app bundle.

The checkpoint SHA-256 is:

```text
d3d02f36967734fd6f0d2770380a04b777b5cd800a9ba68d4ccc9656f6fef603
```

SAMP-Net was selected because its released model directly predicts composition
quality and can run as a bounded FP16 Core ML still-image scorer on the supported
phones. It is not claimed to be the newest model or universally best model.
ProCrop's [author implementation](https://github.com/BWGZK-keke/ProCrop), for
example, also depends on retrieval references, SAM embeddings and a retrieval
database. Simply shipping its crop-head checkpoint would not reproduce its
published method on an iPhone XS. Generic SigLIP remains a scene-content model,
not a substitute for composition training.

## Camera recommendations

1. Keep the existing primary subject/group, bounds, eyes and face direction.
2. Generate up to 36 geometrically feasible views across pan, tilt and continuous
   zoom; use 24 when Low Power Mode or serious thermal pressure is active.
3. Always include the unchanged frame when feasible. Preserve every selected
   group member and face. Reject unseen source pixels and bisected background
   faces before scoring.
4. Score the perspective-rendered previews with SAMP-Net. Compare neighbouring
   positions and focal lengths around the three leading views (up to 18 further
   evaluations). Report actual stage progress instead of waiting on a timer.
5. Combine 78% normalized learned composition rating with 22% geometric layout
   score. Personal preferences can add at most 0.01. Reject zoom above 1.08 times
   the original unless it improves the predicted composition rating by at least
   0.10 on the 1–5 scale. These are conservative app policies, not calibrated
   probabilities of human preference.
6. Automatic selection requires complete specialist evidence, at least 12 model
   assessments, neighbourhood support and the existing detector confidence,
   ranking-margin and capture policies. Ambiguous alternatives appear as real
   preview choices, always retaining the unchanged frame as an option when feasible.
   Missing/failed weights cannot silently authorize a target.

The existing camera hardware zoom limits and 2.4x-relative / 5x-absolute quality
cap remain. The recommendation flows through the original zoom ramp,
post-zoom verification, optical target tracking, alignment and capture code.
The reticle shape, projected-target rendering, video and photo-save paths are
unchanged. There is no artificial delay or fabricated model output.

## Matching training preprocessing

Inference uses RGB float tensors in NCHW order, ImageNet normalization inside
the model, Pillow-compatible antialiased bilinear resizing and the author's
spectral-residual saliency convention (including 95th-percentile clipping).
The saliency port uses separable DFT matrices through Accelerate so arbitrary
preview dimensions do not require zero-padding. Vision saliency still supports
the existing subject detector; it does not replace SAMP-Net's trained input.

Core ML export rewrites only fixed-size max-pooling windows and static surround
indices into supported operators. All learned parameters load strictly.
Random-input operator equivalence, real-photo PyTorch/Core ML parity and
independent production Swift RGB/saliency/score parity are separate checks.
Tensor input avoids implicit image-feature colour conversions. CI fails when
the model, preprocessing or packaged provenance is inconsistent.

## Resource and failure policy

The model is bundled in the IPA and requires no inference server or model
download on the phone. Heavy work remains on the serialized detached worker.
The semantic image encoder is released before the photographic model is loaded.
The model and temporary preview images are released when analysis ends; no new
camera-buffer queue or continuous per-frame inference is introduced. The model
requests CPU and Neural Engine execution; ANE placement of every operation is
not guaranteed. Cancellation is checked between renders/predictions; an already
running synchronous Core ML prediction finishes before the next cancellation
check. Critical thermal state prevents further specialist predictions.

Fallback uses available geometric/system evidence for manual preview selection,
with an explicit message. Partial learned and fallback scores are never mixed
as though they were on the same scale. Source-frame freshness, generation
tokens, lens-change checks and existing analysis deadlines still apply.

## Reproducible evaluation

`scripts/evaluate_composition_model.py` evaluates **all 950 photos in the
author's CADB test split**, separate from the 8,547 training photos. No images
or labels from that split are used to fine-tune the checkpoint. Measured CPU
results for the pinned original model are:

| Photos | Count | Spearman | Pearson | Mean absolute error (1–5) |
| --- | ---: | ---: | ---: | ---: |
| Entire test split | 950 | 0.6567 | 0.6711 | 0.4866 |
| Human | 342 | 0.6555 | 0.6690 | 0.4948 |
| Landscape | 96 | 0.5293 | 0.5000 | 0.5542 |

`prepare_composition_photos.py` independently picks 160 test images: 16 each
from human, landscape, animal, plant, static object, architecture, cityscape,
indoor, night and other categories. Selection uses filename hashes, without
looking at aesthetic ratings. The source archive and every selected photo have
recorded SHA-256 digests. Test photos are not packaged in the app.

The model conversion compares 32 of those photos against PyTorch. The native
Swift validation checks RGB, saliency and rating parity, then runs production
candidate generation, perspective rendering, trained scoring and crop safety on
the original full-resolution photographs; resizing occurs after candidate
projection/cropping. Pre-resizing the source would artificially blur zoomed
previews, so bounded fixtures are only used for numerical conversion parity.
Its people boxes come from Vision in the macOS test
harness; this is not a full iPhone YOLO/camera test. A separate diagnostic scores
28 unconstrained crops per photo and generates contact sheets. Those preferences
are model outputs, not human ground truth; unsafe diagnostic crops are not app
recommendations.

Measured correlation does not prove that every suggested crop is prettier.
Neither macOS timing nor a successful iOS build establishes physical-phone
latency, peak memory, temperature, 60 FPS or subjective image preference on XS
through 17 Pro Max. Those still require physical-device testing. The repository
keeps these limitations explicit instead of reporting invented device results.
