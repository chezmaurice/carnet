import SwiftUI

enum LogKind: String, CaseIterable, Identifiable {
    case meal
    case exercise
    case breathwork
    case meditation
    case note
    case place
    case document
    case task

    var id: String { rawValue }

    var label: String {
        switch self {
        case .meal:       return "Meal"
        case .exercise:   return "Exercise"
        case .breathwork: return "Breathwork"
        case .meditation: return "Meditation"
        case .note:       return "Note"
        case .place:      return "Place"
        case .document:   return "Document"
        case .task:       return "Task"
        }
    }

    var code: String {
        switch self {
        case .meal:       return "MEAL"
        case .exercise:   return "MOVE"
        case .breathwork: return "BREATH"
        case .meditation: return "MEDITATE"
        case .note:       return "NOTE"
        case .place:      return "PLACE"
        case .document:   return "DOC"
        case .task:       return "TASK"
        }
    }

    var symbol: String {
        switch self {
        case .meal:       return "fork.knife"
        case .exercise:   return "dumbbell"
        case .breathwork: return "wind"
        case .meditation: return "sparkles"
        case .note:       return "pencil"
        case .place:      return "mappin"
        case .document:   return "doc.text"
        case .task:       return "checkmark"
        }
    }

    var signalCategory: String? {
        switch self {
        case .meal:       return "eating"
        case .exercise:   return "sports"
        case .breathwork: return "breathing"
        case .meditation: return "meditation"
        default:          return nil
        }
    }

    /// Items shown in the radial menu
    static let radialItems: [LogKind] = [.meal, .exercise, .breathwork, .meditation, .task]
}
