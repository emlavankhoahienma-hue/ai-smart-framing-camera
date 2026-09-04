import Foundation
import AVFoundation
import UIKit
import Combine

public final class ProVideoManualControlsService: ObservableObject {
    public static let shared = ProVideoManualControlsService()
    
    // MARK: - 1. ISO Controls
    @Published public var isAutoISO: Bool = true
    @Published public var currentISO: Float = 100.0
    @Published public var minISO: Float = 32.0
    @Published public var maxISO: Float = 3200.0
    
    // MARK: - 2. Shutter Speed Controls (Mau so giay: 60 = 1/60s)
    @Published public var isAutoShutter: Bool = true
    @Published public var currentShutterSpeed: Double = 60.0
    @Published public var minShutterSpeed: Double = 24.0
    @Published public var maxShutterSpeed: Double = 8000.0
    
    // MARK: - 3. Aperture & EV Bias Controls
    @Published public var isAutoEV: Bool = true
    @Published public var currentEVBias: Float = 0.0
    @Published public var minEVBias: Float = -2.0
    @Published public var maxEVBias: Float = 2.0
    @Published public var hardwareLensAperture: Float = 1.8
    
    // MARK: - 4. White Balance Controls (Kelvin & Tint)
    @Published public var isAutoWB: Bool = true
    @Published public var currentKelvin: Float = 5600.0
    @Published public var currentTint: Float = 0.0
    
    // MARK: - Live Sensor Readouts (Hien thi real-time khi dang Auto)
    @Published public var measuredLiveISO: Float = 100.0
    @Published public var measuredLiveShutterSpeed: Double = 60.0
    @Published public var measuredLiveKelvin: Float = 5600.0
    @Published public var measuredLiveTint: Float = 0.0
    
    // Throttle control
    private var pendingExposureWorkItem: DispatchWorkItem?
    private var pendingWBWorkItem: DispatchWorkItem?
    
    private init() {}
    
    // MARK: - Sync Hardware Range & Aperture
    public func syncHardwareCapabilities() {
        guard let camera = CameraService.shared.currentActiveCamera else { return }
        let format = camera.activeFormat
        
        DispatchQueue.main.async {
            self.minISO = max(25.0, format.minISO)
            self.maxISO = min(6400.0, format.maxISO)
            
            let minDurSeconds = CMTimeGetSeconds(format.minExposureDuration)
            let maxDurSeconds = CMTimeGetSeconds(format.maxExposureDuration)
            
            if minDurSeconds > 0 {
                self.maxShutterSpeed = min(8000.0, round(1.0 / minDurSeconds))
            }
            if maxDurSeconds > 0 {
                self.minShutterSpeed = max(15.0, round(1.0 / maxDurSeconds))
            }
            
            self.minEVBias = max(-2.0, camera.minExposureTargetBias)
            self.maxEVBias = min(2.0, camera.maxExposureTargetBias)
            
            self.hardwareLensAperture = camera.lensAperture > 0 ? camera.lensAperture : 1.8
            
            CameraLogger.info("ProVideo: Sync phan cung -> ISO: \(self.minISO)-\(self.maxISO) | Shutter: 1/\(Int(self.maxShutterSpeed))-1/\(Int(self.minShutterSpeed)) | Khau do: f/\(self.hardwareLensAperture)", category: .capture)
        }
    }
    
    // MARK: - Live Measurements Update
    public func updateLiveMeasurements(iso: Float, shutterDuration: Double) {
        let speed = shutterDuration > 0 ? (1.0 / shutterDuration) : 60.0
        DispatchQueue.main.async {
            self.measuredLiveISO = iso
            self.measuredLiveShutterSpeed = speed
        }
    }
    
    // MARK: - ISO Adjustments
    public func setAutoISO(_ isAuto: Bool) {
        self.isAutoISO = isAuto
        if isAuto {
            if isAutoShutter {
                restoreContinuousAutoExposure()
            } else {
                applyExposureSettings()
            }
        } else {
            applyExposureSettings()
        }
    }
    
    public func setManualISO(_ iso: Float) {
        let clamped = max(minISO, min(iso, maxISO))
        self.currentISO = clamped
        self.isAutoISO = false
        applyExposureSettings()
    }
    
    // MARK: - Shutter Speed Adjustments
    public func setAutoShutter(_ isAuto: Bool) {
        self.isAutoShutter = isAuto
        if isAuto {
            if isAutoISO {
                restoreContinuousAutoExposure()
            } else {
                applyExposureSettings()
            }
        } else {
            applyExposureSettings()
        }
    }
    
    public func setManualShutterSpeed(_ speed: Double) {
        let clamped = max(minShutterSpeed, min(speed, maxShutterSpeed))
        self.currentShutterSpeed = clamped
        self.isAutoShutter = false
        applyExposureSettings()
    }
    
    // MARK: - Aperture & EV Bias Adjustments
    public func setAutoEV(_ isAuto: Bool) {
        self.isAutoEV = isAuto
        if isAuto {
            setManualEVBias(0.0)
            self.isAutoEV = true
        }
    }
    
    public func setManualEVBias(_ bias: Float) {
        let clamped = max(minEVBias, min(bias, maxEVBias))
        self.currentEVBias = clamped
        self.isAutoEV = (clamped == 0.0)
        
        let sessionQueue = CameraService.shared.currentSessionQueue
        sessionQueue.async {
            guard let camera = CameraService.shared.currentActiveCamera else { return }
            do {
                try camera.lockForConfiguration()
                camera.setExposureTargetBias(clamped, completionHandler: nil)
                camera.unlockForConfiguration()
            } catch {
                CameraLogger.error("ProVideo: Loi chinh EV", error: error, category: .capture)
            }
        }
    }
    
    // MARK: - White Balance Adjustments
    public func setAutoWB(_ isAuto: Bool) {
        self.isAutoWB = isAuto
        if isAuto {
            restoreContinuousAutoWhiteBalance()
        } else {
            applyWhiteBalanceSettings()
        }
    }
    
    public func setManualWhiteBalance(kelvin: Float, tint: Float = 0.0) {
        self.currentKelvin = max(2500.0, min(kelvin, 9000.0))
        self.currentTint = max(-50.0, min(tint, 50.0))
        self.isAutoWB = false
        applyWhiteBalanceSettings()
    }
    
    // MARK: - Hardware Exposure Application
    private func applyExposureSettings() {
        pendingExposureWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard let camera = CameraService.shared.currentActiveCamera else { return }
            
            // Neu ca 2 deu Auto -> Tra ve ContinuousAutoExposure
            if self.isAutoISO && self.isAutoShutter {
                self.restoreContinuousAutoExposure()
                return
            }
            
            do {
                try camera.lockForConfiguration()
                if camera.isExposureModeSupported(.custom) {
                    let targetISO: Float
                    if self.isAutoISO {
                        targetISO = camera.iso
                    } else {
                        targetISO = max(camera.activeFormat.minISO, min(self.currentISO, camera.activeFormat.maxISO))
                    }
                    
                    let targetDuration: CMTime
                    if self.isAutoShutter {
                        targetDuration = camera.exposureDuration
                    } else {
                        let sec = 1.0 / self.currentShutterSpeed
                        let cmSec = CMTime(seconds: sec, timescale: 1000000)
                        targetDuration = max(camera.activeFormat.minExposureDuration, min(cmSec, camera.activeFormat.maxExposureDuration))
                    }
                    
                    camera.setExposureModeCustom(duration: targetDuration, iso: targetISO, completionHandler: nil)
                }
                camera.unlockForConfiguration()
            } catch {
                CameraLogger.error("ProVideo: Loi ap dung Exposure Custom", error: error, category: .capture)
            }
        }
        
        self.pendingExposureWorkItem = workItem
        CameraService.shared.currentSessionQueue.asyncAfter(deadline: .now() + 0.02, execute: workItem)
    }
    
    private func restoreContinuousAutoExposure() {
        let sessionQueue = CameraService.shared.currentSessionQueue
        sessionQueue.async {
            guard let camera = CameraService.shared.currentActiveCamera else { return }
            do {
                try camera.lockForConfiguration()
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                camera.unlockForConfiguration()
            } catch {
                CameraLogger.error("ProVideo: Loi khoi phuc Auto Exposure", error: error, category: .capture)
            }
        }
    }
    
    // MARK: - Hardware White Balance Application
    private func applyWhiteBalanceSettings() {
        pendingWBWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard let camera = CameraService.shared.currentActiveCamera else { return }
            
            if self.isAutoWB {
                self.restoreContinuousAutoWhiteBalance()
                return
            }
            
            let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: self.currentKelvin,
                tint: self.currentTint
            )
            
            var gains = camera.deviceWhiteBalanceGains(for: tempAndTint)
            let maxGain = camera.maxWhiteBalanceGain
            gains.redGain = max(1.0, min(gains.redGain, maxGain))
            gains.greenGain = max(1.0, min(gains.greenGain, maxGain))
            gains.blueGain = max(1.0, min(gains.blueGain, maxGain))
            
            do {
                try camera.lockForConfiguration()
                if camera.isWhiteBalanceModeSupported(.locked) {
                    camera.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                }
                camera.unlockForConfiguration()
            } catch {
                CameraLogger.error("ProVideo: Loi khoa White Balance", error: error, category: .capture)
            }
        }
        
        self.pendingWBWorkItem = workItem
        CameraService.shared.currentSessionQueue.asyncAfter(deadline: .now() + 0.02, execute: workItem)
    }
    
    private func restoreContinuousAutoWhiteBalance() {
        let sessionQueue = CameraService.shared.currentSessionQueue
        sessionQueue.async {
            guard let camera = CameraService.shared.currentActiveCamera else { return }
            do {
                try camera.lockForConfiguration()
                if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    camera.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                camera.unlockForConfiguration()
            } catch {
                CameraLogger.error("ProVideo: Loi khoi phuc Auto White Balance", error: error, category: .capture)
            }
        }
    }
    
    // MARK: - Full Reset to Auto (Goi khi chuyen khoi VIDEO PRO)
    public func resetToFullAuto() {
        DispatchQueue.main.async {
            self.isAutoISO = true
            self.isAutoShutter = true
            self.isAutoEV = true
            self.currentEVBias = 0.0
            self.isAutoWB = true
        }
        
        restoreContinuousAutoExposure()
        restoreContinuousAutoWhiteBalance()
        
        let sessionQueue = CameraService.shared.currentSessionQueue
        sessionQueue.async {
            guard let camera = CameraService.shared.currentActiveCamera else { return }
            do {
                try camera.lockForConfiguration()
                camera.setExposureTargetBias(0.0, completionHandler: nil)
                camera.unlockForConfiguration()
            } catch {}
        }
        CameraLogger.info("ProVideo: Da khoi phuc toan bo thong so ve Auto hoan toan", category: .capture)
    }
}
