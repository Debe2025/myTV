###########################################
# myTV Repository Builder
# Builds the full myTV repo structure at
# the script's own directory location.
#
# What it does:
#   1. Detects location via IP
#   2. Fetches channels from IPTV-ORG
#   3. Extracts channel IDs
#   4. Requests EPG from epg-fetcher
#   5. Saves playlist.m3u8 + epg.xml.gz to docs/
#   6. Creates kodi-installer addon (repo source)
#   7. Creates GitHub Actions workflow
#   8. Creates scripts/generate_playlist.py
#   9. Maps PVR IPTV Simple to local docs/ files
#  10. Commits and pushes to GitHub
###########################################

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# ── CONFIGURATION ─────────────────────────────────────────────
$epgFetcherUrl  = "https://tender-rebirth-production.up.railway.app/api/v1/fetch"   # UPDATE THIS
$githubUsername = "Debe2025"                                       # UPDATE THIS
# ──────────────────────────────────────────────────────────────

# All paths derived from where this script lives
$repoRoot      = Split-Path -Parent $MyInvocation.MyCommand.Path
$docsPath      = "$repoRoot\docs"
$scriptsPath   = "$repoRoot\scripts"
$workflowPath  = "$repoRoot\.github\workflows"
$installerPath = "$repoRoot\kodi-installer"

$githubPagesBase = "https://$githubUsername.github.io/myTV"
$remotePlaylist  = "$githubPagesBase/playlist.m3u8"
$remoteEpg       = "$githubPagesBase/epg.xml.gz"
$localPlaylist   = "$docsPath\playlist.m3u8"
$localEpg        = "$docsPath\epg.xml.gz"

# Admin check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Please run as Administrator!" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"; exit 1
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Blue
Write-Host "    myTV Repository Builder" -ForegroundColor Blue
Write-Host "    Repo: $repoRoot" -ForegroundColor Blue
Write-Host "================================================================" -ForegroundColor Blue
Write-Host ""

# =============================================================================
# STEP 1 - DETECT LOCATION
# =============================================================================
Write-Host "Step 1: Detecting location via IP..." -ForegroundColor Cyan
try {
    $geo         = Invoke-RestMethod -Uri "http://ip-api.com/json/" -TimeoutSec 10
    $CountryCode = $geo.countryCode.ToLower()
    $CountryName = $geo.country
    $City        = $geo.city
    Write-Host "  SUCCESS: $City, $CountryName ($CountryCode)" -ForegroundColor Green
} catch {
    Write-Host "  WARNING: IP detection failed, defaulting to US" -ForegroundColor Yellow
    $CountryCode = "us"; $CountryName = "United States"; $City = "Unknown"
}

# =============================================================================
# STEP 2 - FETCH CHANNELS FROM IPTV-ORG
# =============================================================================
Write-Host ""
Write-Host "Step 2: Downloading channels from IPTV-ORG..." -ForegroundColor Cyan

$urls = @{
    Country = "https://iptv-org.github.io/iptv/countries/$CountryCode.m3u"
    News    = "https://iptv-org.github.io/iptv/categories/news.m3u"
    Movies  = "https://iptv-org.github.io/iptv/categories/movies.m3u"
    Sports  = "https://iptv-org.github.io/iptv/categories/sports.m3u"
}

$playlists     = @{}
$counts        = @{}
$totalCount    = 0
$allChannelIds = [System.Collections.Generic.List[string]]::new()

foreach ($cat in $urls.Keys) {
    Write-Host "  Downloading $cat..." -ForegroundColor Gray
    try {
        $tmp     = "$env:TEMP\mytv_$cat.m3u"
        Invoke-WebRequest -Uri $urls[$cat] -OutFile $tmp -TimeoutSec 30
        $content = Get-Content -Path $tmp -Raw -Encoding UTF8
        $count   = ([regex]::Matches($content, '#EXTINF')).Count
        $playlists[$cat] = $content
        $counts[$cat]    = $count
        $totalCount     += $count

        [regex]::Matches($content, 'tvg-id="([^"]+)"') | ForEach-Object {
            $id = $_.Groups[1].Value.Trim()
            if ($id -ne '') { $allChannelIds.Add($id) }
        }

        Write-Host "  SUCCESS: $count channels" -ForegroundColor Green
        Remove-Item $tmp -Force
    } catch {
        Write-Host "  WARNING: Failed to fetch $cat" -ForegroundColor Yellow
        $playlists[$cat] = ""; $counts[$cat] = 0
    }
}

$uniqueIds = $allChannelIds | Select-Object -Unique

Write-Host ""
Write-Host "  Summary: $totalCount channels, $($uniqueIds.Count) unique EPG IDs" -ForegroundColor Cyan

# =============================================================================
# STEP 3 - BUILD COMBINED M3U PLAYLIST
# =============================================================================
Write-Host ""
Write-Host "Step 3: Building combined playlist..." -ForegroundColor Cyan

$m3u = "#EXTM3U`n`n"
foreach ($cat in @('Country','News','Movies','Sports')) {
    if ($playlists[$cat]) {
        $label = if ($cat -eq 'Country') { "LOCAL - $CountryName" } else { $cat.ToUpper() }
        $m3u  += "# ======================================`n"
        $m3u  += "# $label`n"
        $m3u  += "# ======================================`n"
        $m3u  += ($playlists[$cat] -replace '#EXTM3U','').Trim()
        $m3u  += "`n`n"
    }
}

# =============================================================================
# STEP 4 - REQUEST EPG FROM EPG-FETCHER (with full channel metadata)
# =============================================================================
Write-Host ""
Write-Host "Step 4: Requesting EPG from epg-fetcher..." -ForegroundColor Cyan

$epgFetched = $false

if ($epgFetcherUrl -like "https://your-epg-fetcher*") {
    Write-Host "  WARNING: EPG fetcher URL not configured" -ForegroundColor Yellow
    Write-Host "  Update `$epgFetcherUrl at the top of this script" -ForegroundColor Gray
} elseif ($uniqueIds.Count -eq 0) {
    Write-Host "  WARNING: No channel IDs found, skipping EPG" -ForegroundColor Yellow
} else {

    # -- 4a. Fetch iptv-org channel database to get site/site_id/lang for each tvg-id
    Write-Host "  Fetching iptv-org channel database..." -ForegroundColor Gray
    $dbUrl     = "https://raw.githubusercontent.com/iptv-org/database/master/data/channels.csv"
    $channelDb = @{}   # xmltv_id -> @{ site; site_id; lang; name }

    try {
        $csvRaw = Invoke-RestMethod -Uri $dbUrl -TimeoutSec 30
        # Parse CSV: id,name,country,subdivision,city,broadcast_area,languages,
        #            categories,is_nsfw,launched,closed,replaced_by,website,logo
        $lines = $csvRaw -split "`n" | Where-Object { $_.Trim() -ne '' }
        $header = $lines[0] -split ','

        # Column indices
        $idIdx   = 0   # id (same as xmltv_id / tvg-id)
        $nameIdx = 1   # name
        $langIdx = 6   # languages (first language used as lang)

        foreach ($line in $lines[1..($lines.Count-1)]) {
            # Handle quoted CSV fields
            $fields = $line -split ',(?=(?:[^"]*"[^"]*")*[^"]*$)'
            if ($fields.Count -ge 7) {
                $id   = $fields[$idIdx].Trim().Trim('"')
                $name = $fields[$nameIdx].Trim().Trim('"')
                $lang = ($fields[$langIdx].Trim().Trim('"') -split ';')[0].Trim()
                if ($id -ne '') {
                    $channelDb[$id] = @{ name = $name; lang = $lang }
                }
            }
        }
        Write-Host "  Database loaded: $($channelDb.Count) channels" -ForegroundColor Gray
    } catch {
        Write-Host "  WARNING: Could not load channel database - $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # -- 4b. Also fetch the EPG channels list to get site/site_id
    Write-Host "  Fetching EPG channels list from iptv-org/epg..." -ForegroundColor Gray
    $epgDbUrl   = "https://iptv-org.github.io/epg/channels.json"
    $epgChannel = @{}  # xmltv_id -> @{ site; site_id }

    try {
        $epgJson = Invoke-RestMethod -Uri $epgDbUrl -TimeoutSec 30
        foreach ($ch in $epgJson) {
            if ($ch.xmltv_id) {
                $epgChannel[$ch.xmltv_id] = @{
                    site    = $ch.site
                    site_id = $ch.site_id
                }
            }
        }
        Write-Host "  EPG channels loaded: $($epgChannel.Count) entries" -ForegroundColor Gray
    } catch {
        Write-Host "  WARNING: Could not load EPG channels list - $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # -- 4c. Build enriched channel list matching our tvg-ids
    $enrichedChannels = [System.Collections.Generic.List[hashtable]]::new()
    $matched   = 0
    $unmatched = 0

    foreach ($id in $uniqueIds) {
        $entry = @{ xmltv_id = $id }

        # Add lang and name from database
        if ($channelDb.ContainsKey($id)) {
            $entry['name'] = $channelDb[$id].name
            $entry['lang'] = $channelDb[$id].lang
        }

        # Add site and site_id from EPG channels list
        if ($epgChannel.ContainsKey($id)) {
            $entry['site']    = $epgChannel[$id].site
            $entry['site_id'] = $epgChannel[$id].site_id
            $matched++
        } else {
            $unmatched++
        }

        $enrichedChannels.Add($entry)
    }

    Write-Host "  Matched: $matched channels with full EPG metadata" -ForegroundColor Gray
    Write-Host "  Unmatched: $unmatched channels (tvg-id not in EPG database)" -ForegroundColor Gray

    # -- 4d. Send enriched channel list to epg-fetcher
    try {
        $body = @{
            channels    = @($enrichedChannels)
            country     = $CountryCode
            lang        = "en"
        } | ConvertTo-Json -Depth 5

        Write-Host "  Sending $($enrichedChannels.Count) channels to epg-fetcher..." -ForegroundColor Gray
        Write-Host "  Endpoint: $epgFetcherUrl" -ForegroundColor Gray

        New-Item -ItemType Directory -Path $docsPath -Force | Out-Null

        Invoke-RestMethod -Uri $epgFetcherUrl `
            -Method Post `
            -Body $body `
            -Headers @{ "Content-Type" = "application/json" } `
            -OutFile $localEpg `
            -TimeoutSec 120

        if (Test-Path $localEpg) {
            $kb = [math]::Round((Get-Item $localEpg).Length / 1KB, 1)
            Write-Host "  SUCCESS: EPG saved ($kb KB) - $matched channels with guide data" -ForegroundColor Green
            $epgFetched = $true
        }
    } catch {
        Write-Host "  WARNING: EPG request failed - $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# =============================================================================
# STEP 5 - SAVE PLAYLIST + INDEX TO docs/
# =============================================================================
Write-Host ""
Write-Host "Step 5: Saving files to docs/ folder..." -ForegroundColor Cyan

New-Item -ItemType Directory -Path $docsPath -Force | Out-Null
Set-Content -Path $localPlaylist -Value $m3u -Encoding UTF8
Write-Host "  Saved: docs\playlist.m3u8 ($totalCount channels)" -ForegroundColor Green
if ($epgFetched) {
    Write-Host "  Saved: docs\epg.xml.gz" -ForegroundColor Green
}

# docs/index.html
$indexHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>myTV</title>
    <style>
        body{font-family:sans-serif;background:#1a1a2e;color:#eee;display:flex;
             justify-content:center;align-items:center;min-height:100vh;margin:0}
        .card{background:#16213e;border-radius:16px;padding:40px;max-width:700px;
              width:100%;box-shadow:0 8px 32px rgba(0,0,0,.4)}
        h1{margin:0 0 6px;font-size:2.2em}
        .sub{color:#aaa;margin-bottom:20px}
        .pill{display:inline-block;background:#0f3460;border-radius:20px;
              padding:4px 14px;font-size:.85em;margin-bottom:24px}
        .url-box{background:#0f3460;border-radius:10px;padding:18px;margin:14px 0}
        .label{font-size:.75em;text-transform:uppercase;letter-spacing:1px;
               color:#7ec8e3;margin-bottom:8px}
        .url{font-family:monospace;font-size:.9em;word-break:break-all}
        .btn{margin-top:10px;background:#e94560;border:none;color:#fff;
             padding:8px 18px;border-radius:6px;cursor:pointer;font-size:.85em}
        .btn:hover{background:#c73652}
        .steps{margin-top:28px;border-top:1px solid #333;padding-top:20px}
        .steps h3{color:#7ec8e3;margin-bottom:12px}
        .steps ol{margin:0 0 0 18px;line-height:2;color:#ccc}
    </style>
</head>
<body>
<div class="card">
    <h1>TV myTV</h1>
    <p class="sub">Auto-updating IPTV playlist for $CountryName</p>
    <span class="pill">$totalCount channels | Updates every 6 hours</span>

    <div class="url-box">
        <div class="label">M3U Playlist URL</div>
        <div class="url" id="m3u">$remotePlaylist</div>
        <button class="btn" onclick="copy('m3u')">Copy</button>
    </div>

    <div class="url-box">
        <div class="label">EPG / TV Guide URL</div>
        <div class="url" id="epg">$remoteEpg</div>
        <button class="btn" onclick="copy('epg')">Copy</button>
    </div>

    <div class="steps">
        <h3>Setup in Kodi</h3>
        <ol>
            <li>Install <strong>PVR IPTV Simple Client</strong> from Kodi repo</li>
            <li>Set M3U and EPG URLs above in its settings</li>
            <li>Settings &rarr; PVR &amp; Live TV &rarr; Enable Live TV</li>
            <li>TV &rarr; Channels &rarr; Enjoy!</li>
        </ol>
    </div>
</div>
<script>
function copy(id){
    navigator.clipboard.writeText(document.getElementById(id).textContent);
    event.target.textContent='Copied!';
    setTimeout(()=>event.target.textContent='Copy',2000);
}
</script>
</body>
</html>
"@
Set-Content -Path "$docsPath\index.html" -Value $indexHtml -Encoding UTF8
Write-Host "  Saved: docs\index.html" -ForegroundColor Green

# =============================================================================
# STEP 6 - CREATE kodi-installer/ ADDON
# =============================================================================
Write-Host ""
Write-Host "Step 6: Creating kodi-installer addon..." -ForegroundColor Cyan

New-Item -ItemType Directory -Path $installerPath -Force | Out-Null

$addonXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<addon id="repository.mytv"
       name="myTV Repository"
       version="1.0.0"
       provider-name="$githubUsername">
    <extension point="xbmc.addon.repository" name="myTV Repository">
        <dir>
            <info compressed="false">$githubPagesBase/addons.xml</info>
            <checksum>$githubPagesBase/addons.xml.md5</checksum>
            <datadir zip="true">$githubPagesBase/zips/</datadir>
        </dir>
    </extension>
    <extension point="xbmc.addon.metadata">
        <summary lang="en">myTV IPTV Repository</summary>
        <description lang="en">Auto-updating IPTV for $CountryName – $totalCount channels. EPG via epg-fetcher.</description>
        <platform>all</platform>
    </extension>
</addon>
"@
Set-Content -Path "$installerPath\addon.xml" -Value $addonXml -Encoding UTF8

$installerPy = @'
#!/usr/bin/python
# -*- coding: utf-8 -*-
import xbmc, xbmcaddon, xbmcgui

LOCAL_PLAYLIST  = "PLACEHOLDER_LOCAL_PLAYLIST"
LOCAL_EPG       = "PLACEHOLDER_LOCAL_EPG"
REMOTE_PLAYLIST = "PLACEHOLDER_REMOTE_PLAYLIST"
REMOTE_EPG      = "PLACEHOLDER_REMOTE_EPG"
COUNTRY         = "PLACEHOLDER_COUNTRY"
CHANNELS        = "PLACEHOLDER_CHANNELS"

def run():
    dialog = xbmcgui.Dialog()
    choice = dialog.select(
        'myTV - Choose Source',
        ['Local files  (works immediately)',
         'GitHub Pages (auto-updates after push)']
    )
    if choice < 0:
        return
    try:
        pvr = xbmcaddon.Addon('pvr.iptvsimple')
        if choice == 0:
            pvr.setSetting('m3uPathType', '0')
            pvr.setSetting('m3uPath',     LOCAL_PLAYLIST)
            pvr.setSetting('epgPathType', '0')
            pvr.setSetting('epgPath',     LOCAL_EPG)
            source = 'Local files'
        else:
            pvr.setSetting('m3uPathType', '1')
            pvr.setSetting('m3uUrl',      REMOTE_PLAYLIST)
            pvr.setSetting('epgPathType', '1')
            pvr.setSetting('epgUrl',      REMOTE_EPG)
            source = 'GitHub Pages'
        pvr.setSetting('m3uCache',               'true')
        pvr.setSetting('m3uRefreshMode',         '2')
        pvr.setSetting('m3uRefreshIntervalMins', '60')
        pvr.setSetting('epgCache',               'true')
        pvr.setSetting('logoPathType',           '1')
        pvr.setSetting('logoBaseUrl', 'https://iptv-org.github.io/iptv/logos/')
        dialog.ok('myTV Setup Complete',
                  'PVR IPTV Simple configured!\n\n'
                  'Source:   ' + source + '\n'
                  'Country:  ' + COUNTRY + '\n'
                  'Channels: ' + CHANNELS + '\n\n'
                  'Restart Kodi, then enable Live TV.')
        xbmc.log('[myTV] Configured with ' + source, xbmc.LOGINFO)
    except Exception as e:
        dialog.ok('myTV Error', 'Could not configure PVR IPTV Simple.\n\nIs it installed?\n\n' + str(e))
        xbmc.log('[myTV] Error: ' + str(e), xbmc.LOGERROR)

if __name__ == '__main__':
    run()
'@

$localPlaylistFwd = $localPlaylist -replace '\\', '/'
$localEpgFwd      = $localEpg     -replace '\\', '/'

$installerPy = $installerPy `
    -replace 'PLACEHOLDER_LOCAL_PLAYLIST',  $localPlaylistFwd `
    -replace 'PLACEHOLDER_LOCAL_EPG',       $localEpgFwd `
    -replace 'PLACEHOLDER_REMOTE_PLAYLIST', $remotePlaylist `
    -replace 'PLACEHOLDER_REMOTE_EPG',      $remoteEpg `
    -replace 'PLACEHOLDER_COUNTRY',         $CountryName `
    -replace 'PLACEHOLDER_CHANNELS',        "$totalCount"

Set-Content -Path "$installerPath\installer.py" -Value $installerPy -Encoding UTF8

$installerReadme = @"
# myTV Kodi Installer

Kodi addon that configures PVR IPTV Simple for myTV.

## Install
1. Zip this folder as ``repository.mytv-1.0.0.zip``
2. Kodi -> Settings -> Add-ons -> Install from zip file
3. Run **myTV Installer** from Program add-ons
4. Choose Local or GitHub Pages source

## Details
- Country  : $CountryName ($CountryCode)
- Channels : $totalCount
- Playlist : $remotePlaylist
- EPG      : $remoteEpg
"@
Set-Content -Path "$installerPath\README.md" -Value $installerReadme -Encoding UTF8

Write-Host "  Saved: kodi-installer\addon.xml" -ForegroundColor Green
Write-Host "  Saved: kodi-installer\installer.py (dual-mode: local + GitHub Pages)" -ForegroundColor Green
Write-Host "  Saved: kodi-installer\README.md" -ForegroundColor Green

# =============================================================================
# STEP 7 - CREATE .github/workflows/update-playlist.yml
# =============================================================================
Write-Host ""
Write-Host "Step 7: Creating GitHub Actions workflow..." -ForegroundColor Cyan

New-Item -ItemType Directory -Path $workflowPath -Force | Out-Null

$workflow = @'
name: Update Playlist

on:
  schedule:
    - cron: '0 */6 * * *'
  workflow_dispatch:
  push:
    branches: [main]

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - name: Install dependencies
        run: pip install requests

      - name: Detect location
        id: geo
        run: |
          DATA=$(curl -s http://ip-api.com/json/)
          CC=$(echo $DATA | python3 -c "import sys,json; print(json.load(sys.stdin)['countryCode'].lower())")
          CN=$(echo $DATA | python3 -c "import sys,json; print(json.load(sys.stdin)['country'])")
          echo "country_code=$CC" >> $GITHUB_OUTPUT
          echo "country_name=$CN" >> $GITHUB_OUTPUT

      - name: Generate playlist and fetch EPG
        env:
          COUNTRY_CODE:    ${{ steps.geo.outputs.country_code }}
          EPG_FETCHER_URL: ${{ secrets.EPG_FETCHER_URL }}
        run: python scripts/generate_playlist.py

      - name: Commit updated files
        run: |
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git config user.name  "github-actions[bot]"
          git add docs/playlist.m3u8 docs/epg.xml.gz docs/index.html
          git diff --staged --quiet || git commit -m "Update playlist - ${{ steps.geo.outputs.country_name }}"
          git push
'@
Set-Content -Path "$workflowPath\update-playlist.yml" -Value $workflow -Encoding UTF8
Write-Host "  Saved: .github\workflows\update-playlist.yml" -ForegroundColor Green

# =============================================================================
# STEP 8 - CREATE scripts/generate_playlist.py
# =============================================================================
Write-Host ""
Write-Host "Step 8: Creating scripts/generate_playlist.py..." -ForegroundColor Cyan

New-Item -ItemType Directory -Path $scriptsPath -Force | Out-Null

$generatePy = @'
#!/usr/bin/env python3
"""
myTV - Playlist Generator (GitHub Actions)
1. Fetches channels by country from iptv-org
2. Looks up full channel metadata from iptv-org/database and epg channels list
3. Sends enriched channel list to epg-fetcher for XMLTV guide data
"""
import os, re, gzip, json, requests
from pathlib import Path

COUNTRY_CODE    = os.getenv("COUNTRY_CODE", "us")
EPG_FETCHER_URL = os.getenv("EPG_FETCHER_URL", "")
IPTV_BASE       = "https://iptv-org.github.io/iptv"
DOCS            = Path("docs")
DOCS.mkdir(exist_ok=True)

SOURCES = {
    "country": f"{IPTV_BASE}/countries/{COUNTRY_CODE}.m3u",
    "news":    f"{IPTV_BASE}/categories/news.m3u",
    "movies":  f"{IPTV_BASE}/categories/movies.m3u",
    "sports":  f"{IPTV_BASE}/categories/sports.m3u",
}

# ── Step 1: Fetch playlists ───────────────────────────────────
combined    = "#EXTM3U\n\n"
channel_ids = set()
totals      = {}

for label, url in SOURCES.items():
    try:
        r = requests.get(url, timeout=30)
        r.raise_for_status()
        content = r.text
        count   = len(re.findall(r"#EXTINF", content))
        totals[label] = count
        heading = f"LOCAL - {COUNTRY_CODE.upper()}" if label == "country" else label.upper()
        combined += f"# ======================================\n# {heading}\n# ======================================\n"
        combined += content.replace("#EXTM3U", "").strip() + "\n\n"
        for m in re.finditer(r'tvg-id="([^"]+)"', content):
            cid = m.group(1).strip()
            if cid:
                channel_ids.add(cid)
        print(f"  {label}: {count} channels")
    except Exception as e:
        print(f"  WARNING: {label} failed - {e}")
        totals[label] = 0

(DOCS / "playlist.m3u8").write_text(combined, encoding="utf-8")
print(f"\nPlaylist: {sum(totals.values())} channels, {len(channel_ids)} unique IDs")

# ── Step 2: Load iptv-org channel database (id, name, lang) ──
channel_db = {}
try:
    r = requests.get(
        "https://raw.githubusercontent.com/iptv-org/database/master/data/channels.csv",
        timeout=30
    )
    r.raise_for_status()
    lines = r.text.strip().split("\n")
    for line in lines[1:]:
        fields = re.split(r',(?=(?:[^"]*"[^"]*")*[^"]*$)', line)
        if len(fields) >= 7:
            ch_id  = fields[0].strip().strip('"')
            name   = fields[1].strip().strip('"')
            lang   = fields[6].strip().strip('"').split(";")[0].strip()
            if ch_id:
                channel_db[ch_id] = {"name": name, "lang": lang}
    print(f"Channel database: {len(channel_db)} entries")
except Exception as e:
    print(f"WARNING: Channel database failed - {e}")

# ── Step 3: Load iptv-org EPG channels (site, site_id) ───────
epg_channels = {}
try:
    r = requests.get("https://iptv-org.github.io/epg/channels.json", timeout=30)
    r.raise_for_status()
    for ch in r.json():
        if ch.get("xmltv_id"):
            epg_channels[ch["xmltv_id"]] = {
                "site":    ch.get("site", ""),
                "site_id": ch.get("site_id", "")
            }
    print(f"EPG channels list: {len(epg_channels)} entries")
except Exception as e:
    print(f"WARNING: EPG channels list failed - {e}")

# ── Step 4: Enrich and send to epg-fetcher ───────────────────
if not EPG_FETCHER_URL:
    print("EPG_FETCHER_URL not set - skipping")
elif not channel_ids:
    print("No channel IDs found - skipping EPG")
else:
    enriched = []
    matched  = 0

    for cid in channel_ids:
        entry = {"xmltv_id": cid}
        if cid in channel_db:
            entry["name"] = channel_db[cid]["name"]
            entry["lang"] = channel_db[cid]["lang"]
        if cid in epg_channels:
            entry["site"]    = epg_channels[cid]["site"]
            entry["site_id"] = epg_channels[cid]["site_id"]
            matched += 1
        enriched.append(entry)

    print(f"Sending {len(enriched)} channels ({matched} with full metadata) to epg-fetcher...")

    try:
        resp = requests.post(
            EPG_FETCHER_URL,
            json={
                "channels": enriched,
                "country":  COUNTRY_CODE,
                "lang":     "en"
            },
            headers={"Content-Type": "application/json"},
            timeout=120
        )
        resp.raise_for_status()
        epg_path = DOCS / "epg.xml.gz"
        ct = resp.headers.get("Content-Type", "")
        ce = resp.headers.get("Content-Encoding", "")
        if "gzip" in ce or "gzip" in ct:
            epg_path.write_bytes(resp.content)
        else:
            epg_path.write_bytes(gzip.compress(resp.content))
        print(f"EPG saved: {epg_path.stat().st_size // 1024} KB")
    except Exception as e:
        print(f"WARNING: EPG fetch failed - {e}")

print("Done.")
'@
Set-Content -Path "$scriptsPath\generate_playlist.py" -Value $generatePy -Encoding UTF8
Write-Host "  Saved: scripts\generate_playlist.py" -ForegroundColor Green

# =============================================================================
# STEP 9 - MAP PVR IPTV SIMPLE TO LOCAL docs/ FILES
# =============================================================================
Write-Host ""
Write-Host "Step 9: Mapping PVR IPTV Simple to local docs/ files..." -ForegroundColor Cyan

$KodiUserdata = "$env:APPDATA\Kodi\userdata"

if (Test-Path $KodiUserdata) {
    $pvrPath = "$KodiUserdata\addon_data\pvr.iptvsimple"
    New-Item -ItemType Directory -Path $pvrPath -Force | Out-Null

    $pvrXml = @"
<settings version="2">
    <setting id="m3uPathType">0</setting>
    <setting id="m3uPath">$localPlaylist</setting>
    <setting id="m3uCache">true</setting>
    <setting id="m3uRefreshMode">1</setting>
    <setting id="m3uRefreshIntervalMins">60</setting>
    <setting id="epgPathType">0</setting>
    <setting id="epgPath">$localEpg</setting>
    <setting id="epgCache">true</setting>
    <setting id="logoPathType">1</setting>
    <setting id="logoBaseUrl">https://iptv-org.github.io/iptv/logos/</setting>
</settings>
"@
    Set-Content -Path "$pvrPath\settings.xml" -Value $pvrXml -Encoding UTF8

    $guiXml = @"
<settings version="2">
    <setting id="addons.unknownsources" type="boolean">true</setting>
    <setting id="pvrmanager.enabled"    type="boolean">true</setting>
</settings>
"@
    Set-Content -Path "$KodiUserdata\guisettings.xml" -Value $guiXml -Encoding UTF8

    $advXml = @"
<advancedsettings>
    <network>
        <buffermode>1</buffermode>
        <cachemembuffersize>134217728</cachemembuffersize>
        <readbufferfactor>20</readbufferfactor>
    </network>
    <pvr>
        <timecorrection>0</timecorrection>
        <minvideocachelevel>5</minvideocachelevel>
        <minaudiocachelevel>10</minaudiocachelevel>
    </pvr>
</advancedsettings>
"@
    Set-Content -Path "$KodiUserdata\advancedsettings.xml" -Value $advXml -Encoding UTF8

    Write-Host "  PVR mapped to : $localPlaylist" -ForegroundColor Green
    Write-Host "  EPG mapped to : $localEpg" -ForegroundColor Green
    Write-Host "  Kodi settings : updated" -ForegroundColor Green
} else {
    Write-Host "  WARNING: Kodi userdata not found, skipping PVR mapping" -ForegroundColor Yellow
    Write-Host "  Install Kodi first, then re-run this script" -ForegroundColor Gray
}

# =============================================================================
# STEP 10 - GIT COMMIT & PUSH
# =============================================================================
Write-Host ""
Write-Host "Step 10: Committing to GitHub..." -ForegroundColor Cyan

Push-Location $repoRoot
try {
    $gitStatus = git status --porcelain 2>&1
    if ($gitStatus) {
        git add "docs\playlist.m3u8"
        git add "docs\index.html"
        if ($epgFetched) { git add "docs\epg.xml.gz" }
        git add "kodi-installer\"
        git add ".github\"
        git add "scripts\"
        $msg = "myTV update: $CountryName - $totalCount channels $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        git commit -m $msg
        git push origin main
        Write-Host "  Pushed to GitHub successfully" -ForegroundColor Green
        Write-Host "  GitHub Pages updates in ~2 minutes" -ForegroundColor Gray
    } else {
        Write-Host "  No changes to commit" -ForegroundColor Gray
    }
} catch {
    Write-Host "  WARNING: Git push failed - $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Push manually: git push origin main" -ForegroundColor Gray
}
Pop-Location

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "    COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Repo         : $repoRoot" -ForegroundColor White
Write-Host "  Country      : $CountryName ($CountryCode)" -ForegroundColor White
Write-Host "  Channels     : $totalCount (Local $($counts.Country) | News $($counts.News) | Movies $($counts.Movies) | Sports $($counts.Sports))" -ForegroundColor White
if ($epgFetched) {
    Write-Host "  EPG          : Fetched ($($uniqueIds.Count) channels)" -ForegroundColor White
} else {
    Write-Host "  EPG          : Not fetched - set `$epgFetcherUrl at top of script" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Repo structure:" -ForegroundColor Cyan
Write-Host "    docs\playlist.m3u8" -ForegroundColor Gray
Write-Host "    docs\epg.xml.gz" -ForegroundColor Gray
Write-Host "    docs\index.html" -ForegroundColor Gray
Write-Host "    kodi-installer\addon.xml" -ForegroundColor Gray
Write-Host "    kodi-installer\installer.py" -ForegroundColor Gray
Write-Host "    .github\workflows\update-playlist.yml" -ForegroundColor Gray
Write-Host "    scripts\generate_playlist.py" -ForegroundColor Gray
Write-Host ""
Write-Host "  PVR mapped to local files immediately:" -ForegroundColor Cyan
Write-Host "    Playlist : $localPlaylist" -ForegroundColor White
Write-Host "    EPG      : $localEpg" -ForegroundColor White
Write-Host ""
Write-Host "  After GitHub Pages updates (~2 min):" -ForegroundColor Cyan
Write-Host "    Playlist : $remotePlaylist" -ForegroundColor White
Write-Host "    EPG      : $remoteEpg" -ForegroundColor White
Write-Host ""
Write-Host "  Kodi next steps:" -ForegroundColor Yellow
Write-Host "    1. Install PVR IPTV Simple Client (already configured)" -ForegroundColor White
Write-Host "    2. Settings -> PVR & Live TV -> Enable Live TV" -ForegroundColor White
Write-Host "    3. TV -> Channels -> Enjoy!" -ForegroundColor White
Write-Host ""

Read-Host "Press Enter to exit"