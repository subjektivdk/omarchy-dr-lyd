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
  }

  function scheduleStateSave() {
    if (!root.stateLoaded) return
    stateSaveTimer.restart()
  }

  function flushState() {
    stateFile.setText(JSON.stringify({
      favorites: root.favorites,
      lastPlayed: root.lastPlayed,
      groups: root.groupState
    }, null, 2) + "\n")
  }

  Process {
    id: ensureStateDirProc
    command: ["mkdir", "-p", root.stateDir]
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("")
  }

  Timer {
    id: stateSaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushState()
  }

  // ---- Channel directory ----
  // Any dr.dk/lyd/<channel> page embeds the whole directory, so one fixed,
  // known-good page is scraped rather than whatever channel is configured
  // (a stale slug there would otherwise 404 and leave the list empty).
  readonly property string directoryUrl: "https://www.dr.dk/lyd/p1"
  property var channels: []
  property var groupedChannels: Model.groupChannels(root.channels, root.favorites)
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
  // through startFetch() directly so they don't reset the counter. Also
  // forces a fresh now-playing lookup, so the header button is one place
  // to manually re-check everything.
  function refresh() {
    fetchRetries = 0
    startFetch()
    root.refreshNowPlaying()
  }

  // Re-scrape once an hour at most; a manual refresh (button) always forces it.
  function refreshIfStale() {
    if (root.channels.length === 0 || (Date.now() - root.lastFetched) > 3600000) root.refresh()
  }

  function scheduleFetchRetry() {
    if (fetchRetries >= 3) return
    fetchRetries++
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
      root.playingSlug = slug
      root.lastPlayed = slug
      root.scheduleStateSave()
    })
  }

  function stop() {
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

  function toggleDefaultChannel() {
    root.togglePlay(root.startChannel)
  }

  // External control (e.g. `omarchy-shell subjektivdk.dr-lyd play p1`), for
  // scripts/agents that want to switch channel without touching the panel.
  // Deliberately separate from the base Panel's open/close/toggle IPC
  // (manageIpc: false above), since this target is about playback, not the
  // panel's visibility.
  IpcHandler {
    target: "subjektivdk.dr-lyd"
    function play(slug: string): string {
      if (root.channelBySlug(slug)) {
        root.switchTo(slug)
        return "ok"
      }
      if (root.channels.length === 0) {
        root.switchTo(slug)
        return "loading channel directory, retry shortly"
      }
      return "unknown channel: " + slug
    }
    function stop(): string {
      root.stop()
      return "ok"
    }
    function status(): string {
      return root.playingSlug ? root.playingSlug + "\t" + root.playingTitle : "stopped"
    }
    function list(): string {
      if (root.channels.length === 0) {
        root.refreshIfStale()
        return "loading channel directory, retry shortly"
      }
      var lines = []
      for (var i = 0; i < root.channels.length; i++)
        lines.push(root.channels[i].slug + "\t" + root.channels[i].title)
      return lines.join("\n")
    }
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
      }
    }
  }

  Timer {
    id: reconnectTimer
    property string slug: ""
    interval: 2000
    onTriggered: if (slug) root.switchTo(slug, true)
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
    onTriggered: root.nowClock = Date.now()
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

  // Manual re-check from the header button: jump the queue instead of
  // waiting for the scheduled poll.
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

  // The directory is fetched lazily: on first panel open, or when a play
  // request needs it. Nothing contacts dr.dk just because the shell started.
  Component.onCompleted: ensureStateDirProc.running = true

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

  readonly property bool refreshBusy: fetchProc.running || nowPlayingProc.running

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
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "f") root.favoriteCursor()
        else if (t === "r") root.refresh()
        else if (t === "s") root.stop()
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

          Text {
            visible: root.fetchError !== "" && root.channels.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.fetchError
            color: root.bar.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.channels.length === 0 && root.fetchError === ""
            textFormat: Text.PlainText
            text: "Loading channels…"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---- Grouped channel list ----
          Repeater {
            model: root.groupedChannels

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
        }
      }
    }
  }
}
