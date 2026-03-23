// Copyright 2026 Marcus Neves
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import HealthKit
import Network
import Observation
import os
import SwiftData
import SwiftUI
import UIKit

@MainActor
@Observable
final class AppState {
    private let modelContainer: ModelContainer
    private let healthService = HealthKitService()
    private let auditService: AuditService
    private let pairingService: PairingService
    private let networkServer: NetworkServer
    private let backgroundTaskManager: BackgroundTaskManaging
    private let backgroundTaskController: BackgroundTaskController
    private var notificationTask: Task<Void, Never>?

    var syncConfiguration: SyncConfiguration
    var pairingQRCode: PairingQRCode?
    var isServerRunning: Bool = false
    var isServerStarting: Bool = false
    var isRefreshing: Bool = false
    var serverPort: Int = 0
    var serverFingerprint: String = ""
    var lastError: String?
    var protectedDataAvailable: Bool = true
    var healthAuthorizationStatus: Bool = false

    // Cockpit sync state
    private let cockpitClient = CockpitAPIClient()
    var isCockpitSyncing: Bool = false
    var cockpitSyncProgress: String = ""
    var cockpitSyncResult: CockpitSyncResult?

    enum CockpitSyncResult: Equatable {
        case success(sent: Int, ingested: Int, skipped: Int, failed: Int)
        case noNewData
        case error(String)
    }

    init(modelContainer: ModelContainer, backgroundTaskManager: BackgroundTaskManaging = UIApplication.shared) {
        self.modelContainer = modelContainer
        self.auditService = AuditService(modelContainer: modelContainer)
        self.pairingService = PairingService(modelContainer: modelContainer)
        self.backgroundTaskManager = backgroundTaskManager
        self.backgroundTaskController = BackgroundTaskController(manager: backgroundTaskManager)
        self.networkServer = NetworkServer(
            healthService: healthService,
            pairingService: pairingService,
            auditService: auditService,
            modelContainer: modelContainer,
            protectedDataAvailable: {
                await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
            },
            deviceNameProvider: {
                // Use anonymized device identifier to prevent PII exposure
                // Format: "HealthSync-XXXX" where XXXX is first 4 chars of hashed device ID
                await MainActor.run {
                    let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
                    let hash = SHA256.hash(data: Data(deviceId.utf8))
                    let shortHash = hash.prefix(4).map { String(format: "%02x", $0) }.joined()
                    return "HealthSync-\(shortHash.uppercased())"
                }
            },
            listenerPort: NWEndpoint.Port(rawValue: 48484)!
        )

        // Pre-warm TLS identity on a background thread to avoid first-run UI stalls.
        Task.detached(priority: .utility) {
            _ = try? CertificateService.loadOrCreateIdentity()
        }

        let context = modelContainer.mainContext
        do {
            if let existing = try context.fetch(FetchDescriptor<SyncConfiguration>()).first {
                self.syncConfiguration = existing
            } else {
                let newConfig = SyncConfiguration()
                context.insert(newConfig)
                try context.save()
                self.syncConfiguration = newConfig
            }
        } catch {
            AppLoggers.app.error("Failed to load or create SyncConfiguration: \(error.localizedDescription, privacy: .public)")
            // Fallback to in-memory config (not persisted)
            self.syncConfiguration = SyncConfiguration()
        }

        self.protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        self.backgroundTaskController.setOnExpiration { [weak self] in
            guard let self else { return }
            AppLoggers.app.info("Background time expired; stopping server for safety.")
            Task { await self.stopServer() }
        }
        // Cockpit API key is configured via the Setup sheet in CockpitSyncView (stored in Keychain).

        // Notification observers are started from the App entry point on the main actor.
    }

    deinit {}

    func startNotificationObservers() {
        guard notificationTask == nil else { return }

        notificationTask = Task { [weak self] in
            guard let self else { return }

            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await _ in NotificationCenter.default.notifications(
                        named: UIApplication.protectedDataDidBecomeAvailableNotification
                    ) {
                        await self?.handleProtectedDataAvailable()
                    }
                }

                group.addTask { [weak self] in
                    for await _ in NotificationCenter.default.notifications(
                        named: UIApplication.protectedDataWillBecomeUnavailableNotification
                    ) {
                        await self?.handleProtectedDataUnavailable()
                    }
                }

                group.addTask { [weak self] in
                    for await _ in NotificationCenter.default.notifications(
                        named: UIApplication.didBecomeActiveNotification
                    ) {
                        await self?.handleAppDidBecomeActive()
                    }
                }
            }
        }
    }

    func requestHealthAuthorization() async {
        do {
            guard await healthService.isAvailable() else {
                healthAuthorizationStatus = false
                lastError = "Health data is unavailable on this device."
                await auditService.record(eventType: "auth.healthkit", details: ["status": "unavailable"])
                return
            }

            // Show the authorization dialog
            let dialogShown = try await healthService.requestAuthorization(for: syncConfiguration.enabledTypes)

            // NOTE: For READ-only permissions, Apple hides whether user granted or denied.
            // requestAuthorization returns true if the dialog was shown successfully,
            // NOT whether the user approved. We can only know the dialog was presented.
            // Use hasRequestedAuthorization to verify the dialog was shown.
            healthAuthorizationStatus = await healthService.hasRequestedAuthorization(for: syncConfiguration.enabledTypes)

            await auditService.record(eventType: "auth.healthkit", details: [
                "dialogShown": String(dialogShown),
                "requested": String(healthAuthorizationStatus)
            ])
        } catch {
            lastError = "HealthKit authorization failed: \(error.localizedDescription)"
        }
    }

    private var isRunningInSimulator: Bool {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }

    func toggleType(_ type: HealthDataType, enabled: Bool) {
        var types = syncConfiguration.enabledTypes
        if enabled {
            if !types.contains(type) {
                types.append(type)
            }
        } else {
            types.removeAll { $0 == type }
        }
        syncConfiguration.enabledTypes = types
        do {
            try modelContainer.mainContext.save()
        } catch {
            AppLoggers.app.error("Failed to save type toggle: \(error.localizedDescription, privacy: .public)")
        }
    }

    func startServer() async {
        do {
            isServerStarting = true
            defer { isServerStarting = false }

            try await networkServer.start()
            isServerRunning = true
            let snapshot = await networkServer.snapshot()
            serverPort = snapshot.port
            serverFingerprint = snapshot.fingerprint
            AppLoggers.app.info("Server started - port: \(self.serverPort), fingerprint: \(self.serverFingerprint.prefix(16), privacy: .public)...")

            let host = await Task.detached(priority: .utility) {
                Self.localIPAddress() ?? "127.0.0.1"
            }.value
            AppLoggers.app.info("Resolved host IP: \(host, privacy: .public)")

            let qr = await pairingService.generateQRCode(host: host, port: serverPort, fingerprint: serverFingerprint)
            AppLoggers.app.info("Generated pairing QR code; expires: \(qr.expiresAt, privacy: .public)")
            pairingQRCode = qr

            await auditService.record(eventType: "api.server_start", details: ["port": String(serverPort)])
            // Prevent auto-lock while actively sharing.
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            isServerStarting = false
            lastError = "Failed to start server: \(error.localizedDescription)"
            AppLoggers.app.error("Server start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopServer() async {
        await networkServer.stop()
        isServerRunning = false
        serverPort = 0
        pairingQRCode = nil
        await auditService.record(eventType: "api.server_stop", details: [:])
        backgroundTaskController.endIfNeeded()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func refreshPairingCode() async {
        guard isServerRunning else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let host = await Task.detached(priority: .utility) {
            Self.localIPAddress() ?? "127.0.0.1"
        }.value
        pairingQRCode = await pairingService.generateQRCode(host: host, port: serverPort, fingerprint: serverFingerprint)
    }

    func revokeAllPairings() async {
        await pairingService.revokeAll()
        await auditService.record(eventType: "auth.revoke", details: [:])
    }

    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            backgroundTaskController.endIfNeeded()
        case .background:
            guard isServerRunning else { return }
            // Background tasks are time-limited; this is a best-effort grace period.
            // If the system denies the task, the OS may suspend networking shortly after.
            if !backgroundTaskController.beginIfNeeded() {
                AppLoggers.app.info("Background task denied; sharing may pause while app is suspended.")
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    nonisolated private static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer = firstAddr
        while true {
            let interface = pointer.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var addr = interface.ifa_addr.pointee
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                        let bytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                        address = String(decoding: bytes, as: UTF8.self)
                        break
                    }
                }
            }
            if let next = interface.ifa_next {
                pointer = next
            } else {
                break
            }
        }
        return address
    }

    // MARK: - Cockpit Sync

    /// Fetches all samples for a type with pagination (no 5000 limit).
    private func fetchAllSamples(type: HealthDataType, startDate: Date, endDate: Date) async -> [HealthSampleDTO] {
        var allSamples: [HealthSampleDTO] = []
        var offset = 0
        let pageSize = 5000

        while true {
            let response = await healthService.fetchSamples(
                types: [type], startDate: startDate, endDate: endDate, limit: pageSize, offset: offset
            )
            allSamples.append(contentsOf: response.samples)

            guard response.hasMore else { break }
            offset += pageSize
        }

        return allSamples
    }

    /// Sends samples for a single type to the VPS, streaming per-type to avoid memory buildup.
    private func sendTypeToVPS(type: HealthDataType, samples: [HealthSampleDTO], cumulativeSent: Int, totalEstimate: Int) async throws -> CockpitAPIClient.SendResult {
        cockpitSyncProgress = "Sending \(type.displayName) (\(samples.count))..."
        var offset = cumulativeSent
        let result = try await cockpitClient.sendSamples(samples) { sent, _ in
            Task { @MainActor in
                self.cockpitSyncProgress = "Sent \(offset + sent)/\(totalEstimate)..."
            }
        }
        return result
    }

    /// Sends only new data since the last sync for each type.
    /// Queries VPS `/api/healthsync/last-sync`, with fallback to local lastCockpitSyncAt.
    func sendIncremental() async {
        guard !isCockpitSyncing else { return }
        isCockpitSyncing = true
        cockpitSyncResult = nil
        cockpitSyncProgress = "Checking last sync..."
        defer { isCockpitSyncing = false }

        do {
            // Try VPS first, fallback to local
            var lastSyncDates: [String: Date]
            do {
                lastSyncDates = try await cockpitClient.fetchLastSync()
            } catch {
                AppLoggers.app.warning("Failed to fetch last-sync from VPS, using local fallback: \(error.localizedDescription, privacy: .public)")
                let fallbackDate = syncConfiguration.lastCockpitSyncAt ?? Date().addingTimeInterval(-86400)
                lastSyncDates = Dictionary(uniqueKeysWithValues: syncConfiguration.enabledTypes.map { ($0.rawValue, fallbackDate) })
            }

            let enabledTypes = syncConfiguration.enabledTypes
            let now = Date()
            var aggregate = CockpitAPIClient.SendResult()
            var totalFetched = 0

            // Fetch counts first for progress estimate
            for type in enabledTypes {
                let startDate = lastSyncDates[type.rawValue] ?? now.addingTimeInterval(-86400)
                cockpitSyncProgress = "Fetching \(type.displayName)..."
                let samples = await fetchAllSamples(type: type, startDate: startDate, endDate: now)

                if samples.isEmpty { continue }
                totalFetched += samples.count

                let result = try await sendTypeToVPS(type: type, samples: samples, cumulativeSent: aggregate.totalSent + aggregate.totalFailed, totalEstimate: totalFetched)
                aggregate.totalSent += result.totalSent
                aggregate.totalIngested += result.totalIngested
                aggregate.totalSkipped += result.totalSkipped
                aggregate.totalFailed += result.totalFailed
                aggregate.batchesSent += result.batchesSent
            }

            if aggregate.totalSent == 0 && aggregate.totalFailed == 0 {
                cockpitSyncResult = .noNewData
                cockpitSyncProgress = ""
                return
            }

            syncConfiguration.lastCockpitSyncAt = now
            syncConfiguration.lastExportAt = now
            try modelContainer.mainContext.save()

            await auditService.record(eventType: "cockpit.sync", details: [
                "mode": "incremental",
                "sent": String(aggregate.totalSent),
                "ingested": String(aggregate.totalIngested),
                "skipped": String(aggregate.totalSkipped),
                "failed": String(aggregate.totalFailed)
            ])

            cockpitSyncResult = .success(sent: aggregate.totalSent, ingested: aggregate.totalIngested, skipped: aggregate.totalSkipped, failed: aggregate.totalFailed)
            cockpitSyncProgress = ""
        } catch {
            cockpitSyncResult = .error(error.localizedDescription)
            cockpitSyncProgress = ""
            AppLoggers.app.error("Cockpit incremental sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sends all health data from the last N days.
    func sendWindow(days: Int) async {
        guard !isCockpitSyncing else { return }
        isCockpitSyncing = true
        cockpitSyncResult = nil
        cockpitSyncProgress = "Fetching last \(days) days..."
        defer { isCockpitSyncing = false }

        do {
            let now = Date()
            let startDate = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
            let enabledTypes = syncConfiguration.enabledTypes
            var aggregate = CockpitAPIClient.SendResult()
            var totalFetched = 0

            for type in enabledTypes {
                cockpitSyncProgress = "Fetching \(type.displayName)..."
                let samples = await fetchAllSamples(type: type, startDate: startDate, endDate: now)

                if samples.isEmpty { continue }
                totalFetched += samples.count

                let result = try await sendTypeToVPS(type: type, samples: samples, cumulativeSent: aggregate.totalSent + aggregate.totalFailed, totalEstimate: totalFetched)
                aggregate.totalSent += result.totalSent
                aggregate.totalIngested += result.totalIngested
                aggregate.totalSkipped += result.totalSkipped
                aggregate.totalFailed += result.totalFailed
                aggregate.batchesSent += result.batchesSent
            }

            if aggregate.totalSent == 0 && aggregate.totalFailed == 0 {
                cockpitSyncResult = .noNewData
                cockpitSyncProgress = ""
                return
            }

            syncConfiguration.lastCockpitSyncAt = now
            syncConfiguration.lastExportAt = now
            try modelContainer.mainContext.save()

            await auditService.record(eventType: "cockpit.sync", details: [
                "mode": "window",
                "days": String(days),
                "sent": String(aggregate.totalSent),
                "ingested": String(aggregate.totalIngested),
                "skipped": String(aggregate.totalSkipped),
                "failed": String(aggregate.totalFailed)
            ])

            cockpitSyncResult = .success(sent: aggregate.totalSent, ingested: aggregate.totalIngested, skipped: aggregate.totalSkipped, failed: aggregate.totalFailed)
            cockpitSyncProgress = ""
        } catch {
            cockpitSyncResult = .error(error.localizedDescription)
            cockpitSyncProgress = ""
            AppLoggers.app.error("Cockpit window sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clearCockpitResult() {
        cockpitSyncResult = nil
    }

    /// Check if Cockpit API is configured (API key in Keychain).
    var isCockpitConfigured: Bool {
        get async { await cockpitClient.isConfigured }
    }

    /// Fetches sync delta: how many samples are pending per enabled type.
    func fetchSyncDelta() async -> SyncDelta? {
        guard let lastSyncDates = try? await cockpitClient.fetchLastSync() else { return nil }

        // Only check types the VPS actually accepts (has entries in last-sync or is in enabledTypes AND known by VPS)
        let vpsKnownTypes = Set(lastSyncDates.keys)
        let enabledTypes = syncConfiguration.enabledTypes.filter { vpsKnownTypes.contains($0.rawValue) || lastSyncDates[$0.rawValue] != nil }
        let now = Date()
        var types: [SyncDelta.TypeDelta] = []

        for type in enabledTypes {
            let lastSync = lastSyncDates[type.rawValue] ?? Date.distantPast
            let response = await healthService.fetchSamples(
                types: [type], startDate: lastSync, endDate: now, limit: 5000, offset: 0
            )
            if response.returnedCount > 0 {
                types.append(.init(name: type.displayName, pending: response.returnedCount, since: lastSync))
            }
        }

        return SyncDelta(types: types)
    }

    private func handleProtectedDataAvailable() {
        protectedDataAvailable = true
    }

    private func handleProtectedDataUnavailable() {
        protectedDataAvailable = false
    }

    private func handleAppDidBecomeActive() {
        // Refresh protected data status when app becomes active
        // The initial check in init() may run before UIApplication is ready
        protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable

        // Also refresh HealthKit authorization status
        Task { await refreshHealthAuthorizationStatus() }
    }

    private func refreshHealthAuthorizationStatus() async {
        guard await healthService.isAvailable() else {
            healthAuthorizationStatus = false
            return
        }

        // NOTE: For READ-only permissions, Apple hides whether user granted or denied.
        // We can only check if we've REQUESTED authorization (user saw the dialog).
        // This is Apple's privacy design - apps can't know if health data access was denied.
        healthAuthorizationStatus = await healthService.hasRequestedAuthorization(for: syncConfiguration.enabledTypes)
    }
}
