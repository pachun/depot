#!/usr/bin/env bash
set -euo pipefail

jellyfin=http://localhost:8096
jellyfin_database="$HOME/hdds/.config/jellyfin/data/data/jellyfin.db"
aviary_database="$HOME/hdds/.config/aviary/data/aviary.db"
source "$HOME/hdds/.config/depot/demo-account.env"

key=$(sqlite3 "file:$jellyfin_database?mode=ro" "select AccessToken from ApiKeys where Name = 'aviary' limit 1;")

ask_jellyfin() {
  curl -sf -H "X-Emby-Token: $key" -H "Content-Type: application/json" "$@"
}

account_id=$(ask_jellyfin "$jellyfin/Users" | jq -r --arg name "$DEMO_USERNAME" '.[] | select(.Name == $name) | .Id')

restore_the_password() {
  ask_jellyfin -X POST "$jellyfin/Users/$account_id/Password" \
    -d "$(jq -n --arg password "$DEMO_PASSWORD" '{NewPw: $password, ResetPassword: false}')"
}

tmdb_ids_of_everything_on_the_server() {
  ask_jellyfin "$jellyfin/Items?Recursive=true&IncludeItemTypes=Movie,Series&Fields=ProviderIds" \
    | jq -r '.Items[].ProviderIds.Tmdb // empty'
}

put_in_the_library() {
  sqlite3 "$aviary_database" ".timeout 5000" \
    "insert or ignore into library_entries (jellyfin_user_id, tmdb_id, inserted_at) values ('$account_id', '$1', strftime('%Y-%m-%dT%H:%M:%S', 'now'));"
}

restore_the_password
tmdb_ids_of_everything_on_the_server | while read -r tmdb_id; do
  put_in_the_library "$tmdb_id"
done
