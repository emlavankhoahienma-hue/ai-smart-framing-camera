# Composition target and automatic shutter repair

Starting source: `e89f2c66ab61fc2a2b35b5bd4fe9c6a50602d886`.

The previous integration seeded the optical tracker at the composition aim. That
point can be on a blank wall or between group members. The selected plan already
contains a separate measured subject point. Local plans now pass that point to
the unchanged tracker, and use `CompositionAimGeometry` to project the selected
photographic aim. The overlay and shutter admission read this same projection.
Only one moving dot is displayed; the existing hollow centre ring and zoom artwork
are retained. Focus and crop protection continue to follow the physical subject.

The absolute three-degree device-roll veto was removed from shutter admission.
It could strand an aligned landscape or downward-looking shot even though the
selected image was already tilted. Existing horizon presentation remains available.

`CaptureReadinessPolicy` requires accepted optical observations with real capture
timestamps, valid calibration and image coordinates. Gyro prediction and elapsed
time cannot replace an optical observation. Zoom verification requires actual lens
feedback, a matching post-settle camera frame and an accepted post-settle optical
observation. It no longer overwrites the optical timestamp or fabricates a box.
Successful zoom starts a new stable alignment hold. A failed zoom restores the
original field and waits for the existing measured recovery policy. Crop protection
and post-zoom face checks run before capture; the current aim and crop are checked
again after asynchronous face verification. Normal no-zoom shots skip face recheck.

An incomplete composition-model result no longer generates a fixed golden-ratio
target or area-based zoom guess. Automatic plans require both trained scorers to
complete and the existing evidence-confidence threshold. Otherwise measured
suggestions remain available for explicit selection.

The YOLO12s/YOLO12n, Vision, SigLIP, group membership and subject-ranking code is
unchanged. This repair improves which measured subject is passed to tracking; it
does not claim increased detector accuracy or introduce a new trained model.

Search budgets now depend on scene complexity and resource limits:

| Scene | SAMP coarse/refinement | Charm views |
| --- | --- | --- |
| Simple | 24 / 8 | 10 |
| Group, landscape, architecture, environmental portrait | 32 / 12 | 12 |
| Simple, constrained device | 18 / 8 | 8 |
| Complex, constrained device | 24 / 8 | 10 |

Both scorers, the original frame and protected-subject constraints remain. Tighter
alternatives receive reserved slots before neighbouring crops use the Charm budget.
The full-resolution photo validator uses the same budget policy as the app. This
reduces inference work; iPhone latency must still be measured on physical devices.

Native regressions exercise aim/subject separation, alignment holds at multiple
delivery rates, no-zoom capture readiness, real post-zoom evidence, reacquisition,
stale/invalid observations, manual zoom and protected ROI visibility. Portable
source contracts check the actual overlay and CameraViewModel wiring. Real-photo
CI executes both models and the preserved detector on 160 source images, checks
protected people/animals, and builds the complete iOS app with warnings as errors.

`TrackingBoundary.json` retains hashes for all optical/gyro implementations, pin
seeding, hardware ramp, camera and photo/video execution. Its former broad hashes
covering the faulty admission/verification code were narrowed to the unchanged
camera execution; retained hashes are computed from the unmodified starting source.
The three photographic detection boundaries are unchanged. Rendering checks use
simulated lens feedback. Neither those checks nor photo-model tests exercise an
actual iPhone camera, lens handover, thermal behaviour or shutter/save operation.
