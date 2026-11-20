import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// Owns all Backrest traffic and status state. It lives in BarWidget so polling
// continues while the panel is closed, which is what keeps the bar indicator
// (and its tooltip) accurate at a glance.
Item {
  id: root

  property var settings: ({})
  property var bar: null

  readonly property string configuredToken: String(setting("authToken", "")).trim()
  readonly property string username: String(setting("username", ""))
  readonly property string password: String(setting("password", ""))
  readonly property string rawServerUrl: String(setting("serverUrl", "http://127.0.0.1:9898"))
  readonly property string baseUrl: normalizeUrl(rawServerUrl)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)

  // --- observable status ---------------------------------------------------

  property bool online: false
  property bool loading: false
  property string errorKind: ""
  property string errorCode: ""
  property string errorDetail: ""
  property string instance: ""
  property var plans: []
  property var repos: []
  property var recent: []
  property var history: []
  property double historyMaxBytes: 0
  property var running: []
  property double totalProtectedBytes: 0
  property int success30: 0
  property int warning30: 0
  property int failed30: 0
  property double bytesAdded30: 0
  property double lastUpdatedMs: 0
  property string actionMessage: ""
  property string actionError: ""
  property string startingPlan: ""
  property string optimisticPlan: ""
  property double optimisticStartMs: 0
  property double optimisticUntil: 0
  property double nowMs: Date.now()

  // --- derived status ------------------------------------------------------

  readonly property var lastBackup: {
    for (var i = 0; i < recent.length; i++) {
      var kind = recent[i].status
      if (kind === "success" || kind === "warning" || kind === "error") return recent[i]
    }
    return null
  }

  readonly property double nextBackupMs: {
    var best = 0
    for (var i = 0; i < plans.length; i++) {
      var next = plans[i].nextBackupMs
      if (next > 0 && (best === 0 || next < best)) best = next
    }
    return best
  }

  readonly property bool overdue: {
    var now = nowMs
    for (var i = 0; i < plans.length; i++) {
      var next = plans[i].nextBackupMs
      if (next > 0 && next < now - 60 * 60 * 1000) return true
    }
    return false
  }

  readonly property string health: {
    if (!online) return "offline"
    if (startingPlan !== "" || optimisticPlan !== "" || running.length > 0) return "running"
    var result = "ok"
    for (var i = 0; i < plans.length; i++) {
      var last = plans[i].last
      if (!last) continue
      if (last.status === "error") return "error"
      if (last.status === "warning") result = "warning"
    }
    if (result === "ok" && overdue) return "warning"
    return result
  }

  readonly property string ageShort: {
    if (!online) return ""
    if (!lastBackup) return "—"
    var minutes = Math.max(0, Math.floor((nowMs - lastBackup.timestamp) / 60000))
    if (minutes < 1) return strings.t("age.shortNow")
    if (minutes < 60) return minutes + "m"
    var hours = Math.floor(minutes / 60)
    if (hours < 48) return hours + "h"
    return Math.floor(hours / 24) + "d"
  }

  readonly property string ageText: {
    if (!lastBackup) return strings.t("age.never")
    return relativeAge(lastBackup.timestamp)
  }

  readonly property string nextText: {
    if (nextBackupMs <= 0) return strings.t("next.unknown")
    return relativeNext(nextBackupMs)
  }

  readonly property string tooltip: {
    if (baseUrl === "") return strings.t("error.url")
    if (!online) return strings.t("bar.offline").arg(baseUrl)
    if (running.length > 0) {
      var job = running[0]
      var suffix = job.percent >= 0 ? " · " + Math.round(job.percent * 100) + "%" : ""
      return strings.t("bar.running").arg(job.planId) + suffix
    }
    if (startingPlan !== "") return strings.t("bar.starting").arg(startingPlan)
    if (optimisticPlan !== "") return strings.t("bar.starting").arg(optimisticPlan)
    if (health === "error") return strings.t("bar.error").arg(ageText)
    if (overdue) return strings.t("bar.overdue").arg(ageText)
    if (health === "warning") return strings.t("bar.warning").arg(ageText)
    return strings.t("bar.ok").arg(ageText).arg(nextText)
  }

  readonly property string errorText: {
    if (errorKind === "") return ""
    if (baseUrl === "") return strings.t("error.url")
    if (errorKind === "http") {
      var suffix = errorDetail !== "" ? " " + errorDetail : ""
      return strings.t("error.http").arg(errorCode) + suffix
    }
    if (errorKind === "parse") return strings.t("error.parse")
    if (errorKind === "auth") return strings.t("error.auth")
    if (errorKind === "login") return strings.t("error.login")
    return strings.t("error.network").arg(baseUrl)
  }

  readonly property string actionErrorText: actionError !== ""
    ? strings.t("action.failed").arg(actionError) : ""

  // --- helper functions ----------------------------------------------------

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, minimum, maximum) {
    var parsed = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(parsed)) parsed = fallback
    return Math.max(minimum, Math.min(maximum, parsed))
  }

  function normalizeUrl(value) {
    var url = String(value || "").trim().replace(/\/+$/, "")
    if (!/^https?:\/\/[^\s"'<>]+$/i.test(url)) return ""
    return url
  }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function parseJson(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      return parsed && typeof parsed === "object" ? parsed : null
    } catch (error) {
      return null
    }
  }

  // curl appends \n<status> via -w, which keeps the body intact even when it
  // contains newlines.
  function splitResponse(raw) {
    var text = String(raw || "")
    var index = text.lastIndexOf("\n")
    if (index !== -1) {
      var tail = text.substring(index + 1).trim()
      if (/^\d{3}$/.test(tail)) {
        return { status: Number(tail), body: text.substring(0, index) }
      }
    }
    return { status: 0, body: text }
  }

  function apiMessage(body) {
    var parsed = parseJson(body)
    var message = parsed ? String(parsed.message || "") : ""
    message = message.replace(/\s+/g, " ").trim()
    return message.length > 160 ? message.substring(0, 157) + "…" : message
  }

  function isAuthFailure(status, body) {
    return status === 401 || status === 403 || String(body).indexOf("unauthenticated") !== -1
  }

  function bearerToken() {
    return configuredToken !== "" ? configuredToken : sessionToken
  }

  function apiArgs(path, body, tokenOverride) {
    var token = tokenOverride === undefined ? bearerToken() : tokenOverride
    var args = ["curl", "-sS", "--max-time", "10", "-X", "POST",
      "-H", "Content-Type: application/json"]
    if (token !== "") args.push("-H", "Authorization: Bearer " + token)
    args.push("-d", body, baseUrl + path)
    args.push("-w", "\\n%{http_code}")
    return args
  }

  function relativeAge(timestamp) {
    if (!timestamp) return strings.t("age.never")
    var minutes = Math.max(0, Math.floor((nowMs - timestamp) / 60000))
    if (minutes < 1) return strings.t("age.justNow")
    if (minutes < 60) return strings.tn("age.minutes", minutes).arg(Commons.I18n.formatNumber(minutes))
    var hours = Math.floor(minutes / 60)
    if (hours < 48) return strings.tn("age.hours", hours).arg(Commons.I18n.formatNumber(hours))
    var days = Math.floor(hours / 24)
    return strings.tn("age.days", days).arg(Commons.I18n.formatNumber(days))
  }

  function relativeNext(timestamp) {
    if (!timestamp) return strings.t("next.unknown")
    var diff = timestamp - nowMs
    if (diff <= 60000) return strings.t("next.now")
    var minutes = Math.floor(diff / 60000)
    if (minutes < 60) return strings.tn("next.minutes", minutes).arg(Commons.I18n.formatNumber(minutes))
    var hours = Math.floor(minutes / 60)
    if (hours < 48) return strings.tn("next.hours", hours).arg(Commons.I18n.formatNumber(hours))
    var days = Math.floor(hours / 24)
    return strings.tn("next.days", days).arg(Commons.I18n.formatNumber(days))
  }

  function bytes(value) {
    var amount = Number(value)
    if (!isFinite(amount) || amount <= 0) return "0 B"
    var units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var index = 0
    while (amount >= 1024 && index < units.length - 1) {
      amount /= 1024
      index++
    }
    var decimals = index === 0 ? 0 : (amount < 10 ? 1 : 0)
    return Commons.I18n.formatNumber(amount, decimals) + " " + units[index]
  }

  function duration(value) {
    var seconds = Math.max(0, Math.round(Number(value) / 1000))
    if (seconds < 60) return seconds + "s"
    var minutes = Math.floor(seconds / 60)
    var rest = seconds % 60
    return rest > 0 ? minutes + "m " + rest + "s" : minutes + "m"
  }

  function dateTime(timestamp) {
    if (!timestamp) return "—"
    var date = new Date(timestamp)
    return date.toLocaleString(Qt.locale(Commons.I18n.formatLocale), "ddd d MMM · HH:mm")
  }

  function timeOnly(timestamp) {
    if (!timestamp) return ""
    var date = new Date(timestamp)
    return date.toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), "HH:mm")
  }

  function planById(id) {
    for (var i = 0; i < plans.length; i++) {
      if (plans[i].id === id) return plans[i]
    }
    return null
  }

  function planIsRunning(id) {
    for (var i = 0; i < running.length; i++) {
      if (running[i].type === "backup" && running[i].planId === id) return true
    }
    return false
  }

  function openWebUi() {
    if (baseUrl === "") return
    if (bar && typeof bar.run === "function") bar.run("xdg-open " + shellQuote(baseUrl))
    else Qt.openUrlExternally(baseUrl)
  }

  // --- refresh pipeline ----------------------------------------------------

  property bool _ready: false
  property bool _queued: false
  property bool _authTried: false
  property string _dashboardRaw: ""
  property string _operationsRaw: ""
  property string _configRaw: ""
  property string _backupRaw: ""
  property string _loginRaw: ""
  property double _configFetchedMs: 0
  property var _planRepos: ({})
  property string sessionToken: ""
  property string _backupPlan: ""

  readonly property int pollIntervalMs: (running.length > 0 || startingPlan !== "" || optimisticPlan !== "")
    ? 5000 : refreshIntervalSec * 1000

  onBaseUrlChanged: {
    sessionToken = ""
    _authTried = false
    if (_ready) Qt.callLater(function() { root.refresh(true) })
  }
  onConfiguredTokenChanged: {
    sessionToken = ""
    _authTried = false
    if (_ready) Qt.callLater(function() { root.refresh(true) })
  }
  onUsernameChanged: if (_ready) { sessionToken = ""; _authTried = false }
  onPasswordChanged: if (_ready) { sessionToken = ""; _authTried = false }

  function refresh(manual) {
    if (!_ready) return
    if (baseUrl === "") {
      online = false
      loading = false
      running = []
      errorKind = "url"
      errorCode = ""
      errorDetail = ""
      return
    }
    if (loading) {
      _queued = true
      return
    }
    if (manual) {
      _authTried = false
      actionError = ""
      actionMessage = ""
    }
    loading = true
    errorKind = ""
    errorCode = ""
    errorDetail = ""
    _dashboardRaw = ""
    dashboardProcess.command = apiArgs("/v1.Backrest/GetSummaryDashboard", "{}")
    dashboardProcess.running = true
  }

  function fetchOperations() {
    if (operationsProcess.running) {
      loading = false
      return
    }
    _operationsRaw = ""
    operationsProcess.command = apiArgs("/v1.Backrest/GetOperations",
      JSON.stringify({ selector: {}, lastN: "80" }))
    operationsProcess.running = true
  }

  function fetchConfig() {
    if (configProcess.running) return
    _configRaw = ""
    configProcess.command = apiArgs("/v1.Backrest/GetConfig", "{}")
    configProcess.running = true
  }

  function handleDashboard(exitCode, raw) {
    var response = splitResponse(raw)
    var success = exitCode === 0 && response.status >= 200 && response.status < 300
    if (!success) {
      if (isAuthFailure(response.status, response.body) && !_authTried && username !== "" && password !== "") {
        _authTried = true
        loading = false
        login()
        return
      }
      online = false
      loading = false
      running = []
      errorKind = response.status > 0 ? "http" : "network"
      errorCode = response.status > 0 ? String(response.status) : ""
      errorDetail = apiMessage(response.body)
      return
    }

    var parsed = parseJson(response.body)
    if (!parsed) {
      online = false
      loading = false
      running = []
      errorKind = "parse"
      errorCode = ""
      errorDetail = ""
      return
    }

    online = true
    lastUpdatedMs = Date.now()
    plans = Model.parsePlans(parsed, _planRepos)
    repos = Model.parseRepos(parsed)
    var builtHistory = Model.buildHistory(plans, 30)
    history = builtHistory.days
    historyMaxBytes = builtHistory.maxBytes
    recent = Model.mergeRecent(plans, 8)
    totalProtectedBytes = 0
    for (var r = 0; r < repos.length; r++) totalProtectedBytes += repos[r].protectedBytes
    if (totalProtectedBytes === 0) totalProtectedBytes = Model.sumPlans(plans, "protectedBytes")
    success30 = Model.sumPlans(plans, "success30")
    warning30 = Model.sumPlans(plans, "warning30")
    failed30 = Model.sumPlans(plans, "failed30")
    bytesAdded30 = Model.sumPlans(plans, "bytesAdded30")
    fetchOperations()
    if (Date.now() - _configFetchedMs > 30 * 60 * 1000) fetchConfig()
  }

  function handleOperations(exitCode, raw) {
    var response = splitResponse(raw)
    if (exitCode === 0 && response.status >= 200 && response.status < 300) {
      var parsed = parseJson(response.body)
      if (parsed) running = Model.runningOperations(parsed)
    }
    loading = false
    settleOptimistic()
    if (_queued) {
      _queued = false
      Qt.callLater(function() { root.refresh() })
    }
  }

  function settleOptimistic() {
    if (optimisticPlan === "") return
    var stillRunning = planIsRunning(optimisticPlan)
    var plan = planById(optimisticPlan)
    var landed = plan && plan.last && plan.last.timestamp >= optimisticStartMs
    if (stillRunning || landed || Date.now() > optimisticUntil) optimisticPlan = ""
  }

  function handleConfig(exitCode, raw) {
    var response = splitResponse(raw)
    if (exitCode !== 0 || response.status < 200 || response.status >= 300) return
    var parsed = parseJson(response.body)
    if (!parsed) return
    instance = String(parsed.instance || "")
    _planRepos = Model.planRepos(parsed)
    _configFetchedMs = Date.now()
    // Re-apply repo labels now that the plan -> repo mapping is known.
    plans = Model.parsePlans({ planSummaries: planSummariesFromPlans(plans) }, _planRepos)
  }

  // Re-build plan objects after the config arrives without another dashboard
  // request. `plans` already carries everything except the repo id.
  function planSummariesFromPlans(source) {
    var summaries = []
    for (var i = 0; i < source.length; i++) {
      var plan = source[i]
      summaries.push({
        id: plan.id,
        nextBackupTimeMs: plan.nextBackupMs,
        backupsSuccessLast30days: plan.success30,
        backupsWarningLast30days: plan.warning30,
        backupsFailedLast30days: plan.failed30,
        bytesAddedLast30days: plan.bytesAdded30,
        bytesScannedLast30days: plan.bytesScanned30,
        protectedBytes: plan.protectedBytes,
        recentBackups: recentBackupsFromPlan(plan),
        historyLast30days: historyFromPlan(plan)
      })
    }
    return summaries
  }

  function recentBackupsFromPlan(plan) {
    var rows = { flowId: [], timestampMs: [], durationMs: [], status: [], bytesAdded: [] }
    for (var i = 0; i < plan.recent.length; i++) {
      var row = plan.recent[i]
      rows.flowId.push(row.flowId)
      rows.timestampMs.push(String(row.timestamp))
      rows.durationMs.push(String(row.durationMs))
      rows.status.push("STATUS_" + String(row.status).toUpperCase())
      rows.bytesAdded.push(String(row.bytesAdded))
    }
    return rows
  }

  function historyFromPlan(plan) {
    var rows = []
    for (var i = 0; i < plan.history.length; i++) {
      var day = plan.history[i]
      var statusCounts = []
      if (day.counts.success > 0) statusCounts.push({ count: String(day.counts.success), status: "STATUS_SUCCESS" })
      if (day.counts.warning > 0) statusCounts.push({ count: String(day.counts.warning), status: "STATUS_WARNING" })
      if (day.counts.error > 0) statusCounts.push({ count: String(day.counts.error), status: "STATUS_ERROR" })
      rows.push({
        timestampMs: String(day.timestamp),
        bytesAdded: String(day.bytesAdded),
        bytesScanned: String(day.bytesScanned),
        statusCounts: statusCounts
      })
    }
    return rows
  }

  // --- actions -------------------------------------------------------------

  function login() {
    if (loginProcess.running) return
    loading = true
    errorKind = ""
    loginProcess.command = apiArgs("/v1.Authentication/Login",
      JSON.stringify({ username: username, password: password }), "")
    loginProcess.running = true
  }

  function handleLogin(exitCode, raw) {
    var response = splitResponse(raw)
    var parsed = parseJson(response.body)
    var token = parsed ? String(parsed.token || "") : ""
    loading = false
    if (exitCode === 0 && response.status >= 200 && response.status < 300 && token !== "") {
      sessionToken = token
      errorKind = ""
      refresh()
      return
    }
    online = false
    errorKind = "login"
    errorCode = response.status > 0 ? String(response.status) : ""
    errorDetail = apiMessage(response.body)
  }

  function startBackup(planId) {
    var id = String(planId || "")
    if (!online || startingPlan !== "" || backupProcess.running) return
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id)) return
    startingPlan = id
    actionError = ""
    actionMessage = ""
    _backupPlan = id
    _backupRaw = ""
    backupProcess.command = apiArgs("/v1.Backrest/Backup", JSON.stringify({ value: id }))
    backupProcess.running = true
  }

  function handleBackup(exitCode, raw) {
    var response = splitResponse(raw)
    var plan = _backupPlan
    startingPlan = ""
    _backupPlan = ""
    if (exitCode === 0 && response.status >= 200 && response.status < 300) {
      actionMessage = strings.t("action.started").arg(plan)
      actionTimer.restart()
      optimisticPlan = plan
      optimisticStartMs = Date.now()
      optimisticUntil = Date.now() + 60000
      backupKick.restart()
      return
    }
    actionError = apiMessage(response.body)
    if (actionError === "") actionError = response.status > 0 ? "HTTP " + response.status : strings.t("error.network").arg(baseUrl)
    actionTimer.restart()
  }

  // --- processes -----------------------------------------------------------

  Process {
    id: dashboardProcess
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._dashboardRaw = text
    }
    onExited: function(exitCode) { root.handleDashboard(exitCode, root._dashboardRaw) }
  }

  Process {
    id: operationsProcess
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._operationsRaw = text
    }
    onExited: function(exitCode) { root.handleOperations(exitCode, root._operationsRaw) }
  }

  Process {
    id: configProcess
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._configRaw = text
    }
    onExited: function(exitCode) { root.handleConfig(exitCode, root._configRaw) }
  }

  Process {
    id: backupProcess
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._backupRaw = text
    }
    onExited: function(exitCode) { root.handleBackup(exitCode, root._backupRaw) }
  }

  Process {
    id: loginProcess
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._loginRaw = text
    }
    onExited: function(exitCode) { root.handleLogin(exitCode, root._loginRaw) }
  }

  Timer {
    id: pollTimer
    interval: root.pollIntervalMs
    repeat: true
    running: root._ready
    onTriggered: root.refresh()
  }
  onPollIntervalMsChanged: pollTimer.restart()

  Timer {
    id: nowClock
    interval: 15000
    repeat: true
    running: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: backupKick
    interval: 1200
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: actionTimer
    interval: 6000
    repeat: false
    onTriggered: {
      root.actionError = ""
      root.actionMessage = ""
    }
  }

  Component.onCompleted: {
    _ready = true
    nowMs = Date.now()
    refresh()
  }
}
