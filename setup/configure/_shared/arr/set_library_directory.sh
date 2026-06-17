#!/usr/bin/env bash
# Tell an *arr where to save finished media — the "root folder" in
# arr-speak. This is the path the arr considers its library; finished
# downloads are imported here from wherever the download client dropped
# them. Sonarr → /tv (host ~/hdds/media/tv), Radarr → /movies (host
# ~/hdds/media/movies). The path is the container-side mount point;
# see each arr's docker-compose.yml for the host mapping.
#
# Idempotent: GETs /rootfolder first, no-ops if the target path is
# already present.
#
# Lives under _shared/arr/ — the dispatcher skips directories whose
# basename starts with `_`, so this file is library code, not a
# feature unit.

# Args:
#   1: arr base URL (e.g. "http://localhost:8989")
#   2: arr API key
#   3: library path (e.g. "/library/tv")
arr_set_library_directory() {
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
  arr_check_response "POST rootfolder $path" "$resp"
}
