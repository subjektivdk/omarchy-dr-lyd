import QtQuick
import QtTest

import "../Model.js" as Model

// Model.js is pure; these tests feed it synthetic dr.dk pages shaped like
// the real ones (a <script id="__NEXT_DATA__"> with the page props), so
// they run offline and pin down the parts DR's markup is read from.
TestCase {
  name: "DrLydModel"

  function page(pageProps) {
    return "<html><body><script id=\"__NEXT_DATA__\" type=\"application/json\">"
      + JSON.stringify({ props: { pageProps: pageProps } })
      + "</script></body></html>"
  }

  function asset(format, url, bitrate) {
    return { format: format, target: "Stream", url: url, bitrate: bitrate || 0 }
  }

  function channel(slug, title, assets) {
    return { type: "Channel", slug: slug, title: title, audioAssets: assets }
  }

  function track(time, seconds, artist, title, extra) {
    var p = { type: "Track", playedTime: time, durationMilliseconds: seconds * 1000,
              title: title, description: artist, trackUrn: "urn:dr:music:track:" + title }
    for (var k in extra) p[k] = extra[k]
    return p
  }

  // P6 on 2026-09-29 (+02:00): "P6 Beatet" 05:03-07:05, "Morgenbeatet"
  // 07:05-10:03, the page being Morgenbeatet's.
  function playlistPage(points) {
    return page({
      playlistIndexPoints: points,
      playlistQuery: { channelSlug: "p6beat", date: "2026-09-29", productionNumber: "2" },
      schedule: { items: [
        { title: "P6 Beatet", slug: "p6-beatet-1", productionNumber: "1",
          startTime: "2026-09-29T03:03:00+00:00", endTime: "2026-09-29T05:05:00+00:00" },
        { title: "Morgenbeatet", slug: "morgenbeatet-2", productionNumber: "2",
          startTime: "2026-09-29T05:05:00+00:00", endTime: "2026-09-29T08:03:00+00:00" },
        { title: "Later", slug: "later-3", productionNumber: "3",
          startTime: "2026-09-29T08:03:00+00:00", endTime: "2026-09-29T10:00:00+00:00" }
      ] }
    })
  }

  function ms(iso) { return Date.parse(iso) }

  readonly property var morning: [
    track("2026-09-29T09:05:05+02:00", 456, "LCD Soundsystem", "All My Friends"),
    track("2026-09-29T09:12:15+02:00", 230, "Getdown Services", "The Radiator"),
    track("2026-09-29T09:16:05+02:00", 178, "Baby Woodrose", "Everything's Gonna Be Alright"),
    track("2026-09-29T09:18:45+02:00", 169, "", "Animal",
          { roles: [{ name: "Pearl Jam" }] })
  ]

  // ---- Channel directory ----

  function test_parseChannels_keepsRadioChannelsAndPicksStreams() {
    var html = page({ channels: [
      channel("p1", "P1", [asset("HLS", "https://x/p1.m3u8"), asset("ICY", "https://x/p1-low.mp3", 64),
                           asset("ICY", "https://x/p1-high.mp3", 192)]),
      { districts: [channel("p4kbh", "P4 København", [asset("ICY", "https://x/kbh.mp3", 128)])] },
      channel("p6beat", "P6", [asset("ICY", "https://x/p6.mp3", 128)]),
      channel("p3webcam", "P3webcam", [asset("HLS", "https://x/cam.m3u8")]),
      channel("p1", "P1", [asset("ICY", "https://x/dup.mp3", 128)]),
      channel("evil", "P9", [asset("ICY", "--script=/tmp/x", 128)])
    ] })
    var channels = Model.parseChannelsFromHtml(html)
    compare(channels.map(function(c) { return c.slug }).join(","), "p1,p4kbh,p6beat")
    compare(channels[0].icyLowUrl, "https://x/p1-low.mp3")
    compare(channels[0].icyHighUrl, "https://x/p1-high.mp3")
    compare(channels[2].title, "P6 Beat", "display name override")
    compare(Model.streamUrlFor(channels[0], "Low"), "https://x/p1-low.mp3")
    compare(Model.streamUrlFor(channels[0], "High"), "https://x/p1-high.mp3")
  }

  function test_parseChannels_emptyOnMissingOrBrokenData() {
    compare(Model.parseChannelsFromHtml("<html></html>").length, 0)
    compare(Model.parseChannelsFromHtml("<script id=\"__NEXT_DATA__\">{nope</script>").length, 0)
  }

  function test_groupChannels_favoritesFirstRegionalCollapsed() {
    var groups = Model.groupChannels([
      { slug: "p3", title: "P3" }, { slug: "p1", title: "P1" },
      { slug: "p4kbh", title: "P4 København" }, { slug: "p5esbjerg", title: "P5 Esbjerg" }
    ], ["p3"])
    compare(groups.map(function(g) { return g.key }).join(","), "favorites,national,p4,p5")
    compare(groups[0].items[0].slug, "p3")
    compare(groups[1].items.length, 1, "a favorite leaves its regular group")
    verify(groups[2].defaultCollapsed)
    verify(!groups[1].defaultCollapsed)
  }

  // ---- Now playing ----

  function test_nowPlaying_latestStartedTrackWithRolesFallback() {
    var html = playlistPage(morning)
    var np = Model.parseNowPlayingFromHtml(html, ms("2026-09-29T09:20:00+02:00"))
    compare(Model.nowPlayingText(np), "Pearl Jam – Animal")
    compare(Model.nowPlayingAgeText(np, ms("2026-09-29T09:20:00+02:00")), "")
    compare(Model.nowPlayingAgeText(np, ms("2026-09-29T09:24:00+02:00")), "2 min ago")
  }

  function test_nowPlaying_nullWhenStaleOrFuture() {
    var html = playlistPage(morning)
    compare(Model.nowPlayingText(Model.parseNowPlayingFromHtml(html, ms("2026-09-29T09:24:00+02:00"))),
            "Pearl Jam – Animal", "still shown within the grace period after it ends")
    compare(Model.parseNowPlayingFromHtml(html, ms("2026-09-29T09:40:00+02:00")), null,
            "ended more than the grace period ago")
    compare(Model.nowPlayingText(Model.parseNowPlayingFromHtml(html, ms("2026-09-29T09:17:00+02:00"))),
            "Baby Woodrose – Everything's Gonna Be Alright", "ignores tracks that haven't started")
  }

  function test_pollDelay_isBounded() {
    var now = ms("2026-09-29T09:19:00+02:00")
    compare(Model.nowPlayingPollDelay(null, now), 60000)
    compare(Model.nowPlayingPollDelay({ endsAt: now - 60000 }, now), 15000)
    compare(Model.nowPlayingPollDelay({ endsAt: now + 3600000 }, now), 300000)
    compare(Model.nowPlayingPollDelay({ endsAt: now + 100000 }, now), 105000)
  }

  // ---- History logging ----

  function test_tracksForLog_onlyTracksOverlappingTheSession() {
    var html = playlistPage(morning)
    var tracks = Model.tracksForLog(html, ms("2026-09-29T09:14:10+02:00"), ms("2026-09-29T09:20:00+02:00"))
    compare(tracks.map(function(t) { return t.title }).join("|"),
            "The Radiator|Everything's Gonna Be Alright|Animal")
    compare(tracks[0].programme, "Morgenbeatet")
    compare(Model.tracksForLog(html, 0, ms("2026-09-29T09:20:00+02:00")).length, 0,
            "no session, nothing logged")
  }

  function test_tracksForLog_backfillStartsAtFirstLoggedTrack() {
    var html = playlistPage(morning)
    var now = ms("2026-09-29T09:30:00+02:00")
    var tracks = Model.tracksForLog(html, now, now, ms("2026-09-29T09:12:15+02:00"))
    compare(tracks[0].title, "The Radiator",
            "a long earlier track that merely overlaps the first logged one is left out")
    compare(tracks.length, 3)
  }

  function test_playlistCaughtUp() {
    var html = playlistPage(morning)
    verify(Model.playlistCaughtUp(html, ms("2026-09-29T09:20:00+02:00")), "Animal was on air")
    verify(!Model.playlistCaughtUp(html, ms("2026-09-29T09:25:00+02:00")), "DR hasn't listed 09:25 yet")
  }

  function test_backfillWindowStart_modes() {
    var html = playlistPage(morning)
    var anchor = ms("2026-09-29T09:12:15+02:00")
    compare(Model.backfillWindowStart(html, anchor, "Programme"), ms("2026-09-29T07:05:00+02:00"))
    var hour = new Date(anchor)
    hour.setMinutes(0, 0, 0)
    compare(Model.backfillWindowStart(html, anchor, "Hour"), hour.getTime())
    compare(Model.backfillWindowStart(html, anchor, "Listened"), anchor)
    compare(Model.backfillWindowStart(html, ms("2026-09-29T23:00:00+02:00"), "Programme"),
            ms("2026-09-29T23:00:00+02:00"), "outside the schedule: the anchor itself")
  }

  function test_backfillEpisodePaths_earlierProgrammesInWindowOnly() {
    var html = playlistPage(morning)
    var now = ms("2026-09-29T09:30:00+02:00")
    compare(Model.backfillEpisodePaths(html, ms("2026-09-29T07:05:00+02:00"), now).length, 0,
            "a programme ending exactly at the window start is skipped")
    compare(Model.backfillEpisodePaths(html, ms("2026-09-29T06:00:00+02:00"), now).join(","),
            "2026-09-29/p6-beatet-1", "current programme left out, future one too")
  }

  function test_historyInsertSql_escapesQuotes() {
    var sql = Model.historyInsertSql("p1", [{ startedAt: 1000, durationMs: 0, artist: "O'Brien",
                                              title: "It's", trackUrn: "", programme: "" }])
    verify(sql.indexOf("CREATE TABLE IF NOT EXISTS plays") === 0)
    verify(sql.indexOf("O''Brien") !== -1)
    verify(sql.indexOf("It''s") !== -1)
    compare(Model.historyInsertSql("p1", []), "")
    compare(Model.historyFirstTodaySql("p1'; DROP", 5),
            "SELECT MIN(played_at) AS first FROM plays WHERE channel = 'p1''; DROP' AND played_at >= 5;")
  }

  function test_historyPruneSql_zeroKeepsEverything() {
    compare(Model.historyPruneSql(0), "")
    verify(Model.historyPruneSql(2).indexOf("- 172800;") !== -1)
  }

  function test_parseHistoryRows_toleratesEmptyOutput() {
    compare(Model.parseHistoryRows("").length, 0)
    compare(Model.parseHistoryRows("garbage").length, 0)
    compare(Model.parseHistoryRows("[{\"id\":1}]")[0].id, 1)
    compare(Model.parseFirstPlayedMs("[{\"first\":10}]"), 10000)
    compare(Model.parseFirstPlayedMs("[{\"first\":null}]"), 0)
  }

  function test_groupHistory_perLocalDayOnlyTodayExpanded() {
    var now = new Date(2026, 8, 29, 12, 0).getTime()
    function at(d, h) { return new Date(2026, 8, d, h, 30).getTime() / 1000 }
    var groups = Model.groupHistory([
      { id: 3, played_at: at(29, 9), artist: "A", title: "x" },
      { id: 2, played_at: at(28, 22), artist: "", title: "y" },
      { id: 1, played_at: at(26, 8), artist: "B", title: "z" }
    ], now)
    compare(groups.map(function(g) { return g.label }).join(","), "Today,Yesterday,Sat 26 Sep")
    compare(groups[0].key, "day:2026-09-29")
    verify(!groups[0].defaultCollapsed)
    verify(groups[1].defaultCollapsed)
    compare(Model.historyTrackText(groups[0].items[0]), "A – x")
    compare(Model.historyTrackText(groups[1].items[0]), "y")
    compare(Model.historyTimeText(groups[0].items[0]), "09:30")
  }

  // ---- State file ----

  function test_parseStateFile_openSessionAndDefaults() {
    var parsed = Model.parseStateFile(JSON.stringify({
      favorites: ["p1", "", 3], lastPlayed: "p6beat", groups: { p4: true, bad: "x" },
      openSession: { slug: "p6beat", startedAt: 100, lastSeenAt: 200 }
    }))
    compare(parsed.favorites.join(","), "p1")
    compare(parsed.lastPlayed, "p6beat")
    compare(JSON.stringify(parsed.groups), "{\"p4\":true}")
    compare(parsed.openSession.lastSeenAt, 200)
    compare(Model.parseStateFile(JSON.stringify({ openSession: { slug: "p1", startedAt: 200, lastSeenAt: 100 } })).openSession,
            null, "heartbeat before start is rejected")
    compare(Model.parseStateFile("not json").favorites.length, 0)
  }

  function test_plainTooltipText_neutralisesMarkup() {
    var out = Model.plainTooltipText("<img src=\"https://example.com/x.png\"> Sort Sol")
    verify(out.indexOf("<") < 0 && out.indexOf(">") < 0, "no angle brackets survive")
    compare(Model.plainTooltipText("P6 Beat"), "P6 Beat")
    compare(Model.plainTooltipText("Sigur Rós – Hoppípolla"), "Sigur Rós – Hoppípolla")
    compare(Model.plainTooltipText("a\u0000b\u001bc"), "abc", "control characters are dropped")
    compare(Model.plainTooltipText(null), "")
    compare(Model.plainTooltipText(new Array(500).join("x")).length, 200)
  }
}
