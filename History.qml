import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The listening history, without any UI: the sqlite database under
// ~/.local/state/omarchy/dr-lyd/, written through the sqlite3 CLI one
// statement at a time, plus the lookups that feed it (session ends,
// backfill) and reading, exporting and clearing it for the panel.
Item {
  id: root
  visible: false

  // From the widget settings.
  property bool logging: true
  property int keepDays: 0
  property string backfillMode: "Programme"

  // Emitted after every write, so a visible history list can reload.
  signal written()
  // Emitted when rows has been (re)read from the database — not for the
  // initial empty list, so listeners can trust it reflects what is stored.
  signal loaded()

  readonly property string historyDir: Quickshell.env("HOME") + "/.local/state/omarchy/dr-lyd/"
  readonly property string historyPath: root.historyDir + "history.sqlite"

  // Pruning (historyDays) happens once, when the directory is in place.
  Component.onCompleted: ensureDirProc.running = true

  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", root.historyDir]
    onExited: root.queueWrite(Model.historyPruneSql(root.keepDays))
  }

  // ---- Writes ----
  property var writeQueue: []

  function logTracks(slug, tracks) {
    if (!root.logging) return
    root.queueWrite(Model.historyInsertSql(slug, tracks))
  }

  function logPlaylist(slug, html, sessionStartedAt, fetchedAt) {
    root.logTracks(slug, Model.tracksForLog(html, sessionStartedAt, fetchedAt))
  }

  function clear() {
    root.exportStatus = ""
    root.queueWrite(Model.historyClearSql())
  }

  function queueWrite(sql) {
    if (!sql) return
    root.writeQueue = root.writeQueue.concat([sql])
    root.runWrite()
  }

  function runWrite() {
    if (writeProc.running || root.writeQueue.length === 0) return
    var queue = root.writeQueue.slice()
    writeProc.command = ["sqlite3", "-bail", "-cmd", ".timeout 2000", root.historyPath, queue.shift()]
    root.writeQueue = queue
    writeProc.running = true
  }

  Process {
    id: writeProc
    stderr: StdioCollector {
      onStreamFinished: if (text) console.warn("dr-lyd history: " + text)
    }
    onExited: {
      root.written()
      Qt.callLater(root.runWrite)
    }
  }

  // ---- Session ends ----
  // DR lists a track a few minutes after it starts, so an ended session
  // keeps looking up its channel once a minute until DR has listed the
  // track that was on air at the end (at most 10 minutes).
  property var sessionEndQueue: []
  readonly property int sessionEndRetryMs: 60000
  readonly property int sessionEndGiveUpMs: 600000

  function logSessionEnd(slug, startedAt, endedAt) {
    if (!root.logging || !slug || !startedAt) return
    root.sessionEndQueue = root.sessionEndQueue.concat([{ slug: slug, startedAt: startedAt, endedAt: endedAt, dueAt: 0 }])
    root.runSessionEndFetch()
  }

  // Runs the first due lookup; if all are waiting for their retry, sleeps
  // until the earliest one is due.
  function runSessionEndFetch() {
    if (sessionEndProc.running || root.sessionEndQueue.length === 0) return
    var now = Date.now()
    var queue = root.sessionEndQueue.slice()
    var next = -1
    var earliest = 0
    for (var i = 0; i < queue.length; i++) {
      if (queue[i].dueAt <= now) { next = i; break }
      if (!earliest || queue[i].dueAt < earliest) earliest = queue[i].dueAt
    }
    if (next === -1) {
      sessionEndRetryTimer.interval = Math.max(1000, earliest - now)
      sessionEndRetryTimer.restart()
      return
    }
    sessionEndProc.session = queue.splice(next, 1)[0]
    root.sessionEndQueue = queue
    sessionEndProc.command = ["curl", "-fsSL", "--max-time", "10", "--max-filesize", "5000000",
                              "https://www.dr.dk/lyd/playlister/" + sessionEndProc.session.slug]
    sessionEndProc.running = true
  }

  Process {
    id: sessionEndProc
    property var session: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var s = sessionEndProc.session
        var raw = String(text || "")
        if (!s) return
        if (raw) root.logTracks(s.slug, Model.tracksForLog(raw, s.startedAt, s.endedAt))
        var done = raw && Model.playlistCaughtUp(raw, s.endedAt)
        if (!done && Date.now() < s.endedAt + root.sessionEndGiveUpMs)
          root.sessionEndQueue = root.sessionEndQueue.concat([{
            slug: s.slug, startedAt: s.startedAt, endedAt: s.endedAt,
            dueAt: Date.now() + root.sessionEndRetryMs
          }])
      }
    }
    onExited: Qt.callLater(root.runSessionEndFetch)
  }

  Timer {
    id: sessionEndRetryTimer
    onTriggered: root.runSessionEndFetch()
  }

  // ---- Backfill (manual refresh) ----
  // Re-logs everything a channel aired from a start point up to now, so
  // gaps left by restarts or DR's listing lag get filled regardless of what
  // the automatic lookups caught. The anchor is the first track logged on
  // the channel today (or the session start, if earlier); backfillMode
  // widens it to the start of that programme or clock hour, or keeps it.
  // This deliberately logs what aired during pauses too. Steps run one at a
  // time: first-track query → current programme page → one page per
  // earlier programme in the window.
  property string backfillSlug: ""
  property double backfillAnchor: 0
  property double backfillStart: 0
  property double backfillSession: 0
  property double backfillUntil: 0
  property var backfillPaths: []
  readonly property bool backfillBusy: backfillQueryProc.running || backfillFetchProc.running
                                       || root.backfillPaths.length > 0

  function startBackfill(slug, sessionStartedAt) {
    if (!root.logging || !slug || root.backfillBusy) return
    root.backfillSlug = slug
    root.backfillUntil = Date.now()
    root.backfillSession = sessionStartedAt || root.backfillUntil
    backfillQueryProc.command = ["sqlite3", "-json", "-readonly", "-cmd", ".timeout 2000", root.historyPath,
                                 Model.historyFirstTodaySql(slug, Model.startOfDaySec(root.backfillUntil))]
    backfillQueryProc.running = true
  }

  Process {
    id: backfillQueryProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var first = Model.parseFirstPlayedMs(text)
        var session = root.backfillSession
        root.backfillAnchor = first && first < session ? first : session
        root.fetchBackfill("", true)
      }
    }
  }

  function fetchBackfill(path, isCurrent) {
    backfillFetchProc.isCurrent = isCurrent
    backfillFetchProc.command = ["curl", "-fsSL", "--max-time", "10", "--max-filesize", "5000000",
                                 "https://www.dr.dk/lyd/playlister/" + root.backfillSlug + (path ? "/" + path : "")]
    backfillFetchProc.running = true
  }

  Process {
    id: backfillFetchProc
    property bool isCurrent: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        if (!raw) return
        // The current page's schedule decides where the window starts.
        if (backfillFetchProc.isCurrent)
          root.backfillStart = Model.backfillWindowStart(raw, root.backfillAnchor, root.backfillMode)
        root.logTracks(root.backfillSlug,
                       Model.tracksForLog(raw, root.backfillSession, root.backfillUntil, root.backfillStart))
        if (backfillFetchProc.isCurrent)
          root.backfillPaths = Model.backfillEpisodePaths(raw, root.backfillStart, root.backfillUntil)
      }
    }
    onExited: Qt.callLater(function() {
      if (root.backfillPaths.length === 0) return
      var rest = root.backfillPaths.slice()
      var next = rest.shift()
      root.backfillPaths = rest
      root.fetchBackfill(next, false)
    })
  }

  // ---- Reading ----
  property var rows: []

  function load() {
    if (readProc.running) return
    readProc.command = ["sqlite3", "-json", "-readonly", "-cmd", ".timeout 2000", root.historyPath,
                        Model.historySelectSql(500)]
    readProc.running = true
  }

  Process {
    id: readProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.rows = Model.parseHistoryRows(text)
        root.loaded()
      }
    }
  }

  // ---- Export ----
  // Reuses the skill's history.py (shipped in this plugin), so the panel
  // and `dr-lyd.sh export` write the same Markdown. Each date is exported
  // in full from the database.
  readonly property string historyScript: decodeURIComponent(Qt.resolvedUrl("claude-skill/bin/history.py").toString().replace(/^file:\/\//, ""))
  property string exportStatus: ""
  readonly property bool exporting: exportProc.running

  function exportDays(dates) {
    if (exportProc.running || !dates || dates.length === 0) return
    root.exportStatus = "Exporting…"
    exportProc.command = ["python3", root.historyScript, "export", "--dates", dates.join(",")]
    exportProc.running = true
  }

  Process {
    id: exportProc
    stdout: StdioCollector {
      id: exportOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: exportErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var msg = exitCode === 0 ? String(exportOut.text || "").trim() : String(exportErr.text || "").trim()
      root.exportStatus = (exitCode === 0 ? "" : "Export failed: ")
        + msg.replace(Quickshell.env("HOME"), "~")
    }
  }
}
