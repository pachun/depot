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

# Returns 0 if Jellyfin is in a known-broken state: wizard claims
# complete, but no users exist. That combination is impossible by
# design — you can't finish the wizard without creating an admin —
# but Jellyfin 10.11's wizard has been observed to 2xx every endpoint
# (including /Startup/Complete) while silently failing to persist the
# admin user. From the API side there's no recovery: creating a user
# via /Users requires existing auth, which doesn't exist. The only
# way out is to wipe the on-disk state and re-run the wizard, which
# is what configure.sh's reset-and-reboot block does when this
# returns 0.
#
# Deliberately narrow: "wizard complete AND zero users" only. If the
# wizard's complete and there IS a user but login still fails, that's
# a credential mismatch (someone edited admin.env post-bootstrap, or
# changed the password in the UI) — surface as an error rather than
# silently wiping libraries.
jellyfin_in_zero_users_state() {
  local base_url="$1"
  local completed users
  completed=$(curl -sf "$base_url/System/Info/Public" 2>/dev/null \
    | jq -r '.StartupWizardCompleted // false')
  [ "$completed" = "true" ] || return 1
  users=$(curl -sf "$base_url/Users/Public" 2>/dev/null \
    | jq -r 'length' 2>/dev/null || echo 0)
  [ "$users" = "0" ]
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

  # Step 2: create the admin user.
  _jellyfin_wizard_post "Startup/User" \
    "$base_url/Startup/User" \
    "$(jq -nc --arg n "$username" --arg p "$password" '{Name:$n, Password:$p}')" \
    || return 1

  # Verify the admin was actually created before flipping the
  # "wizard complete" flag. /Startup/User has been observed to silently
  # accept POST requests (returning 2xx) without persisting the user on
  # Jellyfin 10.11 — leaving a wizard-done server with no admin once
  # /Startup/Complete runs. If we don't catch it here, the next thing
  # to fail is /Users/AuthenticateByName with a 401 whose body isn't
  # JSON and the script falls over in jq with a confusing message.
  local user_count
  user_count=$(curl -sf "$base_url/Users/Public" 2>/dev/null \
    | jq -r 'length' 2>/dev/null || echo 0)
  if [ "$user_count" = "0" ]; then
    echo "  ERROR: /Startup/User returned 2xx but no users exist." >&2
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
