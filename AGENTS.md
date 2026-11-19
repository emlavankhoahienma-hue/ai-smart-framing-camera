# AI Smart Framing Camera — Project Engineering & Design Rules

## 1. Visual Design System (Strict)
- Palette: Monochrome Matte Carbon (`AlignTheme.studioCanvas`, `studioSurface`, `studioElevated`) + real `.ultraThinMaterial` glass (`StudioGlassCapsule`, `StudioGlassRoundedSurface`) + **ONE single muted Warm Titanium accent (`AlignTheme.studioAccent`, `#D8C7A8`)**.
- Strictly FORBIDDEN: purple/blue/rainbow gradients, neon cyan (`Color(red: 56/255, green: 189/255, blue: 248/255)`), loud yellow accents, AI emojis, or cliché AI SF Symbols (`sparkles`, `wand.and.stars`, `sparkles.tv`). Use restrained optical photography SF Symbols instead.
- Do NOT modify `AISmartFramingCamera/Views/CapturedPhotoPreviewView.swift` (Photo Detail) unless explicitly requested by the user.
- Layout hygiene on 375–430pt iPhones:
  - Never put fixed-count wide `ForEach` `HStack`s inside floating sheets/drawers (causes horizontal overflow); use width-adaptive `Canvas` or bounded grids.
  - Give Vietnamese labels enough horizontal breathing room (zero mid-word wrapping like `HEI/F` and zero unwanted `...` truncation); use full-width segmented pill rows or single-line `Menu` value pills with `.fixedSize(horizontal: true, vertical: false)`.

## 2. Product Logic Invariants
- Default color on launch and normal capture is always natural camera color (`.standard`, film simulation OFF). Never persist forced default color presets across launches, and never let AI silently force a color filter unless AI Auto-Color is explicitly enabled.
- Do not duplicate toggles in `SettingsSheetView` that already live in the 6-dot quick control sheet (`CameraFunctionDrawerView`); keep Settings focused on deep configuration.
- Gate every camera control through a centralized capability/prerequisite check (`CameraFeatureGate`) so incompatible modes (e.g., Photo-only controls in Video, RAW vs Ultra Sharp/Live Photo/Master, Dual Cam vs Windowed Zoom/Horizon Lock/Flip) are clearly disabled and report the exact prerequisite when tapped.

## 3. Protected Boundaries & Mandatory Local Checks
- NEVER edit files or code slices protected by `tests/TrackingBoundary.json` (19 boundaries, including `CameraService.swift`) or `tests/PhotographicDetectionBoundary.json` (3 boundaries).
- Before EVERY commit/push, run all 4 verification scripts with Python 3.12:
  - `scripts/verify_tracking_boundary.py`
  - `scripts/check_responsive_layout.py`
  - `scripts/validate_windowed_zoom.py`
  - `scripts/run_regressions.py`
- Always register any new `.swift` / `.metal` / `.cpp` file cleanly in `AISmartFramingCamera.xcodeproj/project.pbxproj`.

## 4. iOS Simulator Visual Review Loop & Release CI
- For UI changes, iterate on a feature branch (e.g., `ui-polish`) and run `.github/workflows/ui-snapshot.yml` (`gh workflow run ui-snapshot.yml --ref <branch>`), download every rendered PNG artifact, and visually inspect ALL screenshots via `read_file` before merging to `main`.
- `ui-snapshot.yml` build rules:
  - Build with `-sdk iphonesimulator -arch arm64 -configuration Release` WITHOUT `-destination` (combining `-destination` + `-arch` fails with `xcodebuild` exit code 70; Debug fails on pre-existing `#if DEBUG` logging in `FocusPeakingMetalProcessor.swift`).
  - Always pre-warm the app launch once on a freshly booted simulator before capturing screenshots so the first PNG never catches the white launch screen.
- Only merge to `main` after visual verification passes, then watch `ios-build.yml` (`iOS Sideload Build & Release`) to confirm `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` passes and the unsigned IPA GitHub Release is published.
