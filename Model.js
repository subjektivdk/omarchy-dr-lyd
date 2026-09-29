// Parsing and lookup helpers for DR Lyd's channel directory.
//
// dr.dk/lyd/<slug> is a Next.js page that embeds the full channel directory
// (every live channel, not just the one the URL names) as SSR JSON in
// <script id="__NEXT_DATA__">. That JSON is the only source of stream URLs
// used here: DR does not publish a documented public API for this.

function extractNextData(html) {
  var match = /<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/.exec(String(html || ""))
  if (!match) return null
  try {
    return JSON.parse(match[1])
  } catch (e) {
    return null
  }
}

function isRadioChannel(entry) {
  if (!entry || typeof entry !== "object") return false
  if (!entry.slug || !Array.isArray(entry.audioAssets) || entry.audioAssets.length === 0) return false
  if (entry.type && entry.type !== "Channel") return false
  var title = String(entry.title || "")
  // DR's directory also lists internal/technical feeds (webcam preview
  // streams like "P3webcam", MCR monitoring feeds). Real radio channels are
  // titled "P<n>" or "P<n> <district>" (a digit followed by whitespace or
  // end of string — "P3webcam" fails that) or "LYD ekstra*", AND actually
  // carry an ICY (MP3) stream, which the webcam/monitoring feeds never do.
  var titleLooksLikeRadio = /^P\d(\s|$)/i.test(title) || /^LYD ekstra/i.test(title)
  return titleLooksLikeRadio && hasIcyAsset(entry)
}

function hasIcyAsset(entry) {
  for (var i = 0; i < entry.audioAssets.length; i++) {
    var asset = entry.audioAssets[i]
    if (asset && asset.format === "ICY" && asset.target === "Stream" && isHttpUrl(asset.url)) return true
  }
  return false
}

// Stream URLs come from DR's page and end up as an mpv argument. Only
// http(s) is ever expected; anything else (a path, or a string starting
// with "--" that mpv would read as an option) is dropped here.
function isHttpUrl(url) {
  return /^https?:\/\/\S+$/i.test(String(url || ""))
}

function assetsBySlug(entry) {
  var hlsUrl = ""
  var icyLow = null
  var icyHigh = null
  for (var i = 0; i < entry.audioAssets.length; i++) {
    var asset = entry.audioAssets[i]
    if (!asset || asset.target !== "Stream" || !isHttpUrl(asset.url)) continue
    if (asset.format === "HLS" && !hlsUrl) {
      hlsUrl = asset.url
    } else if (asset.format === "ICY") {
      var bitrate = asset.bitrate || 0
      if (!icyLow || bitrate < icyLow.bitrate) icyLow = { url: asset.url, bitrate: bitrate }
      if (!icyHigh || bitrate > icyHigh.bitrate) icyHigh = { url: asset.url, bitrate: bitrate }
    }
  }
  return {
    hlsUrl: hlsUrl,
    icyLowUrl: icyLow ? icyLow.url : "",
    icyHighUrl: icyHigh ? icyHigh.url : ""
  }
}

// DR titles a few channels by number only ("P6", "P8"); these are the names
// they are actually known by. Anything not listed keeps DR's own title.
var DISPLAY_NAMES = {
  p6beat: "P6 Beat",
  p8jazz: "P8 Jazz"
}

function displayTitle(entry) {
  return DISPLAY_NAMES[entry.slug] || String(entry.title || entry.slug)
}

// Walks the whole __NEXT_DATA__ tree (channel entries can sit at the top
// level or nested under a region's "districts" list) and returns a flat,
// deduplicated list of radio channels.
function parseChannelsFromNextData(data) {
  var seen = {}
  var out = []

  function walk(node) {
    if (!node || typeof node !== "object") return
    if (Array.isArray(node)) {
      for (var i = 0; i < node.length; i++) walk(node[i])
      return
    }
    if (isRadioChannel(node) && !seen[node.slug]) {
      seen[node.slug] = true
      var assets = assetsBySlug(node)
      out.push({
        slug: node.slug,
        title: displayTitle(node),
        hlsUrl: assets.hlsUrl,
        icyLowUrl: assets.icyLowUrl,
        icyHighUrl: assets.icyHighUrl
      })
    }
    for (var key in node) walk(node[key])
  }

  walk(data)
  return out
}

function parseChannelsFromHtml(html) {
  var data = extractNextData(html)
  if (!data) return []
  return parseChannelsFromNextData(data)
}

function streamUrlFor(channel, quality) {
  if (!channel) return ""
  if (quality === "Low") {
    return channel.icyLowUrl || channel.icyHighUrl || channel.hlsUrl || ""
  }
  return channel.icyHighUrl || channel.icyLowUrl || channel.hlsUrl || ""
}

// dr.dk/lyd/playlister/<slug> embeds the channel's recent tracks the same
// way (props.pageProps.playlistIndexPoints). The newest "Track" that has
// already started is what's on air. Talk channels have no tracks at all,
// and on mixed channels the host talks between songs, so a track that has
// run past its duration plus some slack is not reported either.
var NOW_PLAYING_GRACE_MS = 300000

function parseNowPlayingFromHtml(html, nowMs) {
  var data = extractNextData(html)
  var props = data && data.props && data.props.pageProps
  var points = props && props.playlistIndexPoints
  if (!Array.isArray(points)) return null

  var latest = null
  for (var i = 0; i < points.length; i++) {
    var track = trackFromPoint(points[i])
    if (!track || track.startedAt > nowMs) continue
    if (!latest || track.startedAt > latest.startedAt) latest = track
  }
  if (latest && latest.endsAt && nowMs > latest.endsAt + NOW_PLAYING_GRACE_MS) return null
  return latest
}

// One playlist entry as the plugin uses it, or null for anything that
// isn't a usable track (jingles, entries without a title or timestamp).
function trackFromPoint(point) {
  if (!point || point.type !== "Track" || !point.title) return null
  var startedAt = Date.parse(point.playedTime)
  if (isNaN(startedAt)) return null
  var duration = Number(point.durationMilliseconds) || 0
  return {
    title: String(point.title),
    artist: artistOf(point),
    startedAt: startedAt,
    durationMs: duration,
    endsAt: duration > 0 ? startedAt + duration : 0,
    trackUrn: String(point.trackUrn || "")
  }
}

// DR's `description` is the artist line as they present it ("A og B");
// the roles list is the structured fallback.
function artistOf(point) {
  var description = String(point.description || "").trim()
  if (description) return description
  var names = []
  var roles = Array.isArray(point.roles) ? point.roles : []
  for (var i = 0; i < roles.length; i++)
    if (roles[i] && roles[i].name) names.push(String(roles[i].name))
  return names.join(", ")
}

function nowPlayingText(track) {
  if (!track) return ""
  return track.artist ? track.artist + " – " + track.title : track.title
}

// How long ago the shown track should have ended — i.e. how stale it might
// be, since DR hasn't logged anything newer. Empty while it's still
// plausibly playing (or duration is unknown) so most tracks show no age at
// all; only flagged once DR's log is at least a minute behind.
function nowPlayingAgeText(track, nowMs) {
  if (!track || !track.endsAt) return ""
  var staleMs = nowMs - track.endsAt
  if (staleMs < 60000) return ""
  return Math.floor(staleMs / 60000) + " min ago"
}

// Poll again just after the current track should end. With no track (or no
// usable duration) check back regularly. Bounded so a bogus duration can
// neither hammer dr.dk nor go quiet for the rest of the show.
function nowPlayingPollDelay(track, nowMs) {
  var delay = 60000
  if (track && track.endsAt) delay = track.endsAt - nowMs + 5000
  return Math.min(Math.max(delay, 15000), 300000)
}

function regionOf(slug) {
  if (/^p4/i.test(slug)) return "p4"
  if (/^p5/i.test(slug)) return "p5"
  return ""
}

// Groups the flat channel list for display: favorited channels first (in
// their own heading, removed from their regular group below), then
// nationwide channels, then the two regional families each collapsed under
// one heading.
function groupChannels(channels, favoriteSlugs) {
  var favSet = {}
  var favs = Array.isArray(favoriteSlugs) ? favoriteSlugs : []
  for (var f = 0; f < favs.length; f++) favSet[favs[f]] = true

  var favorites = []
  var rest = []
  for (var i = 0; i < channels.length; i++) {
    if (favSet[channels[i].slug]) favorites.push(channels[i])
    else rest.push(channels[i])
  }

  var national = []
  var p4 = []
  var p5 = []

  for (var j = 0; j < rest.length; j++) {
    var ch = rest[j]
    var region = regionOf(ch.slug)
    if (region === "p4") p4.push(ch)
    else if (region === "p5") p5.push(ch)
    else national.push(ch)
  }

  function byTitle(a, b) { return a.title.localeCompare(b.title) }
  favorites.sort(byTitle)
  national.sort(byTitle)
  p4.sort(byTitle)
  p5.sort(byTitle)

  // `key` is the stable id the panel remembers collapse state under; the
  // ten-channel regional families start collapsed so favorites and the
  // nationwide channels fit without scrolling.
  var groups = []
  if (favorites.length) groups.push({ key: "favorites", label: "Favorites", items: favorites, defaultCollapsed: false })
  if (national.length) groups.push({ key: "national", label: "Nationwide", items: national, defaultCollapsed: false })
  if (p4.length) groups.push({ key: "p4", label: "P4 regional", items: p4, defaultCollapsed: true })
  if (p5.length) groups.push({ key: "p5", label: "P5 regional", items: p5, defaultCollapsed: true })
  return groups
}

// Parses the plugin's persisted state file (favorites, last played channel,
// which groups the user has expanded/collapsed). Missing/corrupt state is
// treated as "nothing saved yet".
function parseStateFile(raw) {
  var favorites = []
  var lastPlayed = ""
  var groups = {}
  var openSession = null
  try {
    var parsed = JSON.parse(String(raw || ""))
    if (parsed && Array.isArray(parsed.favorites))
      favorites = parsed.favorites.filter(function(s) { return typeof s === "string" && s })
    if (parsed && typeof parsed.lastPlayed === "string") lastPlayed = parsed.lastPlayed
    if (parsed && parsed.groups && typeof parsed.groups === "object" && !Array.isArray(parsed.groups)) {
      for (var key in parsed.groups)
        if (typeof parsed.groups[key] === "boolean") groups[key] = parsed.groups[key]
    }
    var o = parsed && parsed.openSession
    if (o && typeof o.slug === "string" && o.slug && Number(o.startedAt) > 0 && Number(o.lastSeenAt) >= Number(o.startedAt))
      openSession = { slug: o.slug, startedAt: Number(o.startedAt), lastSeenAt: Number(o.lastSeenAt) }
  } catch (e) {
    // First run or corrupt file: fall back to empty state.
  }
  return { favorites: favorites, lastPlayed: lastPlayed, groups: groups, openSession: openSession }
}

// ---- Listening history ----
// The playlist page lists every track of the programme on air, not just the
// current one, so each now-playing lookup doubles as a history source: the
// tracks that overlap the listening session are logged, including short
// ones that started and ended between two polls. Tracks from before the
// session started (the programme's earlier songs) are not.
// With `firstLoggedMs` (backfill) tracks that started at or after that
// already-logged track count too, even outside the session: they fill gaps
// without reaching back to songs that merely overlapped its start.
function tracksForLog(html, sessionStartMs, untilMs, firstLoggedMs) {
  var data = extractNextData(html)
  var props = data && data.props && data.props.pageProps
  var points = props && props.playlistIndexPoints
  if (!Array.isArray(points) || !sessionStartMs) return []
  var programmes = programmesOf(props.schedule)
  var out = []
  for (var i = 0; i < points.length; i++) {
    var track = trackFromPoint(points[i])
    if (!track || track.startedAt > untilMs) continue
    // Unknown duration: only count it if it started while listening.
    var lastHeardAt = track.endsAt || track.startedAt
    var inGap = firstLoggedMs > 0 && track.startedAt >= firstLoggedMs
    if (lastHeardAt < sessionStartMs && !inGap) continue
    track.programme = programmeAt(programmes, track.startedAt)
    out.push(track)
  }
  return out
}

function programmesOf(schedule) {
  var items = schedule && Array.isArray(schedule.items) ? schedule.items : []
  var out = []
  for (var i = 0; i < items.length; i++) {
    var item = items[i]
    var start = Date.parse(item && item.startTime)
    var end = Date.parse(item && item.endTime)
    if (!item || !item.title || isNaN(start) || isNaN(end)) continue
    out.push({ title: String(item.title), start: start, end: end })
  }
  return out
}

function programmeAt(programmes, ms) {
  for (var i = 0; i < programmes.length; i++)
    if (ms >= programmes[i].start && ms < programmes[i].end) return programmes[i].title
  return ""
}

// SQL is handed to the sqlite3 CLI as a single argv entry (no shell), so
// the only thing that needs escaping is the quote of the string literal.
function sqlString(value) {
  return "'" + String(value).replace(/'/g, "''") + "'"
}

var HISTORY_SCHEMA_SQL =
  "CREATE TABLE IF NOT EXISTS plays(" +
  "id INTEGER PRIMARY KEY, channel TEXT NOT NULL, played_at INTEGER NOT NULL, " +
  "duration_ms INTEGER, artist TEXT, title TEXT NOT NULL, track_urn TEXT, programme TEXT, " +
  "UNIQUE(channel, played_at, title));" +
  "CREATE INDEX IF NOT EXISTS plays_by_time ON plays(played_at DESC);"

// One statement per batch: the tracks travel as a JSON array literal and
// json_each unpacks them, so a lookup costs one sqlite3 run no matter how
// many tracks it returned. UNIQUE + OR IGNORE makes re-logging the same
// playlist (every poll sees it again) a no-op.
function historyInsertSql(slug, tracks) {
  if (!slug || !tracks || tracks.length === 0) return ""
  var rows = []
  for (var i = 0; i < tracks.length; i++) {
    var t = tracks[i]
    rows.push({
      channel: slug,
      played_at: Math.floor(t.startedAt / 1000),
      duration_ms: t.durationMs || null,
      artist: t.artist || null,
      title: t.title,
      track_urn: t.trackUrn || null,
      programme: t.programme || null
    })
  }
  return HISTORY_SCHEMA_SQL +
    "INSERT OR IGNORE INTO plays(channel, played_at, duration_ms, artist, title, track_urn, programme) " +
    "SELECT json_extract(value,'$.channel'), json_extract(value,'$.played_at'), " +
    "json_extract(value,'$.duration_ms'), json_extract(value,'$.artist'), json_extract(value,'$.title'), " +
    "json_extract(value,'$.track_urn'), json_extract(value,'$.programme') " +
    "FROM json_each(" + sqlString(JSON.stringify(rows)) + ");"
}

function historyPruneSql(days) {
  var n = Math.floor(Number(days) || 0)
  if (n <= 0) return ""
  return HISTORY_SCHEMA_SQL +
    "DELETE FROM plays WHERE played_at < CAST(strftime('%s','now') AS INTEGER) - " + (n * 86400) + ";"
}

function historySelectSql(limit) {
  return "SELECT id, channel, played_at, artist, title, programme FROM plays " +
    "ORDER BY played_at DESC LIMIT " + Math.max(1, Math.floor(Number(limit) || 100)) + ";"
}

// `sqlite3 -json` prints nothing at all for zero rows (and for a database
// that doesn't exist yet), so empty/garbled output is just "no history".
function parseHistoryRows(raw) {
  try {
    var rows = JSON.parse(String(raw || ""))
    return Array.isArray(rows) ? rows : []
  } catch (e) {
    return []
  }
}

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

function historyTimeText(row) {
  var d = new Date(Number(row.played_at) * 1000)
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

function historyTrackText(row) {
  return row.artist ? row.artist + " – " + row.title : String(row.title || "")
}

function dayKey(d) {
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}

// Rows arrive newest first; they're bucketed per local calendar day under
// "Today" / "Yesterday" / "Mon 28 Sep" headings, keeping that order.
function groupHistory(rows, nowMs) {
  var now = new Date(nowMs)
  var today = dayKey(now)
  var yesterday = dayKey(new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1))
  var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  var groups = []
  var current = null
  for (var i = 0; i < rows.length; i++) {
    var d = new Date(Number(rows[i].played_at) * 1000)
    var key = dayKey(d)
    if (!current || current.key !== key) {
      var label = key === today ? "Today"
        : key === yesterday ? "Yesterday"
        : days[d.getDay()] + " " + d.getDate() + " " + months[d.getMonth()]
      current = { key: key, label: label, items: [] }
      groups.push(current)
    }
    current.items.push(rows[i])
  }
  return groups
}

// DR lists a track a few minutes after it starts, so a lookup made right
// when a session ends usually misses the track that was on air. The
// playlist has "caught up" with the session once it lists a track that was
// still playing at (or started after) the session's end.
function playlistCaughtUp(html, endedAtMs) {
  var data = extractNextData(html)
  var props = data && data.props && data.props.pageProps
  var points = props && props.playlistIndexPoints
  if (!Array.isArray(points)) return false
  for (var i = 0; i < points.length; i++) {
    var track = trackFromPoint(points[i])
    if (track && (track.endsAt || track.startedAt) >= endedAtMs) return true
  }
  return false
}

// ---- Backfill on refresh ----
// A manual refresh fills gaps (shell restarts, DR lagging past a session
// end) by re-logging everything the channel played from the first track
// logged today up to now. The page for the programme on air only lists that
// programme, but its schedule names the day's other programmes, and each
// has its own playlist page at /lyd/playlister/<slug>/<date>/<episode>.
function historyFirstTodaySql(slug, dayStartSec) {
  return "SELECT MIN(played_at) AS first FROM plays WHERE channel = " + sqlString(slug) +
    " AND played_at >= " + Math.floor(Number(dayStartSec) || 0) + ";"
}

function parseFirstPlayedMs(raw) {
  var rows = parseHistoryRows(raw)
  var first = rows.length ? Number(rows[0].first) : 0
  return first > 0 ? first * 1000 : 0
}

function startOfDaySec(nowMs) {
  var d = new Date(nowMs)
  return Math.floor(new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime() / 1000)
}

// Paths ("<date>/<episode-slug>") of the earlier programmes that overlap
// [fromMs, untilMs]. The programme on the page itself is left out; its
// tracks are already in hand.
function backfillEpisodePaths(html, fromMs, untilMs) {
  var data = extractNextData(html)
  var props = data && data.props && data.props.pageProps
  if (!props || !props.schedule || !Array.isArray(props.schedule.items)) return []
  var current = props.playlistQuery && props.playlistQuery.productionNumber
  var out = []
  for (var i = 0; i < props.schedule.items.length; i++) {
    var item = props.schedule.items[i]
    if (!item || !item.slug || !/^[a-z0-9-]+$/i.test(item.slug)) continue
    if (current && String(item.productionNumber) === String(current)) continue
    var start = Date.parse(item.startTime)
    var end = Date.parse(item.endTime)
    if (isNaN(start) || isNaN(end) || end <= fromMs || start > untilMs) continue
    out.push(dayKey(new Date(start)) + "/" + item.slug)
  }
  return out
}

// Where a backfill window starts, from its anchor (first track logged today
// or the session start): the start of the programme airing at the anchor
// ("Programme"), the top of its clock hour ("Hour"), or the anchor itself
// ("Listened", and the fallback when the schedule doesn't cover it).
function backfillWindowStart(html, anchorMs, mode) {
  if (mode === "Hour") {
    var d = new Date(anchorMs)
    d.setMinutes(0, 0, 0)
    return d.getTime()
  }
  if (mode === "Programme") {
    var data = extractNextData(html)
    var props = data && data.props && data.props.pageProps
    var programmes = programmesOf(props && props.schedule)
    for (var i = 0; i < programmes.length; i++)
      if (anchorMs >= programmes[i].start && anchorMs < programmes[i].end) return programmes[i].start
  }
  return anchorMs
}
