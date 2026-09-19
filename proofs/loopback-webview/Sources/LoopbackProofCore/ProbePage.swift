let probePageHTML = #"""
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Loopback proof</title>
<style>
 body { background:#1c1a18; color:#f0e6d6; font:13.5px/1.5 -apple-system, sans-serif; margin:16px; }
 td { padding:2px 10px 2px 0; font-size:12.5px; vertical-align:top; }
 .pass { color:#78b464; } .fail { color:#ff6e64; } .note { color:#b0a090; }
 h1 { font-size:14px; font-weight:600; margin:0 0 8px; }
</style>
</head>
<body>
<h1>Loopback proof</h1>
<table id="table"></table>
<script>
const rows = [];
const secret = (window.__shellDescriptor && window.__shellDescriptor.secret) || "";
function check(name, passed, detail) { rows.push({kind:"check", name, passed: !!passed, detail: String(detail)}); }
function observe(name, detail) { rows.push({kind:"observation", name, passed: null, detail: String(detail)}); }

async function status(path, withSecret) {
  const headers = withSecret ? {"x-loopback-secret": secret} : {};
  try { const r = await fetch(path, {headers}); return r.status; } catch (e) { return "network-error: " + e; }
}

function xhrStatus(path, withSecret) {
  return new Promise(resolve => {
    const x = new XMLHttpRequest();
    x.open("GET", path, true);
    if (withSecret) x.setRequestHeader("x-loopback-secret", secret);
    x.onload = () => resolve(x.status);
    x.onerror = () => resolve("network-error");
    x.send();
  });
}

function loadScript(src) {
  return new Promise(resolve => {
    const s = document.createElement("script");
    s.src = src;
    s.onload = () => resolve("loaded");
    s.onerror = () => resolve("refused");
    document.head.appendChild(s);
  });
}

function openSocket(path, expectText) {
  return new Promise(resolve => {
    let settled = false;
    const finish = v => { if (!settled) { settled = true; resolve(v); } };
    let ws;
    try { ws = new WebSocket(location.origin.replace(/^http/, "ws") + path); }
    catch (e) { return finish("threw: " + e); }
    ws.onmessage = ev => { finish(ev.data === expectText ? "message:" + ev.data : "unexpected:" + ev.data); ws.close(); };
    ws.onerror = () => finish("error");
    ws.onclose = () => finish("closed-without-message");
    setTimeout(() => finish("timeout"), 5000);
  });
}

async function run() {
  check("secure_context", window.isSecureContext === true, "window.isSecureContext = " + window.isSecureContext);

  let digestDetail = "absent";
  let digestOk = false;
  if (window.crypto && crypto.subtle && typeof crypto.subtle.digest === "function") {
    try {
      const out = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array([1,2,3])));
      digestOk = out.length === 32;
      digestDetail = "SHA-256 returned " + out.length + " bytes";
    } catch (e) { digestDetail = "threw: " + e; }
  }
  check("crypto_subtle_works", digestOk, digestDetail);

  const clip = navigator.clipboard && typeof navigator.clipboard.writeText === "function";
  check("clipboard_interface_present", clip, "navigator.clipboard.writeText is " + (clip ? "a function" : "absent"));

  observe("notification_interface", typeof Notification === "undefined"
    ? "window.Notification is undefined in this web view"
    : "window.Notification exists, permission = " + Notification.permission);

  const withSecret = await status("/probe/guarded", true);
  check("data_request_with_secret_accepted", withSecret === 200, "GET /probe/guarded with the header: " + withSecret);

  const withoutSecret = await status("/probe/guarded", false);
  check("data_request_without_secret_refused", withoutSecret === 401, "GET /probe/guarded without the header: " + withoutSecret);

  const xhr = await xhrStatus("/probe/guarded", true);
  check("xhr_with_secret_accepted", xhr === 200, "XMLHttpRequest with the header: " + xhr);

  const sub = await loadScript("/probe/guarded.js");
  // The refusal alone would also be true of a server that has no such path at
  // all, and the Global Constraints forbid a check that passes when the thing it
  // tests is absent. So the same path must answer 200 when the header is on it.
  // The order matters: the sub-resource is asked for first, on a cold cache.
  const guardedJs = await status("/probe/guarded.js", true);
  check("subresource_without_secret_refused",
        sub === "refused" && window.__guardedScriptLoaded === undefined && guardedJs === 200,
        "<script src=/probe/guarded.js> " + sub + "; GET /probe/guarded.js with the header: " + guardedJs);

  let ticket = "";
  let ticketStatus = "not requested";
  try {
    const r = await fetch("/api/v1/threads/ticket", {method:"POST", headers:{"x-loopback-secret": secret}});
    ticketStatus = r.status;
    if (r.status === 200) ticket = (await r.json()).ticket;
  } catch (e) { ticketStatus = "network-error: " + e; }
  check("ticket_minted_with_secret", ticketStatus === 200 && ticket.length > 0, "POST /api/v1/threads/ticket: " + ticketStatus);

  const first = await openSocket("/api/v1/threads/socket?ticket=" + ticket, "hello");
  check("socket_opens_with_ticket", first === "message:hello", "first socket: " + first);

  const second = await openSocket("/api/v1/threads/socket?ticket=" + ticket, "hello");
  check("ticket_is_single_use", second !== "message:hello", "second socket with the same ticket: " + second);

  const none = await openSocket("/api/v1/threads/socket", "hello");
  check("socket_without_ticket_refused", none !== "message:hello", "socket with no ticket: " + none);

  check("no_cookie_is_set", document.cookie === "", "document.cookie = '" + document.cookie + "'");

  const previewPort = (window.__shellDescriptor && window.__shellDescriptor.previewPort) || 0;
  const framed = await new Promise(resolve => {
    const onMessage = event => {
      if (event.data === "preview-ok") { window.removeEventListener("message", onMessage); resolve("the framed page ran and answered"); }
    };
    window.addEventListener("message", onMessage);
    const frame = document.createElement("iframe");
    frame.src = "http://localhost:" + previewPort + "/";
    frame.width = 320; frame.height = 48;
    document.body.appendChild(frame);
    setTimeout(() => resolve("timeout"), 5000);
  });
  check("iframe_to_another_localhost_port_loads", framed !== "timeout",
        "iframe of http://localhost:" + previewPort + "/: " + framed);

  // Built with textContent, never innerHTML: a detail such as
  // "<script src=/probe/guarded.js> refused" is text, and pasting it into the
  // document as markup silently swallows every row after it.
  const table = document.getElementById("table");
  for (const row of rows) {
    const line = document.createElement("tr");
    const mark = document.createElement("td");
    mark.className = row.kind === "observation" ? "note" : (row.passed ? "pass" : "fail");
    mark.textContent = row.kind === "observation" ? "note" : (row.passed ? "pass" : "FAIL");
    const name = document.createElement("td");
    name.textContent = row.name;
    const detail = document.createElement("td");
    detail.className = "note";
    detail.textContent = row.detail;
    line.append(mark, name, detail);
    table.appendChild(line);
  }

  await fetch("/probe/report", {
    method: "POST",
    headers: {"x-loopback-secret": secret, "content-type": "application/json"},
    body: JSON.stringify(rows)
  });
}

run().catch(e => {
  rows.push({kind:"check", name:"page_script_completed", passed:false, detail:"threw: " + e});
  fetch("/probe/report", {
    method: "POST",
    headers: {"x-loopback-secret": secret, "content-type": "application/json"},
    body: JSON.stringify(rows)
  });
});
</script>
</body>
</html>
"""#
