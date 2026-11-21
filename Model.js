.pragma library

// Parsing helpers for the JSON that Backrest's Connect API returns. Every
// number in a protobuf int64 field arrives as a string, so `num()` is used
// everywhere instead of trusting the wire type.

function arr(value) {
  return Array.isArray(value) ? value : []
}

function obj(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : ({})
}

function str(value) {
  return value === undefined || value === null ? "" : String(value)
}

function num(value) {
  var parsed = Number(value)
  return isFinite(parsed) ? parsed : 0
}

function statusKind(raw) {
  var value = str(raw).toUpperCase()
  if (value.indexOf("STATUS_") === 0) value = value.substring(7)
  if (value === "SUCCESS") return "success"
  if (value === "WARNING") return "warning"
  if (value === "ERROR") return "error"
  if (value === "INPROGRESS") return "running"
  if (value === "PENDING") return "pending"
  if (value.indexOf("CANCELLED") !== -1) return "cancelled"
  return "unknown"
}

// Only completed outcomes count toward a plan's health. A cancelled run says
// nothing about whether the last real backup worked.
function completedKind(raw) {
  var kind = statusKind(raw)
  if (kind === "success" || kind === "warning" || kind === "error") return kind
  return ""
}

function severity(kind) {
  if (kind === "error") return 5
  if (kind === "warning") return 4
  if (kind === "running") return 3
  if (kind === "pending") return 2
  if (kind === "success") return 1
  return 0
}

function worst(kinds) {
  var winner = "none"
  for (var i = 0; i < kinds.length; i++) {
    if (severity(kinds[i]) > severity(winner)) winner = kinds[i]
  }
  return winner
}

function dayKey(timestampMs) {
  var date = new Date(timestampMs)
  return date.getFullYear() + "-" + (date.getMonth() + 1) + "-" + date.getDate()
}

function startOfDay(timestampMs) {
  var date = new Date(timestampMs)
  date.setHours(0, 0, 0, 0)
  return date.getTime()
}

function parseRecent(summary) {
  var recent = obj(summary.recentBackups)
  var timestamps = arr(recent.timestampMs)
  var statuses = arr(recent.status)
  var durations = arr(recent.durationMs)
  var bytes = arr(recent.bytesAdded)
  var flows = arr(recent.flowId)
  var rows = []
  var limit = Math.min(timestamps.length, 100)
  for (var i = 0; i < limit; i++) {
    var timestamp = num(timestamps[i])
    if (timestamp <= 0) continue
    rows.push({
      planId: str(summary.id),
      timestamp: timestamp,
      status: statusKind(statuses[i]),
      rawStatus: str(statuses[i]),
      durationMs: num(durations[i]),
      bytesAdded: num(bytes[i]),
      flowId: str(flows[i])
    })
  }
  rows.sort(function(a, b) { return b.timestamp - a.timestamp })
  return rows
}

function parsePlans(dashboard, planRepos) {
  var summaries = arr(obj(dashboard).planSummaries)
  var plans = []
  var planLimit = Math.min(summaries.length, 100)
  for (var i = 0; i < planLimit; i++) {
    var summary = summaries[i]
    var recent = parseRecent(summary)
    var last = null
    for (var j = 0; j < recent.length; j++) {
      if (completedKind(recent[j].status) !== "") {
        last = recent[j]
        break
      }
    }

    var history = []
    var rawHistory = arr(summary.historyLast30days)
    var historyLimit = Math.min(rawHistory.length, 90)
    for (var h = 0; h < historyLimit; h++) {
      var day = rawHistory[h]
      var statusCounts = arr(day.statusCounts)
      var kinds = []
      var counts = { success: 0, warning: 0, error: 0 }
      for (var s = 0; s < statusCounts.length; s++) {
        var kind = statusKind(statusCounts[s].status)
        if (kind !== "success" && kind !== "warning" && kind !== "error") continue
        counts[kind] += num(statusCounts[s].count)
        kinds.push(kind)
      }
      history.push({
        timestamp: num(day.timestampMs),
        bytesAdded: num(day.bytesAdded),
        bytesScanned: num(day.bytesScanned),
        kind: worst(kinds),
        counts: counts
      })
    }

    plans.push({
      id: str(summary.id),
      repo: str(planRepos[str(summary.id)]),
      nextBackupMs: num(summary.nextBackupTimeMs),
      success30: num(summary.backupsSuccessLast30days),
      warning30: num(summary.backupsWarningLast30days),
      failed30: num(summary.backupsFailed30days),
      bytesAdded30: num(summary.bytesAddedLast30days),
      bytesScanned30: num(summary.bytesScannedLast30days),
      protectedBytes: num(summary.protectedBytes),
      recent: recent,
      last: last,
      history: history
    })
  }
  return plans
}

function parseRepos(dashboard) {
  var summaries = arr(obj(dashboard).repoSummaries)
  var repos = []
  var repoLimit = Math.min(summaries.length, 100)
  for (var i = 0; i < repoLimit; i++) {
    var summary = summaries[i]
    repos.push({
      id: str(summary.id),
      protectedBytes: num(summary.protectedBytes),
      success30: num(summary.backupsSuccessLast30days),
      warning30: num(summary.backupsWarningLast30days),
      failed30: num(summary.backupsFailedLast30days),
      bytesAdded30: num(summary.bytesAddedLast30days)
    })
  }
  return repos
}

// Build a contiguous window of days, oldest first, so a day without a backup
// is drawn as an empty slot instead of silently shifting the chart.
function buildHistory(plans, windowDays) {
  var byDay = ({})
  var planCount = arr(plans).length
  for (var i = 0; i < planCount; i++) {
    var history = arr(plans[i].history)
    for (var h = 0; h < history.length; h++) {
      var day = history[h]
      if (day.timestamp <= 0) continue
      var key = dayKey(day.timestamp)
      if (!byDay[key]) {
        byDay[key] = { timestamp: day.timestamp, bytesAdded: 0, counts: { success: 0, warning: 0, error: 0 }, kinds: [] }
      }
      var entry = byDay[key]
      entry.timestamp = Math.max(entry.timestamp, day.timestamp)
      entry.bytesAdded += day.bytesAdded
      entry.counts.success += day.counts.success
      entry.counts.warning += day.counts.warning
      entry.counts.error += day.counts.error
      if (day.kind !== "none") entry.kinds.push(day.kind)
    }
  }

  var today = startOfDay(Date.now())
  var oneDay = 24 * 60 * 60 * 1000
  var days = []
  var maxBytes = 0
  for (var offset = windowDays - 1; offset >= 0; offset--) {
    var timestamp = today - offset * oneDay
    var found = byDay[dayKey(timestamp)]
    var kind = found ? worst(found.kinds) : "none"
    var bytesAdded = found ? found.bytesAdded : 0
    if (bytesAdded > maxBytes) maxBytes = bytesAdded
    days.push({
      timestamp: timestamp,
      bytesAdded: bytesAdded,
      counts: found ? found.counts : { success: 0, warning: 0, error: 0 },
      kind: kind
    })
  }

  // Square-root scaling keeps a small nightly run visible next to a large one.
  for (var d = 0; d < days.length; d++) {
    days[d].scale = maxBytes > 0 && days[d].bytesAdded > 0
      ? Math.max(0.08, Math.sqrt(days[d].bytesAdded / maxBytes))
      : 0
  }

  return { days: days, maxBytes: maxBytes }
}

function mergeRecent(plans, limit) {
  var rows = []
  for (var i = 0; i < plans.length; i++) {
    var recent = arr(plans[i].recent)
    for (var r = 0; r < recent.length; r++) rows.push(recent[r])
  }
  rows.sort(function(a, b) { return b.timestamp - a.timestamp })
  return rows.slice(0, Math.max(0, limit))
}

function runningOperations(operations) {
  var rows = []
  var list = arr(obj(operations).operations)
  var limit = Math.min(list.length, 200)
  for (var i = 0; i < limit; i++) {
    var operation = list[i]
    if (statusKind(operation.status) !== "running") continue
    var backup = obj(operation.operationBackup)
    var row = {
      id: str(operation.id),
      planId: str(operation.planId),
      repoId: str(operation.repoId),
      type: Object.keys(backup).length > 0 ? "backup" : "task",
      percent: -1,
      bytesDone: 0,
      totalBytes: 0,
      filesDone: 0,
      totalFiles: 0,
      currentFile: ""
    }
    if (row.type === "backup") {
      var lastStatus = obj(backup.lastStatus)
      var status = obj(lastStatus.status)
      row.percent = num(status.percentDone)
      row.bytesDone = num(status.bytesDone)
      row.totalBytes = num(status.totalBytes)
      row.filesDone = num(status.filesDone)
      row.totalFiles = num(status.totalFiles)
      row.currentFile = str(arr(status.currentFile)[0])
      if (row.percent < 0) row.percent = 0
    }
    rows.push(row)
  }
  return rows
}

// Operations already carry both ids. Taking the newest operation per plan
// gives the display labels without fetching GetConfig, whose response can
// include repository passwords and storage environment values.
function operationPlanRepos(operations) {
  var map = ({})
  var latest = ({})
  var list = arr(obj(operations).operations)
  var limit = Math.min(list.length, 200)
  for (var i = 0; i < limit; i++) {
    var operation = list[i]
    var planId = str(operation.planId)
    var repoId = str(operation.repoId)
    if (planId === "" || repoId === "") continue
    var timestamp = num(operation.unixTimeStartMs)
    if (!(planId in latest) || timestamp >= latest[planId]) {
      map[planId] = repoId
      latest[planId] = timestamp
    }
  }
  return map
}

function sumPlans(plans, field) {
  var total = 0
  for (var i = 0; i < plans.length; i++) total += num(plans[i][field])
  return total
}
