// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

@main
struct LowlightApp: App {
    var body: some Scene {
        WindowGroup {
            ListeningView()
        }
    }
}

private struct ListeningView: View {
    @State private var showsAbout = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 80, weight: .ultraLight))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("A little room to unwind")
                        .font(.title2)
                        .multilineTextAlignment(.center)
                    Text("Your offline listening space is taking shape. Music is coming soon.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("listeningStatus")
                }
                .frame(maxWidth: 480)
                .padding(32)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Lowlight")
            .toolbar {
                Button("About", systemImage: "info.circle") {
                    showsAbout = true
                }
                .accessibilityIdentifier("aboutButton")
            }
            .sheet(isPresented: $showsAbout) {
                AboutView()
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
                    Text("Playback is not available in this early version.")
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
