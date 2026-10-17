# Local photographic composition and zoom

The local button always captures a new frame and runs real model inference.
Each result carries a request UUID, source timestamp, measured elapsed time and
successful assessment counts. An old frame or result cannot authorize a new
button press. Model load/compilation can make the first run slower than later
runs; no fixed waiting period is used as evidence of quality. The HUD reports
actual SAMP-Net frame counts, Charm assessments and elapsed seconds.
Local analysis has a 75-second cancellation deadline to accommodate cold model
loads on older devices. It returns as soon as the real comparisons finish;
results older than 30 seconds require explicit preview selection instead of
autoselection. Manual review expires 15 seconds after analysis completes, with
a 90-second maximum source age; a cold model cannot consume the review window.

## Released models and provenance

The composition scorer remains **SAMP-Net (BMVC 2021)**, using the author's
[CADB checkpoint](https://github.com/bcmi/Image-Composition-Assessment-Dataset-CADB)
and [paper](https://arxiv.org/abs/2104.03133).

The second scorer is **Charm (2025), DINOv2-small trained on PARA photographic
aesthetic ratings**, from the [author repository](https://github.com/FBehrad/Charm),
[paper](https://arxiv.org/abs/2504.02522) and
[released checkpoints](https://huggingface.co/FatemehBehrad/Charm).
It has 21,538,185 learned parameters. This is the actual released specialist,
not an untrained DINOv2 encoder or an invented aesthetic head.

Checkpoint SHA-256:

| Model | SHA-256 |
| --- | --- |
| SAMP-Net | `d3d02f36967734fd6f0d2770380a04b777b5cd800a9ba68d4ccc9656f6fef603` |
| Charm-PARA | `d7ce85f65ed25fa8c15eeb52f63310e7207cf76fd11ca763f284576d3824a9cb` |

Author sources, checkpoints and position embeddings are pinned and checked
before loading. Model exports include manifests, conversion parity and licenses.
Both run locally through Core ML with CPU/Neural Engine execution requested.
Execution placement of every operation on the ANE is not guaranteed.
No inference server or phone-side model download is required.

## Decision process

1. Preserve the existing YOLO detections, face association, hero identity and
   coherent groups. Detection is unchanged from app revision `8ee6d56`.
2. Generate up to 36 feasible views, then up to 18 local refinements. Devices
   with less than 6 GB physical RAM, Low Power Mode or serious thermal pressure
   use 24 broad proposals. Preserve the unchanged frame as an option.
3. SAMP-Net evaluates composition for the rendered candidates. Release it before
   loading Charm, which reranks up to 18 candidates (12 on constrained devices).
   Include strong tighter views and neighbours, rather than simply rejecting
   every zoom that does not gain 0.10 SAMP rating points.
4. Combine normalized SAMP composition, Charm aesthetics and geometric layout
   with weights 0.45, 0.40 and 0.15. A crop above 1.08 times the source zoom must
   improve the combined score by at least 0.008. These are app policies, not
   calibrated probabilities of human preference.
   Both individual ratings must also stay within 0.06/5 of their original-frame
   values. This permits small numerical variation, while rejecting a clear
   aesthetic regression concealed by a composition gain (or the reverse).
5. Automatic selection requires complete evidence from both scorers, at least
   12 SAMP assessments, local support, detector certainty and a useful margin
   over distinct alternatives. Missing or partial inference uses manual previews;
   fallback scores are never mixed with learned scores on a different scale.

The camera's existing focal limits, relative 2.4x/absolute 5x quality cap and
original zoom ramp are retained. Recommendations cannot invent unseen pixels.
Clutter can be excluded, while detected incidental faces/pets must stay whole
or be omitted whole. A zoom is not forced when it worsens the measured scores.

## Deliberate portrait framing

Previously every portrait crop had to keep the entire detected body, which
excluded head-and-torso photographs even when a tighter view was appropriate.
For a single person with an associated face, an additional built-in Vision pose
request may establish measured shoulders and hips. A torso region is admitted
only when the neck matches that face, both shoulders and hips are reliable,
the face and shoulders remain inside, and the lower cut avoids measured elbows
and wrists. Missing/ambiguous pose evidence retains the complete body.

The environment-portrait option keeps the complete person; groups always retain
their members. This is a composition constraint, not a change to identity or
tracking. The original full body remains the tracker's source rectangle.
The windowed-focal AI shortcut (a 28/35/50/85 mm lookup table) and its obsolete
state are removed. AI exits that manual mode, waits for actual lens settling and
requests a fresh image through the same inference path.

## Input fidelity

SAMP-Net uses RGB/ImageNet normalization, Pillow-compatible antialiased bilinear
resizing and the author's spectral-residual saliency. Its conversion is checked
against the unmodified author implementation and production Swift preprocessing.

Charm uses a bounded preview with aspect ratio preserved, at most 336 pixels
on the long edge, Pillow antialiased bilinear sampling and the author's
`normal_flow`: RGB in [0,1], right/bottom zero padding to 14-pixel patches,
no token dropping, and the exact DINOv2 bicubic position convention. This mobile
profile does not claim full-resolution multiscale Charm benchmark performance.
The exported projection is algebraically equivalent to the author's convolution,
learned scale embedding, encoder and nine-bin PARA aesthetic head. The original
tokenizer and original model independently verify each export fixture.

## Actual measurements

The prior official SAMP evaluation covers all 950 CADB test photos, separate
from its 8,547 training photos: Spearman 0.6567, Pearson 0.6711, MAE 0.4866/5.
Full records remain in `evaluation/samp-cadb-test-950.json`. These numbers measure
whole-image composition agreement, not crop preference.

An additional published FCDB ranking test selects 32 photo IDs by SHA-256 before
predictions. Thirty sources remain available; two return HTTP 404 and are reported
without replacement. On all 300 human-voted crop pairs, SAMP agrees with the
majority on 169/300 (56.33%), Charm on 172/300 (57.33%), and their fixed weighted
combination on 173/300 (57.67%). On the 147 pairs with at least four of five votes,
SAMP and the combination both obtain 91/147 (61.90%). The improvement is modest;
these data do not establish a universal or statistically significant gain.
No fine-tuning or score-dependent photo selection was performed.
See `evaluation/fcdb-crop-preferences-300.json` for URLs, image hashes, human votes,
model scores, failed downloads and the declared scorer-only scope. The app's
geometric constraints, capture integration and tracking are not evaluated by
these pair metrics.

CI separately checks 32 real-photo author/PyTorch/Core ML/Swift inputs and scores,
then runs recognition and search on 160 original full-resolution CADB photos
across 10 scene categories. Crop/project the original before resizing a candidate.
The native bundle compiles the actual protected YOLO/Vision/SigLIP recognition,
face association, hero/group selection and intent algorithms from app source.
Only the scene enum's iOS filter/UI computed properties are omitted by a data
adapter; source hashes are recorded. No subject boxes or confidence scores are
invented by the harness. It checks required body or measured torso regions,
faces and incidental pets. No-subject frames explicitly remain manual.
Camera/motion/capture integration and hardware intrinsics are not exercised;
the geometry uses its declared fallback calibration. Additional native bundles execute the unchanged
YOLO12n and YOLO12s production photographic loaders/decoders on those same 160
photos, a blank frame and cancellation. Detection counts are observations, not
accuracy against human object-box labels.

## Preserved boundaries and limits

CI verifies seventeen original target/capture/reticle source boundaries against
`49f3ef3`, plus the three recognition/group boundaries against `8ee6d56`.
Tracking, recovery, subject projection, reticle shape, zoom verification, photo
capture, video and saving remain unchanged. The original broad view-model
boundary is split around the intentionally changed AI alignment input: all
replacement region hashes are calculated from `49f3ef3`, never from patched code.
The alignment gate body remains protected. A separate read-only quaternion
maps the tracked subject bearing to the selected photographic aim. Alignment
tests this aim, while the original yellow circle continues following the subject.
A small labeled composition marker shows where to point the unchanged white
optical center. Missing pose/frame evidence blocks automatic alignment.

Measured torso bounds feed only crop protection after the unchanged full-body
tracking seed is installed. This fixes full-body protection vetoing an intentional
torso portrait at zoom execution. Group and environmental views retain complete
subject bounds. CI also runs actual Vision body/face/pose plus production torso
eligibility over all 342 CADB human test images; the initial diagnostic admitted
67, without weakening joint confidence or inventing missing anatomy. Every build compiles iOS Release
with warnings treated as errors and verifies packaged model hashes.

Heavy inference remains serialized off the main thread; cancellation is checked
between predictions, and critical thermal state prevents further predictions.
Source generation, lens settling, analysis deadlines and frame freshness still
apply. A synchronous prediction cannot be interrupted halfway through.
No physical XS/17 Pro Max performance, RAM, temperature, 60 FPS or photographic
preference guarantee is inferred from macOS CI. Inference duration alone does
not prove whether a recommendation is good or fabricated.
