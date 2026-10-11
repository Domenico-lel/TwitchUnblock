import UIKit

// ═══════════════════════════════════════════════════════════════════════════
//  Icônes au choix (Réglages → Apparence → Icône de l'app).
//
//  Dessins dans assets/icons (make_icons.py) ; la CI en fait les catalogues
//  « AppIcon-<nom> », chacun avec ses versions sombre et teintée (iOS 18+,
//  dont iOS 26 tire aussi les icônes transparentes), et les aperçus
//  « IconPreview-<nom> » de ce réglage.
// ═══════════════════════════════════════════════════════════════════════════
enum AppIconChoice: String, CaseIterable, Identifiable {
    case standard = "Default"
    case purple = "Purple"
    case night = "Night"
    case light = "Light"
    case contrast = "Contrast"
    case neon = "Neon"

    var id: String { rawValue }
    /// Nom donné à iOS (nil : l'icône par défaut).
    var iconName: String? { self == .standard ? nil : "AppIcon-\(rawValue)" }
    var previewName: String { "IconPreview-\(rawValue)" }
    var labelKey: String { "icon_\(rawValue.lowercased())" }

    @MainActor static var current: AppIconChoice {
        guard let name = UIApplication.shared.alternateIconName else { return .standard }
        return allCases.first { $0.iconName == name } ?? .standard
    }

    /// iOS change l'icône (et le dit lui-même par une petite alerte).
    @MainActor func apply() async -> Bool {
        guard UIApplication.shared.supportsAlternateIcons else { return false }
        do {
            try await UIApplication.shared.setAlternateIconName(iconName)
            return true
        } catch {
            logger.warn("ICON", "Icône refusée par iOS", error.localizedDescription)
            return false
        }
    }
}
