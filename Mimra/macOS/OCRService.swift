// ==============================================================================
// Mimra — On-Device Vision OCR Service
// Asynchronous text recognition on background actor with automatic language detection,
// cooperative cancellation, and direct FTS5 index synchronization in RustCore.
// Linked Features: F-043, F-044, F-051
// Test IDs: T-OCR-01, T-OCR-02, T-SRCH-04
// ==============================================================================

import AppKit
import Foundation
import os.log
@preconcurrency import Vision

private let logger = Logger(subsystem: "com.mimra.app", category: "OCRService")

/// Typed, descriptive errors for OCR operations with explanatory failure messages.
public enum OCRError: LocalizedError, Sendable {
    case invalidImageData
    case cancelled
    case visionFailure(details: String)
    case storageFailure(details: String)

    public var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Failed to perform OCR: Supplied image payload bytes could not be decoded or were empty."
        case .cancelled:
            return "OCR operation was cancelled before completion."
        case .visionFailure(let details):
            return "Apple Vision text recognition failed: \(details)"
        case .storageFailure(let details):
            return "Failed to synchronize extracted OCR text with SQLite storage: \(details)"
        }
    }
}

/// Thread-safe wrapper holding an active Vision request for hardware cancellation across concurrency contexts.
final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: VNRecognizeTextRequest?

    func setRequest(_ req: VNRecognizeTextRequest) {
        lock.lock()
        defer { lock.unlock() }
        _request = req
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        _request?.cancel()
    }
}

/// Actor managing background on-device Apple Vision text recognition requests.
/// Offloads CPU/GPU/Neural Engine compute completely from the main thread.
public actor OCRService {
    public static let shared = OCRService()

    /// Active in-flight recognition tasks keyed by history item ID.
    private var activeTasks: [String: Task<String, any Error>] = [:]

    /// Active Vision request wrappers keyed by history item ID for explicit cancellation.
    private var activeBoxes: [String: RequestBox] = [:]

    public init() {}

    /// Checks if a recognition task is currently active for the given item ID.
    public func isProcessing(itemId: String) -> Bool {
        return activeTasks[itemId] != nil
    }

    /// Number of active OCR tasks currently in progress.
    public var activeTaskCount: Int {
        return activeTasks.count
    }

    /// Cancels an active in-flight OCR task for a specific item ID.
    public func cancel(itemId: String) {
        if let box = activeBoxes[itemId] {
            box.cancel()
            activeBoxes.removeValue(forKey: itemId)
        }
        if let task = activeTasks[itemId] {
            task.cancel()
            activeTasks.removeValue(forKey: itemId)
            logger.info("Cancelled OCR task for item ID \(itemId, privacy: .public)")
        }
    }

    /// Cancels all active in-flight OCR tasks.
    public func cancelAll() {
        for (_, box) in activeBoxes {
            box.cancel()
        }
        activeBoxes.removeAll()

        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
        logger.info("Cancelled all in-flight OCR tasks.")
    }

    /// Performs on-device Vision text recognition on the provided image payload.
    ///
    /// - Parameters:
    ///   - imageData: Raw image byte payload (PNG, JPEG, TIFF, HEIC).
    ///   - itemId: Optional UUID string tracking this task for lifecycle management and cancellation.
    ///   - languages: Optional list of language hints; if nil, relies on automatic language detection.
    /// - Returns: Extracted and normalized plain text recognized in the image.
    public func recognizeText(
        in imageData: Data,
        itemId: String? = nil,
        languages: [String]? = nil
    ) async throws -> String {
        guard !imageData.isEmpty else {
            throw OCRError.invalidImageData
        }

        if Task.isCancelled {
            throw OCRError.cancelled
        }

        let taskKey = itemId ?? UUID().uuidString

        // If an existing task is in-flight for this item ID, await its completion to avoid duplicate computation
        if let existingTask = activeTasks[taskKey] {
            return try await existingTask.value
        }

        let box = RequestBox()
        activeBoxes[taskKey] = box

        let task = Task.detached(priority: .userInitiated) {
            if Task.isCancelled {
                throw OCRError.cancelled
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate

            if #available(macOS 13.0, *) {
                request.automaticallyDetectsLanguage = true
            }

            if let customLangs = languages, !customLangs.isEmpty {
                request.recognitionLanguages = customLangs
            } else {
                request.recognitionLanguages = [
                    "en-US", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "zh-Hans", "zh-Hant", "ja-JP", "ko-KR"
                ]
            }

            box.setRequest(request)

            if Task.isCancelled {
                throw OCRError.cancelled
            }

            let handler = VNImageRequestHandler(data: imageData, options: [:])
            let startUptime = DispatchTime.now().uptimeNanoseconds

            do {
                try handler.perform([request])
            } catch {
                if Task.isCancelled {
                    throw OCRError.cancelled
                }
                throw OCRError.visionFailure(details: error.localizedDescription)
            }

            if Task.isCancelled {
                throw OCRError.cancelled
            }

            guard let observations = request.results else {
                return ""
            }

            var recognizedLines: [String] = []
            for observation in observations {
                if let candidate = observation.topCandidates(1).first {
                    let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        recognizedLines.append(trimmed)
                    }
                }
            }

            let fullText = recognizedLines.joined(separator: "\n").precomposedStringWithCanonicalMapping
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startUptime) / 1_000_000.0

            logger.info("OCR completed in \(elapsedMs, format: .fixed(precision: 1))ms: recognized \(fullText.count, privacy: .public) chars across \(recognizedLines.count, privacy: .public) lines")

            return fullText
        }

        activeTasks[taskKey] = task

        defer {
            activeBoxes.removeValue(forKey: taskKey)
            activeTasks.removeValue(forKey: taskKey)
        }

        do {
            return try await task.value
        } catch {
            if Task.isCancelled {
                throw OCRError.cancelled
            }
            throw error
        }
    }

    /// Performs text recognition on an image payload and transactionally indexes the result in RustCore.
    ///
    /// - Parameters:
    ///   - itemId: UUID string of the history item in SQLite.
    ///   - imageData: Raw image byte payload.
    ///   - coreClient: The actor managing RustCore database access.
    ///   - languages: Optional language hints.
    /// - Returns: Extracted and saved plain text.
    public func recognizeAndIndex(
        itemId: String,
        imageData: Data,
        coreClient: CoreClient,
        languages: [String]? = nil
    ) async throws -> String {
        let extractedText = try await recognizeText(in: imageData, itemId: itemId, languages: languages)

        if Task.isCancelled {
            throw OCRError.cancelled
        }

        do {
            let wasUpdated = try await coreClient.updateOcrText(itemId: itemId, ocrText: extractedText)
            if !wasUpdated {
                logger.info("Item \(itemId, privacy: .public) was deleted before OCR completed. Extracted text discarded without resurrection.")
            }
            return extractedText
        } catch {
            throw OCRError.storageFailure(details: error.localizedDescription)
        }
    }
}
