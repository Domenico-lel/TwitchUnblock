import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  Signature de l'app, lue dans son propre exécutable : l'identifiant
//  d'application (« application-identifier ») avec lequel elle a été signée.
//
//  Un outil de signature comme Feather reprend tels quels, par défaut, les
//  droits (entitlements) du profil de provisionnement : avec le profil
//  générique d'un certificat acheté, l'app est signée « ÉQUIPE.* » au lieu
//  de « ÉQUIPE.<son identifiant> ». iOS refuse alors de lui changer son
//  icône (OSStatus -54, refus d'autorisation de LaunchServices) — Feather
//  corrige l'étoile avec son option « Merge Entitlements ». On le détecte
//  pour le dire, plutôt que de laisser un code d'erreur.
// ═══════════════════════════════════════════════════════════════════════════
enum SigningInfo {
    /// « ABCDE12345.com.mxfia19.TwitchUnblock », « ABCDE12345.* »… ; nil si
    /// illisible (simulateur, app non signée).
    static let applicationIdentifier: String? = entitlements()?["application-identifier"] as? String

    /// Signée avec un autre identifiant que le sien (l'étoile d'un profil
    /// générique, le plus souvent).
    static var signedForOtherIdentifier: Bool {
        guard let id = applicationIdentifier, let bundle = Bundle.main.bundleIdentifier else { return false }
        return !id.hasSuffix(".\(bundle)")
    }

    // MARK: Lecture de la signature (Mach-O → LC_CODE_SIGNATURE → droits)
    private static func entitlements() -> [String: Any]? {
        guard let url = Bundle.main.executableURL,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let magic = read(handle, 0, 4) else { return nil }
        // Binaire universel : la tranche arm64.
        var base: UInt64 = 0
        if magic.uint32BE(0) == 0xCAFE_BABE {
            guard let count = read(handle, 4, 4).map({ Int($0.uint32BE(0)) }), count > 0, count < 16,
                  let archs = read(handle, 8, count * 20) else { return nil }
            for i in 0 ..< count where archs.uint32BE(i * 20) == 0x0100_000C {   // CPU_TYPE_ARM64
                base = UInt64(archs.uint32BE(i * 20 + 8))
                break
            }
            guard base != 0 else { return nil }
        }
        guard let header = read(handle, base, 32), header.uint32LE(0) == 0xFEED_FACF else { return nil }   // MH_MAGIC_64
        let commands = Int(header.uint32LE(16))
        let size = Int(header.uint32LE(20))
        guard size > 0, size < 4_000_000, let list = read(handle, base + 32, size) else { return nil }
        var offset = 0
        for _ in 0 ..< commands {
            guard offset + 16 <= list.count else { return nil }
            let length = Int(list.uint32LE(offset + 4))
            if list.uint32LE(offset) == 0x1D {   // LC_CODE_SIGNATURE
                let dataOffset = UInt64(list.uint32LE(offset + 8))
                let dataSize = Int(list.uint32LE(offset + 12))
                guard dataSize > 12, dataSize < 16_000_000,
                      let blob = read(handle, base + dataOffset, dataSize) else { return nil }
                return entitlements(in: blob)
            }
            guard length > 0 else { return nil }
            offset += length
        }
        return nil
    }

    /// Droits dans la signature (SuperBlob, emplacement 5) : une plist XML.
    private static func entitlements(in blob: Data) -> [String: Any]? {
        guard blob.uint32BE(0) == 0xFADE_0CC0 else { return nil }   // CSMAGIC_EMBEDDED_SIGNATURE
        let count = Int(blob.uint32BE(8))
        for i in 0 ..< min(count, 64) {
            let entry = 12 + i * 8
            guard entry + 8 <= blob.count else { return nil }
            let start = Int(blob.uint32BE(entry + 4))
            guard blob.uint32BE(entry) == 5, start + 8 <= blob.count else { continue }   // CSSLOT_ENTITLEMENTS
            guard blob.uint32BE(start) == 0xFADE_7171 else { return nil }   // CSMAGIC_EMBEDDED_ENTITLEMENTS
            let length = Int(blob.uint32BE(start + 4))
            guard length > 8, start + length <= blob.count else { return nil }
            let xml = blob.subdata(in: blob.startIndex + start + 8 ..< blob.startIndex + start + length)
            return (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any]
        }
        return nil
    }

    private static func read(_ handle: FileHandle, _ offset: UInt64, _ count: Int) -> Data? {
        guard count > 0, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }
}

private extension Data {
    func uint32BE(_ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= count else { return 0 }
        return self[startIndex + at ..< startIndex + at + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func uint32LE(_ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= count else { return 0 }
        return self[startIndex + at ..< startIndex + at + 4].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
