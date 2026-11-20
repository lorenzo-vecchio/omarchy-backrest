import QtQuick
import QtQuick.Effects
import qs.Commons

// The Backrest mark, painted in the theme foreground through its alpha, with a
// small status dot in the corner. The source PNG is the white mark extracted
// from Backrest's own favicon; a raster source keeps this cheap to decode and
// works on every Quickshell build (no SVG module needed).
Item {
  id: root

  property color color: "white"
  property color dotColor: "transparent"
  property real dotSize: Math.max(4, Math.round(Math.min(width, height) * 0.32))
  property bool pulse: false

  implicitWidth: 16
  implicitHeight: 16

  Image {
    id: mark
    anchors.fill: parent
    source: Qt.resolvedUrl("assets/backrest-symbolic.png")
    fillMode: Image.PreserveAspectFit
    sourceSize.width: Math.round(width * Screen.devicePixelRatio)
    sourceSize.height: Math.round(height * Screen.devicePixelRatio)
    visible: false
    layer.enabled: true
  }

  MultiEffect {
    anchors.fill: mark
    source: mark
    colorization: 1.0
    colorizationColor: root.color
  }

  Rectangle {
    id: dot
    visible: root.dotColor.a > 0
    width: root.dotSize
    height: root.dotSize
    radius: width / 2
    color: root.dotColor
    x: root.width - width - Math.round(root.width * 0.02)
    y: root.height - height - Math.round(root.height * 0.02)
    border.width: root.dotSize >= 7 ? 1 : 0
    border.color: Qt.rgba(0, 0, 0, 0.28)

    SequentialAnimation on opacity {
      running: root.pulse
      loops: Animation.Infinite
      NumberAnimation { to: 0.35; duration: Style.duration(700); easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1.0; duration: Style.duration(700); easing.type: Easing.InOutQuad }
    }
  }
}
