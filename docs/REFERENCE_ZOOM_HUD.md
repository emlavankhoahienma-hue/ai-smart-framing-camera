# Reference-inspired target and optical zoom reveal

This change follows the supplied 9.33-second video: a fixed white hollow centre ring, a single
moving white target dot, orange confirmation, then a rounded white crop outline
with a restrained coloured halo. It changes presentation, not recognition models,
subject ranking, optical tracking, target pinning or capture authorization.

## Behaviour

- The existing target coordinates, aspect-fill projection and edge docking are
  unchanged. The centre ring and moving dot have no cross, pulsing radar or perpetual animation.
  A status label is an overlay outside its fixed 36-point layout container, so
  losing optical evidence cannot move the target.
- The dot and ring turn orange on the existing alignment decision. They yield
  to the crop outline during a real AI zoom and return after verification.
- Before zooming in, the outline shows the actual final crop. During the optical
  ramp its normalized width and height equal `actualZoom / targetZoom`. The
  camera's live zoom callback is the only source of expansion. No independent
  timer, spring or target-zoom assignment fabricates hardware progress.
- On zoom out, the outline tracks the original visible field:
  `actualZoom / startingZoom`. The wider unseen image cannot be previewed before
  the camera supplies it. Both directions use the production aspect-fill mapping.
- Invalid/nonpositive lens or viewport values produce no aperture. A no-zoom
  shot has no fake zoom animation. Pinch, cancellation, re-pin, backgrounding,
  zoom timeout, face verification and shutter gates retain their existing paths.
- The light veil affects only the outside of the outlined region; the camera
  feed is not blurred. The displayed current magnification is hardware feedback.
  Only reveal opacity fades; changing crop size is not implicitly animated.

## Boundaries and verification

`tests/TrackingBoundary.json` now explicitly protects camera/tracking, pinning,
alignment/capture, zoom admission and delayed hardware-ramp execution against
the actual starting commit `fdd01d9607f5713b6aa5a4e183454c064a3d4b33`.
The old hashes of target artwork and reveal-opacity statements were removed
because the user explicitly requested replacing that artwork. Retained hashes
come from the unmodified starting source, not the new implementation.
`PhotographicDetectionBoundary.json` remains unchanged.

The native `ViewfinderPresentationRegression.swift` suite executes the production
geometry for preflight, stalled feedback, many zoom paths, zoom out, very small
crops, new sessions, invalid numbers, overshoot, aspect-fill projection and guide
clearances. Existing native composition/capture and portable suites also run.

The `zoom` option in the Simulator Snapshot workflow runs the actual SwiftUI
reticle and reveal overlay on small, standard and Pro Max simulator screens.
It captures seven explicit states plus a motion video per available device.
The calibration scene and lens values in this simulator-only host are synthetic;
they verify rendering and transitions, not physical lens speed, AI quality or
device temperature. The test host is never installed in the IPA build.
