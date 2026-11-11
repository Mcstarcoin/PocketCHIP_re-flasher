@echo off
rem Double-click launcher for the Windows PocketCHIP flasher.
rem Runs the PowerShell script without changing the system execution policy.
title PocketCHIP Flasher
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0pocketchip-flasher.ps1" %*
if errorlevel 1 pause
