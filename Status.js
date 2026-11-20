.pragma library

// One palette for the bar dot and the panel rows. These are status colors, not
// theme roles: green/amber/red/blue keep their meaning in every Omarchy theme.
function color(kind) {
  if (kind === "success" || kind === "ok") return "#55a86f"
  if (kind === "warning") return "#d5a03f"
  if (kind === "error") return "#d15858"
  if (kind === "running") return "#4f93d1"
  return "#7d858c"
}

function alphaColor(kind, alpha) {
  var hex = color(kind)
  var r = parseInt(hex.substring(1, 3), 16) / 255
  var g = parseInt(hex.substring(3, 5), 16) / 255
  var b = parseInt(hex.substring(5, 7), 16) / 255
  return Qt.rgba(r, g, b, alpha)
}
