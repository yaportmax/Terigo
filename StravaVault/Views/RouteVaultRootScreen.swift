import SwiftData
import SwiftUI

struct RouteVaultRootScreen: View {
    private struct PresentedTrackedRoute: Identifiable {
        let routeID: Int

        var id: Int { routeID }
    }

    @AppStorage("terigo.localLibraryEnabled") private var localLibraryEnabled = false
    @AppStorage(RouteTrackingActivityStore.activeRouteIDDefaultsKey) private var activeRouteTrackingRouteID = 0
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: [SortDescriptor(\RouteRecord.syncedAt, order: .reverse)]) private var routes: [RouteRecord]
    @State private var accountManager = RouteVaultAccountManager()
    @State private var statusBannerDismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if accountManager.isRestoringSession && !accountManager.didRestoreInitialState && !localLibraryEnabled && routes.isEmpty {
                ProgressView("Restoring Terigo…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if accountManager.isAuthenticated || localLibraryEnabled || !routes.isEmpty {
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
        TerigoTheme.background
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
    @Environment(\.modelContext) private var modelContext
    @AppStorage("terigo.localLibraryEnabled") private var localLibraryEnabled = false
    @State private var isShowingAccessCodeSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 10) {
                    Image("TerigoMark").resizable().scaledToFit().frame(width: 32, height: 32)
                    Text("Terigo").font(.title2.weight(.bold)).foregroundStyle(.primary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Terigo")

                ZStack {
                    RoundedRectangle(cornerRadius: 32)
                        .fill(TerigoTheme.accent.opacity(0.08))
                    Image(systemName: "mountain.2")
                        .font(.system(size: 96, weight: .ultraLight))
                        .foregroundStyle(TerigoTheme.accent)
                    Image(systemName: "location.north.circle.fill")
                        .font(.system(size: 42))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(TerigoTheme.accent, TerigoTheme.surface)
                        .offset(x: 100, y: 50)
                }
                .frame(height: 210)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Good routes.\nGreat days out.")
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Keep your routes together. Find your next adventure, save it offline, and follow it outside.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await accountManager.connectWithStrava() }
                    } label: {
                        HStack(spacing: 10) {
                            if accountManager.isConnecting { ProgressView().tint(.white) }
                            Text(accountManager.isConnecting ? "Connecting…" : "Connect with Strava")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TerigoTheme.accent)
                    .disabled(accountManager.isConnecting || accountManager.isRestoringSession)

                    Button {
                        localLibraryEnabled = true
                    } label: {
                        Text("Continue with GPX files")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("welcome-continue-local")

                    if let message = accountManager.errorMessage ?? accountManager.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(accountManager.errorMessage == nil ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Have an access code?") { isShowingAccessCodeSheet = true }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                }
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 28)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .background(TerigoTheme.background.ignoresSafeArea())
        .sheet(isPresented: $isShowingAccessCodeSheet) {
            NavigationStack {
                RouteVaultAccessCodeSheet { code in
                    accountManager.activateReviewDemo(using: modelContext, accessCode: code)
                    if accountManager.isAuthenticated { isShowingAccessCodeSheet = false }
                }
                .environment(accountManager)
            }
            .presentationDetents([.medium, .large])
        }
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
