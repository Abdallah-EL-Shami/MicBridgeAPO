@echo off
echo Review INSTALL-TRUST-AR.md and manually verify the publisher before continuing.
powershell.exe -NoProfile -ExecutionPolicy AllSigned -File "%~dp0install.ps1"
