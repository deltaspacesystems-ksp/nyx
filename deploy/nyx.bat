@echo off
rem Zarzadzanie Nyx. Bez argumentow pokazuje pomoc (start, stop, status, nginx, firewall, autostart...).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0nyx.ps1" %*
if "%1"=="" pause
