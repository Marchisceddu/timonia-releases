#!/usr/bin/env bash
# Pubblica una release di Timonia e aggiorna source.json.
# Uso: scripts/release.sh <versione> [percorso-ipa] [note]
# Requisiti: gh (autenticato), jq, shasum.
set -euo pipefail

REPO="Marchisceddu/timonia-releases"
VERSION="${1:?Uso: scripts/release.sh <versione> [percorso-ipa] [note]}"
IPA="${2:-$HOME/Timonia-ipa/Timonia.ipa}"
NOTES="${3:-Rilascio versione $VERSION}"
MIN_IOS="16.0"

cd "$(dirname "$0")/.."

[ -f "$IPA" ] || { echo "IPA non trovato: $IPA" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Working tree non pulito." >&2; exit 1; }

# La versione deve essere più alta della precedente, altrimenti SideStore non propone l'aggiornamento.
LATEST="$(jq -r '.apps[0].versions[0].version // "0.0.0"' source.json)"
if [ "$(printf '%s\n%s\n' "$LATEST" "$VERSION" | sort -V | tail -n1)" != "$VERSION" ] || [ "$LATEST" = "$VERSION" ]; then
  echo "La versione $VERSION non è maggiore di $LATEST." >&2
  exit 1
fi

SIZE="$(stat -f%z "$IPA" 2>/dev/null || stat -c%s "$IPA")"
SHA="$(shasum -a 256 "$IPA" | cut -d' ' -f1)"
URL="https://github.com/$REPO/releases/download/v$VERSION/Timonia.ipa"

gh release create "v$VERSION" "$IPA" \
  --repo "$REPO" \
  --title "$VERSION" \
  --notes "$NOTES"$'\n\n'"SHA-256: \`$SHA\`"

jq --arg v "$VERSION" --arg d "$(date +%F)" --argjson s "$SIZE" \
  --arg u "$URL" --arg n "$NOTES" --arg m "$MIN_IOS" --arg h "$SHA" \
  '.apps[0].versions |= [{
    version: $v,
    buildVersion: $v,
    date: $d,
    size: $s,
    sha256: $h,
    minOSVersion: $m,
    downloadURL: $u,
    localizedDescription: $n
  }] + .' source.json > source.tmp.json
mv source.tmp.json source.json

git add source.json
git commit -m "release $VERSION"
git push

echo "Release $VERSION pubblicata. SHA-256: $SHA"
