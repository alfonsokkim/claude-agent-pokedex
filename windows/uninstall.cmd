@echo off
rem Removes everything install.cmd added: the app, the sprites, the hooks and /pet.
if exist "%LOCALAPPDATA%\ClaudePet\ClaudePet.exe" (
  "%LOCALAPPDATA%\ClaudePet\ClaudePet.exe" --uninstall
) else (
  "%~dp0ClaudePet.exe" --uninstall
)
