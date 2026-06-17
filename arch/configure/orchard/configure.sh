#!/usr/bin/env bash
# Pull orchard and install its CLI subset (zsh + .zshrc.d/cli/, nvim
# with pre-warmed plugins, tmux, mise, claude, git config, etc.) so
# this machine has the same shell tooling as my desktop without
# dragging in the graphical environment. Orchard's install.sh is
# itself idempotent — re-runs pick up upstream changes via git pull
# and the feature scripts no-op once their state is in place.
set -euo pipefail

ORCHARD=~/code/orchard
if [ -d "$ORCHARD/.git" ]; then
  git -C "$ORCHARD" pull
else
  mkdir -p ~/code
  # HTTPS clone so this works on a fresh machine before any SSH key has
  # been generated and added to GitHub. After install.sh has run once,
  # you can switch the remote to SSH manually if you want push access:
  #   git -C ~/code/orchard remote set-url origin git@github.com:pachun/orchard.git
  git clone https://github.com/pachun/orchard.git "$ORCHARD"
fi

bash "$ORCHARD/setup/install.sh" cli
