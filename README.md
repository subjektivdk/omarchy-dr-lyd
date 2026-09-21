# DR Lyd for Omarchy

Afspil DR's live radiokanaler (P1, P2, P3, P6 Beat, P8 Jazz, LYD ekstra og alle
regionale P4/P5-kanaler) direkte fra Omarchy-baren.

## Funktioner

- Klik på DR-ikonet i baren → panel med alle kanaler, grupperet i
  Favoritter / Landsdækkende / P4 regional / P5 regional
- Klik på en kanal for at afspille, klik igen for at stoppe
- Hjerte-knap på hver kanal markerer den som favorit (vises øverst)
- Midterklik på ikonet starter/stopper den sidst afspillede kanal
- Hover over ikonet viser kanalen og det nummer, der spiller lige nu
  (kunstner – titel; tale-kanaler som P1 viser kun kanalen). Halter DR's
  egen log mere end et minut, vises alderen ved siden af (fx "for 4 min.
  siden") — det er en advarsel om at nummeret kan være forældet, ikke en
  fejl i pluginet
- Højreklik på ikonet kopierer "Kunstner – Titel" til udklipsholderen
  (kun aktivt når der er et spiller nu-nummer)
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
omarchy plugin enable subjektivdk.dr-lyd
```

Widgeten lægger sig i barens højre sektion. Flyt den med
`omarchy bar move subjektivdk.dr-lyd --section <left|center|right>`.

## Indstillinger

Sættes i `~/.config/omarchy/shell.json` på widgetens entry, eller via
`omarchy bar set subjektivdk.dr-lyd <key> <value>`:

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

"Spiller nu" kommer fra `https://www.dr.dk/lyd/playlister/<slug>` på samme
måde (`playlistIndexPoints` i sidens JSON). Den hentes kun mens en kanal
afspilles, og næste opslag times til når nummeret forventes at slutte
(mindst 15 sek. mellem opslag). Sidste kendte nummer vises i op til 5
minutter efter det burde være slut — normale pauser mellem numre (jingle,
trafik, vejr, værten snakker) er typisk kortere end det. Går opslaget
galt, eller har kanalen ingen playliste (LYD ekstra), vises bare
kanalnavnet. ↻-knappen i panelets header genopfrisker både kanallisten og
spiller nu-opslaget med det samme, uden at vente på det planlagte poll.

## Udvikling

```bash
omarchy plugin validate ~/.config/omarchy/plugins/subjektivdk.dr-lyd
omarchy restart shell   # QML-ændringer i bar-widgets kræver en genstart
```

## Licens

MIT — se [LICENSE](LICENSE).
