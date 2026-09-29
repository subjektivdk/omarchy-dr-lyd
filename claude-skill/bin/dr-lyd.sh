#!/bin/bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: dr-lyd.sh <play <slug>|stop|status|list|playlist [slug] [minutes]|history [days] [slug]|search <text> [days] [slug]|export [file] [days] [slug]>

  play <slug>          Start playing the given DR channel (slug from 'list').
  stop                 Stop playback.
  status               Show what's playing now (slug<TAB>title, or "stopped").
  list                 List known channels as slug<TAB>title lines.
  playlist [slug] [minutes]
                       Recent tracks (HH:MM<TAB>artist – title), newest last.
                       Defaults to the currently playing channel and 60 min.
  history [days] [slug]
                       Tracks you actually listened to, from the plugin's own
                       log (YYYY-MM-DD HH:MM<TAB>slug<TAB>artist – title<TAB>programme),
                       oldest first. Defaults to the last 1 day; 0 = everything.
  search <text> [days] [slug]
                       Same, only rows whose artist, title or programme contain
                       <text> (case-insensitive). Defaults to all history.
  export [file] [days] [slug]
                       Write the history as Markdown, grouped per day, newest
                       first. Defaults to ~/dr-lyd-history.md and all history.
USAGE
}

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $# -ge 1 ]] || { usage >&2; exit 1; }

case "$1" in
  play)
    [[ $# -eq 2 ]] || { usage >&2; exit 1; }
    omarchy-shell subjektivdk.dr-lyd play "$2"
    ;;
  stop)
    omarchy-shell subjektivdk.dr-lyd stop
    ;;
  status)
    omarchy-shell subjektivdk.dr-lyd status
    ;;
  list)
    omarchy-shell subjektivdk.dr-lyd list
    ;;
  playlist)
    slug="${2:-}"
    minutes="${3:-60}"
    if [[ -z $slug ]]; then
      status=$(omarchy-shell subjektivdk.dr-lyd status)
      slug="${status%%$'\t'*}"
      [[ -n $slug && $slug != "stopped" ]] || { echo "no channel playing — specify a slug" >&2; exit 1; }
    fi
    python3 "$BIN_DIR/playlist.py" "$slug" "$minutes"
    ;;
  history)
    python3 "$BIN_DIR/history.py" list "${@:2}"
    ;;
  search)
    [[ $# -ge 2 ]] || { usage >&2; exit 1; }
    python3 "$BIN_DIR/history.py" search "${@:2}"
    ;;
  export)
    python3 "$BIN_DIR/history.py" export "${@:2}"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
