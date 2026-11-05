// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import LowlightAudio
import SwiftUI

@main
struct LowlightApp: App {
    @State private var model = ListeningModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ListeningView(model: model)
                .task { model.load() }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.sceneActive(phase == .active)
                }
        }
    }
}

private struct ListeningView: View {
    let model: ListeningModel
    @State private var showsAbout = false
    @ScaledMetric private var illustrationSize = 88

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: min(illustrationSize, 112), weight: .ultraLight))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(spacing: 12) {
                        Text("A little room to unwind")
                            .font(.title2)
                        Text(model.statusText)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("listeningStatus")
                    }
                    .multilineTextAlignment(.center)
                    if model.loadFailed {
                        VStack(spacing: 12) {
                            Button("Try Restoring Again") { model.load() }
                                .buttonStyle(.borderedProminent)
                            Button("Start a Fresh Session") { model.startFresh() }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) { transportButtons }
                            VStack(spacing: 16) { transportButtons }
                        }
                        .controlSize(.large)
                    }
                    recoveryActions
                    Text("Original lo-fi, entirely offline")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 480)
                .padding(32)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Lowlight")
            .toolbar {
                Button("About", systemImage: "info.circle") { showsAbout = true }
                    .accessibilityIdentifier("aboutButton")
            }
            .sheet(isPresented: $showsAbout) { AboutView() }
        }
    }

    @ViewBuilder private var transportButtons: some View {
        Button(
            model.primaryActionIsPause ? "Pause" : "Play",
            systemImage: model.primaryActionIsPause ? "pause.fill" : "play.fill"
        ) {
            model.togglePlayback()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canPlay)
        .accessibilityIdentifier("playPauseButton")
        Button("Next", systemImage: "forward.end.fill") { model.next() }
            .buttonStyle(.bordered)
            .disabled(!model.canRequestNext)
            .accessibilityHint("Changes with the next available musical phrase")
            .accessibilityIdentifier("nextButton")
    }

    @ViewBuilder private var recoveryActions: some View {
        if model.playback?.preparationStatus == .waitingForRetry {
            Button("Retry Next Song") { model.retryPreparation() }
                .buttonStyle(.bordered)
        }
        if model.playback?.audioSessionError != nil {
            VStack(spacing: 8) {
                Text("Audio couldn’t finish stopping.")
                Button("Try Pausing Again") { model.retryCleanup() }
                    .buttonStyle(.bordered)
            }
            .multilineTextAlignment(.center)
        }
        if model.saveFailed {
            VStack(spacing: 8) {
                Text("Your place couldn’t be saved. You can keep listening.")
                Button("Retry Saving") { model.retrySave() }
                    .buttonStyle(.bordered)
            }
            .multilineTextAlignment(.center)
        }
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Lowlight") {
                    Text("An offline home for original lo-fi music.")
                    Text("Play, pause, or move into the next piece at a musical phrase.")
                }
                Section("Credits") {
                    Text("Copyright © 2026 Ryan Lefkowitz")
                    Text("Development accelerated with Codex")
                }
                Section("License") {
                    Text("Original code: GNU General Public License v3.0 only (GPL-3.0-only).")
                    Text("This program comes with no warranty.")
                }
                Section("Sound Library") {
                    Text(
                        "Recordings from FreePats Electric Guitar FSBS (jazz), VSCO 2 CE, and VCSL use CC0-1.0."
                    )
                    NavigationLink("Sound library licenses") {
                        ScrollView {
                            Text(soundLibraryNotices).textSelection(.enabled).padding()
                        }
                        .navigationTitle("Sound Licenses")
                    }
                }
                Section("Software") {
                    NavigationLink("Software notices") {
                        ScrollView {
                            Text(softwareNotices).textSelection(.enabled).padding()
                                .accessibilityIdentifier("softwareNoticeText")
                        }
                        .navigationTitle("Software Notices")
                    }
                    .accessibilityIdentifier("softwareNoticesLink")
                }
            }
            .navigationTitle("About Lowlight")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var soundLibraryNotices: String {
        ["FreePats_Electric_Jazz_README", "FreePats_Electric_Jazz_LICENSE", "VSCO_CC0", "VCSL_CC0"]
            .map { name in
                guard
                    let url = Bundle.main.url(
                        forResource: name, withExtension: "txt", subdirectory: "SoundBank/licenses"),
                    let text = try? String(contentsOf: url, encoding: .utf8)
                else { return "License text is unavailable. Please reinstall the app." }
                return text
            }.joined(separator: "\n\n")
    }

    private var softwareNotices: String {
        ["NumPy-Random-Notices", "Pyloudnorm-Notices"].map { name in
            guard
                let url = Bundle.main.url(
                    forResource: name, withExtension: "txt", subdirectory: "ThirdParty"),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { return "Software notices are unavailable. Please reinstall the app." }
            return text
        }.joined(separator: "\n\n")
    }
}
