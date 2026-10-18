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
