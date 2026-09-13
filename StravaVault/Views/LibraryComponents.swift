import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct RouteVaultToolbarIconGlyph: View {
    let systemImage: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .semibold))
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
    }
}

struct RouteVaultToolbarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RouteVaultToolbarIconGlyph(systemImage: systemImage)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct DeletedRoutesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: RouteLibraryModel

    var body: some View {
        Group {
            if model.deletedRoutes.isEmpty {
                ContentUnavailableView(
                    "No Deleted Routes",
                    systemImage: "trash.slash",
                    description: Text("Deleted Strava routes stay blocked from sync until you restore them here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.deletedRoutes.count > 1 {
                            Button("Undelete All", action: model.restoreAllDeletedRoutes)
                                .buttonStyle(.borderedProminent)
                        }

                        ForEach(model.deletedRoutes) { tombstone in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tombstone.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    Text("Deleted \(RouteDisplayFormatter.absoluteDate(tombstone.deletedAt))")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 0)

                                Button("Undelete") {
                                    model.restoreDeletedRoute(tombstone)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                    }
                    .padding(20)
                }
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
            }
        }
        .navigationTitle("Deleted Routes")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("deleted-routes-screen")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close") {
                    dismiss()
                }
            }
        }
    }
}

struct ConnectionSection: View {
    @Bindable var model: RouteLibraryModel

    private var isReconnectState: Bool {
        model.errorMessage?.localizedCaseInsensitiveContains("reconnect") == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isReconnectState ? "Reconnect Strava" : "Connect Strava")
                        .font(.system(.title3, design: .rounded, weight: .bold))

                    Text(
                        isReconnectState
                            ? "Your previous Strava session is no longer valid. Reauthorize the account to resume route sync and exports."
                            : "This app uses its built-in Strava app configuration. The only user action is authorizing account access."
                    )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "link.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color(red: 0.85, green: 0.36, blue: 0.18))
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Redirect URI: \(model.redirectURI)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)

                Button {
                    Task { await model.connect() }
                } label: {
                    if model.isConnecting {
                        ProgressView()
                    } else {
                        Text(isReconnectState ? "Reconnect Strava" : "Connect Strava")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.85, green: 0.36, blue: 0.18))
            }
        }
        .padding(20)
        .routePanelSurface(cornerRadius: 30)
    }
}

enum RouteLibraryActivityState {
    case connecting
    case syncing
    case syncingProgress(completed: Int, total: Int, isEstimated: Bool)
    case importingGPX
    case syncingAndImporting
    case syncingAndImportingProgress(completed: Int, total: Int, isEstimated: Bool)
    case indexingStartLocations(completed: Int, total: Int)

    var symbolName: String {
        switch self {
        case .connecting:
            return "link.badge.plus"
        case .syncing:
            return "arrow.trianglehead.2.clockwise"
        case .syncingProgress:
            return "arrow.trianglehead.2.clockwise"
        case .importingGPX:
            return "square.and.arrow.down.on.square"
        case .syncingAndImporting:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .syncingAndImportingProgress:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .indexingStartLocations:
            return "magnifyingglass.circle"
        }
    }

    var title: String {
        switch self {
        case .connecting:
            return "Connecting Strava"
        case .syncing:
            return "Syncing Route Library"
        case .syncingProgress:
            return "Syncing Route Library"
        case .importingGPX:
            return "Importing GPX Routes"
        case .syncingAndImporting:
            return "Refreshing Local Library"
        case .syncingAndImportingProgress:
            return "Refreshing Local Library"
        case .indexingStartLocations:
            return "Indexing Start Locations"
        }
    }

    var message: String {
        switch self {
        case .connecting:
            return "Finishing authorization and preparing access to your routes."
        case .syncing:
            return "Pulling the latest routes from Strava. You can keep browsing while the library refreshes."
        case let .syncingProgress(completed, total, isEstimated):
            return "\(completed.formatted())/\(totalProgressLabelValue(total, isEstimated: isEstimated)) routes downloaded from Strava so far. You can keep browsing while the library refreshes."
        case .importingGPX:
            return "Parsing files, deriving start locations, and saving routes locally."
        case .syncingAndImporting:
            return "Strava sync and GPX import are both running. The route list will refresh as work completes."
        case let .syncingAndImportingProgress(completed, total, isEstimated):
            return "\(completed.formatted())/\(totalProgressLabelValue(total, isEstimated: isEstimated)) routes downloaded from Strava while GPX import also runs."
        case let .indexingStartLocations(completed, total):
            return "\(completed.formatted())/\(max(total, 1).formatted()) routes indexed for better search and start-area filtering."
        }
    }

    var progress: (completed: Int, total: Int)? {
        switch self {
        case let .syncingProgress(completed, total, _):
            return (completed, max(total, 1))
        case let .syncingAndImportingProgress(completed, total, _):
            return (completed, max(total, 1))
        case let .indexingStartLocations(completed, total):
            return (completed, max(total, 1))
        case .connecting, .syncing, .importingGPX, .syncingAndImporting:
            return nil
        }
    }

    var progressLabel: String? {
        switch self {
        case let .syncingProgress(completed, total, isEstimated):
            return "\(completed.formatted())/\(totalProgressLabelValue(total, isEstimated: isEstimated))"
        case let .syncingAndImportingProgress(completed, total, isEstimated):
            return "\(completed.formatted())/\(totalProgressLabelValue(total, isEstimated: isEstimated))"
        case let .indexingStartLocations(completed, total):
            return "\(completed.formatted())/\(max(total, 1).formatted())"
        case .connecting, .syncing, .importingGPX, .syncingAndImporting:
            return nil
        }
    }

    private func totalProgressLabelValue(_ total: Int, isEstimated: Bool) -> String {
        let formattedTotal = max(total, 1).formatted()
        return isEstimated ? "\(formattedTotal)+" : formattedTotal
    }
}

struct LibraryActivityBanner: View {
    @Environment(\.colorScheme) private var colorScheme

    let state: RouteLibraryActivityState

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(colorScheme == .dark ? 0.20 : 0.12))
                    .frame(width: 38, height: 38)

                Image(systemName: state.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(state.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)

                Text(state.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let progress = state.progress {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(state.progressLabel ?? "\(progress.completed.formatted())/\(progress.total.formatted())")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .tint(accent)
                        .frame(width: 88)
                }
                .padding(.top, 2)
            } else {
                ProgressView()
                    .tint(accent)
                    .controlSize(.regular)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var accent: Color {
        Color(red: 0.93, green: 0.45, blue: 0.20)
    }

    private var background: Color {
        colorScheme == .dark
            ? Color(red: 0.19, green: 0.13, blue: 0.10)
            : Color(red: 0.98, green: 0.93, blue: 0.89)
    }

    private var border: Color {
        accent.opacity(colorScheme == .dark ? 0.25 : 0.18)
    }
}

struct DisconnectedEmptyState: View {
    let isImportingGPX: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Once Strava is connected, this screen becomes the full route workspace.")
                .font(.system(.title3, design: .rounded, weight: .bold))

            Text(descriptionText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .routePanelSurface(cornerRadius: 28)
    }

    private var descriptionText: String {
        if isImportingGPX {
            return "GPX import is in progress. Starting locations are derived from the first route point in each file."
        }

        return "You can sync the athlete’s routes from Strava or import GPX files from the top-right menu, then search by start location, sort by distance or climbing, and manage local collections without leaving this page."
    }
}

struct BannerView: View {
    @Environment(\.colorScheme) private var colorScheme
    enum Tone {
        case success
        case error
    }

    let message: String
    let tone: Tone

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var foreground: Color {
        switch tone {
        case .success:
            return colorScheme == .dark ? Color(red: 0.66, green: 0.91, blue: 0.72) : Color(red: 0.20, green: 0.42, blue: 0.22)
        case .error:
            return colorScheme == .dark ? Color(red: 1, green: 0.72, blue: 0.70) : Color(red: 0.62, green: 0.18, blue: 0.18)
        }
    }

    private var background: Color {
        switch tone {
        case .success:
            return colorScheme == .dark
                ? Color(red: 0.10, green: 0.24, blue: 0.15)
                : Color(red: 0.88, green: 0.95, blue: 0.88)
        case .error:
            return colorScheme == .dark
                ? Color(red: 0.28, green: 0.12, blue: 0.13)
                : Color(red: 0.98, green: 0.90, blue: 0.90)
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("route-library-search")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, text.isEmpty ? 14 : 0)
        .frame(minHeight: 50)
        .background(TerigoTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

struct FilterPanel<Content: View>: View {
    let title: String
    let caption: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                if let caption = caption.nilIfEmpty {
                    Text(caption)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .padding(16)
        .routePanelSurface(cornerRadius: 28)
    }
}


extension View {
    func routePanelSurface(cornerRadius: CGFloat) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    @ViewBuilder
    func routeControlSurface(isActive: Bool, cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(
                    isActive
                        ? .regular.tint(Color(red: 0.95, green: 0.63, blue: 0.48)).interactive()
                        : .regular.interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isActive ? Color(red: 0.95, green: 0.63, blue: 0.48).opacity(0.18) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            isActive ? Color(red: 0.95, green: 0.63, blue: 0.48).opacity(0.35) : Color.primary.opacity(0.08),
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension UTType {
    static var gpxRoute: UTType {
        UTType(filenameExtension: "gpx") ?? .xml
    }
}

extension Comparable {
    func routeClamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Shared semantic colors adapt to appearance and accessibility contrast.
enum TerigoTheme {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.56, blue: 0.32, alpha: 1)
            : UIColor(red: 0.72, green: 0.25, blue: 0.10, alpha: 1)
    })
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.045, green: 0.055, blue: 0.052, alpha: 1)
            : UIColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.085, green: 0.10, blue: 0.095, alpha: 1)
            : .white
    })
}
