import Foundation

/// The one static, mobile-first page served at GET / (and /remote) for V1.5's iPhone remote.
/// Plain HTML + vanilla JS, no build step, no third-party code -- kept as a literal like
/// LocalAPIOpenAPISpec so it ships inside the app with nothing to bundle or fetch.
///
/// It is ONLY a client of the public API: everything it shows comes from the same
/// token-gated endpoints a future SwiftUI iPhone app would call (/shoots, /shoots/{id}/photos,
/// /previews/{id}, /results/{id}, /critique, /jobs, /export, /downloads, /remote/config).
/// The token lives in the phone's localStorage; it arrives either pasted, or through the
/// setup QR in Settings as a `#token=` fragment, which browsers never send to the server.
enum LocalAPIWebUI {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="PhotoCritic">
<meta name="theme-color" content="#111214">
<title>PhotoCritic Remote</title>
<style>
:root {
  --bg: #f4f4f2; --surface: #ffffff; --surface-2: #ececea; --text: #18191b; --muted: #6a6c70;
  --line: #dcdcd8; --accent: #2f6fde; --keep: #1f8a4c; --maybe: #b07a10; --reject: #c0392b;
  --radius: 12px;
}
@media (prefers-color-scheme: dark) {
  :root { --bg: #111214; --surface: #1b1c1f; --surface-2: #26272b; --text: #ececec; --muted: #9a9ca1;
          --line: #2e3034; --accent: #5b93f0; --keep: #3fbf74; --maybe: #e0a834; --reject: #e5675a; }
}
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
html, body { margin: 0; background: var(--bg); color: var(--text);
  font: 16px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
body { padding-bottom: calc(64px + env(safe-area-inset-bottom)); }
header { position: sticky; top: 0; z-index: 5; background: color-mix(in srgb, var(--bg) 88%, transparent);
  backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px);
  padding: calc(10px + env(safe-area-inset-top)) 16px 10px; display: flex; align-items: center; gap: 10px;
  border-bottom: 1px solid var(--line); }
header h1 { font-size: 17px; margin: 0; flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
main { padding: 12px 16px; max-width: 1100px; margin: 0 auto; }
button, select, input { font: inherit; color: inherit; }
.btn { border: 0; border-radius: 10px; padding: 9px 14px; background: var(--surface-2); cursor: pointer; white-space: nowrap; }
.btn.primary { background: var(--accent); color: #fff; }
.btn.small { padding: 6px 10px; font-size: 14px; }
.btn:disabled { opacity: .45; }
.back { background: none; border: 0; color: var(--accent); padding: 4px 0; font-size: 16px; cursor: pointer; }
.muted { color: var(--muted); }
.small { font-size: 13px; }
.card { background: var(--surface); border-radius: var(--radius); padding: 14px; margin-bottom: 10px; border: 1px solid var(--line); }
.list .card { display: block; width: 100%; text-align: left; cursor: pointer; }
.row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.spacer { flex: 1; }
.pill { font-size: 12px; font-weight: 600; padding: 2px 8px; border-radius: 99px; background: var(--surface-2); }
.pill.KEEP { color: var(--keep); } .pill.MAYBE { color: var(--maybe); } .pill.REJECT { color: var(--reject); }
.chips { display: flex; gap: 6px; overflow-x: auto; padding-bottom: 8px; margin-bottom: 4px; }
.chip { border: 1px solid var(--line); background: var(--surface); border-radius: 99px; padding: 5px 12px; font-size: 14px; white-space: nowrap; cursor: pointer; }
.chip.on { background: var(--text); color: var(--bg); border-color: var(--text); }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(108px, 1fr)); gap: 4px; }
.tile { position: relative; aspect-ratio: 1; background: var(--surface-2); border-radius: 6px; overflow: hidden; border: 0; padding: 0; cursor: pointer; }
.tile img { width: 100%; height: 100%; object-fit: cover; display: block; }
.tile .score { position: absolute; left: 4px; bottom: 4px; font-size: 11px; font-weight: 700; padding: 1px 6px; border-radius: 6px; background: rgba(0,0,0,.6); color: #fff; }
.tile .dot { position: absolute; right: 5px; top: 5px; width: 9px; height: 9px; border-radius: 50%; }
.dot.KEEP { background: var(--keep); } .dot.MAYBE { background: var(--maybe); } .dot.REJECT { background: var(--reject); }
.tile.sel { outline: 3px solid var(--accent); outline-offset: -3px; }
.tile .check { position: absolute; right: 5px; bottom: 5px; width: 22px; height: 22px; border-radius: 50%; background: var(--accent); color: #fff; font-size: 14px; display: none; align-items: center; justify-content: center; }
.tile.sel .check { display: flex; }
.hero { width: 100%; border-radius: var(--radius); background: var(--surface-2); display: block; min-height: 200px; object-fit: contain; max-height: 75vh; }
.bar { height: 6px; background: var(--surface-2); border-radius: 99px; overflow: hidden; margin-top: 8px; }
.bar > div { height: 100%; background: var(--accent); transition: width .4s; }
.status-running { color: var(--accent); } .status-done { color: var(--keep); } .status-failed { color: var(--reject); } .status-queued { color: var(--muted); }
pre { white-space: pre-wrap; word-break: break-word; font-size: 12px; background: var(--surface-2); padding: 8px; border-radius: 8px; max-height: 240px; overflow: auto; }
ul.tight { margin: 4px 0 0; padding-left: 18px; }
nav.tabs { position: fixed; left: 0; right: 0; bottom: 0; z-index: 6; display: flex; background: var(--surface); border-top: 1px solid var(--line); padding-bottom: env(safe-area-inset-bottom); }
nav.tabs button { flex: 1; background: none; border: 0; padding: 10px 0 12px; font-size: 13px; color: var(--muted); cursor: pointer; }
nav.tabs button.on { color: var(--accent); font-weight: 600; }
.actionbar { position: fixed; left: 0; right: 0; bottom: calc(56px + env(safe-area-inset-bottom)); z-index: 7; padding: 10px 16px; background: var(--surface); border-top: 1px solid var(--line); display: flex; gap: 8px; align-items: center; }
.sheet-bg { position: fixed; inset: 0; z-index: 20; background: rgba(0,0,0,.45); display: flex; align-items: flex-end; justify-content: center; }
.sheet { background: var(--surface); width: 100%; max-width: 560px; border-radius: 16px 16px 0 0; padding: 18px 16px calc(18px + env(safe-area-inset-bottom)); max-height: 85vh; overflow: auto; }
.sheet h2 { margin: 0 0 8px; font-size: 18px; }
.field { display: block; margin: 12px 0; }
.field select, .field input { width: 100%; padding: 10px; border-radius: 10px; border: 1px solid var(--line); background: var(--bg); }
.toast { position: fixed; left: 16px; right: 16px; bottom: calc(76px + env(safe-area-inset-bottom)); z-index: 30; background: var(--text); color: var(--bg); padding: 12px 14px; border-radius: 12px; text-align: center; }
.err { color: var(--reject); }
.empty { text-align: center; padding: 40px 0; }
.dl img { width: 64px; height: 64px; object-fit: cover; border-radius: 6px; background: var(--surface-2); }
</style>
</head>
<body>
<header><button class="back" id="back" hidden>‹ Back</button><h1 id="title">PhotoCritic</h1><span id="hdr-actions" class="row"></span></header>
<main id="main"></main>
<div id="actionbar"></div>
<nav class="tabs" id="tabs">
  <button data-tab="shoots">Shoots</button>
  <button data-tab="jobs">Jobs</button>
  <button data-tab="settings">Connection</button>
</nav>
<script>
"use strict";
const TOKEN_KEY = "photocritic.token";
const $ = (sel, el = document) => el.querySelector(sel);
const h = (tag, attrs = {}, ...kids) => {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "class") el.className = v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid.nodeType ? kid : String(kid));
  return el;
};
function store(key, value) { try { value == null ? localStorage.removeItem(key) : localStorage.setItem(key, value); } catch (_) {} }
function load(key) { try { return localStorage.getItem(key); } catch (_) { return null; } }

// ---- token: from the setup QR's #token= fragment (never sent to the server), else storage
let token = load(TOKEN_KEY);
(function takeTokenFromFragment() {
  const m = location.hash.match(/token=([0-9a-fA-F]{16,})/);
  if (m) { token = m[1]; store(TOKEN_KEY, token); history.replaceState(null, "", location.pathname + "#/shoots"); }
})();

class AuthError extends Error {}
async function api(path, opts = {}) {
  const headers = Object.assign({ Authorization: "Bearer " + token }, opts.body ? { "Content-Type": "application/json" } : {});
  const res = await fetch(path, { method: opts.method || "GET", headers, body: opts.body ? JSON.stringify(opts.body) : undefined, cache: "no-store" });
  if (res.status === 401) throw new AuthError("Token rejected");
  if (opts.raw) { if (!res.ok) throw new Error("HTTP " + res.status); return res; }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error((data.error && data.error.message) || ("HTTP " + res.status));
  return data;
}

// ---- authorized images: <img src> can't send a bearer header, so fetch -> blob: URL.
const blobCache = new Map(); // key -> objectURL (insertion-ordered, trimmed LRU-ish)
let inflight = 0; const waiting = [];
function pump() {
  while (inflight < 6 && waiting.length) {
    const job = waiting.shift();
    if (job.img.isConnected === false && job.lazy) continue;
    inflight++;
    api(job.url, { raw: true }).then(r => r.blob()).then(b => {
      const u = URL.createObjectURL(b); blobCache.set(job.url, u); job.img.src = u;
      if (blobCache.size > 500) { const [k, old] = blobCache.entries().next().value; URL.revokeObjectURL(old); blobCache.delete(k); }
    }).catch(() => { job.img.alt = "preview unavailable"; }).finally(() => { inflight--; pump(); });
  }
}
function setImg(img, url, lazy) {
  const hit = blobCache.get(url);
  if (hit) { img.src = hit; return; }
  waiting.push({ img, url, lazy }); pump();
}
const io = "IntersectionObserver" in window ? new IntersectionObserver(entries => {
  for (const e of entries) if (e.isIntersecting) { io.unobserve(e.target); setImg(e.target, e.target.dataset.src, true); }
}, { rootMargin: "400px" }) : null;
function lazyImg(url, alt) {
  const img = h("img", { alt: alt || "", "data-src": url, decoding: "async" });
  if (io) io.observe(img); else setImg(img, url);
  return img;
}

// ---- UI helpers
function toast(msg, ms = 2600) { const t = h("div", { class: "toast", role: "status" }, msg); document.body.append(t); setTimeout(() => t.remove(), ms); }
function sheet(build) {
  const bg = h("div", { class: "sheet-bg" }); const s = h("div", { class: "sheet", role: "dialog" });
  const close = () => bg.remove();
  bg.addEventListener("click", e => { if (e.target === bg) close(); });
  build(s, close); bg.append(s); document.body.append(bg); return close;
}
function confirmSheet(title, body, okLabel, onOk) {
  sheet((s, close) => s.append(h("h2", {}, title), h("p", { class: "muted" }, body),
    h("div", { class: "row" }, h("button", { class: "btn", onclick: close }, "Cancel"), h("span", { class: "spacer" }),
      h("button", { class: "btn primary", onclick: () => { close(); onOk(); } }, okLabel))));
}
function setHeader(title, { back, actions = [] } = {}) {
  $("#title").textContent = title;
  const b = $("#back"); b.hidden = !back; b.onclick = back || null;
  $("#hdr-actions").replaceChildren(...actions);
}
function setTab(tab) { for (const b of document.querySelectorAll("nav.tabs button")) b.classList.toggle("on", b.dataset.tab === tab); }
function fmtScore(v) { return v == null ? "–" : Number(v).toFixed(1); }
function showError(e) {
  if (e instanceof AuthError) { location.hash = "#/settings"; toast("Token rejected — set it again"); return; }
  $("#main").replaceChildren(h("div", { class: "card err" }, String(e.message || e)));
}
let pollTimer = null;
function stopPolling() { if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; } }
let configCache = null;
async function config() { return configCache || (configCache = await api("/remote/config")); }

// ---- views
const state = { shoots: null, selected: new Set(), selecting: false, filter: "", sort: "score" };

async function viewShoots() {
  setTab("shoots"); setHeader("Shoots", { actions: [h("button", { class: "btn small", onclick: () => { state.shoots = null; route(); } }, "Refresh")] });
  const main = $("#main");
  if (!state.shoots) { main.replaceChildren(h("p", { class: "muted" }, "Loading…")); state.shoots = await api("/shoots"); }
  if (!state.shoots.length) { main.replaceChildren(h("p", { class: "muted empty" }, "No shoots yet.")); return; }
  const filterInput = h("input", { type: "search", placeholder: "Filter shoots", style: "width:100%;padding:10px;border-radius:10px;border:1px solid var(--line);background:var(--surface);margin-bottom:10px" });
  const list = h("div", { class: "list" });
  const render = () => {
    const q = filterInput.value.trim().toLowerCase();
    list.replaceChildren(...state.shoots.filter(s => !q || (s.name + " " + s.parent).toLowerCase().includes(q)).map(s =>
      h("button", { class: "card", onclick: () => { location.hash = "#/shoot/" + s.id; } },
        h("div", { class: "row" }, h("strong", {}, s.name), h("span", { class: "spacer" }), h("span", { class: "muted small" }, s.total_files + " photos")),
        h("div", { class: "muted small" }, s.parent),
        h("div", { class: "row", style: "margin-top:6px" },
          s.evaluated ? [h("span", { class: "pill KEEP" }, s.keep + " keep"), h("span", { class: "pill MAYBE" }, s.maybe + " maybe"), h("span", { class: "pill REJECT" }, s.reject + " reject")]
                      : h("span", { class: "pill" }, "not critiqued")))));
  };
  filterInput.addEventListener("input", render); render();
  main.replaceChildren(filterInput, list);
}

async function viewShoot(id) {
  setTab("shoots");
  if (!state.shoots) state.shoots = await api("/shoots");
  const shoot = state.shoots.find(s => s.id === id);
  if (!shoot) throw new Error("Shoot " + id + " not found");
  if (state.shootId !== id) { state.shootId = id; state.selected.clear(); state.selecting = false; }
  const selectBtn = h("button", { class: "btn small" }, state.selecting ? "Done" : "Select");
  selectBtn.onclick = () => { state.selecting = !state.selecting; if (!state.selecting) state.selected.clear(); route(); };
  setHeader(shoot.name, { back: () => { location.hash = "#/shoots"; }, actions: [selectBtn] });

  const main = $("#main");
  main.replaceChildren(h("p", { class: "muted" }, "Loading…"));
  const qs = new URLSearchParams({ sort: state.sort }); if (state.filter) qs.set("recommendation", state.filter);
  const photos = await api("/shoots/" + id + "/photos?" + qs);
  state.photoIds = photos.map(p => p.id);

  const chips = h("div", { class: "chips" },
    ["", "KEEP", "MAYBE", "REJECT"].map(f => h("button", { class: "chip" + (state.filter === f ? " on" : ""), onclick: () => { state.filter = f; route(); } }, f || "All")),
    h("span", { style: "width:8px" }),
    [["score", "By score"], ["filename", "By name"]].map(([k, l]) => h("button", { class: "chip" + (state.sort === k ? " on" : ""), onclick: () => { state.sort = k; route(); } }, l)));

  const summary = h("div", { class: "row", style: "margin-bottom:10px" },
    h("span", { class: "muted small" }, photos.length + " shown · " + shoot.evaluated + "/" + shoot.total_files + " critiqued"),
    h("span", { class: "spacer" }),
    h("button", { class: "btn small primary", onclick: () => confirmSheet("Critique this shoot?",
      "Runs the full evaluation on the Mac for all " + shoot.total_files + " photos in “" + shoot.name + "”. It's queued behind anything already running.",
      "Start", () => startCritique({ path: shoot.folder_path })) }, "Critique shoot"));

  const grid = h("div", { class: "grid" }, photos.map(p => {
    const tile = h("button", { class: "tile" + (state.selected.has(p.id) ? " sel" : ""), "aria-label": p.filename },
      p.has_preview ? lazyImg("/previews/" + p.id + "?w=512", p.filename) : h("span", { class: "muted small", style: "padding:6px;display:block" }, p.filename),
      p.score != null ? h("span", { class: "score" }, fmtScore(p.score)) : null,
      p.recommendation ? h("span", { class: "dot " + p.recommendation }) : null,
      h("span", { class: "check" }, "✓"));
    tile.onclick = () => {
      if (state.selecting) { state.selected.has(p.id) ? state.selected.delete(p.id) : state.selected.add(p.id); tile.classList.toggle("sel"); renderActionBar(); }
      else location.hash = "#/photo/" + p.id;
    };
    return tile;
  }));
  main.replaceChildren(chips, summary, photos.length ? grid : h("p", { class: "muted empty" }, "Nothing matches this filter."));
  renderActionBar();
}

function renderActionBar() {
  const bar = $("#actionbar");
  if (!state.selecting || !location.hash.startsWith("#/shoot/")) { bar.replaceChildren(); return; }
  const n = state.selected.size;
  bar.replaceChildren(h("div", { class: "actionbar" },
    h("span", {}, n + " selected"), h("span", { class: "spacer" }),
    h("button", { class: "btn small", disabled: !n, onclick: () => startCritique({ ids: [...state.selected] }) }, "Critique"),
    h("button", { class: "btn small primary", disabled: !n || n > 20, onclick: () => exportSheet([...state.selected]) }, n > 20 ? "Max 20" : "Export")));
  document.body.style.paddingBottom = "calc(130px + env(safe-area-inset-bottom))";
}

async function startCritique(body) {
  try { const r = await api("/critique", { method: "POST", body }); toast("Queued — job " + r.job_id.slice(0, 8)); location.hash = "#/jobs"; }
  catch (e) { if (e instanceof AuthError) return showError(e); toast("Couldn't start: " + e.message, 4000); }
}

async function viewPhoto(id) {
  setTab("shoots");
  const ids = state.photoIds || [];
  const idx = ids.indexOf(id);
  const go = d => { const n = ids[idx + d]; if (n != null) location.hash = "#/photo/" + n; };
  setHeader("Photo", { back: () => { state.shootId ? location.hash = "#/shoot/" + state.shootId : history.back(); },
    actions: idx >= 0 ? [h("button", { class: "btn small", disabled: idx <= 0, onclick: () => go(-1) }, "‹"), h("button", { class: "btn small", disabled: idx >= ids.length - 1, onclick: () => go(1) }, "›")] : [] });
  const main = $("#main");
  const img = h("img", { class: "hero", alt: "" });
  setImg(img, "/previews/" + id + "?w=2048");
  main.replaceChildren(img, h("p", { class: "muted" }, "Loading…"));
  const d = await api("/results/" + id);
  setHeader(d.filename, { back: $("#back").onclick, actions: [...$("#hdr-actions").children] });
  const list = (title, items) => items && items.length ? h("div", { class: "card" }, h("strong", {}, title), h("ul", { class: "tight" }, items.map(i => h("li", {}, i)))) : null;
  const m = d.metadata || {};
  main.replaceChildren(...[img,
    h("div", { class: "card" },
      h("div", { class: "row" }, h("strong", { style: "font-size:24px" }, fmtScore(d.score)), d.recommendation ? h("span", { class: "pill " + d.recommendation }, d.recommendation) : h("span", { class: "pill" }, "not critiqued"),
        d.classification ? h("span", { class: "muted" }, d.classification) : null, h("span", { class: "spacer" }),
        h("button", { class: "btn small", onclick: () => exportSheet([id]) }, "Export")),
      d.percentile_shoot != null ? h("div", { class: "muted small", style: "margin-top:4px" }, "Top " + Math.max(1, Math.round(100 - d.percentile_shoot)) + "% of shoot") : null,
      d.critique ? h("p", {}, d.critique) : null),
    list("Strengths", d.strengths), list("Weaknesses", d.weaknesses), list("Technical", d.technical_issues),
    h("div", { class: "card muted small" }, [m.camera_model, m.lens, m.focal_length && m.focal_length + "mm", m.aperture && "f/" + m.aperture, m.shutter_speed, m.iso && "ISO " + m.iso, m.capture_time].filter(Boolean).join(" · ") || "No metadata")].filter(Boolean));
}

function exportSheet(ids) {
  config().then(cfg => sheet((s, close) => {
    const preset = h("select", {}, cfg.export_presets.map(p => h("option", { value: p, selected: p === "original" }, p.replace(/_/g, " "))));
    const go = h("button", { class: "btn primary" }, "Export " + ids.length);
    const out = h("div");
    go.onclick = async () => {
      go.disabled = true; go.textContent = "Exporting on the Mac…";
      const day = new Date().toISOString().slice(0, 10);
      try {
        const r = await api("/export", { method: "POST", body: { ids, preset: preset.value, dest: cfg.remote_exports_dir + "/" + day } });
        out.replaceChildren(h("p", { class: "muted small" }, r.exported + " exported" + (r.failed ? ", " + r.failed + " failed" : "")),
          ...r.results.map(res => res.error ? h("div", { class: "card err small" }, "File " + res.file_id + ": " + res.error) : downloadRow(res.path)));
        go.textContent = "Done";
      } catch (e) { out.replaceChildren(h("p", { class: "err" }, e.message)); go.disabled = false; go.textContent = "Retry"; }
    };
    s.append(h("h2", {}, "Export " + ids.length + " photo" + (ids.length > 1 ? "s" : "")),
      h("p", { class: "muted small" }, "Renders a JPEG on the Mac from the RAW and sends only that finished file to this phone."),
      h("label", { class: "field" }, h("span", { class: "small muted" }, "Preset"), preset),
      h("div", { class: "row" }, h("button", { class: "btn", onclick: close }, "Close"), h("span", { class: "spacer" }), go), out);
  })).catch(showError);
}

function downloadRow(path) {
  const url = "/downloads?path=" + encodeURIComponent(path);
  const name = path.split("/").pop();
  const thumb = h("img", { alt: "" });
  const save = h("a", { class: "btn small primary", href: "#", download: name }, "Save");
  api(url, { raw: true }).then(r => r.blob()).then(b => { const u = URL.createObjectURL(b); thumb.src = u; save.href = u; })
    .catch(e => { save.textContent = "Failed"; save.removeAttribute("href"); save.title = e.message; });
  return h("div", { class: "card row dl" }, thumb, h("span", { class: "small", style: "flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis" }, name), save);
}

async function viewJobs() {
  setTab("jobs"); setHeader("Jobs");
  const main = $("#main");
  const tick = async () => {
    let jobs;
    try { jobs = await api("/jobs?limit=30"); } catch (e) { stopPolling(); return showError(e); }
    if (!location.hash.startsWith("#/jobs")) return;
    main.replaceChildren(...(jobs.length ? jobs.map(jobCard) : [h("p", { class: "muted empty" }, "No jobs in the last 24 hours.")]));
    const active = jobs.some(j => j.status === "running" || j.status === "queued");
    pollTimer = setTimeout(tick, active ? 2500 : 10000);
  };
  main.replaceChildren(h("p", { class: "muted" }, "Loading…"));
  await tick();
}

function jobCard(j) {
  const pct = j.total ? Math.min(100, Math.round(100 * (j.current || 0) / j.total)) : null;
  const when = new Date(j.created_at * 1000).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  return h("div", { class: "card" },
    h("div", { class: "row" }, h("strong", { class: "status-" + j.status }, j.status), h("span", { class: "muted small" }, describeParams(j.params)), h("span", { class: "spacer" }), h("span", { class: "muted small" }, when)),
    j.stage || pct != null ? h("div", { class: "small muted", style: "margin-top:4px" }, [j.stage, pct != null ? (j.current + "/" + j.total + " · " + pct + "%") : null].filter(Boolean).join(" — ")) : null,
    j.status === "running" ? h("div", { class: "bar" }, h("div", { style: "width:" + (pct || 3) + "%" })) : null,
    j.error ? h("details", {}, h("summary", { class: "err small" }, "Error details"), h("pre", {}, j.error)) : null,
    j.result && j.result.files_evaluated != null ? h("div", { class: "small muted" }, j.result.files_evaluated + " photos in shoot") : null);
}
function describeParams(p) {
  if (!p) return "";
  const [kind, val] = p.split(":");
  if (kind === "shoot") { const s = (state.shoots || []).find(x => String(x.id) === val); return "shoot " + (s ? s.name : val); }
  if (kind === "files") return val + " photo(s)";
  return p;
}

function viewSettings(message) {
  setTab("settings"); setHeader("Connection");
  const input = h("input", { type: "password", placeholder: "Paste API token", autocomplete: "off", autocapitalize: "off", spellcheck: "false", value: token || "" });
  const status = h("p", { class: "small muted" }, message || "");
  const save = h("button", { class: "btn primary" }, "Save & test");
  save.onclick = async () => {
    token = input.value.trim(); store(TOKEN_KEY, token || null); configCache = null; state.shoots = null;
    status.textContent = "Testing…";
    try { const c = await config(); status.textContent = "Connected to PhotoCriticViewer " + c.app_version + "."; status.className = "small status-done"; }
    catch (e) { status.textContent = e.message; status.className = "small err"; }
  };
  $("#main").replaceChildren(h("div", { class: "card" },
    h("p", { class: "small muted", style: "margin-top:0" }, "Easiest: on the Mac open PhotoCriticViewer › Settings › Show iPhone setup QR, and scan it with the Camera. Or paste the token from ~/.photocritic/api_token."),
    h("label", { class: "field" }, input), h("div", { class: "row" }, save, h("span", { class: "spacer" }),
      h("button", { class: "btn", onclick: () => { token = null; store(TOKEN_KEY, null); input.value = ""; status.textContent = "Token removed from this phone."; } }, "Forget")), status),
    h("p", { class: "small muted" }, "Only reachable over Tailscale. Previews and exported JPEGs come to this phone; RAW files never leave the Mac."));
}

// ---- router (hash-based so the iOS back gesture works)
async function route() {
  stopPolling();
  document.body.style.paddingBottom = "";
  $("#actionbar").replaceChildren();
  if (!token) { if (location.hash !== "#/settings") history.replaceState(null, "", "#/settings"); return viewSettings("Connect this phone to PhotoCritic first."); }
  const hash = location.hash || "#/shoots";
  let m;
  try {
    if ((m = hash.match(/^#\/shoot\/(\d+)/))) await viewShoot(Number(m[1]));
    else if ((m = hash.match(/^#\/photo\/(\d+)/))) await viewPhoto(Number(m[1]));
    else if (hash.startsWith("#/jobs")) await viewJobs();
    else if (hash.startsWith("#/settings")) viewSettings();
    else await viewShoots();
  } catch (e) { showError(e); }
  window.scrollTo(0, scrollMemory.get(hash) || 0);
}
// Back from a photo should land where you were in the grid, not at the top.
const scrollMemory = new Map();
for (const b of document.querySelectorAll("nav.tabs button")) b.onclick = () => { location.hash = "#/" + b.dataset.tab; };
window.addEventListener("hashchange", e => {
  const old = new URL(e.oldURL).hash || "#/shoots";
  scrollMemory.set(old, window.scrollY);
  route();
});
route();
</script>
</body>
</html>
"""#
}
