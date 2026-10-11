import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Chat d'un direct sur l'Apple TV, en lecture seule et sans compte : l'IRC
//  de Twitch par WebSocket, avec un pseudo anonyme (« justinfanNNNNN »),
//  comme le site. Posé sur le côté droit de l'image, dans le calque du
//  lecteur natif (sous ses commandes) ; le bouton « Chat » de la barre de
//  lecture l'affiche ou le masque. Emotes Twitch en images (positions
//  données par Twitch), les autres restent en texte.
// ═══════════════════════════════════════════════════════════════════════════

struct TVChatLine: Identifiable, Equatable {
    enum Part: Equatable {
        case text(String)
        case emote(id: String, name: String)
    }

    let id: String
    let login: String
    let name: String
    let color: Color
    let parts: [Part]
    /// « /me » : tout le message de la couleur du pseudo.
    let action: Bool
}

@MainActor
final class TVChatModel: ObservableObject {
    @Published private(set) var lines: [TVChatLine] = []
    @Published private(set) var connected = false

    private var channel: String?
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    /// Assez pour remplir la hauteur de l'écran.
    private static let keep = 40

    func start(_ login: String) {
        let channel = login.lowercased()
        guard channel != self.channel else { return }
        stop()
        self.channel = channel
        lines = []
        loop = Task { [weak self] in await self?.run(channel) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        channel = nil
        connected = false
    }

    /// Connexion, lecture, et reconnexion après une coupure (2 s, puis de
    /// plus en plus espacée, 30 s au plus).
    private func run(_ channel: String) async {
        var delay: UInt64 = 2
        while !Task.isCancelled {
            await session(channel)
            guard !Task.isCancelled else { return }
            connected = false
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 30)
        }
    }

    private func session(_ channel: String) async {
        guard let url = URL(string: "wss://irc-ws.chat.twitch.tv:443") else { return }
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        ws.resume()
        let nick = "justinfan\(Int.random(in: 10_000 ... 99_999))"
        for command in ["CAP REQ :twitch.tv/tags twitch.tv/commands", "PASS SCHMOOPIIE",
                        "NICK \(nick)", "JOIN #\(channel)"] {
            try? await ws.send(.string(command))
        }
        while !Task.isCancelled {
            guard let message = try? await ws.receive() else { return }
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            for raw in text.components(separatedBy: "\r\n") where !raw.isEmpty {
                await handle(raw, ws)
            }
        }
    }

    private func handle(_ raw: String, _ ws: URLSessionWebSocketTask) async {
        if raw.hasPrefix("PING") {
            try? await ws.send(.string("PONG :tmi.twitch.tv"))
            return
        }
        guard let msg = TVIRCLine(raw) else { return }
        switch msg.command {
        case "001", "JOIN", "ROOMSTATE":
            connected = true
        case "PRIVMSG":
            append(msg)
        case "CLEARMSG":
            // Message supprimé par la modération.
            if let id = msg.tags["target-msg-id"] { lines.removeAll { $0.id == id } }
        case "CLEARCHAT":
            // Personne bannie ou exclue : ses messages partent ; sans nom, tout le chat.
            if let user = msg.trailing?.lowercased(), !user.isEmpty { lines.removeAll { $0.login == user } }
            else { lines = [] }
        default:
            break
        }
    }

    private func append(_ msg: TVIRCLine) {
        guard var body = msg.trailing else { return }
        var action = false
        if body.hasPrefix("\u{1}ACTION "), body.hasSuffix("\u{1}") {
            body = String(body.dropFirst(8).dropLast())
            action = true
        }
        let login = msg.nick ?? ""
        let shown = msg.tags["display-name"] ?? ""
        lines.append(TVChatLine(id: msg.tags["id"] ?? UUID().uuidString,
                                login: login,
                                name: shown.isEmpty ? login : shown,
                                color: Self.color(msg.tags["color"], login: login),
                                parts: Self.parts(body, emotes: msg.tags["emotes"] ?? ""),
                                action: action))
        if lines.count > Self.keep { lines.removeFirst(lines.count - Self.keep) }
    }

    /// Texte et emotes Twitch. Les positions du tag « emotes »
    /// (« 25:0-4,12-16/1902:6-10 ») comptent en points de code Unicode.
    static func parts(_ body: String, emotes: String) -> [TVChatLine.Part] {
        let scalars = Array(body.unicodeScalars)
        var ranges: [(start: Int, end: Int, id: String)] = []
        for entry in emotes.split(separator: "/") {
            let pieces = entry.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            for span in pieces[1].split(separator: ",") {
                let ends = span.split(separator: "-")
                guard ends.count == 2, let a = Int(ends[0]), let b = Int(ends[1]),
                      a <= b, b < scalars.count else { continue }
                ranges.append((a, b, String(pieces[0])))
            }
        }
        ranges.sort { $0.start < $1.start }

        func string(_ from: Int, _ to: Int) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[from ..< to])
            return String(view)
        }
        var out: [TVChatLine.Part] = []
        var i = 0
        for r in ranges where r.start >= i {
            if r.start > i { out.append(.text(string(i, r.start))) }
            out.append(.emote(id: r.id, name: string(r.start, r.end + 1)))
            i = r.end + 1
        }
        if i < scalars.count { out.append(.text(string(i, scalars.count))) }
        return out
    }

    /// Couleurs que Twitch donne à qui n'en a pas choisi.
    private static let palette: [(Double, Double, Double)] = [
        (1, 0, 0), (0, 0, 1), (0, 0.5, 0), (0.7, 0.13, 0.13), (1, 0.5, 0.31), (0.6, 0.8, 0.2), (1, 0.27, 0),
        (0.18, 0.55, 0.34), (0.85, 0.65, 0.13), (0.82, 0.41, 0.12), (0.37, 0.62, 0.63), (0.12, 0.56, 1),
        (1, 0.41, 0.71), (0.54, 0.17, 0.89), (0, 1, 0.5),
    ]

    /// Couleur du pseudo, éclaircie si elle se lit mal sur l'image sombre.
    static func color(_ hex: String?, login: String) -> Color {
        var rgb: (Double, Double, Double)
        if let hex, hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) {
            rgb = (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        } else {
            let sum = login.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            rgb = palette[sum % palette.count]
        }
        let luminance = 0.299 * rgb.0 + 0.587 * rgb.1 + 0.114 * rgb.2
        if luminance < 0.45 {
            let k = 0.45
            rgb = (rgb.0 + (1 - rgb.0) * k, rgb.1 + (1 - rgb.1) * k, rgb.2 + (1 - rgb.2) * k)
        }
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

/// Une ligne IRC de Twitch : « @tags :préfixe COMMANDE #salon :texte ».
struct TVIRCLine {
    var tags: [String: String] = [:]
    var nick: String?
    var command = ""
    var trailing: String?

    init?(_ raw: String) {
        var rest = Substring(raw)
        if rest.hasPrefix("@") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            for pair in rest[rest.index(after: rest.startIndex) ..< space].split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                tags[String(kv[0])] = kv.count > 1 ? Self.unescape(String(kv[1])) : ""
            }
            rest = rest[rest.index(after: space)...]
        }
        if rest.hasPrefix(":") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            let prefix = rest[rest.index(after: rest.startIndex) ..< space]
            nick = prefix.split(separator: "!").first.map(String.init)
            rest = rest[rest.index(after: space)...]
        }
        if let colon = rest.range(of: " :") {
            trailing = String(rest[colon.upperBound...])
            rest = rest[..<colon.lowerBound]
        }
        command = String(rest.split(separator: " ").first ?? "")
        if command.isEmpty { return nil }
    }

    /// Valeurs des tags : « \s » espace, « \: » point-virgule, « \\ » barre.
    private static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaping = false
        for c in s {
            if escaping {
                switch c {
                case "s": out.append(" ")
                case ":": out.append(";")
                case "r", "n": break
                default: out.append(c)
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        return out
    }
}

// MARK: – Affichage
/// Chat sur le côté droit de l'image : les messages les plus récents en
/// bas, les plus anciens s'effacent en haut. Ne prend jamais le focus.
struct TVChatOverlay: View {
    @ObservedObject var model: TVChatModel
    let waiting: String

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                Spacer(minLength: 0)
                if model.lines.isEmpty {
                    Text(waiting)
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.6))
                }
                ForEach(model.lines) { line in
                    TVChatRow(line: line)
                }
            }
            .frame(width: 500, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 30)
            .padding(.vertical, 50)
            .background(Color.black.opacity(0.5))
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .black, location: 0.3),
                                         .init(color: .black, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

struct TVChatRow: View {
    let line: TVChatLine

    private enum Token { case word(String), emote(id: String, name: String) }

    /// Mot par mot, pour que la ligne se coupe entre les mots et les emotes.
    private var tokens: [Token] {
        line.parts.flatMap { part -> [Token] in
            switch part {
            case .text(let s): return s.split(separator: " ").map { .word(String($0)) }
            case .emote(let id, let name): return [.emote(id: id, name: name)]
            }
        }
    }

    var body: some View {
        TVFlowLayout(spacing: 7, lineSpacing: 4) {
            Text(line.action ? line.name : line.name + ":")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(line.color)
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                switch token {
                case .word(let w):
                    Text(w)
                        .font(.system(size: 24))
                        .foregroundColor(line.action ? line.color : .white)
                case .emote(let id, let name):
                    AsyncImage(url: URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/default/dark/2.0")) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        Text(name).font(.system(size: 24)).foregroundColor(.white.opacity(0.7))
                    }
                    .frame(height: 34)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Éléments posés à la suite et renvoyés à la ligne quand la place manque,
/// centrés verticalement sur leur ligne (texte et emotes mêlés).
struct TVFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        let lines = rows(subviews, width: width)
        let height = lines.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) }
            + lineSpacing * CGFloat(max(0, lines.count - 1))
        let used = lines.map { row in row.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, row.count - 1)) }
        return CGSize(width: min(width, used.max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let height = row.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2),
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + lineSpacing
        }
    }
}
