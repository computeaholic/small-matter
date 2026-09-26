import Foundation

struct CoolingTemperatureGroup: Identifiable, Equatable {
    let label: String
    let valueCelsius: Double
    let readingCount: Int

    var id: String {
        label
    }
}

enum CoolingTemperaturePresentation {
    static func groups(_ temperatures: [CoolingTemperature]) -> [CoolingTemperatureGroup] {
        var orderedLabels: [String] = []
        var readingsByLabel: [String: [Double]] = [:]

        for temperature in temperatures {
            let label = logicalLabel(for: temperature.name)
            if readingsByLabel[label] == nil {
                orderedLabels.append(label)
                readingsByLabel[label] = []
            }
            readingsByLabel[label, default: []].append(temperature.valueCelsius)
        }

        return orderedLabels.compactMap { label in
            guard let readings = readingsByLabel[label], !readings.isEmpty else { return nil }
            return CoolingTemperatureGroup(
                label: label,
                valueCelsius: readings.reduce(0, +) / Double(readings.count),
                readingCount: readings.count
            )
        }
    }

    static func logicalLabel(for rawName: String) -> String {
        switch rawName {
        case "Battery", "Battery 0", "Battery 1", "Battery 2": return "Battery"
        case "CPU": return "CPU"
        case "GPU": return "GPU"
        default: return "Other"
        }
    }
}
