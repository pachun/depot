#!/usr/bin/env bash
# Shared HTTP plumbing for the *arr REST APIs (Sonarr v3, Radarr v3,
# Prowlarr v1). Every other helper in _shared/arr/ depends on these
# for the boring parts: polling until the service is up, generic
# upserts, response-code checking.
#
# Lives under _shared/arr/ — the dispatcher skips directories whose
# basename starts with `_`, so this file is library code, not a
# feature unit.

# Poll an arr's REST API until /system/status returns 2xx. Fresh
# starts take ~5-15s after `docker compose up -d` reports the
# container running. Args:
#   1: base URL (e.g. "http://localhost:8989")
#   2: API version segment ("v1" for Prowlarr, "v3" for Sonarr/Radarr)
#   3: API key
arr_wait_for_api() {
  local base_url="$1"
  local api_version="$2"
  local api_key="$3"
  local attempts=30

  for _ in $(seq 1 $attempts); do
    if curl -sf -H "X-Api-Key: $api_key" \
         "$base_url/api/$api_version/system/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "arr api did not come up after ${attempts}s: $base_url/api/$api_version" >&2
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

# Fire a per-series rescan in Sonarr (or per-movie in Radarr) so the
# format-score and cutoff flags are recomputed against the current
# profile. Detects which arr by hitting /api/v3/series first — Sonarr
# returns a list, Radarr 404s. Async on the arr side; returns
# immediately.
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

# Takes a label and a curl response that was captured with
# `-w $'\n%{http_code}'` (last line = status code, everything before =
# body). Prints a clear warning on non-2xx instead of letting the
# failure disappear into /dev/null. Returns non-zero on failure so a
# caller can exit if it cares, but most callers should let
# configure.sh continue.
arr_check_response() {
  local label="$1"
  local resp="$2"
  local status="${resp##*$'\n'}"
  local body="${resp%$'\n'*}"

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
