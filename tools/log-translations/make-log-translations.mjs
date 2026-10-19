// Génère Sources/Services/LogTranslations.swift depuis fragments.json (relevé
// des appels au journal) et translations.json (français → [en, es, ru]).
//   node make-log-translations.mjs <fragments.json> <translations.json> <sortie.swift>
import fs from 'node:fs'

const [fragFile, trFile, outFile] = process.argv.slice(2)
const fragments = JSON.parse(fs.readFileSync(fragFile, 'utf8')).map((x) => x.fr)
const tr = JSON.parse(fs.readFileSync(trFile, 'utf8'))   // JSON.parse garde la dernière clé en double : contrôlée ci-dessous

// Clés en double dans le fichier source (JSON.parse les fusionnerait sans rien dire).
const rawKeys = [...fs.readFileSync(trFile, 'utf8').matchAll(/^\s*"((?:[^"\\]|\\.)*)"\s*:/gm)].map((m) => JSON.parse(`"${m[1]}"`))
const dup = rawKeys.filter((k, i) => rawKeys.indexOf(k) !== i)
if (dup.length) throw new Error(`clés en double : ${dup.join(' | ')}`)

let errors = 0
for (const [fr, v] of Object.entries(tr)) {
  if (!Array.isArray(v) || v.length !== 3 || v.some((s) => typeof s !== 'string' || !s)) { console.log('✗ traduction incomplète :', fr); errors++ }
  if (!fragments.some((f) => f.includes(fr))) { console.log('✗ absente du journal :', fr); errors++ }
}
// Morceaux encore français sans aucune traduction qui les couvre.
const french = /[éèêàâçùûîïôœ]|\b(le|la|les|des|du|de|pour|sans|avec|une?|pas|plus|par|sur|dans|reçu|échou|refus|chargé|terminé|indisponible)\b/i
const uncovered = fragments.filter((f) => french.test(f) && !Object.keys(tr).some((k) => f.includes(k)))
for (const f of uncovered) console.log('· sans traduction :', JSON.stringify(f))
if (errors) process.exit(1)

const q = (s) => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n')}"`
const rows = Object.entries(tr).sort((a, b) => a[0].localeCompare(b[0], 'fr'))
  .map(([fr, [en, es, ru]]) => `        ${q(fr)}: [${q(en)}, ${q(es)}, ${q(ru)}],`).join('\n')

const swift = `import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  Journal traduit — FICHIER GÉNÉRÉ (tools/log-translations, voir son README.md,
//  depuis les appels au journal) : ne pas le modifier à la main.
//  Le journal reste écrit en français ; à l'affichage, ses morceaux français
//  sont remplacés par leur traduction dans la langue de l'app. Les nombres,
//  noms et adresses insérés dans les messages ne changent pas.
// ═══════════════════════════════════════════════════════════════════════════

enum LogTranslator {
    /// Français → [anglais, espagnol, russe].
    private static let table: [String: [String]] = [
${rows}
    ]

    private struct Entry {
        let fr: String
        let tr: [String]
        /// Un seul mot : remplacé seulement s'il est entier (pas dans un pseudo).
        let word: NSRegularExpression?
    }

    /// Les plus longs d'abord : une phrase passe avant les mots qu'elle contient.
    private static let entries: [Entry] = table
        .sorted { $0.key.count != $1.key.count ? $0.key.count > $1.key.count : $0.key < $1.key }
        .map { fr, tr in
            let word = fr.contains(" ") ? nil : try? NSRegularExpression(
                pattern: "(?<![\\\\p{L}\\\\p{N}_])" + NSRegularExpression.escapedPattern(for: fr) + "(?![\\\\p{L}\\\\p{N}_])")
            return Entry(fr: fr, tr: tr, word: word)
        }

    /// Textes déjà traduits (« langue|texte »), vidé au-delà de 4 000.
    private static var cache: [String: String] = [:]

    /// Texte du journal dans la langue de l'app (le français tel quel).
    static func translate(_ text: String, _ lang: Lang) -> String {
        let col: Int
        switch lang.rawValue {
        case "fr": return text
        case "es": col = 1
        case "ru": col = 2
        default:   col = 0
        }
        guard !text.isEmpty else { return text }
        let key = "\\(lang.rawValue)|\\(text)"
        if let hit = cache[key] { return hit }
        var out = text
        for e in entries where out.contains(e.fr) {
            let t = e.tr[col]
            if let re = e.word {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                  withTemplate: NSRegularExpression.escapedTemplate(for: t))
            } else {
                out = out.replacingOccurrences(of: e.fr, with: t)
            }
        }
        if cache.count > 4000 { cache.removeAll() }
        cache[key] = out
        return out
    }
}
`
fs.writeFileSync(outFile, swift)
console.log(`${Object.keys(tr).length} traductions écrites dans ${outFile} (${uncovered.length} morceaux français sans traduction)`)
