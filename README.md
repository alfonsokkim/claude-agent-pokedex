# Claude Agent Pokédex

A pixel Pokemon for every Claude Code session you have running, on a Mac or a
Windows PC. They float at the edge of your screen and act out what their agent
is doing, so you can tell at a glance which one is working, which one is
waiting on you, and which one just finished.

![Four pets in the corner of the screen while Claude Code works](docs/desktop.jpg)

| Agent | Pet |
| --- | --- |
| Working | Paces back and forth over a row of dots |
| Needs you (a permission prompt or a question) | Hops and flashes red, like it's taking hits |
| Finished | Jumps for joy over "*Pikachu* is done" until you look at it |
| Idle | Steps in place, then falls asleep with z's drifting up |
| Untouched for 12 hours | Goes back into its Poke Ball |

Each session gets its own Pokemon and keeps it. There are 32 to choose from,
including the starters, Pikachu, Gengar, Snorlax, every Eevee evolution, the
legendary birds and Dragonite.

## Download

| | |
| --- | --- |
| **Mac** (macOS 14 or later) | [claude-agent-pokedex-mac.zip](https://github.com/alfonsokkim/claude-agent-pokedex/releases/latest/download/claude-agent-pokedex-mac.zip) |
| **Windows** (Windows 10 or 11, 64-bit) | [claude-agent-pokedex-windows.zip](https://github.com/alfonsokkim/claude-agent-pokedex/releases/latest/download/claude-agent-pokedex-windows.zip) |

Both need [Claude Code](https://claude.com/claude-code).

## Install on a Mac

The Mac app is built on your machine, so you need Xcode's command-line tools:
`xcode-select --install`.

Unzip the download, then in Terminal:

```bash
cd ~/Downloads/claude-agent-pokedex-mac
zsh install.sh
```

Or with git:

```bash
git clone https://github.com/alfonsokkim/claude-agent-pokedex.git
cd claude-agent-pokedex
./install.sh
```

The installer:

1. downloads the sprites (they aren't shipped here, see [Sprites](#sprites))
2. builds `Claude Pet.app` into `~/Applications`
3. adds a `claude-pet` command and a `/pet` command for Claude Code
4. adds a set of hooks to `~/.claude/settings.json` so each session can report
   its status, leaving your other settings exactly as they were
5. starts the app

Run it again any time, for example after a `git pull`. To start the pets when
you log in, add **Claude Pet** under System Settings → General → Login Items.

## Install on Windows

Heads up: I lowkey haven't tested the Windows version yet, so if it's cooked,
just let me know by [opening an issue](https://github.com/alfonsokkim/claude-agent-pokedex/issues) :)

1. Unzip the download.
2. Double-click **install.cmd**.
3. Windows may warn that it "protected your PC", because the app isn't signed.
   Click **More info**, then **Run anyway**.

The installer copies the app to `%LOCALAPPDATA%\ClaudePet`, downloads the
sprites, adds the hooks to `%USERPROFILE%\.claude\settings.json` (leaving your
other settings as they were), adds `/pet` to Claude Code and starts the pets.
Nothing else needs installing.

To start the pets when you sign in, press Win+R, type `shell:startup`, and put
a shortcut to `%LOCALAPPDATA%\ClaudePet\ClaudePet.exe` in that folder.

## Using it

A pet appears for each Claude Code session as soon as it does something, so
send a message in a session that was already open to see its pet.

- **Summon or dismiss** the pets with `/pet` in Claude Code, or `claude-pet` in
  a Mac terminal.
- **Click** a pet to jump to its session: it brings that terminal forward, and
  clears the "is done".
- **Drag** a pet anywhere. It stays where you leave it.
- **Hover** over a pet to see which project it belongs to.
- **Right-click** a pet for:
  - **Go to Agent**
  - **Pokemon**: pick a different one from a grid of every sprite. The ones
    other sessions have are greyed out, and picking one swaps the two.
  - **Return to Poke Ball** / **Let Out**: put a pet away by hand. It comes
    back out when you click it or its session gets busy.
  - **Line Up Pets**: a column or a row, in any corner of the screen. Pets are
    spaced by their real size, so a Snorlax gets more room than a Poke Ball.

![Picking a Pokemon from the right-click menu](docs/picker.png)

## How it works

Claude Code runs the app's own binary (`ClaudePet --hook`) in the background on
each hook event: when a session starts, when you send a message, when a tool
runs, when it asks for permission, when it finishes and when it ends. Each run
writes one small file per session, which the app reads once a second:
`~/.local/share/claude-pet/sessions` on a Mac, `%LOCALAPPDATA%\ClaudePet\sessions`
on Windows.

Pressing Esc to deny a prompt or interrupt a turn doesn't fire a hook, so the
app also checks the end of the session's transcript for the interrupt. A
session that crashes is cleaned up by watching its Claude process.

If you run your agents in [herdr](https://herdr.dev), the pets follow herdr's
sidebar instead: they line up in the same order, and clicking one switches
herdr to that pane.

`ClaudePet --status` lists every session the pets can see. On a Mac that's
`~/Applications/Claude Pet.app/Contents/MacOS/ClaudePet --status`; on Windows,
`%LOCALAPPDATA%\ClaudePet\ClaudePet.exe --status`.

## Uninstall

- **Mac:** `zsh install.sh --uninstall` from the download (or the cloned repo).
  To keep the app but stop the hooks, use `zsh install.sh --remove-hooks`.
- **Windows:** double-click **uninstall.cmd** from the download.

Either way this removes the app, the commands, the hooks, the downloaded
sprites and the pets' saved settings.

## Troubleshooting

- **No pets:** make sure the app is running (`/pet`), then send a message in a
  Claude Code session so it reports in.
- **A pet is stuck working or flashing:** send that session a message, or
  click the pet; its next hook event puts it right.
- **The Mac build fails:** install or update Xcode's command-line tools with
  `xcode-select --install`, then run the installer again.
- **Windows sprites are missing:** run install.cmd again; it retries any that
  didn't download.

## Project layout

| File | What it is |
| --- | --- |
| `ClaudePet.swift` | The Mac app: a single Swift file on AppKit, no dependencies |
| `install.sh`, `build.sh`, `fetch-sprites.sh`, `hooks.js` | The Mac installer and its parts |
| `claude-pet`, `pet.md` | The Mac toggle command and `/pet` |
| `Info.plist` | The Mac app bundle's metadata |
| `windows/Program.cs` | The Windows app: a single C# file on WPF, which also installs itself |
| `windows/install.cmd`, `windows/uninstall.cmd` | Double-click launchers for the Windows setup |
| `.github/workflows/build.yml` | Builds both apps, and publishes the downloads on each release |

## Sprites

The Pokemon are Gen 3-style walking sprites from the
[pokeemerald-expansion](https://github.com/rh-hideout/pokeemerald-expansion)
project, and the Poke Ball is FireRed's item ball from
[pret/pokefirered](https://github.com/pret/pokefirered). They're Nintendo and
Game Freak's art, so they aren't included in this repo: the installers
download them, for personal use.

Pokemon is a trademark of Nintendo, Game Freak and Creatures. Claude is a
trademark of Anthropic. This is a fan project, not affiliated with or endorsed
by any of them.
