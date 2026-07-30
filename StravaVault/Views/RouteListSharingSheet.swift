import SwiftUI
import SwiftData
import UIKit

struct RouteListSharingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(RouteVaultAccountManager.self) private var accountManager

    @Bindable var list: RouteList
    let routes: [RouteRecord]

    @State private var collaboratorDraft: String
    @State private var viewerDraft: String
    @State private var isSyncing = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private let listSyncService = RouteVaultListSyncService()

    init(list: RouteList, routes: [RouteRecord]) {
        self.list = list
        self.routes = routes
        _collaboratorDraft = State(initialValue: list.collaboratorCodes.joined(separator: ", "))
        _viewerDraft = State(initialValue: list.viewerCodes.joined(separator: ", "))
    }

    var body: some View {
        let audit = listSyncService.auditShareability(for: routes)

        Form {
            Section("Account") {
                Text(accountManager.backendStatusText)
                    .foregroundStyle(.secondary)

                if let profile = accountManager.accountSession?.profile {
                    LabeledContent("Signed In As", value: profile.displayName)
                    LabeledContent("Account Code", value: profile.accountCode)
                    Button {
                        UIPasteboard.general.string = profile.accountCode
                        statusMessage = "Copied your Terigo account code."
                    } label: {
                        Label("Copy My Code", systemImage: "doc.on.doc")
                    }
                } else {
                    Text("Connect Strava and let Terigo finish backend setup before syncing lists.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Visibility") {
                Picker("Who Can Open This List", selection: visibilityBinding) {
                    ForEach(RouteListVisibilityMode.allCases, id: \.self) { mode in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.title)
                            Text(mode.description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.inline)

                if list.sharingVisibility == .invitedView {
                    TextField("TG-ABC123, 12345678", text: $viewerDraft, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("Only the Terigo account codes listed here can open the list. You can paste either a Terigo code or a raw Strava athlete ID.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Collaboration") {
                Picker("Who Can Edit", selection: collaborationBinding) {
                    ForEach(availableCollaborationModes, id: \.self) { mode in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.title)
                            Text(mode.description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .disabled(list.sharingVisibility == .privateAccess)

                if list.sharingVisibility == .privateAccess {
                    Text("Private lists ignore collaboration settings until you switch them to a shared visibility mode.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if list.collaborationMode == .invitedEditors && list.sharingVisibility != .privateAccess {
                    TextField("TG-ABC123, 12345678", text: $collaboratorDraft, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Only the Terigo account codes listed here can edit. These codes resolve to Strava-backed Terigo accounts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let summaryText = audit.summaryText {
                Section("Shareability Warning") {
                    Text(summaryText)
                        .font(.body.weight(.semibold))

                    ForEach(audit.issues) { issue in
                        Text(issue.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Actions") {
                Button {
                    Task { await syncList() }
                } label: {
                    Label(isSyncing ? "Syncing…" : "Sync Sharing Settings", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncing || !accountManager.canUseBackendFeatures)

                if let shareURL = listSyncService.publicShareURL(for: list) {
                    ShareLink(item: shareURL) {
                        Label("Share Link", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        UIPasteboard.general.string = shareURL.absoluteString
                        statusMessage = "Copied the live share link."
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                }
            }

            if let errorMessage = errorMessage?.trimmed.nilIfEmpty {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if let statusMessage = statusMessage?.trimmed.nilIfEmpty {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sharing & Collaboration")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    dismiss()
                }
            }
        }
    }

    private var visibilityBinding: Binding<RouteListVisibilityMode> {
        Binding(
            get: { list.sharingVisibility },
            set: { newValue in
                list.sharingVisibility = newValue
                if newValue == .privateAccess {
                    list.collaborationMode = .ownerOnly
                } else if newValue == .invitedView && list.collaborationMode == .linkEditors {
                    list.collaborationMode = .ownerOnly
                }
                list.touch()
            }
        )
    }

    private var availableCollaborationModes: [RouteListCollaborationMode] {
        switch list.sharingVisibility {
        case .privateAccess:
            return [.ownerOnly]
        case .invitedView:
            return [.ownerOnly, .invitedEditors]
        case .linkView:
            return RouteListCollaborationMode.allCases
        }
    }

    private var collaborationBinding: Binding<RouteListCollaborationMode> {
        Binding(
            get: { list.collaborationMode },
            set: { newValue in
                list.collaborationMode = newValue
                if newValue == .ownerOnly {
                    collaboratorDraft = ""
                    list.collaboratorCodes = []
                }
                list.touch()
            }
        )
    }

    @MainActor
    private func syncList() async {
        guard !isSyncing else {
            return
        }

        isSyncing = true
        errorMessage = nil
        statusMessage = nil
        defer { isSyncing = false }

        if accountManager.isReviewerDemoActive {
            list.collaboratorCodes = collaboratorDraft
                .split(separator: ",")
                .compactMap { RouteVaultAccountCode.normalize(String($0)) }
            list.viewerCodes = viewerDraft
                .split(separator: ",")
                .compactMap { RouteVaultAccountCode.normalize(String($0)) }
            list.touch()
            try? modelContext.save()
            statusMessage = "Reviewer demo mode saved these sharing settings locally."
            return
        }

        if list.sharingVisibility == .invitedView && list.collaborationMode == .linkEditors {
            list.collaborationMode = .ownerOnly
        }

        list.collaboratorCodes = collaboratorDraft
            .split(separator: ",")
            .compactMap { RouteVaultAccountCode.normalize(String($0)) }
        list.viewerCodes = viewerDraft
            .split(separator: ",")
            .compactMap { RouteVaultAccountCode.normalize(String($0)) }

        do {
            let syncFingerprint = listSyncService.fingerprint(for: list, routes: routes)
            let response = try await listSyncService.sync(list: list, routes: routes)
            list.remoteListID = response.listID
            list.remoteOwnerAccountID = response.ownerAccountID
            list.remoteShareToken = response.shareToken
            list.remoteRevision = response.revision
            list.lastRemoteSyncAt = response.updatedAt
            list.lastRemoteSyncFingerprint = syncFingerprint
            list.updatedAt = response.updatedAt
            try modelContext.save()

            if response.shareabilityIssues.contains(where: { $0.kind == .privateRouteMissingDownloadedDetails }) {
                statusMessage = "List synced. Some private routes are still blocked from shared viewers until route details are downloaded."
            } else {
                statusMessage = "List synced to your Terigo account."
            }
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    private func displayMessage(for error: Error) -> String {
        if let error = error as? LocalizedError,
           let description = error.errorDescription {
            return description
        }

        return error.localizedDescription
    }
}
