#!/usr/bin/env bash
# Shared helpers for Jellyfin's first-run bootstrap via REST API.
# Sourced from jellyfin/configure.sh after the container is up.
#
# Jellyfin's startup wizard endpoints accept anonymous calls during
# the initial setup window only — once StartupWizardCompleted flips
# to true on the system, those endpoints silently 404 (which is the
# right idempotency story: bootstrap-then-skip).
#
# All other endpoints require X-Emby-Token auth. We acquire one by
# logging in as ADMIN_USERNAME / ADMIN_PASSWORD via
# /Users/AuthenticateByName, then carry it through the bootstrap.
#
# Underscore-prefixed file at configure/ root so the dispatcher
# skips it (iterates configure/*/ only).

# Polls Jellyfin's public endpoint until it responds AND the container
# has finished its EF migrations. The second gate matters on Jellyfin
# 10.11+: new normalized-username migrations race the wizard endpoints
# at fresh-container startup, and POST /Startup/User silently 4xxs (no
# user is created) if it lands while the Users table is mid-rebuild.
# "Startup complete" in the container logs is Jellyfin's own signal
# that core init — including DB migrations — has finished.
jellyfin_wait_for_api() {
  local base_url="$1"
  for _ in $(seq 1 60); do
    if curl -sf "$base_url/System/Info/Public" >/dev/null 2>&1 \
       && docker logs jellyfin 2>&1 | grep -q 'Startup complete'; then
      return 0
    fi
    sleep 1
  done
  echo "  WARN: Jellyfin API didn't respond within 60s" >&2
  return 1
}

# POST to a wizard endpoint and assert 2xx. Wizard endpoints silently
# 4xx if a payload's schema is wrong, or while migrations are still
# settling — without this check, the script happily marches forward
# from a failed /Startup/User to a "successful" /Startup/Complete and
# leaves us with a wizard-done Jellyfin that has no admin user.
_jellyfin_wizard_post() {
  local label="$1"
  local url="$2"
  local body="${3:-}"
  local tmp code
  tmp=$(mktemp)
  if [ -n "$body" ]; then
    code=$(curl -s -o "$tmp" -w '%{http_code}' -X POST \
      -H "Content-Type: application/json" -d "$body" "$url")
  else
    code=$(curl -s -o "$tmp" -w '%{http_code}' -X POST "$url")
  fi
  if [[ ! "$code" =~ ^2 ]]; then
    echo "  ERROR: wizard step '$label' returned HTTP $code" >&2
    echo "         body: $(head -c 400 "$tmp")" >&2
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  return 0
}

# Returns 0 if Jellyfin still needs the startup wizard, non-zero if
# already done. Used to gate the wizard-driving block.
jellyfin_needs_bootstrap() {
  local base_url="$1"
  local info
  info=$(curl -s "$base_url/System/Info/Public")
  # StartupWizardCompleted exists in Jellyfin 10.8+
  local completed
  completed=$(echo "$info" | jq -r '.StartupWizardCompleted // false')
  [ "$completed" != "true" ]
}


# Drives the startup wizard: pick language, create admin, accept
# defaults, mark complete. Idempotent via jellyfin_needs_bootstrap.
jellyfin_run_startup_wizard() {
  local base_url="$1"
  local username="$2"
  local password="$3"

  # Step 1: server language (required to advance the wizard).
  _jellyfin_wizard_post "Startup/Configuration" \
    "$base_url/Startup/Configuration" \
    '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' \
    || return 1

  # Step 2a: GET /Startup/FirstUser before posting our real admin
  # creds. Jellyfin's UserManager lazily creates a placeholder user
  # named "abc" the first time anything queries the user list — and
  # POST /Startup/User is an UPDATE call, not a create. With zero
  # users in the DB it 404s because there's no first user to update.
  # The web-UI wizard hits this GET when it renders the user-creation
  # step; we have to do the same.
  if ! curl -sf "$base_url/Startup/FirstUser" >/dev/null; then
    echo "  ERROR: GET /Startup/FirstUser failed — couldn't trigger placeholder user creation" >&2
    return 1
  fi

  # Step 2b: update the placeholder to the real admin creds.
  _jellyfin_wizard_post "Startup/User" \
    "$base_url/Startup/User" \
    "$(jq -nc --arg n "$username" --arg p "$password" '{Name:$n, Password:$p}')" \
    || return 1

  # Verify the placeholder was actually renamed to our admin creds
  # before flipping the "wizard complete" flag. /Startup/User has been
  # observed to accept POST requests (returning 2xx) without persisting
  # the change on Jellyfin 10.11. GET /Startup/FirstUser tells us
  # directly what name the first user has — much more semantic than
  # checking /Users/Public, which hides the still-placeholder user
  # until /Startup/Complete fires.
  local first_user_name
  first_user_name=$(curl -sf "$base_url/Startup/FirstUser" 2>/dev/null \
    | jq -r '.Name // empty' 2>/dev/null)
  if [ "$first_user_name" != "$username" ]; then
    echo "  ERROR: POST /Startup/User returned 2xx but /Startup/FirstUser still" >&2
    echo "         reports '$first_user_name' — expected '$username'." >&2
    echo "         Aborting before /Startup/Complete to keep the wizard re-runnable." >&2
    return 1
  fi

  # Step 3: remote-access defaults (accept default; we're behind
  # tailscale anyway).
  _jellyfin_wizard_post "Startup/RemoteAccess" \
    "$base_url/Startup/RemoteAccess" \
    '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' \
    || return 1

  # Step 4: mark wizard complete.
  _jellyfin_wizard_post "Startup/Complete" \
    "$base_url/Startup/Complete" \
    || return 1
}

# Authenticate the admin user and echo the resulting AccessToken.
# Callers use that as X-Emby-Token for the rest of the bootstrap.
jellyfin_login() {
  local base_url="$1"
  local username="$2"
  local password="$3"

  curl -s -X POST \
    -H "Content-Type: application/json" \
    -H 'X-Emby-Authorization: MediaBrowser Client="depot", Device="depot-configure", DeviceId="depot-configure", Version="1.0"' \
    -d "$(jq -nc --arg n "$username" --arg p "$password" '{Username:$n, Pw:$p}')" \
    "$base_url/Users/AuthenticateByName" \
    | jq -r '.AccessToken // empty'
}

# Upsert a Library virtual folder. Idempotent by name lookup.
# Args:
#   1: base URL
#   2: token
#   3: library name ("Movies" or "Shows")
#   4: collection type ("movies" or "tvshows")
#   5: in-container path ("/media/movies" or "/media/tv")
jellyfin_upsert_library() {
  local base_url="$1"
  local token="$2"
  local name="$3"
  local coll_type="$4"
  local path="$5"

  local existing
  existing=$(curl -s -H "X-Emby-Token: $token" \
    "$base_url/Library/VirtualFolders" \
    | jq -r --arg n "$name" '.[] | select(.Name == $n) | .ItemId')

  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    return 0
  fi

  # LibraryOptions includes EnableRealtimeMonitor so the README's
  # manual "enable real-time monitoring" step is baked in from the
  # start.
  local lib_options
  lib_options=$(jq -nc '{
    EnableRealtimeMonitor: true,
    EnablePhotos: false,
    EnableChapterImageExtraction: false,
    ExtractChapterImagesDuringLibraryScan: false,
    EnableTrickplayImageExtraction: false,
    EnableInternetProviders: true,
    SaveLocalMetadata: true,
    EnableEmbeddedTitles: false,
    EnableEmbeddedEpisodeInfos: false,
    AutomaticRefreshIntervalDays: 30,
    PreferredMetadataLanguage: "en",
    MetadataCountryCode: "US",
    SeasonZeroDisplayName: "Specials",
    PathInfos: [{Path: $path}]
  }' --arg path "$path")

  curl -s -X POST -H "X-Emby-Token: $token" \
    "$base_url/Library/VirtualFolders?name=${name}&collectionType=${coll_type}&refreshLibrary=true" \
    -H "Content-Type: application/json" \
    -d "{\"LibraryOptions\": $lib_options, \"PathInfos\": [{\"Path\": \"$path\"}]}" \
    >/dev/null
}

# Upsert an API key. Returns the key string on stdout. Idempotent by
# app name — if a key with this app name already exists, returns the
# existing key.
jellyfin_upsert_api_key() {
  local base_url="$1"
  local token="$2"
  local app_name="$3"

  local existing
  existing=$(curl -s -H "X-Emby-Token: $token" \
    "$base_url/Auth/Keys" \
    | jq -r --arg n "$app_name" '.Items[] | select(.AppName == $n) | .AccessToken')

  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    echo "$existing"
    return 0
  fi

  curl -s -X POST -H "X-Emby-Token: $token" \
    "$base_url/Auth/Keys?app=$app_name" >/dev/null

  curl -s -H "X-Emby-Token: $token" \
    "$base_url/Auth/Keys" \
    | jq -r --arg n "$app_name" '.Items[] | select(.AppName == $n) | .AccessToken'
}
