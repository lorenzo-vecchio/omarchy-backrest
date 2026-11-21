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

  // Credentials are only ever used against the server they were entered for.
  // Changing the URL leaves them bound to the old origin until one of them is
  // edited again, so the previous server's token is never offered to the new
  // one. The same binding covers session tokens and pending responses.
  readonly property string configuredToken: String(setting("authToken", "")).trim()
  readonly property string configuredUsername: String(setting("username", ""))
  readonly property string configuredPassword: String(setting("password", ""))
  readonly property bool hasConfiguredCredentials: configuredToken !== ""
    || (configuredUsername !== "" && configuredPassword !== "")
  readonly property bool credentialsMatchServer: _credentialsBaseUrl === baseUrl
  readonly property bool credentialsMismatch: hasConfiguredCredentials && !credentialsMatchServer
  readonly property string username: credentialsMatchServer ? configuredUsername : ""
  readonly property string password: credentialsMatchServer ? configuredPassword : ""
  readonly property string rawServerUrl: String(setting("serverUrl", "http://127.0.0.1:9898"))
  readonly property string baseUrl: normalizeUrl(rawServerUrl)
  readonly property bool insecureUrl: isInsecureUrl(rawServerUrl)
  readonly property string instance: baseUrl === "" ? "" : urlHost(baseUrl)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  readonly property var curlCommand: ["/bin/sh", "-c",
    "IFS= read -r line || exit 64; printf '%b' \"$line\" | exec curl -q --globoff -sS --config - -w '\\n%{http_code}'"]

  // --- observable status ---------------------------------------------------

  property bool online: false
  property bool loading: false
  property string errorKind: ""
  property string errorCode: ""
  property string errorDetail: ""
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
    if (baseUrl === "") return insecureUrl ? strings.t("error.insecure") : strings.t("error.url")
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
    if (baseUrl === "") return insecureUrl ? strings.t("error.insecure") : strings.t("error.url")
    if (errorKind === "http") {
      var suffix = errorDetail !== "" ? " " + errorDetail : ""
      return strings.t("error.http").arg(errorCode) + suffix
    }
    if (errorKind === "parse") return strings.t("error.parse")
    if (errorKind === "auth") return strings.t("error.auth")
    if (errorKind === "credentials") return strings.t("error.credentials").arg(baseUrl)
    if (errorKind === "login") return strings.t("error.login")
    if (errorKind === "toolarge") return strings.t("error.toolarge")
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

  function urlHost(value) {
    var match = /^https?:\/\/([^\/?#]+)/i.exec(String(value || ""))
    if (!match) return ""
    var authority = match[1]
    var at = authority.lastIndexOf("@")
    if (at !== -1) authority = authority.substring(at + 1)
    if (authority.charAt(0) === "[") {
      var end = authority.indexOf("]")
      return end === -1 ? "" : authority.substring(1, end).toLowerCase()
    }
    return authority.replace(/:\d+$/, "").toLowerCase().replace(/\.$/, "")
  }

  function isLoopbackHost(host) {
    if (host === "localhost" || host === "::1" || host === "0:0:0:0:0:0:0:1") return true
    return /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host)
  }

  function isInsecureUrl(value) {
    var url = String(value || "").trim().replace(/\/+$/, "")
    if (!/^http:\/\//i.test(url)) return false
    var host = urlHost(url)
    return host !== "" && !isLoopbackHost(host)
  }

  // http is only accepted for this machine. Anything remote must be https, so
  // a password or a configuration response never crosses a plain connection.
  function normalizeUrl(value) {
    var url = String(value || "").trim().replace(/\/+$/, "")
    if (!/^https?:\/\/[^\s"'<>]+$/i.test(url)) return ""
    var authority = /^https?:\/\/([^\/?#]*)/i.exec(url)
    if (!authority || authority[1].indexOf("@") !== -1) return ""
    var host = urlHost(url)
    if (host === "") return ""
    if (/^http:\/\//i.test(url) && !isLoopbackHost(host)) return ""
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
    if (configuredToken !== "" && credentialsMatchServer) return configuredToken
    if (sessionToken !== "" && sessionTokenServer === baseUrl) return sessionToken
    return ""
  }

  function curlQuote(value) {
    return '"' + String(value)
      .replace(/\\/g, "\\\\")
      .replace(/"/g, '\\"')
      .replace(/\r/g, "\\r")
      .replace(/\n/g, "\\n")
      .replace(/\t/g, "\\t") + '"'
  }

  // curl reads this whole request — URL, headers, credential and body — from
  // stdin, so no secret ever appears in the process table. The command itself
  // carries only the fixed script and a non-secret status format.
  function apiConfig(path, body, tokenOverride) {
    var token = tokenOverride === undefined ? bearerToken() : tokenOverride
    var lines = [
      "url = " + curlQuote(baseUrl + path),
      'request = "POST"',
      "header = " + curlQuote("Content-Type: application/json"),
      "header = " + curlQuote("Accept: application/json")
    ]
    if (token !== "") lines.push("header = " + curlQuote("Authorization: Bearer " + token))
    lines.push("data-binary = " + curlQuote(String(body || "{}")))
    lines.push("connect-timeout = 10")
    lines.push("max-time = 10")
    // curl aborts the transfer at the ceiling, so the collector never buffers
    // an unbounded response. 8 MiB is far above any dashboard this widget uses.
    lines.push("max-filesize = 8388608")
    lines.push("max-redirs = 0")
    lines.push('proto = "=http,https"')
    lines.push('proto-redir = "=http,https"')
    return lines.join("\n") + "\n"
  }

  // Quickshell never closes a process's stdin, so the shell reads one line and
  // decodes it itself. Backslashes are doubled and real newlines become \n;
  // printf '%b' restores the config without waiting for EOF.
  function encodeConfig(config) {
    return String(config)
      .replace(/\\/g, "\\\\")
      .replace(/\r/g, "\\r")
      .replace(/\n/g, "\\n")
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
  property string _credentialsBaseUrl: ""
  property int _credentialEpoch: 0
  property int _generation: 0
  property var _planRepos: ({})
  property string sessionToken: ""
  property string sessionTokenServer: ""
  property string _backupPlan: ""
  property string _loginServer: ""
  property int _loginEpoch: -1

  readonly property int pollIntervalMs: (running.length > 0 || startingPlan !== "" || optimisticPlan !== "")
    ? 5000 : refreshIntervalSec * 1000

  onBaseUrlChanged: {
    if (_credentialsBaseUrl === "") _credentialsBaseUrl = baseUrl
    resetForServerChange()
    if (_ready) Qt.callLater(function() { root.refresh(true) })
  }
  onConfiguredTokenChanged: bindCredentials()
  onConfiguredUsernameChanged: bindCredentials()
  onConfiguredPasswordChanged: bindCredentials()

  function bindCredentials() {
    _credentialsBaseUrl = baseUrl
    _credentialEpoch++
    sessionToken = ""
    sessionTokenServer = ""
    _authTried = false
    stopRequests(false)
    if (_ready) Qt.callLater(function() { root.refresh(true) })
  }

  function stopRequests(includeBackup) {
    _generation++
    _queued = false
    loading = false
    if (dashboardProcess && dashboardProcess.running) dashboardProcess.running = false
    if (operationsProcess && operationsProcess.running) operationsProcess.running = false
    if (loginProcess && loginProcess.running) loginProcess.running = false
    if (includeBackup && backupProcess && backupProcess.running) backupProcess.running = false
  }

  function resetForServerChange() {
    stopRequests(true)
    sessionToken = ""
    sessionTokenServer = ""
    _authTried = false
    _planRepos = ({})
    online = false
    plans = []
    repos = []
    recent = []
    history = []
    historyMaxBytes = 0
    running = []
    startingPlan = ""
    optimisticPlan = ""
    _backupPlan = ""
  }

  function startRequest(process, path, body, tokenOverride) {
    process.request = apiConfig(path, body, tokenOverride)
    process.requestServer = baseUrl
    process.requestGeneration = _generation
    process.running = true
  }

  function finishLoading() {
    loading = false
    if (_queued) {
      _queued = false
      Qt.callLater(function() { root.refresh() })
    }
  }

  function refresh(manual) {
    if (!_ready) return
    if (baseUrl === "") {
      online = false
      loading = false
      _queued = false
      running = []
      errorKind = insecureUrl ? "insecure" : "url"
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
    _queued = false
    _generation++
    errorKind = ""
    errorCode = ""
    errorDetail = ""
    startRequest(dashboardProcess, "/v1.Backrest/GetSummaryDashboard", "{}")
  }

  function fetchOperations() {
    if (operationsProcess.running) {
      finishLoading()
      return
    }
    startRequest(operationsProcess, "/v1.Backrest/GetOperations",
      JSON.stringify({ selector: {}, lastN: "80" }))
  }

  function handleDashboard(exitCode, raw, requestServer, requestGeneration) {
    if (requestServer !== baseUrl || requestGeneration !== _generation) return
    var response = splitResponse(raw)
    if (exitCode === 63) {
      online = false
      running = []
      errorKind = "toolarge"
      errorCode = ""
      errorDetail = ""
      finishLoading()
      return
    }
    var success = exitCode === 0 && response.status >= 200 && response.status < 300
    if (!success) {
      if (isAuthFailure(response.status, response.body)) {
        if (credentialsMismatch) {
          online = false
          running = []
          errorKind = "credentials"
          errorCode = response.status > 0 ? String(response.status) : ""
          errorDetail = ""
          finishLoading()
          return
        }
        // A configured bearer token is authoritative. It never falls back to
        // the saved password; only a login request that started without a
        // token may sign in with username/password.
        if (!_authTried && configuredToken === "" && username !== "" && password !== "") {
          _authTried = true
          loading = false
          login()
          return
        }
      }
      online = false
      running = []
      errorKind = response.status > 0 ? "http" : "network"
      errorCode = response.status > 0 ? String(response.status) : ""
      errorDetail = apiMessage(response.body)
      finishLoading()
      return
    }

    var parsed = parseJson(response.body)
    if (!parsed) {
      online = false
      running = []
      errorKind = "parse"
      errorCode = ""
      errorDetail = ""
      finishLoading()
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
  }

  function handleOperations(exitCode, raw, requestServer, requestGeneration) {
    if (requestServer !== baseUrl || requestGeneration !== _generation) return
    var response = splitResponse(raw)
    if (exitCode === 0 && response.status >= 200 && response.status < 300) {
      var parsed = parseJson(response.body)
      if (parsed) {
        running = Model.runningOperations(parsed)
        var mapping = Model.operationPlanRepos(parsed)
        if (planRepoMapChanged(mapping)) {
          _planRepos = mapping
          applyPlanRepos()
        }
      }
    }
    finishLoading()
    settleOptimistic()
  }

  // The operation feed already carries plan_id and repo_id, so the widget
  // never needs to fetch GetConfig (which can contain repository passwords and
  // storage environment values) just to label a plan.
  function planRepoMapChanged(next) {
    for (var key in next) {
      if (_planRepos[key] !== next[key]) return true
    }
    for (var oldKey in _planRepos) {
      if (next[oldKey] === undefined) return true
    }
    return false
  }

  function applyPlanRepos() {
    var updated = []
    for (var i = 0; i < plans.length; i++) {
      var plan = plans[i]
      var repo = _planRepos[plan.id]
      updated.push({
        id: plan.id,
        repo: repo !== undefined && repo !== "" ? repo : plan.repo,
        nextBackupMs: plan.nextBackupMs,
        success30: plan.success30,
        warning30: plan.warning30,
        failed30: plan.failed30,
        bytesAdded30: plan.bytesAdded30,
        bytesScanned30: plan.bytesScanned30,
        protectedBytes: plan.protectedBytes,
        recent: plan.recent,
        last: plan.last,
        history: plan.history
      })
    }
    plans = updated
  }

  function settleOptimistic() {
    if (optimisticPlan === "") return
    var stillRunning = planIsRunning(optimisticPlan)
    var plan = planById(optimisticPlan)
    var landed = plan && plan.last && plan.last.timestamp >= optimisticStartMs
    if (stillRunning || landed || Date.now() > optimisticUntil) optimisticPlan = ""
  }

  // --- actions -------------------------------------------------------------

  function login() {
    if (loginProcess.running) return
    if (!credentialsMatchServer || username === "" || password === "") {
      loading = false
      errorKind = "auth"
      return
    }
    loading = true
    errorKind = ""
    _loginServer = baseUrl
    _loginEpoch = _credentialEpoch
    loginProcess.request = apiConfig("/v1.Authentication/Login",
      JSON.stringify({ username: username, password: password }), "")
    loginProcess.requestServer = baseUrl
    loginProcess.requestGeneration = _generation
    loginProcess.running = true
  }

  function handleLogin(exitCode, raw, requestServer, requestGeneration, requestEpoch) {
    if (requestServer !== baseUrl || requestGeneration !== _generation) return
    if (requestEpoch !== _credentialEpoch) return
    var response = splitResponse(raw)
    var parsed = parseJson(response.body)
    var token = parsed ? String(parsed.token || "") : ""
    if (exitCode === 0 && response.status >= 200 && response.status < 300 && token !== "") {
      sessionToken = token
      sessionTokenServer = baseUrl
      errorKind = ""
      loading = false
      refresh()
      return
    }
    online = false
    errorKind = credentialsMismatch ? "credentials" : "login"
    errorCode = response.status > 0 ? String(response.status) : ""
    errorDetail = apiMessage(response.body)
    finishLoading()
  }

  function startBackup(planId) {
    var id = String(planId || "")
    if (!online || startingPlan !== "" || backupProcess.running) return
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id)) return
    startingPlan = id
    actionError = ""
    actionMessage = ""
    _backupPlan = id
    startRequest(backupProcess, "/v1.Backrest/Backup", JSON.stringify({ value: id }))
  }

  function handleBackup(exitCode, raw, requestServer) {
    if (requestServer !== baseUrl) return
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
    command: root.curlCommand
    stdinEnabled: true
    property string request: ""
    property string requestServer: ""
    property int requestGeneration: 0
    property string response: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: dashboardProcess.response = text
    }
    onStarted: if (request !== "") { write(root.encodeConfig(request)); request = "" }
    onExited: function(exitCode) {
      var raw = response
      response = ""
      root.handleDashboard(exitCode, raw, requestServer, requestGeneration)
    }
  }

  Process {
    id: operationsProcess
    command: root.curlCommand
    stdinEnabled: true
    property string request: ""
    property string requestServer: ""
    property int requestGeneration: 0
    property string response: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: operationsProcess.response = text
    }
    onStarted: if (request !== "") { write(root.encodeConfig(request)); request = "" }
    onExited: function(exitCode) {
      var raw = response
      response = ""
      root.handleOperations(exitCode, raw, requestServer, requestGeneration)
    }
  }

  Process {
    id: backupProcess
    command: root.curlCommand
    stdinEnabled: true
    property string request: ""
    property string requestServer: ""
    property string response: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: backupProcess.response = text
    }
    onStarted: if (request !== "") { write(root.encodeConfig(request)); request = "" }
    onExited: function(exitCode) {
      var raw = response
      response = ""
      root.handleBackup(exitCode, raw, requestServer)
    }
  }

  Process {
    id: loginProcess
    command: root.curlCommand
    stdinEnabled: true
    property string request: ""
    property string requestServer: ""
    property int requestGeneration: 0
    property int requestEpoch: -1
    property string response: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: loginProcess.response = text
    }
    onStarted: if (request !== "") { write(root.encodeConfig(request)); request = "" }
    onExited: function(exitCode) {
      var raw = response
      response = ""
      root.handleLogin(exitCode, raw, requestServer, requestGeneration, requestEpoch)
    }
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
    if (_credentialsBaseUrl === "") _credentialsBaseUrl = baseUrl
    _ready = true
    nowMs = Date.now()
    refresh()
  }
}
