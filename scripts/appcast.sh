#!/usr/bin/env bash
# Writes the Sparkle feeds (appcasts) that Plamonic updates from (docs/DEVELOPMENT.md, "Updates"):
#
#   scripts/appcast.sh item --version 1.2.3 --build 42 --url URL --length BYTES --signature EDDSA \
#     --minimum-system 15.0 [--notes HTML] [--date "Thu, 06 Nov 2026 12:00:00 +0000"]
#       one <item> for an update archive
#   scripts/appcast.sh items FEED beta|release
#       the items of an existing feed whose archive is on the prerelease "beta", or on a release
#   scripts/appcast.sh feed TITLE ITEM_FILE...
#       a whole feed with the items of the files, in that order
#   scripts/appcast.sh build FEED beta|release
#   scripts/appcast.sh length FEED beta|release
#       the build number, or the archive's size in bytes, of the feed's first item of that kind, or an empty line
#
# Everything goes to standard output. Sparkle compares sparkle:version, the build number (CFBundleVersion), and shows
# sparkle:shortVersionString. Needs xmllint.
set -euo pipefail
# Bash 5.2 and later would read & in a ${s//pattern/replacement} replacement as the matched text.
shopt -u patsub_replacement 2>/dev/null || true

fail() {
  echo "appcast.sh: $*" >&2
  exit 1
}

# Text and attribute values.
escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
}

beta_path='/releases/download/beta/'

# The XPath predicate for the items whose archive is on the prerelease "beta", or on a release.
predicate() {
  case "$1" in
  beta) printf '%s' "contains(enclosure/@url, '$beta_path')" ;;
  release) printf '%s' "not(contains(enclosure/@url, '$beta_path'))" ;;
  *) fail "the kind of item is beta or release, not '$1'" ;;
  esac
}

item() {
  local version="" build="" url="" length="" signature="" minimum="" notes="" date=""
  while (($#)); do
    (($# >= 2)) || fail "$1 needs a value"
    case "$1" in
    --version) version="$2" ;;
    --build) build="$2" ;;
    --url) url="$2" ;;
    --length) length="$2" ;;
    --signature) signature="$2" ;;
    --minimum-system) minimum="$2" ;;
    --notes) notes="$2" ;;
    --date) date="$2" ;;
    *) fail "unknown option $1" ;;
    esac
    shift 2
  done
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]] || fail "bad --version '$version'"
  [[ "$build" =~ ^[1-9][0-9]*$ ]] || fail "bad --build '$build'"
  [[ "$url" =~ ^https?://[^[:space:]]+$ ]] || fail "bad --url '$url'"
  [[ "$length" =~ ^[1-9][0-9]*$ ]] || fail "bad --length '$length'"
  [[ "$signature" =~ ^[A-Za-z0-9+/]+=*$ ]] || fail "bad --signature '$signature'"
  [[ "$minimum" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "bad --minimum-system '$minimum'"
  [[ "$notes" != *"]]>"* ]] || fail "--notes cannot contain ]]>"
  [[ -n "$date" ]] || date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

  printf '    <item>\n'
  printf '      <title>Plamonic %s</title>\n' "$(escape "$version")"
  printf '      <pubDate>%s</pubDate>\n' "$(escape "$date")"
  printf '      <sparkle:version>%s</sparkle:version>\n' "$build"
  printf '      <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$version"
  printf '      <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>\n' "$minimum"
  if [[ -n "$notes" ]]; then
    printf '      <description><![CDATA[%s]]></description>\n' "$notes"
  fi
  printf '      <enclosure url="%s" length="%s" type="application/octet-stream" sparkle:edSignature="%s"/>\n' \
    "$(escape "$url")" "$length" "$signature"
  printf '    </item>\n'
}

items() {
  local feed="${1:-}" filter
  [[ -f "$feed" ]] || fail "no feed '$feed'"
  filter="$(predicate "${2:-}")"
  xmllint --noout "$feed" || fail "$feed is not well-formed"
  # xmllint exits with 10 when nothing matches.
  local status=0
  xmllint --xpath "/rss/channel/item[$filter]" "$feed" 2>/dev/null || status=$?
  ((status == 0 || status == 10)) || fail "cannot read the items of $feed"
  echo
}

# number FEED KIND XPATH: a number of the feed's first item of that kind, read with XPATH from the item.
number() {
  local feed="$1" filter value
  [[ -f "$feed" ]] || fail "no feed '$feed'"
  filter="$(predicate "$2")"
  xmllint --noout "$feed" || fail "$feed is not well-formed"
  value="$(xmllint --xpath "string((/rss/channel/item[$filter])[1]/$3)" "$feed")" || fail "cannot read $feed"
  [[ "$value" =~ ^([1-9][0-9]*)?$ ]] || fail "'$value' in $feed is not a number"
  printf '%s\n' "$value"
}

feed() {
  local title="${1:-}"
  [[ -n "$title" ]] || fail "feed needs a title"
  shift
  (($#)) || fail "feed needs at least one item file"
  local file
  for file in "$@"; do
    [[ -f "$file" ]] || fail "no item file '$file'"
  done
  local doc
  doc="$(
    printf '<?xml version="1.0" encoding="utf-8"?>\n'
    printf '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
    printf '  <channel>\n'
    printf '    <title>%s</title>\n' "$(escape "$title")"
    printf '    <link>https://github.com/%s</link>\n' "$(escape "${GITHUB_REPOSITORY:-sizumita/Plamonic}")"
    printf '    <language>ja</language>\n'
    cat "$@"
    printf '  </channel>\n'
    printf '</rss>\n'
  )"
  xmllint --noout - <<<"$doc" || fail "the feed is not well-formed"
  local count signed
  count="$(xmllint --xpath 'count(/rss/channel/item)' - <<<"$doc")"
  signed="$(xmllint --xpath 'count(/rss/channel/item[enclosure/@url and enclosure/@*[local-name()="edSignature"]])' - <<<"$doc")"
  ((count > 0)) || fail "the feed has no item"
  ((count == signed)) || fail "an item has no signed enclosure"
  printf '%s\n' "$doc"
}

command="${1:-}"
(($#)) && shift
case "$command" in
item) item "$@" ;;
items) items "$@" ;;
feed) feed "$@" ;;
build) number "${1:-}" "${2:-}" '*[local-name()="version"]' ;;
length) number "${1:-}" "${2:-}" 'enclosure/@length' ;;
*) fail "usage: scripts/appcast.sh item OPTIONS | items|build|length FEED beta|release | feed TITLE ITEM_FILE..." ;;
esac
