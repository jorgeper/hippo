#!/usr/bin/env bash
# Guided Dropbox setup. Writes Config/Secrets.xcconfig (app key) and, optionally, .env (app key +
# refresh token for integration tests). Needs only bash, curl, openssl and python3.
# Never echoes the app key, the authorization code or any token; only first-4…last-4 masks.
set -euo pipefail
cd "$(dirname "$0")/.."

mask() { local v="$1"; printf '%s…%s' "${v:0:4}" "${v: -4}"; }

confirm_overwrite() {
  local file="$1" answer
  [ -e "$file" ] || return 0
  read -r -p "$file exists. Overwrite? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

cat <<'STEPS'
Dropbox app setup (about two minutes)

1. Open https://www.dropbox.com/developers/apps and choose "Create app".
2. Pick "Scoped access", then "App folder", and name the app "Hippo".
3. Permissions tab: tick files.content.write, files.content.read, files.metadata.read and
   account_info.read, then press Submit.
4. Settings tab: under "Redirect URIs" add   db-<APP KEY>://2/token   (use the App key shown
   on that tab in place of <APP KEY>) and press Add.

STEPS

read -r -s -p "Paste the App key (input is hidden): " APP_KEY
echo
if ! [[ "$APP_KEY" =~ ^[a-z0-9]{15}$ ]]; then
  echo "error: that does not look like a Dropbox app key (15 lowercase letters and digits)." >&2
  exit 1
fi

if confirm_overwrite Config/Secrets.xcconfig; then
  umask 077
  printf 'HIPPO_DROPBOX_APP_KEY = %s\n' "$APP_KEY" > Config/Secrets.xcconfig
  chmod 600 Config/Secrets.xcconfig
  echo "Wrote Config/Secrets.xcconfig: HIPPO_DROPBOX_APP_KEY = $(mask "$APP_KEY")"
else
  echo "Kept the existing Config/Secrets.xcconfig."
fi

echo
read -r -p "Also sign in once to create a refresh token for the integration tests? [y/N] " WANT_TOKEN
if [[ "$WANT_TOKEN" =~ ^[Yy]$ ]]; then
  VERIFIER="$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')"
  CHALLENGE="$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  echo
  echo "Open this URL, allow access, and copy the code Dropbox shows:"
  echo "https://www.dropbox.com/oauth2/authorize?client_id=${APP_KEY}&response_type=code&token_access_type=offline&code_challenge=${CHALLENGE}&code_challenge_method=S256"
  echo
  read -r -s -p "Paste the code (input is hidden): " CODE
  echo
  RESPONSE="$(curl -s https://api.dropboxapi.com/oauth2/token \
    --data-urlencode "code=${CODE}" \
    -d grant_type=authorization_code \
    --data-urlencode "code_verifier=${VERIFIER}" \
    --data-urlencode "client_id=${APP_KEY}")" || true
  REFRESH="$(printf '%s' "$RESPONSE" | python3 -I -c \
    'import json,sys
try:
    print(json.load(sys.stdin).get("refresh_token",""))
except Exception:
    print("")')"
  unset RESPONSE CODE VERIFIER
  if [ -z "$REFRESH" ]; then
    echo "error: Dropbox did not return a refresh token. Check the code and try again." >&2
    exit 1
  fi
  if confirm_overwrite .env; then
    umask 077
    printf 'HIPPO_DROPBOX_APP_KEY=%s\nHIPPO_DROPBOX_REFRESH_TOKEN=%s\n' "$APP_KEY" "$REFRESH" > .env
    chmod 600 .env
    echo "Wrote .env: HIPPO_DROPBOX_APP_KEY=$(mask "$APP_KEY"), HIPPO_DROPBOX_REFRESH_TOKEN=$(mask "$REFRESH")"
  else
    echo "Kept the existing .env."
  fi
fi

echo
echo "Done. Run: make generate"
