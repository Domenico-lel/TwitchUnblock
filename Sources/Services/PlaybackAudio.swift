import AVFoundation

// ═══════════════════════════════════════════════════════════════════════════
//  Session audio de la lecture.
//
//  Catégorie `.playback`, mode `.moviePlayback`, réglée au lancement : le son
//  continue écran verrouillé et dans une autre app ; le PiP et AirPlay en ont
//  besoin. La session, elle, n'est activée qu'à l'ouverture d'un lecteur :
//  activée dès le lancement, elle coupait la musique des autres apps à la
//  simple ouverture de l'app, sans rien lire. À la fermeture du dernier
//  lecteur, elle est relâchée en prévenant les autres apps
//  (`notifyOthersOnDeactivation`) : une musique coupée par la vidéo peut
//  reprendre.
// ═══════════════════════════════════════════════════════════════════════════
final class PlaybackAudio {
    static let shared = PlaybackAudio()

    /// Activer ou relâcher la session bloque le temps qu'iOS réponde : jamais
    /// sur le fil principal.
    private let queue = DispatchQueue(label: "tu.audio.session")
    // Tenus sur `queue` seulement.
    /// Lecteurs ouverts : « player » (écran du lecteur), « multi » (multi-live).
    private var owners = Set<String>()
    /// Dernière demande : une relâche prévue n'a lieu que si aucun lecteur ne
    /// s'est ouvert entre-temps.
    private var generation = 0

    private init() {}

    /// Au lancement : la catégorie seulement, sans activer la session.
    static func configure() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        } catch {
            logger.warn("LECTEUR", "Session audio : catégorie refusée", error.localizedDescription)
        }
    }

    /// Un lecteur s'ouvre : le son passe à l'app (celui des autres apps
    /// s'arrête, comme pour toute vidéo).
    func claim(_ owner: String) {
        queue.async { [self] in
            owners.insert(owner)
            generation += 1
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                // Appel en cours, par exemple : AVPlayer la redemandera en jouant.
                logger.warn("LECTEUR", "Session audio refusée", error.localizedDescription)
            }
        }
    }

    /// Un lecteur se ferme. Au dernier, la session est relâchée un peu plus
    /// tard : passer du multi-live au lecteur (ou l'inverse) ferme l'un juste
    /// avant d'ouvrir l'autre, et la musique des autres apps ne doit pas
    /// reprendre le temps d'un éclair. `notifyOthers` faux (minuteur de
    /// veille) : la session est rendue sans réveiller la musique d'une autre
    /// app.
    func release(_ owner: String, notifyOthers: Bool = true) {
        queue.async { [self] in
            guard owners.remove(owner) != nil, owners.isEmpty else { return }
            generation += 1
            let wanted = generation
            queue.asyncAfter(deadline: .now() + 1.5) { [self] in
                deactivate(notifyOthers: notifyOthers, generation: wanted, attempt: 0)
            }
        }
    }

    /// Sur `queue`. Refusé tant qu'un son joue encore (PiP d'un lecteur déjà
    /// fermé) : nouvel essai toutes les 10 s, pendant 10 min au plus, tant
    /// qu'aucun lecteur ne reprend la session.
    private func deactivate(notifyOthers: Bool, generation wanted: Int, attempt: Int) {
        guard wanted == generation, owners.isEmpty else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: notifyOthers ? .notifyOthersOnDeactivation : [])
            logger.info("LECTEUR", "Session audio relâchée",
                        notifyOthers ? "les autres apps peuvent reprendre leur son"
                                     : "sans réveiller les autres apps (minuteur de veille)")
        } catch {
            if attempt == 0 { logger.debug("LECTEUR", "Session audio gardée", error.localizedDescription) }
            guard attempt < 60 else { return }
            queue.asyncAfter(deadline: .now() + 10) { [self] in
                deactivate(notifyOthers: notifyOthers, generation: wanted, attempt: attempt + 1)
            }
        }
    }
}
