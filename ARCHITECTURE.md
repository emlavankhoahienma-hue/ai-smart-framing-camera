# AlignAI Studio Architecture

## Runtime layers

### Engine layer

- `CameraService` exclusively owns the `AVCaptureSession`, capture inputs and outputs, and the serial camera-session queue. Direct `AVCaptureDevice` work must cross `scheduleDeviceConfiguration(after:operation:)`.
- `VisionFramingEngine` owns Vision requests and optical tracking on its dedicated queue. It publishes normalized, top-left-origin coordinates.
- `SpatialTrackingEngine` fuses optical observations with device motion and owns the tracking-quality state machine.
- `RealtimeHistogramEngine`, `FocusPeakingEngine`, and `FilmFilterEngine` are bounded image-processing components. They do not own UI state.
- `GeminiService` is an optional cloud adapter. The camera remains functional without a key or network connection.

### View-model layer

`CameraViewModel` is `@MainActor` and is the only object that composes engine output into screen state. The deployment target remains iOS 16, so it deliberately uses `ObservableObject`/`@Published`; Observation's `@Observable` would require raising the minimum OS to iOS 17.

The AI capture lifecycle is explicit:

```text
idle -> analyzing -> targetPlaced -> alignmentPerfect -> capturing -> done
```

Late cloud responses are rejected with a monotonically increasing session generation. Auto-capture and focus-dismiss work are cancellable tasks.

### UI layer

SwiftUI views render state and forward intent to the view model. AVFoundation preview rendering is isolated in `PreviewContainerView`. The visual system uses an amber accent, dark glass panels, compact rounded controls, and bottom-reachable pro controls.

## Queue and state ownership

| State/resource | Owner | Write context |
| --- | --- | --- |
| Capture session, active camera, outputs | `CameraService` | `sessionQueue` |
| Raw sample delivery | `CameraService` | `videoDataQueue` |
| Vision tracker state | `VisionFramingEngine` | `visionQueue` |
| Fused tracking state | `SpatialTrackingEngine` | Its motion/processing queue |
| SwiftUI-observed state | `CameraViewModel` and pro-control service | Main queue |
| Photo filtering | `FilmFilterEngine` | User-initiated background queue |
| API inspection fields | `GeminiService` | Main queue |

The live frame path always discards late frames. Histogram and focus-peaking work is throttled and bypassed while Settings is visible.

## Hardware-control invariants

- Zoom, ISO, reciprocal shutter speed, EV, white-balance gains, and lens position must be finite before reaching AVFoundation.
- A reciprocal shutter denominator is never allowed to reach zero.
- Every successful `lockForConfiguration()` has a scoped `defer` unlock in new hardware-control code.
- Slider bursts are coalesced with cancellable `DispatchWorkItem`s.
- Manual focus ranges from `0` (near) to `1` (infinity) and is only exposed when the device reports custom lens-position support.
- AI autofocus does not override manual focus in Pro Video. Tapping the preview explicitly returns to continuous autofocus.
- Only one photo request may own the Live Photo coordination state at a time.

## Professional-camera benchmark

The feature comparison used the vendors' published product material:

- [Halide](https://halide.cam/) emphasizes tactile manual focus, focus peaking, and a focus loupe.
- [Leica LUX](https://leica-camera.com/en-US/photography/leica-apps/leica-lux) exposes manual exposure, shutter speed, ISO, focus, and white balance alongside lens rendering and color looks.
- [Blackmagic Camera](https://www.blackmagicdesign.com/products/blackmagiccamera) combines manual controls with histogram, focus assist, levels, frame guides, zebra, and false-color monitoring.

AlignAI already provides RAW/HEIC/JPEG capture, live histogram, focus peaking, horizon leveling, manual exposure and white balance, film looks, and AI framing. The most important control gap was true manual lens focus; it is now integrated into the Pro Video drawer with near-to-infinity presets, a continuous slider, live lens readout, automatic peaking, and safe AF handoff.

Zebra/false-color monitoring, waveform scopes, ProRes/Log recording, audio meters, and media/timecode management remain possible future product directions, but they should be introduced only with device-capability checks and measured frame-budget impact.

## Build and release gate

The repository targets a generic iOS device with code signing disabled in GitHub Actions on macOS/Xcode. A change is releasable only after the `iOS Sideload Build & Release` workflow succeeds for the exact commit. The Windows development host cannot run `xcodebuild`; remote macOS CI is therefore the authoritative compiler and linker gate.
