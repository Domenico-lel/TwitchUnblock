import AVFoundation

// ═══════════════════════════════════════════════════════════════════════════
//  Audio spatial (AirPods). Une vidéo lue par AVPlayer est spatialisée par
//  défaut, même en stéréo (`allowedAudioSpatializationFormats` vaut alors
//  `.monoStereoAndMultichannel`) : c'est le cas des lives et VODs Twitch.
//
//  Le seul choix qu'iOS laisse à une app : autoriser ou non cette
//  spatialisation, élément par élément. « Fixe » et « Suivi de la tête » se
//  règlent dans le Centre de contrôle (appui long sur le volume → Audio
//  spatial) ; les API qui les ouvrent aux apps n'existent que sur visionOS.
// ═══════════════════════════════════════════════════════════════════════════

enum SpatialAudio {
    /// « auto » : choix d'iOS ; « off » : jamais spatialisé dans l'app.
    static let key = "cfg_spatial_audio"

    static var isOff: Bool { UserDefaults.standard.string(forKey: key) == "off" }

    /// À appliquer avant la lecture. `[]` : la stéréo reste de la stéréo, le
    /// suivi de la tête n'a plus d'effet. Rien sinon : la valeur par défaut
    /// d'iOS dépend du type d'élément (vidéo ou audio seul).
    static func apply(to item: AVPlayerItem) {
        if isOff { item.allowedAudioSpatializationFormats = [] }
    }
}

extension Notification.Name {
    /// Réglage « Audio spatial » changé : les lecteurs recréent leur élément.
    static let tuSpatialAudioChanged = Notification.Name("TUSpatialAudioChanged")
}
