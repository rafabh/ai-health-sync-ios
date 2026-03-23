// Copyright 2026 Marcus Neves
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

actor CockpitAPIClient {
    private static let keychainService = "com.rafael.healthsync.cockpit"
    private static let keychainAccountAPIKey = "api-key"
    private static let keychainAccountBaseURL = "base-url"
    private static let defaultBaseURL = "http://srv1421979.hstgr.cloud"
    private static let batchSize = 500

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.rafael.healthsync", category: "CockpitAPI")

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Configuration

    private var baseURL: String {
        if let data = try? KeychainStore.load(service: Self.keychainService, account: Self.keychainAccountBaseURL),
           let url = String(data: data, encoding: .utf8) {
            return url
        }
        return Self.defaultBaseURL
    }

    private var apiKey: String? {
        guard let data = try? KeychainStore.load(service: Self.keychainService, account: Self.keychainAccountAPIKey) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Saves the API key and optional base URL to Keychain.
    /// Call once during setup.
    static func configure(apiKey: String, baseURL: String? = nil) throws {
        try KeychainStore.save(
            Data(apiKey.utf8),
            service: keychainService,
            account: keychainAccountAPIKey
        )
        if let baseURL {
            try KeychainStore.save(
                Data(baseURL.utf8),
                service: keychainService,
                account: keychainAccountBaseURL
            )
        }
    }

    var isConfigured: Bool {
        apiKey != nil
    }

    /// Removes stored credentials so the setup sheet reappears.
    static func resetConfiguration() {
        KeychainStore.delete(service: keychainService, account: keychainAccountAPIKey)
        KeychainStore.delete(service: keychainService, account: keychainAccountBaseURL)
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
        var request = URLRequest(url: URL(string: "\(baseURL)/api/healthsync/last-sync")!)
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

    // MARK: - Errors

    struct ErrorsResponse: Codable, Sendable {
        let ok: Bool
        let errors: [IngestError]
        let total: Int
    }

    struct IngestError: Codable, Sendable, Identifiable {
        let id: Int
        let timestamp: String
        let sampleType: String?
        let sampleId: String?
        let errorMessage: String
    }

    func fetchErrors(limit: Int = 20) async throws -> [IngestError] {
        var request = URLRequest(url: URL(string: "\(baseURL)/api/healthsync/errors?limit=\(limit)")!)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }

        let result = try decoder.decode(ErrorsResponse.self, from: data)
        return result.errors
    }

    // MARK: - Ingest

    struct IngestPayload: Codable, Sendable {
        let samples: [HealthSampleDTO]
    }

    struct IngestResponse: Codable, Sendable {
        let ok: Bool
        let ingested: Int?
        let skipped: Int?
        let errors: Int?
    }

    struct SendResult: Sendable {
        var totalSent: Int = 0
        var totalIngested: Int = 0
        var totalSkipped: Int = 0
        var totalFailed: Int = 0
        var batchesSent: Int = 0
    }

    func sendSamples(_ samples: [HealthSampleDTO], onBatchSent: (@Sendable (Int, Int) -> Void)? = nil) async throws -> SendResult {
        guard let key = apiKey else {
            throw CockpitError.notConfigured
        }

        var result = SendResult()
        let batches = stride(from: 0, to: samples.count, by: Self.batchSize).map {
            Array(samples[$0..<min($0 + Self.batchSize, samples.count)])
        }

        for (index, batch) in batches.enumerated() {
            do {
                let payload = IngestPayload(samples: batch)
                let body = try encoder.encode(payload)

                var request = URLRequest(url: URL(string: "\(baseURL)/api/healthsync/ingest")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.httpBody = body

                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse

                if http?.statusCode == 401 {
                    throw CockpitError.unauthorized
                }

                if http?.statusCode != 200 {
                    let responseBody = String(data: data, encoding: .utf8) ?? "no body"
                    logger.error("Batch \(index + 1)/\(batches.count) failed [\(http?.statusCode ?? 0)]: \(responseBody)")
                    result.totalFailed += batch.count
                    onBatchSent?(result.totalSent + result.totalFailed, samples.count)
                    continue
                }

                let ingestResult = try decoder.decode(IngestResponse.self, from: data)
                result.totalSent += batch.count
                result.totalIngested += ingestResult.ingested ?? 0
                result.totalSkipped += ingestResult.skipped ?? 0
                result.totalFailed += ingestResult.errors ?? 0
                result.batchesSent += 1

                logger.info("Batch \(index + 1)/\(batches.count): ingested=\(ingestResult.ingested ?? 0) skipped=\(ingestResult.skipped ?? 0)")
            } catch let error as CockpitError {
                throw error // Re-throw auth errors — don't continue
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
    case unauthorized
    case notConfigured
    case ingestFailed

    var errorDescription: String? {
        switch self {
        case .serverError(let code):
            return "Server returned status \(code)"
        case .unauthorized:
            return "API key rejected (401). Check configuration."
        case .notConfigured:
            return "Cockpit API key not configured. Go to Settings."
        case .ingestFailed:
            return "Ingest request failed"
        }
    }
}
