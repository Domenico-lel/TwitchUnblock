// Relève les morceaux de texte des appels au journal (logger.info/success/
// warn/error/debug) dans les sources Swift : chaînes littérales des
// arguments (sauf la catégorie), coupées aux interpolations \( … ).
//   node extract-log-fragments.mjs <dossier Sources> <sortie.json>
import fs from 'node:fs'
import path from 'node:path'

const [dir, outFile] = process.argv.slice(2)
const files = []
const walk = (d) => {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name)
    if (e.isDirectory()) walk(p)
    else if (e.name.endsWith('.swift')) files.push(p)
  }
}
walk(dir)

const ESC = { n: '\n', t: '\t', '"': '"', '\\': '\\', "'": "'", r: '\r', '0': '\0' }

/** Chaîne Swift qui commence à src[i] === '"' : rend { end, parts } où parts
 *  alterne texte littéral et null (interpolation). */
function readString(src, i) {
  if (src.startsWith('"""', i)) {   // multi-ligne : ignorée (rare dans le journal)
    const end = src.indexOf('"""', i + 3)
    return { end: end < 0 ? src.length : end + 3, parts: [] }
  }
  let j = i + 1
  let cur = ''
  const parts = []
  while (j < src.length) {
    const c = src[j]
    if (c === '\\') {
      const n = src[j + 1]
      if (n === '(') {
        parts.push(cur); cur = ''
        parts.push(null)
        j = skipParens(src, j + 1)
        continue
      }
      if (n === 'u' && src[j + 2] === '{') {
        const close = src.indexOf('}', j)
        cur += String.fromCodePoint(parseInt(src.slice(j + 3, close), 16))
        j = close + 1
        continue
      }
      cur += ESC[n] ?? n
      j += 2
      continue
    }
    if (c === '"') { parts.push(cur); return { end: j + 1, parts } }
    if (c === '\n') break
    cur += c
    j++
  }
  parts.push(cur)
  return { end: j, parts }
}

/** src[i] === '(' : position après la parenthèse fermante (chaînes comprises). */
function skipParens(src, i) {
  let depth = 0
  let j = i
  while (j < src.length) {
    const c = src[j]
    if (c === '"') { j = readString(src, j).end; continue }
    if (c === '(') depth++
    else if (c === ')') { depth--; if (depth === 0) return j + 1 }
    j++
  }
  return j
}

const counts = new Map()
let calls = 0
for (const f of files) {
  const src = fs.readFileSync(f, 'utf8')
  // Appels au journal (logger., et self. dans AppLogger), et lignes écrites
  // directement (LogEntry : arrêt brutal, plantage).
  const re = /(?:logger|self\??)\.(?:info|success|warn|error|debug)\(|LogEntry\(/g
  let m
  while ((m = re.exec(src))) {
    calls++
    const open = m.index + m[0].length - 1
    const end = skipParens(src, open)
    // Chaînes des arguments ; la première (catégorie) est laissée.
    let j = open + 1
    let first = true
    let depth = 0
    while (j < end - 1) {
      const c = src[j]
      if (c === '"') {
        const s = readString(src, j)
        if (first && depth === 0) { first = false; j = s.end; continue }
        first = false
        for (const p of s.parts) {
          if (p === null) continue
          const t = p.trim()
          // Au moins 3 lettres, et pas un simple jeton technique (HTTP, GQL…).
          if ((t.match(/\p{L}/gu) || []).length < 3) continue
          if (/^[A-Z0-9_./:-]+$/.test(t)) continue
          counts.set(t, (counts.get(t) || 0) + 1)
        }
        j = s.end
        continue
      }
      if (c === '(') depth++
      else if (c === ')') depth--
      else if (c === ',' && depth === 0) first = false
      j++
    }
  }
}
const list = [...counts.entries()].sort((a, b) => a[0].localeCompare(b[0], 'fr')).map(([fr, n]) => ({ fr, n }))
fs.writeFileSync(outFile, JSON.stringify(list, null, 1))
console.log(`${calls} appels, ${list.length} morceaux distincts, ${list.reduce((s, x) => s + x.fr.length, 0)} caractères`)
