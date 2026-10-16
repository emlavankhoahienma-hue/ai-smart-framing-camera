# Photographic subject and composition pipeline

This revision changes interpretation, composition search and viewfinder styling.
It leaves the pinned target's optical tracking, motion fusion, recovery, zoom
verification, alignment gate and photo/video/PhotoKit pipeline intact.
`scripts/verify_tracking_boundary.py` checks normalized SHA-256 hashes of ten
complete source files, three view-model regions, the projected target layer and the original reticle view
against commit `49f3ef3a2938bf5f36c2e8e47e9fdf5980875abf`.

## Data flow

```text
Detached camera image + capture pose + calibration
  -> Vision bodies / own face landmarks / animals / two saliency maps
  -> YOLO12s pretrained COCO inference for photographic analysis
  -> measured subject ranking, deduplication, coherent person grouping
  -> freeze one primary subject or group
  -> constrained pan / tilt / continuous focal-length search
  -> perspective-correct previews
  -> Apple aesthetic model (iOS 18+) and SigLIP semantic comparison
  -> existing choice / confidence policy
  -> existing pinTargetAndStartMotion contract, unchanged
```

No image or inference is sent to a server by this local pipeline. The existing
optional cloud mode remains a separate user choice.

## Subject interpretation

`HeroSubjectPolicy` combines detector confidence with relative subject size,
semantics, face association, attention density, attention mass, measured local
contrast, detail and exposure. A small confident background person does not
automatically outrank a prominent object. Confidence is never increased by
saliency, semantic similarity, preference feedback or aesthetic scores.

Faces attach to a containing body using normalized head-position affinity.
The best associated face supplies that body's eye anchor and yaw, so the first face returned by Vision
cannot accidentally steer somebody else's composition. Overlapping body/object
proposals collapse before layout search; overlapping people with distinct eye
anchors retain separate identities. Comparable-scale nearby people form a
connected group. Distant small people do not enlarge the hero's protected crop.

One-shot analysis freezes identity and does not continuously replace a pinned
subject. Live preview uses a separate presentation-only identity selector: a
challenger needs 22 percent plus 0.025 more rank for 550 ms before taking over.
Empty, stale or invalid evidence clears the presentation. This selector has no
access to target, optical-flow, pose or capture state.

## Composition and zoom

The search proposes a camera rotation and a continuous focal length together.
It uses the existing calibrated ray/projection functions to predict the full
subject rectangle and all four source-image corners. Invalid calibration,
nonfinite values, unseen source pixels, newly cropped hero boundaries and
cropped selected companions reject a proposal before aesthetic ranking.

A coarse spatial/log-focal search seeds continuous coordinate refinement. Its
objective combines scene-specific subject occupancy, retained context, clean
frame borders, visual balance, measured symmetry, subject separation, headroom,
edge margin and supported horizon position. Positive image-right yaw places the
subject toward the left to preserve looking room. The eye anchor has a separate
vertical objective from a generic object's centre. Group and architecture
layouts prefer centering where appropriate. Source visibility is authoritative;
the engine never claims to know what a pan outside the observed image contains.

Automatic magnification stays within the camera's supplied range and at most
2.4 times the source magnification / 5x absolute. An already selected longer
telephoto frame remains available. This limit avoids optimizing aesthetics by
discarding excessive source resolution. Actual hardware motion, crop verification
and post-zoom capture safety continue through the original implementation.

Apple's pretrained aesthetic assessment contributes at most 0.075 rank to each
already safe preview. SigLIP contributes a bounded semantic correction; it is
not described as an aesthetic model. Utility-image classification does not veto
intentional food or product photographs. User preferences only nudge safe choices.
Neither learned model can authorize capture or rescue an invalid crop.

## Device and runtime policy

| Environment | Photographic inference |
| --- | --- |
| iPhone XS and later, iOS 17+ | YOLO12s for a requested still analysis, native Vision and bounded geometric search |
| At least 4 GB RAM, normal thermal state, Low Power Mode off | Pinned SigLIP encoder and semantic prompt bank, released when analysis finishes |
| iOS 18+ and aesthetic request succeeds | Apple pretrained aesthetic preview ranking |
| Serious/critical thermal state or Low Power Mode | Existing lightweight detector path; skip SigLIP |
| Missing/failed Core ML assets | Independent native Vision evidence; weak or empty evidence cannot force a target |

The quality-only YOLO model has a separate short lifetime and cannot replace the
detector used by existing target recovery. Its input preserves aspect ratio.
Legacy `detectObjects` keeps its previous threshold, geometry preprocessing,
label mapping and prominence formula for recovery callers.

All heavy interpretation runs in the existing detached serialized worker.
Frames retain their capture timestamp/calibration/pose through the existing
handoff. Cancellation reaches active Vision requests and bounded search. No
unbounded frame queue, new camera-pool cache or per-frame aesthetic model is added.
The small immutable 32x32 evidence raster is independent of camera-buffer lifetime.

A 60 FPS camera preview is a design target, not a measured device guarantee.
Native model scheduling can include CPU fallback; ANE-only execution is not
claimed. Physical-device profiling is still required for latency, peak memory,
temperature and image preference on XS, intermediate devices and 17 Pro Max.
Actual world motion between the one-shot image and user alignment remains the
responsibility of the unchanged tracker and capture verification.

## HUD

The HUD renders a single hero/group bracket with restrained champagne accents,
thin contrast-backed strokes and a damped spring on detection rectangles. Once
a target is pinned, incidental detection boxes disappear. Projected target
position, docking, hit testing and the transaction disabling position animation
remain byte-for-byte equivalent after newline normalization. The complete reticle
view is restored to its original circle, central crosshair, colors, dimensions
and pulse, as requested. Its source is protected by the baseline hash manifest.

## Verification

The macOS native regression executable runs the production planner, raster
renderer, numerical policies and cancellation code. Added cases cover attention
versus semantics, distant clutter, five-person proximity, identity hysteresis,
empty/low-light frames, correct gaze direction and continuous hardware-bounded
zoom. Existing crop, companion, projection, orientation and capture-transition
regressions remain in CI. The full unsigned iOS build still treats Swift/Clang
warnings as errors, packages the real pretrained models, checks their provenance
and creates an IPA. A successful build is not a physical camera or aesthetic
preference evaluation.

## Primary references

- [Apple face landmarks](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest)
- [Apple attention saliency](https://developer.apple.com/documentation/vision/vngenerateattentionbasedsaliencyimagerequest)
- [Apple objectness saliency](https://developer.apple.com/documentation/vision/vngenerateobjectnessbasedsaliencyimagerequest)
- [Apple aesthetic scoring](https://developer.apple.com/documentation/vision/vncalculateimageaestheticsscoresrequest)
- [Apple aesthetic score observations](https://developer.apple.com/documentation/vision/vnimageaestheticsscoresobservation)
- [Ultralytics Core ML integration](https://docs.ultralytics.com/integrations/coreml/)
- [Pinned SigLIP model](https://huggingface.co/google/siglip-base-patch16-224/tree/7fd15f0689c79d79e38b1c2e2e2370a7bf2761ed)
