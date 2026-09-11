@echo off
rem Developer-only DEBUG launcher: all values increase-only, saving disabled.
rem End users start the game via xinsong-zhisuo.exe directly and never get this flag.
start "" "%~dp0..\build\xinsong-zhisuo.exe" -- --debug
