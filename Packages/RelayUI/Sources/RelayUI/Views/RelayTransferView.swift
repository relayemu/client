// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelayDesignSystem
import RelayTransfer

struct RelayTransferView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(RelayActions.self) private var actions
    @Environment(\.scenePhase) private var scenePhase
    @State private var transfer = TransferModel()
    @State private var confirmingClose = false
    @State private var showPro = false

    var body: some View {
        Group {
            #if os(tvOS)
            televisionContent
            #else
            compactContent
            #endif
        }
        .relayCanvas()
        #if os(tvOS)
        .navigationTitle(Text(verbatim: ""))
        #else
        .navigationTitle(Text("From a computer", bundle: .module))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { close() } label: { Text("Close", bundle: .module) }
            }
        }
        #endif
        .interactiveDismissDisabled(transfer.isBusy)
        .confirmationDialog(Text("Cancel this transfer?", bundle: .module), isPresented: $confirmingClose, titleVisibility: .visible) {
            Button(role: .destructive) { Task { await transfer.stop(); actions.transferPresented = false } } label: { Text("Cancel transfer", bundle: .module) }
        } message: { Text("Games already added stay in your library.", bundle: .module) }
        .sheet(isPresented: $showPro) { NavigationStack { RelayProView(feature: .transfer, isPresentedModally: true) } }
        .task(id: library.environment.relayAccount?.accountID) { await transfer.start(library: library) }
        .onChange(of: library.environment.relayPro.isPro) { _, isPro in
            Task { if isPro { await transfer.start(library: library) } else { await transfer.stop(reason: "auth_lost") } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await transfer.stop(reason: "backgrounded") } }
            else if phase == .active { Task { await transfer.start(library: library) } }
        }
        .onDisappear { Task { await transfer.stop() } }
    }

    private var compactContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RelaySpacing.xl) {
                if !library.environment.relayPro.isPro {
                    Text("Relay Pro", bundle: .module).font(.relayDetailTitle)
                    Text("Send games from your computer straight to Relay. Your files aren't stored online.", bundle: .module)
                        .foregroundStyle(RelayColor.textSecondary)
                    Button { showPro = true } label: { Text("Explore Relay Pro", bundle: .module) }
                        .buttonStyle(EmberButtonStyle())
                } else if let account = library.environment.relayAccount {
                    if account.isConnected {
                        if transfer.files.isEmpty { waitingCard }
                        else {
                            transferCard
                            if transfer.isComplete {
                                Button { close() } label: { Label { Text("Library", bundle: .module) } icon: { Image(systemName: "books.vertical") } }
                                    .buttonStyle(EmberButtonStyle())
                                Text("Send more files from your computer, or close this screen to play.", bundle: .module)
                                    .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                            }
                            fileList
                        }
                        transferGuidance
                    } else {
                        Text("Sign in to pair your computer with Relay. You don't need a Sync membership.", bundle: .module)
                        NativeAppleSignInButton(isEnabled: !account.isBusy && account.session != nil) { account.signIn(anchor: $0) }
                        if let message = account.errorMessage { Text(message).foregroundStyle(RelayColor.textSecondary) }
                    }
                } else { Text("Transfer isn't available on this service yet.", bundle: .module) }
            }
            .padding(RelaySpacing.layout.screenMargin)
            .frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    #if os(tvOS)
    private var televisionContent: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: RelaySpacing.xxl) {
                HStack {
                    Text("From a computer", bundle: .module).font(.relayShelfTitle)
                    Spacer()
                    Button { close() } label: { Text("Close", bundle: .module) }
                        .buttonStyle(.quiet)
                }
                if library.environment.relayPro.isPro, library.environment.relayAccount?.isConnected == true {
                    HStack(alignment: .center, spacing: RelaySpacing.giant) {
                        VStack(alignment: .leading, spacing: RelaySpacing.xxl) {
                            if transfer.files.isEmpty {
                                Image(systemName: "appletv").font(.relayScreenTitle)
                                    .foregroundStyle(RelayColor.textSecondary).accessibilityHidden(true)
                                Text(transfer.message).font(.relayScreenTitle)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("relay.transfer.status")
                                Text(portalAddress).font(.relayDetailTitle).foregroundStyle(RelayColor.ember)
                                    .fixedSize(horizontal: true, vertical: true)
                            } else {
                                transferCard
                                if transfer.isComplete {
                                    Button { close() } label: { Label { Text("Library", bundle: .module) } icon: { Image(systemName: "books.vertical") } }
                                        .buttonStyle(.ember)
                                    Text("Send more files from your computer, or close this screen to play.", bundle: .module)
                                        .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                                }
                            }
                        }
                        .frame(width: (geometry.size.width - 2 * RelaySpacing.layout.screenMargin - RelaySpacing.giant) / 2, alignment: .leading)

                        if transfer.files.isEmpty {
                            VStack(alignment: .leading, spacing: RelaySpacing.xxxl) {
                                step(1, title: L("Open this address on your computer")) { EmptyView() }
                                Divider()
                                accountStep
                                Divider()
                                sendStep
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ScrollView { fileList.padding(RelaySpacing.xs) }
                                .focusSection()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    transferGuidance
                } else {
                    compactContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, RelaySpacing.layout.screenMargin)
            .padding(.vertical, RelaySpacing.xxl)
        }
    }
    #endif

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.xl) {
            pairingSymbols
            Text(transfer.message).font(.relayDetailTitle).accessibilityIdentifier("relay.transfer.status")
            VStack(alignment: .leading, spacing: RelaySpacing.l) {
                addressStep
                accountStep
                sendStep
            }
        }
        .padding(RelaySpacing.xl).frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayColor.surface, in: RoundedRectangle(cornerRadius: RelayRadius.xl))
    }

    private var pairingSymbols: some View {
        HStack(spacing: RelaySpacing.m) {
            Image(systemName: "desktopcomputer").font(.largeTitle).foregroundStyle(RelayColor.textPrimary)
            Image(systemName: "arrow.right").font(.title3).foregroundStyle(RelayColor.ember)
            Image(systemName: deviceSymbol).font(.largeTitle).foregroundStyle(RelayColor.ember)
        }.accessibilityHidden(true)
    }

    private var addressStep: some View {
        step(1, title: L("Open this address on your computer")) {
            Text(portalAddress).font(.relaySubheader).foregroundStyle(RelayColor.ember)
                .fixedSize(horizontal: false, vertical: true)
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
        }
    }

    private var accountStep: some View {
        step(2, title: L("Choose Transfer, then this device")) {
            Text("Sign in with the same Apple account.", bundle: .module)
                .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
        }
    }

    private var sendStep: some View {
        step(3, title: L("Drop your files and choose Send to Relay")) { EmptyView() }
    }

    private var transferGuidance: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.m) {
            Label { Text("Keep Relay open while your files arrive.", bundle: .module) } icon: { Image(systemName: "info.circle") }
                .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
            Label { Text("Send games from your computer straight to Relay. Your files aren't stored online.", bundle: .module) } icon: { Image(systemName: "lock.shield") }
                .font(.relayStatus).foregroundStyle(RelayColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func step<Content: View>(_ number: Int, title: String, @ViewBuilder detail: () -> Content) -> some View {
        HStack(alignment: .top, spacing: RelaySpacing.s) {
            Text(number, format: .number).font(.relayBadge).foregroundStyle(RelayColor.ember)
                .frame(width: 28, height: 28).background(RelayColor.emberTint, in: Circle())
            VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                Text(title).font(.relayCardTitle).fixedSize(horizontal: false, vertical: true)
                detail()
            }
        }.accessibilityElement(children: .combine)
    }

    private var transferCard: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.l) {
            HStack(alignment: .top, spacing: RelaySpacing.s) {
                Image(systemName: transfer.isComplete ? "checkmark.circle.fill" : transfer.isReceiving ? "arrow.down.circle.fill" : "tray.and.arrow.down.fill")
                    .font(.title).foregroundStyle(transfer.isComplete ? RelayColor.positive : RelayColor.ember).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                    Text(transfer.message).font(.relaySubheader).accessibilityIdentifier("relay.transfer.status")
                    if transfer.isBusy {
                        if transfer.isReceiving {
                            Text("\(transfer.files.count) files", bundle: .module).font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                        } else {
                            Text("Adding games… \(transfer.terminalFileCount) of \(transfer.files.count)", bundle: .module)
                                .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                        }
                    }
                }
                Spacer(minLength: RelaySpacing.xs)
                if let route = transfer.route {
                    Label {
                        Text(route == .direct ? "Direct" : "Via Relay", bundle: .module)
                    } icon: {
                        Image(systemName: route == .direct ? "arrow.up.right" : "network")
                    }
                    .font(.relayBadge).foregroundStyle(RelayColor.textSecondary)
                    .padding(.horizontal, RelaySpacing.s).padding(.vertical, RelaySpacing.xxs)
                    .background(RelayColor.separator, in: Capsule())
                    .fixedSize().accessibilityIdentifier("relay.transfer.route")
                }
            }
            if transfer.isComplete { resultSummary }
            else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: RelaySpacing.xxs) {
                        Text("Received", bundle: .module).font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                        Text(Formatting.bytes(transfer.receivedBytes)).font(.relayDetailTitle).monospacedDigit()
                        Text(Formatting.bytes(transfer.totalBytes)).font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                    }
                    Spacer(minLength: RelaySpacing.xs)
                    Text(transfer.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.relayScreenTitle).monospacedDigit().foregroundStyle(RelayColor.ember)
                }
                ProgressView(value: transfer.fraction).tint(RelayColor.ember)
                    .accessibilityLabel(Text("Received", bundle: .module))
                    .accessibilityIdentifier("relay.transfer.progress")
                if transfer.isReceiving {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: RelaySpacing.xl) { receiveMetrics }
                        VStack(alignment: .leading, spacing: RelaySpacing.m) { receiveMetrics }
                    }
                    Text("Up to two files at a time", bundle: .module).font(.relayBadge).foregroundStyle(RelayColor.textSecondary)
                } else if transfer.isBusy {
                    HStack(alignment: .top, spacing: RelaySpacing.s) {
                        ProgressView().controlSize(.small)
                        Text("Your files have arrived. Relay is checking them and adding games. Large archives can take a few minutes.", bundle: .module)
                            .font(.relayMeta).foregroundStyle(RelayColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(RelaySpacing.xl).frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayColor.surface, in: RoundedRectangle(cornerRadius: RelayRadius.xl))
        .modifier(TransferReadingFocus())
    }

    @ViewBuilder private var receiveMetrics: some View {
        metric(L("Speed"), value: transfer.bytesPerSecond > 0 ? String(localized: "\(Formatting.bytes(Int64(transfer.bytesPerSecond)))/s", bundle: .module) : L("Estimating…"))
        metric(L("Time left to receive"), value: transfer.remainingSeconds.map { String(localized: "About \(Formatting.playDuration($0))", bundle: .module) } ?? L("Estimating…"))
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: RelaySpacing.xs) {
            Text(title).font(.relayStatus).foregroundStyle(RelayColor.textSecondary)
            Text(value).font(.relayCardTitle).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    private var resultSummary: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            Text("\(transfer.counts.imported) games added", bundle: .module).font(.relayDetailTitle)
            if transfer.counts.duplicate > 0 {
                Text("\(transfer.counts.duplicate) already in your library", bundle: .module).foregroundStyle(RelayColor.textSecondary)
            }
            let problems = transfer.statuses.values.filter { $0.state == "failed" || $0.state == "unsupported" }.count
            if problems > 0 { Text("\(problems) need attention", bundle: .module).foregroundStyle(RelayColor.textSecondary) }
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            HStack {
                Text("Files", bundle: .module).font(.relaySubheader)
                Spacer()
                Text("\(transfer.files.count) files", bundle: .module).font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
            }
            LazyVStack(spacing: 0) {
                ForEach(transfer.files) { file in
                    fileRow(file)
                    if file.id != transfer.files.last?.id {
                        Divider().padding(.leading, RelaySpacing.m + fileIconSize + fileRowSpacing)
                    }
                }
            }
            .background(RelayColor.surface, in: RoundedRectangle(cornerRadius: RelayRadius.l))
        }
    }

    private func fileRow(_ file: TransferFile) -> some View {
        let status = transfer.statuses[file.id]
        let success = status?.state == "imported" || status?.state == "duplicate"
        let problem = status?.state == "failed" || status?.state == "unsupported"
        return HStack(alignment: fileRowAlignment, spacing: fileRowSpacing) {
            Image(systemName: success ? "checkmark.circle.fill" : problem ? "exclamationmark.circle" : "doc")
                .font(.title3).foregroundStyle(success ? RelayColor.positive : problem ? RelayColor.caution : RelayColor.ember)
                .frame(width: fileIconSize, height: fileIconSize).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                Text(status?.title ?? file.name).font(.relayCardTitle).lineLimit(2)
                if status?.title != nil { Text(file.name).font(.relayStatus).foregroundStyle(RelayColor.textSecondary).lineLimit(1) }
                Text(status?.message ?? TransferModel.stateLabel(status?.state))
                    .font(.relayMeta).foregroundStyle(RelayColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                if status?.state == "receiving" {
                    ProgressView(value: Double(transfer.receivedByID[file.id] ?? 0), total: Double(max(1, file.size))).tint(RelayColor.ember)
                    Text("\(Formatting.bytes(transfer.receivedByID[file.id] ?? 0)) of \(Formatting.bytes(file.size))", bundle: .module)
                        .font(.relayStatus).monospacedDigit().foregroundStyle(RelayColor.textSecondary)
                } else { Text(Formatting.bytes(file.size)).font(.relayStatus).foregroundStyle(RelayColor.textTertiary) }
            }
            Spacer(minLength: 0)
            if status?.state == "importing" || status?.state == "verifying" { ProgressView().controlSize(.small) }
        }
        .padding(RelaySpacing.m).accessibilityElement(children: .combine)
        .modifier(TransferReadingFocus())
    }

    private var fileIconSize: CGFloat {
        #if os(tvOS)
        RelaySpacing.giant
        #else
        32
        #endif
    }

    private var fileRowSpacing: CGFloat {
        #if os(tvOS)
        RelaySpacing.m
        #else
        RelaySpacing.s
        #endif
    }

    private var fileRowAlignment: VerticalAlignment {
        #if os(tvOS)
        .center
        #else
        .top
        #endif
    }

    private var portalAddress: String {
        guard let url = library.environment.relayAccount?.environment.portalOrigin else { return "account.relayemu.app" }
        return (url.host ?? "account.relayemu.app") + (url.port.map { ":\($0)" } ?? "")
    }
    private var deviceSymbol: String {
        switch library.environment.deviceKind {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .appleTV: "appletv"
        case .mac: "laptopcomputer"
        default: "display"
        }
    }
    private func close() {
        if transfer.isBusy { confirmingClose = true }
        else { Task { await transfer.stop(); actions.transferPresented = false } }
    }
}

/// Reading targets let the TV remote reveal long queues without pretending
/// that informational cards are buttons. The outline keeps focus visible.
private struct TransferReadingFocus: ViewModifier {
    #if os(tvOS)
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: RelayRadius.l)
                    .strokeBorder(focused ? RelayColor.textPrimary : .clear, lineWidth: 3)
            }
            .focusable()
            .focused($focused)
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}
