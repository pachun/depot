#!/usr/bin/env bash
# Pull in the shared admin creds. Jellyfin's bootstrap-api block in
# configure.sh uses ADMIN_USERNAME + ADMIN_PASSWORD to drive the
# first-run wizard automatically.
HERE_PROMPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE_PROMPTS/../_admin-creds.sh"
