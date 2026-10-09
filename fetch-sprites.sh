#!/bin/zsh
# Downloads the Gen 3-style walking sprite sheets the pets use, from the
# pokeemerald-expansion project's follower sprites. Personal use only.
# Each sheet is one row of square frames: down ×2, up ×2, side ×2 (facing left).
# They go where the app looks for them, wherever this repo is cloned.
set -e
dir="$HOME/.local/share/claude-pet/sprites"
base=https://raw.githubusercontent.com/rh-hideout/pokeemerald-expansion/master/graphics/pokemon
mkdir -p "$dir"

for name in bulbasaur charmander squirtle pikachu oddish psyduck poliwag abra geodude \
  slowpoke gastly gengar cubone magikarp gyarados lapras ditto \
  eevee vaporeon jolteon flareon espeon umbreon leafeon glaceon sylveon \
  kabuto snorlax articuno zapdos moltres dragonite; do
  [[ -s "$dir/$name.png" ]] && continue
  curl -fsSL "$base/$name/overworld.png" -o "$dir/$name.png" || { rm -f "$dir/$name.png"; echo "missing: $name"; }
done

# FireRed's overworld item ball, where pets rest after 12 hours unused.
[[ -s "$dir/_pokeball.png" ]] || curl -fsSL \
  https://raw.githubusercontent.com/pret/pokefirered/master/graphics/object_events/pics/misc/item_ball.png \
  -o "$dir/_pokeball.png"

echo "$(ls "$dir" | grep -vc '^_') sprite sheets in $dir"
