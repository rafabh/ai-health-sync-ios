// Copyright 2026 Marcus Neves
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct CockpitSyncSection: View {
    @Environment(AppState.self) private var appState

    @State private var selectedDays: Int = 7
    @State private var isConfigured: Bool = true
    @State private var showingSetup: Bool = false
    @State private var syncDelta: SyncDelta?
    @State private var isLoadingDelta: Bool = false
    @State private var isDeltaExpanded: Bool = true
    private let dayOptions = [1, 3, 7, 14, 30, 90, 180]

    var body: some View {
        Section("Cockpit Executivo") {
            if !isConfigured {
                setupPrompt
            } else {
                syncStatusRow
                deltaRow
                incrementalButton
                windowPicker
                windowButton
                progressRow
                resultRow
                reconfigureButton
            }
        }
        .animation(.smooth, value: appState.isCockpitSyncing)
        .animation(.smooth, value: appState.cockpitSyncResult != nil)
        .task { await checkConfiguration() }
        .sheet(isPresented: $showingSetup) { CockpitSetupView(isConfigured: $isConfigured) }
    }

    // MARK: - Setup

    private var setupPrompt: some View {
        Button {
            showingSetup = true
        } label: {
            Label("Configure Cockpit API Key", systemImage: "key.fill")
        }
        .liquidGlassButtonStyle(.prominent)
    }

    // MARK: - Sync Status

    private var syncStatusRow: some View {
        Group {
            if let lastSync = appState.syncConfiguration.lastCockpitSyncAt {
                let elapsed = Date().timeIntervalSince(lastSync)
                LabeledContent("Last Sync") {
                    VStack(alignment: .trailing) {
                        Text(lastSync.formatted(date: .abbreviated, time: .shortened))
                        Text(formatElapsed(elapsed))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                LabeledContent("Last Sync", value: "Never")
            }
        }
    }

    // MARK: - Delta

    @ViewBuilder
    private var deltaRow: some View {
        if isLoadingDelta {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking pending data...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let delta = syncDelta {
            if delta.totalPending == 0 {
                Label("All synced", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .onTapGesture { Task { await loadDelta() } }
            } else {
                DisclosureGroup(isExpanded: $isDeltaExpanded) {
                    ForEach(delta.types.filter { $0.pending > 0 }, id: \.name) { t in
                        HStack {
                            Text(t.name)
                                .font(.caption2)
                            Spacer()
                            Text("\(t.pending)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        }
                    }
                } label: {
                    Label("\(delta.totalPending) pending samples", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .onTapGesture { Task { await loadDelta() } }
            }
        } else {
            Button {
                Task { await loadDelta() }
            } label: {
                Label("Check pending data", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
        }
    }

    // MARK: - Buttons

    private var incrementalButton: some View {
        Button {
            HapticFeedback.impact(.medium)
            Task {
                await appState.sendIncremental()
                await loadDelta()
            }
        } label: {
            HStack(spacing: 8) {
                if appState.isCockpitSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Text("Sync Incremental")
            }
        }
        .liquidGlassButtonStyle(.prominent)
        .disabled(appState.isCockpitSyncing)
    }

    private var windowPicker: some View {
        Picker("Period", selection: $selectedDays) {
            ForEach(dayOptions, id: \.self) { days in
                Text("\(days)d").tag(days)
            }
        }
        .pickerStyle(.segmented)
    }

    private var windowButton: some View {
        Button {
            HapticFeedback.impact(.medium)
            Task {
                await appState.sendWindow(days: selectedDays)
                await loadDelta()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                Text("Send Last \(selectedDays) Days")
            }
        }
        .liquidGlassButtonStyle(.standard)
        .disabled(appState.isCockpitSyncing)
    }

    private var reconfigureButton: some View {
        Button {
            CockpitAPIClient.resetConfiguration()
            isConfigured = false
        } label: {
            Label("Reconfigure API Key", systemImage: "key.fill")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Progress & Result

    @ViewBuilder
    private var progressRow: some View {
        if appState.isCockpitSyncing, !appState.cockpitSyncProgress.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(appState.cockpitSyncProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var resultRow: some View {
        if let result = appState.cockpitSyncResult {
            resultView(result)
                .onTapGesture { appState.clearCockpitResult() }
        }
    }

    @ViewBuilder
    private func resultView(_ result: AppState.CockpitSyncResult) -> some View {
        switch result {
        case .success(let sent, let ingested, let skipped, let failed):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(sent) sent (\(ingested) ingested, \(skipped) skipped)")
                        .font(.caption)
                    if failed > 0 {
                        Text("\(failed) failed")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } icon: {
                Image(systemName: failed > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed > 0 ? .orange : .green)
            }

        case .noNewData:
            Label("All synced — no new data", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Helpers

    private func checkConfiguration() async {
        isConfigured = await appState.isCockpitConfigured
        if isConfigured {
            await loadDelta()
        }
    }

    private func loadDelta() async {
        isLoadingDelta = true
        defer { isLoadingDelta = false }
        syncDelta = await appState.fetchSyncDelta()
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

// MARK: - Delta Model

struct SyncDelta {
    struct TypeDelta {
        let name: String
        let pending: Int
        let since: Date
    }
    let types: [TypeDelta]
    var totalPending: Int { types.reduce(0) { $0 + $1.pending } }
}

// MARK: - Setup Sheet

struct CockpitSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var isConfigured: Bool
    @State private var apiKey: String = ""
    @State private var baseURL: String = "http://srv1421979.hstgr.cloud"
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("VPS Connection") {
                    TextField("Base URL", text: $baseURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField("API Key", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Section {
                    Button("Save to Keychain") {
                        save()
                    }
                    .disabled(apiKey.isEmpty)
                }
            }
            .navigationTitle("Cockpit Setup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func save() {
        do {
            try CockpitAPIClient.configure(apiKey: apiKey, baseURL: baseURL)
            isConfigured = true
            dismiss()
        } catch {
            self.error = "Failed to save: \(error.localizedDescription)"
        }
    }
}
