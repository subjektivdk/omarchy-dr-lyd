---
name: dr-lyd
description: Switch, stop, or check DR's live radio channels (P1-P8, regional P4/P5, LYD ekstra) playing via the DR Lyd Omarchy bar plugin, and look up what's been played recently. Use when the user asks to play/skift/switch radio or a DR channel by name (e.g. "skift til P1", "spil P3", "put on some radio", "hvad kører der på radioen", "sluk radioen", "hvad er der spillet den sidste time", "playlist for p6").
---

# DR Lyd

Controls the DR Lyd Omarchy bar widget (`~/.config/omarchy/plugins/dr-lyd/`), which plays DR's live radio channels via `mpv`. This talks to the already-running Omarchy shell over IPC — nothing is started or duplicated here.

## Commands

All via `~/.claude/skills/dr-lyd/bin/dr-lyd.sh`:

- `dr-lyd.sh list` — lists known channels as `slug<TAB>title` lines.
- `dr-lyd.sh play <slug>` — switches to that channel (stops whatever's playing first).
- `dr-lyd.sh stop` — stops playback.
- `dr-lyd.sh status` — shows what's playing now (`slug<TAB>title`, or `stopped`).
- `dr-lyd.sh playlist [slug] [minutes]` — recent tracks as `HH:MM<TAB>artist – title` lines, oldest first. `slug` defaults to whatever's currently playing (via `status`); `minutes` defaults to 60. Talk channels (P1, P2) and LYD ekstra have no playlist and print a note instead.

## Switching channel

Channel slugs (P4/P5 regional especially) aren't fixed or guessable — **always run `dr-lyd.sh list` first** and match the user's request against the returned titles, rather than guessing a slug. A few well-known ones: `p1`, `p2`, `p3`, `p6beat` (P6 Beat), `p8jazz` (P8 Jazz), and DR's own LYD-ekstra channels. Regional P4 (city/area) and P5 (region) channels only show up in `list`.

If `list` (or `play`) returns `loading channel directory, retry shortly`, the plugin hasn't fetched DR's channel directory yet — wait a couple of seconds and retry once.

Example: user says "skift til P1":
```bash
~/.claude/skills/dr-lyd/bin/dr-lyd.sh list       # confirm the exact slug, e.g. "p1"
~/.claude/skills/dr-lyd/bin/dr-lyd.sh play p1
```

## Recently played

For "hvad er der spillet den sidste time" / "what's been playing on P6" style questions, use `playlist` rather than `status` (which only has the current track):

```bash
~/.claude/skills/dr-lyd/bin/dr-lyd.sh playlist          # currently playing channel, last 60 min
~/.claude/skills/dr-lyd/bin/dr-lyd.sh playlist p3 30     # P3, last 30 min
```

This fetches `dr.dk/lyd/playlister/<slug>` directly (same source the plugin itself uses for now-playing) — it does not go through the running shell, so it works even if nothing is currently playing, as long as a slug is given explicitly.

## Errors

- No output / empty reply from `omarchy-shell` — the Omarchy shell isn't running, or the plugin's IPC handler hasn't loaded (needs `omarchy restart shell` after a plugin update). Say so rather than retrying silently.
- `unknown channel: <slug>` — the slug doesn't exist in the current directory; re-check with `list`.
