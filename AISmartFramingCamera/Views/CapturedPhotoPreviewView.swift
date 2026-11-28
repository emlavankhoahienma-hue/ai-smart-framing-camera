import SwiftUI
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ImageIO
import Vision

// MARK: - Clean Minimalist Photo Detail & Non-Destructive Darkroom Studio
public struct CapturedPhotoPreviewView: View {
    public let item: CapturedPhotoItem
    public var viewModel: CameraViewModel?
    @Environment(\.dismiss) private var dismiss

    // Unified Non-Destructive Edit State & Undo/Redo Stack
    @State private var editState: PhotoDarkroomEditState
    @State private var historyStack = PhotoDarkroomHistoryStack(maxDepth: 40)
    @State private var activeAIColorParams: AIColorParameters? = nil

    // Darkroom Studio Navigation States (Studio Closed by Default so Photo Shines!)
    @State private var isEditDrawerOpen: Bool = false
    @State private var activeMainTab: PhotoDarkroomMainTab = .looks
    @State private var activeLooksSubTab: PhotoLooksSubTab = .films
    @State private var selectedEffect: PhotoEffectKind? = nil
    @State private var selectedTool: PhotoToolKind? = nil
    @State private var isTuningFilmIntensity: Bool = false
    @State private var selectedHSLChannel: PhotoHSLColorChannel = .red
    @State private var selectedCurveChannel: PhotoCurveChannel = .rgb

    // User Custom Recipes & Favorites (Persisted via PhotoDarkroomRecipeStore)
    @State private var customRecipes: [PhotoDarkroomRecipe] = []
    @State private var favoriteFilmRawValues: Set<String> = []
    @State private var favoriteRecipeIDs: Set<String> = []

    // Sheets & Inspector
    @State private var isShowingInfoSheet: Bool = false
    @State private var isShowingCatalogSheet: Bool = false
    @State private var isShowingSaveRecipeSheet: Bool = false
    @State private var histogramSnapshot: PhotoDarkroomHistogram = .empty

    // Render & Persistence Status
    @State private var isDevelopingPreview: Bool = false
    @State private var isSavingToLibrary: Bool = false
    @State private var hasSavedNewEnhancement: Bool = false
    @State private var isPreparingShare: Bool = false
    @State private var isShowingShareSheet: Bool = false
    @State private var cachedShareURL: URL? = nil

    // Dual-Resolution Caches (1440px Interactive Proxy + On-Demand Full-Res CGImage)
    @State private var currentFullResCGImage: CGImage
    @State private var fullResNeedsRefresh: Bool = false
    @State private var cachedFullResUIImage: UIImage
    @State private var cachedDisplayUIImage: UIImage
    @State private var cachedOriginalDisplayUIImage: UIImage
    @State private var cachedMiniMapUIImage: UIImage

    // Session Background Renderer (Coalesced Preview Queue + Bounded Lazy Thumbnail Cache)
    @State private var coordinator = PhotoDarkroomSessionCoordinator()

    // Comparison & Zoom States
    @State private var isSplitCompareMode: Bool = false
    @State private var splitRatio: CGFloat = 0.5
    @State private var isPeekingOriginal: Bool = false

    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var dismissDragOffsetY: CGFloat = 0.0

    // Still-Photo Long-Press QR Scanner States (Gallery & Post-Capture Viewer)
    @State private var photoQRCodes: [DetectedQRCode] = []
    @State private var activePhotoQR: DetectedQRCode? = nil
    @State private var hasScannedCurrentImageForQR: Bool = false
    @State private var isScanningPhotoQR: Bool = false
    @State private var qrPressTouchPoint: CGPoint? = nil
    @State private var isTrackingTouchDown: Bool = false
    @State private var lastTouchDownLocation: CGPoint? = nil
    @State private var photoQRDetailTarget: DetectedQRCode? = nil
    @State private var isShowingPhotoQRMultiList: Bool = false
    @State private var photoQRToastMessage: String? = nil
    @State private var photoQRScanTask: Task<Void, Never>? = nil
    @State private var photoQRToastTask: Task<Void, Never>? = nil

    public init(item: CapturedPhotoItem, viewModel: CameraViewModel? = nil) {
        self.item = item
        self.viewModel = viewModel
        _currentFullResCGImage = State(initialValue: item.processedImage)

        let initialDisplayUI: UIImage
        let initialOriginalUI: UIImage
        let initialMiniUI: UIImage
        if let preDisplay = item.predecodedDisplayImage {
            initialDisplayUI = preDisplay
            initialOriginalUI = item.predecodedOriginalDisplayImage ?? preDisplay
            initialMiniUI = item.predecodedMiniMapImage ?? preDisplay
        } else {
            let initSpan = CameraLogger.beginTrace(
                "PREVIEW_INIT_DOWNSAMPLE_FALLBACK",
                detail: "src=\(item.processedImage.width)x\(item.processedImage.height)",
                category: .capture
            )
            initialDisplayUI = Self.downsampleForFastDisplay(item.processedImage, maxSide: 1440)
            initialOriginalUI = (item.originalImage === item.processedImage)
                ? initialDisplayUI
                : Self.downsampleForFastDisplay(item.originalImage, maxSide: 1440)
            initialMiniUI = Self.downsampleForFastDisplay(item.processedImage, maxSide: 220)
            CameraLogger.endTrace(initSpan, detail: "disp=\(Int(initialDisplayUI.size.width))x\(Int(initialDisplayUI.size.height))")
        }
        _cachedFullResUIImage = State(initialValue: initialDisplayUI)
        _cachedDisplayUIImage = State(initialValue: initialDisplayUI)
        _cachedOriginalDisplayUIImage = State(initialValue: initialOriginalUI)
        _cachedMiniMapUIImage = State(initialValue: initialMiniUI)

        var initialEffects = PhotoEffectsState.neutral
        if let vm = viewModel {
            switch vm.masterWatermarkLogoStyle {
            case .alignStudio: initialEffects.frameLogo = .alignStudio
            case .aperturePro: initialEffects.frameLogo = .aperturePro
            case .none, .appleIcon, .customImage: initialEffects.frameLogo = .none
            }
        }
        _editState = State(initialValue: PhotoDarkroomEditState(
            presetRawValue: item.appliedPreset.rawValue,
            filmIntensity: 1.0,
            isAIEnhanced: false,
            effects: initialEffects,
            tools: .neutral
        ))
    }

    private var hasModifiedSinceOpen: Bool {
        editState.isModifiedComparedTo(initialPresetRaw: item.appliedPreset.rawValue)
    }

    private var isActivelyCropping: Bool {
        isEditDrawerOpen && activeMainTab == .tools && selectedTool == .crop && item.saveFormat != .dng
    }

    private var activeLookBadgeTitle: String {
        if let recipeName = editState.activeRecipeName, !recipeName.isEmpty {
            return recipeName
        }
        if let preset = FilmPreset(rawValue: editState.presetRawValue) {
            return preset == .standard ? "GỐC" : preset.cameraDisplayTag
        }
        return "GỐC"
    }

    private var renderMetadata: PhotoDarkroomRenderMetadata {
        PhotoDarkroomRenderMetadata(
            timestamp: item.timestamp,
            iso: item.iso,
            shutterSpeed: item.shutterSpeed,
            focalLengthMM: focalLengthMillimeters,
            aperture: 1.8,
            deviceName: viewModel?.masterWatermarkDeviceName ?? "ALIGN STUDIO OPTICAL"
        )
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                AlignTheme.studioCanvas.ignoresSafeArea()

                VStack(spacing: 0) {
                    if isEditDrawerOpen && item.saveFormat != .dng {
                        darkroomEditHeaderBar
                    } else {
                        cleanTopHeaderBar
                    }

                    heroPhotoViewport
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isEditDrawerOpen && item.saveFormat != .dng {
                        PhotoDarkroomStudioDeckView(
                            editState: $editState,
                            activeMainTab: $activeMainTab,
                            activeLooksSubTab: $activeLooksSubTab,
                            selectedEffect: $selectedEffect,
                            selectedTool: $selectedTool,
                            isTuningFilmIntensity: $isTuningFilmIntensity,
                            selectedHSLChannel: $selectedHSLChannel,
                            selectedCurveChannel: $selectedCurveChannel,
                            originalImage: item.originalImage,
                            currentImageSize: cachedDisplayUIImage.size,
                            coordinator: coordinator,
                            histogram: histogramSnapshot,
                            customRecipes: customRecipes,
                            favoriteFilmRawValues: favoriteFilmRawValues,
                            favoriteRecipeIDs: favoriteRecipeIDs,
                            onLiveChange: {
                                hasSavedNewEnhancement = false
                                fullResNeedsRefresh = true
                                cachedShareURL = nil
                                schedulePreviewRender()
                            },
                            onCommitChange: { previousState in
                                historyStack.pushUndoSnapshot(previousState, newState: editState)
                            },
                            onOpenCatalogSheet: {
                                isShowingCatalogSheet = true
                            },
                            onOpenNewRecipeSheet: {
                                isShowingSaveRecipeSheet = true
                            },
                            onToggleFavoriteFilm: { raw in
                                favoriteFilmRawValues = PhotoDarkroomRecipeStore.shared.toggleFavoriteFilm(raw)
                            },
                            onToggleFavoriteRecipe: { id in
                                favoriteRecipeIDs = PhotoDarkroomRecipeStore.shared.toggleFavoriteRecipe(id)
                            },
                            onDeleteCustomRecipe: { id in
                                customRecipes = PhotoDarkroomRecipeStore.shared.deleteCustomRecipe(id: id)
                                favoriteRecipeIDs = PhotoDarkroomRecipeStore.shared.loadFavoriteRecipeIDs()
                            },
                            onToggleAIEnhance: {
                                toggleAIFullColorEnhancement()
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        calmBottomActionBar
                            .transition(.opacity)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .interactiveDismissDisabled(zoomScale > 1.02 || isSplitCompareMode || isEditDrawerOpen)
            .sheet(isPresented: $isShowingInfoSheet) {
                photoInfoInspectorSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isShowingCatalogSheet) {
                PhotoDarkroomCatalogSheetView(
                    initialSubTab: activeLooksSubTab,
                    currentEditState: editState,
                    originalImage: item.originalImage,
                    coordinator: coordinator,
                    customRecipes: customRecipes,
                    favoriteFilmRawValues: favoriteFilmRawValues,
                    favoriteRecipeIDs: favoriteRecipeIDs,
                    onSelectFilm: { preset in
                        let before = editState
                        editState.presetRawValue = preset.rawValue
                        editState.filmIntensity = 1.0
                        editState.activeRecipeID = nil
                        editState.activeRecipeName = nil
                        historyStack.pushUndoSnapshot(before, newState: editState)
                        hasSavedNewEnhancement = false
                        fullResNeedsRefresh = true
                        cachedShareURL = nil
                        schedulePreviewRender()
                    },
                    onSelectRecipe: { recipe in
                        let before = editState
                        editState = recipe.apply(preservingCropFrom: editState)
                        historyStack.pushUndoSnapshot(before, newState: editState)
                        hasSavedNewEnhancement = false
                        fullResNeedsRefresh = true
                        cachedShareURL = nil
                        schedulePreviewRender()
                    },
                    onToggleFavoriteFilm: { raw in
                        favoriteFilmRawValues = PhotoDarkroomRecipeStore.shared.toggleFavoriteFilm(raw)
                    },
                    onToggleFavoriteRecipe: { id in
                        favoriteRecipeIDs = PhotoDarkroomRecipeStore.shared.toggleFavoriteRecipe(id)
                    }
                )
            }
            .sheet(isPresented: $isShowingSaveRecipeSheet) {
                PhotoSaveRecipeSheetView(activePresetName: activeLookBadgeTitle) { name in
                    let newRecipe = PhotoDarkroomRecipe(
                        id: "custom.\(UUID().uuidString)",
                        name: name.uppercased(),
                        isBuiltIn: false,
                        presetRawValue: editState.presetRawValue,
                        filmIntensity: editState.filmIntensity,
                        effects: editState.effects,
                        tools: editState.tools
                    )
                    customRecipes = PhotoDarkroomRecipeStore.shared.saveCustomRecipe(newRecipe)
                    editState.activeRecipeID = newRecipe.id
                    editState.activeRecipeName = newRecipe.name
                    activeMainTab = .looks
                    activeLooksSubTab = .mine
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isShowingShareSheet) {
                if let url = cachedShareURL {
                    CapturedPhotoActivityShareSheet(items: [url])
                }
            }
            .sheet(item: $photoQRDetailTarget) { qr in
                QRCodeDetailSheetView(
                    qrCode: qr,
                    onCopy: { copyStillPhotoQR(qr) },
                    onCopyCustom: { text, notice in copyCustomStillPhotoQRText(text, notice: notice) },
                    onOpenURL: { url in UIApplication.shared.open(url) }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isShowingPhotoQRMultiList) {
                QRCodeMultiListSheetView(
                    codes: photoQRCodes,
                    activeRawValue: activePhotoQR?.rawValue,
                    onSelectFocus: { qr in selectStillPhotoQR(qr) },
                    onCopy: { qr in copyStillPhotoQR(qr) },
                    onCopyCustom: { text, notice in copyCustomStillPhotoQRText(text, notice: notice) },
                    onOpenURL: { url in UIApplication.shared.open(url) }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .onAppear {
                CameraLogger.lifecycle("VIEW_APPEAR", detail: "CapturedPhotoPreviewView \(item.processedImage.width)x\(item.processedImage.height)", category: .photoKit)
                loadRecipeStoreState()
                let safeOriginalPredecode: UIImage? = item.predecodedOriginalDisplayImage
                    ?? (item.originalImage === item.processedImage ? item.predecodedDisplayImage : nil)
                coordinator.prepareProxies(
                    from: item.originalImage,
                    predecodedDisplay: safeOriginalPredecode
                ) {
                    refreshHistogramAsync(for: currentFullResCGImage)
                }
            }
            .onDisappear {
                CameraLogger.lifecycle("VIEW_DISAPPEAR", detail: "CapturedPhotoPreviewView", category: .photoKit)
                photoQRScanTask?.cancel()
                photoQRToastTask?.cancel()
                coordinator.teardown()
            }
            .onChangeCompatible(of: isEditDrawerOpen) { editing in
                if editing {
                    clearStillPhotoQROverlay(resetScanCache: false)
                }
            }
            .onChangeCompatible(of: zoomScale > 2.2) { needsFullRes in
                if needsFullRes {
                    if fullResNeedsRefresh {
                        refreshFullResForDeepZoom()
                    } else {
                        cachedFullResUIImage = UIImage(cgImage: currentFullResCGImage)
                    }
                } else {
                    cachedFullResUIImage = cachedDisplayUIImage
                }
            }
            .onChangeCompatible(of: isActivelyCropping) { cropping in
                if cropping {
                    resetZoomAndPan()
                    isSplitCompareMode = false
                }
                if hasModifiedSinceOpen || !editState.tools.crop.isIdentity {
                    schedulePreviewRender()
                }
            }
        }
    }

    // MARK: - 1A. Clean Calm View Header Bar (Default When Studio Is Collapsed)
    private var cleanTopHeaderBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.90))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Đóng")

            Spacer()

            VStack(spacing: 2) {
                Text("\(formatBadgeTitle) · \(megapixelsString)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                Text(opticalSummaryLine)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }

            Spacer()

            Button(action: { isShowingInfoSheet = true }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.90))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thông số ảnh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 1B. Darkroom Edit Mode Header Bar (Close · Live Histogram · Undo/Redo · More · Xong)
    private var darkroomEditHeaderBar: some View {
        HStack(spacing: 10) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.90))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Đóng xem ảnh")

            // Live Mini Luminance Histogram (Tap for full RGB & EXIF Inspector)
            Button(action: { isShowingInfoSheet = true }) {
                PhotoDarkroomMiniHistogramView(histogram: histogramSnapshot)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(AlignTheme.studioElevated)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(AlignTheme.studioHairlineSubtle, lineWidth: 0.6)
                            )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Biểu đồ sáng và thông số ảnh")

            Spacer(minLength: 4)

            // Undo & Redo Controls
            HStack(spacing: 6) {
                Button(action: { performUndo() }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(historyStack.canUndo ? .white : .white.opacity(0.26))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(historyStack.canUndo ? 0.09 : 0.03)))
                }
                .buttonStyle(.plain)
                .disabled(!historyStack.canUndo)
                .accessibilityLabel("Hoàn tác")

                Button(action: { performRedo() }) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(historyStack.canRedo ? .white : .white.opacity(0.26))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(historyStack.canRedo ? 0.09 : 0.03)))
                }
                .buttonStyle(.plain)
                .disabled(!historyStack.canRedo)
                .accessibilityLabel("Làm lại")
            }

            Spacer(minLength: 4)

            // More Actions Menu (...)
            Menu {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        resetZoomAndPan()
                        if isActivelyCropping { selectedTool = nil }
                        isSplitCompareMode.toggle()
                    }
                }) {
                    Label(isSplitCompareMode ? "Tắt so sánh chia đôi" : "So sánh gốc chia đôi", systemImage: "square.split.2x1")
                }

                Button(action: { isShowingInfoSheet = true }) {
                    Label("Thông số & Biểu đồ RGB", systemImage: "info.circle")
                }

                Button(action: { isShowingSaveRecipeSheet = true }) {
                    Label("Lưu thành Công thức mới", systemImage: "plus.square.on.square")
                }

                Button(action: { toggleAIFullColorEnhancement() }) {
                    Label(editState.isAIEnhanced ? "Tắt AI Cân Màu" : "Bật AI Cân Màu", systemImage: "wand.and.stars")
                }

                if hasModifiedSinceOpen {
                    Divider()
                    Button(role: .destructive, action: { resetToOriginalPhoto() }) {
                        Label("Đặt lại toàn bộ ảnh gốc", systemImage: "arrow.counterclockwise")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.88))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }

            // Done / Finish Editing Pill (Warm Titanium Accent)
            Button(action: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    isEditDrawerOpen = false
                    selectedEffect = nil
                    selectedTool = nil
                    isTuningFilmIntensity = false
                    isSplitCompareMode = false
                }
            }) {
                Text("Xong")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7.5)
                    .background(Capsule().fill(AlignTheme.studioAccent))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - 2. Unobstructed Hero Photo Viewport
    private var heroPhotoViewport: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear

                if isActivelyCropping {
                    ZStack {
                        Image(uiImage: cachedDisplayUIImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(14)
                            .frame(width: geo.size.width, height: geo.size.height)

                        PhotoInteractiveCropOverlayView(
                            cropState: $editState.tools.crop,
                            imageSize: cachedDisplayUIImage.size,
                            viewportSize: geo.size,
                            onCommit: { previousCrop in
                                var previousEdit = editState
                                previousEdit.tools.crop = previousCrop
                                historyStack.pushUndoSnapshot(previousEdit, newState: editState)
                                hasSavedNewEnhancement = false
                                fullResNeedsRefresh = true
                                cachedShareURL = nil
                            }
                        )
                    }
                } else if isSplitCompareMode && zoomScale <= 1.05 && item.saveFormat != .dng {
                    splitScreenComparisonCanvas(in: geo.size)
                } else {
                    zoomableHeroCanvas(in: geo.size)
                }

                // Subtle Developing / Processing Indicator Pill at Top
                if isDevelopingPreview {
                    VStack {
                        HStack(spacing: 7) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.75)
                            Text("ĐANG XỬ LÝ...")
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .tracking(0.6)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(StudioGlassCapsule(tintOpacity: 0.68, borderOpacity: 0.16))
                        .padding(.top, 12)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // Peeking Original Indicator
                if isPeekingOriginal {
                    VStack {
                        Text("ẢNH GỐC")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4.5)
                            .background(Capsule().fill(Color.white.opacity(0.92)))
                            .padding(.top, 12)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // Bottom-Left Floating Active Look Pill (Hidden when QR Floating Pill is active so zero overlap)
                if item.saveFormat != .dng && zoomScale <= 1.05 && !isPeekingOriginal && !isActivelyCropping && !isSplitCompareMode && activePhotoQR == nil && photoQRToastMessage == nil {
                    VStack {
                        Spacer()
                        HStack {
                            PhotoDarkroomLookBadgePill(title: activeLookBadgeTitle) {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                    if !isEditDrawerOpen {
                                        isEditDrawerOpen = true
                                        activeMainTab = .looks
                                        activeLooksSubTab = (editState.activeRecipeID != nil) ? .recipes : .films
                                    } else {
                                        activeMainTab = .looks
                                        if editState.presetRawValue != FilmPreset.standard.rawValue {
                                            isTuningFilmIntensity.toggle()
                                        }
                                    }
                                }
                            }
                            .padding(.leading, 14)
                            .padding(.bottom, 12)

                            Spacer()
                        }
                    }
                    .transition(.opacity)
                }

                // Touch-Point Optical Scan Pulse while decoding long-pressed QR region
                if isScanningPhotoQR, let pressPt = qrPressTouchPoint {
                    StillPhotoQRTouchPulseView()
                        .position(pressPt)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // Bottom Floating Studio QR Pill + Copy/Feedback Toast inside Photo Viewer
                if !isEditDrawerOpen && !isActivelyCropping && !isSplitCompareMode {
                    VStack(spacing: 8) {
                        Spacer()

                        if let toast = photoQRToastMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "qrcode.viewfinder")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(AlignTheme.studioAccent)
                                Text(toast)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(AlignTheme.studioInkPrimary)
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(StudioGlassCapsule(tintOpacity: 0.80, borderOpacity: 0.18))
                            .shadow(color: Color.black.opacity(0.42), radius: 10, y: 4)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        if let qr = activePhotoQR {
                            let activeIdx = photoQRCodes.firstIndex(where: { $0.rawValue == qr.rawValue }) ?? 0
                            QRCodeFloatingBannerPill(
                                qrCode: qr,
                                totalCount: photoQRCodes.count,
                                activeIndex: activeIdx,
                                maxWidth: min(geo.size.width - 24, 344),
                                onPrimaryTap: { openStillPhotoQRPrimaryAction(qr) },
                                onShowAllTap: {
                                    viewModel?.haptics.triggerSelectionChange()
                                    isShowingPhotoQRMultiList = true
                                },
                                onCopyTap: { copyStillPhotoQR(qr) },
                                onDismissTap: {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        activePhotoQR = nil
                                    }
                                }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.bottom, 12)
                    .animation(.spring(response: 0.28, dampingFraction: 0.84), value: activePhotoQR?.rawValue)
                    .animation(.easeInOut(duration: 0.20), value: photoQRToastMessage)
                }

                // Zoom Region Mini-Map + Reset Pill When Zoomed In
                if zoomScale > 1.05 && !isActivelyCropping {
                    VStack {
                        HStack(alignment: .top) {
                            zoomRegionMiniMap(viewportSize: geo.size)
                                .padding(.top, 12)
                                .padding(.leading, 14)

                            Spacer()

                            Button(action: {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                                    resetZoomAndPan()
                                }
                            }) {
                                Text(String(format: "%.1fx · Đặt lại", zoomScale))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.black.opacity(0.72)))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 12)
                            .padding(.trailing, 14)
                        }
                        Spacer()
                    }
                    .transition(.opacity)
                }
            }
            .clipped()
        }
    }

    @ViewBuilder
    private func zoomableHeroCanvas(in size: CGSize) -> some View {
        let isZoomedIn = zoomScale > 1.02
        let activeUIImage: UIImage = isPeekingOriginal
            ? cachedOriginalDisplayUIImage
            : (zoomScale > 2.3 ? cachedFullResUIImage : cachedDisplayUIImage)
        let fittedRect = StillPhotoQRGeometry.fittedImageRect(imageSize: activeUIImage.size, in: size)

        ZStack {
            Color.clear

            ZStack {
                Image(uiImage: activeUIImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)

                // Pixel-locked QR Animated Running Border + Secondary Tappable QR Brackets (Scales & Pans 1:1 with Photo)
                if !isEditDrawerOpen && !isPeekingOriginal && fittedRect.width > 1 && fittedRect.height > 1 {
                    if let activeQR = activePhotoQR, !activeQR.normalizedBoundingBox.isEmpty {
                        let qrRect = CGRect(
                            x: fittedRect.minX + activeQR.normalizedBoundingBox.minX * fittedRect.width,
                            y: fittedRect.minY + activeQR.normalizedBoundingBox.minY * fittedRect.height,
                            width: activeQR.normalizedBoundingBox.width * fittedRect.width,
                            height: activeQR.normalizedBoundingBox.height * fittedRect.height
                        )
                        StillPhotoQRAnimatedFrameView(
                            rect: qrRect,
                            zoomScale: zoomScale
                        )
                        .id(activeQR.rawValue)
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 1.08).combined(with: .opacity))
                    }

                    if photoQRCodes.count > 1 && activePhotoQR != nil {
                        ForEach(photoQRCodes) { qr in
                            if qr.rawValue != activePhotoQR?.rawValue, !qr.normalizedBoundingBox.isEmpty {
                                let secRect = CGRect(
                                    x: fittedRect.minX + qr.normalizedBoundingBox.minX * fittedRect.width,
                                    y: fittedRect.minY + qr.normalizedBoundingBox.minY * fittedRect.height,
                                    width: qr.normalizedBoundingBox.width * fittedRect.width,
                                    height: qr.normalizedBoundingBox.height * fittedRect.height
                                )
                                let w = max(28, secRect.width + 8)
                                let h = max(28, secRect.height + 8)
                                CornerBracketsShape(bracketLength: min(14, min(w, h) * 0.28))
                                    .stroke(
                                        Color.white.opacity(0.72),
                                        style: StrokeStyle(lineWidth: max(1.1, 1.6 / sqrt(zoomScale)), lineCap: .round, lineJoin: .round)
                                    )
                                    .frame(width: w, height: h)
                                    .position(x: secRect.midX, y: secRect.midY)
                                    .shadow(color: Color.black.opacity(0.45), radius: 2, y: 0.5)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectStillPhotoQR(qr)
                                    }
                            }
                        }
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .scaleEffect(zoomScale)
            .offset(
                x: panOffset.width,
                y: isZoomedIn ? panOffset.height : dismissDragOffsetY
            )
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "capturedPhotoHeroSpace")
        .contentShape(Rectangle())
        .gesture(
            MagnificationGesture()
                .onChanged { val in
                    let nextScale = min(max(lastZoomScale * val, 1.0), 8.0)
                    zoomScale = nextScale
                    dismissDragOffsetY = 0
                    if nextScale <= 1.02 {
                        panOffset = .zero
                    } else {
                        let scaleRatio = nextScale / max(1.0, lastZoomScale)
                        let scaledPan = CGSize(
                            width: lastPanOffset.width * scaleRatio,
                            height: lastPanOffset.height * scaleRatio
                        )
                        panOffset = clampPanOffset(scaledPan, in: size, scale: nextScale)
                    }
                }
                .onEnded { _ in
                    if zoomScale < 1.05 {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                            resetZoomAndPan()
                        }
                    } else {
                        lastZoomScale = zoomScale
                        panOffset = clampPanOffset(panOffset, in: size, scale: zoomScale)
                        lastPanOffset = panOffset
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("capturedPhotoHeroSpace"))
                .onChanged { val in
                    if !isTrackingTouchDown {
                        isTrackingTouchDown = true
                        lastTouchDownLocation = val.startLocation
                    }
                }
                .onEnded { _ in
                    isTrackingTouchDown = false
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("capturedPhotoHeroSpace"))
                .onChanged { val in
                    if zoomScale > 1.02 {
                        dismissDragOffsetY = 0
                        let raw = CGSize(
                            width: lastPanOffset.width + val.translation.width,
                            height: lastPanOffset.height + val.translation.height
                        )
                        panOffset = clampPanOffset(raw, in: size, scale: zoomScale)
                    } else if !isEditDrawerOpen && val.translation.height > 12 && abs(val.translation.height) > abs(val.translation.width) * 1.35 {
                        dismissDragOffsetY = max(0, val.translation.height * 0.72)
                    }
                }
                .onEnded { val in
                    if zoomScale > 1.02 {
                        lastPanOffset = panOffset
                    } else if dismissDragOffsetY > 0 {
                        if val.translation.height > 110 || val.predictedEndTranslation.height > 190 {
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                                dismissDragOffsetY = 0
                            }
                        }
                    }
                }
        )
        .highPriorityGesture(
            SpatialTapGesture(count: 2)
                .onEnded { event in
                    dismissDragOffsetY = 0
                    handleDoubleTap(at: event.location, in: size)
                }
        )
        .onLongPressGesture(minimumDuration: 0.30, maximumDistance: 16, pressing: { pressing in
            if isEditDrawerOpen {
                guard item.saveFormat != .dng, zoomScale <= 1.05 else { return }
                withAnimation(.easeInOut(duration: 0.14)) {
                    isPeekingOriginal = pressing
                }
            } else if !pressing && isPeekingOriginal {
                withAnimation(.easeInOut(duration: 0.14)) {
                    isPeekingOriginal = false
                }
            }
        }, perform: {
            if !isEditDrawerOpen {
                let touchPoint = lastTouchDownLocation ?? CGPoint(x: size.width * 0.5, y: size.height * 0.5)
                handleLongPressQRScan(at: touchPoint, in: size, displayedImage: activeUIImage)
            }
        })
    }

    @ViewBuilder
    private func splitScreenComparisonCanvas(in size: CGSize) -> some View {
        let splitX = size.width * splitRatio
        ZStack {
            Image(uiImage: cachedDisplayUIImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)

            Image(uiImage: cachedOriginalDisplayUIImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .mask(
                    HStack(spacing: 0) {
                        Rectangle().frame(width: splitX)
                        Spacer(minLength: 0)
                    }
                )

            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 1.8, height: size.height)

                Circle()
                    .fill(Color.black.opacity(0.82))
                    .frame(width: 34, height: 34)
                    .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.2))
                    .overlay(
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    )
            }
            .position(x: splitX, y: size.height / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        splitRatio = min(max(value.location.x / max(1, size.width), 0.06), 0.94)
                    }
            )
        }
    }

    // MARK: - 3. Calm Bottom Action Bar (Default View Mode)
    private var calmBottomActionBar: some View {
        HStack(spacing: 12) {
            if item.saveFormat != .dng {
                Button(action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        resetZoomAndPan()
                        isEditDrawerOpen = true
                    }
                }) {
                    VStack(spacing: 3) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 17, weight: .medium))
                        Text("Chỉnh ảnh")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(hasModifiedSinceOpen ? AlignTheme.studioAccent : .white.opacity(0.88))
                    .frame(width: 70, height: 44)
                }
                .buttonStyle(.plain)
            }

            // Primary Save Pill
            Button(action: { saveCurrentVersionToPhotos() }) {
                HStack(spacing: 6) {
                    if isSavingToLibrary {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: hasSavedNewEnhancement ? "checkmark" : "square.and.arrow.down")
                            .font(.system(size: 13.5, weight: .bold))
                    }
                    Text(hasSavedNewEnhancement ? "Đã lưu" : (item.saveFormat == .dng ? "Lưu RAW" : "Lưu ảnh"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .foregroundColor(hasSavedNewEnhancement ? .white : .black)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    Capsule()
                        .fill(hasSavedNewEnhancement ? AlignTheme.studioPositive : Color.white)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSavingToLibrary || isDevelopingPreview)

            // Share Control (Preserving OriginalDNGShare contract; non-DNG encodes lazily off main thread)
            if item.saveFormat == .dng {
                if let url = item.rawLocalFileURL, FileManager.default.fileExists(atPath: url.path) {
                    ShareLink(item: url) { shareIconLabel }
                } else if let data = item.rawPhotoData, SuperResolutionRAWEngine.isDNGData(data) {
                    ShareLink(item: OriginalDNGShare(data: data),
                              preview: SharePreview("AlignAI True RAW DNG")) {
                        shareIconLabel
                    }
                }
            } else {
                Button(action: { prepareAndPresentShareSheet() }) {
                    if isPreparingShare {
                        VStack(spacing: 3) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.75)
                            Text("Chuẩn bị...")
                                .font(.system(size: 10.0, weight: .medium, design: .rounded))
                        }
                        .foregroundColor(.white.opacity(0.80))
                        .frame(width: 70, height: 44)
                    } else {
                        shareIconLabel
                    }
                }
                .buttonStyle(.plain)
                .disabled(isPreparingShare || isDevelopingPreview)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(AlignTheme.studioCanvas)
    }

    private var shareIconLabel: some View {
        VStack(spacing: 3) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 17, weight: .medium))
            Text("Chia sẻ")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
        }
        .foregroundColor(.white.opacity(0.88))
        .frame(width: 70, height: 44)
    }

    // MARK: - 4. EXIF & RGB Histogram Info Sheet
    private var photoInfoInspectorSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("BIỂU ĐỒ QUANG PHỔ RGB")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.6))
                            Spacer()
                            Text("Sáng TB \(Int(round(histogramSnapshot.meanLuminance * 100)))%")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.75))
                        }

                        PhotoDetailHistogramCanvasView(snapshot: histogramSnapshot)
                            .frame(height: 82)

                        HStack {
                            Text("Vùng tối sâu: \(String(format: "%.1f%%", histogramSnapshot.shadowClipPercent))")
                            Spacer()
                            Text("Cháy sáng: \(String(format: "%.1f%%", histogramSnapshot.highlightClipPercent))")
                                .foregroundColor(histogramSnapshot.highlightClipPercent > 3.5 ? AlignTheme.amberGold : .white.opacity(0.55))
                        }
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55))
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AlignTheme.studioSurface)
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("THÔNG SỐ QUANG HỌC")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            infoStatCell(label: "Độ phân giải", value: "\(currentFullResCGImage.width) × \(currentFullResCGImage.height) (\(megapixelsString))")
                            infoStatCell(label: "Định dạng & Dung lượng", value: "\(formatBadgeTitle) · \(estimatedFileSizeString)")
                            infoStatCell(label: "Tiêu cự & Khẩu độ", value: "\(focalLengthDisplayString) · f/1.8")
                            infoStatCell(label: "Phơi sáng", value: "\(formattedShutterSpeed) · ISO \(Int(round(max(25, item.iso))))")
                            infoStatCell(label: "Bối cảnh AI", value: item.sceneType.rawValue)
                            infoStatCell(label: "Bố cục & Điểm", value: "\(item.compositionRule.rawValue) (\(Int(round(item.alignmentScore * 100)))%)")
                        }
                    }
                }
                .padding(18)
            }
            .background(AlignTheme.studioCanvas.ignoresSafeArea())
            .navigationTitle("Thông số ảnh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xong") { isShowingInfoSheet = false }
                        .foregroundColor(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func infoStatCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.52))
            Text(value)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(AlignTheme.studioSurface)
        )
    }

    // MARK: - 5. Zero-Lag Coalesced Preview & Full-Res Rendering Pipeline
    private func loadRecipeStoreState() {
        customRecipes = PhotoDarkroomRecipeStore.shared.loadCustomRecipes()
        favoriteFilmRawValues = PhotoDarkroomRecipeStore.shared.loadFavoriteFilmRawValues()
        favoriteRecipeIDs = PhotoDarkroomRecipeStore.shared.loadFavoriteRecipeIDs()
    }

    private func schedulePreviewRender() {
        clearStillPhotoQROverlay(resetScanCache: true)
        var previewState = editState
        // While interactively dragging crop handles, show full oriented frame (rotation/flip/straighten active, rect uncropped)
        if isActivelyCropping {
            previewState.tools.crop.normalizedRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let aiParams = editState.isAIEnhanced ? (activeAIColorParams ?? item.sceneType.aiFullColorParameters) : nil
        let meta = renderMetadata
        let customLogo = viewModel?.masterWatermarkCustomLogoImage

        coordinator.scheduleInteractivePreview(
            fallbackOriginal: item.originalImage,
            state: previewState,
            metadata: meta,
            aiColorParams: aiParams,
            customWatermarkLogo: customLogo,
            applyCropGeometry: true
        ) { displayUI, miniUI, hist in
            self.cachedDisplayUIImage = displayUI
            self.cachedMiniMapUIImage = miniUI
            self.histogramSnapshot = hist
            if self.zoomScale <= 2.2 {
                self.cachedFullResUIImage = displayUI
            }
        }
    }

    private func refreshFullResForDeepZoom() {
        isDevelopingPreview = true
        let aiParams = editState.isAIEnhanced ? (activeAIColorParams ?? item.sceneType.aiFullColorParameters) : nil
        coordinator.renderFullResolutionAsync(
            original: item.originalImage,
            state: editState,
            metadata: renderMetadata,
            aiColorParams: aiParams,
            customWatermarkLogo: viewModel?.masterWatermarkCustomLogoImage
        ) { fullCG in
            self.currentFullResCGImage = fullCG
            self.fullResNeedsRefresh = false
            self.cachedFullResUIImage = UIImage(cgImage: fullCG)
            self.isDevelopingPreview = false
        }
    }

    private func ensureFullResolutionReady(completion: @escaping (CGImage) -> Void) {
        if !hasModifiedSinceOpen && !fullResNeedsRefresh {
            completion(item.processedImage)
            return
        }
        if !fullResNeedsRefresh {
            completion(currentFullResCGImage)
            return
        }
        isDevelopingPreview = true
        let aiParams = editState.isAIEnhanced ? (activeAIColorParams ?? item.sceneType.aiFullColorParameters) : nil
        coordinator.renderFullResolutionAsync(
            original: item.originalImage,
            state: editState,
            metadata: renderMetadata,
            aiColorParams: aiParams,
            customWatermarkLogo: viewModel?.masterWatermarkCustomLogoImage
        ) { fullCG in
            self.currentFullResCGImage = fullCG
            self.fullResNeedsRefresh = false
            self.isDevelopingPreview = false
            completion(fullCG)
        }
    }

    private func performUndo() {
        guard let prev = historyStack.undo(current: editState) else { return }
        editState = prev
        hasSavedNewEnhancement = false
        fullResNeedsRefresh = true
        cachedShareURL = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        schedulePreviewRender()
    }

    private func performRedo() {
        guard let next = historyStack.redo(current: editState) else { return }
        editState = next
        hasSavedNewEnhancement = false
        fullResNeedsRefresh = true
        cachedShareURL = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        schedulePreviewRender()
    }

    private func toggleAIFullColorEnhancement() {
        let before = editState
        editState.isAIEnhanced.toggle()
        if editState.isAIEnhanced {
            activeAIColorParams = item.sceneType.aiFullColorParameters
            if editState.presetRawValue == FilmPreset.standard.rawValue {
                editState.presetRawValue = item.sceneType.recommendedFilter.rawValue
            }
        } else {
            activeAIColorParams = nil
        }
        historyStack.pushUndoSnapshot(before, newState: editState)
        hasSavedNewEnhancement = false
        fullResNeedsRefresh = true
        cachedShareURL = nil
        schedulePreviewRender()
    }

    private func resetToOriginalPhoto() {
        let before = editState
        editState = PhotoDarkroomEditState(
            presetRawValue: FilmPreset.standard.rawValue,
            filmIntensity: 1.0,
            isAIEnhanced: false,
            effects: .neutral,
            tools: .neutral
        )
        activeAIColorParams = nil
        historyStack.pushUndoSnapshot(before, newState: editState)
        isPeekingOriginal = false
        isSplitCompareMode = false
        currentFullResCGImage = item.originalImage
        fullResNeedsRefresh = false
        cachedDisplayUIImage = cachedOriginalDisplayUIImage
        cachedFullResUIImage = cachedOriginalDisplayUIImage
        cachedShareURL = nil
        hasSavedNewEnhancement = false
        refreshHistogramAsync(for: item.originalImage)
    }

    private func refreshHistogramAsync(for image: CGImage) {
        DispatchQueue.global(qos: .utility).async {
            let snap = PhotoDarkroomHistogram.compute(from: image)
            DispatchQueue.main.async {
                self.histogramSnapshot = snap
            }
        }
    }

    private static func downsampleForFastDisplay(_ cgImage: CGImage, maxSide: CGFloat) -> UIImage {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let longest = max(w, h)
        guard longest > maxSide, w > 0, h > 0 else {
            let ui = UIImage(cgImage: cgImage)
            return ui.preparingForDisplay() ?? ui
        }
        let scale = maxSide / longest
        let targetSize = CGSize(width: round(w * scale), height: round(h * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let downsampled = UIGraphicsImageRenderer(size: targetSize, format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .high
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return downsampled.preparingForDisplay() ?? downsampled
    }

    // MARK: - 6. Share & Save Operations (Full-Res Background Export)
    private func prepareAndPresentShareSheet() {
        if let existing = cachedShareURL, FileManager.default.fileExists(atPath: existing.path) {
            isShowingShareSheet = true
            return
        }
        isPreparingShare = true
        ensureFullResolutionReady { fullCG in
            let format = self.item.saveFormat
            let itemID = self.item.id
            let preserveOrig = self.item.preservesOriginalFile && !self.hasModifiedSinceOpen && (fullCG === self.item.processedImage)
            let rawData = preserveOrig ? self.item.rawPhotoData : nil

            DispatchQueue.global(qos: .userInitiated).async {
                let url = Self.writeShareFileOnBackground(
                    cgImage: fullCG,
                    saveFormat: format,
                    itemID: itemID,
                    rawPhotoData: rawData
                )
                DispatchQueue.main.async {
                    self.isPreparingShare = false
                    if let url {
                        self.cachedShareURL = url
                        self.isShowingShareSheet = true
                    }
                }
            }
        }
    }

    private static func writeShareFileOnBackground(
        cgImage: CGImage,
        saveFormat: PhotoSaveFormat,
        itemID: UUID,
        rawPhotoData: Data?
    ) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        if let data = rawPhotoData {
            let ext = saveFormat == .jpeg ? "jpg" : "heic"
            let url = tempDir.appendingPathComponent("AlignAI_Original_\(itemID.uuidString).\(ext)")
            if (try? data.write(to: url, options: .atomic)) != nil {
                return url
            }
        }
        let isHEIC = saveFormat == .heif || saveFormat == .heic
        let ext = isHEIC ? "heic" : "jpg"
        let utType = isHEIC ? UTType.heic : UTType.jpeg
        let fileURL = tempDir.appendingPathComponent("AlignAI_Studio_\(itemID.uuidString).\(ext)")
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, utType.identifier as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        do {
            try (data as Data).write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    private func saveCurrentVersionToPhotos() {
        guard let vm = viewModel else { return }
        isSavingToLibrary = true

        ensureFullResolutionReady { fullCG in
            let preserveOriginal = !self.hasModifiedSinceOpen && self.item.preservesOriginalFile &&
                (fullCG === self.item.processedImage)
            let appliedPreset = FilmPreset(rawValue: self.editState.presetRawValue) ?? self.item.appliedPreset
            let updatedItem = CapturedPhotoItem(
                originalImage: self.item.originalImage,
                processedImage: fullCG,
                rawPhotoData: self.item.rawPhotoData,
                processedCompanionData: preserveOriginal ? self.item.processedCompanionData : nil,
                saveFormat: self.item.saveFormat,
                preservesOriginalFile: preserveOriginal,
                rawLocalFileURL: self.item.rawLocalFileURL,
                livePhotoMovieURL: self.item.livePhotoMovieURL,
                sceneType: self.item.sceneType,
                appliedPreset: appliedPreset,
                compositionRule: self.item.compositionRule,
                alignmentScore: self.item.alignmentScore,
                iso: self.item.iso,
                shutterSpeed: self.item.shutterSpeed,
                aiColorParameters: self.editState.isAIEnhanced ? (self.activeAIColorParams ?? self.item.sceneType.aiFullColorParameters) : self.item.aiColorParameters
            )

            vm.savePhotoToLibrary(updatedItem) { success in
                self.isSavingToLibrary = false
                self.hasSavedNewEnhancement = success
            }
        }
    }

    // MARK: - 7. Interactive Zoom Navigator Mini-Map
    @ViewBuilder
    private func zoomRegionMiniMap(viewportSize: CGSize) -> some View {
        let displaySize = isPeekingOriginal ? cachedOriginalDisplayUIImage.size : cachedDisplayUIImage.size
        let imgW = max(1, displaySize.width)
        let imgH = max(1, displaySize.height)
        let imgAspect = imgW / imgH
        let vpAspect = viewportSize.width / max(1.0, viewportSize.height)

        let baseW: CGFloat = (vpAspect > imgAspect) ? (viewportSize.height * imgAspect) : viewportSize.width
        let baseH: CGFloat = (vpAspect > imgAspect) ? viewportSize.height : (viewportSize.width / imgAspect)
        let renderedW = max(1.0, baseW * zoomScale)
        let renderedH = max(1.0, baseH * zoomScale)

        let miniW: CGFloat = imgAspect >= 1.0 ? 78 : 58
        let miniH: CGFloat = max(42, min(88, miniW / imgAspect))

        let visibleFracW = min(1.0, viewportSize.width / renderedW)
        let visibleFracH = min(1.0, viewportSize.height / renderedH)
        let indW = max(10.0, miniW * visibleFracW)
        let indH = max(10.0, miniH * visibleFracH)

        let maxShiftX = max(0.0, (miniW - indW) / 2.0)
        let maxShiftY = max(0.0, (miniH - indH) / 2.0)
        let rawIndOffsetX = -(panOffset.width / renderedW) * miniW
        let rawIndOffsetY = -(panOffset.height / renderedH) * miniH
        let indOffsetX = min(maxShiftX, max(-maxShiftX, rawIndOffsetX))
        let indOffsetY = min(maxShiftY, max(-maxShiftY, rawIndOffsetY))

        ZStack {
            Image(uiImage: cachedMiniMapUIImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: miniW, height: miniH)

            Color.black.opacity(0.40)
                .frame(width: miniW, height: miniH)

            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.white.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .stroke(AlignTheme.studioAccent, lineWidth: 1.5)
                )
                .frame(width: indW, height: indH)
                .offset(x: indOffsetX, y: indOffsetY)
                .shadow(color: Color.black.opacity(0.65), radius: 2)
        }
        .frame(width: miniW, height: miniH)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 0.9)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 8, y: 3)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let targetPan = CGSize(
                        width: -((value.location.x - miniW * 0.5) / miniW) * renderedW,
                        height: -((value.location.y - miniH * 0.5) / miniH) * renderedH
                    )
                    let clamped = clampPanOffset(targetPan, in: viewportSize, scale: zoomScale)
                    panOffset = clamped
                    lastPanOffset = clamped
                }
        )
        .accessibilityLabel("Bản đồ vùng đang phóng to \(String(format: "%.1f", zoomScale)) lần")
    }

    // MARK: - 8. Zoom & Pan Helpers
    private func resetZoomAndPan() {
        zoomScale = 1.0
        lastZoomScale = 1.0
        panOffset = .zero
        lastPanOffset = .zero
    }

    private func clampPanOffset(_ offset: CGSize, in size: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1.0 else { return .zero }
        let displaySize = isPeekingOriginal ? cachedOriginalDisplayUIImage.size : cachedDisplayUIImage.size
        let imgW = max(1, displaySize.width)
        let imgH = max(1, displaySize.height)
        let imgAspect = imgW / imgH
        let vpAspect = size.width / max(1.0, size.height)
        let baseW: CGFloat = (vpAspect > imgAspect) ? (size.height * imgAspect) : size.width
        let baseH: CGFloat = (vpAspect > imgAspect) ? size.height : (size.width / imgAspect)
        let maxX = max(0, (baseW * scale - size.width) / 2.0)
        let maxY = max(0, (baseH * scale - size.height) / 2.0)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    private func handleDoubleTap(at location: CGPoint, in size: CGSize) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
            if zoomScale > 1.3 {
                resetZoomAndPan()
                return
            }
            let nextScale: CGFloat = 2.8
            let center = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
            let targetOffset = CGSize(
                width: (center.x - location.x) * (nextScale - 1.0),
                height: (center.y - location.y) * (nextScale - 1.0)
            )
            zoomScale = nextScale
            lastZoomScale = nextScale
            panOffset = clampPanOffset(targetOffset, in: size, scale: nextScale)
            lastPanOffset = panOffset
        }
    }

    // MARK: - 9. Metadata & Share Format Helpers
    private struct OriginalDNGShare: Transferable {
        let data: Data
        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(exportedContentType: UTType(filenameExtension: "dng") ?? .rawImage) { value in
                value.data
            }
        }
    }

    private var formatBadgeTitle: String {
        if item.saveFormat == .dng { return "RAW DNG" }
        if item.livePhotoMovieURL != nil { return "LIVE" }
        return item.saveFormat.rawValue
    }

    private var megapixelsString: String {
        let mp = Double(currentFullResCGImage.width * currentFullResCGImage.height) / 1_000_000.0
        return String(format: "%.1f MP", mp)
    }

    private var focalLengthMillimeters: Double {
        if let vm = viewModel {
            if vm.isWindowedZoomActive { return Double(vm.windowedZoomFocalLength) }
            let z = vm.displayZoom
            if z < 0.75 { return 13.0 }
            if z >= 2.8 { return 77.0 }
            if z >= 1.9 { return 48.0 }
        }
        return 24.0
    }

    private var focalLengthDisplayString: String {
        "\(Int(round(focalLengthMillimeters)))mm"
    }

    private var formattedShutterSpeed: String {
        let s = item.shutterSpeed
        guard s > 0 else { return "1/120s" }
        if s >= 1.0 { return String(format: "%.1fs", s) }
        return "1/\(max(1, Int(round(1.0 / s))))s"
    }

    private var opticalSummaryLine: String {
        let isoVal = Int(round(max(25, item.iso)))
        return "\(focalLengthDisplayString) · f/1.8 · \(formattedShutterSpeed) · ISO \(isoVal)"
    }

    private var estimatedFileSizeString: String {
        if let rawData = item.rawPhotoData, !hasModifiedSinceOpen {
            let mb = Double(rawData.count) / (1024.0 * 1024.0)
            return String(format: "%.2f MB", mb)
        }
        let pixels = Double(currentFullResCGImage.width * currentFullResCGImage.height)
        let bytesPerPx = (item.saveFormat == .dng) ? 1.8 : ((item.saveFormat == .jpeg) ? 0.42 : 0.24)
        let estMB = max(0.25, (pixels * bytesPerPx) / (1024.0 * 1024.0))
        return String(format: "~%.1f MB", estMB)
    }

    // MARK: - 6. Still-Photo Long-Press QR / Barcode Scanner Actions (Gallery & Photo Viewer Only)
    private func handleLongPressQRScan(at viewportPoint: CGPoint, in viewportSize: CGSize, displayedImage: UIImage) {
        let effectivePan = CGSize(
            width: panOffset.width,
            height: (zoomScale > 1.02) ? panOffset.height : dismissDragOffsetY
        )
        guard let normPoint = StillPhotoQRGeometry.normalizedImagePoint(
            fromViewportLocation: viewportPoint,
            viewportSize: viewportSize,
            imageSize: displayedImage.size,
            zoomScale: zoomScale,
            panOffset: effectivePan
        ) else {
            return
        }

        // 0ms fast path if already scanned this exact photo and user long-pressed a detected QR region
        if hasScannedCurrentImageForQR,
           let cachedHit = StillPhotoQRGeometry.hitTest(normalizedPoint: normPoint, in: photoQRCodes) {
            selectStillPhotoQR(cachedHit)
            return
        }

        let scanSourceCG: CGImage = (fullResNeedsRefresh || hasModifiedSinceOpen)
            ? (displayedImage.cgImage ?? currentFullResCGImage)
            : currentFullResCGImage

        photoQRScanTask?.cancel()
        qrPressTouchPoint = viewportPoint
        withAnimation(.easeInOut(duration: 0.16)) {
            isScanningPhotoQR = true
        }
        viewModel?.haptics.triggerLight()

        let existingCached = hasScannedCurrentImageForQR ? photoQRCodes : []
        let canFallbackPeekOriginal = (item.saveFormat != .dng)
            && (zoomScale <= 1.05)
            && (hasModifiedSinceOpen || item.originalImage !== item.processedImage)

        photoQRScanTask = Task {
            let scanResult = await Task.detached(priority: .userInitiated) {
                StillPhotoQRScanner.scan(
                    cgImage: scanSourceCG,
                    normalizedTouchPoint: normPoint,
                    existingCodes: existingCached
                )
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                withAnimation(.easeOut(duration: 0.18)) {
                    isScanningPhotoQR = false
                }
                hasScannedCurrentImageForQR = true
                photoQRCodes = scanResult.allCodes

                if let hit = scanResult.hitCode {
                    viewModel?.haptics.triggerSuccess()
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
                        activePhotoQR = hit
                    }
                } else if canFallbackPeekOriginal && isTrackingTouchDown {
                    // Nếu nhấn giữ vùng trống trên ảnh đã chỉnh màu -> giữ hành vi xem nhanh ảnh gốc
                    withAnimation(.easeInOut(duration: 0.14)) {
                        isPeekingOriginal = true
                    }
                } else {
                    if activePhotoQR != nil {
                        withAnimation(.easeOut(duration: 0.18)) {
                            activePhotoQR = nil
                        }
                    }
                    let msg = scanResult.allCodes.isEmpty
                        ? "Không tìm thấy mã QR trong ảnh này"
                        : "Nhấn giữ trực tiếp lên mã QR để quét"
                    showPhotoQRToast(msg)
                }
            }
        }
    }

    private func selectStillPhotoQR(_ code: DetectedQRCode) {
        viewModel?.haptics.triggerSuccess()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            activePhotoQR = code
        }
    }

    private func openStillPhotoQRPrimaryAction(_ code: DetectedQRCode) {
        viewModel?.haptics.triggerSelectionChange()
        if let url = code.openableURL {
            UIApplication.shared.open(url)
        } else {
            photoQRDetailTarget = code
        }
    }

    private func copyStillPhotoQR(_ code: DetectedQRCode) {
        UIPasteboard.general.string = code.copyableText
        viewModel?.haptics.triggerSuccess()
        showPhotoQRToast(code.copySuccessMessage)
    }

    private func copyCustomStillPhotoQRText(_ text: String, notice: String) {
        UIPasteboard.general.string = text
        viewModel?.haptics.triggerSuccess()
        showPhotoQRToast(notice)
    }

    private func clearStillPhotoQROverlay(resetScanCache: Bool) {
        photoQRScanTask?.cancel()
        isScanningPhotoQR = false
        activePhotoQR = nil
        isShowingPhotoQRMultiList = false
        if resetScanCache {
            hasScannedCurrentImageForQR = false
            photoQRCodes = []
        }
    }

    private func showPhotoQRToast(_ message: String) {
        photoQRToastTask?.cancel()
        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
            photoQRToastMessage = message
        }
        photoQRToastTask = Task {
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.20)) {
                    if photoQRToastMessage == message {
                        photoQRToastMessage = nil
                    }
                }
            }
        }
    }
}

// MARK: - Standalone Still-Photo Apple Vision QR/Barcode Decoder (Does NOT modify live camera QR scanner)
private enum StillPhotoQRScanner {
    struct ScanOutcome: Sendable {
        let allCodes: [DetectedQRCode]
        let hitCode: DetectedQRCode?
    }

    static func scan(
        cgImage: CGImage,
        normalizedTouchPoint: CGPoint,
        existingCodes: [DetectedQRCode]
    ) -> ScanOutcome {
        return autoreleasepool {
            var collected = existingCodes

            // Pass 1: Native full-image Apple Vision scan (10 symbologies, zero copy)
            if collected.isEmpty {
                let request = makeBarcodeRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
                if (try? handler.perform([request])) != nil {
                    collected = makeDetectedCodes(
                        from: request.results,
                        subCropTopLeft: CGRect(x: 0, y: 0, width: 1, height: 1)
                    )
                }
            }

            if let directHit = StillPhotoQRGeometry.hitTest(normalizedPoint: normalizedTouchPoint, in: collected) {
                return ScanOutcome(allCodes: deduplicateAndCap(collected), hitCode: directHit)
            }

            // Pass 2 & 3: Touch-centered zoomed high-contrast + inverted dark-mode pass for tiny/low-contrast QRs
            let cropNorm = StillPhotoQRGeometry.normalizedTouchCropRect(around: normalizedTouchPoint, sideFraction: 0.42)
            let imgW = CGFloat(cgImage.width)
            let imgH = CGFloat(cgImage.height)
            if imgW >= 120 && imgH >= 120 {
                let pixelCrop = CGRect(
                    x: floor(cropNorm.minX * imgW),
                    y: floor(cropNorm.minY * imgH),
                    width: max(32, floor(cropNorm.width * imgW)),
                    height: max(32, floor(cropNorm.height * imgH))
                ).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

                if let croppedCG = cgImage.cropping(to: pixelCrop) {
                    let ciContext = CIContext(options: [
                        .useSoftwareRenderer: false,
                        .cacheIntermediates: false,
                        .priorityRequestLow: true
                    ])
                    let baseCI = CIImage(cgImage: croppedCG)

                    // Pass 2: Zoomed monochrome high-contrast + sharpen
                    let contrasted = baseCI
                        .applyingFilter("CIColorControls", parameters: [
                            kCIInputSaturationKey: 0.0,
                            kCIInputContrastKey: 1.48
                        ])
                        .applyingFilter("CISharpenLuminance", parameters: [
                            kCIInputSharpnessKey: 0.72
                        ])
                    let pass2Req = makeBarcodeRequest()
                    let pass2Handler = VNImageRequestHandler(ciImage: contrasted, orientation: .up, options: [.ciContext: ciContext])
                    if (try? pass2Handler.perform([pass2Req])) != nil {
                        let pass2Codes = makeDetectedCodes(from: pass2Req.results, subCropTopLeft: cropNorm)
                        collected.append(contentsOf: pass2Codes)
                    }

                    // Pass 3: Inverted dark-mode polarity if still no hit at touch point
                    if StillPhotoQRGeometry.hitTest(normalizedPoint: normalizedTouchPoint, in: collected) == nil {
                        let inverted = baseCI
                            .applyingFilter("CIColorControls", parameters: [
                                kCIInputSaturationKey: 0.0,
                                kCIInputContrastKey: 1.35
                            ])
                            .applyingFilter("CIColorInvert")
                        let pass3Req = makeBarcodeRequest()
                        let pass3Handler = VNImageRequestHandler(ciImage: inverted, orientation: .up, options: [.ciContext: ciContext])
                        if (try? pass3Handler.perform([pass3Req])) != nil {
                            let pass3Codes = makeDetectedCodes(from: pass3Req.results, subCropTopLeft: cropNorm)
                            collected.append(contentsOf: pass3Codes)
                        }
                    }

                    ciContext.clearCaches()
                }
            }

            let merged = deduplicateAndCap(collected)
            let hit = StillPhotoQRGeometry.hitTest(normalizedPoint: normalizedTouchPoint, in: merged)
            return ScanOutcome(allCodes: merged, hitCode: hit)
        }
    }

    private static func makeBarcodeRequest() -> VNDetectBarcodesRequest {
        let request = VNDetectBarcodesRequest()
        let preferred: [VNBarcodeSymbology] = [
            .qr, .microQR, .aztec, .dataMatrix, .pdf417,
            .ean13, .ean8, .upce, .code128, .code39
        ]
        let supported = (try? request.supportedSymbologies()) ?? [.qr]
        let resolved = preferred.filter { supported.contains($0) }
        request.symbologies = resolved.isEmpty ? [.qr] : resolved
        return request
    }

    private static func makeDetectedCodes(
        from observations: [VNBarcodeObservation]?,
        subCropTopLeft: CGRect
    ) -> [DetectedQRCode] {
        guard let observations, !observations.isEmpty else { return [] }
        var results: [DetectedQRCode] = []
        results.reserveCapacity(min(8, observations.count))
        for obs in observations {
            guard let raw = obs.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            let box = QRCodePayloadParser.visionRectToFullFrameTopLeft(
                obs.boundingBox,
                subCropTopLeft: subCropTopLeft
            )
            let symLabel = symbologyLabel(for: obs.symbology)
            results.append(
                DetectedQRCode(
                    rawValue: raw,
                    kind: QRCodePayloadParser.parse(raw, symbologyLabel: symLabel),
                    normalizedBoundingBox: box,
                    symbologyLabel: symLabel,
                    timestamp: 0
                )
            )
        }
        return results
    }

    private static func deduplicateAndCap(_ codes: [DetectedQRCode]) -> [DetectedQRCode] {
        var selector = QRCodeMultiSelector()
        return selector.select(from: codes).allCodes
    }

    private static func symbologyLabel(for symbology: VNBarcodeSymbology) -> String {
        switch symbology {
        case .qr: return "QR"
        case .microQR: return "Micro QR"
        case .aztec: return "Aztec"
        case .dataMatrix: return "DataMatrix"
        case .pdf417: return "PDF417"
        case .ean13: return "EAN-13"
        case .ean8: return "EAN-8"
        case .upce: return "UPC-E"
        case .code128: return "Code 128"
        case .code39: return "Code 39"
        default: return "QR"
        }
    }
}

// MARK: - Animated Luminous Light Trail Orbiting Around Scanned QR Code
private struct StillPhotoQRAnimatedFrameView: View {
    let rect: CGRect
    let zoomScale: CGFloat

    @State private var orbitAngle: Double = 0
    @State private var scanBeamProgress: CGFloat = 0.0
    @State private var scanBeamOpacity: Double = 0.95
    @State private var bracketScale: CGFloat = 1.14
    @State private var haloBreath: Bool = false

    var body: some View {
        let zoomComp = max(1.0, sqrt(zoomScale))
        let pad: CGFloat = 8.0 / zoomComp
        let w = max(32.0 / zoomComp, rect.width + pad * 2.0)
        let h = max(32.0 / zoomComp, rect.height + pad * 2.0)
        let cornerR = min(14.0 / zoomComp, min(w, h) * 0.20)
        let borderW = max(1.1, 2.5 / zoomComp)
        let bracketW = max(1.3, 2.7 / zoomComp)
        let bracketLen = min(18.0 / zoomComp, min(w, h) * 0.28)
        let spinnerDim = max(w, h) * 1.65

        ZStack {
            // 1. Soft breathing Warm Titanium ambient outer halo
            RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                .stroke(AlignTheme.studioAccent.opacity(haloBreath ? 0.42 : 0.22), lineWidth: borderW * 2.4)
                .blur(radius: 5.0 / zoomComp)
                .frame(width: w, height: h)

            // 2. Subtle darkroom contrast backing rim so bright trail pops even on pure white paper QRs
            RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                .stroke(Color.black.opacity(0.42), lineWidth: borderW + 1.2 / zoomComp)
                .frame(width: w, height: h)

            // 3. Continuous Orbiting Luminous Light Trail (Dual-Comet AngularGradient masked cleanly to QR perimeter)
            AngularGradient(
                gradient: Gradient(stops: [
                    .init(color: AlignTheme.studioAccent.opacity(0.16), location: 0.00),
                    .init(color: AlignTheme.studioAccent.opacity(0.55), location: 0.14),
                    .init(color: Color.white.opacity(0.98), location: 0.24),
                    .init(color: AlignTheme.studioAccent.opacity(0.88), location: 0.30),
                    .init(color: AlignTheme.studioAccent.opacity(0.14), location: 0.48),
                    .init(color: AlignTheme.studioAccent.opacity(0.45), location: 0.64),
                    .init(color: Color.white.opacity(0.86), location: 0.74),
                    .init(color: AlignTheme.studioAccent.opacity(0.20), location: 0.86),
                    .init(color: AlignTheme.studioAccent.opacity(0.16), location: 1.00)
                ]),
                center: .center
            )
            .frame(width: spinnerDim, height: spinnerDim)
            .rotationEffect(.degrees(orbitAngle))
            .frame(width: w, height: h)
            .mask(
                RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: borderW, lineCap: .round, lineJoin: .round))
                    .frame(width: w, height: h)
            )
            .shadow(color: AlignTheme.studioAccent.opacity(0.65), radius: 5.0 / zoomComp)

            // 4. One-shot optical laser scan line sweeping top-to-bottom across QR interior on lock
            if scanBeamOpacity > 0.01 {
                ZStack(alignment: .top) {
                    LinearGradient(
                        colors: [
                            Color.clear,
                            AlignTheme.studioAccent.opacity(0.24),
                            Color.white.opacity(0.92)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: w, height: max(8.0 / zoomComp, h * 0.26))
                    .offset(y: scanBeamProgress * max(0, h - max(8.0 / zoomComp, h * 0.26)))
                }
                .frame(width: w, height: h, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: cornerR, style: .continuous))
                .opacity(scanBeamOpacity)
            }

            // 5. Crisp Spring-Locking Optical Corner Brackets
            CornerBracketsShape(bracketLength: bracketLen)
                .stroke(
                    AlignTheme.studioAccent,
                    style: StrokeStyle(lineWidth: bracketW, lineCap: .round, lineJoin: .round)
                )
                .frame(width: w + 4.0 / zoomComp, height: h + 4.0 / zoomComp)
                .scaleEffect(bracketScale)
                .shadow(color: Color.black.opacity(0.55), radius: 2.0 / zoomComp, y: 0.5 / zoomComp)
        }
        .frame(width: w + 12.0 / zoomComp, height: h + 12.0 / zoomComp)
        .position(x: rect.midX, y: rect.midY)
        .onAppear {
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                orbitAngle = 360.0
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                haloBreath = true
            }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.70)) {
                bracketScale = 1.0
            }
            withAnimation(.easeInOut(duration: 0.68)) {
                scanBeamProgress = 1.0
            }
            withAnimation(.easeOut(duration: 0.32).delay(0.56)) {
                scanBeamOpacity = 0.0
            }
        }
    }
}

// MARK: - Touch-Point Concentric Optical Scan Pulse While Decoding
private struct StillPhotoQRTouchPulseView: View {
    @State private var expand: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(AlignTheme.studioAccent.opacity(expand ? 0.0 : 0.72), lineWidth: 1.6)
                .frame(width: 44, height: 44)
                .scaleEffect(expand ? 2.1 : 0.75)

            Circle()
                .fill(AlignTheme.studioAccent.opacity(0.18))
                .frame(width: 28, height: 28)
                .overlay(Circle().stroke(AlignTheme.studioAccent.opacity(0.85), lineWidth: 1.2))
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.85).repeatForever(autoreverses: false)) {
                expand = true
            }
        }
    }
}

// MARK: - Smooth RGB + Luminance Histogram Waveform Canvas
private struct PhotoDetailHistogramCanvasView: View {
    let snapshot: PhotoDarkroomHistogram

    private func buildPath(bins: [Double], in size: CGSize, closed: Bool) -> Path {
        var path = Path()
        guard bins.count >= 2 else { return path }
        let stepX = size.width / CGFloat(bins.count - 1)
        if closed {
            path.move(to: CGPoint(x: 0, y: size.height))
            for (idx, val) in bins.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(idx) * stepX, y: size.height * (1.0 - CGFloat(min(1.0, max(0.0, val))))))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        } else {
            for (idx, val) in bins.enumerated() {
                let pt = CGPoint(x: CGFloat(idx) * stepX, y: size.height * (1.0 - CGFloat(min(1.0, max(0.0, val)))))
                if idx == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
        }
        return path
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                buildPath(bins: snapshot.redBins, in: size, closed: true).fill(Color.red.opacity(0.20))
                buildPath(bins: snapshot.greenBins, in: size, closed: true).fill(Color.green.opacity(0.20))
                buildPath(bins: snapshot.blueBins, in: size, closed: true).fill(Color.cyan.opacity(0.22))
                buildPath(bins: snapshot.redBins, in: size, closed: false).stroke(Color.red.opacity(0.75), lineWidth: 1.0)
                buildPath(bins: snapshot.greenBins, in: size, closed: false).stroke(Color.green.opacity(0.75), lineWidth: 1.0)
                buildPath(bins: snapshot.blueBins, in: size, closed: false).stroke(Color.cyan.opacity(0.80), lineWidth: 1.0)
                buildPath(bins: snapshot.lumaBins, in: size, closed: false).stroke(Color.white.opacity(0.90), lineWidth: 1.2)
            }
        }
    }
}

private struct CapturedPhotoActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
