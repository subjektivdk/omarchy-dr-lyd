#!/usr/bin/env python3
"""Listening history logged by the DR Lyd plugin
(~/.local/state/omarchy/dr-lyd/history.sqlite, table `plays`).

  history.py list   [days] [slug]           tab-separated rows, oldest first
  history.py search <text> [days] [slug]    same, filtered on artist/title/programme
  history.py export [file] [days] [slug] [--dates YYYY-MM-DD,...]
                                            Markdown, per day, newest first;
                                            --dates limits it to those days
  history.py clear --yes                    delete the entire history

days = 0 means everything. The database is opened read-only except by
`clear`; otherwise the plugin is the only writer."""
import datetime
import os
import sqlite3
import subprocess
import sys
import time

DB = os.path.expanduser("~/.local/state/omarchy/dr-lyd/history.sqlite")
DEFAULT_EXPORT = os.path.expanduser("~/dr-lyd-history.md")


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def parse_days(value, default):
    if value in (None, ""):
        return default
    if not value.isdigit():
        die("days must be a whole number (0 = everything)")
    return int(value)


def fetch(days, slug, text=None):
    if not os.path.exists(DB):
        return None
    where, params = [], []
    if days > 0:
        where.append("played_at >= ?")
        params.append(int(datetime.datetime.now().timestamp()) - days * 86400)
    if slug:
        where.append("channel = ?")
        params.append(slug)
    if text:
        like = "%" + text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
        where.append("(artist LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\' OR programme LIKE ? ESCAPE '\\')")
        params += [like, like, like]
    sql = "SELECT played_at, channel, artist, title, programme, duration_ms FROM plays"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY played_at"
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=2)
    try:
        return con.execute(sql, params).fetchall()
    finally:
        con.close()


def channel_titles():
    # Pretty names ("P6 Beat") come from the running plugin; the slug is the
    # fallback when the shell isn't running or hasn't loaded the directory.
    # Right after a shell start the plugin answers "loading channel
    # directory, retry shortly" while it fetches; one retry covers that.
    out = ""
    for attempt in range(2):
        try:
            out = subprocess.run(["omarchy-shell", "subjektivdk.dr-lyd", "list"],
                                 capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return {}
        if not out.startswith("loading"):
            break
        time.sleep(2)
    titles = {}
    for line in out.splitlines():
        slug, sep, title = line.partition("\t")
        if sep:
            titles[slug] = title
    return titles


def track_text(artist, title):
    return f"{artist} – {title}" if artist else title


def local(ts):
    return datetime.datetime.fromtimestamp(ts)


def scope_text(days, slug, text=None):
    parts = []
    if text:
        parts.append(f'matching "{text}"')
    if slug:
        parts.append(f"on {slug}")
    parts.append(f"in the last {days} day(s)" if days > 0 else "in the history")
    return " ".join(parts)


def print_rows(rows, days, slug, text=None):
    if rows is None:
        print(f"no listening history yet ({DB} doesn't exist)")
        return
    if not rows:
        print(f"no tracks {scope_text(days, slug, text)}")
        return
    for played_at, channel, artist, title, programme, _ in rows:
        print("\t".join([local(played_at).strftime("%Y-%m-%d %H:%M"), channel,
                         track_text(artist, title), programme or ""]))


def md_cell(value):
    return str(value or "").replace("|", "\\|").replace("\n", " ")


def parse_dates(value):
    try:
        return sorted({datetime.date.fromisoformat(d.strip()) for d in value.split(",") if d.strip()}, reverse=True)
    except ValueError:
        die("--dates takes comma-separated YYYY-MM-DD dates")


def export(path, days, slug, dates=None):
    rows = fetch(days, slug)
    if rows is None:
        die(f"no listening history yet ({DB} doesn't exist)")
    if dates is not None:
        wanted = set(dates)
        rows = [r for r in rows if local(r[0]).date() in wanted]
        if not rows:
            die("no tracks on the selected days")
    titles = channel_titles()
    now = datetime.datetime.now()
    lines = ["# DR Lyd listening history", ""]
    if dates is not None:
        span = ", ".join(d.strftime("%-d %b %Y") for d in dates)
    else:
        span = f"last {days} day{'' if days == 1 else 's'}" if days > 0 else "all history"
    scope = [f"{len(rows)} track{'' if len(rows) == 1 else 's'}", span]
    if slug:
        scope.append(titles.get(slug, slug))
    lines.append(f"Exported {now.strftime('%Y-%m-%d %H:%M')} · " + " · ".join(scope))

    days_seen = {}
    for row in rows:
        days_seen.setdefault(local(row[0]).date(), []).append(row)
    for day in sorted(days_seen, reverse=True):
        lines += ["", f"## {day.strftime('%A %-d %B %Y')}", "",
                  "| Time | Channel | Artist | Title | Programme |",
                  "|------|---------|--------|-------|-----------|"]
        # Newest first within the day too, matching the panel.
        for played_at, channel, artist, title, programme, _ in reversed(days_seen[day]):
            lines.append("| " + " | ".join(md_cell(v) for v in [
                local(played_at).strftime("%H:%M"), titles.get(channel, channel),
                artist, title, programme]) + " |")

    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)
    print(f"exported {len(rows)} tracks to {path}")


def main():
    args = sys.argv[1:]
    if not args:
        die(__doc__)
    cmd, rest = args[0], args[1:]
    if cmd == "list":
        days = parse_days(rest[0] if rest else None, 1)
        slug = rest[1] if len(rest) > 1 else ""
        print_rows(fetch(days, slug), days, slug)
    elif cmd == "search":
        if not rest or not rest[0].strip():
            die("usage: history.py search <text> [days] [slug]")
        text = rest[0].strip()
        days = parse_days(rest[1] if len(rest) > 1 else None, 0)
        slug = rest[2] if len(rest) > 2 else ""
        print_rows(fetch(days, slug, text), days, slug, text)
    elif cmd == "clear":
        if rest != ["--yes"]:
            die("refusing to clear without --yes (deletes the entire listening history)")
        if not os.path.exists(DB):
            print("no listening history to clear")
            return
        con = sqlite3.connect(DB, timeout=2)
        try:
            with con:
                n = con.execute("DELETE FROM plays").rowcount
        finally:
            con.close()
        print(f"deleted {n} tracks from the listening history")
    elif cmd == "export":
        dates = None
        if "--dates" in rest:
            i = rest.index("--dates")
            if i + 1 >= len(rest):
                die("--dates needs a value")
            dates = parse_dates(rest[i + 1])
            rest = rest[:i] + rest[i + 2:]
        path = os.path.expanduser(rest[0]) if rest and rest[0] else DEFAULT_EXPORT
        days = parse_days(rest[1] if len(rest) > 1 else None, 0)
        slug = rest[2] if len(rest) > 2 else ""
        export(path, days, slug, dates)
    else:
        die(__doc__)


if __name__ == "__main__":
    main()
