---
inclusion: always
---

# Phone Access (replaces SSH)

The Sharp Aquos S40P running hp-server is accessible via HTTPS through Cloudflare Tunnel.
**Never use `ssh hp` — use the API instead.** SSH is LAN-only and unreliable from Kiro.

## How to run commands on the phone

Write the JSON body to a temp file, then use curl with `@file`:

```powershell
$key = $env:HP_ADMIN_KEY
'{"cmd":"YOUR_COMMAND_HERE","timeout_ms":60000}' | Out-File -Encoding utf8 -FilePath "$env:TEMP\hp-exec.json"
curl.exe -sm 90 -X POST -H "X-API-Key: $key" -H "Content-Type: application/json" -d "@$env:TEMP\hp-exec.json" https://app.rofihosted.space/api/system/exec
Remove-Item "$env:TEMP\hp-exec.json" -ErrorAction SilentlyContinue
```

For complex commands with special characters, use a helper function:

```powershell
function Invoke-Phone {
    param([string]$Cmd, [int]$TimeoutMs = 60000)
    $key = $env:HP_ADMIN_KEY
    if (-not $key) { throw "HP_ADMIN_KEY not set" }
    $tmp = "$env:TEMP\hp-exec-$(Get-Random).json"
    @{cmd=$Cmd; timeout_ms=$TimeoutMs} | ConvertTo-Json | Out-File -Encoding utf8 $tmp
    $result = curl.exe -sm ([int]($TimeoutMs/1000)+10) -X POST -H "X-API-Key: $key" -H "Content-Type: application/json" -d "@$tmp" https://app.rofihosted.space/api/system/exec | ConvertFrom-Json
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($result.stdout) { Write-Host $result.stdout }
    if ($result.stderr) { Write-Host $result.stderr -ForegroundColor Red }
    return $result
}
# Usage: Invoke-Phone "ls ~/data/projects"
```

## How to rebuild hp-server on the phone

```powershell
$key = $env:HP_ADMIN_KEY
curl.exe -sm 300 -X POST -H "X-API-Key: $key" https://app.rofihosted.space/v1/system/update
```

## How to push files to the phone

Use `scp` for binary files (woff2, zip, etc):
```
scp localfile.txt hp:~/destination/
```

For text files, use `/api/system/exec` with a heredoc-style write:
```powershell
$key = $env:HP_ADMIN_KEY
$content = Get-Content "localfile.sh" -Raw
$escaped = $content -replace '"', '\"' -replace "`n", '\n'
$body = "{`"cmd`":`"printf '%s' `"$escaped`" > ~/destination/file.sh`"}"
curl.exe -sm 10 -X POST -H "X-API-Key: $key" -H "Content-Type: application/json" -d $body https://app.rofihosted.space/api/system/exec
```

For large files, still use scp. For small scripts, use exec.

## Credentials

The admin API key is stored in `$env:HP_ADMIN_KEY` in the PowerShell session.
If not set, ask the user to run: `$env:HP_ADMIN_KEY = "rh_..."`

The key must have `admin` scope. Create one at https://app.rofihosted.space/security.

## Endpoints available

- `GET  /v1/system/version`  — current SHA + binary mtime
- `GET  /v1/system/info`     — battery, mem, disk, uptime
- `GET  /v1/system/power`    — charger status
- `POST /v1/system/update`   — git pull + rebuild + restart
- `POST /v1/system/backup`   — trigger backup (local or r2)
- `GET  /v1/projects`        — list all projects
- `POST /api/system/exec`    — run arbitrary shell command (admin scope)

## Important notes

- `/api/system/exec` timeout default is 60s, max 300s
- Rebuild via `/v1/system/update` takes 30-90s and may 524 (CF timeout) — that's OK, phone keeps building
- After rebuild, hp-server restarts; wait ~10s then verify with `/v1/system/version`
- The phone is at `192.168.100.69:8022` on LAN (SSH key-based) but prefer HTTPS API
- All exec commands are audit-logged on the phone
