import CoreLocation
import MapboxMaps
import SwiftUI
import UIKit

private enum RouteTrackingCameraFollowMode {
    case centered
    case courseFollowing
}

struct RouteTrackingView: View {
    private static let signalFreshnessThreshold: TimeInterval = 25
    private static let suppressReducedTrackingPromptStorageKey = "routeTrackingSuppressBatterySaverPrompt"
    private static let suppressContinuousTrackingPromptStorageKey = "routeTrackingSuppressContinuousTrackingPrompt"

    @AppStorage(Self.suppressReducedTrackingPromptStorageKey) private var suppressReducedTrackingPrompt = false
    @AppStorage(Self.suppressContinuousTrackingPromptStorageKey) private var suppressContinuousTrackingPrompt = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let route: RouteRecord

    @StateObject private var session: RouteTrackingSession
    @State private var followsUser = true
    @State private var cameraFollowMode: RouteTrackingCameraFollowMode = .centered
    @State private var recenterTrigger = 0
    @State private var isShowingEndConfirmation = false
    @State private var isControlPanelHidden = false
    @State private var activeElevationDistanceMeters: Double?
    @State private var lockedElevationDistanceMeters: Double?
    @State private var isShowingElevationChart = true
    @State private var controlPanelHeight: CGFloat = 0
    @State private var isShowingReducedTrackingPrompt = false
    @State private var isShowingContinuousTrackingPrompt = false

    init(route: RouteRecord) {
        self.route = route
        _session = StateObject(
            wrappedValue: RouteTrackingSession(
                route: route,
                screenshotPreview: AppStoreScreenshotSupport.trackingPreview(for: route)
            )
        )
    }

    private var progress: RouteTrackingProgress? {
        session.progress
    }

    private var screenshotPreviewElevationSamples: [RouteElevationSample] {
        AppStoreScreenshotSupport.previewElevationProfile(for: route)
    }

    private var resolvedElevationSamples: [RouteElevationSample] {
        let routeSamples = route.elevationProfile
        if routeSamples.count > 1 {
            return routeSamples
        }

        return screenshotPreviewElevationSamples
    }

    private var closeButtonLabel: String {
        switch session.phase {
        case .tracking, .locating, .paused:
            return "End activity"
        default:
            return "Close"
        }
    }

    private var currentProgressDistanceMeters: Double? {
        progress?.currentProgressDistanceMeters
    }

    private var currentElevationSample: RouteElevationSample? {
        guard let currentProgressDistanceMeters else {
            return nil
        }

        return nearestElevationSample(in: resolvedElevationSamples, to: currentProgressDistanceMeters)
    }

    private var canShowElevationChart: Bool {
        resolvedElevationSamples.count > 1
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if session.hasTrackableGeometry {
                RouteTrackingMapSurface(
                    route: route,
                    session: session,
                    followsUser: followsUser,
                    cameraFollowMode: cameraFollowMode,
                    recenterTrigger: recenterTrigger,
                    bottomOverlayHeight: isControlPanelHidden ? 0 : controlPanelHeight,
                    userInterfaceStyle: colorScheme == .dark ? UIUserInterfaceStyle.dark : UIUserInterfaceStyle.light,
                    onUserCameraInteraction: handleUserCameraInteraction
                )
                .ignoresSafeArea()
            } else {
                ContentUnavailableView(
                    "Route Tracking Unavailable",
                    systemImage: "figure.walk.motion",
                    description: Text("This route does not have enough geometry to start a tracked activity.")
                )
                .foregroundStyle(.white)
                .padding(24)
            }

            VStack(spacing: 14) {
                headerBar
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 18)

            VStack {
                Spacer(minLength: 0)
                bottomOverlay
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
        .background(Color.black.ignoresSafeArea())
        .accessibilityIdentifier("route-tracking-screen-\(route.stravaRouteID)")
        .routeTrackingIdleTimerDisabled(session.keepsScreenAwake)
        .interactiveDismissDisabled(true)
        .task {
            if session.phase == .idle {
                session.startActivity()
            }
        }
        .confirmationDialog(
            "End Activity?",
            isPresented: $isShowingEndConfirmation,
            titleVisibility: Visibility.visible
        ) {
            Button("End Activity", role: .destructive) {
                session.finishActivity()
            }
            .accessibilityIdentifier("route-tracking-confirm-end")
            Button("Keep Tracking", role: .cancel) { }
                .accessibilityIdentifier("route-tracking-cancel-end")
        } message: {
            Text("Ending the activity stops live route tracking for this session.")
        }
        .alert(
            "Turn Off Continuous GPS?",
            isPresented: $isShowingReducedTrackingPrompt
        ) {
            Button("Keep Continuous GPS", role: .cancel) { }
                .accessibilityIdentifier("route-tracking-continuous-gps-keep")
            Button("Turn Off Continuous GPS") {
                session.enableBatterySaver()
            }
            .accessibilityIdentifier("route-tracking-continuous-gps-turn-off")
            Button("Turn Off And Don’t Show Again") {
                suppressReducedTrackingPrompt = true
                session.enableBatterySaver()
            }
            .accessibilityIdentifier("route-tracking-continuous-gps-turn-off-dont-show")
        } message: {
            Text("Terigo will stop continuous GPS updates while the app is in the background or your phone is locked. Your position will refresh the next time you reopen the app during this activity.")
        }
        .alert(
            "Enable Continuous GPS?",
            isPresented: $isShowingContinuousTrackingPrompt
        ) {
            Button("Not Now", role: .cancel) { }
                .accessibilityIdentifier("route-tracking-continuous-gps-not-now")
            Button("Enable Continuous GPS") {
                session.enableContinuousTracking()
            }
            .accessibilityIdentifier("route-tracking-continuous-gps-enable")
            Button("Enable And Don’t Show Again") {
                suppressContinuousTrackingPrompt = true
                session.enableContinuousTracking()
            }
            .accessibilityIdentifier("route-tracking-continuous-gps-enable-dont-show")
        } message: {
            Text("Terigo will keep GPS updates running while the app is in the background or your phone is locked. This uses more battery, but off-route alerts can keep working without reopening the app.")
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button(action: handleCloseTapped) {
                Image(systemName: session.canFinish ? "xmark" : "chevron.down")
                    .font(.headline.weight(.bold))
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(closeButtonLabel)
            .accessibilityIdentifier("route-tracking-close")

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                RouteMapSettingsButton()

                Button {
                    cameraFollowMode = cameraFollowMode == .centered ? .courseFollowing : .centered
                    recenterTrigger += 1
                    followsUser = true
                } label: {
                    Image(systemName: "scope")
                        .font(.headline.weight(.bold))
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Recenter on current location")
                .accessibilityIdentifier("route-tracking-recenter")

                batterySaverButton
            }
        }
    }

    @ViewBuilder
    private var bottomOverlay: some View {
        if isControlPanelHidden {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isControlPanelHidden = false
                    if canShowElevationChart {
                        isShowingElevationChart = true
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "eye")
                        .font(.caption.weight(.bold))
                    Text(canShowElevationChart ? "Show route profile" : "Show tracking stats")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show tracking controls")
            .accessibilityIdentifier("route-tracking-show-controls")
        } else {
            controlPanel
        }
    }

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if canShowElevationChart {
                if isShowingElevationChart {
                    RouteElevationChartPanel(
                        route: route,
                        activeDistanceMeters: $activeElevationDistanceMeters,
                        lockedDistanceMeters: $lockedElevationDistanceMeters,
                        panelStyle: .trackingCompact,
                        isLoading: false,
                        unavailableMessage: "No elevation profile is available for this route.",
                        currentProgressDistanceMeters: currentProgressDistanceMeters,
                        onToggleVisibility: toggleElevationChartVisibility,
                        sampleOverride: screenshotPreviewElevationSamples.isEmpty ? nil : screenshotPreviewElevationSamples
                    )
                } else {
                    collapsedElevationRow
                }
            }

            metricsGrid

            if session.permissionDenied {
                permissionActionRow
            }

            if session.showsOffRouteAlertControls {
                notificationActionRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: RouteTrackingPanelHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(RouteTrackingPanelHeightPreferenceKey.self) { newValue in
            guard abs(newValue - controlPanelHeight) > 1 else {
                return
            }
            controlPanelHeight = newValue
            if followsUser {
                recenterTrigger += 1
            }
        }
    }

    private var metricsGrid: some View {
        HStack(spacing: 6) {
            RouteTrackingMiniMetric(
                title: "Done",
                value: RouteDisplayFormatter.distance(progress?.completedProgressDistanceMeters ?? 0)
            )
            RouteTrackingMiniMetric(
                title: "Left",
                value: RouteDisplayFormatter.distance(progress?.remainingDistanceMeters ?? max(route.distanceMeters, 0))
            )
            RouteTrackingMiniMetric(
                title: "Tracking",
                value: trackingStatusMetric.value,
                valueTint: trackingStatusMetric.tint
            )
        }
    }

    private var batterySaverButton: some View {
        Button(action: handleBatterySaverTapped) {
            Image(systemName: session.usesContinuousTracking ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(
                    session.usesContinuousTracking
                        ? Color(red: 0.18, green: 0.82, blue: 0.69)
                        : Color.white
                )
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(
                    session.usesContinuousTracking
                        ? Color(red: 0.18, green: 0.82, blue: 0.69)
                        : Color(red: 0.96, green: 0.71, blue: 0.24)
                )
                .frame(width: 10, height: 10)
                .overlay {
                    Circle()
                        .strokeBorder(Color.black.opacity(0.18), lineWidth: 1)
                }
                .offset(x: -3, y: -3)
        }
        .overlay {
            Circle()
                .strokeBorder(
                    session.usesContinuousTracking
                        ? Color(red: 0.18, green: 0.82, blue: 0.69).opacity(0.32)
                        : Color.white.opacity(0.08),
                    lineWidth: 1
                )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Continuous GPS")
        .accessibilityValue(session.usesContinuousTracking ? "On" : "Off")
        .accessibilityHint(
            session.usesContinuousTracking
                ? "Turns off continuous GPS tracking."
                : "Turns on continuous GPS tracking."
        )
        .accessibilityIdentifier("route-tracking-battery-saver")
    }

    private var collapsedElevationRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isShowingElevationChart = true
                isControlPanelHidden = false
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "mountain.2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.96, green: 0.71, blue: 0.24))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Elevation")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    if let currentElevationSample,
                       let currentProgressDistanceMeters {
                        Text("\(RouteDisplayFormatter.distance(currentProgressDistanceMeters)) • \(RouteDisplayFormatter.altitude(currentElevationSample.elevationMeters))")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    } else {
                        Text("Show route profile")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "eye")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show elevation chart")
        .accessibilityIdentifier("route-tracking-show-elevation")
    }

    private var permissionActionRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Location Required")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("Enable location access in Settings to track your position along this route.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("Settings", action: openSettings)
                .buttonStyle(.borderedProminent)
        }
    }

    private var notificationActionRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Off-Route Alerts")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("Allow notifications so Terigo can alert you if you drift off the saved route while the app is in the background or the screen is locked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if session.notificationPermissionDenied {
                Button("Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Allow Alerts", action: session.requestNotificationAuthorization)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var hasFreshTrackingSignal: Bool {
        guard let lastUpdatedAt = session.lastUpdatedAt ?? session.currentLocation?.timestamp else {
            return false
        }

        let age = abs(lastUpdatedAt.timeIntervalSinceNow)
        guard age <= Self.signalFreshnessThreshold else {
            return false
        }

        guard let currentLocation = session.currentLocation else {
            return false
        }

        guard currentLocation.horizontalAccuracy >= 0,
              currentLocation.horizontalAccuracy <= 100 else {
            return false
        }

        return true
    }

    private var trackingStatusMetric: (value: String, tint: Color) {
        if session.phase == .awaitingPermission || session.permissionDenied || !hasFreshTrackingSignal || progress == nil {
            return (
                value: "No Signal",
                tint: Color(red: 0.96, green: 0.71, blue: 0.24)
            )
        }

        if progress?.isOffRoute == true {
            return (
                value: "Off Course",
                tint: Color(red: 0.98, green: 0.52, blue: 0.43)
            )
        }

        return (
            value: "On Course",
            tint: Color(red: 0.34, green: 0.86, blue: 0.64)
        )
    }

    private func handleCloseTapped() {
        switch session.phase {
        case .tracking, .locating, .paused:
            isShowingEndConfirmation = true
        default:
            session.clearPersistedActivity()
            dismiss()
        }
    }

    private func handleEndTapped() {
        switch session.phase {
        case .completed, .finished:
            dismiss()
        case .tracking, .locating, .paused:
            isShowingEndConfirmation = true
        default:
            dismiss()
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }

        UIApplication.shared.open(url)
    }

    private func toggleElevationChartVisibility() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if isShowingElevationChart {
                isShowingElevationChart = false
                isControlPanelHidden = true
                activeElevationDistanceMeters = nil
                lockedElevationDistanceMeters = nil
            } else {
                isControlPanelHidden = false
                isShowingElevationChart = true
            }
        }
    }

    private func handleBatterySaverTapped() {
        if session.usesContinuousTracking {
            if suppressReducedTrackingPrompt {
                session.enableBatterySaver()
            } else {
                isShowingReducedTrackingPrompt = true
            }
        } else {
            if suppressContinuousTrackingPrompt {
                session.enableContinuousTracking()
            } else {
                isShowingContinuousTrackingPrompt = true
            }
        }
    }

    private func handleUserCameraInteraction() {
        guard followsUser else {
            return
        }

        followsUser = false
    }

    private func nearestElevationSample(
        in samples: [RouteElevationSample],
        to distanceMeters: Double
    ) -> RouteElevationSample? {
        guard !samples.isEmpty else {
            return nil
        }

        if distanceMeters <= samples[0].distanceMeters {
            return samples[0]
        }

        if let lastSample = samples.last, distanceMeters >= lastSample.distanceMeters {
            return lastSample
        }

        var lowerIndex = 0
        var upperIndex = samples.count - 1

        while lowerIndex + 1 < upperIndex {
            let middleIndex = (lowerIndex + upperIndex) / 2
            if samples[middleIndex].distanceMeters < distanceMeters {
                lowerIndex = middleIndex
            } else {
                upperIndex = middleIndex
            }
        }

        let lowerSample = samples[lowerIndex]
        let upperSample = samples[upperIndex]
        return abs(lowerSample.distanceMeters - distanceMeters) <= abs(upperSample.distanceMeters - distanceMeters)
            ? lowerSample
            : upperSample
    }
}

private struct RouteTrackingStatusBadge: View {
    let phase: RouteTrackingPhase

    private var tint: Color {
        switch phase {
        case .tracking:
            return Color(red: 0.16, green: 0.78, blue: 0.67)
        case .paused:
            return Color(red: 0.96, green: 0.71, blue: 0.24)
        case .completed:
            return Color(red: 0.26, green: 0.80, blue: 0.60)
        case .awaitingPermission, .locating:
            return Color(red: 0.46, green: 0.67, blue: 0.98)
        case .finished:
            return Color(red: 0.76, green: 0.76, blue: 0.80)
        case .idle:
            return Color(red: 0.72, green: 0.72, blue: 0.76)
        }
    }

    var body: some View {
        Text(phase.title)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

private struct RouteTrackingMetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct RouteTrackingCompactMetricPill: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(1)

                Text(value)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct RouteTrackingMiniMetric: View {
    let title: String
    let value: String
    let valueTint: Color

    init(title: String, value: String, valueTint: Color = .primary) {
        self.title = title
        self.value = value
        self.valueTint = valueTint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)

            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RouteTrackingPanelHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct RouteTrackingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .padding(.vertical, 14)
            .foregroundStyle(.black)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.18, green: 0.82, blue: 0.69).opacity(configuration.isPressed ? 0.85 : 1))
            )
    }
}

private struct RouteTrackingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
    }
}

private struct RouteTrackingMapSurface: UIViewRepresentable {
    @AppStorage(AppRouteMapStyle.storageKey) private var appRouteMapStyleRawValue = AppRouteMapStyle.defaultValue.rawValue
    @AppStorage(AppRouteMapPerspective.storageKey) private var appRouteMapPerspectiveRawValue = AppRouteMapPerspective.defaultValue.rawValue

    let route: RouteRecord
    @ObservedObject var session: RouteTrackingSession
    let followsUser: Bool
    let cameraFollowMode: RouteTrackingCameraFollowMode
    let recenterTrigger: Int
    let bottomOverlayHeight: CGFloat
    let userInterfaceStyle: UIUserInterfaceStyle
    let onUserCameraInteraction: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MapView {
        RouteVaultMapboxConfiguration.configure()

        let mapView = MapView(
            frame: .zero,
            mapInitOptions: MapInitOptions(
                mapStyle: appRouteMapStyle.resolvedStyle(for: route, colorScheme: userInterfaceStyle),
                cameraOptions: CameraOptions(
                    center: route.startCoordinate,
                    zoom: 10.5,
                    pitch: appRouteMapPerspective.isThreeDimensional ? appRouteMapPerspective.pitch : 0
                )
            )
        )

        context.coordinator.bind(to: mapView)
        configureMapView(mapView)
        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        configureMapView(mapView)
        context.coordinator.update(
            mapView: mapView,
            route: route,
            progress: session.progress,
            currentLocation: session.currentLocation,
            breadcrumbCoordinates: session.breadcrumbCoordinates,
            followsUser: followsUser,
            cameraFollowMode: cameraFollowMode,
            recenterTrigger: recenterTrigger,
            bottomOverlayHeight: bottomOverlayHeight,
            userInterfaceStyle: userInterfaceStyle,
            routeMapStyle: appRouteMapStyle,
            perspective: appRouteMapPerspective
            ,
            onUserCameraInteraction: onUserCameraInteraction
        )
    }

    private func configureMapView(_ mapView: MapView) {
        mapView.gestures.options.rotateEnabled = true
        mapView.gestures.options.pitchEnabled = appRouteMapPerspective.isThreeDimensional

        var ornamentOptions = mapView.ornaments.options
        ornamentOptions.compass.visibility = .adaptive
        ornamentOptions.scaleBar.visibility = .adaptive
        mapView.ornaments.options = ornamentOptions
    }

    private var appRouteMapStyle: AppRouteMapStyle {
        AppRouteMapStyle.resolved(from: appRouteMapStyleRawValue)
    }

    private var appRouteMapPerspective: AppRouteMapPerspective {
        AppRouteMapPerspective(rawValue: appRouteMapPerspectiveRawValue) ?? .defaultValue
    }

    final class Coordinator {
        private struct StaticState {
            let routeSignature: String
            let styleKey: String
            let perspectivePitch: CGFloat
        }

        private weak var mapView: MapView?
        private var cancelables = Set<AnyCancelable>()
        private var routeOutlineManager: PolylineAnnotationManager?
        private var routeBaseLineManager: PolylineAnnotationManager?
        private var routeCompletedManager: PolylineAnnotationManager?
        private var breadcrumbManager: PolylineAnnotationManager?
        private var directionArrowManager: PointAnnotationManager?
        private var markerManager: PointAnnotationManager?
        private var lastStaticState: StaticState?
        private var lastFollowCoordinate: CLLocationCoordinate2D?
        private var lastRecenteringToken: Int = 0
        private var hasAppliedInitialCamera = false
        private var latestRoute: RouteRecord?
        private var latestProgress: RouteTrackingProgress?
        private var latestCurrentLocation: CLLocation?
        private var latestBreadcrumbCoordinates: [CLLocationCoordinate2D] = []
        private var latestFollowsUser = true
        private var latestCameraFollowMode: RouteTrackingCameraFollowMode = .centered
        private var latestPerspective: AppRouteMapPerspective = .defaultValue
        private var latestBottomOverlayHeight: CGFloat = 0
        private var onUserCameraInteraction: (() -> Void)?
        private var ignoreManualCameraChangesUntil: CFAbsoluteTime = 0
        private var didReportManualCameraWhileFollowing = false
        private var cameraChangeArrowRefreshTask: Task<Void, Never>?

        func bind(to mapView: MapView) {
            guard self.mapView !== mapView else {
                return
            }

            cancelables.removeAll()
            self.mapView = mapView

            mapView.mapboxMap.onStyleLoaded.observeNext { [weak self, weak mapView] _ in
                guard let self, let mapView else {
                    return
                }

                RouteMapTerrainTuning.apply(
                    to: mapView.mapboxMap,
                    perspective: self.latestPerspective
                )
                self.recreateManagers(on: mapView)
                self.reapplyLatestState(on: mapView)
            }
            .store(in: &cancelables)

            mapView.mapboxMap.onCameraChanged.observe { [weak self] _ in
                guard let self else {
                    return
                }

                self.cameraChangeArrowRefreshTask?.cancel()
                self.cameraChangeArrowRefreshTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(75))
                    guard let self, !Task.isCancelled else {
                        return
                    }

                    self.refreshDirectionArrowsForCurrentCamera()
                }

                guard self.latestFollowsUser else {
                    self.didReportManualCameraWhileFollowing = false
                    return
                }

                let now = CFAbsoluteTimeGetCurrent()
                guard now > self.ignoreManualCameraChangesUntil else {
                    return
                }

                guard !self.didReportManualCameraWhileFollowing else {
                    return
                }

                self.didReportManualCameraWhileFollowing = true
                DispatchQueue.main.async { [weak self] in
                    self?.onUserCameraInteraction?()
                }
            }
            .store(in: &cancelables)
        }

        func update(
            mapView: MapView,
            route: RouteRecord,
            progress: RouteTrackingProgress?,
            currentLocation: CLLocation?,
            breadcrumbCoordinates: [CLLocationCoordinate2D],
            followsUser: Bool,
            cameraFollowMode: RouteTrackingCameraFollowMode,
            recenterTrigger: Int,
            bottomOverlayHeight: CGFloat,
            userInterfaceStyle: UIUserInterfaceStyle,
            routeMapStyle: AppRouteMapStyle,
            perspective: AppRouteMapPerspective,
            onUserCameraInteraction: @escaping () -> Void
        ) {
            ensureManagers(on: mapView)

            latestRoute = route
            latestProgress = progress
            latestCurrentLocation = currentLocation
            latestBreadcrumbCoordinates = breadcrumbCoordinates
            latestFollowsUser = followsUser
            latestCameraFollowMode = cameraFollowMode
            latestPerspective = perspective
            self.onUserCameraInteraction = onUserCameraInteraction
            let bottomInsetDidChange = abs(bottomOverlayHeight - latestBottomOverlayHeight) > 1
            latestBottomOverlayHeight = bottomOverlayHeight
            RouteMapTerrainTuning.apply(
                to: mapView.mapboxMap,
                perspective: perspective
            )

            let routeSignature = "\(route.stravaRouteID)|\(route.routeGeometryPolyline)"
            let styleKey = "\(routeMapStyle.rawValue)-\(userInterfaceStyle.rawValue)-\(route.prefersOutdoorsMapStyle)"
            let staticState = StaticState(
                routeSignature: routeSignature,
                styleKey: styleKey,
                perspectivePitch: perspective.pitch
            )
            let styleDidChange = styleKey != lastStaticState?.styleKey
            let routeDidChange = routeSignature != lastStaticState?.routeSignature
            let perspectiveDidChange = staticState.perspectivePitch != lastStaticState?.perspectivePitch

            if styleDidChange {
                mapView.mapboxMap.mapStyle = routeMapStyle.resolvedStyle(for: route, colorScheme: userInterfaceStyle)
                recreateManagers(on: mapView)
            }

            if routeDidChange || styleDidChange {
                renderRoute(route.routeCoordinates, surfaceKind: route.surfaceKind)
            }

            if routeDidChange || !hasAppliedInitialCamera || (!followsUser && perspectiveDidChange) {
                fitCamera(to: route.routeCoordinates, on: mapView, perspective: perspective)
                hasAppliedInitialCamera = true
            }

            renderDynamicState(
                route: route,
                progress: progress,
                currentLocation: currentLocation,
                breadcrumbCoordinates: breadcrumbCoordinates
            )

            if followsUser,
               let currentCoordinate = currentLocation?.coordinate {
                didReportManualCameraWhileFollowing = false
                center(
                    on: currentCoordinate,
                    course: currentLocation?.course,
                    in: mapView,
                    followMode: cameraFollowMode,
                    perspective: perspective,
                    forced: recenterTrigger != lastRecenteringToken || styleDidChange || perspectiveDidChange || bottomInsetDidChange
                )
            } else if recenterTrigger != lastRecenteringToken,
                      let currentCoordinate = currentLocation?.coordinate {
                center(
                    on: currentCoordinate,
                    course: currentLocation?.course,
                    in: mapView,
                    followMode: cameraFollowMode,
                    perspective: perspective,
                    forced: true
                )
            }

            lastRecenteringToken = recenterTrigger
            lastStaticState = staticState
        }

        private func reapplyLatestState(on mapView: MapView) {
            guard let latestRoute else {
                return
            }

            renderRoute(latestRoute.routeCoordinates, surfaceKind: latestRoute.surfaceKind)
            renderDynamicState(
                route: latestRoute,
                progress: latestProgress,
                currentLocation: latestCurrentLocation,
                breadcrumbCoordinates: latestBreadcrumbCoordinates
            )

            if latestFollowsUser,
               let currentCoordinate = latestCurrentLocation?.coordinate {
                center(
                    on: currentCoordinate,
                    course: latestCurrentLocation?.course,
                    in: mapView,
                    followMode: latestCameraFollowMode,
                    perspective: latestPerspective,
                    forced: true
                )
            }
        }

        private func renderRoute(_ coordinates: [CLLocationCoordinate2D], surfaceKind: RouteSurfaceKind?) {
            guard coordinates.count > 1 else {
                routeOutlineManager?.annotations = []
                routeBaseLineManager?.annotations = []
                directionArrowManager?.annotations = []
                return
            }

            var outlinePolyline = PolylineAnnotation(lineCoordinates: coordinates)
            outlinePolyline.lineColor = StyleColor(RouteMapLineStyle.outlineColor)
            outlinePolyline.lineWidth = RouteMapLineStyle.outlineWidth

            var routePolyline = PolylineAnnotation(lineCoordinates: coordinates)
            routePolyline.lineColor = StyleColor(RouteMapLineStyle.fillColor.withAlphaComponent(0.88))
            routePolyline.lineWidth = RouteMapLineStyle.fillWidth

            routeOutlineManager?.annotations = [outlinePolyline]
            routeBaseLineManager?.annotations = [routePolyline]
            routeBaseLineManager?.lineDasharray = surfaceKind == .paved ? nil : RouteMapLineStyle.unpavedDashPattern
            directionArrowManager?.annotations = RouteDirectionArrowRenderer.annotations(
                for: coordinates,
                imageNamePrefix: "route-tracking-direction-arrow",
                zoomLevel: mapView.map { CGFloat($0.mapboxMap.cameraState.zoom) },
                visibleBounds: mapView.map { $0.mapboxMap.coordinateBounds(for: $0.bounds) },
                emphasis: .tracking
            )
        }

        @MainActor
        private func refreshDirectionArrowsForCurrentCamera() {
            guard let latestRoute else {
                return
            }

            renderRoute(latestRoute.routeCoordinates, surfaceKind: latestRoute.surfaceKind)
        }

        private func renderDynamicState(
            route: RouteRecord,
            progress: RouteTrackingProgress?,
            currentLocation: CLLocation?,
            breadcrumbCoordinates: [CLLocationCoordinate2D]
        ) {
            if let progress,
               progress.traversedRouteCoordinates.count > 1 {
                var completedPolyline = PolylineAnnotation(lineCoordinates: progress.traversedRouteCoordinates)
                completedPolyline.lineColor = StyleColor(UIColor(red: 0.16, green: 0.82, blue: 0.68, alpha: 1))
                completedPolyline.lineWidth = RouteMapLineStyle.fillWidth + 1.2
                routeCompletedManager?.annotations = [completedPolyline]
            } else {
                routeCompletedManager?.annotations = []
            }

            if breadcrumbCoordinates.count > 1 {
                var breadcrumbPolyline = PolylineAnnotation(lineCoordinates: breadcrumbCoordinates)
                breadcrumbPolyline.lineColor = StyleColor(UIColor(red: 0.42, green: 0.67, blue: 0.99, alpha: 0.82))
                breadcrumbPolyline.lineWidth = 2.8
                breadcrumbManager?.annotations = [breadcrumbPolyline]
            } else {
                breadcrumbManager?.annotations = []
            }

            var pointAnnotations: [PointAnnotation] = []

            if let startCoordinate = route.startCoordinate {
                var startMarker = PointAnnotation(coordinate: startCoordinate)
                startMarker.image = .init(image: markerImage(fill: UIColor.white, size: 18, stroke: UIColor(red: 0.96, green: 0.58, blue: 0.24, alpha: 1)), name: "route-tracking-start")
                pointAnnotations.append(startMarker)
            }

            if let endCoordinate = route.endCoordinate {
                var endMarker = PointAnnotation(coordinate: endCoordinate)
                endMarker.image = .init(image: markerImage(fill: UIColor.black.withAlphaComponent(0.72), size: 14, stroke: UIColor.white), name: "route-tracking-end")
                pointAnnotations.append(endMarker)
            }

            if let currentCoordinate = currentLocation?.coordinate {
                var currentMarker = PointAnnotation(coordinate: currentCoordinate)
                currentMarker.image = .init(image: markerImage(fill: UIColor(red: 0.29, green: 0.60, blue: 0.99, alpha: 1), size: 22, stroke: UIColor.white), name: "route-tracking-current")
                pointAnnotations.append(currentMarker)
            }

            if let progress {
                let snappedFill = progress.isOffRoute
                    ? UIColor(red: 1.0, green: 0.76, blue: 0.24, alpha: 1)
                    : UIColor(red: 0.16, green: 0.82, blue: 0.68, alpha: 1)
                var snappedMarker = PointAnnotation(coordinate: progress.snappedCoordinate)
                snappedMarker.image = .init(image: markerImage(fill: snappedFill, size: 16, stroke: UIColor.black.withAlphaComponent(0.7)), name: "route-tracking-snapped")
                pointAnnotations.append(snappedMarker)
            }

            markerManager?.annotations = pointAnnotations
        }

        private func fitCamera(to coordinates: [CLLocationCoordinate2D], on mapView: MapView, perspective: AppRouteMapPerspective) {
            guard coordinates.count > 1 else {
                return
            }
            ignoreManualCameraChangesUntil = CFAbsoluteTimeGetCurrent() + 1.2

            do {
                let cameraOptions = try mapView.mapboxMap.camera(
                    for: coordinates,
                    camera: CameraOptions(
                        bearing: 0,
                        pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                    ),
                    coordinatesPadding: cameraPadding(),
                    maxZoom: 15.5,
                    offset: nil
                )
                mapView.camera.ease(to: cameraOptions, duration: 0)
            } catch {
                if let bounds = RouteMapboxGeometry.coordinateBounds(for: coordinates, minimumMeters: 1_200, paddingFactor: 0.26) {
                    do {
                        let fallbackCamera = try mapView.mapboxMap.camera(
                            for: [bounds.southwest, bounds.southeast, bounds.northeast, bounds.northwest],
                            camera: CameraOptions(
                                bearing: 0,
                                pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                            ),
                            coordinatesPadding: cameraPadding(),
                            maxZoom: 15.5,
                            offset: nil
                        )
                        mapView.camera.ease(to: fallbackCamera, duration: 0)
                    } catch {
                        mapView.camera.ease(
                            to: CameraOptions(
                                center: coordinates.first,
                                zoom: 11,
                                pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                            ),
                            duration: 0
                        )
                    }
                }
            }
        }

        private func center(
            on coordinate: CLLocationCoordinate2D,
            course: CLLocationDirection?,
            in mapView: MapView,
            followMode: RouteTrackingCameraFollowMode,
            perspective: AppRouteMapPerspective,
            forced: Bool
        ) {
            if !forced,
               let lastFollowCoordinate,
               lastFollowCoordinate.trackingDistance(to: coordinate) < 8 {
                return
            }

            let currentZoom = mapView.mapboxMap.cameraState.zoom
            let targetZoom = currentZoom.isFinite && currentZoom > 0 ? currentZoom : 15.4

            let bearing: CLLocationDirection?
            let targetPitch: CGFloat
            switch followMode {
            case .centered:
                bearing = nil
                targetPitch = perspective.isThreeDimensional ? perspective.pitch : 0
            case .courseFollowing:
                if let course, course >= 0, course.isFinite {
                    bearing = course
                } else {
                    bearing = nil
                }
                targetPitch = max(perspective.isThreeDimensional ? perspective.pitch : 0, 52)
            }

            ignoreManualCameraChangesUntil = CFAbsoluteTimeGetCurrent() + (forced ? 1.1 : 1.4)
            mapView.camera.ease(
                to: CameraOptions(
                    center: coordinate,
                    padding: cameraPadding(),
                    zoom: targetZoom,
                    bearing: bearing,
                    pitch: targetPitch
                ),
                duration: forced ? 0.45 : 0.8
            )
            lastFollowCoordinate = coordinate
        }

        private func cameraPadding() -> UIEdgeInsets {
            UIEdgeInsets(
                top: 112,
                left: 20,
                bottom: max(32, latestBottomOverlayHeight + 20),
                right: 20
            )
        }

        private func recreateManagers(on mapView: MapView) {
            let ids = [
                "route-tracking-outline",
                "route-tracking-base",
                "route-tracking-completed",
                "route-tracking-breadcrumb",
                "route-tracking-direction-arrows",
                "route-tracking-markers"
            ]

            for id in ids {
                mapView.annotations.removeAnnotationManager(withId: id)
            }

            routeOutlineManager = mapView.annotations.makePolylineAnnotationManager(id: "route-tracking-outline")
            routeBaseLineManager = mapView.annotations.makePolylineAnnotationManager(id: "route-tracking-base")
            routeCompletedManager = mapView.annotations.makePolylineAnnotationManager(id: "route-tracking-completed")
            breadcrumbManager = mapView.annotations.makePolylineAnnotationManager(id: "route-tracking-breadcrumb")
            directionArrowManager = mapView.annotations.makePointAnnotationManager(id: "route-tracking-direction-arrows")
            markerManager = mapView.annotations.makePointAnnotationManager(id: "route-tracking-markers")
        }

        private func ensureManagers(on mapView: MapView) {
            if routeOutlineManager == nil ||
                routeBaseLineManager == nil ||
                routeCompletedManager == nil ||
                breadcrumbManager == nil ||
                directionArrowManager == nil ||
                markerManager == nil {
                recreateManagers(on: mapView)
            }
        }

        private func markerImage(fill: UIColor, size: CGFloat, stroke: UIColor) -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size)).insetBy(dx: 2, dy: 2)
                context.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 2),
                    blur: 6,
                    color: UIColor.black.withAlphaComponent(0.24).cgColor
                )
                context.cgContext.setFillColor(fill.cgColor)
                context.cgContext.fillEllipse(in: rect)
                context.cgContext.setStrokeColor(stroke.cgColor)
                context.cgContext.setLineWidth(3)
                context.cgContext.strokeEllipse(in: rect)
            }
        }
    }
}

private extension CLLocationCoordinate2D {
    func trackingDistance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
}

private struct RouteTrackingIdleTimerModifier: ViewModifier {
    let isDisabled: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = isDisabled
            }
            .onChange(of: isDisabled) { _, newValue in
                UIApplication.shared.isIdleTimerDisabled = newValue
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
    }
}

private extension View {
    func routeTrackingIdleTimerDisabled(_ isDisabled: Bool) -> some View {
        modifier(RouteTrackingIdleTimerModifier(isDisabled: isDisabled))
    }
}
