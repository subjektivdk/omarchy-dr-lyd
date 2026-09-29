import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Playback, without any UI: DR's channel directory, one mpv process at a
// time with a single automatic reconnect, the now-playing poll, and the
// listening session (start, 30 s heartbeat, end). The panel owns what gets
// persisted and shown; history logging hangs off the signals below.
Item {
  id: root
  visible: false

  // Preferred ICY bitrate ("Low"/"High"), from the widget settings.
  property string quality: "High"

  // Every now-playing lookup, with the session it belongs to, so the
  // history can log the tracks that overlap it.
  signal playlistFetched(string slug, string html, double sessionStartedAt, double fetchedAt)
  // A listening session ended (stop, switch, or a stream that couldn't be
  // restarted); the history keeps looking it up until DR has caught up.
  signal sessionEnded(string slug, double startedAt, double endedAt)
  // A channel actually started playing (not a reconnect).
  signal started(string slug)

  readonly property bool busy: fetchProc.running || nowPlayingProc.running

  // ---- Channel directory ----
  // Any dr.dk/lyd/<channel> page embeds the whole directory, so one fixed,
  // known-good page is scraped rather than whatever channel is configured
  // (a stale slug there would otherwise 404 and leave the list empty).
  readonly property string directoryUrl: "https://www.dr.dk/lyd/p1"
  property var channels: []
  property double lastFetched: 0
  property string fetchError: ""
  property int fetchRetries: 0

  function channelBySlug(slug) {
    for (var i = 0; i < root.channels.length; i++)
      if (root.channels[i].slug === slug) return root.channels[i]
    return null
  }

  function startFetch() {
    if (fetchProc.running) return
    fetchProc.command = ["curl", "-fsSL", "--max-time", "10", "--max-filesize", "5000000", root.directoryUrl]
    fetchProc.running = true
  }

  // A user- or open-triggered fetch gets a fresh retry budget. Retries go
  // through startFetch() directly so they don't reset the counter.
  function refreshDirectory() {
    root.fetchRetries = 0
    root.startFetch()
  }

  // Re-scrape once an hour at most; a manual refresh always forces it.
  function refreshIfStale() {
    if (root.channels.length === 0 || (Date.now() - root.lastFetched) > 3600000) {
      root.refreshDirectory()
      root.refreshNowPlaying()
    }
  }

  function scheduleFetchRetry() {
    if (root.fetchRetries >= 3) return
    root.fetchRetries++
    fetchRetryTimer.restart()
  }

  Process {
    id: fetchProc
    // Failure handling lives here alone: a failed curl (-f) closes stdout
    // with nothing in it, so empty text covers both network errors and an
    // empty body, and exit codes need no separate handler.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        if (raw === "") {
          root.fetchError = "Could not fetch dr.dk/lyd"
          root.scheduleFetchRetry()
          return
        }
        var parsed = Model.parseChannelsFromHtml(raw)
        if (parsed.length === 0) {
          root.fetchError = "Could not find channels on dr.dk"
          root.scheduleFetchRetry()
          return
        }
        root.channels = parsed
        root.lastFetched = Date.now()
        root.fetchError = ""
        root.fetchRetries = 0
        if (root.pendingPlaySlug) {
          var slug = root.pendingPlaySlug
          root.pendingPlaySlug = ""
          root.switchTo(slug)
        }
      }
    }
  }

  Timer {
    id: fetchRetryTimer
    interval: 3000
    onTriggered: root.startFetch()
  }

  // ---- Playback: shell out to mpv, one channel at a time ----
  property string playingSlug: ""
  readonly property var playingChannel: root.playingSlug ? root.channelBySlug(root.playingSlug) : null
  readonly property string playingTitle: playingChannel ? playingChannel.title : ""

  // playToken identifies each switch/stop attempt so a deferred start from
  // an older attempt is dropped.
  property int playToken: 0
  // Setting running=false only asks mpv to quit: `running` stays true and
  // exited() fires later — after a replacement start has been requested, in
  // which case Quickshell launches the replacement right after. Every kill
  // we ask for is counted here so onExited can tell those exits from a
  // stream that actually died.
  property int mpvKillsPending: 0

  function killMpv() {
    if (mpvProc.running) root.mpvKillsPending++
    mpvProc.running = false
  }

  // A play request made before the directory has loaded (middle-click right
  // after shell start) waits here and is honoured when the fetch lands.
  property string pendingPlaySlug: ""

  // Shown in the header while nothing is playing, e.g. after mpv died.
  property string playbackError: ""

  // One automatic restart when a live stream drops. The budget resets on
  // any user action and when a stream has run long enough (30 s) to count
  // as having worked, so a later drop gets its own retry.
  property int reconnectAttempts: 0
  property double mpvStartedAt: 0

  function switchTo(slug, isReconnect) {
    if (!isReconnect) {
      root.reconnectAttempts = 0
      reconnectTimer.stop()
    }

    var channel = root.channelBySlug(slug)
    if (!channel) {
      if (root.channels.length === 0) {
        root.pendingPlaySlug = slug
        root.refreshIfStale()
      }
      return
    }
    var url = Model.streamUrlFor(channel, root.quality)
    if (!url) {
      root.playbackError = "No stream found for " + channel.title
      return
    }

    if (!isReconnect) root.endSession()
    root.playToken++
    var token = root.playToken
    root.killMpv()
    root.playingSlug = ""
    Qt.callLater(function() {
      if (token !== root.playToken) return
      mpvProc.command = ["mpv", "--no-video", "--idle=no", "--really-quiet", "--force-media-title=DR " + channel.title, "--", url]
      mpvProc.running = true
      root.mpvStartedAt = Date.now()
      root.playbackError = ""
      if (!isReconnect || !root.sessionStartedAt) {
        root.sessionStartedAt = Date.now()
        root.openSession = { slug: slug, startedAt: root.sessionStartedAt, lastSeenAt: root.sessionStartedAt }
      }
      root.playingSlug = slug
      if (!isReconnect) root.started(slug)
    })
  }

  function stop() {
    root.endSession()
    root.playToken++
    root.pendingPlaySlug = ""
    root.playbackError = ""
    root.reconnectAttempts = 0
    reconnectTimer.stop()
    root.killMpv()
    root.playingSlug = ""
  }

  function togglePlay(slug) {
    if (root.playingSlug === slug || root.pendingPlaySlug === slug) root.stop()
    else root.switchTo(slug)
  }

  Process {
    id: mpvProc
    onExited: function(exitCode) {
      if (root.mpvKillsPending > 0) {
        root.mpvKillsPending--
        return
      }

      var slug = root.playingSlug
      var title = root.playingTitle
      root.playingSlug = ""
      if (!slug) return

      if (Date.now() - root.mpvStartedAt > 30000) root.reconnectAttempts = 0
      if (root.reconnectAttempts < 1) {
        root.reconnectAttempts++
        root.playbackError = "Lost " + title + " — retrying…"
        reconnectTimer.slug = slug
        reconnectTimer.restart()
      } else {
        root.playbackError = "Could not play " + title
        root.sessionEnded(slug, root.sessionStartedAt, Date.now())
        root.sessionStartedAt = 0
        root.openSession = null
      }
    }
  }

  Timer {
    id: reconnectTimer
    property string slug: ""
    interval: 2000
    onTriggered: if (slug) root.switchTo(slug, true)
  }

  // ---- Listening session ----
  // Starts when a channel starts (a reconnect continues it) and ends on
  // stop, switch or give-up. openSession mirrors it with a 30 s heartbeat
  // for the panel to persist, so a session cut short by a shell restart can
  // be finished on the next start.
  property double sessionStartedAt: 0
  property var openSession: null

  function endSession() {
    if (root.playingSlug && root.sessionStartedAt)
      root.sessionEnded(root.playingSlug, root.sessionStartedAt, Date.now())
    root.sessionStartedAt = 0
    root.openSession = null
  }

  function touchSession() {
    if (!root.openSession || !root.playingSlug) return
    root.openSession = { slug: root.openSession.slug, startedAt: root.openSession.startedAt, lastSeenAt: Date.now() }
  }

  // ---- Now playing: the track the channel is airing ----
  // Polled only while a channel plays; each result schedules the next poll
  // for when the track should end. A pending request is never killed: its
  // result is discarded by token, and a request that arrived while it ran
  // is sent once it exits.
  property var nowPlaying: null
  readonly property string nowPlayingText: Model.nowPlayingText(root.nowPlaying)
  // Ticks while playing so the age shown on hover keeps advancing between
  // polls, not just when a fetch lands.
  property double nowClock: Date.now()
  readonly property string nowPlayingAgeText: Model.nowPlayingAgeText(root.nowPlaying, root.nowClock)
  property int nowPlayingToken: 0
  property bool nowPlayingRefetch: false

  onPlayingSlugChanged: {
    root.nowPlayingToken++
    root.nowPlaying = null
    root.nowPlayingRefetch = false
    nowPlayingTimer.stop()
    if (root.playingSlug) root.fetchNowPlaying()
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.playingSlug !== ""
    onTriggered: {
      root.nowClock = Date.now()
      root.touchSession()
    }
  }

  function fetchNowPlaying() {
    if (!root.playingSlug) return
    if (nowPlayingProc.running) {
      root.nowPlayingRefetch = true
      return
    }
    nowPlayingProc.token = root.nowPlayingToken
    nowPlayingProc.command = ["curl", "-fsSL", "--max-time", "10", "--max-filesize", "5000000",
                              "https://www.dr.dk/lyd/playlister/" + root.playingSlug]
    nowPlayingProc.running = true
  }

  // Manual re-check: jump the queue instead of waiting for the scheduled poll.
  function refreshNowPlaying() {
    if (!root.playingSlug) return
    nowPlayingTimer.stop()
    root.fetchNowPlaying()
  }

  Process {
    id: nowPlayingProc
    property int token: -1
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (nowPlayingProc.token !== root.nowPlayingToken) return
        var raw = String(text || "")
        var now = Date.now()
        root.nowClock = now
        if (raw === "") {
          // Network trouble, or a channel without a playlist page (LYD ekstra 404s).
          root.nowPlaying = null
          nowPlayingTimer.interval = 300000
        } else {
          root.nowPlaying = Model.parseNowPlayingFromHtml(raw, now)
          root.playlistFetched(root.playingSlug, raw, root.sessionStartedAt, now)
          nowPlayingTimer.interval = Model.nowPlayingPollDelay(root.nowPlaying, now)
        }
        nowPlayingTimer.restart()
      }
    }
    onExited: {
      if (!root.nowPlayingRefetch) return
      root.nowPlayingRefetch = false
      Qt.callLater(root.fetchNowPlaying)
    }
  }

  Timer {
    id: nowPlayingTimer
    onTriggered: root.fetchNowPlaying()
  }
}
