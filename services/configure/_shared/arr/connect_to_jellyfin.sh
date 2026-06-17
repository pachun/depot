#!/usr/bin/env bash
# Wire up Jellyfin as an *arr's notification target — on every import,
# upgrade, or rename, the arr fires a webhook that tells Jellyfin to
# refresh its library. Without this Jellyfin's scheduled scan would
# lag the actual file landing by up to 12 hours.
#
# Two functions here because they're coupled:
#   * arr_lookup_jellyfin_api_key — reads the Jellyfin SQLite DB for
#     the named API key (created during Jellyfin's bootstrap).
#   * arr_connect_to_jellyfin   — POSTs/PUTs the notification config
#     using that API key.
# Each arr's configure.sh calls them in sequence: look up the key,
# then connect.
#
# Idempotent: looks up "Jellyfin" by name in /notification, PUTs to
# update, POSTs to create.
#
# Lives under _shared/arr/ — the dispatcher skips directories whose
# basename starts with `_`, so this file is library code, not a
# feature unit.

# Returns the Jellyfin API key with AppName matching $1, or empty
# string if none. We created keys named "sonarr" and "aviary" during
# Jellyfin's bootstrap; this lets each arr's configure.sh pick up the
# right one.
arr_lookup_jellyfin_api_key() {
  local app_name="$1"
  # Try the SQLite path first since it doesn't require auth round-
  # tripping.
  for db in \
    "$HOME/hdds/.config/jellyfin/data/data/jellyfin.db" \
    "$HOME/hdds/.config/jellyfin/data/jellyfin.db"
  do
    if [ -s "$db" ]; then
      local key
      key=$(sqlite3 "$db" \
        "SELECT AccessToken FROM ApiKeys WHERE Name = '$app_name' LIMIT 1;" 2>/dev/null)
      if [ -n "$key" ]; then
        echo "$key"
        return 0
      fi
    fi
  done
}

# Args:
#   1: arr base URL
#   2: arr API key
#   3: Jellyfin API key (from arr_lookup_jellyfin_api_key)
arr_connect_to_jellyfin() {
  local base_url="$1"
  local api_key="$2"
  local jellyfin_api_key="$3"

  local payload
  payload=$(cat <<EOF
{
  "name": "Jellyfin",
  "onGrab": false,
  "onDownload": true,
  "onUpgrade": true,
  "onRename": true,
  "onSeriesDelete": false,
  "onEpisodeFileDelete": false,
  "onEpisodeFileDeleteForUpgrade": false,
  "onMovieDelete": false,
  "onMovieFileDelete": false,
  "onMovieFileDeleteForUpgrade": false,
  "onHealthIssue": false,
  "onApplicationUpdate": false,
  "supportsOnGrab": false,
  "supportsOnDownload": true,
  "supportsOnUpgrade": true,
  "supportsOnRename": true,
  "supportsOnSeriesDelete": false,
  "supportsOnEpisodeFileDelete": false,
  "supportsOnEpisodeFileDeleteForUpgrade": false,
  "supportsOnMovieDelete": false,
  "supportsOnMovieFileDelete": false,
  "supportsOnMovieFileDeleteForUpgrade": false,
  "supportsOnHealthIssue": false,
  "supportsOnApplicationUpdate": false,
  "includeHealthWarnings": false,
  "implementation": "MediaBrowser",
  "implementationName": "Emby",
  "configContract": "MediaBrowserSettings",
  "fields": [
    {"name": "host", "value": "host.docker.internal"},
    {"name": "port", "value": 8096},
    {"name": "useSsl", "value": false},
    {"name": "apiKey", "value": "$jellyfin_api_key"},
    {"name": "updateLibrary", "value": true}
  ],
  "tags": []
}
EOF
  )

  local existing_id
  existing_id=$(curl -s -H "X-Api-Key: $api_key" \
    "$base_url/api/v3/notification" \
    | jq -r '.[] | select(.name == "Jellyfin") | .id' | head -1)

  local resp
  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    local with_id
    with_id=$(echo "$payload" | jq --arg id "$existing_id" '.id = ($id | tonumber)')
    resp=$(curl -s -w $'\n%{http_code}' -X PUT \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$with_id" \
      "$base_url/api/v3/notification/${existing_id}")
    arr_check_response "PUT notification Jellyfin" "$resp"
  else
    resp=$(curl -s -w $'\n%{http_code}' -X POST \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$base_url/api/v3/notification")
    arr_check_response "POST notification Jellyfin" "$resp"
  fi
}
