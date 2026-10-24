import Foundation
import LightShotCore
import Vision

struct ScrollRegistration: Sendable {
    /// Pixels of new content above the overlap. Positive means the page moved
    /// up (the user scrolled down).
    let offset: Int
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
    /// Registers `current` against `previous`. Vision's alignment transform is
    /// in pixels; a positive `ty` means the previous content moved down in the
    /// current frame, so the current frame has that many rows of new content.
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
            offset: Int(observation.alignmentTransform.ty.rounded()),
            confidence: observation.confidence
        )
    }
}
