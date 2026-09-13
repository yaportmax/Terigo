import CoreLocation
import SwiftUI
import UIKit

struct RouteCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppMeasurementSystem.storageKey) private var appMeasurementSystemRawValue = AppMeasurementSystem.defaultValue.rawValue
    let route: RouteRecord
    let density: AppRouteListDensity
    let onSelect: () -> Void

    init(
        route: RouteRecord,
        density: AppRouteListDensity = .compact,
        onSelect: @escaping () -> Void
    ) {
        self.route = route
        self.density = density
        self.onSelect = onSelect
    }

    var body: some View {
        Button(action: onSelect) {
            routeCardBody
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("route-row-\(route.stravaRouteID)")
    }

    @ViewBuilder
    private var routeCardBody: some View {
        switch density {
        case .compact:
            CompactRouteListRow(route: route)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        case .medium:
            MediumRouteCardContent(route: route)
                .padding(density.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
                .overlay(cardOutline)
                .contentShape(RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous))
        case .expanded:
            ExpandedRouteCardContent(route: route)
                .padding(density.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
                .overlay(cardOutline)
                .contentShape(RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous))
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(TerigoTheme.surface)
    }

    private var cardOutline: some View {
        RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
            .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
    }
}

private struct CompactRouteListRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let route: RouteRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(route.name)
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                CompactInlineMetric(iconName: route.sportSymbolName, text: RouteDisplayFormatter.distance(route.distanceMeters))
                CompactInlineMetric(iconName: "mountain.2.fill", text: RouteDisplayFormatter.climb(route.elevationGainMeters))
                CompactInlineMetric(iconName: "clock.fill", text: RouteDisplayFormatter.duration(route.estimatedMovingTime))
            }
            .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 10) {
                Text(compactMetaLine)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    if route.hasOfflineAssets {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(red: 0.93, green: 0.45, blue: 0.20))
                    }

                    Text(createdDateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 2)
        }
    }

    private var compactMetaLine: String {
        var components = [route.sportDisplayName, route.isPrivate ? "Private" : "Public"]

        if let surface = route.surfaceDisplayName {
            components.append(surface)
        }

        if route.hasLists, let firstList = route.listNames.first {
            let listSummary = route.listNames.count > 1 ? "\(firstList) +\(route.listNames.count - 1)" : firstList
            components.append(listSummary)
        }

        return components.joined(separator: " • ")
    }

    private var createdDateLabel: String {
        "Created \(RouteDisplayFormatter.calendarDate(route.createdAt ?? route.primaryTimestamp))"
    }
}

private struct MediumRouteCardContent: View {
    let route: RouteRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                RouteTraceThumbnail(coordinates: route.routeCoordinates)
                    .frame(width: 64, height: 70)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(route.sportDisplayName.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(1)
                        .foregroundStyle(TerigoTheme.accent)
                    Text(route.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if !route.displayLocation.isEmpty {
                        Text(route.displayLocation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            RouteMetricRow(route: route, size: .regular)
            HStack(spacing: 8) {
                if route.hasOfflineAssets {
                    Label("Offline", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(TerigoTheme.accent)
                }
                if route.isPrivate {
                    Image(systemName: "lock.fill")
                        .accessibilityLabel("Private route")
                }
                if let surface = route.surfaceDisplayName { Text(surface) }
                Spacer(minLength: 0)
                if let list = route.listNames.first {
                    Label(list, systemImage: "square.stack")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !route.notes.isEmpty {
                Text(route.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// A local route outline makes each card recognizable without tile requests.
struct RouteTraceThumbnail: View {
    let coordinates: [CLLocationCoordinate2D]

    var body: some View {
        GeometryReader { geometry in
            let points = projectedPoints(in: geometry.size)
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(TerigoTheme.accent.opacity(0.08))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    path.addLines(points)
                }
                .stroke(TerigoTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                if let first = points.first {
                    Circle().fill(TerigoTheme.accent).frame(width: 7, height: 7).position(first)
                } else {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .foregroundStyle(TerigoTheme.accent)
                }
            }
        }
    }

    private func projectedPoints(in size: CGSize) -> [CGPoint] {
        let valid = coordinates.filter(CLLocationCoordinate2DIsValid)
        guard let origin = valid.first else { return [] }
        let scale = max(cos(origin.latitude * .pi / 180), 0.01)
        // Unwrap around the start so routes crossing the date line stay compact.
        let points = valid.map { coordinate in
            let longitude = (coordinate.longitude - origin.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
            return CGPoint(x: longitude * scale, y: -coordinate.latitude)
        }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let factor = min((size.width - 20) / max(maxX - minX, 0.00001), (size.height - 20) / max(maxY - minY, 0.00001))
        return points.map {
            CGPoint(x: ($0.x - (minX + maxX) / 2) * factor + size.width / 2,
                    y: ($0.y - (minY + maxY) / 2) * factor + size.height / 2)
        }
    }
}

private struct ExpandedRouteCardContent: View {
    let route: RouteRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RouteMapHeroPreview(route: route)
                .frame(maxWidth: .infinity)
                .frame(height: 214)

            VStack(alignment: .leading, spacing: 12) {
                RouteTitleBlock(route: route, titleFont: .system(.title3, design: .rounded, weight: .semibold))

                RouteMetricRow(route: route, size: .regular)

                RouteBadgeRow(route: route, size: .regular)
            }

            if route.hasLists {
                RouteTagCapsules(tags: route.listNames, size: .regular, allowsHorizontalScroll: true)
            }

            if !route.notes.isEmpty {
                Text(route.notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            RouteFooterLine(route: route)
        }
    }
}

private struct RouteTitleBlock: View {
    let route: RouteRecord
    let titleFont: Font

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(route.name)
                    .font(titleFont)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                if !route.displayLocation.isEmpty {
                    Label(route.displayLocation, systemImage: "location")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct RouteMetricRow: View {
    let route: RouteRecord
    let size: RouteCardElementSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: size.rowSpacing) {
                metricViews
            }

            VStack(alignment: .leading, spacing: size.rowSpacing) {
                HStack(spacing: size.rowSpacing) {
                    MetricPill(iconName: route.sportSymbolName, text: RouteDisplayFormatter.distance(route.distanceMeters), size: size)
                    MetricPill(iconName: "mountain.2.fill", text: RouteDisplayFormatter.climb(route.elevationGainMeters), size: size)
                }

                MetricPill(iconName: "clock.fill", text: RouteDisplayFormatter.duration(route.estimatedMovingTime), size: size)
            }
        }
    }

    @ViewBuilder
    private var metricViews: some View {
        MetricPill(iconName: route.sportSymbolName, text: RouteDisplayFormatter.distance(route.distanceMeters), size: size)
        MetricPill(iconName: "mountain.2.fill", text: RouteDisplayFormatter.climb(route.elevationGainMeters), size: size)
        MetricPill(iconName: "clock.fill", text: RouteDisplayFormatter.duration(route.estimatedMovingTime), size: size)
    }
}

private struct RouteBadgeRow: View {
    let route: RouteRecord
    let size: RouteCardElementSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: size.rowSpacing) {
                badgeViews
            }

            VStack(alignment: .leading, spacing: size.rowSpacing) {
                HStack(spacing: size.rowSpacing) {
                    CapsuleLabel(text: route.sportDisplayName, tone: .accent, size: size)
                    CapsuleLabel(text: route.isPrivate ? "Private" : "Public", tone: .neutral, size: size)
                }

                if let surface = route.surfaceDisplayName {
                    CapsuleLabel(text: surface, tone: .neutral, size: size)
                }
            }
        }
    }

    @ViewBuilder
    private var badgeViews: some View {
        CapsuleLabel(text: route.sportDisplayName, tone: .accent, size: size)
        CapsuleLabel(text: route.isPrivate ? "Private" : "Public", tone: .neutral, size: size)
        if let surface = route.surfaceDisplayName {
            CapsuleLabel(text: surface, tone: .neutral, size: size)
        }
    }
}

private struct RouteFooterLine: View {
    let route: RouteRecord

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                if route.hasOfflineAssets {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(red: 0.93, green: 0.45, blue: 0.20))
                }

                Text(createdDateLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var createdDateLabel: String {
        "Created \(RouteDisplayFormatter.calendarDate(route.createdAt ?? route.primaryTimestamp))"
    }
}

private struct RouteMapHeroPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let route: RouteRecord

    var body: some View {
        ZStack {
            RouteMapPreview(
                route: route,
                displayMode: .cardPreview,
                routeFitInsets: .expandedPreview,
                userInterfaceStyle: colorScheme == .dark ? .dark : .light
            )
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack {
                HStack {
                    if route.hasOfflineAssets {
                        Label("Saved", systemImage: "arrow.down.circle.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color(red: 0.93, green: 0.45, blue: 0.20))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 1)
        }
    }
}

private enum RouteCardElementSize {
    case compact
    case regular

    var rowSpacing: CGFloat {
        switch self {
        case .compact:
            return 6
        case .regular:
            return 8
        }
    }

    var metricFont: Font {
        switch self {
        case .compact:
            return .system(.caption, design: .rounded, weight: .semibold)
        case .regular:
            return .footnote.weight(.semibold)
        }
    }

    var metricHorizontalPadding: CGFloat {
        switch self {
        case .compact:
            return 10
        case .regular:
            return 12
        }
    }

    var metricVerticalPadding: CGFloat {
        switch self {
        case .compact:
            return 6
        case .regular:
            return 8
        }
    }

    var metricIconSize: CGFloat {
        switch self {
        case .compact:
            return 12
        case .regular:
            return 14
        }
    }

    var badgeFont: Font {
        switch self {
        case .compact:
            return .system(.caption2, design: .rounded, weight: .bold)
        case .regular:
            return .caption.weight(.bold)
        }
    }

    var badgeHorizontalPadding: CGFloat {
        switch self {
        case .compact:
            return 8
        case .regular:
            return 10
        }
    }

    var badgeVerticalPadding: CGFloat {
        switch self {
        case .compact:
            return 4
        case .regular:
            return 6
        }
    }
}

private struct MetricPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let iconName: String
    let text: String
    let size: RouteCardElementSize

    var body: some View {
        HStack(spacing: 6) {
            AppIconGlyph(name: iconName, size: size.metricIconSize, weight: .semibold)
            Text(text)
                .lineLimit(1)
        }
        .font(size.metricFont)
        .foregroundStyle(.primary)
        .padding(.horizontal, size.metricHorizontalPadding)
        .padding(.vertical, size.metricVerticalPadding)
        .background(
            Capsule(style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06))
        )
    }
}

private struct CompactInlineMetric: View {
    let iconName: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            AppIconGlyph(name: iconName, size: 12, weight: .semibold)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
    }
}

private struct CapsuleLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    enum Tone {
        case accent
        case neutral
    }

    let text: String
    let tone: Tone
    let size: RouteCardElementSize

    var body: some View {
        Text(text)
            .font(size.badgeFont)
            .lineLimit(1)
            .padding(.horizontal, size.badgeHorizontalPadding)
            .padding(.vertical, size.badgeVerticalPadding)
            .background(background)
            .foregroundStyle(foreground)
    }

    private var background: some ShapeStyle {
        switch tone {
        case .accent:
            return Color(red: 0.96, green: 0.44, blue: 0.25).opacity(0.15)
        case .neutral:
            return colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
        }
    }

    private var foreground: Color {
        switch tone {
        case .accent:
            return TerigoTheme.accent
        case .neutral:
            return colorScheme == .dark ? Color.white.opacity(0.72) : .secondary
        }
    }
}

private struct RouteTagCapsules: View {
    @Environment(\.colorScheme) private var colorScheme
    let tags: [String]
    let size: RouteCardElementSize
    let allowsHorizontalScroll: Bool

    var body: some View {
        if allowsHorizontalScroll {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: size.rowSpacing) {
                    tagViews
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: size.rowSpacing) {
                        tagViews
                    }
                }
            }
        } else {
            HStack(spacing: size.rowSpacing) {
                tagViews
            }
        }
    }

    @ViewBuilder
    private var tagViews: some View {
        ForEach(tags, id: \.self) { tag in
            Text(tag)
                .font(size.badgeFont)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.78) : Color(red: 0.43, green: 0.42, blue: 0.39))
                .lineLimit(1)
                .padding(.horizontal, size.badgeHorizontalPadding)
                .padding(.vertical, size.badgeVerticalPadding)
                .background(
                    Capsule(style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color(red: 0.92, green: 0.90, blue: 0.86))
                )
        }
    }
}
