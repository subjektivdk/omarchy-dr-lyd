import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "subjektivdk.dr-lyd"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function toggleDefaultChannel() {
    if (panelLoader.item && panelLoader.item.toggleDefaultChannel) panelLoader.item.toggleDefaultChannel()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  readonly property bool playing: panelLoader.item ? panelLoader.item.playingSlug !== "" : false
  readonly property string playingTitle: panelLoader.item ? panelLoader.item.playingTitle : ""

  // assets/dr-mark.png is an 88x35 white-on-transparent mask: DR's wordmark
  // condensed to the proportions DR uses for its own square favicon. The
  // widget keeps the standard icon slot width; the mark spans that slot
  // minus a small side margin (wider than the 16px glyph canvas, or two
  // letters would be unreadable) and its height follows from the aspect.
  // Everything derives from bar tokens, so it scales with the font scale
  // and theme overrides like every other bar icon.
  readonly property real markWidth: Style.bar.iconSlot - Style.space(6)
  readonly property real markHeight: markWidth * (35 / 88)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.playing ? ("Afspiller " + root.playingTitle + " — klik for kanaler") : "DR Lyd — klik for kanaler"

    iconComponent: Component {
      Item {
        // Fills the optical canvas; the mark overflows it horizontally on
        // purpose (nothing clips) and is centered on it.
        Image {
          id: mark
          anchors.centerIn: parent
          width: root.markWidth
          height: root.markHeight
          rotation: root.bar && root.bar.vertical ? 90 : 0
          source: Qt.resolvedUrl("assets/dr-mark.png")
          fillMode: Image.PreserveAspectFit
          // Decode at physical pixels so the mark stays crisp on HiDPI.
          sourceSize.width: Math.round(width * Screen.devicePixelRatio)
          sourceSize.height: Math.round(height * Screen.devicePixelRatio)
          smooth: true
          // Hidden; MultiEffect samples it as a layer and paints the recolored copy.
          visible: false
          layer.enabled: true
        }

        MultiEffect {
          anchors.fill: mark
          rotation: mark.rotation
          source: mark
          colorization: 1.0
          colorizationColor: button.foreground
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.toggleDefaultChannel()
      else root.togglePanel()
    }
  }
}
