// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
import SwiftUI
import RelaySync
import RelayHostedSync
import RelayDomain
import RelayDesignSystem
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@_spi(AccessibilityQualification)
public struct RelayAccessibilityEnvironmentProbe: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @State private var dismissed = false
    #endif

    public init() {}

    public var body: some View {
        #if os(iOS)
        if !dismissed {
            Button { dismissed = true } label: { probeLabel }
                .buttonStyle(.plain)
                .accessibilityLabel("Debug accessibility environment")
                .accessibilityValue(evidence)
                .accessibilityHint("Dismisses this debug readout after its measured values have been captured.")
                .accessibilityIdentifier("relay.debug.accessibilityEnvironment")
        }
        #else
        probeLabel
            .accessibilityLabel("Debug accessibility environment")
            .accessibilityValue(evidence)
            .accessibilityIdentifier("relay.debug.accessibilityEnvironment")
        #endif
    }

    private var probeLabel: some View {
        Text(verbatim: "DEBUG · AX")
            .font(.caption)
            .lineLimit(1)
            .padding(8)
            .background(.regularMaterial)
    }

    private var evidence: String {
        var result = "dynamicType=\(dynamicType);contrast=\(contrast == .increased ? "increased" : "standard");reduceMotion=\(reduceMotion)"
        #if canImport(UIKit)
        result += ";systemReduceMotion=\(UIAccessibility.isReduceMotionEnabled)"
        result += ";systemDarkerColors=\(UIAccessibility.isDarkerSystemColorsEnabled)"
        result += ";systemContentSize=\(UIApplication.shared.preferredContentSizeCategory.rawValue)"
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        for (sceneIndex, scene) in scenes.prefix(2).enumerated() {
            result += ";scene\(sceneIndex)ContentSize=\(scene.traitCollection.preferredContentSizeCategory.rawValue)"
            for (windowIndex, window) in scene.windows.filter(\.isKeyWindow).prefix(2).enumerated() {
                let prefix = "scene\(sceneIndex)Window\(windowIndex)"
                result += ";\(prefix)ContentSize=\(window.traitCollection.preferredContentSizeCategory.rawValue)"
                var controller = window.rootViewController
                for depth in 0..<4 {
                    guard let current = controller else { break }
                    result += ";\(prefix)Controller\(depth)ContentSize=\(current.traitCollection.preferredContentSizeCategory.rawValue)"
                    if let view = current.viewIfLoaded {
                        result += ";\(prefix)View\(depth)ContentSize=\(view.traitCollection.preferredContentSizeCategory.rawValue)"
                    }
                    controller = current.presentedViewController
                }
            }
        }
        #elseif canImport(AppKit)
        result += ";systemReduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)"
        result += ";systemIncreaseContrast=\(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)"
        // AppKit reports Keyboard > Keyboard navigation here, which is distinct
        // from Accessibility > Keyboard > Full Keyboard Access.
        result += ";systemKeyboardNavigation=\(NSApplication.shared.isFullKeyboardAccessEnabled)"
        #endif
        return result
    }
}

/// Immutable, conspicuously marked presentation-only samples. No LibraryModel,
/// RelayAccountModel, session, entitlement provider, store, transport or backend
/// exists in this view. The live adapter and this fixture render identical rows.
@_spi(AccessibilityQualification)
public struct RelaySyncAccessibilityFixtureView: View {
    private let scenario: String
    private let sampledAt: Date
    @State private var selectedFixture: FixtureDestination?

    private enum FixtureDestination: String, CaseIterable, Identifiable {
        case active, recovery, purged, error, conflict, transfer

        var id: String { rawValue }
        var title: String {
            switch self {
            case .active: "Active account"
            case .recovery: "Recovery period"
            case .purged: "Online storage removed"
            case .error: "Account and sync error"
            case .conflict: "Two save versions"
            case .transfer: "Download progress"
            }
        }
    }

    public init(scenario: String) {
        self.scenario = scenario
        self.sampledAt = Date()
    }

    public var body: some View {
        NavigationStack {
            if scenario == "catalog" {
                fixtureCatalog
            } else if scenario == "conflict" || scenario == "transfer" {
                cardFixture
                    .navigationTitle("Accessibility qualification")
            } else {
            List {
                Section {
                    fixtureMarker
                }
                if let presentation {
                    RelayAccountPresentationSection(presentation: presentation, actions: .init(
                        signIn: { _ in }, refresh: {}, signOut: {}, openPortal: {},
                        setGameFilesEnabled: { _ in }, retrySync: {},
                        acceptAccountChange: {}, keepSyncOff: {}
                    ))
                } else {
                    Text(verbatim: "Unsupported fixture scenario")
                        .accessibilityIdentifier("relay.debug.fixture.invalid")
                }
            }
            .navigationTitle("Accessibility qualification")
            }
        }
    }

    /// Navigation between existing samples only. The sheet's persistent Done
    /// control stays reachable without scrolling back through the sample.
    private var fixtureCatalog: some View {
        List {
            Section {
                Text(verbatim: "DEBUG PRESENTATION FIXTURES ONLY")
                    .bold()
                    .accessibilityIdentifier("relay.debug.fixture.catalog")
                Text(verbatim: "Choose a sample screen for accessibility inspection. Account and save actions are inert. These screens do not represent your account, library, or a running transfer. Use Done to return here.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                ForEach(FixtureDestination.allCases) { destination in
                    Button { selectedFixture = destination } label: {
                        Text(verbatim: destination.title)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("relay.debug.fixture.open." + destination.rawValue)
                    .accessibilityHint("Opens a presentation fixture. No account or save data is changed.")
                }
            } header: {
                Text(verbatim: "Sample screens")
            }
        }
        .navigationTitle("Debug fixture catalog")
        .sheet(item: $selectedFixture) { destination in
            RelaySyncAccessibilityFixtureView(scenario: destination.rawValue)
                .safeAreaInset(edge: .bottom) {
                    Button { selectedFixture = nil } label: {
                        Text(verbatim: "Done")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Done, return to fixture catalog")
                    .accessibilityIdentifier("relay.debug.fixture.done")
                    .padding()
                    .background(.regularMaterial)
                }
        }
    }

    private var fixtureMarker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "DEBUG · \(scenario) sample").bold()
            Text(verbatim: "Actions are inert.")
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("relay.debug.fixture")
        .accessibilityHint("Sample data only. This is not an authenticated account or backend lifecycle test. No save is selected and no file is transferred.")
        #if os(tvOS)
        // Standalone account samples omit the earlier Settings controls that
        // normally provide initial focus. Give this read-only debug marker a
        // native entry point; account actions still require remote traversal.
        .focusable()
        #endif
    }

    private var cardFixture: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RelaySpacing.l) {
                fixtureMarker
                if scenario == "conflict" {
                    // Match CompareView's existing adaptive card arrangement.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: RelaySpacing.m) { versionCards }
                        VStack(alignment: .leading, spacing: RelaySpacing.m) { versionCards }
                    }
                    Text("The other version stays in Previous versions. Nothing is deleted.", bundle: .module)
                        .font(.relayCallout)
                        .foregroundStyle(RelayColor.textTertiary)
                } else {
                    GameCard(GameCardModel(
                        id: GameID("33333333-3333-4333-8333-333333333333")!,
                        title: "Sample transfer", system: SystemID(rawValue: "gba"), systemName: "Game Boy Advance",
                        hue: .amber, badge: .downloading(0.42)
                    ), artworkHeight: 180, action: {})
                    .accessibilityIdentifier("relay.debug.transfer")
                }
            }
            .padding(RelaySpacing.layout.screenMargin)
        }
        .relayCanvas()
    }

    @ViewBuilder private var versionCards: some View {
        ForEach(Array(sampleHeads.enumerated()), id: \.element.id) { index, head in
            VersionCard(revision: head, versionNumber: index + 1, hue: .amber,
                        session: nil, isLocal: false, thisDevice: .current,
                        loader: nil, busy: false, keep: {})
        }
    }

    /// Value-only references: there is no payload and no content is opened.
    private var sampleHeads: [BatteryRevision] {
        let game = GameID("33333333-3333-4333-8333-333333333333")!
        return [
            ("11111111-1111-4111-8111-111111111111", DeviceKind.iPhone),
            ("22222222-2222-4222-8222-222222222222", DeviceKind.mac),
        ].enumerated().map { index, sample in
            BatteryRevision(
                id: BatteryRevisionID(sample.0)!, gameID: game, parentIDs: [], createdAt: sampledAt,
                dataFingerprint: try! ContentFingerprint(sha256: Array(repeating: UInt8(index + 1), count: 32)),
                sizeInBytes: 0, installationID: InstallationID(sample.0)!, deviceKind: sample.1,
                location: try! ContentLocation(root: .managedLibrary, relativePath: "DebugPresentation/\(sample.0).sav"),
                origin: .remote
            )
        }
    }

    private var presentation: RelayAccountPresentation? {
        guard ["active", "recovery", "purged", "error"].contains(scenario) else { return nil }
        var status = SyncStatus()
        status.provider = .relaySync
        status.account = .available
        status.isActive = true
        status.lastPullAt = sampledAt
        if scenario == "error" { status.problem = .network }
        let vault: String
        let recovery: String?
        switch scenario {
        case "recovery":
            vault = L("Recovery")
            recovery = L("Download your games and saves before the recovery period ends. New uploads are paused. Your local progress stays safe.")
        case "purged":
            vault = L("Online storage removed")
            recovery = L("Your online storage has been removed. Your local games and saves have not been deleted.")
        default:
            vault = L("Active")
            recovery = nil
        }
        return RelayAccountPresentation(
            isConnected: true, isBusy: false, canSignIn: false, hasLoadedAccount: true,
            planName: "Relay Sync", vaultStatus: vault,
            usedBytes: scenario == "purged" ? 0 : 1_073_741_824, quotaBytes: 5_368_709_120,
            canUpload: scenario == "active" || scenario == "error", recoveryMessage: recovery,
            purgeAt: scenario == "recovery" ? sampledAt.addingTimeInterval(7 * 86_400) : nil,
            lastSyncAt: sampledAt,
            errorMessage: scenario == "error" ? L("Relay Sync couldn't connect. Check your connection and try again. Your local progress is safe.") : nil,
            portalOrigin: RelayHostedEnvironment.preproduction.portalOrigin,
            isRelaySelected: true, isSwitchingProvider: false, syncStatus: status
        )
    }
}
#endif
