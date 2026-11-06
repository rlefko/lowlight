// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import LowlightAudio
import LowlightPlanning
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsAbout = false
    @State private var showsControls = false
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
                    primaryControls
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
            .sheet(isPresented: $showsControls, onDismiss: { model.commitControls() }) {
                ListeningControlsSheet(model: model)
            }
        }
    }

    private var primaryControls: some View {
        VStack(spacing: 24) {
            Menu {
                ForEach(Preset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) { model.selectPreset(preset) }
                }
            } label: {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text("Preset: \(model.presetName)")
                            .multilineTextAlignment(.center)
                    } else {
                        Label(
                            "Preset: \(model.presetName)", systemImage: "line.3.horizontal.decrease"
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("Preset")
            .accessibilityValue(model.presetName)
            .accessibilityIdentifier("presetPicker")
            ListeningControlSlider(
                title: "Energy", value: model.controls.energy, range: 0...1,
                valueText: "\(Int((model.controls.energy * 100).rounded()))%",
                identifier: "energySlider", preview: { preview(\.energy, value: $0) },
                commit: model.commitControls)
            ListeningControlSlider(
                title: "Mood", value: model.controls.mood, range: -1...1,
                valueText: moodText, identifier: "moodSlider",
                lowerLabel: "Reflective", upperLabel: "Bright",
                preview: { preview(\.mood, value: $0) }, commit: model.commitControls)
            Button("More Controls", systemImage: "slider.horizontal.3") { showsControls = true }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("moreControlsButton")
        }
        .disabled(!model.canEditControls)
    }

    private var moodText: String {
        let amount = Int((abs(model.controls.mood) * 100).rounded())
        guard amount != 0 else { return "Neutral" }
        return "\(amount)% \(model.controls.mood < 0 ? "reflective" : "bright")"
    }

    private func preview(_ key: WritableKeyPath<Controls, Double>, value: Double) {
        var controls = model.controls
        controls[keyPath: key] = value
        model.previewControls(controls)
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
        if model.controlsFailed, !model.isStartingNewSession {
            Button("Retry Changes") { model.retryControls() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("retryControlsButton")
        }
        if model.playback?.preparationStatus == .waitingForRetry, !model.isStartingNewSession {
            Button("Retry Next Song") { model.retryPreparation() }
                .buttonStyle(.bordered)
        }
        if model.playback?.audioSessionError != nil {
            VStack(spacing: 8) {
                Text("Audio couldn’t finish stopping.")
                Button(model.isStartingNewSession ? "Retry Stopping Audio" : "Try Pausing Again") {
                    model.retryCleanup()
                }
                .buttonStyle(.bordered)
            }
            .multilineTextAlignment(.center)
        }
        if model.canStartNewSession {
            VStack(spacing: 8) {
                Text("Keep your settings and discard your saved place. Press Play to begin again.")
                Button("Start a New Session") { model.startNewSession() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("startNewSessionButton")
            }
            .multilineTextAlignment(.center)
        }
        if model.saveFailed {
            VStack(spacing: 8) {
                Text("Your settings and place couldn’t be saved. You can keep listening.")
                Button("Retry Saving") { model.retrySave() }
                    .buttonStyle(.bordered)
            }
            .multilineTextAlignment(.center)
        }
    }
}

/// Touch dragging previews only. An accessibility adjustment commits one complete
/// snapshot explicitly, without depending on the order of native drag callbacks.
private struct ListeningControlSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    let valueText: String
    let identifier: String
    var lowerLabel: String?
    var upperLabel: String?
    let preview: (Double) -> Void
    let commit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(valueText).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text(valueText).foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
            Slider(
                value: Binding(get: { value }, set: { preview(quantized($0)) }),
                in: range, step: step,
                onEditingChanged: { if !$0 { commit() } }
            )
            .accessibilityLabel(title)
            .accessibilityValue(valueText)
            .accessibilityIdentifier(identifier)
            .accessibilityAdjustableAction { direction in
                let delta: Double
                switch direction {
                case .increment: delta = step
                case .decrement: delta = -step
                @unknown default: return
                }
                preview(quantized(value + delta))
                commit()
            }
            if let lowerLabel, let upperLabel {
                HStack {
                    Text(lowerLabel)
                    Spacer()
                    Text(upperLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
        }
    }

    private func quantized(_ value: Double) -> Double {
        let scale = 1 / step
        return (min(range.upperBound, max(range.lowerBound, value)) * scale).rounded() / scale
    }

}

private struct ListeningControlsSheet: View {
    let model: ListeningModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Form {
                Section("Tempo") {
                    Toggle(
                        "Auto Tempo",
                        isOn: Binding(
                            get: { model.controls.tempo == nil },
                            set: {
                                var controls = model.controls
                                controls.tempo = $0 ? nil : (64 + 34 * controls.energy).rounded()
                                model.previewControls(controls)
                                model.commitControls()
                            })
                    )
                    .accessibilityIdentifier("autoTempoToggle")
                    if let tempo = model.controls.tempo {
                        ListeningControlSlider(
                            title: "Tempo", value: tempo, range: 60...100, step: 1,
                            valueText: "\(Int(tempo.rounded())) BPM", identifier: "tempoSlider",
                            preview: {
                                var controls = model.controls
                                controls.tempo = $0
                                model.previewControls(controls)
                            }, commit: model.commitControls)
                    } else {
                        Text("Auto follows Energy.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ListeningControlSlider(
                        title: "Variation", value: model.controls.variation, range: 0...1,
                        valueText: "\(Int((model.controls.variation * 100).rounded()))%",
                        identifier: "variationSlider",
                        preview: {
                            var controls = model.controls
                            controls.variation = $0
                            model.previewControls(controls)
                        }, commit: model.commitControls)
                } footer: {
                    Text(
                        "Shape how much the music changes between pieces. New pieces keep playing at every setting."
                    )
                }
            }
            .disabled(!model.canEditControls)
            .navigationTitle("Listening Controls")
            .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.commitControls()
                        dismiss()
                    }
                }
            }
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
                    Text(
                        "Choose a preset, shape the music, or move into the next piece at a musical phrase."
                    )
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
