# DR Lyd for Omarchy

Afspil DR's live radiokanaler (P1, P2, P3, P6 Beat, P8 Jazz, LYD ekstra og alle
regionale P4/P5-kanaler) direkte fra Omarchy-baren.

## Funktioner

- Klik på DR-ikonet i baren → panel med alle kanaler, grupperet i
  Favoritter / Landsdækkende / P4 regional / P5 regional
- Klik på en kanal for at afspille, klik igen for at stoppe
- Hjerte-knap på hver kanal markerer den som favorit (vises øverst)
- Midterklik på ikonet starter/stopper den sidst afspillede kanal
- Hover over ikonet viser hvad der spiller
- Afspilning via `mpv`; med `mpv-mpris` installeret dukker kanalen op i
  Omarchys Media-widget og kan styres med medietaster
- Ikonet følger barens tema (monokromt, farves med barens forgrundsfarve)

## Krav

- `mpv` (afspilning)
- `curl` (henter kanallisten)
- `mpv-mpris` (valgfrit — MPRIS-integration med `omarchy.media` og medietaster)

```bash
omarchy pkg add mpv mpv-mpris
```

## Installation

```bash
omarchy plugin add https://github.com/subjektivdk/omarchy-dr-lyd
omarchy plugin enable dk.mtj.dr-lyd
```

Widgeten lægger sig i barens højre sektion. Flyt den med
`omarchy bar move dk.mtj.dr-lyd --section <left|center|right>`.

## Indstillinger

Sættes i `~/.config/omarchy/shell.json` på widgetens entry, eller via
`omarchy bar set dk.mtj.dr-lyd <key> <value>`:

| Nøgle            | Standard | Beskrivelse                                                                 |
|------------------|----------|-----------------------------------------------------------------------------|
| `defaultChannel` | `p6beat` | Kanal-slug fra `dr.dk/lyd/<slug>`. Bruges indtil en kanal er blevet afspillet |
| `quality`        | `High`   | `Low` eller `High` — foretrukken MP3-bitrate                                 |

Favoritter og sidst afspillede kanal gemmes i
`~/.local/state/omarchy/settings/dr-lyd.json`.

## Sådan virker det

Pluginnet henter `https://www.dr.dk/lyd/p1` og læser kanalkataloget ud af
sidens indlejrede `__NEXT_DATA__`-JSON (ét kald giver alle kanaler med deres
HLS- og ICY/MP3-stream-URL'er). DR udstiller ikke en dokumenteret offentlig API
til dette, så ændrer DR deres frontend, kan parsingen holde op med at virke —
panelet viser i så fald en fejl og prøver igen.

## Udvikling

```bash
omarchy plugin validate ~/.config/omarchy/plugins/dr-lyd
omarchy restart shell   # QML-ændringer i bar-widgets kræver en genstart
```

## Licens

MIT — se [LICENSE](LICENSE).
