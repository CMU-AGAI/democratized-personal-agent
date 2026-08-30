<#
  start.ps1 - quick restart of the whole stack AFTER first-time setup.

  Use up.ps1 for the initial run (it also pulls the model and links Signal).
  Once the Signal number is linked (keys live in the signal_data volume), this is
  enough to rebuild + bring everything back up.
#>
$ErrorActionPreference = "Stop"
docker compose up -d --build
docker compose ps
