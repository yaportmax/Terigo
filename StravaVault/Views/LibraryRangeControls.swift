import SwiftUI

/// Both filters use the same native controls and keep storage values in legacy units.
struct RouteRangePanel: View {
    enum Kind { case distance, climb }
    @Bindable var model: RouteLibraryModel
    let kind: Kind
    let sliderBounds: ClosedRange<Double>
    let filteredBounds: ClosedRange<Double>?
    @State private var minimumDraft = ""
    @State private var maximumDraft = ""
    @State private var inputError: String?
    @FocusState private var focusedEndpoint: Endpoint?
    private enum Endpoint: Hashable { case minimum, maximum }

    private var title: String { kind == .distance ? "Distance" : "Elevation gain" }
    private var unit: String {
        kind == .distance ? RouteDisplayFormatter.measurementSystem.distanceUnitLabel
            : RouteDisplayFormatter.measurementSystem.climbUnitLabel
    }
    private var minimum: Double? {
        kind == .distance ? model.selectedDistanceMinimumMiles : model.selectedClimbMinimumFeet
    }
    private var maximum: Double? {
        kind == .distance ? model.selectedDistanceMaximumMiles : model.selectedClimbMaximumFeet
    }
    private var bounds: ClosedRange<Double> { display(sliderBounds.lowerBound)...display(sliderBounds.upperBound) }
    private var lowerValue: Double { min(max(display(minimum ?? sliderBounds.lowerBound), bounds.lowerBound), upperValue) }
    private var upperValue: Double { max(min(display(maximum ?? sliderBounds.upperBound), bounds.upperBound), bounds.lowerBound) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if minimum != nil || maximum != nil || hasLegacyFilter {
                    Button("Reset") {
                        focusedEndpoint = nil
                        set(nil, for: .minimum)
                        set(nil, for: .maximum)
                        updateDrafts()
                    }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
                }
            }
            HStack(spacing: 12) {
                endpointField(.minimum, title: "Minimum", text: $minimumDraft)
                endpointField(.maximum, title: "Maximum", text: $maximumDraft)
            }
            Slider(value: sliderBinding(.minimum), in: bounds,
                   step: kind == .distance ? RouteDisplayFormatter.distanceSliderStep : RouteDisplayFormatter.climbSliderStep) {
                Text("Minimum \(title.lowercased())")
            }
            .accessibilityValue("\(lowerValue.formatted()) \(unit)")
            .disabled(filteredBounds == nil)
            Slider(value: sliderBinding(.maximum), in: bounds,
                   step: kind == .distance ? RouteDisplayFormatter.distanceSliderStep : RouteDisplayFormatter.climbSliderStep) {
                Text("Maximum \(title.lowercased())")
            }
            .accessibilityValue("\(upperValue.formatted()) \(unit)")
            .disabled(filteredBounds == nil)
            if let inputError {
                Text(inputError).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear(perform: updateDrafts)
        .onChange(of: focusedEndpoint) { oldValue, _ in
            if let oldValue { commit(oldValue) }
        }
        .onDisappear {
            if let focusedEndpoint { commit(focusedEndpoint) }
        }
        .toolbar {
            if focusedEndpoint != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Clear") {
                        if let endpoint = focusedEndpoint {
                            set(nil, for: endpoint)
                            updateDrafts()
                        }
                    }
                    Spacer()
                    Button("Done") { focusedEndpoint = nil }
                }
            }
        }
    }

    private func endpointField(_ endpoint: Endpoint, title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Any", text: text)
                    .keyboardType(.decimalPad)
                    .focused($focusedEndpoint, equals: endpoint)
                    .accessibilityLabel("\(self.title) \(title.lowercased())")
                Text(unit).foregroundStyle(.secondary)
            }
            .font(.subheadline.monospacedDigit())
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var hasLegacyFilter: Bool {
        kind == .distance ? model.selectedDistance != .all : model.selectedClimb != .all
    }
    private func display(_ value: Double) -> Double {
        kind == .distance ? RouteDisplayFormatter.distanceDisplayValue(forMiles: value)
            : RouteDisplayFormatter.climbDisplayValue(forFeet: value)
    }
    private func stored(_ value: Double) -> Double {
        kind == .distance ? RouteDisplayFormatter.miles(fromDistanceDisplayValue: value)
            : RouteDisplayFormatter.feet(fromClimbDisplayValue: value)
    }
    private func set(_ value: Double?, for endpoint: Endpoint) {
        if kind == .distance {
            model.selectedDistance = .all
            if endpoint == .minimum { model.selectedDistanceMinimumMiles = value }
            else { model.selectedDistanceMaximumMiles = value }
        } else {
            model.selectedClimb = .all
            if endpoint == .minimum { model.selectedClimbMinimumFeet = value }
            else { model.selectedClimbMaximumFeet = value }
        }
        inputError = nil
    }
    private func sliderBinding(_ endpoint: Endpoint) -> Binding<Double> {
        Binding(get: { endpoint == .minimum ? lowerValue : upperValue }, set: { value in
            let limited = endpoint == .minimum ? min(value, upperValue) : max(value, lowerValue)
            let isUnbounded = endpoint == .minimum ? limited <= bounds.lowerBound : limited >= bounds.upperBound
            set(isUnbounded ? nil : stored(limited), for: endpoint)
            updateDrafts()
        })
    }
    private func updateDrafts() {
        minimumDraft = minimum.map { display($0).formatted(.number.precision(.fractionLength(0...2))) } ?? ""
        maximumDraft = maximum.map { display($0).formatted(.number.precision(.fractionLength(0...2))) } ?? ""
    }
    private func commit(_ endpoint: Endpoint) {
        let draft = (endpoint == .minimum ? minimumDraft : maximumDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty { set(nil, for: endpoint); return }
        guard let value = RouteDisplayFormatter.parseNumericInput(draft), value.isFinite, value >= 0 else {
            inputError = "Enter a positive number or leave the field empty."
            return
        }
        let valueInStorageUnits = stored(value)
        if endpoint == .minimum, let maximum, valueInStorageUnits > maximum {
            inputError = "Minimum must be less than maximum."
        } else if endpoint == .maximum, let minimum, valueInStorageUnits < minimum {
            inputError = "Maximum must be greater than minimum."
        } else {
            set(valueInStorageUnits, for: endpoint)
        }
    }
}
