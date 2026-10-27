//
//  CameraViewModel+PoseGuide.swift
//  AISmartFramingCamera
//
//  Created by Antigravity on 2026-10-27.
//  Copyright © 2026 AI Smart Framing Camera. All rights reserved.
//

import Foundation
import CoreGraphics
import CoreVideo
import Vision

extension CameraViewModel {
    // MARK: - AI Pose Guide Evaluation (So Khớp Khung Xương Thời Gian Thực)
    public func selectPoseTemplate(_ template: AIPoseTemplate?) {
        activePoseTemplate = template
        if template == nil {
            poseAlignmentScore = 0.0
            isPoseMatched = false
            livePoseJoints = [:]
            poseFeedbackMessage = ""
            AIPoseAlignmentEngine.shared.reset()
        }
    }

    public func togglePosePicker() {
        isPosePickerPresented.toggle()
    }

    public func evaluateLivePose(in pixelBuffer: CVPixelBuffer) {
        guard let template = activePoseTemplate else { return }
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            if let observation = request.results?.first {
                let result = AIPoseAlignmentEngine.shared.evaluate(observation: observation, template: template)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let wasMatched = self.isPoseMatched
                    self.poseAlignmentScore = result.score
                    self.isPoseMatched = result.isMatched
                    self.livePoseJoints = result.recognizedJoints
                    self.poseFeedbackMessage = result.feedbackMessage
                    if !wasMatched && result.isMatched {
                        self.haptics.triggerMagneticSnap()
                    }
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.poseAlignmentScore = max(0.0, self.poseAlignmentScore * 0.85)
                    self.isPoseMatched = false
                    self.livePoseJoints = [:]
                    self.poseFeedbackMessage = "Chưa phát hiện dáng người"
                }
            }
        } catch {
            // graceful ignore
        }
    }
}
