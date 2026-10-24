import Foundation
import LightShotCore
import Vision

struct ScrollRegistration: Sendable {
    /// Raw Vision `alignmentTransform.ty` in pixels. Vision's space is
    /// bottom-left, y-up: a downward scroll yields a negative value.
    /// Interpret through `ScrollAlignment.overlapRows`, never directly.
    let translationY: Int
    let confidence: Float
}

enum ScrollRegistrationError: Error, LocalizedError, Sendable {
    case requestFailed(String)
    case noResult

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            return "Scroll registration failed: \(message)"
        case .noResult:
            return "Scroll registration found no alignment."
        }
    }
}

enum ScrollRegistrationService {
    /// Registers `current` against `previous`.
    static func offset(previous: ImageData, current: ImageData) throws -> ScrollRegistration {
        let request = VNTranslationalImageRegistrationRequest(
            targetedCGImage: previous.cgImage,
            options: [:]
        )
        let handler = VNImageRequestHandler(cgImage: current.cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ScrollRegistrationError.requestFailed(error.localizedDescription)
        }
        guard let observation = request.results?.first else {
            throw ScrollRegistrationError.noResult
        }
        return ScrollRegistration(
            translationY: Int(observation.alignmentTransform.ty.rounded()),
            confidence: observation.confidence
        )
    }
}
