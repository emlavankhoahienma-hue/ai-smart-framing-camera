# Subject-aware camera reframing

This replaces the composition search of `8baea803327e6bb5b8d9d402b9a2e8729a7e5e92`.
The optical tracker, gyro fusion, YOLO, face association, coherent person groups,
camera service and photo/video/save implementation retain their original hashes.

## Why the previous target stayed at the pressed heading

The old planner required all future image corners to remain inside the captured
source. At the same focal length, almost every nonzero camera pan therefore
failed feasibility. A second problem was using whole-photo SAMP/Charm ratings as
the main crop-ranking objective; preserving the complete source often won. The
result then legitimately had an identity rotation, so its target was simply the
heading of the camera when the source frame was captured. Neither issue is fixed
by animating the target or forcing an arbitrary off-center point.

The previous 160-photo report selected the exact original image in 61 cases.
The existing FCDB evaluation matched human crop-pair votes in 173/300 cases.
Those were numerical model tests, not proof that everyday camera framing worked.

## Released local crop model

The new source-relative ranker is [Appwrite FocalNet](https://github.com/appwrite/focalnet),
released with [checkpoints](https://huggingface.co/appwrite/focalnet) on September
18, 2026. It has a RepViT-M0.9 importance encoder and a preference head pretrained
on CPC and fine-tuned on GAICD. This is a released trained checkpoint, not a model
trained by this project. Appwrite publishes engineering evaluations; there is no
claim here that FocalNet has a separate peer-reviewed paper. SAMP-Net (BMVC 2021)
and Charm (CVPR 2025) remain real quality audits of shortlisted observed views.

The exact source revision is `f3c55aeb5827f302d1bbe9f0f41da38139f3dc36`;
the Hugging Face revision is `f114d602b055aa1955f23a591a161336517789c4`.
The released PyTorch checkpoint SHA-256 is
`82c4d695310c220e5f3bcfbf5e64d315a5e826cfd77e945e61e032460014480a`.
Conversion preserves the learned network in float32. The model is bundled and
inference does not contact a server. Published weights, source and license are
verified before conversion; production Swift preprocessing is tested separately.

An initial CPU probe matched 210/300 FCDB crop preferences. It also selected the
complete original in 149/160 same-aspect unconstrained CADB searches. This is why
the model is not deployed as an unrestricted raw-logit winner. Relative crop
preference does not substitute for selecting a photographic objective.

## Planning and freshness

The detector first freezes a measured subject/group. Learned importance enriches
composition evidence without raising detector confidence or changing membership.
The existing context, gaze, subject size, headroom, edge safety and balance
measurements define an admissible set near the best safe photographic geometry.
The trained crop ranker then compares these regions in the full source context;
SAMP and Charm audit a small shortlist. The original remains a valid outcome when
it satisfies the framing objective. Its status explicitly says to keep the frame.

The encoder is shared across up to 128 crop regions per call. Bounded neighboring
views refine the leading proposals; only six or eight views run through the
larger quality models. Preference logits are compared within one source image,
and never displayed as recognition confidence or an absolute aesthetic rating.

The audits can veto a substantial zoom when FocalNet and Charm jointly indicate
lost context/quality, or both whole-image quality models indicate a material
regression. The guard margins exceed measured numerical/preprocessing variation.
When the relative crop ranker clearly prefers the source, making the subject
larger also needs a measurable improvement from at least one quality model.
This catches observed blurry-background and false-face zooms that a geometric
subject-size objective alone encouraged. If every goal-fitting crop is vetoed,
the actual scored original is offered for explicit review; it cannot silently
become an automatic center target. Same-focal pans retain separate observed-pixel
handling because their unknown new margins are not complete photo crops.

Camera-pan mode permits a small newly revealed margin, with at least 78 percent
of the planned view supported by observed source pixels. Polygon clipping
measures support. Previews and quality audits contain only observed pixels; no
image generation, black-padding fiction or unseen-pixel confidence is used.
The full protected subject and selected companions must still fit in the frame.
Full-source rendering and final scene verification check every projected corner;
an almost-complete area fraction cannot hide a thin newly revealed triangle.

If camera pose has changed by more than two degrees or the lens changes during
analysis, the result is discarded and a new captured frame is analyzed. This is
bounded to two automatic retries per button press. Continuous motion asks the
user to hold the camera instead of producing a stale target.

After alignment, a plan that reveals new margins must pass recognition again on
an actual current camera frame. The principal subject category, spatial overlap,
minimum people and faces are checked. A failed or cancelled check cannot trigger
capture. The existing optical freshness, crop, zoom and post-await alignment gates
remain in force. The tracker itself still follows the real subject point; one
projected photographic aim drives both the visible dot and alignment admission.

CameraService's measured telephoto factor is passed separately from display zoom
presets. A 4x or 5x physical lens can extend the search beyond the old digital
budget when that factor is also advertised by the camera. A digital 5x button
alone cannot imply optical resolution or raise that budget. Final lens feedback,
fresh tracking and capture admission still use the unchanged camera controls.

## Verification and limits

- Native policies cover one-focal-length pan feasibility, observed support,
  invalid/flat evidence, stale heading/lens rejection and group-member loss.
- Conversion and the production Swift wrapper are compared with the released
  PyTorch model on 32 real images. Native image/box/content tensors are replayed
  unchanged in PyTorch to test model numerics independently of JPEG decoders.
  Pillow versus ImageIO/Core Image input differences are bounded and reported
  separately; those different decoded inputs must not masquerade as model error.
  Black, white and low-light flat inputs must
  remain finite. FCDB's same 300 published human crop-pair votes are checked;
  dataset training overlap is not established, so this is not claimed as an
  untouched benchmark or overall photo-quality accuracy.
  The 30 original photo inputs are fixed under `tests/fixtures/fcdb/` with
  their published URLs and SHA-256 values in `SOURCES.json`; runner evaluation
  does not depend on Flickr allowing that runner's IP address.
- The production detector and composition search run on the same 160 full source
  images, plus the remaining 326 human-scene test photos, covering all 342 human
  photos in the author test split. A further 36 virtual camera windows test different initial framing.
  Those 36 searches use the constrained device budget, alongside the normal
  budget used for the 486 source photos; neither is a device latency benchmark.
  Another 24 searches reuse 12 confident physical subjects under 4x/5x optical
  profiles, with the same model and crop-safety checks. The profiles supply
  hardware metadata; they do not simulate a physical lens or claim device tests.
  Final replay margins come from real parent-photo pixels, and exercise the
  actual recognition and guide projection. These are planar image replays, not
  physical camera, parallax, shutter or optical-lens tests.
  These photographs also supply application-policy regression cases; the counts
  are functional validation, not an untouched benchmark of aesthetic quality.
- Simulator checks render the production reticle/zoom artwork with synthetic lens
  feedback. Xcode compiles the iOS release with warnings as errors, and packaging
  verifies all six compiled models against their manifests.

No iPhone XS/17 Pro Max latency, thermal, lens-handover or physical capture/save
measurement is claimed. The source is designed for iOS 17+; hardware confirmation
still requires running the signed app on an actual phone.
