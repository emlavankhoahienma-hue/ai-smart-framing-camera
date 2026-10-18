# Camera reliability audit (2026-10-18)

Baseline: `56260af71371f9a3cddc3ff33b971f7cb2fc7cd2`.

## Findings before editing

- WindowedZoomOverlayView positions a ZStack containing an unbounded positioned
  crosshair without first fixing the stack to the crop size. Its layout is larger
  than the visible border. Drag uses absolute finger coordinates instead of the
  translation from the starting crop center. Both can move the window upward.
- Window fractions assume a 3:4 source, while photo, square and 9:16 video need
  explicit source/output aspect ratios. Photo processing reads the window center
  after exposure instead of freezing it with the capture settings.
- VideoPreviewSheetView crops processedVideoURL repeatedly, and applies the same
  crop again when grading. Independent X/Y scaling can stretch a different-aspect
  crop. The source must remain immutable and crop/color must be rendered once.
- CameraService admits larger non-16:9 formats for 4K, and chooses a frame-rate
  range's minimum duration (its maximum FPS) instead of the requested 30/60 FPS.
  The film preview also holds its last video buffer while recording disables that
  output, so the overlay can obscure the moving AVFoundation preview.
- compositionAlignmentPoint reads raw spatial.projection, bypassing the existing
  tracker's presentation recovery slew. A temporary missing pose clears the dot,
  resets dwell, and cancels asynchronous verification. Status directly follows
  individual evidence samples instead of the hysteretic admission state.
- One-shot Core ML calls run in a detached task without per-inference autorelease
  pools. Focal and semantic model lifetimes overlap larger quality models. Charm
  accepts different patch shapes per crop. The supplied log has no jetsam report
  or stack trace: memory pressure is a concrete risk, not a proven crash cause.

## Blast radius and verification plan

Window geometry will be shared by the overlay, frozen photo crop and video export;
test portrait/square/video dimensions, translated touch gestures, boundary clamps,
nonzero Core Image origins and repeated exports. Native video fixtures must verify
encoded dimensions, orientation and FPS, with identifiable image landmarks.

Composition-to-guide presentation and admission will consume the same displayed
tracking point. Optical/IMU engines, appearance identity, group membership and
capture freshness remain independent safety requirements. Test brief evidence
gaps, recovery, sustained loss, moving camera and cancellation during verification.

Inference stages will release transient buffers/models deterministically, report
errors explicitly and record memory/stage diagnostics. Evaluate the released
Focal crop model and Charm 2025 alongside Apple's on-device image-aesthetics
request (introduced in 2024, iOS 18+). iOS 17 keeps supported bundled experts.
No unsupported claim of ANE placement, device latency or crash reproduction.

Run native production policies, actual Core ML inference on the established real
photo corpus, repeat-inference memory tests, simulator layout screenshots and a
Release Xcode IPA build. Hardware shutter, thermal and jetsam conclusions require
device evidence; a green CI job alone cannot establish them.

## Further cross-review findings and repairs

The displayed subject point and the latest frame can belong to different camera
poses/intrinsics. The tracker now exposes its exact delivered smoothed world
bearing, read-only, alongside the existing callback. Composition reprojects that
bearing into the current image. Fusion, optical identity, Kalman corrections,
recovery slew and their thresholds are unchanged. A delayed-frame/zoom native
replay checks this path rather than decoding an old point with new intrinsics.

Windowed capture waits for the optical 1x reset acknowledgement; crop settings
cannot freeze the previous telephoto base while the camera queue switches inputs.
Window controls are frozen for each recording/exposure. The chosen design keeps a
wide optical reference while moving an off-axis crop; it does not claim native
telephoto resolution for a digitally cropped window.

Video fallback now resolves a supported device/format pair for every requested or
fallback resolution. It commits exactly the requested frame duration, rolls back
a failed mode change and configures stereo after successful video-mode admission.
Export uses asynchronous composition creation, modern async export on iOS18+ and
a serialized compatibility exporter on iOS17. Cancellation reaches AVFoundation
and removes partial output files. This is checked using encoded video fixtures.

Final scene verification no longer reloads SigLIP or the scene classifier. It
still measures bodies, faces, animals, saliency and the photographic detector,
then applies the same hero/group/overlap/count policy. The final-photo replay
executes this exact reduced path and asserts that no semantic encoder was used.

The new one-shot detector is pinned Ultralytics YOLO26s (2026), exported as an
Apple NMS pipeline. The retained YOLO12 tracker uses its original scaleFill and
recovery behavior. The old unused photographic flag was removed from that private
decoder. A frozen 96-image author-labelled COCO val2017 subset is evaluated before
composition conversions, so model choice can be assessed using measured results.
This is a subset test at the app's 0.45 confidence filter, not official COCO AP.

The raw detector comparison is followed by two full production-recognition runs
on the same 96 sources. The baseline bundle contains YOLO12s and the new bundle
contains YOLO26s; both contain the same SigLIP prompts and Vision fusion code.
The harness asserts the detector that actually ran on every image. It records
all retained candidates, face associations, coherent groups and the selected
hero, including six reviewed detector regressions. COCO has no photographic
hero/group labels: these decisions are diagnostic observations, not invented
ground truth. Whole-person/animal box accounting excludes face-only candidates
and synthetic group unions; animal species are explicitly collapsed.

Simulator snapshot timeouts collect app-specific launch diagnostics before one
bounded cold-service recovery. Genuine launch errors and repeated timeouts still
fail. Stage screenshots are reviewed independently of the native video pixel
tests; recovering a simulator service is not evidence of a repaired app crash.

Sources: [YOLO26 paper](https://arxiv.org/abs/2606.03748),
[author models](https://huggingface.co/Ultralytics/YOLO26),
[Apple image aesthetics](https://developer.apple.com/documentation/vision/vncalculateimageaestheticsscoresrequest),
[Charm paper](https://arxiv.org/abs/2504.02522),
[FocalNet source](https://github.com/appwrite/focalnet).
