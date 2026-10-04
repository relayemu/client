// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import RelayLibrary
import RelayDesignSystem

/// One small, device-local firmware page. BIOS bytes never enter sync or game content.
struct PlayStationFirmwareView: View {
    @Environment(LibraryModel.self) private var model
    @State private var installed: [PlayStationFirmware] = []
    @State private var selecting = false
    @State private var busy = false
    @State private var failed = false
    @State private var address = ""
    private var store: PlayStationFirmwareStore {
        PlayStationFirmwareStore(firmwareDirectory: model.environment.firmwareDirectory)
    }
    var body: some View {
        List {
            Section {
                ForEach(PlayStationFirmware.allCases, id: \.self) { bios in
                    HStack {
                        Text(name(bios))
                        Spacer()
                        Text(installed.contains(bios) ? L("Installed") : L("Not installed"))
                            .foregroundStyle(RelayColor.textSecondary)
                    }
                }
                #if !os(tvOS)
                Button { selecting = true } label: { Text("Import Firmware", bundle: .module) }
                    .accessibilityIdentifier("ps1.importBIOS")
                #else
                TextField(L("Firmware File URL"), text: $address)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                Button { Task { await importAddress() } } label: { Text("Import Firmware", bundle: .module) }
                    .disabled(busy || address.isEmpty)
                #endif
                if busy { ProgressView() }
            } footer: {
                Text("Import firmware from your own PlayStation: SCPH-5500, SCPH-5501 or SCPH-5502. Relay checks it before use. Firmware stays on this device and isn't synced.", bundle: .module)
            }
            Section {
                Text("PlayStation firmware improves game compatibility. Without it, Relay uses emulated system software. Import the same firmware on your other devices to use Auto Resume and Saves there.", bundle: .module)
            }
            if failed {
                Section {
                    Text("This firmware couldn't be imported. Choose an unmodified 512 KB SCPH-5500, SCPH-5501 or SCPH-5502 file.", bundle: .module)
                        .foregroundStyle(RelayColor.textSecondary)
                }
            }
        }
        .relaySettingsPage(L("PlayStation Firmware"))
        .onAppear { refresh() }
        #if !os(tvOS)
        .fileImporter(isPresented: $selecting, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            do { try store.importFile(url); failed = false; refresh() } catch { failed = true }
        }
        #endif
    }
    private func refresh() {
        do { installed = try store.installed() } catch { failed = true }
    }
    private func name(_ bios: PlayStationFirmware) -> String {
        switch bios {
        case .japan: return L("Japan · SCPH-5500")
        case .northAmerica: return L("North America · SCPH-5501")
        case .europe: return L("Europe · SCPH-5502")
        }
    }
    #if os(tvOS)
    private func importAddress() async {
        busy = true; defer { busy = false }
        do {
            guard let url = URL(string: address), url.scheme?.lowercased() == "https",
                  url.host != nil, url.user == nil, url.password == nil else { throw PlayStationFirmwareError.incompatibleFile }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (stream, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.url?.scheme?.lowercased() == "https",
                  response.expectedContentLength <= PlayStationFirmwareStore.size else { throw PlayStationFirmwareError.incompatibleFile }
            var data = Data(); data.reserveCapacity(PlayStationFirmwareStore.size)
            for try await byte in stream {
                guard data.count < PlayStationFirmwareStore.size else { throw PlayStationFirmwareError.incompatibleFile }
                data.append(byte)
            }
            try store.importData(data); address = ""; failed = false; refresh()
        } catch { failed = true }
    }
    #endif
}
