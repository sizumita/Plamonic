#!/usr/bin/env bash
# Sends a build of the Chrome extension to the Chrome Web Store and submits it for review, as the release workflow
# does for every release (docs/DEVELOPMENT.md, "Chrome Web Store"). The store publishes it once the review passes.
#
#   scripts/chrome-web-store.sh PACKAGE VERSION
#
# PACKAGE is a zip of BrowserExtension/dist/chrome, built without --dev and with --version=VERSION. The environment
# names the item and holds the key:
#
#   CHROME_WEB_STORE_PUBLISHER        the publisher ID (Developer Dashboard › Account)
#   CHROME_WEB_STORE_ITEM             the item's ID, which is also the extension's ID
#   CHROME_WEB_STORE_SERVICE_ACCOUNT  the JSON key of the service account that the publisher has linked
#
# It never takes the store back and never submits a version twice: when the store's published version, or the one in
# review, is this version or a newer one, it does nothing. An older version still in review is withdrawn first, since
# the store reviews one submission at a time. Needs curl, jq, openssl and unzip.
set -euo pipefail

fail() {
  echo "chrome-web-store.sh: $*" >&2
  exit 1
}

# A line in the log, and on the run's page when GitHub Actions runs this.
note() {
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    echo "::notice::$*"
  else
    echo "$*"
  fi
}

(($# == 2)) || fail "usage: scripts/chrome-web-store.sh PACKAGE VERSION"
package="$1"
version="$2"
[[ -f "${package}" ]] || fail "there is no package ${package}"
[[ "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  fail "the store takes a release, version X.Y.Z, not '${version}'"
for name in CHROME_WEB_STORE_PUBLISHER CHROME_WEB_STORE_ITEM CHROME_WEB_STORE_SERVICE_ACCOUNT; do
  [[ -n "${!name:-}" ]] || fail "${name} is not set"
done
[[ "${CHROME_WEB_STORE_ITEM}" =~ ^[a-p]{32}$ ]] ||
  fail "CHROME_WEB_STORE_ITEM is not an extension ID (32 letters from a to p)"

# The package is the release's build: the store would refuse a wrong version only after the upload, and takes a
# manifest key for a different item's ID as it is.
manifest="$(unzip -p "${package}" manifest.json 2>/dev/null)" || fail "${package} has no manifest.json at its top"
packed="$(jq -r '.version // empty' <<<"${manifest}")"
[[ "${packed}" == "${version}" ]] || fail "${package} is version '${packed}', not ${version}"
[[ "$(jq -r 'has("key")' <<<"${manifest}")" == false ]] ||
  fail "${package} is a development build (its manifest has a key): build it without --dev"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

base64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# An access token for the service account: a JWT signed with its key, exchanged at Google's token endpoint. The key
# and the tokens reach openssl and curl through pipes, never as arguments or files.
token_url="https://oauth2.googleapis.com/token"
email="$(jq -r '.client_email // empty' <<<"${CHROME_WEB_STORE_SERVICE_ACCOUNT}" 2>/dev/null)" || email=""
[[ -n "${email}" ]] || fail "CHROME_WEB_STORE_SERVICE_ACCOUNT is not a service account's JSON key"
claims="$(jq -cn --arg iss "${email}" --arg aud "${token_url}" --argjson iat "$(date +%s)" \
  '{iss: $iss, scope: "https://www.googleapis.com/auth/chromewebstore", aud: $aud, iat: $iat, exp: ($iat + 600)}')"
unsigned="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64url).$(printf '%s' "${claims}" | base64url)"
signature="$(printf '%s' "${unsigned}" |
  openssl dgst -sha256 -sign <(jq -r '.private_key // empty' <<<"${CHROME_WEB_STORE_SERVICE_ACCOUNT}") | base64url)" ||
  fail "the private key of CHROME_WEB_STORE_SERVICE_ACCOUNT does not sign"
status="$(printf 'grant_type=urn%%3Aietf%%3Aparams%%3Aoauth%%3Agrant-type%%3Ajwt-bearer&assertion=%s' \
  "${unsigned}.${signature}" | curl -sS -o "${work}/token" -w '%{http_code}' --data @- "${token_url}")" ||
  fail "Google's token endpoint did not answer"
token="$(jq -r '.access_token // empty' "${work}/token" 2>/dev/null)" || token=""
[[ "${status}" == 200 && -n "${token}" ]] ||
  fail "Google gave no access token for ${email} (HTTP ${status}): $(jq -c 'del(.access_token)' "${work}/token" 2>/dev/null || true)"

# api METHOD PATH [curl arguments]: calls the store as the service account and prints the answer.
item="publishers/${CHROME_WEB_STORE_PUBLISHER}/items/${CHROME_WEB_STORE_ITEM}"
api() {
  local method="$1" path="$2" status
  shift 2
  status="$(printf 'header = "Authorization: Bearer %s"\n' "${token}" |
    curl -sS -o "${work}/answer" -w '%{http_code}' -X "${method}" --config - "$@" \
      "https://chromewebstore.googleapis.com/${path}")" || fail "the store did not answer ${method} ${path}"
  [[ "${status}" == 2* ]] || fail "the store refused ${method} ${path} (HTTP ${status}): $(cat "${work}/answer")"
  cat "${work}/answer"
}

# The version of a revision in the store's status, or nothing.
revision() { jq -r --arg key "$1" '[.[$key].distributionChannels[]?.crxVersion] | first // empty' <<<"${state}"; }
# newer A B: A is a higher version than B.
newer() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -n 1)" == "$1" ]]
}

state="$(api GET "v2/${item}:fetchStatus")"
published="$(revision publishedItemRevisionStatus)"
submitted="$(revision submittedItemRevisionStatus)"
review="$(jq -r '.submittedItemRevisionStatus.state // empty' <<<"${state}")"
echo "The store has published '${published}' and its submission is '${submitted}' (${review:-none})."
if [[ "$(jq -r '.takenDown // false' <<<"${state}")" == true ]]; then
  fail "the store has taken the item down: see the Developer Dashboard"
fi

# A rejected or withdrawn submission is not in the store's way, and is sent again.
waiting=""
if [[ "${review}" == PENDING_REVIEW || "${review}" == STAGED ]]; then
  waiting="${submitted}"
fi
for has in "${published}" "${waiting}"; do
  [[ -n "${has}" ]] || continue
  if [[ "${has}" == "${version}" ]]; then
    note "The Chrome Web Store already has ${version}: nothing is sent."
    exit 0
  elif newer "${has}" "${version}"; then
    note "The Chrome Web Store already has ${has}, newer than ${version}: nothing is sent."
    exit 0
  fi
done

if [[ "${review}" == PENDING_REVIEW ]]; then
  echo "Withdrawing ${submitted}, still in review."
  api POST "v2/${item}:cancelSubmission" -H 'Content-Length: 0' >/dev/null
fi

upload="$(api POST "upload/v2/${item}:upload" -T "${package}")"
uploaded="$(jq -r '.uploadState // empty' <<<"${upload}")"
# The store may still be working on a large package.
for ((try = 0; try < 60; try++)); do
  [[ "${uploaded}" == IN_PROGRESS || "${uploaded}" == UPLOAD_IN_PROGRESS ]] || break
  sleep "${CHROME_WEB_STORE_POLL_SECONDS:-5}"
  uploaded="$(api GET "v2/${item}:fetchStatus" | jq -r '.lastAsyncUploadState // empty')"
done
[[ "${uploaded}" == SUCCEEDED ]] || fail "the store did not take the package (${uploaded:-no state}): ${upload}"
echo "Uploaded ${version}."

answer="$(api POST "v2/${item}:publish" -H 'Content-Length: 0')"
jq -r '.warningInfo.warnings[]? | "warning: \(.reason): \(.description)"' <<<"${answer}"
result="$(jq -r '.state // empty' <<<"${answer}")"
case "${result}" in
PENDING_REVIEW) note "Plamonic ${version} is in review at the Chrome Web Store, which publishes it when it passes." ;;
STAGED | PUBLISHED | PUBLISHED_TO_TESTERS) note "The Chrome Web Store took Plamonic ${version} (${result})." ;;
*) fail "the store did not take the submission (${result:-no state}): ${answer}" ;;
esac
