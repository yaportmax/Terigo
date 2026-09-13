import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SortPriorityPanel: View {
    @Bindable var model: RouteLibraryModel
    let hasSelectedStartLocation: Bool

    private var isAppStorePreview: Bool {
        AppStoreScreenshotSupport.requestedShot == .sortOrder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isAppStorePreview ? 6 : 10) {
            VStack(alignment: .leading, spacing: isAppStorePreview ? 6 : 8) {
                ForEach(Array(model.sortCriteria.enumerated()), id: \.element.id) { index, criterion in
                    SortCriterionRow(
                        index: index,
                        criterion: criterion,
                        availableOptions: availableSortOptions(for: criterion),
                        canMoveUp: index > 0,
                        canMoveDown: index < model.sortCriteria.count - 1,
                        canRemove: model.sortCriteria.count > 1,
                        hasSelectedStartLocation: hasSelectedStartLocation,
                        isCondensed: isAppStorePreview,
                        onSelectOption: { model.updateSortCriterion(criterion.id, option: $0) },
                        onToggleDirection: {
                            let nextDirection: RouteSortDirection = criterion.direction == .descending ? .ascending : .descending
                            model.updateSortCriterion(criterion.id, direction: nextDirection)
                        },
                        onMoveUp: { model.moveSortCriterion(criterion.id, by: -1) },
                        onMoveDown: { model.moveSortCriterion(criterion.id, by: 1) },
                        onRemove: { model.removeSortCriterion(criterion.id) }
                    )
                }
            }

            if !availableAdditionalSorts.isEmpty {
                Menu {
                    ForEach(availableAdditionalSorts) { option in
                        Button {
                            model.addSortCriterion(option)
                        } label: {
                            Label(option.title, systemImage: option.symbolName)
                        }
                    }
                } label: {
                    Label("Add Sort Criterion", systemImage: "plus")
                        .font(isAppStorePreview ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, isAppStorePreview ? 10 : 12)
                        .padding(.vertical, isAppStorePreview ? 8 : 10)
                        .routeControlSurface(isActive: false, cornerRadius: isAppStorePreview ? 18 : 20)
                }
            }

            if model.usesStartProximitySort && !hasSelectedStartLocation {
                Text("Pick a start reference to make Closest Start meaningful.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func availableSortOptions(for criterion: RouteSortCriterion) -> [RouteSortOption] {
        RouteSortOption.allCases.filter { option in
            option == criterion.option || !model.sortCriteria.contains(where: { $0.option == option })
        }
    }

    private var availableAdditionalSorts: [RouteSortOption] {
        RouteSortOption.allCases.filter { option in
            !model.sortCriteria.contains(where: { $0.option == option })
        }
    }
}

private struct SortCriterionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let index: Int
    let criterion: RouteSortCriterion
    let availableOptions: [RouteSortOption]
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canRemove: Bool
    let hasSelectedStartLocation: Bool
    let isCondensed: Bool
    let onSelectOption: (RouteSortOption) -> Void
    let onToggleDirection: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isCondensed ? 4 : 6) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: isCondensed ? 6 : 8))
            layout {
                Text("#\(index + 1)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                Menu {
                    ForEach(availableOptions) { option in
                        Button {
                            onSelectOption(option)
                        } label: {
                            Label(option.title, systemImage: option.symbolName)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: criterion.option.symbolName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(criterion.option.title)
                            .font(isCondensed ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, isCondensed ? 10 : 12)
                    .padding(.vertical, isCondensed ? 8 : 10)
                    .routeControlSurface(isActive: false, cornerRadius: 18)
                }
                .buttonStyle(.plain)

                Button(action: onToggleDirection) {
                    HStack(spacing: 6) {
                        Image(systemName: criterion.direction.symbolName)
                            .font(.caption.weight(.bold))
                        Text(criterion.option.directionTitle(for: criterion.direction))
                            .font(isCondensed ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    }
                    .padding(.horizontal, isCondensed ? 8 : 10)
                    .padding(.vertical, isCondensed ? 8 : 10)
                    .routeControlSurface(isActive: false, cornerRadius: 18)
                }
                .buttonStyle(.plain)
            }

            if canMoveUp || canMoveDown || canRemove || criterion.option == .startProximity {
                HStack(spacing: isCondensed ? 8 : 10) {
                    Spacer(minLength: 32)

                    SortRowAccessoryButton(
                        symbolName: "arrow.up",
                        isEnabled: canMoveUp,
                        action: onMoveUp,
                        isCondensed: isCondensed
                    )

                    SortRowAccessoryButton(
                        symbolName: "arrow.down",
                        isEnabled: canMoveDown,
                        action: onMoveDown,
                        isCondensed: isCondensed
                    )

                    if canRemove {
                        SortRowAccessoryButton(
                            symbolName: "minus.circle",
                            isEnabled: true,
                            action: onRemove,
                            isCondensed: isCondensed
                        )
                    }

                    if criterion.option == .startProximity {
                        Text(hasSelectedStartLocation ? "Using start reference" : "Needs start reference")
                            .font(isCondensed ? .caption2 : .caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct SortRowAccessoryButton: View {
    let symbolName: String
    let isEnabled: Bool
    let action: () -> Void
    let isCondensed: Bool

    var body: some View {
        Button(action: action) {
            AppIconGlyph(name: symbolName, size: isCondensed ? 10 : 12, weight: .bold)
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .frame(width: 44, height: 44)
                .routeControlSurface(isActive: false, cornerRadius: isCondensed ? 12 : 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbolName == "arrow.up" ? "Move earlier" : (symbolName == "arrow.down" ? "Move later" : "Remove sort criterion"))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

struct FilterNavigationRow<Destination: View>: View {
    let title: String
    let summary: String
    let symbolName: String
    let isActive: Bool
    @ViewBuilder let destination: () -> Destination

    private var usesActivityGlyph: Bool {
        symbolName.hasPrefix("activity-")
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                AppIconGlyph(name: symbolName, size: 16, weight: .semibold)
                    .foregroundStyle(isActive ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
                    .frame(width: usesActivityGlyph ? 26 : 18, height: 26, alignment: .center)
                    .offset(y: usesActivityGlyph ? 2 : 0)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .routeControlSurface(isActive: isActive, cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }
}


struct FilterToggleRow: View {
    let title: String
    let summary: String
    let symbolName: String
    @Binding var isOn: Bool

    private var usesActivityGlyph: Bool {
        symbolName.hasPrefix("activity-")
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                AppIconGlyph(name: symbolName, size: 16, weight: .semibold)
                    .foregroundStyle(isOn ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
                    .frame(width: usesActivityGlyph ? 26 : 18, height: 26, alignment: .center)
                    .offset(y: usesActivityGlyph ? 2 : 0)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isOn ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .routeControlSurface(isActive: isOn, cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }
}

struct FilterOptionSelectionScreen<Option: Identifiable & Hashable>: View {
    let title: String
    let descriptionText: String
    let options: [Option]
    let isSelected: (Option) -> Bool
    let action: (Option) -> Void
    let titleForOption: (Option) -> String
    let symbolNameForOption: (Option) -> String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !descriptionText.isEmpty {
                    Text(descriptionText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(options) { option in
                        FilterSelectionRow(
                            title: titleForOption(option),
                            symbolName: symbolNameForOption(option),
                            isSelected: isSelected(option)
                        ) {
                            action(option)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}


struct StartLocationSearchResult: Identifiable, Hashable {
    let selectionValue: String
    let subtitle: String?

    var id: String { selectionValue.routeLocationToken }

    init?(_ item: MKMapItem) {
        let primaryLine = StartLocationSearchResult.primaryLine(for: item)
        guard let selectionValue = primaryLine.nilIfEmpty else {
            return nil
        }

        self.selectionValue = selectionValue
        subtitle = StartLocationSearchResult.subtitle(for: item, excluding: selectionValue)
    }

    private static func primaryLine(for item: MKMapItem) -> String {
        let placemark = item.placemark

        return item.name?.trimmed.nilIfEmpty ??
            placemark.locality?.trimmed.nilIfEmpty ??
            placemark.subAdministrativeArea?.trimmed.nilIfEmpty ??
            placemark.administrativeArea?.trimmed.nilIfEmpty ??
            placemark.country?.trimmed.nilIfEmpty ??
            placemark.title?.trimmed.nilIfEmpty ??
            ""
    }

    private static func subtitle(for item: MKMapItem, excluding primaryLine: String) -> String? {
        let placemark = item.placemark
        let parts = [
            placemark.locality?.trimmed.nilIfEmpty,
            placemark.subAdministrativeArea?.trimmed.nilIfEmpty,
            placemark.administrativeArea?.trimmed.nilIfEmpty,
            placemark.country?.trimmed.nilIfEmpty
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty && $0.routeLocationToken != primaryLine.routeLocationToken }

        guard !parts.isEmpty else {
            return nil
        }

        var seen = Set<String>()
        let deduplicated = parts.filter { value in
            seen.insert(value.routeLocationToken).inserted
        }

        return deduplicated.joined(separator: ", ").nilIfEmpty
    }
}

struct StartLocationFilterBox: View {
    let selectedValues: [String]
    let activeRadiusSummary: String?
    let activeRadiusReferenceName: String?
    @Binding var draft: String
    let searchResults: [StartLocationSearchResult]
    let isSearching: Bool
    let onSelectSearchResult: (StartLocationSearchResult) -> Void
    let onRemoveValue: (String) -> Void
    let onChooseOnMap: () -> Void
    let onClearRadius: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "map")
                    .foregroundStyle(.secondary)

                TextField(textFieldPlaceholder, text: $draft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                } else if !draft.trimmed.isEmpty {
                    Button {
                        draft = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            if !searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select a Location")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(searchResults) { result in
                            Button {
                                onSelectSearchResult(result)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "mappin.and.ellipse")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color(red: 0.79, green: 0.32, blue: 0.15))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.selectionValue)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)

                                        if let subtitle = result.subtitle {
                                            Text(subtitle)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }

                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if draft.trimmed.count >= 2, !isSearching {
                Text("No matching places found. Try a broader location name.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !selectedValues.isEmpty || activeRadiusSummary != nil {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(selectedValues, id: \.self) { value in
                        StartLocationValueChip(value: value) {
                            onRemoveValue(value)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if let activeRadiusSummary {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Map Radius")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            Text(radiusSummaryText(activeRadiusSummary))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        Button("Clear", action: onClearRadius)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(red: 0.79, green: 0.32, blue: 0.15))
                            .buttonStyle(.plain)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                Button(action: onChooseOnMap) {
                    HStack(spacing: 10) {
                        Image(systemName: "map")
                            .font(.system(size: 15, weight: .semibold))
                        Text(activeRadiusSummary == nil ? "Choose on Map" : "Adjust on Map")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .routeControlSurface(isActive: activeRadiusSummary != nil, cornerRadius: 20)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var textFieldPlaceholder: String {
        "Search San Francisco, Marin, Yosemite, ..."
    }

    private func radiusSummaryText(_ summary: String) -> String {
        if let activeRadiusReferenceName = activeRadiusReferenceName?.trimmed.nilIfEmpty {
            return "\(summary) from \(activeRadiusReferenceName)"
        }

        return summary
    }
}

private struct StartLocationValueChip: View {
    let value: String
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.79, green: 0.32, blue: 0.15))

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .routeControlSurface(isActive: true, cornerRadius: 18)
    }
}

struct InlineListFilterBox: View {
    let lists: [RouteList]
    let selectedTags: Set<String>
    let onToggle: (String) -> Void

    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 10)]

    private var listNames: [String] {
        lists.map(\.name)
    }

    private var filteredListNames: [String] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return listNames
        }

        return listNames.filter { $0.localizedCaseInsensitiveContains(normalizedQuery) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if listNames.isEmpty {
                ContentUnavailableView(
                    "No Lists Yet",
                    systemImage: "list.bullet",
                    description: Text("Create lists from Manage Lists or route details, then filter them here.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                SearchField(text: $query, placeholder: "Search lists")

                if filteredListNames.isEmpty {
                    ContentUnavailableView(
                        "No Matching Lists",
                        systemImage: "list.bullet",
                        description: Text("Try a different list search.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(filteredListNames, id: \.self) { listName in
                            ListFilterChip(
                                listName: listName,
                                isSelected: selectedTags.contains(listName)
                            ) {
                                onToggle(listName)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ListFilterChip: View {
    let listName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)

                Text(listName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .routeControlSurface(isActive: isSelected, cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }
}

private struct FilterSelectionRow: View {
    let title: String
    let symbolName: String
    let isSelected: Bool
    let action: () -> Void

    private var usesActivityGlyph: Bool {
        symbolName.hasPrefix("activity-")
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                AppIconGlyph(name: symbolName, size: 16, weight: .semibold)
                    .foregroundStyle(isSelected ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
                    .frame(width: usesActivityGlyph ? 26 : 18, height: 26, alignment: .center)
                    .offset(y: usesActivityGlyph ? 1 : 0)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .routeControlSurface(isActive: isSelected, cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }
}


struct ActionControlChip: View {
    let title: String
    let value: String
    let symbolName: String
    let isActive: Bool
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AppIconGlyph(name: symbolName, size: 14, weight: .semibold)
                    .foregroundStyle(isActive ? Color(red: 0.79, green: 0.32, blue: 0.15) : Color.secondary)
                    .frame(width: 18, height: 18)

                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if !value.isEmpty {
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .routeControlSurface(isActive: isActive, cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }
}


struct AppliedFilterToken: Identifiable {
    let id: String
    let title: String
    let value: String
    let symbolName: String
    let clear: () -> Void
}

