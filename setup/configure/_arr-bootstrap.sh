#!/usr/bin/env bash
# Shared bootstrap helpers for Sonarr + Radarr: root folder, qBit
# download client, Jellyfin Connect notification. Same idempotent
# upsert pattern as everything else — lookup by name/path, PUT if
# present, POST if new.
#
# Underscore-prefixed file at the configure/ root so the dispatcher
# skips it.

# Pass-through to the response-check helper that lives in
# _prowlarr-helpers.sh — sourced together from arr configure.sh.

# Upsert a root folder. Idempotent: GET /rootfolder first, skip if the
# target path is already there.
arr_upsert_root_folder() {
  local base_url="$1"
  local api_key="$2"
  local path="$3"

  local existing
  existing=$(curl -s -H "X-Api-Key: $api_key" \
    "$base_url/api/v3/rootfolder" \
    | jq -r --arg p "$path" '.[] | select(.path == $p) | .id' | head -1)

  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    return 0
  fi

  local resp
  resp=$(curl -s -w $'\n%{http_code}' -X POST \
    -H "X-Api-Key: $api_key" \
    -H "Content-Type: application/json" \
    -d "{\"path\": \"$path\"}" \
    "$base_url/api/v3/rootfolder")
  prowlarr_check_response "POST rootfolder $path" "$resp"
}

# Upsert qBittorrent as a download client. tvCategory/movieCategory
# differ between Sonarr and Radarr — caller passes the appropriate
# one. The other category field is still required by the schema, so
# we send the same value for both (qBit ignores the one that isn't
# its protocol's typical category).
#
# Args:
#   1: arr base URL
#   2: arr API key
#   3: qbit username
#   4: qbit password
#   5: category (e.g. "tv" or "movies")
arr_upsert_qbittorrent_client() {
  local base_url="$1"
  local api_key="$2"
  local qbit_user="$3"
  local qbit_pass="$4"
  local category="$5"

  local payload
  payload=$(cat <<EOF
{
  "name": "qBittorrent",
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": true,
  "removeFailedDownloads": true,
  "implementation": "QBittorrent",
  "implementationName": "qBittorrent",
  "configContract": "QBittorrentSettings",
  "fields": [
    {"name": "host", "value": "host.docker.internal"},
    {"name": "port", "value": 8080},
    {"name": "useSsl", "value": false},
    {"name": "urlBase", "value": ""},
    {"name": "username", "value": $(jq -Rn --arg v "$qbit_user" '$v')},
    {"name": "password", "value": $(jq -Rn --arg v "$qbit_pass" '$v')},
    {"name": "tvCategory", "value": "$category"},
    {"name": "movieCategory", "value": "$category"},
    {"name": "recentTvPriority", "value": 0},
    {"name": "olderTvPriority", "value": 0},
    {"name": "recentMoviePriority", "value": 0},
    {"name": "olderMoviePriority", "value": 0},
    {"name": "initialState", "value": 0}
  ],
  "tags": []
}
EOF
  )

  local existing_id
  existing_id=$(curl -s -H "X-Api-Key: $api_key" \
    "$base_url/api/v3/downloadclient" \
    | jq -r '.[] | select(.name == "qBittorrent") | .id' | head -1)

  local resp
  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    local with_id
    with_id=$(echo "$payload" | jq --arg id "$existing_id" '.id = ($id | tonumber)')
    resp=$(curl -s -w $'\n%{http_code}' -X PUT \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$with_id" \
      "$base_url/api/v3/downloadclient/${existing_id}")
    prowlarr_check_response "PUT downloadclient qBittorrent" "$resp"
  else
    resp=$(curl -s -w $'\n%{http_code}' -X POST \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$base_url/api/v3/downloadclient")
    prowlarr_check_response "POST downloadclient qBittorrent" "$resp"
  fi
}

# Upsert a Jellyfin Connect notification (Emby webhook). On every
# import/upgrade/rename, the arr fires a webhook that tells Jellyfin
# to refresh its library — without this Jellyfin's scheduled scan
# would lag the actual file landing by up to 12 hours.
#
# Args:
#   1: arr base URL
#   2: arr API key
#   3: Jellyfin API key (created by jellyfin bootstrap)
arr_upsert_jellyfin_notification() {
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
    prowlarr_check_response "PUT notification Jellyfin" "$resp"
  else
    resp=$(curl -s -w $'\n%{http_code}' -X POST \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$base_url/api/v3/notification")
    prowlarr_check_response "POST notification Jellyfin" "$resp"
  fi
}

# Returns the Jellyfin API key with AppName matching $1, or empty
# string if none. Used by Sonarr/Radarr to wire the Jellyfin
# notification — we created keys named "sonarr" and "aviary" during
# Jellyfin's bootstrap; this lets the arr configure.sh pick up the
# right one.
arr_lookup_jellyfin_api_key() {
  local app_name="$1"
  # Try the SQLite path first since it doesn't require auth round-
  # tripping.
  for db in \
    "$HOME/library/.config/jellyfin/data/data/jellyfin.db" \
    "$HOME/library/.config/jellyfin/data/jellyfin.db"
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
