import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct RouteVaultAccountSettingsSheet: View {
    @Environment(RouteVaultAccountManager.self) private var accountManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var isConfirmingAccountDeletion = false
    @State private var isConfirmingDemoExit = false

    var body: some View {
        Form {
            if accountManager.isReviewerDemoActive {
                Section("Reviewer Demo Mode") {
                    Text("This device is using seeded local demo routes, lists, and activities so App Review can exercise the full app without a live Strava account.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Exit Demo Mode", role: .destructive) {
                        isConfirmingDemoExit = true
                    }
                }
            }

            Section("Terigo Account") {
                if let profile = accountManager.accountSession?.profile {
                    LabeledContent("Name", value: profile.displayName)
                    LabeledContent("Account Code", value: profile.accountCode)
                } else {
                    Text(accountManager.backendStatusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sharing Identity") {
                if let accountCode = accountManager.accountCode {
                    Button {
                        UIPasteboard.general.string = accountCode
                        accountManager.statusMessage = "Copied your Terigo account code."
                    } label: {
                        Label("Copy Account Code", systemImage: "doc.on.doc")
                    }
                }

                Text(accountManager.isReviewerDemoActive
                     ? "Reviewer demo mode keeps sharing local to this device. The account code is shown so list-sharing screens still demonstrate the full flow."
                     : "Private collaboration now uses Strava-backed Terigo account codes instead of invite email. Share this code with friends so they can be added to specific-viewer or specific-editor lists.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !accountManager.isReviewerDemoActive,
               accountManager.accountSession != nil {
                Section("Account Data") {
                    Text("Deleting your account removes your hosted Terigo profile, synced lists, sharing permissions, feedback, and stored shared-route files. Routes saved only on this iPhone stay on the device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Delete Terigo Account", role: .destructive) {
                        isConfirmingAccountDeletion = true
                    }
                    .disabled(accountManager.isDeletingAccount)
                }
            }

            if let errorMessage = accountManager.errorMessage?.trimmed.nilIfEmpty {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            } else if let statusMessage = accountManager.statusMessage?.trimmed.nilIfEmpty {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .alert("Clear the demo library?", isPresented: $isConfirmingDemoExit) {
            Button("Exit and Clear Demo", role: .destructive) {
                accountManager.deactivateReviewDemo(using: modelContext)
                if !accountManager.isReviewerDemoActive { dismiss() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the demo routes, lists, activities, and offline files, including anything you added during demo mode.")
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .confirmationDialog(
            "Delete your Terigo account?",
            isPresented: $isConfirmingAccountDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Account and Hosted Data", role: .destructive) {
                Task {
                    if await accountManager.deleteAccount() {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Your Strava account is not deleted, and routes stored only on this iPhone remain until you remove them or delete the app.")
        }
    }
}

struct RouteVaultFeedbackSheet: View {
    @Environment(RouteVaultAccountManager.self) private var accountManager
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Testing Feedback") {
                Text(accountManager.isReviewerDemoActive
                     ? "Reviewer demo mode keeps feedback on-device only. Use this screen to verify the flow without sending anything to the live backend."
                     : "Use this temporary testing form to report bugs, friction, or ideas directly from the app. Terigo will attach the feedback to your signed-in account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if message.trimmed.isEmpty {
                        Text("What happened? What were you trying to do?")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }

                    TextEditor(text: $message)
                        .frame(minHeight: 180)
                        .onChange(of: message) { _, newValue in
                            if newValue.count > 4_000 {
                                message = String(newValue.prefix(4_000))
                            }
                        }
                }

                Text("\(message.count)/4,000")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let accountCode = accountManager.accountCode {
                Section("Account") {
                    LabeledContent("From", value: accountCode)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Send Feedback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(isSubmitting ? "Sending…" : "Send") {
                    Task { await submitFeedback() }
                }
                .disabled(isSubmitting || message.trimmed.isEmpty)
            }
        }
    }

    @MainActor
    private func submitFeedback() async {
        if accountManager.isReviewerDemoActive {
            accountManager.errorMessage = nil
            accountManager.statusMessage = "Reviewer demo mode keeps feedback local only."
            dismiss()
            return
        }

        guard let accountSession = accountManager.accountSession else {
            errorMessage = "Terigo account sync is still reconnecting. Try again in a moment."
            return
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await RouteVaultBackendService().submitFeedback(
                message: message.trimmed,
                sourceScreen: "route_library",
                accountSessionToken: accountSession.token
            )
            accountManager.errorMessage = nil
            accountManager.statusMessage = "Feedback sent. Thanks for testing Terigo."
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

