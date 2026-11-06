// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Accessibility
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var showsAbout = false
    @State private var showsControls = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 0) {
                        horizonArt
                        VStack(alignment: .leading, spacing: 12) {
                            if model.loadFailed {
                                status
                                Button("Try Restoring Again") { model.load() }
                                    .buttonStyle(.borderedProminent)
                                Button("Start a Fresh Session") { model.startFresh() }
                                    .buttonStyle(.bordered)
                            } else {
                                FittingRow(spacing: 10) {
                                    status.frame(maxWidth: .infinity, alignment: .leading)
                                    FittingRow(spacing: 10) { transportButtons }
                                        .fixedSize(
                                            horizontal: !dynamicTypeSize.isAccessibilitySize,
                                            vertical: false)
                                }
                            }
                            recoveryActions
                        }
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: .rect(cornerRadius: 20)
                    )
                    .clipShape(.rect(cornerRadius: 20))
                    primaryControls
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Lowlight")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                Button("About", systemImage: "info.circle") { showsAbout = true }
                    .accessibilityIdentifier("aboutButton")
            }
            .sheet(isPresented: $showsAbout) { AboutView() }
            .sheet(isPresented: $showsControls, onDismiss: { model.commitControls() }) {
                ListeningControlsSheet(model: model)
            }
            .onChange(of: model.statusText) { _, message in
                guard voiceOver, scenePhase == .active, !showsAbout, !showsControls else { return }
                AccessibilityNotification.Announcement(message).post()
            }
        }
        .tint(
            colorScheme == .dark
                ? Color(red: 0.76, green: 0.71, blue: 0.83)
                : Color(red: 0.35, green: 0.31, blue: 0.44))
    }

    private var horizonArt: some View {
        HorizonMotionView(model: model, covered: showsAbout || showsControls)
            .frame(
                height: verticalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize
                    ? 72 : 148)
    }

    private var status: some View {
        Text(model.statusText)
            .font(.subheadline.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("listeningStatus")
    }

    private var presetPicker: some View {
        Menu {
            ForEach(Preset.allCases, id: \.self) { preset in
                Button {
                    model.selectPreset(preset)
                } label: {
                    if preset.rawValue == model.presetName {
                        Label(preset.rawValue, systemImage: "checkmark")
                    } else {
                        Text(preset.rawValue)
                    }
                }
                .accessibilityAddTraits(preset.rawValue == model.presetName ? .isSelected : [])
            }
        } label: {
            FittingRow(spacing: 4) {
                Text("Preset").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                presetValue
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(.rect)
        }
        .foregroundStyle(.primary)
        .menuOrder(.fixed)
        .accessibilityLabel("Preset")
        .accessibilityValue(model.presetName)
        .accessibilityIdentifier("presetPicker")
    }

    private var presetValue: some View {
        HStack(spacing: 6) {
            Text(model.presetName)
            Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
        }
        .foregroundStyle(.tint)
    }

    private var primaryControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            presetPicker
            Divider()
            VStack(spacing: 10) {
                ListeningEffectSlider(title: "Warmth", key: \.warmth, model: model)
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
            }
            .padding(.vertical, 14)
            Divider()
            Button {
                showsControls = true
            } label: {
                HStack {
                    Label("More Controls", systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(.rect)
            }
            .accessibilityIdentifier("moreControlsButton")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
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
        .foregroundStyle(Color(uiColor: .systemBackground))
        .fixedSize()
        .disabled(!model.canPlay)
        .accessibilityIdentifier("playPauseButton")
        Button("Next", systemImage: "forward.end.fill") { model.next() }
            .buttonStyle(.bordered)
            .fixedSize()
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Audio couldn’t finish stopping.")
                Button(model.isStartingNewSession ? "Retry Stopping Audio" : "Try Pausing Again") {
                    model.retryCleanup()
                }
                .buttonStyle(.bordered)
            }
        }
        if model.canStartNewSession {
            VStack(alignment: .leading, spacing: 8) {
                Text("Keep your settings and discard your saved place. Press Play to begin again.")
                Button("Start a New Session") { model.startNewSession() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("startNewSessionButton")
            }
        }
        if model.saveFailed {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your settings and place couldn’t be saved. You can keep listening.")
                Button("Retry Saving") { model.retrySave() }
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// Reflows the same accessibility elements when their labels outgrow the row.
private struct FittingRow: Layout {
    var spacing: CGFloat

    private func stack(width: CGFloat?, subviews: Subviews) -> AnyLayout {
        let row = AnyLayout(HStackLayout(spacing: spacing))
        var cache = row.makeCache(subviews: subviews)
        let natural = row.sizeThatFits(proposal: .unspecified, subviews: subviews, cache: &cache)
        if let width, natural.width > width {
            return AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        }
        return row
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = stack(width: proposal.width, subviews: subviews)
        var layoutCache = layout.makeCache(subviews: subviews)
        return layout.sizeThatFits(proposal: proposal, subviews: subviews, cache: &layoutCache)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let layout = stack(width: bounds.width, subviews: subviews)
        var layoutCache = layout.makeCache(subviews: subviews)
        layout.placeSubviews(
            in: bounds, proposal: ProposedViewSize(bounds.size), subviews: subviews,
            cache: &layoutCache)
    }
}

private struct ListeningEffectSlider: View {
    let title: String
    let key: WritableKeyPath<Controls, Double>
    let model: ListeningModel

    var body: some View {
        let value = model.controls[keyPath: key]
        ListeningControlSlider(
            title: title, value: value, range: 0...1,
            valueText: "\(Int((value * 100).rounded()))%",
            identifier: title.lowercased() + "Slider",
            preview: {
                var controls = model.controls
                controls[keyPath: key] = $0
                model.previewControls(controls)
            }, commit: model.commitControls)
    }
}

/// Touch dragging previews until release. An accessibility adjustment commits one complete
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
        VStack(alignment: .leading, spacing: 0) {
            FittingRow(spacing: 4) {
                Text(title).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                Text(valueText).monospacedDigit().foregroundStyle(.primary.opacity(0.67))
            }
            .accessibilityHidden(true)
            Slider(
                value: Binding(get: { value }, set: { preview(quantized($0)) }),
                in: range, step: step,
                onEditingChanged: { if !$0 { commit() } }
            )
            .frame(minHeight: 44)
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
                .foregroundStyle(.primary.opacity(0.67))
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
                Section {
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
                            .foregroundStyle(.primary.opacity(0.72))
                    }
                } header: {
                    Text("Tempo").font(.subheadline.weight(.semibold)).foregroundStyle(
                        Color(uiColor: .label).opacity(0.72))
                }
                Section {
                    ListeningEffectSlider(title: "Space", key: \.space, model: model)
                    ListeningEffectSlider(title: "Texture", key: \.texture, model: model)
                } header: {
                    Text("Sound").font(.subheadline.weight(.semibold)).foregroundStyle(
                        Color(uiColor: .label).opacity(0.72))
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
                    Text("Variation sets how much each new piece differs from the last.")
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.72))
                }
            }
            .disabled(!model.canEditControls)
            .navigationTitle("Listening Controls")
            .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") {
                        model.commitControls()
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityShowsLargeContentViewer {
                        Label("Done", systemImage: "checkmark")
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
