import CoreGraphics
import Foundation
import SnipboCore
import Vision

enum RedactionMode: Int, Sendable {
    case sensitiveText
    case faces
    case allText
}

enum RedactionError: Error, LocalizedError, Sendable {
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            return L10n.tr("Redaction failed: \(message)", "打码识别失败：\(message)")
        }
    }
}

/// Finds regions worth hiding before a screenshot is shared. Everything runs
/// on-device through Vision; no pixels leave the machine.
actor RedactionService {
    static let shared = RedactionService()

    private init() {}

    func regions(
        in image: ImageData,
        mode: RedactionMode,
        languages: [String]
    ) async throws -> [CGRect] {
        try Task.checkCancellation()
        let width = image.cgImage.width
        let height = image.cgImage.height
        guard width > 0, height > 0 else { return [] }

        let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
        switch mode {
        case .faces:
            let request = VNDetectFaceRectanglesRequest()
            do {
                try handler.perform([request])
            } catch {
                throw RedactionError.requestFailed(error.localizedDescription)
            }
            try Task.checkCancellation()
            let rects = (request.results ?? []).map {
                pixelRect($0.boundingBox, width: width, height: height)
            }
            return merged(rects, imageWidth: width, imageHeight: height)

        case .sensitiveText, .allText:
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = languages.isEmpty
                ? AppSettings.defaultOCRLanguages
                : languages
            do {
                try handler.perform([request])
            } catch {
                throw RedactionError.requestFailed(error.localizedDescription)
            }
            try Task.checkCancellation()
            let observations = request.results ?? []
            let selected = observations.filter { observation in
                guard mode == .sensitiveText else { return true }
                return observation.topCandidates(1).first.map {
                    Self.isSensitive($0.string)
                } ?? false
            }
            let rects = selected.map {
                pixelRect($0.boundingBox, width: width, height: height)
            }
            return merged(rects, imageWidth: width, imageHeight: height)
        }
    }

    private func pixelRect(
        _ box: CGRect,
        width: Int,
        height: Int
    ) -> CGRect {
        let imageWidth = CGFloat(width)
        let imageHeight = CGFloat(height)
        return CGRect(
            x: box.minX * imageWidth,
            y: (1 - box.maxY) * imageHeight,
            width: box.width * imageWidth,
            height: box.height * imageHeight
        )
    }

    /// Expands slightly, clips to the image, and unions overlapping boxes so a
    /// paragraph does not produce dozens of adjacent annotations.
    private func merged(
        _ rects: [CGRect],
        imageWidth: Int,
        imageHeight: Int
    ) -> [CGRect] {
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        var result: [CGRect] = []
        for rect in rects {
            var candidate = rect.insetBy(dx: -3, dy: -3)
                .intersection(bounds)
                .integral
            guard candidate.width >= 2, candidate.height >= 2 else { continue }
            var didMerge = true
            while didMerge {
                didMerge = false
                for (index, existing) in result.enumerated() {
                    let union = existing.union(candidate)
                    let overlap = existing.intersection(candidate)
                    if !overlap.isNull,
                       overlap.width * overlap.height > 0,
                       union.width * union.height
                        <= existing.width * existing.height
                            + candidate.width * candidate.height {
                        candidate = union
                        result.remove(at: index)
                        didMerge = true
                        break
                    }
                }
            }
            result.append(candidate)
        }
        return result.sorted {
            if $0.minY != $1.minY { return $0.minY < $1.minY }
            return $0.minX < $1.minX
        }
    }

    /// Email addresses, long digit runs (IDs/cards), phone numbers, and links.
    private static func isSensitive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5 else { return false }
        let patterns = [
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            #"\b\d{17}[\dXx]\b"#,
            #"\b\d{13,19}\b"#,
            #"\b(?:\+?\d{1,3}[\s-]?)?(?:\(\d{2,4}\)[\s-]?)?\d{3,4}[\s-]?\d{4}\b"#,
        ]
        for pattern in patterns {
            if trimmed.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                return true
            }
        }
        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
                | NSTextCheckingResult.CheckingType.link.rawValue
        ) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if detector.firstMatch(in: trimmed, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }
}
