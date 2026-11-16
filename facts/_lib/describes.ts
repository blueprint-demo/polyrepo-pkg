// The version a component package describes: the latest released version of the unit it describes, read from the version
// file in that unit's directory. A release changes that file in the same commit as the release itself, so `describes` and
// the version actually released never need a second edit. The directory comes from the entry that calls describesOf; no
// release manifest or config is read here, and a check on the release side keeps the directory equal to the unit's path there.
import { existsSync, readFileSync } from 'node:fs'

const root = new URL('../../', import.meta.url)

// The version of a `[section]` key of a TOML file: only the plain `version = "x"` form of that table counts.
function tomlVersion(text: string, section: string): string | undefined {
  let current = ''
  for (const line of text.split(/\r?\n/)) {
    // an array table `[[x]]` leaves the current section, and its keys never belong to a plain `[section]`
    if (/^\s*\[\[[^\]]+\]\]\s*(?:#.*)?$/.test(line)) {
      current = ''
      continue
    }
    const header = /^\s*\[([^\]]+)\]\s*(?:#.*)?$/.exec(line)
    if (header !== null) {
      current = header[1]!.trim()
      continue
    }
    if (current !== section) continue
    const m = /^\s*version\s*=\s*["']([^"']+)["']\s*(?:#.*)?$/.exec(line)
    if (m !== null) return m[1]
  }
  return undefined
}

// Version files in the order they are tried: the files a release writes for the node, python, rust and simple release types.
const READERS: Array<[string, (text: string) => string | undefined]> = [
  ['package.json', (t) => (JSON.parse(t) as { version?: unknown }).version as string | undefined],
  // the release tooling reads [project] first and falls back to [tool.poetry]
  ['pyproject.toml', (t) => tomlVersion(t, 'project') ?? tomlVersion(t, 'tool.poetry')],
  ['Cargo.toml', (t) => tomlVersion(t, 'package')],
  ['version.txt', (t) => t.trim() || undefined],
]

/**
 * `describes` for the unit in `dir` (relative to the repository root): `{ [component]: <its version> }`.
 * A unit with no version file, or still at the 0.0.0 placeholder (not released yet), gives `{}`, the same as a
 * package that describes nothing.
 */
export function describesOf(component: string, dir: string): Record<string, string> {
  for (const [name, read] of READERS) {
    const file = new URL(`${dir.replace(/\/+$/, '')}/${name}`, root)
    if (!existsSync(file)) continue
    const version = read(readFileSync(file, 'utf8'))
    if (typeof version !== 'string' || version === '') continue
    return version === '0.0.0' ? {} : { [component]: version }
  }
  return {}
}
