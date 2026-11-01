#!/usr/bin/env bash
# Pubblica una release di Timonia e aggiorna source.json.
# Requisiti: gh (autenticato), jq, shasum.
set -euo pipefail

REPO="Marchisceddu/timonia-releases"

usage() {
  cat <<'EOF'
Uso: scripts/release.sh <versione> [opzioni]

Opzioni (facoltative):
  -i, --ipa <percorso>      File .ipa              (default: ~/Timonia-ipa/Timonia.ipa)
  -n, --notes <testo>       Note della versione    (default: "Rilascio versione <versione>")
  -m, --min-ios <versione>  iOS minimo             (default: 16.0)
  -b, --build <numero>      buildVersion in source.json (default: letto dall'.ipa)
      --prerelease          Segna la Release come pre-release (default: sì sotto la 1.0.0)
      --stable              Release normale, anche sotto la 1.0.0
      --no-push             Commit locale di source.json, senza push
  -y, --yes                 Non chiede conferma
      --dry-run             Mostra cosa farebbe, senza pubblicare nulla
  -h, --help                Mostra questo aiuto

Esempi:
  scripts/release.sh 0.2.0
  scripts/release.sh 0.2.0 -n "Corretto il saldo dei gruppi" -y
  scripts/release.sh 1.0.0 -i ~/Desktop/Timonia.ipa --stable --dry-run
EOF
}

die() { echo "$1" >&2; exit 1; }

VERSION=""
IPA="$HOME/Timonia-ipa/Timonia.ipa"
NOTES=""
MIN_IOS="16.0"
BUILD_OVERRIDE=""
PRERELEASE_MODE="auto"
PUSH=1
ASSUME_YES=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--ipa)      IPA="${2:?Manca il valore per $1}"; shift 2 ;;
    -n|--notes)    NOTES="${2:?Manca il valore per $1}"; shift 2 ;;
    -m|--min-ios)  MIN_IOS="${2:?Manca il valore per $1}"; shift 2 ;;
    -b|--build)    BUILD_OVERRIDE="${2:?Manca il valore per $1}"; shift 2 ;;
    --prerelease)  PRERELEASE_MODE="yes"; shift ;;
    --stable)      PRERELEASE_MODE="no"; shift ;;
    --no-push)     PUSH=0; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            usage >&2; die "Opzione sconosciuta: $1" ;;
    *)
      [ -z "$VERSION" ] || die "Argomento inatteso: $1 (la versione è già $VERSION)"
      VERSION="$1"; shift ;;
  esac
done

[ -n "$VERSION" ] || { usage >&2; exit 1; }
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "Versione non valida: $VERSION (formato atteso: 1.2.3)" ;;
esac

# Sotto la 1.0.0 la release è una beta, salvo --stable.
if [ "$PRERELEASE_MODE" = "auto" ]; then
  if [ "${VERSION%%.*}" -lt 1 ]; then PRERELEASE_MODE="yes"; else PRERELEASE_MODE="no"; fi
fi
PRERELEASE=()
DEFAULT_NOTES="Rilascio versione $VERSION"
if [ "$PRERELEASE_MODE" = "yes" ]; then
  PRERELEASE=(--prerelease)
  DEFAULT_NOTES="$DEFAULT_NOTES beta"
fi
NOTES="${NOTES:-$DEFAULT_NOTES}"

cd "$(dirname "$0")/.."

[ -f "$IPA" ] || die "IPA non trovato: $IPA"
[ -z "$(git status --porcelain)" ] || die "Working tree non pulito."

# La versione deve essere più alta della precedente, altrimenti SideStore non propone l'aggiornamento.
LATEST="$(jq -r '.apps[0].versions[0].version // "0.0.0"' source.json)"
if [ "$(printf '%s\n%s\n' "$LATEST" "$VERSION" | sort -V | tail -n1)" != "$VERSION" ] || [ "$LATEST" = "$VERSION" ]; then
  die "La versione $VERSION non è maggiore di $LATEST."
fi

# SideStore confronta buildVersion con il numero di build dentro l'.ipa (CFBundleVersion).
PLIST="Payload/Timonia.app/Info.plist"
IPA_BUILD="$(unzip -p "$IPA" "$PLIST" | plutil -extract CFBundleVersion raw -o - -)"
IPA_VERSION="$(unzip -p "$IPA" "$PLIST" | plutil -extract CFBundleShortVersionString raw -o - -)"
[ "$IPA_VERSION" = "$VERSION" ] || die "L'IPA contiene la versione $IPA_VERSION, non $VERSION."

BUILD="${BUILD_OVERRIDE:-$IPA_BUILD}"
if [ "$BUILD" != "$IPA_BUILD" ]; then
  echo "ATTENZIONE: buildVersion $BUILD diverso da quello nell'.ipa ($IPA_BUILD): SideStore rifiuterà l'installazione." >&2
fi

SIZE="$(stat -f%z "$IPA" 2>/dev/null || stat -c%s "$IPA")"
SHA="$(shasum -a 256 "$IPA" | cut -d' ' -f1)"
URL="https://github.com/$REPO/releases/download/v$VERSION/Timonia.ipa"

echo "Release da pubblicare"
echo "  versione      $VERSION (precedente: $LATEST)"
echo "  buildVersion  $BUILD (nell'.ipa: $IPA_BUILD)"
echo "  ipa           $IPA"
echo "  dimensione    $SIZE byte"
echo "  sha256        $SHA"
echo "  iOS minimo    $MIN_IOS"
echo "  pre-release   $PRERELEASE_MODE"
echo "  push          $([ "$PUSH" = 1 ] && echo sì || echo no)"
echo "  note          $NOTES"

if [ "$DRY_RUN" = 1 ]; then
  echo "Dry run: nessuna modifica effettuata."
  exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Procedo? [y/N] " ANSWER
  case "$ANSWER" in y|Y|s|S) ;; *) die "Annullato." ;; esac
fi

gh release create "v$VERSION" "$IPA" \
  ${PRERELEASE[@]+"${PRERELEASE[@]}"} \
  --repo "$REPO" \
  --title "$VERSION" \
  --notes "$NOTES"$'\n\n'"SHA-256: \`$SHA\`"

jq --arg v "$VERSION" --arg d "$(date +%F)" --argjson s "$SIZE" \
  --arg u "$URL" --arg n "$NOTES" --arg m "$MIN_IOS" --arg h "$SHA" --arg b "$BUILD" \
  '.apps[0].versions |= [{
    version: $v,
    buildVersion: $b,
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
if [ "$PUSH" = 1 ]; then
  git push
else
  echo "Push saltato: ricorda di eseguire 'git push'."
fi

echo "Release $VERSION pubblicata. SHA-256: $SHA"
