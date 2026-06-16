#!/usr/bin/env bash
# Shared helpers for the Prowlarr REST API — registering Newznab
# indexers and the Sonarr/Radarr Applications that consume them.
# Sourced (not executed) from prowlarr/configure.sh.
#
# All three operations idempotent: lookup by name, PUT if present,
# POST if not.
#
# Underscore-prefixed file at the configure/ root so the dispatcher
# skips it (it iterates configure/*/ only).

# Polls Prowlarr's API until it responds. Fresh installs need ~5-10s
# after container start before /api/v1/system/status is up.
prowlarr_wait_for_api() {
  local base_url="$1"
  local api_key="$2"
  local attempts=30

  for _ in $(seq 1 $attempts); do
    if curl -sf -H "X-Api-Key: $api_key" \
         "$base_url/api/v1/system/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "prowlarr api did not come up after ${attempts}s" >&2
  return 1
}

# Upsert a Newznab indexer in Prowlarr.
# Args:
#   1: prowlarr base URL (e.g. "http://localhost:9696")
#   2: prowlarr API key
#   3: indexer name (e.g. "NZBGeek")
#   4: indexer base URL (e.g. "https://api.nzbgeek.info")
#   5: indexer API key
prowlarr_register_newznab() {
  local base_url="$1"
  local api_key="$2"
  local indexer_name="$3"
  local indexer_url="$4"
  local indexer_api_key="$5"

  # Categories: 2000-2090 = Movies subcategories, 5000-5090 = TV
  # subcategories. Standard Newznab numbering. Sending the full range
  # tells Prowlarr "use this indexer for both TV and movies."
  local categories='[2000,2010,2020,2030,2040,2045,2050,2060,5000,5010,5020,5030,5040,5045,5050,5060,5070,5080]'

  local payload
  payload=$(cat <<EOF
{
  "name": "$indexer_name",
  "enable": true,
  "redirect": false,
  "supportsRss": true,
  "supportsSearch": true,
  "supportsRedirect": false,
  "priority": 25,
  "downloadClientId": 0,
  "implementation": "Newznab",
  "implementationName": "Newznab",
  "configContract": "NewznabSettings",
  "protocol": "usenet",
  "privacy": "private",
  "fields": [
    {"name": "baseUrl", "value": "$indexer_url"},
    {"name": "apiPath", "value": "/api"},
    {"name": "apiKey", "value": "$indexer_api_key"},
    {"name": "categories", "value": $categories}
  ],
  "tags": []
}
EOF
  )

  local existing_id
  existing_id=$(curl -s -H "X-Api-Key: $api_key" \
    "${base_url}/api/v1/indexer" \
    | jq -r --arg n "$indexer_name" '.[] | select(.name==$n) | .id' | head -1)

  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    local with_id
    with_id=$(echo "$payload" | jq --arg id "$existing_id" '.id = ($id | tonumber)')
    curl -s -X PUT \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$with_id" \
      "${base_url}/api/v1/indexer/${existing_id}" >/dev/null
  else
    curl -s -X POST \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${base_url}/api/v1/indexer" >/dev/null
  fi
}

# Upsert a Sonarr-or-Radarr Application in Prowlarr. The Application
# bridge is what makes Prowlarr push indexer config TO the arrs —
# without it the arrs never learn what Prowlarr knows.
# Args:
#   1: prowlarr base URL
#   2: prowlarr API key
#   3: implementation ("Sonarr" or "Radarr")
#   4: arr base URL the arr reaches itself at (from inside docker
#      bridge, so "http://host.docker.internal:8989" etc.)
#   5: arr API key
prowlarr_register_application() {
  local base_url="$1"
  local api_key="$2"
  local impl="$3"
  local arr_url="$4"
  local arr_api_key="$5"

  # Category sets per arr — Newznab numbering. fullSync makes
  # Prowlarr keep the arr in sync as indexers are added/removed in
  # Prowlarr, rather than a one-shot push.
  local sync_categories
  case "$impl" in
    Sonarr)
      sync_categories='[5000,5010,5020,5030,5040,5045,5050,5060,5070,5080]'
      ;;
    Radarr)
      sync_categories='[2000,2010,2020,2030,2040,2045,2050,2060]'
      ;;
    *)
      echo "prowlarr_register_application: unknown impl '$impl'" >&2
      return 1
      ;;
  esac

  # prowlarrUrl is what the ARR will call back to Prowlarr at when it
  # needs an indexer search. host.docker.internal because the arr is
  # in a container reaching Prowlarr's host-published 9696 port.
  local payload
  payload=$(cat <<EOF
{
  "name": "$impl",
  "syncLevel": "fullSync",
  "implementation": "$impl",
  "implementationName": "$impl",
  "configContract": "${impl}Settings",
  "fields": [
    {"name": "prowlarrUrl", "value": "http://host.docker.internal:9696"},
    {"name": "baseUrl", "value": "$arr_url"},
    {"name": "apiKey", "value": "$arr_api_key"},
    {"name": "syncCategories", "value": $sync_categories}
  ],
  "tags": []
}
EOF
  )

  local existing_id
  existing_id=$(curl -s -H "X-Api-Key: $api_key" \
    "${base_url}/api/v1/applications" \
    | jq -r --arg n "$impl" '.[] | select(.name==$n) | .id' | head -1)

  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    local with_id
    with_id=$(echo "$payload" | jq --arg id "$existing_id" '.id = ($id | tonumber)')
    curl -s -X PUT \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$with_id" \
      "${base_url}/api/v1/applications/${existing_id}" >/dev/null
  else
    curl -s -X POST \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${base_url}/api/v1/applications" >/dev/null
  fi
}
