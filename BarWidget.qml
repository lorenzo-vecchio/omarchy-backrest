import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Status.js" as Status

BarWidget {
  id: root
  moduleName: "io.github.lorenzo-vecchio.backrest"

  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  readonly property color iconColor: service.online ? foreground : Qt.darker(foreground, 1.9)
  readonly property color dotColor: Status.color(service.health)
  readonly property bool showAge: String(setting("showAge", true)) !== "false"
  readonly property string ageLabel: showAge && !vertical && service.online ? service.ageShort : ""
  readonly property real barSlotSize: Style.bar.iconSlot
    + (ageLabel !== "" ? ageMetrics.advanceWidth(ageLabel) + Style.space(5) : 0)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Service {
    id: service
    settings: root.settings
    bar: root.bar
  }

  FontMetrics {
    id: ageMetrics
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.bar.iconFont
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.service = service
    target.anchorItem = button
    target.hostWidget = root
  }

  function refresh() {
    service.refresh(true)
  }

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function status() {
    return service.health
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: root.injectPanel()
  }

  IpcHandler {
    target: "io.github.lorenzo-vecchio.backrest"
    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string { return root.status() }
    function backup(plan: string): string {
      if (!plan) return "missing plan"
      service.startBackup(String(plan))
      return "ok"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: root.barSlotSize
    labelText: root.ageLabel
    active: service.health === "error"
    tooltipText: service.tooltip
    iconComponent: Component {
      Item {
        width: button.canvasSize
        height: button.canvasSize

        BackrestMark {
          anchors.centerIn: parent
          width: Style.space(15)
          height: Style.space(11.6)
          color: root.iconColor
          dotColor: root.dotColor
          pulse: service.health === "running"
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else if (buttonCode === Qt.RightButton) service.openWebUi()
      else root.toggle()
    }
  }
}
