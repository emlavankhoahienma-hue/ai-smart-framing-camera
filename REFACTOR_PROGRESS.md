# Layout and Tracking Refactor Progress

## Scope

Fix viewfinder collapse when opening Pro controls or changing capture modes; stabilize tracked targets and detection boxes; preserve accurate autofocus coordinates; publish a verified release IPA.

## Baseline

- Starting commit: `2bcb63080082527bd51ba3ef137bd6d56d31b976` on `main`.
- Working tree clean; GitHub `main` matches the local baseline.
- Development host is Windows. Apple SDKs and `xcodebuild` are unavailable locally; macOS GitHub Actions supplies compilation and release validation.

## Findings

- The preview shares a vertical stack with the Pro drawer and histogram. Their changing height reduces the preview's layout proposal.
- Overlay coordinate conversion assumes a 3:4 input even when the video buffer is 9:16.
- Both UIKit and SwiftUI install focus/zoom gestures over the same preview, with different coordinate/zoom conventions.
- Vision tracker start/stop mutates state outside its processing queue. Detection rectangles are published without identity matching or temporal smoothing.

## Work log

- [x] Verify repository baseline and trace layout, gesture, and tracking data flow.
- [x] Isolate preview geometry from floating controls and unify coordinate conversion.
  - Live View is a centered, fixed-ratio background layer (4:3 photo; 16:9 video/pro).
  - Top HUD, 1x/2x zoom switcher, Pro controls, film drawer, shutter, and mode switcher are independent overlays.
  - `Ảnh · Video · Pro` now renders below the shutter row; the Pro panel is height-bounded and scrollable.
  - UIKit owns viewfinder tap, long-press, and pinch gestures; SwiftUI's AR layer is draw-only.
- [x] Add stable identity association, bounded motion smoothing, occlusion retention, and autofocus gating.
  - Detection rectangles use IoU/center/scale association, adaptive smoothing, outlier confirmation, and short prediction windows.
  - Vision start/stop is serialized on its owning queue and publishes center, box, confidence, and predicted state.
  - Spatial tracking state/configuration is lock-protected across the camera, main, and motion queues.
  - Hardware AF/AE consumes finite clamped points, is rate-limited, and respects AE/AF lock and manual focus.
- [x] Add regression checks for aspect ratios, coordinate transforms, jitter, occlusions, outliers, and invalid numbers.
  - Added a Swift package test target covering iPhone SE/standard/Pro Max geometry, RMS jitter, linear tracking lag, one-frame outliers, short occlusions/reacquisition, and AF mapping/policy.
  - CI runs the data-only suite before the warning-as-error iOS build.
- [x] Run checks, push changes, self-heal Xcode diagnostics, and verify release artifacts.
  - First CI pass exposed ambiguous non-finite constants in the new Swift 6 test build; fixtures were qualified as `CGFloat` and rerun.
  - GitHub Actions run `35371679163` passed at implementation HEAD `258e9c3eddc2d204e5c5e14bf462010a7a4651d7`.
  - Data-only geometry/tracking tests, CoreML export, warning-as-error iOS Release build, IPA packaging, artifact upload, and release publication all passed.
  - Release `v1.0.0-build.194` contains `AISmartFramingCamera.ipa` (14,260,340 bytes, SHA-256 `c880110b1c3689318841ec7a26766bd578f14b139efac6804c335f21dfa152dd`) and the source archive.

## Local validation

- `git diff --check`: pass.
- `xcodebuild`: unavailable on this Windows host by design; the macOS CI build remains the authoritative Apple SDK gate.
- macOS GitHub Actions `xcodebuild` with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` and `GCC_TREAT_WARNINGS_AS_ERRORS=YES`: pass, with the workflow's explicit zero-warning log gate.

## Validation limits

Physical camera behavior, thermal performance, and gesture ergonomics require an iPhone. CI validation will be reported separately from hardware verification.
