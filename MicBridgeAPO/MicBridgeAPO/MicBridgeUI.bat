@echo off
start "" powershell.exe -NoProfile -ExecutionPolicy AllSigned -WindowStyle Hidden -File "%~dp0MicBridgeUI.ps1"
