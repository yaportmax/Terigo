import CoreLocation
import Foundation

enum RouteDisplayFormatter {
    private static let milesToKilometers = 1.60934
    private static let feetToMeters = 0.3048

    private static let wholeNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .autoupdatingCurrent
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    private static let compactNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .autoupdatingCurrent
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    private static let decimalInputFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .autoupdatingCurrent
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    private static let relativeDateFormatter = RelativeDateTimeFormatter()

    private static let absoluteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let calendarDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let weatherNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .autoupdatingCurrent
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    static var measurementSystem: AppMeasurementSystem {
        let rawValue = UserDefaults.standard.string(forKey: AppMeasurementSystem.storageKey)
            ?? AppMeasurementSystem.defaultValue.rawValue
        return AppMeasurementSystem(rawValue: rawValue) ?? AppMeasurementSystem.defaultValue
    }

    static var distanceSliderStep: Double {
        1
    }

    static var climbSliderStep: Double {
        measurementSystem == .metric ? 25 : 50
    }

    static func distance(_ meters: Double) -> String {
        distanceLabel(distanceDisplayValue(forMeters: meters))
    }

    static func distanceMiles(_ miles: Double) -> String {
        distanceLabel(distanceDisplayValue(forMiles: miles))
    }

    static func climb(_ meters: Double) -> String {
        climbLabel(climbDisplayValue(forMeters: meters))
    }

    static func altitude(_ meters: Double) -> String {
        climbLabel(climbDisplayValue(forMeters: meters))
    }

    static func grade(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else {
            return "0%"
        }

        let percent = fraction * 100
        let formatted = compactNumberFormatter.string(from: NSNumber(value: percent)) ?? "0"
        return "\(formatted)%"
    }

    static func climbFeet(_ feet: Double) -> String {
        climbLabel(climbDisplayValue(forFeet: feet))
    }

    static func distanceInputValue(forMiles miles: Double) -> String {
        formattedNumber(distanceDisplayValue(forMiles: miles), allowsFractionalValue: true)
    }

    static func climbInputValue(forFeet feet: Double) -> String {
        formattedNumber(climbDisplayValue(forFeet: feet), allowsFractionalValue: false)
    }

    static func parseNumericInput(_ string: String) -> Double? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let value = decimalInputFormatter.number(from: trimmed)?.doubleValue {
            return value
        }

        let allowedCharacters = CharacterSet(charactersIn: "0123456789-+.,")
        let sanitized = trimmed.unicodeScalars
            .filter { allowedCharacters.contains($0) }
            .map(String.init)
            .joined()

        guard !sanitized.isEmpty else {
            return nil
        }

        return decimalInputFormatter.number(from: sanitized)?.doubleValue
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds > 0 else {
            return "No estimate"
        }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.zeroFormattingBehavior = [.dropAll]
        return formatter.string(from: seconds) ?? "No estimate"
    }

    static func raceTime(_ seconds: Double) -> String {
        guard seconds > 0 else {
            return "No estimate"
        }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: seconds) ?? "No estimate"
    }

    static func pace(_ seconds: Double, overDistanceMeters meters: Double) -> String {
        guard seconds > 0, meters > 0 else {
            return "No pace"
        }

        let unitDistanceMeters = measurementSystem == .metric ? 1_000.0 : 1_609.34
        let secondsPerUnit = seconds / (meters / unitDistanceMeters)
        let paceValue = raceTime(secondsPerUnit)
        return "\(paceValue) /\(measurementSystem.distanceUnitLabel)"
    }

    static func speed(_ metersPerSecond: Double) -> String {
        guard metersPerSecond > 0 else {
            return "No speed"
        }

        let unitSpeed = measurementSystem == .metric ? metersPerSecond * 3.6 : metersPerSecond * 2.23694
        let formatted = compactNumberFormatter.string(from: NSNumber(value: unitSpeed)) ?? "0"
        let unitLabel = measurementSystem == .metric ? "km/h" : "mph"
        return "\(formatted) \(unitLabel)"
    }

    static func relativeDate(_ date: Date?) -> String {
        guard let date else {
            return "Unknown"
        }

        return relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func absoluteDate(_ date: Date?) -> String {
        guard let date else {
            return "Unknown"
        }

        return absoluteDateFormatter.string(from: date)
    }

    static func calendarDate(_ date: Date?) -> String {
        guard let date else {
            return "Unknown"
        }

        return calendarDateFormatter.string(from: date)
    }

    static func compactCount(_ count: Int) -> String {
        compactNumberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    static func coordinateLabel(for coordinate: CLLocationCoordinate2D) -> String {
        let latitude = compactNumberFormatter.string(from: NSNumber(value: coordinate.latitude)) ?? "0"
        let longitude = compactNumberFormatter.string(from: NSNumber(value: coordinate.longitude)) ?? "0"
        return "\(latitude), \(longitude)"
    }

    static func weatherTemperature(_ value: Double, includeUnit: Bool = false) -> String {
        let formattedValue = weatherNumberFormatter.string(from: NSNumber(value: value)) ?? "0"
        let suffix = includeUnit
            ? (measurementSystem == .metric ? "°C" : "°F")
            : "°"
        return "\(formattedValue)\(suffix)"
    }

    static func weatherWindSpeed(_ value: Double) -> String {
        let formattedValue = weatherNumberFormatter.string(from: NSNumber(value: value)) ?? "0"
        let unitLabel = measurementSystem == .metric ? "km/h" : "mph"
        return "\(formattedValue) \(unitLabel)"
    }

    static func percent(_ value: Double) -> String {
        let formattedValue = weatherNumberFormatter.string(from: NSNumber(value: value)) ?? "0"
        return "\(formattedValue)%"
    }

    static func radius(_ miles: Double) -> String {
        distanceMiles(miles)
    }

    static func distanceDisplayValue(forMeters meters: Double) -> Double {
        measurementSystem == .metric ? meters / 1_000 : meters * 0.000621371
    }

    static func distanceDisplayValue(forMiles miles: Double) -> Double {
        measurementSystem == .metric ? miles * milesToKilometers : miles
    }

    static func miles(fromDistanceDisplayValue value: Double) -> Double {
        measurementSystem == .metric ? value / milesToKilometers : value
    }

    static func climbDisplayValue(forMeters meters: Double) -> Double {
        measurementSystem == .metric ? meters : meters * 3.28084
    }

    static func climbDisplayValue(forFeet feet: Double) -> Double {
        measurementSystem == .metric ? feet * feetToMeters : feet
    }

    static func feet(fromClimbDisplayValue value: Double) -> Double {
        measurementSystem == .metric ? value / feetToMeters : value
    }

    private static func distanceLabel(_ value: Double) -> String {
        let formatter = value >= 100 ? wholeNumberFormatter : compactNumberFormatter
        let formattedValue = formatter.string(from: NSNumber(value: value)) ?? "0"
        return "\(formattedValue) \(measurementSystem.distanceUnitLabel)"
    }

    private static func climbLabel(_ value: Double) -> String {
        let formattedValue = wholeNumberFormatter.string(from: NSNumber(value: value)) ?? "0"
        return "\(formattedValue) \(measurementSystem.climbUnitLabel)"
    }

    private static func formattedNumber(_ value: Double, allowsFractionalValue: Bool) -> String {
        let formatter: NumberFormatter
        if allowsFractionalValue, value < 100 {
            formatter = compactNumberFormatter
        } else {
            formatter = wholeNumberFormatter
        }

        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }
}
