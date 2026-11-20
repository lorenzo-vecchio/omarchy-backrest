import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Status.js" as Status

Panel {
  id: root
  moduleName: "io.github.lorenzo-vecchio.backrest"
  ipcTarget: "io.github.lorenzo-vecchio.backrest"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property QtObject service: null
  property int cursor: 0

  readonly property var planList: service ? service.plans : []
  readonly property var runningList: service ? service.running : []
  readonly property var recentList: service ? service.recent : []
  readonly property var historyDays: service ? service.history : []
  readonly property var repoList: service ? service.repos : []
  readonly property string health: service ? service.health : "offline"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(root.barForeground, 1.5)
  readonly property int actionCount: planList.length + 1
  readonly property var runningJob: {
    for (var i = 0; i < runningList.length; i++) {
      if (runningList[i].type === "backup") return runningList[i]
    }
    return null
  }
  readonly property int runningPercent: runningJob && runningJob.percent >= 0
    ? Math.round(runningJob.percent * 100) : -1
  readonly property string healthDetail: {
    if (!service || !service.online) return strings.t("panel.health.offline")
    if (health !== "running") return strings.t("panel.health." + health)
    return runningJob ? strings.t("panel.health.running") : strings.t("panel.health.busy")
  }

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  function statusColor(kind) {
    if (kind === "ok") return Status.color("success")
    return Status.color(kind)
  }

  function statusLabel(kind) {
    return strings.t("status." + (kind === "ok" ? "success" : kind))
  }

  function planMeta(plan) {
    var repo = plan.repo !== "" ? plan.repo : strings.t("plan.none")
    var last = plan.last ? service.relativeAge(plan.last.timestamp) : strings.t("plan.never")
    var next = plan.nextBackupMs > 0 ? service.relativeNext(plan.nextBackupMs) : strings.t("next.unknown")
    return strings.t("plan.meta").arg(repo).arg(last).arg(next)
  }

  function planButtonLabel(plan) {
    if (service.startingPlan === plan.id) return strings.t("plan.starting")
    if (service.planIsRunning(plan.id)) return strings.t("plan.running")
    return strings.t("plan.backupNow")
  }

  function canStart(plan) {
    return service && service.online && service.startingPlan === "" && !service.planIsRunning(plan.id)
  }

  function openWebUi() {
    if (service) service.openWebUi()
  }

  function moveCursor(delta) {
    if (actionCount <= 0) return
    cursor = (cursor + delta + actionCount) % actionCount
  }

  function activateCursor() {
    if (cursor >= 0 && cursor < planList.length) {
      var plan = planList[cursor]
      if (canStart(plan)) service.startBackup(plan.id)
      return
    }
    openWebUi()
  }

  function historyTotalText() {
    if (!service || historyDays.length === 0) return strings.t("history.empty")
    return strings.t("history.total").arg(service.bytes(service.bytesAdded30))
  }

  function recentMeta(row) {
    if (!service) return ""
    return strings.t("recent.meta").arg(service.dateTime(row.timestamp)).arg(service.duration(row.durationMs))
  }

  function recentBytes(row) {
    if (!service || row.bytesAdded <= 0) return ""
    return service.bytes(row.bytesAdded)
  }

  function runningTitle() {
    if (runningJob) return strings.t("running.title").arg(runningJob.planId)
    if (service && service.optimisticPlan !== "") return strings.t("running.starting").arg(service.optimisticPlan)
    if (runningList.length > 0) return strings.t("running.maintenance")
    return strings.t("running.preparing")
  }

  function runningProgress() {
    if (!runningJob || runningJob.percent < 0) return strings.t("running.preparing")
    return strings.t("running.progress")
      .arg(Commons.I18n.formatNumber(root.runningPercent))
      .arg(service.bytes(runningJob.bytesDone))
      .arg(service.bytes(runningJob.totalBytes))
  }

  onOpenedChanged: {
    if (opened) {
      cursor = 0
      if (service) service.refresh(true)
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(430))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight, Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTextKey: function(text) {
        var key = String(text).toLowerCase()
        if (key === "r") {
          if (root.service) root.service.refresh(true)
        } else if (key === "o") {
          root.openWebUi()
        } else if (key === "b") {
          root.activateCursor()
        }
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: flick.width - (flick.interactive ? Style.space(8) : 0)
          spacing: Style.space(12)

          // ---------- hero ------------------------------------------------
          PanelHero {
            width: parent.width
            title: strings.t("panel.title")
            meta: root.service && root.service.online
              ? (root.service.instance !== "" ? root.service.instance.toUpperCase() : strings.t("panel.online"))
              : strings.t("panel.offline")
            detail: root.service && root.service.online ? root.healthDetail : ""
            foreground: root.barForeground
            fontFamily: root.fontFamily
            iconComponent: Component {
              BackrestMark {
                width: Style.space(44)
                height: Style.space(34)
                color: root.barForeground
                dotColor: Status.color(root.health)
                dotSize: Style.space(10)
                pulse: root.health === "running"
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(2)
                PanelActionButton {
                  iconText: root.service && root.service.loading ? "󰔟" : "󰑐"
                  tooltipText: strings.t("refresh")
                  foreground: root.barForeground
                  onClicked: if (root.service) root.service.refresh(true)
                }
                PanelActionButton {
                  iconText: "󰖟"
                  tooltipText: strings.t("openWeb")
                  foreground: root.barForeground
                  enabled: root.service && root.service.baseUrl !== ""
                  onClicked: root.openWebUi()
                }
              }
            }
          }

          // ---------- unreachable ------------------------------------------
          BorderSurface {
            width: parent.width
            visible: !root.service || !root.service.online
            color: Status.alphaColor("error", 0.10)
            borderSpec: Border.controlSpec("normal", Status.color("error"), Commons.Color.accent)
            radius: Style.cornerRadius
            padding: Style.space(10)
            implicitHeight: errorColumn.implicitHeight + contentTopInset + contentBottomInset

            Column {
              id: errorColumn
              x: parent.contentLeftInset
              y: parent.contentTopInset
              width: parent.width - parent.contentLeftInset - parent.contentRightInset
              spacing: Style.space(6)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.service ? root.service.errorText : strings.t("error.network").arg("")
                color: root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              Row {
                spacing: Style.space(8)
                Button {
                  text: strings.t("retry")
                  foreground: root.barForeground
                  bordered: true
                  onClicked: if (root.service) root.service.refresh(true)
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: strings.t("footer.settingsHint")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  width: parent.width - parent.children[0].width - Style.space(8)
                }
              }
            }
          }

          // ---------- running backup --------------------------------------
          BorderSurface {
            width: parent.width
            visible: root.health === "running"
            color: Status.alphaColor("running", 0.10)
            borderSpec: Border.controlSpec("normal", Status.color("running"), Commons.Color.accent)
            radius: Style.cornerRadius
            padding: Style.space(10)
            implicitHeight: runningColumn.implicitHeight + contentTopInset + contentBottomInset

            Column {
              id: runningColumn
              x: parent.contentLeftInset
              y: parent.contentTopInset
              width: parent.width - parent.contentLeftInset - parent.contentRightInset
              spacing: Style.space(7)

              Item {
                width: parent.width
                height: Math.max(runningTitleText.implicitHeight, runningPercentText.implicitHeight)

                Text {
                  id: runningTitleText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - runningPercentText.width - Style.space(8)
                  textFormat: Text.PlainText
                  text: root.runningTitle()
                  elide: Text.ElideRight
                  color: root.barForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  id: runningPercentText
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  visible: root.runningPercent >= 0
                  text: root.runningPercent >= 0
                    ? Commons.I18n.formatNumber(root.runningPercent) + "%" : ""
                  color: Status.color("running")
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(3)
                radius: height / 2
                color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.14)

                Rectangle {
                  width: parent.width * Math.max(0, Math.min(1, root.runningJob ? root.runningJob.percent : 0))
                  height: parent.height
                  radius: parent.radius
                  color: Status.color("running")
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.runningProgress()
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                visible: root.runningList.length > 1
                textFormat: Text.PlainText
                text: strings.t("running.more").arg(Commons.I18n.formatNumber(root.runningList.length - 1))
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---------- summary ---------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(8)

            Stat {
              width: (parent.width - parent.spacing * 2) / 3
              label: strings.t("section.lastBackup")
              value: root.service ? root.service.ageText : "—"
              sub: root.service && root.service.lastBackup
                ? root.service.dateTime(root.service.lastBackup.timestamp) : ""
              valueColor: root.service && root.service.lastBackup
                ? root.statusColor(root.service.lastBackup.status) : root.dim
              labelColor: root.dim
              fontFamily: root.fontFamily
            }

            Stat {
              width: (parent.width - parent.spacing * 2) / 3
              label: strings.t("section.nextBackup")
              value: root.service ? root.service.nextText : "—"
              sub: root.service && root.service.nextBackupMs > 0
                ? root.service.dateTime(root.service.nextBackupMs) : ""
              valueColor: root.service && root.service.overdue
                ? Status.color("warning") : root.barForeground
              labelColor: root.dim
              fontFamily: root.fontFamily
            }

            Stat {
              width: (parent.width - parent.spacing * 2) / 3
              label: strings.t("section.protected")
              value: root.service ? root.service.bytes(root.service.totalProtectedBytes) : "—"
              sub: root.service
                ? strings.t("history.legend").arg(Commons.I18n.formatNumber(root.service.success30)).arg(root.statusLabel("success"))
                : ""
              valueColor: root.barForeground
              labelColor: root.dim
              fontFamily: root.fontFamily
            }
          }

          // ---------- 30-day history --------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(7)

            PanelSeparator { foreground: root.barForeground }

            Item {
              width: parent.width
              height: Math.max(historyHeader.implicitHeight, historyTotal.implicitHeight)

              PanelSectionHeader {
                id: historyHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("section.history")
                foreground: root.barForeground
                fontFamily: root.fontFamily
              }

              Text {
                id: historyTotal
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.historyTotalText()
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              id: historyRow
              width: parent.width
              spacing: Style.space(2)
              readonly property real cell: Math.max(2,
                (width - spacing * Math.max(0, root.historyDays.length - 1))
                / Math.max(1, root.historyDays.length))

              Repeater {
                model: root.historyDays
                delegate: Item {
                  required property var modelData
                  width: historyRow.cell
                  height: Style.space(34)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.space(1)
                    color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.07)
                  }

                  Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: Math.max(2, parent.height * modelData.scale)
                    radius: Style.space(1)
                    color: Status.color(modelData.kind)
                    opacity: modelData.kind === "none" ? 0.16 : 0.95
                  }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(12)

              Repeater {
                model: [
                  { kind: "success", count: root.service ? root.service.success30 : 0 },
                  { kind: "warning", count: root.service ? root.service.warning30 : 0 },
                  { kind: "error", count: root.service ? root.service.failed30 : 0 }
                ]
                delegate: Row {
                  required property var modelData
                  spacing: Style.space(4)

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(6)
                    height: width
                    radius: width / 2
                    color: Status.color(modelData.kind)
                    opacity: modelData.count > 0 ? 1 : 0.35
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: strings.t("history.legend")
                      .arg(Commons.I18n.formatNumber(modelData.count))
                      .arg(root.statusLabel(modelData.kind))
                    color: modelData.count > 0 ? root.dim : Qt.darker(root.dim, 1.3)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          // ---------- recent backups --------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(7)
            visible: root.recentList.length > 0

            PanelSeparator { foreground: root.barForeground }
            PanelSectionHeader {
              text: strings.t("section.recent")
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.recentList.slice(0, 5)
              delegate: Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(6)
                  height: width
                  radius: width / 2
                  color: root.statusColor(modelData.status)
                }

                Column {
                  width: parent.width - Style.space(6) - Style.space(8)
                    - bytesText.width - statusText.width - Style.space(8) * 3
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: modelData.planId
                    elide: Text.ElideRight
                    color: root.barForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: root.recentMeta(modelData)
                    elide: Text.ElideRight
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  id: bytesText
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: root.recentBytes(modelData)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  id: statusText
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: root.statusLabel(modelData.status)
                  color: root.statusColor(modelData.status)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: modelData.status === "error" || modelData.status === "warning"
                }
              }
            }
          }

          // ---------- plans -----------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(5)

            PanelSeparator { foreground: root.barForeground }
            PanelSectionHeader {
              text: strings.t("section.plans")
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              visible: root.planList.length === 0
              textFormat: Text.PlainText
              text: strings.t("plans.empty")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.planList
              delegate: Item {
                id: planItem
                required property var modelData
                required property int index
                width: parent.width
                height: planRow.implicitHeight + Style.space(10)

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.cursor = planItem.index
                  onClicked: {
                    root.cursor = planItem.index
                    if (root.canStart(planItem.modelData)) root.service.startBackup(planItem.modelData.id)
                  }
                }

                CursorSurface {
                  anchors.fill: parent
                  hasCursor: root.cursor === planItem.index
                  foreground: root.barForeground
                }

                Row {
                  id: planRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(8)

                  Column {
                    width: parent.width - planButton.width - parent.spacing
                    spacing: Style.space(1)

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: planItem.modelData.id
                      elide: Text.ElideRight
                      color: root.barForeground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: root.planMeta(planItem.modelData)
                      elide: Text.ElideRight
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Button {
                    id: planButton
                    text: root.planButtonLabel(planItem.modelData)
                    enabled: root.canStart(planItem.modelData)
                    hasCursor: root.cursor === planItem.index
                    bordered: true
                    foreground: root.barForeground
                    fontSize: Style.font.bodySmall
                    onClicked: root.service.startBackup(planItem.modelData.id)
                  }
                }
              }
            }
          }

          // ---------- action feedback -------------------------------------
          Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: text !== ""
            text: root.service
              ? (root.service.actionErrorText !== "" ? root.service.actionErrorText : root.service.actionMessage)
              : ""
            color: root.service && root.service.actionErrorText !== "" ? Status.color("error") : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---------- open web UI -----------------------------------------
          Button {
            width: parent.width
            text: strings.t("openWeb")
            leftAlign: true
            bordered: true
            foreground: root.barForeground
            hasCursor: root.cursor === root.planList.length
            enabled: root.service && root.service.baseUrl !== ""
            onHovered: function(isHovered) { if (isHovered) root.cursor = root.planList.length }
            onClicked: root.openWebUi()
          }

          // ---------- footer ----------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(2)

            PanelSeparator { foreground: root.barForeground }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.service && root.service.lastUpdatedMs > 0
                ? strings.t("footer.updated").arg(root.service.timeOnly(root.service.lastUpdatedMs))
                : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.service ? root.service.baseUrl : ""
              color: Qt.darker(root.dim, 1.15)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }

  component Stat: Column {
    id: stat
    property string label: ""
    property string value: ""
    property string sub: ""
    property color valueColor: Commons.Color.foreground
    property color labelColor: Commons.Color.muted
    property string fontFamily: Style.font.family
    spacing: Style.space(2)

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: stat.label
      elide: Text.ElideRight
      color: stat.labelColor
      font.family: stat.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: stat.value
      elide: Text.ElideRight
      color: stat.valueColor
      font.family: stat.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      visible: stat.sub !== ""
      text: stat.sub
      elide: Text.ElideRight
      color: stat.labelColor
      font.family: stat.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
