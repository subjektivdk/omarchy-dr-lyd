#!/bin/bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: dr-lyd.sh <play <slug>|stop|status|list|playlist [slug] [minutes]>

  play <slug>          Start playing the given DR channel (slug from 'list').
  stop                 Stop playback.
  status               Show what's playing now (slug<TAB>title, or "stopped").
  list                 List known channels as slug<TAB>title lines.
  playlist [slug] [minutes]
                       Recent tracks (HH:MM<TAB>artist – title), newest last.
                       Defaults to the currently playing channel and 60 min.
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
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
