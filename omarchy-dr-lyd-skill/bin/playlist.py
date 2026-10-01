#!/usr/bin/env python3
"""Recent tracks for a DR Lyd channel, scraped the same way the plugin
itself does: dr.dk/lyd/playlister/<slug> embeds the playlist as SSR JSON
in <script id="__NEXT_DATA__"> (props.pageProps.playlistIndexPoints).
DR doesn't publish a documented public API for this."""
import re
import json
import sys
import datetime
import urllib.request


def main():
    if len(sys.argv) < 2:
        print("usage: playlist.py <slug> [minutes]", file=sys.stderr)
        sys.exit(1)
    slug = sys.argv[1]
    minutes = int(sys.argv[2]) if len(sys.argv) > 2 else 60

    url = f"https://www.dr.dk/lyd/playlister/{slug}"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            html = r.read().decode("utf-8", "replace")
    except Exception as e:
        print(f"could not fetch playlist: {e}", file=sys.stderr)
        sys.exit(1)

    m = re.search(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', html, re.S)
    if not m:
        print("could not find playlist data on the page", file=sys.stderr)
        sys.exit(1)
    try:
        data = json.loads(m.group(1))
    except json.JSONDecodeError as e:
        print(f"could not parse playlist data: {e}", file=sys.stderr)
        sys.exit(1)

    points = (data.get("props", {}).get("pageProps", {}) or {}).get("playlistIndexPoints") or []
    now = datetime.datetime.now(datetime.timezone.utc)
    cutoff = now - datetime.timedelta(minutes=minutes)

    tracks = []
    for p in points:
        if p.get("type") != "Track" or not p.get("title"):
            continue
        played = p.get("playedTime")
        if not played:
            continue
        try:
            t = datetime.datetime.fromisoformat(played.replace("Z", "+00:00"))
        except ValueError:
            continue
        if t < cutoff or t > now:
            continue
        desc = (p.get("description") or "").strip()
        if not desc:
            roles = p.get("roles") or []
            desc = ", ".join(r.get("name", "") for r in roles if r.get("name"))
        tracks.append((t, desc, p["title"]))

    tracks.sort()
    if not tracks:
        print(f"no tracks found for {slug} in the last {minutes} min (talk channel, or no playlist)")
        return
    for t, artist, title in tracks:
        local = t.astimezone()
        line = f"{local.strftime('%H:%M')}\t{title}"
        if artist:
            line = f"{local.strftime('%H:%M')}\t{artist} – {title}"
        print(line)


if __name__ == "__main__":
    main()
