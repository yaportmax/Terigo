import SwiftData
import SwiftUI

struct RouteVaultRootScreen: View {
    private struct PresentedTrackedRoute: Identifiable {
        let routeID: Int

        var id: Int { routeID }
    }

    @AppStorage(RouteTrackingActivityStore.activeRouteIDDefaultsKey) private var activeRouteTrackingRouteID = 0
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: [SortDescriptor(\RouteRecord.syncedAt, order: .reverse)]) private var routes: [RouteRecord]
    @State private var accountManager = RouteVaultAccountManager()
    @State private var statusBannerDismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if accountManager.isRestoringSession && !accountManager.didRestoreInitialState {
                ProgressView("Restoring Terigo…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if accountManager.isAuthenticated {
                RouteLibraryScreen()
                    .environment(accountManager)
            } else {
                RouteVaultWelcomeScreen()
                    .environment(accountManager)
            }
        }
        .task {
            await accountManager.restorePersistedStateIfNeeded()
        }
        .onChange(of: accountManager.statusMessage) { _, newValue in
            scheduleStatusBannerDismiss(for: newValue)
        }
        .onDisappear {
            statusBannerDismissTask?.cancel()
            statusBannerDismissTask = nil
        }
        .onOpenURL { url in
            accountManager.captureIncomingURL(url)
        }
        .onChange(of: availableTrackedRouteIDs) { _, trackedRouteIDs in
            guard !trackedRouteIDs.isEmpty,
                  activeRouteTrackingRouteID > 0,
                  !trackedRouteIDs.contains(activeRouteTrackingRouteID) else {
                return
            }

            clearActiveRouteTracking()
        }
        .fullScreenCover(item: activeTrackedRouteBinding) { presentedRoute in
            if let route = routes.first(where: { $0.stravaRouteID == presentedRoute.routeID }) {
                RouteTrackingView(route: route)
            } else {
                Color.clear
                    .ignoresSafeArea()
                    .onAppear {
                        clearActiveRouteTracking()
                    }
            }
        }
        .background(backgroundColor.ignoresSafeArea())
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? .black : Color(red: 0.95, green: 0.94, blue: 0.90)
    }

    private func scheduleStatusBannerDismiss(for value: String?) {
        statusBannerDismissTask?.cancel()
        statusBannerDismissTask = nil

        guard value?.trimmed.nilIfEmpty != nil else {
            return
        }

        let message = value
        statusBannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if accountManager.statusMessage == message {
                accountManager.clearTransientMessages()
            }
        }
    }

    private var activeTrackedRouteBinding: Binding<PresentedTrackedRoute?> {
        Binding(
            get: {
                guard activeRouteTrackingRouteID > 0,
                      routes.contains(where: { $0.stravaRouteID == activeRouteTrackingRouteID }) else {
                    return nil
                }

                return PresentedTrackedRoute(routeID: activeRouteTrackingRouteID)
            },
            set: { presentedRoute in
                if let presentedRoute {
                    activeRouteTrackingRouteID = presentedRoute.routeID
                } else {
                    clearActiveRouteTracking()
                }
            }
        )
    }

    private var availableTrackedRouteIDs: [Int] {
        routes.map(\.stravaRouteID).sorted()
    }

    private func clearActiveRouteTracking() {
        if activeRouteTrackingRouteID > 0 {
            RouteTrackingActivityStore.clearSnapshot(for: activeRouteTrackingRouteID)
        }
        activeRouteTrackingRouteID = 0
    }
}

private struct RouteVaultWelcomeScreen: View {
    @Environment(RouteVaultAccountManager.self) private var accountManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @State private var isShowingAccessCodeSheet = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack {
                    Spacer(minLength: max(geometry.safeAreaInsets.top, 48))

                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            Image("TerigoLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 260, alignment: .leading)
                                .accessibilityLabel("Terigo")

                            Text("Connect to Strava to access Terigo.")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            Task { await accountManager.connectWithStrava() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "figure.run")
                                Text(accountManager.isConnecting ? "Connecting…" : "Connect With Strava")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.orange)
                        .disabled(accountManager.isConnecting || accountManager.isRestoringSession)

                        Button {
                            isShowingAccessCodeSheet = true
                        } label: {
                            Text("Enter Access Code")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .disabled(accountManager.isConnecting || accountManager.isRestoringSession)

                        Text(helperMessage)
                            .font(.footnote)
                            .foregroundStyle(helperUsesErrorTone ? Color.red.opacity(0.95) : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 440, alignment: .leading)
                    .padding(24)
                    .background(cardFill)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .padding(.horizontal, 24)

                    Spacer(minLength: 32)
                }
                .frame(minHeight: geometry.size.height)
                .padding(.bottom, 32)
            }
        }
        .sheet(isPresented: $isShowingAccessCodeSheet) {
            NavigationStack {
                RouteVaultAccessCodeSheet { accessCode in
                    accountManager.activateReviewDemo(using: modelContext, accessCode: accessCode)
                    if accountManager.isAuthenticated {
                        isShowingAccessCodeSheet = false
                    }
                }
                .environment(accountManager)
            }
            .presentationDetents([.fraction(0.34)])
        }
    }

    private var cardFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.94)
    }

    private var helperMessage: String {
        if let errorMessage = accountManager.errorMessage?.trimmed.nilIfEmpty {
            return errorMessage
        }

        if let statusMessage = accountManager.statusMessage?.trimmed.nilIfEmpty {
            return statusMessage
        }

        return accountManager.backendStatusText
    }

    private var helperUsesErrorTone: Bool {
        accountManager.errorMessage?.trimmed.nilIfEmpty != nil
    }
}

private struct RouteVaultAccessCodeSheet: View {
    @Environment(RouteVaultAccountManager.self) private var accountManager
    @Environment(\.dismiss) private var dismiss

    @State private var accessCode = ""

    let onUnlock: (String) -> Void

    var body: some View {
        Form {
            Section("Access Code") {
                TextField("Enter code", text: $accessCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()

                Text("Use this only if Terigo support gave you an access code for a local demo library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = accountManager.errorMessage?.trimmed.nilIfEmpty {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Access Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("Unlock") {
                    onUnlock(accessCode.trimmed)
                }
                .disabled(accessCode.trimmed.isEmpty)
            }
        }
    }
}
