import Foundation

// MARK: – BetterTTV en direct
//
// Connexion en direct de BTTV (wss://sockets.betterttv.net/ws, le protocole
// de son extension) :
//   • emotes personnelles des abonnés BTTV Pro (« lookup_user ») : BTTV les
//     annonce quand ils ouvrent le chat, et elles valent pour leurs messages
//     seulement, dans toutes les chaînes. Pas de rattrapage : quelqu'un
//     annoncé avant notre arrivée reste inconnu jusqu'à sa prochaine annonce ;
//   • emotes ajoutées, renommées ou retirées sur la chaîne pendant le live
//     (« emote_create », « emote_update », « emote_delete ») : avant, il
//     fallait rouvrir le chat pour les voir.
// Une seule connexion pour tous les chats ouverts (multi-live compris).
actor BTTVLive {
    static let shared = BTTVLive()
    private init() {}

    private var socket: URLSessionWebSocketTask?
    /// Chaînes suivies → nombre de chats ouverts dessus.
    private var channels: [String: Int] = [:]
    /// Attente avant de se reconnecter (s), doublée à chaque échec.
    private var retry: UInt64 = 2

    func join(channelId: String) {
        guard !channelId.isEmpty else { return }
        channels[channelId, default: 0] += 1
        if socket == nil { connect() }
        else if channels[channelId] == 1 { send("join_channel", ["name": "twitch:\(channelId)"]) }
    }

    func leave(channelId: String) {
        guard let n = channels[channelId] else { return }
        if n > 1 { channels[channelId] = n - 1; return }
        channels[channelId] = nil
        send("part_channel", ["name": "twitch:\(channelId)"])
        if channels.isEmpty {
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
        }
    }

    private func connect() {
        guard let url = URL(string: "wss://sockets.betterttv.net/ws") else { return }
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        ws.resume()
        for id in channels.keys { send("join_channel", ["name": "twitch:\(id)"]) }
        listen(ws)
    }

    private func send(_ name: String, _ data: [String: Any]) {
        guard let socket,
              let body = try? JSONSerialization.data(withJSONObject: ["name": name, "data": data]),
              let text = String(data: body, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private nonisolated func listen(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            guard let self else { return }
            Task { await self.received(result, from: ws) }
        }
    }

    private func received(_ result: Result<URLSessionWebSocketTask.Message, Error>,
                          from ws: URLSessionWebSocketTask) async {
        guard ws === socket else { return }   // connexion déjà remplacée
        switch result {
        case .failure:
            socket = nil
            guard !channels.isEmpty else { return }
            let wait = retry
            retry = min(60, retry * 2)
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            if socket == nil, !channels.isEmpty { connect() }
        case .success(let message):
            retry = 2
            if case .string(let text) = message { await handle(text) }
            listen(ws)
        }
    }

    private func handle(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String,
              let d = obj["data"] as? [String: Any] else { return }
        // « twitch:<id de la chaîne> »
        let channelId = (d["channel"] as? String)?.components(separatedBy: ":").last ?? ""
        switch name {
        case "lookup_user":
            guard d["pro"] as? Bool == true, let uid = d["providerId"] as? String,
                  let list = d["emotes"] as? [[String: Any]], !list.isEmpty else { return }
            await EmoteService.shared.setPersonalBTTV(userId: uid, emotes: list)
            logger.debug("EMOTES", "Emotes personnelles BTTV", "\(list.count) pour \(uid)")
        case "emote_create", "emote_update":
            guard let e = d["emote"] as? [String: Any], !channelId.isEmpty else { return }
            await EmoteService.shared.upsertChannelBTTV(channelId: channelId, emote: e)
        case "emote_delete":
            guard let eid = d["emoteId"] as? String, !channelId.isEmpty else { return }
            await EmoteService.shared.removeChannelBTTV(channelId: channelId, emoteId: eid)
        default:
            break
        }
    }
}
