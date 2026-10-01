import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "subjektivdk.dr-lyd"
  ipcTarget: "subjektivdk.dr-lyd"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    setCenterHoverRevealSuppressed(false)
    root.resetCursor()
    root.controller.show()
    root.refreshIfStale()
  }

  function openFromHotkey() {
    root.resetCursor()
    root.controller.show()
    root.refreshIfStale()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Settings (manifest-backed: defaultChannel, quality) ----
  readonly property string defaultChannel: String(root.setting("defaultChannel", "p6beat"))
  readonly property string quality: String(root.setting("quality", "High"))
  readonly property bool logHistory: root.setting("logHistory", true) === true
  readonly property int historyDays: Number(root.setting("historyDays", 0)) || 0
  readonly property string backfillMode: String(root.setting("backfillFrom", "Programme"))

  // ---- Persisted state: favorites + last played channel ----
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/settings/"
  readonly property string statePath: root.stateDir + "dr-lyd.json"
  property var favorites: []
  property string lastPlayed: ""
  // group key -> expanded; a key that is absent falls back to the group's
  // default (regional families collapsed, the rest expanded).
  property var groupState: ({})
  property bool stateLoaded: false
  // What "start playing"/middle-click resolves to: the last channel that
  // was actually played, falling back to the configured default until
  // anything has ever been played.
  readonly property string startChannel: root.lastPlayed || root.defaultChannel

  function isFavorite(slug) {
    return root.favorites.indexOf(slug) !== -1
  }

  function toggleFavorite(slug) {
    var idx = root.favorites.indexOf(slug)
    var next = root.favorites.slice()
    if (idx === -1) next.push(slug)
    else next.splice(idx, 1)
    root.favorites = next
    root.scheduleStateSave()
  }

  function isGroupExpanded(group) {
    var stored = root.groupState[group.key]
    return stored === undefined ? !group.defaultCollapsed : stored
  }

  function toggleGroup(group) {
    var next = {}
    for (var key in root.groupState) next[key] = root.groupState[key]
    next[group.key] = !root.isGroupExpanded(group)
    root.groupState = next
    root.scheduleStateSave()
  }

  function loadState(raw) {
    // FileView can fire onLoaded more than once during startup; only the
    // first read should seed state, or a later reload could stomp a
    // just-made change with stale disk content.
    if (root.stateLoaded) return
    var parsed = Model.parseStateFile(raw)
    root.favorites = parsed.favorites
    root.lastPlayed = parsed.lastPlayed
    root.groupState = parsed.groups
    root.stateLoaded = true
    // A session still marked open means the shell stopped (restart, plugin
    // reload, crash) while a channel played. Finish it from its last
    // heartbeat once settings have been injected.
    if (parsed.openSession) {
      recoverSessionTimer.session = parsed.openSession
      recoverSessionTimer.start()
    }
  }

  Timer {
    id: recoverSessionTimer
    property var session: null
    interval: 2000
    onTriggered: {
      if (session) history.logSessionEnd(session.slug, session.startedAt, session.lastSeenAt)
      session = null
      root.scheduleStateSave()
    }
  }

  function scheduleStateSave() {
    if (!root.stateLoaded) return
    stateSaveTimer.restart()
  }

  // The state file lives in a user-writable directory, so it is read and
  // written by scripts/state.py (no FIFOs, symlinks or oversized files, and
  // every step relative to one directory handle) instead of a FileView.
  readonly property string stateScript: Model.localPath(Qt.resolvedUrl("scripts/state.py"))

  function flushState() {
    if (stateWriteProc.running) {
      // Only one write at a time; run again once this one has finished.
      root.stateDirty = true
      return
    }
    root.stateDirty = false
    stateWriteProc.command = ["python3", root.stateScript, "write", root.stateDir, JSON.stringify({
      favorites: root.favorites,
      lastPlayed: root.lastPlayed,
      groups: root.groupState,
      openSession: player.openSession
    }, null, 2) + "\n"]
    stateWriteProc.running = true
  }

  property bool stateDirty: false

  Process {
    id: stateWriteProc
    onExited: if (root.stateDirty) root.flushState()
  }

  Process {
    id: stateReadProc
    command: ["python3", root.stateScript, "read", root.stateDir]
    stdout: StdioCollector {
      id: stateReadOut
      waitForEnd: true
      onStreamFinished: root.loadState(stateReadOut.text)
    }
  }

  Timer {
    id: stateSaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushState()
  }

  // ---- Playback and history ----
  // The logic lives in two non-visual components; the panel wires them
  // together, persists what they report and shows it. Everything below the
  // IPC handler reads them through the plain properties here, so the UI and
  // BarWidget.qml don't need to know which component owns what.
  Player {
    id: player
    quality: root.quality
    onStarted: function(slug) {
      root.lastPlayed = slug
      root.scheduleStateSave()
    }
    onOpenSessionChanged: root.scheduleStateSave()
    onPlaylistFetched: function(slug, html, sessionStartedAt, fetchedAt) {
      history.logPlaylist(slug, html, sessionStartedAt, fetchedAt)
    }
    onSessionEnded: function(slug, startedAt, endedAt) {
      history.logSessionEnd(slug, startedAt, endedAt)
    }
  }

  History {
    id: history
    logging: root.logHistory
    keepDays: root.historyDays
    backfillMode: root.backfillMode
    onWritten: if (root.view === "history") history.load()
    onLoaded: {
      root.historyClock = Date.now()
      root.pruneDayState()
    }
  }

  readonly property var channels: player.channels
  readonly property var groupedChannels: Model.groupChannels(player.channels, root.favorites)
  readonly property string fetchError: player.fetchError
  readonly property string playingSlug: player.playingSlug
  readonly property string playingTitle: player.playingTitle
  readonly property string pendingPlaySlug: player.pendingPlaySlug
  readonly property string playbackError: player.playbackError
  readonly property string nowPlayingText: player.nowPlayingText
  readonly property string nowPlayingAgeText: player.nowPlayingAgeText
  readonly property bool refreshBusy: player.busy || history.backfillBusy

  function channelBySlug(slug) { return player.channelBySlug(slug) }
  function togglePlay(slug) { player.togglePlay(slug) }
  function stop() { player.stop() }
  function toggleDefaultChannel() { player.togglePlay(root.startChannel) }
  function refreshIfStale() { player.refreshIfStale() }

  // The header button / r: re-fetch the directory and now-playing, and
  // backfill the playing channel's history.
  function refresh() {
    player.refreshDirectory()
    player.refreshNowPlaying()
    history.startBackfill(player.playingSlug, player.sessionStartedAt)
  }

  // External control (e.g. `omarchy-shell subjektivdk.dr-lyd play p1`), for
  // scripts/agents that want to switch channel without touching the panel.
  // manageIpc: false above so this panel can own the single IpcHandler the
  // target permits, like the built-in power/monitor panels: it carries the
  // usual open/close/toggle verbs plus the playback methods.
  IpcHandler {
    target: "subjektivdk.dr-lyd"
    // Panel visibility, same verbs as the built-in panels' targets.
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function play(slug: string): string {
      if (player.channelBySlug(slug)) {
        player.switchTo(slug)
        return "ok"
      }
      if (player.channels.length === 0) {
        player.switchTo(slug)
        return "loading channel directory, retry shortly"
      }
      return "unknown channel: " + slug
    }
    function stop(): string {
      player.stop()
      return "ok"
    }
    function status(): string {
      return player.playingSlug ? player.playingSlug + "\t" + player.playingTitle : "stopped"
    }
    function list(): string {
      if (player.channels.length === 0) {
        player.refreshIfStale()
        return "loading channel directory, retry shortly"
      }
      var lines = []
      for (var i = 0; i < player.channels.length; i++)
        lines.push(player.channels[i].slug + "\t" + player.channels[i].title)
      return lines.join("\n")
    }
  }

  // ---- History view ----
  property string view: "channels"
  readonly property var historyRows: history.rows
  readonly property var groupedHistory: Model.groupHistory(history.rows, root.historyClock)
  // "Today"/"Yesterday" are relative to this clock. It is the panel's own,
  // not the player's (which only ticks while a channel plays): set on every
  // load and ticking each minute while the History tab is showing, so the
  // labels move on at midnight with nothing playing too.
  property double historyClock: Date.now()

  Timer {
    interval: 60000
    repeat: true
    running: root.opened && root.view === "history"
    onTriggered: root.historyClock = Date.now()
  }
  readonly property string exportStatus: history.exportStatus

  function setView(next) {
    if (root.view === next) return
    root.view = next
    root.resetCursor()
    history.resetExportStatus()
    if (next === "history") {
      root.historyClock = Date.now()
      history.load()
    }
  }

  // Export writes what is expanded: each expanded day in full.
  readonly property var expandedDays: {
    var dates = []
    for (var i = 0; i < root.groupedHistory.length; i++)
      if (root.isGroupExpanded(root.groupedHistory[i])) dates.push(root.groupedHistory[i].day)
    return dates
  }
  // With every day collapsed there is nothing to export; say so for as long
  // as that lasts instead of only after a failed attempt.
  readonly property string exportHint: root.expandedDays.length === 0 ? "Expand a day to export it" : ""

  function exportHistory() {
    history.exportDays(root.expandedDays)
  }

  // Collapse state for days lives in groupState as "day:<date>"; drop the
  // entries for days no longer in the history so the state file doesn't
  // grow by one key per day forever.
  function pruneDayState() {
    var present = {}
    for (var i = 0; i < root.groupedHistory.length; i++) present[root.groupedHistory[i].key] = true
    var next = {}
    var changed = false
    for (var key in root.groupState) {
      if (key.indexOf("day:") === 0 && !present[key]) changed = true
      else next[key] = root.groupState[key]
    }
    if (!changed) return
    root.groupState = next
    root.scheduleStateSave()
  }

  // ---- Clear history (x, or the trash button; confirmed in a dialog) ----
  property bool clearConfirmOpen: false

  function askClearHistory() {
    if (root.view !== "history" || root.historyRows.length === 0) return
    root.clearConfirmOpen = true
    clearConfirm.selectedIndex = 0
    clearConfirm.forceActiveFocus()
  }

  function closeClearConfirm() {
    root.clearConfirmOpen = false
    keyCatcher.forceActiveFocus()
  }

  function confirmClearHistory() {
    root.closeClearConfirm()
    history.clear()
  }

  function channelTitle(slug) {
    var channel = player.channelBySlug(slug)
    return channel ? channel.title : slug
  }

  // The copied row swaps its channel · programme line for a confirmation
  // for a moment (mouse click and Enter alike).
  property int copiedRowId: -1

  function copyHistoryRow(row) {
    root.copyText(Model.historyTrackText(row))
    root.copiedRowId = row.id
    copiedTimer.restart()
  }

  Timer {
    id: copiedTimer
    interval: 1500
    onTriggered: root.copiedRowId = -1
  }

  function copyText(value) {
    if (!value) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(value) + " | wl-copy"])
  }

  // The directory is fetched lazily: on first panel open, or when a play
  // request needs it. Nothing contacts dr.dk just because the shell started.
  Component.onCompleted: stateReadProc.running = true


  // ---- Keyboard + mouse cursor ----
  // One cursor shared by keyboard and mouse, as in the stock panels: rows
  // paint their highlight from hasCursor (CursorSurface), never from their
  // own containsMouse, so there is only ever one highlight on screen. The
  // cursor is tracked by key rather than index so it stays on the same row
  // when favoriting moves a channel or a group above it opens or closes.
  property bool cursorActive: false
  property string cursorKey: ""

  readonly property var cursorTargets: {
    var list = []
    if (root.view === "history") {
      for (var h = 0; h < root.groupedHistory.length; h++) {
        var day = root.groupedHistory[h]
        list.push({ key: "group:" + day.key, group: day })
        if (!root.isGroupExpanded(day)) continue
        for (var r = 0; r < day.items.length; r++)
          list.push({ key: "history:" + day.items[r].id, row: day.items[r] })
      }
      return list
    }
    for (var i = 0; i < root.groupedChannels.length; i++) {
      var group = root.groupedChannels[i]
      list.push({ key: "group:" + group.key, group: group })
      if (!root.isGroupExpanded(group)) continue
      for (var j = 0; j < group.items.length; j++)
        list.push({ key: "channel:" + group.items[j].slug, slug: group.items[j].slug })
    }
    return list
  }

  function hasCursor(key) {
    return root.cursorActive && root.cursorKey === key
  }

  function setCursor(key) {
    root.cursorActive = true
    root.cursorKey = key
  }

  function resetCursor() {
    root.cursorActive = false
    root.cursorKey = ""
    channelScroll.contentY = 0
  }

  function cursorIndex() {
    for (var i = 0; i < root.cursorTargets.length; i++)
      if (root.cursorTargets[i].key === root.cursorKey) return i
    return -1
  }

  // The first arrow press only reveals the cursor, on the playing channel
  // if it is listed, otherwise on the first row.
  function moveCursor(delta) {
    var targets = root.cursorTargets
    if (targets.length === 0) return
    var index = root.cursorIndex()
    if (!root.cursorActive || index === -1) {
      var playingKey = "channel:" + root.playingSlug
      var start = 0
      for (var i = 0; i < targets.length; i++)
        if (targets[i].key === playingKey) start = i
      root.setCursor(targets[start].key)
      return
    }
    var next = Math.max(0, Math.min(targets.length - 1, index + delta))
    root.setCursor(targets[next].key)
  }

  function activateCursor() {
    var target = root.cursorTargets[root.cursorIndex()]
    if (!root.cursorActive || !target) return
    if (target.group) root.toggleGroup(target.group)
    else if (target.row) root.copyHistoryRow(target.row)
    else root.togglePlay(target.slug)
  }

  function favoriteCursor() {
    var target = root.cursorTargets[root.cursorIndex()]
    if (root.cursorActive && target && target.slug) root.toggleFavorite(target.slug)
  }

  // Keeps the cursor row inside the scrolled viewport while j/k walk the list.
  function ensureCursorVisible(item) {
    if (!item) return
    var margin = Style.space(6)
    var maxY = Math.max(0, channelScroll.contentHeight - channelScroll.height)
    var top = item.mapToItem(channelColumn, 0, 0).y
    var bottom = top + item.height
    if (top < channelScroll.contentY + margin)
      channelScroll.contentY = Math.max(0, Math.min(maxY, top - margin))
    else if (bottom > channelScroll.contentY + channelScroll.height - margin)
      channelScroll.contentY = Math.max(0, Math.min(maxY, bottom + margin - channelScroll.height))
  }


  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(channelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      blocked: root.clearConfirmOpen
      onCloseRequested: root.close()
      onDeleteRequested: root.askClearHistory()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "f") root.favoriteCursor()
        else if (t === "r") root.refresh()
        else if (t === "s") root.stop()
        // h/j/k/l are taken by the key catcher's vim movement, so the tabs
        // get c(hannels) and p(layed).
        else if (t === "c") root.setView("channels")
        else if (t === "p") root.setView("history")
        else if (t === "e" && root.view === "history") root.exportHistory()
      }

      ConfirmDialog {
        id: clearConfirm
        anchors.fill: parent
        z: 10
        opened: root.clearConfirmOpen
        message: "Delete the entire listening history?"
        confirmText: "Delete"
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        Keys.onPressed: function(event) { if (clearConfirm.handleKey(event)) event.accepted = true }
        onCanceled: root.closeClearConfirm()
        onConfirmed: root.confirmClearHistory()
      }

      Flickable {
        id: channelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: channelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: channelColumn
          width: channelScroll.width
          spacing: Style.space(10)

          // ---- Hero: channel · what's on air · refresh ----
          PanelHero {
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            iconOpacity: root.playingSlug ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰐹"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            title: root.playingSlug ? root.playingTitle
              : root.pendingPlaySlug ? "Starting…"
              : "DR Lyd"
            meta: root.playingSlug
              ? (root.nowPlayingText
                  ? root.nowPlayingText + (root.nowPlayingAgeText ? " · " + root.nowPlayingAgeText : "")
                  : "On air")
              : (root.playbackError || "Stopped")
            trailingControl: Component {
              PanelActionButton {
                iconText: "󰑐"
                tooltipText: root.refreshBusy ? "Refreshing…" : "Refresh (r)"
                enabled: !root.refreshBusy
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.refresh()
              }
            }
          }

          // Tabs on the left; the History tab's export button on the right
          // of the same row, with its result on a line of its own below.
          Item {
            width: parent.width
            implicitHeight: Math.max(viewTabs.implicitHeight, exportButton.implicitHeight)

            ButtonGroup {
              id: viewTabs
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              options: [
                { value: "channels", label: "Channels", tooltip: "Channels (c)" },
                { value: "history", label: "History", tooltip: "Tracks you've listened to (p)" }
              ]
              value: root.view
              focusable: false
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              onChanged: function(v) { root.setView(v) }
            }

            PanelActionButton {
              id: clearButton
              visible: exportButton.visible
              anchors.right: exportButton.left
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰩹"
              tooltipText: "Clear history (x)"
              foreground: Qt.darker(root.bar.foreground, 1.4)
              hoverColor: root.bar.urgent
              fontFamily: root.bar.fontFamily
              onClicked: root.askClearHistory()
            }

            PanelActionButton {
              id: exportButton
              visible: root.view === "history" && root.historyRows.length > 0
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰈇"
              tooltipText: history.exporting ? "Exporting…" : "Export expanded days to ~/dr-lyd-history.md (e)"
              enabled: !history.exporting && root.expandedDays.length > 0
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.exportHistory()
            }
          }

          Text {
            visible: root.view === "history" && root.historyRows.length > 0
                     && (root.exportStatus !== "" || root.exportHint !== "")
            width: parent.width
            leftPadding: Style.space(6)
            rightPadding: Style.space(6)
            textFormat: Text.PlainText
            // A result from the last export wins; otherwise the standing hint.
            text: root.exportStatus || root.exportHint
            color: root.exportStatus.indexOf("Export failed") === 0 ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideMiddle
          }

          Text {
            visible: root.view === "channels" && root.fetchError !== "" && root.channels.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.fetchError
            color: root.bar.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.view === "channels" && root.channels.length === 0 && root.fetchError === ""
            textFormat: Text.PlainText
            text: "Loading channels…"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---- Grouped channel list ----
          Repeater {
            model: root.view === "channels" ? root.groupedChannels : []

            Column {
              id: groupColumn
              required property var modelData
              readonly property bool expanded: root.isGroupExpanded(modelData)
              width: parent.width
              spacing: Style.space(6)

              PanelSeparator {
                foreground: root.bar.foreground
              }

              // Section heading with a +/− on the right, lined up with the
              // hearts below. Collapsed groups show their channel count.
              CursorSurface {
                id: groupHeader
                readonly property string cursorKey: "group:" + groupColumn.modelData.key
                width: parent.width
                implicitHeight: Math.max(groupLabel.implicitHeight, groupToggle.implicitHeight) + Style.space(4)
                hasCursor: root.hasCursor(cursorKey)
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(groupHeader)
                foreground: root.bar.foreground

                PanelSectionHeader {
                  id: groupLabel
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: groupColumn.modelData.label.toUpperCase()
                    + (groupColumn.expanded ? "" : " (" + groupColumn.modelData.items.length + ")")
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) root.setCursor(groupHeader.cursorKey)
                  onClicked: root.toggleGroup(groupColumn.modelData)
                }

                PanelActionButton {
                  id: groupToggle
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: groupColumn.expanded ? "󰍴" : "󰐕"
                  tooltipText: groupColumn.expanded ? "Collapse" : "Expand"
                  foreground: Qt.darker(root.bar.foreground, 1.4)
                  hoverColor: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onHovered: function(on) { if (on) root.setCursor(groupHeader.cursorKey) }
                  onClicked: root.toggleGroup(groupColumn.modelData)
                }
              }

              Repeater {
                model: groupColumn.expanded ? groupColumn.modelData.items : []

                CursorSurface {
                  id: channelRow
                  required property var modelData
                  readonly property string cursorKey: "channel:" + modelData.slug
                  readonly property bool isPlaying: modelData.slug === root.playingSlug
                  readonly property bool isFavorite: root.isFavorite(modelData.slug)
                  width: parent.width
                  implicitHeight: Math.max(channelTitle.implicitHeight, favoriteButton.implicitHeight) + Style.space(6)
                  hasCursor: root.hasCursor(cursorKey)
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(channelRow)
                  current: isPlaying
                  foreground: root.bar.foreground

                  // Fixed slot so titles stay aligned whether or not a row plays.
                  Text {
                    id: playGlyph
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(18)
                    horizontalAlignment: Text.AlignHCenter
                    textFormat: Text.PlainText
                    text: channelRow.isPlaying ? "󰐊" : ""
                    color: Style.selectedStateColor(root.bar.foreground, Color.accent)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.icon
                  }

                  Text {
                    id: channelTitle
                    anchors.left: playGlyph.right
                    anchors.leftMargin: Style.space(6)
                    anchors.right: favoriteButton.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: channelRow.modelData.title
                    color: channelRow.isPlaying
                      ? Style.selectedStateColor(root.bar.foreground, Color.accent)
                      : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: channelRow.isPlaying
                    elide: Text.ElideRight
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onContainsMouseChanged: if (containsMouse) root.setCursor(channelRow.cursorKey)
                    onClicked: root.togglePlay(channelRow.modelData.slug)
                  }

                  PanelActionButton {
                    id: favoriteButton
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: channelRow.isFavorite ? "󰋑" : "󰋕"
                    tooltipText: channelRow.isFavorite ? "Remove from favorites (f)" : "Add to favorites (f)"
                    foreground: channelRow.isFavorite ? Color.accent : Qt.darker(root.bar.foreground, 1.4)
                    hoverColor: Color.accent
                    fontFamily: root.bar.fontFamily
                    onHovered: function(on) { if (on) root.setCursor(channelRow.cursorKey) }
                    onClicked: root.toggleFavorite(channelRow.modelData.slug)
                  }
                }
              }
            }
          }

          // ---- History: tracks from past listening sessions, per day ----
          Text {
            visible: root.view === "history" && root.historyRows.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.logHistory ? "No history yet — tracks are logged while a channel plays."
                                  : "History logging is off (logHistory)."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.view === "history" ? root.groupedHistory : []

            Column {
              id: dayColumn
              required property var modelData
              readonly property bool expanded: root.isGroupExpanded(modelData)
              width: parent.width
              spacing: Style.space(4)

              PanelSeparator {
                foreground: root.bar.foreground
              }

              // Same heading + +/− as the channel groups; collapsed days
              // show how many tracks they hold.
              CursorSurface {
                id: dayHeader
                readonly property string cursorKey: "group:" + dayColumn.modelData.key
                width: parent.width
                implicitHeight: Math.max(dayLabel.implicitHeight, dayToggle.implicitHeight) + Style.space(4)
                hasCursor: root.hasCursor(cursorKey)
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(dayHeader)
                foreground: root.bar.foreground

                PanelSectionHeader {
                  id: dayLabel
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: dayColumn.modelData.label.toUpperCase()
                    + (dayColumn.expanded ? "" : " (" + dayColumn.modelData.items.length + ")")
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) root.setCursor(dayHeader.cursorKey)
                  onClicked: root.toggleGroup(dayColumn.modelData)
                }

                PanelActionButton {
                  id: dayToggle
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: dayColumn.expanded ? "󰍴" : "󰐕"
                  tooltipText: dayColumn.expanded ? "Collapse" : "Expand"
                  foreground: Qt.darker(root.bar.foreground, 1.4)
                  hoverColor: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onHovered: function(on) { if (on) root.setCursor(dayHeader.cursorKey) }
                  onClicked: root.toggleGroup(dayColumn.modelData)
                }
              }

              Repeater {
                model: dayColumn.expanded ? dayColumn.modelData.items : []

                CursorSurface {
                  id: historyRow
                  required property var modelData
                  readonly property string cursorKey: "history:" + modelData.id
                  width: parent.width
                  implicitHeight: historyText.implicitHeight + Style.space(6)
                  hasCursor: root.hasCursor(cursorKey)
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(historyRow)
                  foreground: root.bar.foreground

                  Text {
                    id: historyTime
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(6)
                    anchors.top: historyText.top
                    textFormat: Text.PlainText
                    text: Model.historyTimeText(historyRow.modelData)
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Column {
                    id: historyText
                    anchors.left: historyTime.right
                    anchors.leftMargin: Style.space(8)
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: Model.historyTrackText(historyRow.modelData)
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      readonly property bool copied: root.copiedRowId === historyRow.modelData.id
                      text: copied ? "󰄬 Copied to clipboard"
                        : root.channelTitle(historyRow.modelData.channel)
                          + (historyRow.modelData.programme ? " · " + historyRow.modelData.programme : "")
                      color: copied ? Color.accent : Qt.darker(root.bar.foreground, 1.4)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onContainsMouseChanged: if (containsMouse) root.setCursor(historyRow.cursorKey)
                    onClicked: root.copyHistoryRow(historyRow.modelData)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
