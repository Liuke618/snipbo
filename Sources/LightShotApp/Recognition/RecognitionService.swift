import Foundation
import LightShotCore
import Vision

enum RecognitionError: Error, LocalizedError, Sendable {
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            return "Recognition failed: \(message)"
        }
    }
}

/// Serializes Vision requests on an actor so OCR never blocks the main thread
/// and at most one recognition runs at a time. Vision's synchronous request
/// cannot be interrupted mid-flight; callers cancel the surrounding task and
/// discard the result by checking cancellation after the request returns.
actor RecognitionService {
    /// One shared actor keeps every editor's OCR requests serial, as required
    /// by the design.
    static let shared = RecognitionService()

    private init() {}

    func recognize(_ image: ImageData, languages: [String]) async throws -> RecognitionResult {
        try Task.checkCancellation()

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true
        textRequest.recognitionLanguages = languages.isEmpty
            ? AppSettings.defaultOCRLanguages
            : languages

        // Leaving `symbologies` at its default scans every symbology Vision
        // supports, including QR, Aztec, Data Matrix, PDF417, and common 1D
        // barcodes.
        let barcodeRequest = VNDetectBarcodesRequest()

        let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
        do {
            try handler.perform([textRequest, barcodeRequest])
        } catch {
            throw RecognitionError.requestFailed(error.localizedDescription)
        }
        try Task.checkCancellation()

        let textBlocks = (textRequest.results ?? []).compactMap { observation -> TextBlock? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextBlock(
                text: candidate.string,
                boundingBox: observation.boundingBox,
                confidence: candidate.confidence
            )
        }
        let barcodes = (barcodeRequest.results ?? []).compactMap { observation -> BarcodeResult? in
            guard let payload = observation.payloadStringValue else { return nil }
            return BarcodeResult(
                payload: payload,
                symbology: observation.symbology.rawValue,
                boundingBox: observation.boundingBox
            )
        }
        return RecognitionResult(textBlocks: textBlocks, barcodes: barcodes)
    }
}
