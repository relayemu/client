// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CoverSettingsSection.swift
//  RelayUI — Settings ▸ Library ▸ Download Covers (cover-art spec §2), on
//  every platform. Absent from builds without a cover origin. Remove
//  Downloaded Covers appears only while downloading is off: with it on, the
//  next pass would fetch them again.

import SwiftUI
import RelayDesignSystem

struct CoverSettingsSection: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        if model.canDownloadCovers {
            Section {
                Toggle(isOn: Binding(get: { model.downloadCovers }, set: { model.setDownloadCovers($0) })) {
                    Text("Download Covers", bundle: .module)
                }
                .accessibilityIdentifier("settings.downloadCovers")
                if !model.downloadCovers {
                    Button { Task { await model.removeDownloadedCovers() } } label: {
                        Text("Remove Downloaded Covers", bundle: .module)
                    }
                    .accessibilityIdentifier("settings.removeDownloadedCovers")
                }
            } footer: {
                Text("Covers of recognized games come from Relay's servers in the EU. Requests carry no account or device identifier.", bundle: .module)
                    .foregroundStyle(RelayColor.textSecondary)
                    #if os(macOS)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    #endif
            }
        }
    }
}
