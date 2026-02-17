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

# â”€â”€ Step 1: Fetch playlists â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

# â”€â”€ Step 2: Load iptv-org channel database (id, name, lang) â”€â”€
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

# â”€â”€ Step 3: Load iptv-org EPG channels (site, site_id) â”€â”€â”€â”€â”€â”€â”€
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

# â”€â”€ Step 4: Enrich and send to epg-fetcher â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
