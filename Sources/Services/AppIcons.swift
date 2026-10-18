import UIKit

// ═══════════════════════════════════════════════════════════════════════════
//  Icônes au choix (Réglages → Apparence → Icône de l'app).
//
//  Dessins dans assets/icons (make_icons.py). Les icônes au choix sont des
//  fichiers PNG séparés (CFBundleIconFiles), ajoutés à l'app par buildipa.sh,
//  comme Feather pour les siennes : déclarées seulement par le catalogue
//  d'icônes, iOS refusait de les poser sur une app installée par Feather
//  (OSStatus -54). Aperçus « IconPreview-<nom> » faits par la CI.
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

    /// Icônes au choix refusées par cette installation (outil de signature
    /// qui les retire de l'app, par exemple).
    static let unsupported = "unsupported"

    @MainActor static var current: AppIconChoice {
        guard let name = UIApplication.shared.alternateIconName else { return .standard }
        return allCases.first { $0.iconName == name } ?? .standard
    }

    /// iOS change l'icône (et le dit lui-même par une petite alerte). `done` :
    /// nil si c'est fait, sinon la raison donnée par iOS — jusqu'ici avalée,
    /// un refus ne se voyait pas : on croyait que l'appui ne marchait pas.
    /// Numéro de la dernière demande : le second essai d'une ancienne ne
    /// remplace plus une icône choisie entre-temps.
    @MainActor private static var requests = 0

    @MainActor func apply(retry: Bool = true, request: Int? = nil, _ done: @escaping (String?) -> Void) {
        let request = request ?? {
            Self.requests += 1
            return Self.requests
        }()
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else {
            logger.warn("ICON", "Icônes au choix indisponibles", "supportsAlternateIcons = false")
            done(Self.unsupported)
            return
        }
        // Déjà celle-là : rien à demander.
        guard app.alternateIconName != iconName else { done(nil); return }
        let name = iconName
        app.setAlternateIconName(name) { error in
            Task { @MainActor in
                guard let error else {
                    logger.success("ICON", "Icône changée", name ?? "par défaut")
                    done(nil)
                    return
                }
                let ns = error as NSError
                logger.warn("ICON", "Icône refusée par iOS", "\(name ?? "par défaut") — \(ns.domain) \(ns.code) \(ns.localizedDescription) — signée « \(SigningInfo.applicationIdentifier ?? "?") »")
                // « Ressource temporairement indisponible » : iOS occupé, un
                // second essai un peu plus tard passe d'habitude.
                if retry, ns.domain == NSPOSIXErrorDomain, ns.code == 35 {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    // Une autre icône demandée entre-temps : c'est elle qui compte.
                    guard request == Self.requests else { done(nil); return }
                    apply(retry: false, request: request, done)
                    return
                }
                done("\(ns.localizedDescription) (\(ns.domain) \(ns.code))")
            }
        }
    }
}
