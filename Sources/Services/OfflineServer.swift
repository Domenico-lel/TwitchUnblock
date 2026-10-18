import Foundation
import Network
import UIKit

// ═══════════════════════════════════════════════════════════════════════════
//  Mini-serveur HTTP local pour lire les VODs téléchargées.
//
//  AVPlayer ne lit une playlist HLS que par HTTP : pas de lecture directe d'un
//  .m3u8 et de ses segments posés sur le disque. Ce serveur n'écoute que sur
//  l'interface de bouclage (127.0.0.1 : rien n'est joignable depuis le
//  réseau) et sert le dossier des téléchargements, le temps de la lecture.
// ═══════════════════════════════════════════════════════════════════════════

final class OfflineServer {
    static let shared = OfflineServer()

    private let queue = DispatchQueue(label: "tu.offline.server")
    private var listener: NWListener?
    private var port: UInt16?
    /// Port du dernier serveur, repris quand il faut le relancer : la lecture
    /// en cours (adresses déjà données à AVPlayer) peut ainsi continuer.
    private var lastPort: UInt16?
    private var waiting: [(UInt16?) -> Void] = []

    private init() {
        // iOS ferme le serveur pendant que l'app est suspendue : relancé au
        // retour (premier plan, ou app réactivée sans y passer).
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { if self.lastPort != nil { self.ensureStarted { _ in } } }
            }
        }
    }

    /// Préfixe secret tiré à chaque lancement : une autre app de l'appareil,
    /// qui parcourrait les ports, ne lit ni la liste des téléchargements ni
    /// leurs chats (tout le dossier était servi sans contrôle).
    private let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    /// http://127.0.0.1:<port>/<secret>, serveur démarré au besoin. nil s'il ne peut pas.
    func baseURL() async -> URL? {
        let port: UInt16? = await withCheckedContinuation { cont in
            queue.async { self.ensureStarted { cont.resume(returning: $0) } }
        }
        return port.flatMap { URL(string: "http://127.0.0.1:\($0)/\(secret)") }
    }

    /// Seuls la playlist et les segments vidéo sont servis (ni index.json,
    /// ni plan.json, ni chat.json : l'app les lit sur le disque).
    private static let servedExtensions: Set<String> = ["m3u8", "ts", "mp4", "m4s", "aac", "m4a", "mp3"]

    private func ensureStarted(_ done: @escaping (UInt16?) -> Void) {
        if let port { done(port); return }
        waiting.append(done)
        if listener == nil { startListener() }   // sinon : démarrage déjà en cours
    }

    private func startListener() {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let wanted = lastPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        guard let l = try? NWListener(using: params, on: wanted) else {
            if lastPort != nil { lastPort = nil; startListener() } else { finish(nil) }
            return
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            switch state {
            case .ready:
                self.port = l.port?.rawValue
                self.lastPort = self.port
                self.finish(self.port)
            case .waiting, .failed:
                l.cancel()   // → .cancelled
            case .cancelled:
                guard self.listener === l else { return }
                let wasReady = self.port != nil
                self.port = nil
                self.listener = nil
                if wasReady, self.lastPort != nil {
                    // Fermé par iOS pendant une suspension : une lecture hors
                    // ligne peut reprendre sans repasser au premier plan (écran
                    // verrouillé, PiP) et calait. Relancé aussitôt sur le même
                    // port : les adresses données à AVPlayer restent bonnes.
                    self.startListener()
                } else if self.lastPort != nil, !self.waiting.isEmpty {
                    // L'ancien port est pris : un autre.
                    self.lastPort = nil
                    self.startListener()
                } else {
                    self.finish(nil)
                }
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        listener = l
        l.start(queue: queue)
    }

    private func finish(_ port: UInt16?) {
        let callbacks = waiting
        waiting.removeAll()
        callbacks.forEach { $0(port) }
    }

    // MARK: Requêtes
    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(conn, request: String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if complete || error != nil || buf.count > 65_536 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, request: String) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            send(conn, status: "405 Method Not Allowed", headers: [:], body: Data())
            return
        }
        let rawPath = String(parts[1]).components(separatedBy: "?").first ?? ""
        let full = (rawPath.removingPercentEncoding ?? rawPath).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Préfixe secret obligatoire, retiré avant de chercher le fichier.
        guard full.hasPrefix(secret + "/") else {
            send(conn, status: "404 Not Found", headers: [:], body: Data())
            return
        }
        let path = String(full.dropFirst(secret.count + 1))
        let file = VodDownloads.directory.appendingPathComponent(path)
        // Rien en dehors du dossier des téléchargements, et seulement la vidéo.
        guard !path.isEmpty, !path.contains(".."),
              Self.servedExtensions.contains(file.pathExtension.lowercased()),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            send(conn, status: "404 Not Found", headers: [:], body: Data())
            return
        }
        var status = "200 OK"
        var body = data
        var headers = ["Content-Type": Self.mime(file.pathExtension), "Accept-Ranges": "bytes"]
        if let line = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let asked = Self.byteRange(line, size: data.count) {
            switch asked {
            case .range(let range):
                status = "206 Partial Content"
                body = data.subdata(in: range)
                headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
            case .unsatisfiable:
                status = "416 Range Not Satisfiable"
                body = Data()
                headers["Content-Range"] = "bytes */\(data.count)"
            }
        }
        headers["Content-Length"] = "\(body.count)"
        send(conn, status: status, headers: headers, body: parts[0] == "HEAD" ? Data() : body)
    }

    private func send(_ conn: NWConnection, status: String, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status)\r\nConnection: close\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private enum ByteRange { case range(Range<Int>), unsatisfiable }

    /// « Range: bytes=début-fin » (fin facultative), ou « bytes=-N » : les N
    /// derniers octets (servi comme « depuis 0 » avant). Hors du fichier : 416
    /// (un 200 avec tout le fichier était renvoyé).
    private static func byteRange(_ line: String, size: Int) -> ByteRange? {
        guard let spec = line.split(separator: "=", maxSplits: 1).last else { return nil }
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        let first = bounds[0].trimmingCharacters(in: .whitespaces)
        let last = bounds[1].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            guard let n = Int(last), n > 0, size > 0 else { return .unsatisfiable }
            return .range(max(0, size - n) ..< size)
        }
        guard let start = Int(first) else { return nil }
        let end = Int(last).map { min($0, size - 1) } ?? size - 1
        guard start < size, start <= end else { return .unsatisfiable }
        return .range(start ..< end + 1)
    }

    private static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "m3u8":       return "application/vnd.apple.mpegurl"
        case "ts":         return "video/mp2t"
        case "mp4", "m4s": return "video/mp4"
        case "aac":        return "audio/aac"
        default:           return "application/octet-stream"
        }
    }
}
