@echo off
start "" powershell -NoProfile -ExecutionPolicy AllSigned -WindowStyle Hidden -File "%~dp0MicBridgeUI.ps1"
