#!/usr/bin/env bash
# Tests the release scripts (version.sh, appcast.sh and chrome-web-store.sh) in a throwaway repository, the last
# against a stand-in for curl. Needs git, xmllint, jq, openssl, zip and unzip.
#
#   scripts/test.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# check NAME EXPECTED ACTUAL
check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok    $1"
  else
    echo "FAIL  $1: expected '$2', got '$3'"
    failures=$((failures + 1))
  fi
}

git() {
  command git -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false \
    -c init.defaultBranch=main "$@"
}
commit() { git commit -q --allow-empty -m "$1"; }
project() { printf 'settings:\n  base:\n    MARKETING_VERSION: "%s"\n' "$1" >project.yml; }
version() { scripts/version.sh "$@" 2>/dev/null | tr '\n' ' ' || echo refused; }

# version.sh
repo="$work/repo"
mkdir -p "$repo/scripts"
cp "$root/scripts/version.sh" "$repo/scripts/"
cd "$repo"
git init -q
project 0.1.0
git add .
commit one
commit two
check "no tag yet" "version=0.1.0-beta.2 build=2 " "$(version beta)"

git tag v0.1.0
check "release at its tag" "version=0.1.0 build=2 " "$(version release v0.1.0)"
check "beta at a release tag" "version=0.1.1-beta.0 build=2 " "$(version beta)"

commit three
commit four
check "beta after a tag" "version=0.1.1-beta.2 build=4 " "$(version beta)"
check "release of a tag that is not HEAD" refused "$(version release v0.1.0)"
check "release of a missing tag" refused "$(version release v9.9.9)"
check "release of a malformed tag" refused "$(version release v1.02.3)"
check "no command" refused "$(version)"

project 0.3.0
git commit -qam "raise the version"
check "project.yml ahead of the tags" "version=0.3.0-beta.3 build=5 " "$(version beta)"

git checkout -q -b side
commit side
git tag v0.9.0
git checkout -q main
commit five
check "a tag outside HEAD's history" "version=0.3.0-beta.4 build=6 " "$(version beta)"

git tag v0.10.0
commit six
check "tags sort by number" "version=0.10.1-beta.1 build=7 " "$(version beta)"

project 1.0
git commit -qam "malformed version"
check "malformed MARKETING_VERSION" refused "$(version beta)"

git clone -q --depth 1 "file://$repo" "$work/shallow"
check "shallow clone" refused "$(cd "$work/shallow" && version beta)"

# appcast.sh
cd "$work"
appcast="$root/scripts/appcast.sh"
"$appcast" item --version 0.2.0-beta.4 --build 12 --length 100 --signature 'YmV0YQ==' --minimum-system 15.0 \
  --url https://github.com/sizumita/Plamonic/releases/download/beta/Plamonic-Beta.zip \
  --notes '<p>main の <a href="https://github.com/sizumita/Plamonic/commit/0123abc">0123abc</a> から</p>' >beta.xml
"$appcast" item --version 0.1.0 --build 10 --length 200 --signature 'c3RhYmxl' --minimum-system 15.0 \
  --url https://github.com/sizumita/Plamonic/releases/download/v0.1.0/Plamonic.zip >release.xml
"$appcast" feed "Plamonic" release.xml >stable-feed.xml
"$appcast" feed "Plamonic (beta)" beta.xml release.xml >beta-feed.xml

xpath() { xmllint --xpath "$1" "$2"; }
check "feed is well-formed" ok "$(xmllint --noout beta-feed.xml && echo ok)"
check "feed lists both items" 2 "$(xpath 'count(/rss/channel/item)' beta-feed.xml)"
check "build numbers" "1210" "$(xpath '/rss/channel/item/*[local-name()="version"]/text()' beta-feed.xml | tr -d '\n')"
check "notes stay HTML" '<p>main の <a href="https://github.com/sizumita/Plamonic/commit/0123abc">0123abc</a> から</p>' \
  "$(xpath 'string(/rss/channel/item[1]/description)' beta-feed.xml)"

"$appcast" items beta-feed.xml beta >beta-again.xml
"$appcast" items stable-feed.xml release >release-again.xml
"$appcast" feed "Plamonic (beta)" beta-again.xml release-again.xml >rebuilt.xml
check "items survive a round trip" "$(xpath '/rss/channel/item' beta-feed.xml)" "$(xpath '/rss/channel/item' rebuilt.xml)"

"$appcast" items stable-feed.xml beta >none.xml
check "no beta item in a stable feed" 0 "$(grep -c '<item>' none.xml || true)"
check "a feed needs an item" refused "$("$appcast" feed Plamonic none.xml 2>/dev/null || echo refused)"
check "an item needs a release version" refused \
  "$("$appcast" item --version 1.0 --build 1 --length 1 --signature eA== --minimum-system 15.0 \
    --url https://example.com/a.zip 2>/dev/null || echo refused)"

check "build of the beta" 12 "$("$appcast" build beta-feed.xml beta)"
check "build of the release" 10 "$("$appcast" build beta-feed.xml release)"
check "length of the beta" 100 "$("$appcast" length beta-feed.xml beta)"
check "length of the release" 200 "$("$appcast" length beta-feed.xml release)"
check "no beta build in a stable feed" "" "$("$appcast" build stable-feed.xml beta)"
check "a kind of item" refused "$("$appcast" build beta-feed.xml canary 2>/dev/null || echo refused)"
sed 's|<sparkle:version>12<|<sparkle:version>1x<|' beta-feed.xml >odd-build.xml
check "a build that is not a number" refused "$("$appcast" build odd-build.xml beta 2>/dev/null || echo refused)"

"$appcast" item --version 0.1.0 --build 10 --length 200 --signature 'c3RhYmxl' --minimum-system 15.0 \
  --url 'https://example.com/a.zip?a=1&b="<x>"' >odd.xml
"$appcast" feed 'Plamonic <"&">' odd.xml >odd-feed.xml
check "titles are escaped" 'Plamonic <"&">' "$(xpath 'string(/rss/channel/title)' odd-feed.xml)"
check "urls are escaped" 'https://example.com/a.zip?a=1&b="<x>"' "$(xpath 'string(//enclosure/@url)' odd-feed.xml)"

# chrome-web-store.sh, with a curl that answers from the files of $STORE and lists what was asked in $STORE/calls.
export STORE="$work/store"
mkdir -p "$STORE" "$work/bin" "$work/package"
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
out="" url=""
while (($#)); do
  case "$1" in
  -o) out="$2" && shift 2 ;;
  -w | -X | -H | -T | --data | --config) shift 2 ;;
  -*) shift ;;
  *) url="$1" && shift ;;
  esac
done
cat >/dev/null
name="${url##*[:/]}"
echo "$name" >>"$STORE/calls"
if [[ -f "$STORE/$name" ]]; then
  cat "$STORE/$name" >"$out"
  printf 200
else
  echo '{"error": "refused"}' >"$out"
  printf 403
fi
CURL
chmod +x "$work/bin/curl"

openssl genrsa -out "$work/key.pem" 2048 2>/dev/null
account="$(jq -n --rawfile key "$work/key.pem" '{client_email: "store@example.invalid", private_key: $key}')"
pack() { # pack NAME MANIFEST
  echo "$2" >"$work/package/manifest.json"
  rm -f "$work/$1.zip"
  (cd "$work/package" && zip -q "$work/$1.zip" manifest.json)
}
pack release '{"version": "0.2.0"}'
pack development '{"version": "0.2.0", "key": "MIIB"}'
pack beta '{"version": "0.2.0", "version_name": "0.2.0-beta.3"}'

# revisions PUBLISHED [SUBMITTED STATE]: the store's status.
revisions() {
  jq -n --arg published "$1" --arg submitted "${2:-}" --arg state "${3:-}" '
    def revision(version; state): {state: state, distributionChannels: [{deployPercentage: 100, crxVersion: version}]};
    (if $published == "" then {} else {publishedItemRevisionStatus: revision($published; "PUBLISHED")} end) +
    (if $submitted == "" then {} else {submittedItemRevisionStatus: revision($submitted; $state)} end)' \
    >"$STORE/fetchStatus"
}
# What the script asked the store for, then "refused" if it failed.
submit() { # submit [PACKAGE [VERSION]]
  : >"$STORE/calls"
  local result=""
  PATH="$work/bin:$PATH" CHROME_WEB_STORE_PUBLISHER=publisher CHROME_WEB_STORE_ITEM=abcdefghijklmnopabcdefghijklmnop \
    CHROME_WEB_STORE_SERVICE_ACCOUNT="$account" CHROME_WEB_STORE_POLL_SECONDS=0 \
    "$root/scripts/chrome-web-store.sh" "$work/${1:-release}.zip" "${2:-0.2.0}" >/dev/null 2>&1 || result=refused
  echo "$(tr '\n' ' ' <"$STORE/calls")$result"
}

echo '{"access_token": "token", "expires_in": 3600}' >"$STORE/token"
echo '{"uploadState": "SUCCEEDED", "crxVersion": "0.2.0"}' >"$STORE/upload"
echo '{"state": "PENDING_REVIEW"}' >"$STORE/publish"
echo '{}' >"$STORE/cancelSubmission"

revisions 0.1.0
check "a newer release is sent" "token fetchStatus upload publish " "$(submit)"
revisions ""
check "an item not published yet" "token fetchStatus upload publish " "$(submit)"
revisions 0.2.0
check "the published version is not sent again" "token fetchStatus " "$(submit)"
revisions 0.1.0 0.2.0 PENDING_REVIEW
check "the version in review is not sent again" "token fetchStatus " "$(submit)"
revisions 0.10.0
check "the store is never taken back" "token fetchStatus " "$(submit)"
revisions 0.1.0 0.3.0 PENDING_REVIEW
check "nor past a newer version in review" "token fetchStatus " "$(submit)"
revisions 0.1.0 0.1.5 PENDING_REVIEW
check "an older version in review is withdrawn" "token fetchStatus cancelSubmission upload publish " "$(submit)"
revisions 0.1.0 0.2.0 REJECTED
check "a rejected version is sent again" "token fetchStatus upload publish " "$(submit)"
revisions 0.1.0 0.2.0 CANCELLED
check "a withdrawn version is sent again" "token fetchStatus upload publish " "$(submit)"

revisions 0.1.0
jq '. + {lastAsyncUploadState: "SUCCEEDED"}' "$STORE/fetchStatus" >"$STORE/status" && mv "$STORE/status" "$STORE/fetchStatus"
echo '{"uploadState": "IN_PROGRESS"}' >"$STORE/upload"
check "an upload the store is still working on" "token fetchStatus upload fetchStatus publish " "$(submit)"
echo '{"uploadState": "FAILED"}' >"$STORE/upload"
check "a failed upload" "token fetchStatus upload refused" "$(submit)"
echo '{"uploadState": "SUCCEEDED", "crxVersion": "0.2.0"}' >"$STORE/upload"
echo '{"state": "REJECTED"}' >"$STORE/publish"
check "a submission the store does not take" "token fetchStatus upload publish refused" "$(submit)"
rm "$STORE/publish"
check "a call the store refuses" "token fetchStatus upload publish refused" "$(submit)"
echo '{"state": "PENDING_REVIEW"}' >"$STORE/publish"
jq '. + {takenDown: true}' "$STORE/fetchStatus" >"$STORE/status" && mv "$STORE/status" "$STORE/fetchStatus"
check "an item taken down" "token fetchStatus refused" "$(submit)"
revisions 0.1.0
echo '{"error": "invalid_grant"}' >"$STORE/token"
check "no access token" "token refused" "$(submit)"
echo '{"access_token": "token", "expires_in": 3600}' >"$STORE/token"

check "a package of another version" refused "$(submit release 0.3.0)"
check "a development build" refused "$(submit development)"
check "a beta" refused "$(submit beta 0.2.0-beta.3)"
account='{"type": "authorized_user"}'
check "a key that is not a service account's" refused "$(submit)"

if ((failures)); then
  echo "$failures failed"
  exit 1
fi
echo "All passed."
