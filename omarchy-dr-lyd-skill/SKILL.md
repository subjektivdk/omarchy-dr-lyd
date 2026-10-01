---
name: dr-lyd
description: Switch, stop, or check DR's live radio channels (P1-P8, regional P4/P5, LYD ekstra) playing via the DR Lyd Omarchy bar plugin, and look up what's been played recently. Use when the user asks to play/skift/switch radio or a DR channel by name (e.g. "skift til P1", "spil P3", "put on some radio", "hvad kører der på radioen", "sluk radioen", "hvad er der spillet den sidste time", "playlist for p6", "hvad hørte jeg i går", "hvad var det for en sang jeg hørte i morges", "hvornår hørte jeg sidst Sort Sol", "eksportér min radiohistorik").
---

# DR Lyd

Controls the DR Lyd Omarchy bar widget (`~/.config/omarchy/plugins/subjektivdk.dr-lyd/`), which plays DR's live radio channels via `mpv`. This talks to the already-running Omarchy shell over IPC — nothing is started or duplicated here.

## Commands

All via `~/.claude/skills/dr-lyd/bin/dr-lyd.sh`:

- `dr-lyd.sh list` — lists known channels as `slug<TAB>title` lines.
- `dr-lyd.sh play <slug>` — switches to that channel (stops whatever's playing first).
- `dr-lyd.sh stop` — stops playback.
- `dr-lyd.sh status` — shows what's playing now (`slug<TAB>title`, or `stopped`).
- `dr-lyd.sh history [days] [slug]` — tracks the user actually listened to, from the plugin's own sqlite log: `YYYY-MM-DD HH:MM<TAB>slug<TAB>artist – title<TAB>programme` lines, oldest first. `days` defaults to 1 (`0` = everything); `slug` filters to one channel.
- `dr-lyd.sh search <text> [days] [slug]` — same output, only rows whose artist, title or programme contain `<text>` (case-insensitive for ASCII; `%`/`_` are literal). Searches all history by default.
- `dr-lyd.sh clear --yes` — deletes the entire listening history. Irreversible: only run it when the user has explicitly asked to clear/delete their radio history in this conversation, and confirm with them first unless they already said to go ahead. Suggest `export` first if they might want a copy.
- `dr-lyd.sh export [file] [days] [slug]` — writes the history as Markdown (one `##` heading per day, days and tracks newest first, table of time/channel/artist/title/programme). Defaults to `~/dr-lyd-history.md` and all history; add `--dates YYYY-MM-DD,...` to export only those days (the panel's export button does this with the days expanded there). Prints `exported N tracks to <file>`.
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

## Listening history

The plugin logs every track that overlaps a listening session to `~/.local/state/omarchy/dr-lyd/history.sqlite`, so the history goes back as far as the user has been listening (unless the `historyDays` setting prunes it). The panel's refresh button also backfills the playing channel — by default the whole programme the user first tuned into that day (setting `backfillFrom`: `Programme`/`Hour`/`Listened`) — so the history can include tracks that aired around, not only during, their listening; say "played while you were listening to P6" rather than claiming they heard every row. Use it for anything about what the user *heard*; use `playlist` only for what DR is airing now/recently, since it covers just the current programme and includes tracks the user didn't hear.

Pick the command by the question:

- **Time-based** ("hvad hørte jeg i går", "hvad var sangen i morges på P6") → `history <days> [slug]`, then pick the rows by timestamp yourself ("i morges" = today before noon, "i går" = yesterday's date). Ask for enough days to cover the period — `history` counts back from now, so "i går" needs `2`.
- **Artist/title/programme** ("hvornår hørte jeg sidst Sort Sol", "har jeg hørt Teardrop", "hvad spillede de i Morgenbeatet") → `search <text>`. Search on the most distinctive word if the full name gives nothing (spelling, "The", accents — non-ASCII letters like æøå match case-sensitively).
- **Overview / stats** ("hvad hører jeg mest", "hvilke kunstnere i denne uge") → `history 7` (or `0`) and count/summarise the rows yourself; don't paste hundreds of rows back.
- **Export** ("eksportér historikken", "gem det som markdown") → `export`, with a file path only if the user named one. Report the path and count from its output. The panel's export button (`e` in the History tab) runs the same export.

```bash
~/.claude/skills/dr-lyd/bin/dr-lyd.sh history 2               # today + yesterday, all channels
~/.claude/skills/dr-lyd/bin/dr-lyd.sh search "sort sol"       # every time it was heard
~/.claude/skills/dr-lyd/bin/dr-lyd.sh search teardrop 7 p6beat
~/.claude/skills/dr-lyd/bin/dr-lyd.sh export                  # ~/dr-lyd-history.md
~/.claude/skills/dr-lyd/bin/dr-lyd.sh export ~/Documents/radio.md 30
```

Answer in the user's language with local times as printed, and name the channel by its title (`p6beat` → P6 Beat; `list` has the titles). `no listening history yet` means logging is off (`logHistory` setting) or nothing has been played since the feature was installed; `no tracks …` means the filter matched nothing — widen `days` or loosen the search before saying it wasn't heard.

## Errors

- No output / empty reply from `omarchy-shell` — the Omarchy shell isn't running, or the plugin's IPC handler hasn't loaded (needs `omarchy restart shell` after a plugin update). Say so rather than retrying silently.
- `unknown channel: <slug>` — the slug doesn't exist in the current directory; re-check with `list`.
