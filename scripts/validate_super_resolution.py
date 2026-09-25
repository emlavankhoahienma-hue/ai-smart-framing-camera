"""Native capture source contracts; does not compile iOS or inspect real photos.

The former burst reconstruction tests have been replaced because that algorithm
is removed. Device colour, actual megapixels, PhotoKit and EXIF tests remain
mandatory; see tests/CameraCaptureRegressionTests.swift and README_VI.md.
"""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera'
def source(path): return (ROOT / path).read_text(encoding='utf-8')
C = source('Services/CameraService.swift')
V = source('ViewModels/CameraViewModel.swift')
D = source('Services/SuperResolutionRAWEngine.swift')
P = source('Views/CapturedPhotoPreviewView.swift')

class NativeCaptureContracts(unittest.TestCase):
    def test_no_burst_or_raw_developer_entry_point(self):
        production = '\n'.join(p.read_text(encoding='utf-8') for p in ROOT.rglob('*.swift'))
        for removed in ['CIRAWFilter(', 'captureSuperResolutionBurst(', 'SuperResolutionMetalShaders.shared']:
            self.assertNotIn(removed, production)
    def test_raw_and_processed_are_one_request(self):
        self.assertIn('AVCapturePhotoSettings(rawPixelFormatType: raw,', C)
        self.assertIn('processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg]', C)
        self.assertIn('request.id == photo.resolvedSettings.uniqueID', C)
        self.assertIn('request.id == resolvedSettings.uniqueID', C)
    def test_raw_asset_keeps_dng_and_colour_companion_together(self):
        self.assertIn('rawFileType: .dng', C)
        self.assertIn('processedFileType: .jpg', C)
        self.assertIn('settings.rawEmbeddedThumbnailPhotoFormat', C)
        self.assertIn('request.processedData = data', C)
        save = V.split('public func savePhotoToLibrary', 1)[1].split('// MARK: - Computed helpers', 1)[0]
        self.assertIn('request.addResource(with: .photo, data: mainData', save)
        self.assertIn('request.addResource(with: .alternatePhoto, data: companion', save)
    def test_raw_unavailable_is_an_error(self):
        self.assertIn('reject(CameraServiceError.rawUnavailable); return', C)
        self.assertIn('actualFormat = .dng', C)
    def test_native_resolution_has_no_thumbnail_or_upscale(self):
        self.assertIn('supportedMaxPhotoDimensions', C)
        self.assertIn('settings.maxPhotoDimensions = dimensions', C)
        self.assertIn('CGImageSourceCreateImageAtIndex(source, 0, options)', D)
        self.assertNotIn('CGImageSourceCreateThumbnailAtIndex', D)
        self.assertNotIn('CGAffineTransform(scaleX:', D)
    def test_no_deferred_proxy_without_delegate(self):
        self.assertIn('isAutoDeferredPhotoDeliveryEnabled = false', C)
        self.assertIn('isFastCapturePrioritizationEnabled = false', C)
    def test_decoded_orientation_and_colour_profile(self):
        self.assertIn('CGImagePropertyOrientation(rawValue: value) ?? .up', D)
        self.assertEqual(D.count('.oriented(orientation)'), 1)
        self.assertIn('colorSpace: outputSpace', D)
        self.assertIn('metadata[kCGImagePropertyOrientation as String] = 1', V)
    def test_save_and_share_preserve_original_raw(self):
        save=V.split('public func savePhotoToLibrary',1)[1].split('// MARK: - Computed helpers',1)[0]
        self.assertIn('SuperResolutionRAWEngine.isDNGData',save)
        self.assertIn('request.addResource(with: .photo, data: mainData',save)
        self.assertNotIn('creationRequestForAsset(from:',save)
        self.assertIn('ShareLink(item: OriginalDNGShare(data: data)',P)
        self.assertIn('value.data',P.split('private struct OriginalDNGShare',1)[1])
    def test_capture_settings_are_snapshotted_and_raw_skips_edits(self):
        self.assertIn('captureProcessingSettings = currentPhotoProcessingSettings()', V)
        self.assertIn('let isFilmActive = settings.applyFilm && format != .dng', V)
        self.assertIn('let isWindowed = settings.crop && format != .dng', V)
    def test_save_result_is_reported_after_photokit(self):
        self.assertIn('completion?(success)', V)
        self.assertIn('self.hasSavedNewEnhancement = success', P)
    def test_timeout_does_not_clear_hardware_busy_early(self):
        block=C.split('self.sessionQueue.asyncAfter(deadline: .now() + 30)',1)[1].split('// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate',1)[0]
        self.assertIn('request.failureReported = true',block)
        self.assertNotIn('isPhotoCaptureInFlight = false',block)

if __name__ == '__main__': unittest.main(verbosity=2)
