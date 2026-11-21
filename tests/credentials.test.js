#!/usr/bin/env node
// Exercises the credential binding policy in Service.qml.
//
// The policy block between the marker comments is extracted verbatim and
// evaluated with the same globals QML provides, so these tests run against the
// code that ships instead of a copy. They exist so a change to the binding
// rules fails here first: every credential must have a proven origin before it
// can be sent, and no state file may ever contain the secret itself.
//
// Run with: node tests/credentials.test.js

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const SERVICE_PATH = path.join(__dirname, "..", "Service.qml");
const START = "  // --- credential binding policy";
const END = "  // --- end credential binding policy";

const source = fs.readFileSync(SERVICE_PATH, "utf8");
const startIndex = source.indexOf(START);
const endIndex = source.indexOf(END);
if (startIndex < 0 || endIndex < 0 || endIndex <= startIndex) {
  console.error("FAIL  could not find the credential binding policy block in Service.qml");
  process.exit(1);
}
const policy = source.slice(startIndex, endIndex);

const A = "https://a.example";
const B = "https://b.example";
const C = "https://c.example";

function md5(value) {
  return crypto.createHash("md5").update(String(value)).digest("hex");
}

function legacyFingerprint(token, username, password) {
  if (token === "" && username === "" && password === "") return "";
  return md5(JSON.stringify([token, username, password]));
}

function makeService({ token = "", username = "", password = "", url = A, state = "" }) {
  const ctx = {
    configuredToken: token,
    configuredUsername: username,
    configuredPassword: password,
    baseUrl: url,
    _tokenServer: "",
    _usernameServer: "",
    _passwordServer: "",
    _credentialFields: ({}),
    state: state,
    credentialsFile: {
      text: () => ctx.state,
      setText: (value) => { ctx.state = value; }
    },
    parseJson: (raw) => {
      try {
        const parsed = JSON.parse(String(raw || ""));
        return parsed && typeof parsed === "object" ? parsed : null;
      } catch (error) {
        return null;
      }
    },
    Qt: { md5 }
  };

  const factory = new Function("ctx", `
    with (ctx) {
      ${policy}
      return {
        credentialValue,
        credentialSnapshot,
        changedCredentials,
        loadCredentialBinding,
        saveCredentialBinding,
        applyCredentialSnapshot,
        boundServer,
        restoreCredentialServers,
        bindCredentialToCurrentServer
      };
    }
  `);

  const api = factory(ctx);
  const service = { ctx, api };

  // What the service would actually send.
  service.effective = () => ({
    token: ctx.configuredToken !== "" && ctx._tokenServer === ctx.baseUrl ? ctx.configuredToken : "",
    username: ctx.configuredUsername !== "" && ctx._usernameServer === ctx.baseUrl ? ctx.configuredUsername : "",
    password: ctx.configuredPassword !== "" && ctx._passwordServer === ctx.baseUrl ? ctx.configuredPassword : ""
  });

  // What handleSettingsChange does with a settings delivery, minus the QML
  // plumbing: diff against the last observed values, then apply the policy.
  service.deliver = (values) => {
    const observed = ctx._observed || { token: "", username: "", password: "" };
    const changed = api.changedCredentials(values, observed);
    const firstDelivery = !ctx._settingsSeen;
    ctx.configuredToken = values.token;
    ctx.configuredUsername = values.username;
    ctx.configuredPassword = values.password;
    ctx._observed = values;
    ctx._settingsSeen = true;
    api.applyCredentialSnapshot(changed, firstDelivery);
  };

  // Mirrors Component.onCompleted: settings may already be present, then the
  // host delivers them (possibly empty) right after startup.
  service.start = () => {
    api.loadCredentialBinding();
    ctx._observed = api.credentialSnapshot();
    ctx._settingsSeen = ctx.configuredToken !== "" || ctx.configuredUsername !== ""
      || ctx.configuredPassword !== "";
  };

  service.persisted = () => {
    if (ctx.state === "") return null;
    try { return JSON.parse(ctx.state); } catch (error) { return "invalid"; }
  };

  return service;
}

let failures = 0;
let checks = 0;

function check(label, condition, detail) {
  checks++;
  if (condition) {
    console.log("ok    " + label);
  } else {
    failures++;
    console.error("FAIL  " + label + (detail === undefined ? "" : "\n        " + detail));
  }
}

function same(label, actual, expected) {
  const got = JSON.stringify(actual);
  const want = JSON.stringify(expected);
  check(label, got === want, "got " + got + ", expected " + want);
}

function noSecrets(label, service, secrets) {
  const state = service.ctx.state;
  const leaked = secrets.filter((secret) => state.indexOf(secret) !== -1);
  check(label, leaked.length === 0, "state file contains " + JSON.stringify(leaked));
}

const usableOnA = { token: "T", username: "U", password: "P" };
const nothing = { token: "", username: "", password: "" };
const credentials = { token: "T", username: "U", password: "P" };

// 1. A missing state file must not make configured credentials usable.
let s = makeService({ ...credentials, url: A, state: "" });
s.start();
same("missing state file: nothing is sent", s.effective(), nothing);
check("missing state file: no binding is invented", s.ctx.state === "");

// 2. An unreadable state file fails closed the same way.
s = makeService({ ...credentials, url: A, state: "{ not json" });
s.start();
same("unreadable state file: nothing is sent", s.effective(), nothing);
check("unreadable state file: file is left alone", s.ctx.state === "{ not json");

// 3. A state file without any credential entry proves nothing.
s = makeService({ ...credentials, url: A, state: JSON.stringify({ version: 2, fields: {} }) });
s.start();
same("empty state entries: nothing is sent", s.effective(), nothing);

// 4. Settings delivered after startup with no state are a load, not an edit.
s = makeService({ url: A, state: "" });
s.start();
s.deliver({ ...credentials });
same("startup delivery with no state: nothing is sent", s.effective(), nothing);
check("startup delivery with no state: no binding written", s.ctx.state === "");

// 5. A matching v2 entry is trusted, and only on its stored origin.
const stateA = JSON.stringify({ version: 2, fields: {
  token: { server: A, fingerprint: md5("T") },
  username: { server: A, fingerprint: md5("U") },
  password: { server: A, fingerprint: md5("P") }
} });
s = makeService({ url: A, state: stateA });
s.start();
s.deliver({ ...credentials });
same("matching binding: usable on stored origin", s.effective(), usableOnA);

// 6. A URL change while stopped leaves the stored credentials unused.
s = makeService({ url: B, state: stateA });
s.start();
s.deliver({ ...credentials });
same("url changed while stopped: nothing is sent", s.effective(), nothing);

// 7. The legacy single binding migrates only when its fingerprint still matches.
const legacyMatching = JSON.stringify({ server: A, fingerprint: legacyFingerprint("T", "U", "P") });
s = makeService({ ...credentials, url: A, state: legacyMatching });
s.start();
same("legacy matching binding: usable on its origin", s.effective(), usableOnA);
same("legacy matching binding: migrated to v2",
  s.persisted() && s.persisted().version, 2);

// 8. A credential changed while stopped has no verified origin and must not be
//    assigned to the legacy server (the reviewer's second finding).
const legacyStale = JSON.stringify({ server: A, fingerprint: legacyFingerprint("T", "U", "P-old") });
s = makeService({ token: "T", username: "U", password: "P-new", url: A, state: legacyStale });
s.start();
same("legacy stale binding: nothing is sent", s.effective(), nothing);
check("legacy stale binding: no forged v2 entry",
  s.ctx.state === legacyStale, "state is " + s.ctx.state);

// 9. An edit while running binds exactly the changed field to the current URL.
s = makeService({ url: A, state: "" });
s.start();
s.deliver({ token: "", username: "", password: "" });
s.deliver({ token: "T", username: "", password: "" });
same("live token edit: bound to current url", s.effective(), { token: "T", username: "", password: "" });
s.ctx.baseUrl = B;
same("after url change: edited token is not sent", s.effective(), nothing);

// 10. Editing one field never releases another field's retained origin.
s = makeService({ url: A, state: "" });
s.start();
s.deliver({ token: "", username: "", password: "" });
s.deliver({ token: "T", username: "", password: "" });
s.ctx.baseUrl = B;
s.deliver({ token: "T", username: "", password: "P2" });
same("edit password on B: only password is sent", s.effective(), { token: "", username: "", password: "P2" });

// 11. Changing URL and credential together binds the new value to the new URL.
s = makeService({ url: A, state: "" });
s.start();
s.deliver({ token: "", username: "", password: "" });
s.ctx.baseUrl = B;
s.deliver({ token: "T2", username: "", password: "" });
same("url and credential changed together", s.effective(), { token: "T2", username: "", password: "" });

// 12. Clearing a field drops its stored binding.
s = makeService({ url: A, state: "" });
s.start();
s.deliver({ token: "", username: "", password: "" });
s.deliver({ token: "T", username: "", password: "" });
s.deliver({ token: "", username: "", password: "" });
same("cleared field: nothing is sent", s.effective(), nothing);
check("cleared field: entry removed",
  !s.persisted() || !s.persisted().fields || s.persisted().fields.token === undefined);

// 13. The explicit confirmation the panel offers binds every value to the
//     current server after a load failed closed.
s = makeService({ ...credentials, url: A, state: "" });
s.start();
for (const name of ["token", "username", "password"]) s.api.bindCredentialToCurrentServer(name);
s.api.saveCredentialBinding();
same("confirmed credentials: usable on current url", s.effective(), usableOnA);

// 14. The state file only ever holds origins and fingerprints.
s = makeService({ ...credentials, url: A, state: "" });
s.start();
s.deliver({ token: "", username: "", password: "" });
for (const name of ["token", "username", "password"]) s.api.bindCredentialToCurrentServer(name);
s.api.saveCredentialBinding();
noSecrets("state file never contains a secret", s, ["T", "U", "P"]);
const saved = s.persisted();
check("state file is v2", saved && saved.version === 2);
check("state entries hold only server and fingerprint",
  saved && Object.values(saved.fields).every((entry) =>
    Object.keys(entry).sort().join(",") === "fingerprint,server"));

// 15. A stale fingerprint for the current value is ignored.
s = makeService({ url: A, state: JSON.stringify({ version: 2, fields: {
  token: { server: A, fingerprint: md5("T-old") }
} }) });
s.start();
s.deliver({ token: "T", username: "", password: "" });
same("stale fingerprint: nothing is sent", s.effective(), nothing);

// 16. Contract checks: the edit signal is the whole settings object, and the
//     per-property handlers that reopened the origin hole are gone.
check("Service.qml uses the settings delivery signal",
  /onSettingsChanged:\s*handleSettingsChange\(\)/.test(source));
check("Service.qml has no per-property credential edit handlers",
  !/onConfigured(Token|Username|Password)Changed/.test(source));
check("Service.qml keeps a recovery action",
  /function confirmCredentials\(\)/.test(source));

// 17. A second run on the same server stays usable.
s = makeService({ ...credentials, url: A, state: stateA });
s.start();
s.deliver({ ...credentials });
const persistedA = s.ctx.state;
s = makeService({ token: "T", username: "U", password: "P", url: A, state: persistedA });
s.start();
s.deliver({ ...credentials });
same("restart on same server: still usable", s.effective(), usableOnA);

// 18. A different server C never receives the earlier server's values.
s = makeService({ url: C, state: persistedA });
s.start();
s.deliver({ ...credentials });
same("third server: nothing is sent", s.effective(), nothing);

console.log("\n" + (checks - failures) + "/" + checks + " checks passed");
if (failures > 0) process.exit(1);
