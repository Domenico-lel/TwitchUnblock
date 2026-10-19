import AVFoundation

// ═══════════════════════════════════════════════════════════════════════════
//  Ce que le lecteur vidéo ne disait pas : erreurs HLS (segment ou playlist
//  refusés, code HTTP, serveur) et lecture bloquée faute de données. Écouté
//  une fois pour tous les lecteurs (immersif, Apple, multi-live, Apple TV),
//  dans le journal : quand un direct coupe, on voit pourquoi.
//  Seul le serveur est noté, jamais l'adresse complète (elle porte le jeton
//  de lecture).
// ═══════════════════════════════════════════════════════════════════════════
enum PlaybackDiagnostics {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: nil, queue: .main) { note in
            guard let item = note.object as? AVPlayerItem,
                  let event = item.errorLog()?.events.last else { return }
            let host = event.uri.flatMap { URL(string: $0)?.host } ?? "?"
            let code = event.errorStatusCode
            // Le journal regroupe les répétitions (« ×N ») : une rafale de
            // segments refusés reste une seule ligne.
            logger.warn("LECTEUR", code >= 400 ? "Segment ou playlist refusé (HTTP \(code))" : "Erreur de lecture HLS",
                        "\(event.errorDomain) \(code) · \(host)\(event.errorComment.map { " · \($0)" } ?? "")")
        }
        nc.addObserver(forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main) { note in
            let host = ((note.object as? AVPlayerItem)?.asset as? AVURLAsset)?.url.host ?? "?"
            logger.warn("LECTEUR", "Lecture bloquée : plus de données (réseau trop lent ?)", host)
        }
    }
}
