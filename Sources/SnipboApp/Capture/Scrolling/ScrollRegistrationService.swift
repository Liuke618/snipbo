import Foundation
import SnipboCore
import Vision

struct ScrollRegistration: Sendable {
    /// Raw Vision `alignmentTransform.ty` in pixels. For text-bearing
    /// content a downward scroll yields a positive value whose magnitude is
    /// the rows the content moved up. Interpret through `ScrollAlignment`,
    /// never directly.
    let translationY: Int
    let confidence: Float
}

enum ScrollRegistrationError: Error, LocalizedError, Sendable {
    case requestFailed(String)
    case noResult

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            return L10n.tr(
                "Scroll registration failed: \(message)",
                "滚动对齐失败：\(message)"
            )
        case .noResult:
            return L10n.tr(
                "Scroll registration found no alignment.",
                "滚动对齐没有找到匹配。"
            )
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
