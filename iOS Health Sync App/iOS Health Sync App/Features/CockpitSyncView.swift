// Copyright 2026 Marcus Neves
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct CockpitSyncSection: View {
    @Environment(AppState.self) private var appState

    @State private var selectedDays: Int = 7
    private let dayOptions = [1, 3, 7, 14, 30, 90]

    var body: some View {
        Section("Cockpit Executivo") {
            // Last sync info
            if let lastSync = appState.syncConfiguration.lastCockpitSyncAt {
                LabeledContent("Last Sync", value: lastSync.formatted(date: .abbreviated, time: .shortened))
            }

            // Incremental sync button
            Button {
                HapticFeedback.impact(.medium)
                Task { await appState.sendIncremental() }
            } label: {
                HStack(spacing: 8) {
                    if appState.isCockpitSyncing && appState.cockpitSyncProgress.contains("Checking") {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text("Sync Incremental")
                }
            }
            .liquidGlassButtonStyle(.prominent)
            .disabled(appState.isCockpitSyncing)

            // Manual window sync
            HStack {
                Picker("Period", selection: $selectedDays) {
                    ForEach(dayOptions, id: \.self) { days in
                        Text("\(days)d").tag(days)
                    }
                }
                .pickerStyle(.segmented)
            }

            Button {
                HapticFeedback.impact(.medium)
                Task { await appState.sendWindow(days: selectedDays) }
            } label: {
                HStack(spacing: 8) {
                    if appState.isCockpitSyncing && !appState.cockpitSyncProgress.contains("Checking") {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "calendar.badge.clock")
                    }
                    Text("Send Last \(selectedDays) Days")
                }
            }
            .liquidGlassButtonStyle(.standard)
            .disabled(appState.isCockpitSyncing)

            // Progress
            if appState.isCockpitSyncing, !appState.cockpitSyncProgress.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(appState.cockpitSyncProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Result feedback
            if let result = appState.cockpitSyncResult {
                resultView(result)
                    .onTapGesture { appState.clearCockpitResult() }
            }
        }
        .animation(.smooth, value: appState.isCockpitSyncing)
        .animation(.smooth, value: appState.cockpitSyncResult != nil)
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
            Label {
                Text("No new data to send")
                    .font(.caption)
            } icon: {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }

        case .error(let message):
            Label {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}
