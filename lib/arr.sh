#!/usr/bin/env bash
# lib/arr.sh — Sonarr/Radarr/Prowlarr REST API helpers, sourced by
# install_depot for the multiple per-service blocks that all upsert
# config against the same arr-style API shape.
#
# Function naming: `arr_*` for things that work against any arr.
# Format JSON blobs are exported as ARR_FORMAT_* env vars so install
# blocks can reference them by name.

# Poll an arr's REST API until /system/status returns 2xx. Fresh starts
# take ~5-15s after `docker compose up -d`. Args:
#   1: base URL (e.g. "http://localhost:8989")
#   2: API version segment ("v1" for Prowlarr, "v3" for Sonarr/Radarr)
#   3: API key
arr_wait_for_api() {
  local base_url="$1" api_version="$2" api_key="$3"
  for _ in $(seq 1 30); do
    if curl -sf -H "X-Api-Key: $api_key" \
         "$base_url/api/$api_version/system/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "arr api did not come up after 30s: $base_url/api/$api_version" >&2
  return 1
}

# Takes a label and a curl response captured with `-w $'\n%{http_code}'`
# (last line = status, everything before = body). Prints a clear warning
# on non-2xx instead of letting it disappear into /dev/null. Returns
# non-zero on failure so callers can exit if they care.
arr_check_response() {
  local label="$1" resp="$2"
  local status="${resp##*$'\n'}" body="${resp%$'\n'*}"
  if [[ "$status" =~ ^2 ]]; then
    return 0
  fi
  echo "  WARN: ${label} returned HTTP ${status}"
  if [ -n "$body" ]; then
    echo "        ${body}" | head -c 500
    echo
  fi
  return 1
}

# Upsert a custom format by name.
#   1: base URL
#   2: api key
#   3: format name
#   4: full JSON payload (must include "name", "specifications", may omit "id")
arr_upsert_custom_format() {
  local base_url="$1" api_key="$2" name="$3" payload="$4"
  local existing_id
  existing_id=$(curl -s -H "X-Api-Key: $api_key" \
    "$base_url/api/v3/customformat" \
    | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -1)

  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    local with_id
    with_id=$(echo "$payload" | jq --arg id "$existing_id" '.id = ($id | tonumber)')
    curl -s -X PUT \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$with_id" \
      "$base_url/api/v3/customformat/$existing_id" >/dev/null
  else
    curl -s -X POST \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$base_url/api/v3/customformat" >/dev/null
  fi
}

# Fire a per-series rescan in Sonarr (or per-movie in Radarr) so the
# format-score and cutoff flags are recomputed against the current
# profile. Detects which arr by hitting /api/v3/series first — Sonarr
# returns a list, Radarr 404s. Async on the arr side; returns immediately.
arr_force_rescan() {
  local base_url="$1" api_key="$2"

  local series_ids
  series_ids=$(curl -s -H "X-Api-Key: $api_key" \
    "$base_url/api/v3/series" 2>/dev/null \
    | jq -r 'if type == "array" then .[].id else empty end' 2>/dev/null)

  if [ -n "$series_ids" ]; then
    for sid in $series_ids; do
      curl -s -X POST \
        -H "X-Api-Key: $api_key" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"RescanSeries\", \"seriesId\": $sid}" \
        "$base_url/api/v3/command" >/dev/null
    done
    return
  fi

  local movie_ids
  movie_ids=$(curl -s -H "X-Api-Key: $api_key" \
    "$base_url/api/v3/movie" 2>/dev/null \
    | jq -r 'if type == "array" then .[].id else empty end' 2>/dev/null)
  if [ -n "$movie_ids" ]; then
    for mid in $movie_ids; do
      curl -s -X POST \
        -H "X-Api-Key: $api_key" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"RescanMovie\", \"movieId\": $mid}" \
        "$base_url/api/v3/command" >/dev/null
    done
  fi
}

# Create the first admin user on an arr. Each exposes /initialize.json
# anonymous-accessible until the first admin exists; we POST creds
# there, set auth to Forms with local-address bypass.
# Idempotent: 409/404/401 from an already-set-up server treated as success.
arr_create_admin() {
  local base_url="$1" username="$2" password="$3" label="$4"

  local resp
  resp=$(curl -s -w $'\n%{http_code}' -X POST \
    --data-urlencode "username=$username" \
    --data-urlencode "password=$password" \
    --data-urlencode "passwordConfirmation=$password" \
    --data-urlencode "authenticationMethod=Forms" \
    --data-urlencode "authenticationRequired=DisabledForLocalAddresses" \
    "$base_url/initialize.json")

  local status="${resp##*$'\n'}"
  case "$status" in
    2*|409|404|401) return 0 ;;
    *)
      echo "  WARN: ${label} initialize.json returned HTTP ${status}"
      echo "        ${resp%$'\n'*}" | head -c 400
      echo
      return 1
      ;;
  esac
}

# Wire qBittorrent as a download client. Sonarr and Radarr both call
# this; tvCategory vs movieCategory differ. Both fields are required
# by the schema so we send the same value for both — qBit ignores
# whichever isn't its protocol's typical category.
#   1: arr base URL    2: arr API key
#   3: qbit user       4: qbit pass    5: category
arr_connect_to_qbit() {
  local base_url="$1" api_key="$2" qbit_user="$3" qbit_pass="$4" category="$5"

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
    arr_check_response "PUT downloadclient qBittorrent" "$resp"
  else
    resp=$(curl -s -w $'\n%{http_code}' -X POST \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$base_url/api/v3/downloadclient")
    arr_check_response "POST downloadclient qBittorrent" "$resp"
  fi
}

# Returns the Jellyfin API key with AppName matching $1, or empty if
# none. install_depot's install_jellyfin() creates keys named "sonarr"
# and "aviary"; each arr's install picks up the right one.
arr_lookup_jellyfin_api_key() {
  local app_name="$1"
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

# Wire Jellyfin as an arr's notification target. On every import,
# upgrade, or rename, the arr fires a webhook that tells Jellyfin to
# refresh its library. Without this, Jellyfin's scheduled scan lags
# the actual file landing by up to 12 hours.
arr_connect_to_jellyfin() {
  local base_url="$1" api_key="$2" jellyfin_api_key="$3"

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

# Tell an arr where to save finished media (the "root folder").
# Sonarr → /tv, Radarr → /movies. Idempotent.
arr_set_library_directory() {
  local base_url="$1" api_key="$2" path="$3"

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
  arr_check_response "POST rootfolder $path" "$resp"
}

# ============================================================
# Custom format payloads (opinions about which releases the arrs
# should reject at search time). All `required: true` so a single
# spec match qualifies the release.
# ============================================================

ARR_FORMAT_AUDIO_DESCRIPTION=$(cat <<'JSON'
{
  "name": "Audio Description",
  "includeCustomFormatWhenRenaming": false,
  "specifications": [
    {
      "name": "descriptive in title",
      "implementation": "ReleaseTitleSpecification",
      "negate": false,
      "required": true,
      "fields": [
        {"name": "value", "value": "\\b(descriptive|audio.{0,2}description|narration)\\b"}
      ]
    }
  ]
}
JSON
)

ARR_FORMAT_CAM_TS=$(cat <<'JSON'
{
  "name": "Theater Cam / Telesync / Screener",
  "includeCustomFormatWhenRenaming": false,
  "specifications": [
    {
      "name": "cam-rip indicators",
      "implementation": "ReleaseTitleSpecification",
      "negate": false,
      "required": true,
      "fields": [
        {"name": "value", "value": "\\b(CAM|HDCAM|HDTS|TELESYNC|TELECINE|HC[._\\-]?HDRip|SCREENER|DVDSCR|PDVD)\\b"}
      ]
    }
  ]
}
JSON
)

ARR_FORMAT_BAD_GROUPS=$(cat <<'JSON'
{
  "name": "Banned Release Groups",
  "includeCustomFormatWhenRenaming": false,
  "specifications": [
    {
      "name": "known low-quality groups",
      "implementation": "ReleaseGroupSpecification",
      "negate": false,
      "required": true,
      "fields": [
        {"name": "value", "value": "^(YIFY|YTS.*|KOGI|Kitsune|aXXo|mSD)$"}
      ]
    }
  ]
}
JSON
)

# HEVC/x265: browsers can't direct-stream, every play needs Jellyfin
# to transcode to h264, which is expensive even with QSV. Banning
# auto-grabs forces 1080p h264. User can still Interactive-Search
# override per-episode if no h264 alternative exists.
ARR_FORMAT_HEVC=$(cat <<'JSON'
{
  "name": "Codec: HEVC / x265",
  "includeCustomFormatWhenRenaming": false,
  "specifications": [
    {
      "name": "HEVC video codec",
      "implementation": "ReleaseTitleSpecification",
      "negate": false,
      "required": true,
      "fields": [
        {"name": "value", "value": "\\b(HEVC|H[._\\-]?265|x265)\\b"}
      ]
    }
  ]
}
JSON
)

# 2160p/4K: typically HEVC 10-bit + HDR/DV. Server-side transcoding to
# browser-playable h264 SDR is prohibitively heavy. Banning at auto-grab
# forces 1080p (which direct-streams or transcodes cleanly).
ARR_FORMAT_RES_2160P=$(cat <<'JSON'
{
  "name": "Resolution: 2160p / 4K",
  "includeCustomFormatWhenRenaming": false,
  "specifications": [
    {
      "name": "matches 2160p",
      "implementation": "ResolutionSpecification",
      "negate": false,
      "required": true,
      "fields": [
        {"name": "value", "value": 2160}
      ]
    }
  ]
}
JSON
)

# Apply policy to every quality profile on this arr:
#   - language = English (id=1)
#   - upgrades on
#   - minFormatScore=0 + cutoffFormatScore=0 (so -10000 banned formats
#     disqualify at search time and show up in Cutoff Unmet for upgrade)
#   - banned formats added with score -10000, missing ones appended
arr_apply_profile_policy() {
  local base_url="$1" api_key="$2"
  shift 2
  local ban_names=("$@")

  local bans_json
  bans_json=$(printf '%s\n' "${ban_names[@]}" | jq -R . | jq -s .)

  local cf_table
  cf_table=$(curl -s -H "X-Api-Key: $api_key" "$base_url/api/v3/customformat" \
    | jq --argjson bans "$bans_json" '
        [ .[] | {
            id: .id,
            name: .name,
            ban: (.name as $n | $bans | index($n) | . != null)
          } ]
      ')

  local profile_ids
  profile_ids=$(curl -s -H "X-Api-Key: $api_key" \
    "$base_url/api/v3/qualityprofile" | jq -r '.[].id')

  local pid
  for pid in $profile_ids; do
    local profile updated
    profile=$(curl -s -H "X-Api-Key: $api_key" \
      "$base_url/api/v3/qualityprofile/$pid")
    updated=$(echo "$profile" | jq --argjson cfs "$cf_table" '
      . as $doc
      | .language = {id: 1, name: "English"}
      | .upgradeAllowed = true
      | .minFormatScore = 0
      | .cutoffFormatScore = 0
      | .formatItems = (
          ($doc.formatItems // [])
          | map(
              . as $item
              | ($cfs | map(select(.id == $item.format))[0]) as $cf
              | if $cf.ban then $item + {score: -10000} else $item end
            )
          + (
              $cfs
              | map(select(.ban))
              | map(
                  select(
                    .id as $bid
                    | ($doc.formatItems // []) | any(.format == $bid) | not
                  )
                )
              | map({format: .id, name: .name, score: -10000})
            )
        )
    ')
    curl -s -X PUT \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$updated" \
      "$base_url/api/v3/qualityprofile/$pid" >/dev/null
  done

  # Sonarr/Radarr cache qualityCutoffNotMet at import time. A profile
  # change doesn't auto-recompute that flag — the next scheduled rescan
  # (~12h) eventually picks it up. Force a per-series/movie rescan so
  # the new scores propagate immediately.
  arr_force_rescan "$base_url" "$api_key"
}

# Convenience wrapper: apply every opinion in one call. Idempotent.
arr_opinionate_downloads() {
  local base_url="$1" api_key="$2"

  arr_wait_for_api "$base_url" "v3" "$api_key" || return 1

  arr_upsert_custom_format "$base_url" "$api_key" \
    "Audio Description" "$ARR_FORMAT_AUDIO_DESCRIPTION"
  arr_upsert_custom_format "$base_url" "$api_key" \
    "Theater Cam / Telesync / Screener" "$ARR_FORMAT_CAM_TS"
  arr_upsert_custom_format "$base_url" "$api_key" \
    "Banned Release Groups" "$ARR_FORMAT_BAD_GROUPS"
  arr_upsert_custom_format "$base_url" "$api_key" \
    "Resolution: 2160p / 4K" "$ARR_FORMAT_RES_2160P"
  arr_upsert_custom_format "$base_url" "$api_key" \
    "Codec: HEVC / x265" "$ARR_FORMAT_HEVC"

  arr_apply_profile_policy "$base_url" "$api_key" \
    "Audio Description" \
    "Theater Cam / Telesync / Screener" \
    "Banned Release Groups" \
    "Resolution: 2160p / 4K" \
    "Codec: HEVC / x265"
}
