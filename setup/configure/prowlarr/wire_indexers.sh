#!/usr/bin/env bash
# Wire indexers into Prowlarr — currently NZBGeek (Newznab-style
# Usenet indexer) and IPTorrents (private torrent tracker). Each
# function upserts by name: GET /indexer, PUT if present, POST if new.
# Idempotent on every layer.
#
# Sourced (not executed) from prowlarr/configure.sh. Lives next to
# its only caller per the "delete a folder, rest still works" rule.

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

  # appProfileId: Prowlarr's per-indexer "App Profile" assignment.
  # Required field — POSTing without it 400s with "App Profile Id must
  # be greater than 0". Prowlarr seeds id=1 ("Standard") on first
  # boot, which is what we want; resolve dynamically so a user who
  # renamed/reordered profiles in the UI still gets a valid id.
  local app_profile_id
  app_profile_id=$(curl -s -H "X-Api-Key: $api_key" \
    "${base_url}/api/v1/appprofile" \
    | jq -r 'sort_by(.id) | .[0].id // 1')

  # Usenet indexers MUST have redirect enabled (Prowlarr enforces this
  # in validation — newznab releases are NZB-file links the download
  # client needs to fetch via the indexer's redirect URL). Torrent
  # indexers can have either setting; we leave it true for symmetry.
  #
  # priority=10 (vs. Prowlarr's default 25): Sonarr/Radarr's release
  # picker uses indexer priority as the tiebreaker when two indexers
  # return same-scored releases — LOWER number = preferred (counter-
  # intuitive but that's the spec). Setting Newznab/Usenet indexers
  # to 10 and leaving the user's tracker at the UI default of 25 means
  # Usenet wins on ties → no ratio cost when both have the release,
  # tracker falls back when only it does.
  local payload
  payload=$(cat <<EOF
{
  "name": "$indexer_name",
  "enable": true,
  "redirect": true,
  "supportsRss": true,
  "supportsSearch": true,
  "supportsRedirect": true,
  "priority": 10,
  "downloadClientId": 0,
  "appProfileId": $app_profile_id,
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

  local resp
  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    local with_id
    with_id=$(echo "$payload" | jq --arg id "$existing_id" '.id = ($id | tonumber)')
    resp=$(curl -s -w $'\n%{http_code}' -X PUT \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$with_id" \
      "${base_url}/api/v1/indexer/${existing_id}")
    arr_check_response "PUT indexer $indexer_name" "$resp"
  else
    resp=$(curl -s -w $'\n%{http_code}' -X POST \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${base_url}/api/v1/indexer")
    arr_check_response "POST indexer $indexer_name" "$resp"
  fi
}

# Upsert IPTorrents as an indexer in Prowlarr. Same upsert-by-name
# pattern as Newznab, but with the IPTorrents implementation +
# cookie/UA auth fields that the user pasted in during prompts.sh.
#
# Args:
#   1: prowlarr base URL
#   2: prowlarr API key
#   3: IPT browser session cookie
#   4: IPT browser user-agent
prowlarr_register_iptorrents() {
  local base_url="$1"
  local api_key="$2"
  local ipt_cookie="$3"
  local ipt_useragent="$4"

  local app_profile_id
  app_profile_id=$(curl -s -H "X-Api-Key: $api_key" \
    "${base_url}/api/v1/appprofile" \
    | jq -r 'sort_by(.id) | .[0].id // 1')

  local categories='[2000,2010,2020,2030,2040,2045,2050,2060,5000,5010,5020,5030,5040,5045,5050,5060,5070,5080]'

  local payload
  payload=$(cat <<EOF
{
  "name": "IPTorrents",
  "enable": true,
  "redirect": false,
  "supportsRss": true,
  "supportsSearch": true,
  "supportsRedirect": false,
  "priority": 25,
  "downloadClientId": 0,
  "appProfileId": $app_profile_id,
  "implementation": "IPTorrents",
  "implementationName": "IPTorrents",
  "configContract": "IPTorrentsSettings",
  "protocol": "torrent",
  "privacy": "private",
  "fields": [
    {"name": "baseUrl", "value": "https://iptorrents.com"},
    {"name": "cookie", "value": $(jq -Rn --arg c "$ipt_cookie" '$c')},
    {"name": "userAgent", "value": $(jq -Rn --arg u "$ipt_useragent" '$u')},
    {"name": "categories", "value": $categories}
  ],
  "tags": []
}
EOF
  )

  local existing_id
  existing_id=$(curl -s -H "X-Api-Key: $api_key" \
    "${base_url}/api/v1/indexer" \
    | jq -r '.[] | select(.name=="IPTorrents") | .id' | head -1)

  local resp
  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    local with_id
    with_id=$(echo "$payload" | jq --arg id "$existing_id" '.id = ($id | tonumber)')
    resp=$(curl -s -w $'\n%{http_code}' -X PUT \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$with_id" \
      "${base_url}/api/v1/indexer/${existing_id}")
    arr_check_response "PUT indexer IPTorrents" "$resp"
  else
    resp=$(curl -s -w $'\n%{http_code}' -X POST \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${base_url}/api/v1/indexer")
    arr_check_response "POST indexer IPTorrents" "$resp"
  fi
}
