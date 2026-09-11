@echo off
chcp 65001 >nul
setlocal
title 导出 新宋 · 治所 - Windows

set "ROOT=%~dp0\.."
set "TPL_VERSION=4.7.2.stable"
set "TPL_DIR=%APPDATA%\Godot\export_templates\%TPL_VERSION%"
set "TPZ=%TEMP%\Godot_v4.7.2-stable_export_templates.tpz"
set "OUT=%ROOT%\build\xinsong-zhisuo.exe"

rem ---- 1. 定位 Godot（优先 PATH，其次 WinGet 默认安装路径）----
set "GODOT=godot"
where godot >nul 2>nul
if errorlevel 1 set "GODOT=C:\Users\tiger\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"
if not exist "%GODOT%" (echo [错误] 找不到 Godot 4.7.2，请先安装 & pause & exit /b 1)

rem ---- 2. 检查导出模板，缺失则下载安装（约 1GB，只需一次）----
if not exist "%TPL_DIR%\windows_release_x86_64.exe" (
	echo [提示] 首次运行：正在下载导出模板，约 1GB，请耐心等待...
	curl -L --retry 3 -o "%TPZ%" "https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz"
	if errorlevel 1 (echo [错误] 模板下载失败 & pause & exit /b 1)
	echo [提示] 解压安装模板...
	set "TMPDIR=%TEMP%\godot_tpl_%RANDOM%"
	mkdir "%TMPDIR%" 2>nul
	tar -xf "%TPZ%" -C "%TMPDIR%"
	mkdir "%TPL_DIR%" 2>nul
	xcopy /E /Y /Q "%TMPDIR%\templates\*" "%TPL_DIR%\" >nul
	rmdir /S /Q "%TMPDIR%"
	del "%TPZ%" 2>nul
)
if not exist "%TPL_DIR%\windows_release_x86_64.exe" (echo [错误] 模板安装失败 & pause & exit /b 1)

rem ---- 3. 导出 ----
if not exist "%ROOT%\build" mkdir "%ROOT%\build"
echo [提示] 开始导出...
"%GODOT%" --headless --path "%ROOT%" --export-release "Windows Desktop" "%OUT%"
if errorlevel 1 (echo [错误] 导出失败，查看上方日志 & pause & exit /b 1)

echo.
echo [完成] 导出成功：
echo   %OUT%
dir /B "%ROOT%\build"
pause
