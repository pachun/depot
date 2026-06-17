#!/usr/bin/env bash
# Tell Prowlarr about Sonarr and Radarr — Prowlarr's "Applications"
# bridge is what makes it push indexer config TO the arrs. Without
# this, the arrs never learn what Prowlarr knows; they just sit
# there with no indexers configured.
#
# Idempotent: upsert by name (Sonarr / Radarr), PUT if present,
# POST if new.
#
# Sourced (not executed) from prowlarr/configure.sh. Lives next to
# its only caller per the "delete a folder, rest still works" rule.

# Args:
#   1: prowlarr base URL
#   2: prowlarr API key
#   3: implementation ("Sonarr" or "Radarr")
#   4: arr base URL that Prowlarr reaches the arr at (from inside
#      docker bridge, so "http://host.docker.internal:8989" etc.)
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

  local resp
  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    local with_id
    with_id=$(echo "$payload" | jq --arg id "$existing_id" '.id = ($id | tonumber)')
    resp=$(curl -s -w $'\n%{http_code}' -X PUT \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$with_id" \
      "${base_url}/api/v1/applications/${existing_id}")
    arr_check_response "PUT application $impl" "$resp"
  else
    resp=$(curl -s -w $'\n%{http_code}' -X POST \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${base_url}/api/v1/applications")
    arr_check_response "POST application $impl" "$resp"
  fi
}
