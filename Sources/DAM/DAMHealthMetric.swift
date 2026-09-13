import Foundation
import SwiftUI

// MARK: - Available health metrics

/// A selectable storage-health metric shown in the Storage Health panel.
/// The user can toggle each metric on/off; the selection is persisted
/// automatically via `DAMHealthMetricsStore`.
enum DAMHealthMetric: String, CaseIterable, Codable, Identifiable {
    case smartStatus
    case healthScore
    case freeSpace
    case filesystemVerify
    case temperature
    case powerOnHours
    case powerCycles
    case startStops
    case loadCycles
    case udmaCRCErrors
    case reallocatedSectors
    case pendingSectors
    case offlineUncorrectable
    case gSenseErrors
    case multiZoneErrors
    case wearLevel
    case percentageUsed
    case fileVault
    case encryption
    case timeMachineBackup
    case busProtocol
    case isSSD

    var id: String { rawValue }

    /// User-facing label.
    var displayName: String {
        switch self {
        case .smartStatus:          return "SMART status"
        case .healthScore:          return "Health score"
        case .freeSpace:            return "Free space %"
        case .filesystemVerify:     return "Filesystem verify"
        case .temperature:          return "Temperature"
        case .powerOnHours:         return "Power-on hours"
        case .powerCycles:          return "Power cycles"
        case .startStops:           return "Start/stop count"
        case .loadCycles:           return "Load cycles"
        case .udmaCRCErrors:        return "UDMA CRC errors"
        case .reallocatedSectors:   return "Reallocated sectors"
        case .pendingSectors:       return "Pending sectors"
        case .offlineUncorrectable: return "Offline uncorrectable"
        case .gSenseErrors:         return "G-sense errors"
        case .multiZoneErrors:      return "Multi-zone errors"
        case .wearLevel:            return "Wear level %"
        case .percentageUsed:       return "NVMe % used"
        case .fileVault:            return "FileVault"
        case .encryption:           return "Encryption"
        case .timeMachineBackup:    return "Time Machine backup"
        case .busProtocol:          return "Bus/protocol"
        case .isSSD:                return "SSD"
        }
    }

    /// Logical grouping for the selection menu.
    var category: String {
        switch self {
        case .smartStatus, .healthScore, .temperature, .powerOnHours, .powerCycles,
             .startStops, .loadCycles, .udmaCRCErrors, .reallocatedSectors,
             .pendingSectors, .offlineUncorrectable, .gSenseErrors,
             .multiZoneErrors, .wearLevel, .percentageUsed:
            return "SMART / Drive"
        case .freeSpace, .filesystemVerify, .fileVault,
             .encryption, .timeMachineBackup:
            return "Volume / System"
        case .busProtocol, .isSSD:
            return "Identity"
        }
    }

    /// Default visibility when the user has never customised the list.
    var isVisibleByDefault: Bool {
        switch self {
        case .smartStatus, .healthScore, .freeSpace, .temperature, .powerOnHours,
             .reallocatedSectors, .pendingSectors, .wearLevel, .percentageUsed,
             .fileVault, .encryption, .timeMachineBackup:
            return true
        default:
            return false
        }
    }
}

// MARK: - Persistent selection store

/// Persists which health metrics the user wants to see.
/// The selection is saved to UserDefaults automatically on every change.
@Observable
@MainActor
final class DAMHealthMetricsStore {
    static let shared = DAMHealthMetricsStore()

    private let defaultsKey = "dam.healthMetrics.selection"

    private(set) var selected: Set<DAMHealthMetric> = []

    private init() {
        selected = loadSelection()
    }

    func isSelected(_ metric: DAMHealthMetric) -> Bool {
        selected.contains(metric)
    }

    func toggle(_ metric: DAMHealthMetric) {
        if selected.contains(metric) {
            selected.remove(metric)
        } else {
            selected.insert(metric)
        }
        saveSelection(selected)
    }

    func resetToDefaults() {
        selected = Set(DAMHealthMetric.allCases.filter(\.isVisibleByDefault))
        saveSelection(selected)
    }

    // MARK: - Persistence

    private func loadSelection() -> Set<DAMHealthMetric> {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(Set<DAMHealthMetric>.self, from: data)
        else {
            return Set(DAMHealthMetric.allCases.filter(\.isVisibleByDefault))
        }
        return decoded
    }

    private func saveSelection(_ selection: Set<DAMHealthMetric>) {
        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - Helper extensions

private extension DAMHealthMetric {
    /// Decode-safe key path for `Set<DAMHealthMetric>`.
}
