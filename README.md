# DR Lyd for Omarchy

Play DR's live radio channels (P1, P2, P3, P6 Beat, P8 Jazz, LYD ekstra and all
regional P4/P5 channels) straight from the Omarchy bar.

## Features

- Click the DR icon in the bar → panel with all channels, grouped into
  Favorites / Nationwide / P4 regional / P5 regional
- Click a channel to play it, click again to stop
- A heart button on each channel marks it as a favorite (shown at the top)
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
the channel name is shown. The ↻ button in the panel header refreshes both
the channel list and the now-playing lookup immediately, without waiting for
the scheduled poll.

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

## Development

```bash
omarchy plugin validate ~/.config/omarchy/plugins/subjektivdk.dr-lyd
omarchy restart shell   # QML changes in bar widgets require a restart
```

## License

MIT — see [LICENSE](LICENSE).
