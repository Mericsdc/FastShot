import CoreGraphics
import FastShotCore
import Foundation
import Vision

/// On-device OCR for "copy text" and "translate".
enum TextRecognizer {
    /// Recognised lines with their boxes in image pixels (top-left origin), top to bottom.
    static func lines(_ image: CGImage) async throws -> [TextReflow.Line] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["tr-TR", "en-US"]
                request.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let width = CGFloat(image.width), height = CGFloat(image.height)
                    let lines = (request.results ?? []).compactMap { observation -> TextReflow.Line? in
                        guard let text = observation.topCandidates(1).first?.string else { return nil }
                        let box = observation.boundingBox
                        return TextReflow.Line(text: text, box: CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                                                                       width: box.width * width, height: box.height * height))
                    }
                    continuation.resume(returning: lines.sorted { $0.box.minY < $1.box.minY })
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The text as paragraphs: wrapped lines are joined back into sentences.
    static func recognize(_ image: CGImage) async throws -> String {
        TextReflow.join(try await lines(image))
    }
}
