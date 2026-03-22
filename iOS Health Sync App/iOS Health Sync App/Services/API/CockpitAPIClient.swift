// Copyright 2026 Marcus Neves
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

actor CockpitAPIClient {
    private static let baseURL = "http://srv1421979.hstgr.cloud"
    private static let apiKey = "healthsync-vps-a95c359b77d47005e25b6164f96c013b"
    private static let batchSize = 100

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Last Sync

    struct LastSyncResponse: Codable, Sendable {
        let ok: Bool
        let lastSync: [String: LastSyncEntry]
    }

    struct LastSyncEntry: Codable, Sendable {
        let lastTime: String
        let date: String
        let sampleId: String
    }

    func fetchLastSync() async throws -> [String: Date] {
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/healthsync/last-sync")!)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CockpitError.serverError(statusCode: code)
        }

        let result = try decoder.decode(LastSyncResponse.self, from: data)
        guard result.ok else {
            throw CockpitError.serverError(statusCode: 0)
        }

        let iso = ISO8601DateFormatter()
        var dates: [String: Date] = [:]
        for (type, entry) in result.lastSync {
            if let date = iso.date(from: entry.lastTime) {
                dates[type] = date
            }
        }
        return dates
    }

    // MARK: - Ingest

    struct IngestPayload: Codable, Sendable {
        let samples: [HealthSampleDTO]
    }

    struct IngestResponse: Codable, Sendable {
        let ok: Bool
        let ingested: Int?
        let skipped: Int?
    }

    struct SendResult: Sendable {
        var totalSent: Int = 0
        var totalIngested: Int = 0
        var totalSkipped: Int = 0
        var totalFailed: Int = 0
        var batchesSent: Int = 0
    }

    func sendSamples(_ samples: [HealthSampleDTO], onBatchSent: (@Sendable (Int, Int) -> Void)? = nil) async throws -> SendResult {
        var result = SendResult()
        let batches = stride(from: 0, to: samples.count, by: Self.batchSize).map {
            Array(samples[$0..<min($0 + Self.batchSize, samples.count)])
        }

        let logger = Logger(subsystem: "com.rafael.healthsync", category: "CockpitAPI")

        for (index, batch) in batches.enumerated() {
            do {
                let payload = IngestPayload(samples: batch)
                let body = try encoder.encode(payload)

                var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/healthsync/ingest")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(Self.apiKey, forHTTPHeaderField: "x-api-key")
                request.httpBody = body

                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse

                if http?.statusCode != 200 {
                    let responseBody = String(data: data, encoding: .utf8) ?? "no body"
                    logger.error("Batch \(index + 1)/\(batches.count) failed with status \(http?.statusCode ?? 0): \(responseBody)")
                    result.totalFailed += batch.count
                    onBatchSent?(result.totalSent + result.totalFailed, samples.count)
                    continue
                }

                let ingestResult = try decoder.decode(IngestResponse.self, from: data)
                result.totalSent += batch.count
                result.totalIngested += ingestResult.ingested ?? 0
                result.totalSkipped += ingestResult.skipped ?? 0
                result.batchesSent += 1

                logger.info("Batch \(index + 1)/\(batches.count): ingested=\(ingestResult.ingested ?? 0) skipped=\(ingestResult.skipped ?? 0)")
            } catch {
                logger.error("Batch \(index + 1)/\(batches.count) error: \(error.localizedDescription)")
                result.totalFailed += batch.count
            }

            onBatchSent?(result.totalSent + result.totalFailed, samples.count)
        }

        return result
    }
}

enum CockpitError: LocalizedError {
    case serverError(statusCode: Int)
    case ingestFailed

    var errorDescription: String? {
        switch self {
        case .serverError(let code):
            return "Server returned status \(code)"
        case .ingestFailed:
            return "Ingest request failed"
        }
    }
}
