# DR Lyd for Omarchy

Play DR's live radio channels (P1, P2, P3, P6 Beat, P8 Jazz, LYD ekstra and all
regional P4/P5 channels) straight from the Omarchy bar.

## Features

- Click the DR icon in the bar → panel with all channels, grouped into
  Favorites / Nationwide / P4 regional / P5 regional
- Click a channel to play it, click again to stop
- A heart button on each channel marks it as a favorite (shown at the top);
  the +/− on each heading expands or collapses that group
- The panel header shows the playing channel and the track on air
- Keyboard: ↑/↓ or j/k move, Enter/Space plays a channel or opens/closes a
  group, `f` toggles favorite, `r` refreshes, `s` stops, `c`/`p` switch
  between the Channels and History tabs, Esc closes
- **History**: the panel's *History* tab lists the tracks you have listened
  to, grouped by day, with channel and programme. Click or Enter copies
  "Artist – Title"; the export button (`e`) writes it all to
  `~/dr-lyd-history.md`. Logged to SQLite, see [Listening history](#listening-history)
- Middle-click the icon to start/stop the last played channel
- Hovering the icon shows the channel and the track currently playing
  (artist – title; talk channels like P1 show only the channel). If DR's
  own log lags by more than a minute, the age is shown next to it (e.g.
  "4 min ago") — that's a warning that the track may be stale, not a bug
  in the plugin
- Right-click the icon to copy "Artist – Title" to the clipboard
  (only active when there is a now-playing track)
- Playback via `mpv`; with `mpv-mpris` installed the channel shows up in
  Omarchy's Media widget and can be controlled with media keys
- The icon follows the bar theme (monochrome, tinted with the bar's foreground color)

## Requirements

- `mpv` (playback)
- `curl` (fetches the channel list)
- `sqlite3` (listening history; part of Arch's `sqlite` package, installed by default)
- `mpv-mpris` (optional — MPRIS integration with `omarchy.media` and media keys)

```bash
omarchy pkg add mpv mpv-mpris
```

## Installation

```bash
omarchy plugin add https://github.com/subjektivdk/omarchy-dr-lyd
omarchy plugin enable subjektivdk.dr-lyd
```

The widget goes in the bar's right section. Move it with
`omarchy bar move subjektivdk.dr-lyd --section <left|center|right>`.

## Settings

Set in `~/.config/omarchy/shell.json` on the widget's entry, or via
`omarchy bar set subjektivdk.dr-lyd <key> <value>`:

| Key              | Default  | Description                                                                  |
|------------------|----------|------------------------------------------------------------------------------|
| `defaultChannel` | `p6beat` | Channel slug from `dr.dk/lyd/<slug>`. Used until a channel has been played   |
| `quality`        | `High`   | `Low` or `High` — preferred MP3 bitrate                                      |
| `logHistory`     | `true`   | Log the tracks you listen to (see below)                                     |
| `historyDays`    | `0`      | Delete logged tracks older than this many days at shell start; `0` keeps all |
| `backfillFrom`   | `Programme` | How far back refresh fills history: `Programme`, `Hour` or `Listened`     |

Favorites and the last played channel are stored in
`~/.local/state/omarchy/settings/dr-lyd.json`.

## How it works

The plugin fetches `https://www.dr.dk/lyd/p1` and reads the channel directory
out of the page's embedded `__NEXT_DATA__` JSON (one request returns every
channel with its HLS and ICY/MP3 stream URLs). DR does not expose a documented
public API for this, so if DR changes its frontend the parsing may stop
working — the panel then shows an error and retries.

"Now playing" comes from `https://www.dr.dk/lyd/playlister/<slug>` the same
way (`playlistIndexPoints` in the page's JSON). It is only fetched while a
channel is playing, and the next lookup is timed for when the track is
expected to end (at least 15 s between lookups). The last known track is
shown for up to 5 minutes after it should have ended — normal breaks between
tracks (jingles, traffic, weather, the host talking) are usually shorter than
that. If the lookup fails, or the channel has no playlist (LYD ekstra), only
the channel name is shown. The refresh button in the panel header refreshes both
the channel list and the now-playing lookup immediately, without waiting for
the scheduled poll.

## Listening history

The playlist page lists every track of the programme on air, so each
now-playing lookup also logs the tracks that overlap your listening session —
including short ones that started and ended between two lookups, but not the
programme's earlier tracks from before you tuned in. When a session ends
(stop, switching channel, or a stream that can't be restarted) the plugin
keeps looking up that channel once a minute until DR has listed the track
that was on air at the end — DR lists tracks a few minutes after they start —
for at most 10 minutes. No extra requests are made while playing.

The open session is saved to the state file with a 30-second heartbeat, so a
session cut short by a shell restart, plugin reload or crash is finished the
same way on the next start.

The refresh button (`r`) also backfills: while a channel plays, it re-reads
DR's playlists for that channel up to now — including earlier programmes,
which have their own playlist pages — and logs anything missing. It starts
from the first track logged on the channel today (or the session start),
widened by `backfillFrom` to the start of that programme (e.g. all of
Morgenbeatet), the top of that hour, or not at all (`Listened`). That fills
gaps from outages, but also logs what aired while you weren't listening.

Tracks go to `~/.local/state/omarchy/dr-lyd/history.sqlite` via the `sqlite3`
CLI, one row per track (`channel`, `played_at` as Unix seconds, `duration_ms`,
`artist`, `title`, `track_urn`, `programme`):

```bash
sqlite3 ~/.local/state/omarchy/dr-lyd/history.sqlite \
  "SELECT datetime(played_at, 'unixepoch', 'localtime'), channel, artist, title
   FROM plays ORDER BY played_at DESC LIMIT 20"
```

The bundled `claude-skill/bin/history.py` lists, searches and exports it
without writing any SQL:

```bash
history.py list 7 p6beat                  # last week on P6 Beat
history.py search "sort sol"              # artist, title or programme
history.py export ~/dr-lyd-history.md 30  # Markdown, per day; 0 days = everything
```

## Remote control

The plugin can be controlled from outside via the Omarchy shell's IPC, without
opening the panel:

```bash
omarchy-shell subjektivdk.dr-lyd list           # slug<TAB>title for all known channels
omarchy-shell subjektivdk.dr-lyd play <slug>     # switch to a channel, e.g. p1, p3, p6beat
omarchy-shell subjektivdk.dr-lyd stop            # stop playback
omarchy-shell subjektivdk.dr-lyd status          # slug<TAB>title for what's playing, or "stopped"
```

`play` with an unknown slug returns `unknown channel: <slug>`. If the channel
list hasn't been fetched yet, `list`/`play` return `loading channel directory,
retry shortly` — try again in a few seconds.

## Claude Code skill

[`claude-skill/`](claude-skill) is a [Claude Code](https://claude.com/claude-code)
skill built on the remote control above. It lets Claude switch, stop or check
the channel ("skift til P1", "sluk radioen"), look up what you listened to
("hvad hørte jeg i går") and what has been played
recently. Link it into your skills directory so it updates with the plugin:

```bash
ln -s ~/.config/omarchy/plugins/subjektivdk.dr-lyd/claude-skill ~/.claude/skills/dr-lyd
```

## Development

```bash
omarchy plugin validate ~/.config/omarchy/plugins/subjektivdk.dr-lyd
omarchy restart shell   # QML changes in bar widgets require a restart
```

## License

MIT — see [LICENSE](LICENSE).
