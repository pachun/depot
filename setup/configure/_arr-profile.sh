#!/usr/bin/env bash
# Shared opinionated profile configuration for Sonarr and Radarr.
# Sourced (not executed) from each arr's configure.sh after the
# container is up. Three things baked in here:
#
#   1. English-only language on every quality profile (so French/
#      Spanish/etc. releases get auto-rejected at search-result time).
#   2. A handful of `score: -10000` custom formats that effectively
#      ban release types the user never wants — Audio Description
#      tracks, theater cam-rips / telesyncs / screeners, and a small
#      set of well-known low-quality release groups (YTS/YIFY etc.).
#
# Underscore-prefixed file (and lives at the configure/ root, not
# inside a feature dir) so the top-level configure.sh dispatcher
# skips it — it iterates configure/*/ only.
#
# Idempotent: keyed by custom-format `name`, formats are upserted
# rather than re-created, and profile updates re-apply the same
# settings on every run.

# Polls the arr's REST API until it responds. Sonarr/Radarr take
# ~5-15s to come up even after `docker-compose up -d` reports the
# container running.
arr_wait_for_api() {
  local base_url="$1"
  local api_key="$2"
  local attempts=30

  for _ in $(seq 1 $attempts); do
    if curl -sf -H "X-Api-Key: $api_key" \
         "$base_url/api/v3/system/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "arr api did not come up after ${attempts}s: $base_url" >&2
  return 1
}

# Upsert a custom format by name. Args:
#   1: base URL (http://localhost:8989 etc.)
#   2: api key
#   3: format name (used as the lookup key)
#   4: full JSON payload — must include "name", "specifications", and
#      may omit "id" (we add it on PUT)
arr_upsert_custom_format() {
  local base_url="$1"
  local api_key="$2"
  local name="$3"
  local payload="$4"

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

# Apply our policy to every quality profile on this arr:
#   * language = English (id=1, same on Sonarr & Radarr)
#   * for each custom-format name in $3+, set the corresponding
#     formatItems entry's score to -10000 (effective ban: below
#     minFormatScore once we set it).
#   * if a banned format isn't yet in formatItems (fresh creation,
#     Sonarr hasn't backfilled), append it.
#   * minFormatScore = 0 so a -10000 score actually disqualifies.
arr_apply_profile_policy() {
  local base_url="$1"
  local api_key="$2"
  shift 2
  local ban_names=("$@")

  # Custom format id ⇄ name table, with a "ban" flag for names in our list.
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
      # Upgrades must be on. Without this Sonarr/Radarr ignore the
      # format-score cutoff entirely — a 1080p file with score -20000
      # is considered "complete" and never appears in Cutoff Unmet,
      # so the audit-and-replace flow we rely on can never fire.
      | .upgradeAllowed = true
      # minFormatScore=0 ensures a -10000 score actually disqualifies a
      # release at search time; cutoffFormatScore=0 ensures an existing
      # file with negative score shows up in Cutoff Unmet for
      # upgrading. Both at 0 by Sonarr default but explicit here for
      # clarity (and so depot owns the policy end-to-end).
      | .minFormatScore = 0
      | .cutoffFormatScore = 0
      | .formatItems = (
          # Bump banned formats already in the list to -10000.
          ($doc.formatItems // [])
          | map(
              . as $item
              | ($cfs | map(select(.id == $item.format))[0]) as $cf
              | if $cf.ban then $item + {score: -10000} else $item end
            )
          # Append banned formats not yet in the list. Bind $doc above
          # so this check sees the ORIGINAL items, not the iteration
          # element from $cfs (which has no .formatItems field).
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

  # Sonarr/Radarr cache qualityCutoffNotMet on each episode/movie
  # file at import time. A profile change here doesn't auto-recompute
  # that flag — the next scheduled rescan (~12h) eventually picks it
  # up, but Cutoff Unmet stays empty in the UI until then. Fire a
  # RescanSeries / RescanMovie command per series/movie now so the
  # new format scores propagate immediately.
  arr_force_rescan "$base_url" "$api_key"
}

# Fires a per-series rescan in Sonarr (or per-movie in Radarr) so
# the format-score and cutoff flags are recomputed against the
# current profile. Detects which arr by hitting /api/v3/series
# first — Sonarr returns a list, Radarr 404s. Async on the arr side;
# returns immediately.
arr_force_rescan() {
  local base_url="$1"
  local api_key="$2"

  # Try Sonarr-style first.
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

  # Otherwise try Radarr.
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

# The three opinionated custom-format JSON payloads. Defined here so
# both Sonarr's and Radarr's configure.sh can reference them by name.
# All three use `required: true` so the format matches when ANY
# specification matches (single-spec formats — same effect either way).

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

# HEVC / x265 / H.265 — modern, efficient codec but a non-starter for
# browser playback. Browsers can't direct-stream HEVC, so every play
# needs Jellyfin to transcode the file to h264. Even with hardware
# acceleration that's expensive; without it (QSV currently broken on
# framework-depot) it's effectively unplayable. Score -10000 to keep
# Sonarr/Radarr from auto-grabbing HEVC content — user can still
# Interactive-Search Override on a per-episode basis if no h264
# alternative exists for a specific show.
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

# 2160p / 4K UHD releases — typically HEVC 10-bit + HDR or Dolby
# Vision. Server-side transcoding to browser-playable h264 SDR is
# prohibitively heavy even with hardware acceleration, and most
# transcodes either fail to start or produce stuttering at low
# bitrate. Banning the resolution at the auto-grab stage forces
# 1080p (which direct-streams or transcodes cleanly), without
# touching the user's option to Interactive-Search override on a
# per-episode basis when they explicitly know what they want.
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

# Convenience wrapper called by each arr's configure.sh — does the
# whole opinionated bootstrap in one call. Idempotent end-to-end.
arr_apply_opinionated_policy() {
  local base_url="$1"
  local api_key="$2"

  arr_wait_for_api "$base_url" "$api_key" || return 1

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
