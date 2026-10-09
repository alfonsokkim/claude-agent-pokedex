#!/bin/zsh
# Sets up Claude Agent Pokédex on this Mac: downloads the sprites, builds
# Claude Pet.app into ~/Applications, installs the `claude-pet` command and
# `/pet` in Claude Code, adds the Claude Code hooks that report each session's
# status, then starts it. Safe to re-run, for example after pulling changes.
#
#   ./install.sh                 install or update
#   ./install.sh --remove-hooks  take the Claude Code hooks out
#   ./install.sh --uninstall     remove everything the installer added
set -e
here=${0:A:h}
app="$HOME/Applications/Claude Pet.app"
binary="$app/Contents/MacOS/ClaudePet"
settings="$HOME/.claude/settings.json"
data="$HOME/.local/share/claude-pet"

case "$1" in
  --remove-hooks)
    /usr/bin/osascript -l JavaScript "$here/hooks.js" "$settings" "$binary" remove
    exit
    ;;
  --uninstall)
    pkill -x ClaudePet 2>/dev/null || true
    /usr/bin/osascript -l JavaScript "$here/hooks.js" "$settings" "$binary" remove
    rm -rf "$app" "$data/sprites" "$data/sessions"
    rm -f ~/.local/bin/claude-pet ~/.claude/commands/pet.md
    defaults delete com.alfonsokim.claude-pet 2>/dev/null || true
    echo "Uninstalled. This folder is untouched; delete it yourself if you like."
    exit
    ;;
esac

if ! command -v swiftc >/dev/null; then
  echo "Building needs Xcode's command-line tools. Run: xcode-select --install"
  exit 1
fi

"$here/fetch-sprites.sh"
"$here/build.sh"

mkdir -p ~/.local/bin ~/.claude/commands
install -m 755 "$here/claude-pet" ~/.local/bin/claude-pet
sed "s|__HOME__|$HOME|g" "$here/pet.md" > ~/.claude/commands/pet.md

/usr/bin/osascript -l JavaScript "$here/hooks.js" "$settings" "$binary" add

pkill -x ClaudePet 2>/dev/null || true
open "$app"
echo "Done. Your pets will appear as Claude Code sessions report in."
echo "Toggle them with claude-pet in a terminal, or /pet in Claude Code."
