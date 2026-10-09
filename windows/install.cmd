@echo off
rem Installs Claude Agent Pokedex: copies Claude Pet into %LOCALAPPDATA%\ClaudePet,
rem downloads the sprites, adds the Claude Code hooks and /pet, then starts it.
rem Safe to run again, for example to update.
"%~dp0ClaudePet.exe" --install
