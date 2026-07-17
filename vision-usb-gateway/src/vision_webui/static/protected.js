// Protected-folders page. Like the export page, it lives outside the admin
// password wall and signs in with the SMB password, so it stands alone from
// app.js and must not depend on anything the config UI loads.

function getCookie(name) {
  for (const p of document.cookie.split(";").map((s) => s.trim())) {
    if (p.startsWith(name + "=")) return p.split("=", 2)[1];
  }
  return "";
}

function showToast(text, kind) {
  let c = document.getElementById("toast-container");
  if (!c) {
    c = document.createElement("div");
    c.id = "toast-container";
    document.body.appendChild(c);
    const s = document.createElement("style");
    s.textContent =
      "#toast-container{position:fixed;top:18px;right:18px;z-index:9999;display:flex;" +
      "flex-direction:column;gap:10px;max-width:min(360px,92vw)}" +
      ".toast{padding:12px 16px;border-radius:8px;color:#fff;font-size:14px;line-height:1.35;" +
      "box-shadow:0 8px 28px rgba(0,0,0,.28);opacity:0;transform:translateX(24px);" +
      "transition:opacity .22s ease,transform .22s ease;word-break:break-word}" +
      ".toast.show{opacity:1;transform:none}" +
      ".toast.ok{background:#1e8e5a}.toast.warn{background:#b5760f}.toast.error{background:#bb4238}";
    document.head.appendChild(s);
  }
  const t = document.createElement("div");
  t.className = "toast " + (kind || "ok");
  t.textContent = text;
  c.appendChild(t);
  requestAnimationFrame(() => t.classList.add("show"));
  setTimeout(() => { t.classList.remove("show"); setTimeout(() => t.remove(), 260); }, 3600);
}

function setStatus(text) {
  document.getElementById("status-line").textContent = text;
}

async function api(path, options = {}) {
  const headers = options.headers || {};
  headers["X-CSRF"] = getCookie("csrf");
  headers["Content-Type"] = "application/json";
  options.headers = headers;
  const res = await fetch(path, options);
  if (res.status === 401) {
    setStatus("Session expired — signing in again");
    setTimeout(() => { window.location.href = "/protected"; }, 1200);
    throw new Error("Session expired");
  }
  if (!res.ok) {
    let text;
    try {
      const j = await res.json();
      text = j.error || j.message || res.statusText;
    } catch {
      text = (await res.text()) || res.statusText;
    }
    throw new Error(text);
  }
  return res.json();
}

const state = { path: "", picked: new Set(), mirror: null };

function fmtSize(n) {
  if (!n) return "0 B";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return n.toFixed(i ? 1 : 0) + " " + u[i];
}

function renderPicked() {
  const el = document.getElementById("protected-list");
  const rows = [...state.picked].sort().map(
    (p) => `<div class="file-row">${p}<button class="link-btn" data-drop="${p}">remove</button></div>`
  );
  el.innerHTML = rows.join("") || '<div class="hint">Nothing protected — the unit may delete any of it to make room.</div>';
  el.querySelectorAll("button[data-drop]").forEach((b) => {
    b.onclick = () => { state.picked.delete(b.dataset.drop); renderPicked(); loadDir(state.path); };
  });
}

async function loadDir(path) {
  const listEl = document.getElementById("mirror-list");
  try {
    const d = await api(`/api/usb-export/list?root=mirror&path=${encodeURIComponent(path || "")}`);
    state.path = d.path;
    const parts = d.path ? d.path.split("/") : [];
    const crumb = [`<a href="#" data-path="">mirror</a>`].concat(
      parts.map((p, i) => `<a href="#" data-path="${parts.slice(0, i + 1).join("/")}">${p}</a>`)
    );
    const crumbEl = document.getElementById("mirror-crumb");
    crumbEl.innerHTML = crumb.join(" / ");
    crumbEl.querySelectorAll("a").forEach((a) => {
      a.onclick = (e) => { e.preventDefault(); loadDir(a.dataset.path); };
    });

    // Only folders can be protected: retention deletes whole trees' worth of
    // images, and picking individual files would be unusable at 49k of them.
    const dirs = d.entries.filter((e) => e.dir);
    listEl.innerHTML = dirs.map((e) => {
      const full = d.path ? `${d.path}/${e.name}` : e.name;
      const covered = [...state.picked].some((p) => full === p || full.startsWith(p + "/"));
      const box = `<input type="checkbox" data-path="${full}"${state.picked.has(full) ? " checked" : ""}${covered && !state.picked.has(full) ? " disabled" : ""}>`;
      const note = covered && !state.picked.has(full) ? ' <span class="hint">(already covered)</span>' : "";
      return `<div class="file-row">${box} <a href="#" data-path="${full}"><b>${e.name}/</b></a>${note}</div>`;
    }).join("") || '<div class="hint">(no folders here)</div>';

    listEl.querySelectorAll("a").forEach((a) => {
      a.onclick = (e) => { e.preventDefault(); loadDir(a.dataset.path); };
    });
    listEl.querySelectorAll("input[type=checkbox]").forEach((c) => {
      c.onchange = () => {
        if (c.checked) state.picked.add(c.dataset.path);
        else state.picked.delete(c.dataset.path);
        renderPicked();
        loadDir(state.path);
      };
    });
  } catch (err) {
    listEl.innerHTML = `<div class="hint">${err.message}</div>`;
  }
}

async function refresh() {
  let s;
  try {
    s = await api("/api/protected");
  } catch { return; }
  state.picked = new Set(s.paths);
  state.mirror = s.mirror || {};
  renderPicked();

  document.getElementById("usage").textContent =
    `Mirror: ${s.mirror.avail || "?"} free of ${s.mirror.size || "?"} (${s.mirror.percent || "?"} used) · ` +
    `protected: ${fmtSize(s.protected_bytes)}`;
  setStatus(`${s.paths.length} folder(s) protected`);

  // Retention said it is stuck. That means the mirror is filling and the sync
  // will stop capturing — the operator has to see it here, not only in a log.
  const bb = document.getElementById("blocked-banner");
  if (s.blocked) {
    bb.classList.remove("hidden");
    bb.innerHTML =
      `<b>The unit cannot free up space.</b> The disk is at ${s.blocked.usage}% and everything` +
      ` else has already been deleted. <b>New images may stop being saved.</b>` +
      ` Un-protect something, or copy it off and remove it.`;
  } else {
    bb.classList.add("hidden");
  }

  // Warn before that happens, not after.
  const sb = document.getElementById("space-banner");
  const pct = parseInt((s.mirror.percent || "0").replace("%", ""), 10);
  const share = s.mirror.size ? null : null;
  if (!s.blocked && s.paths.length && pct >= 75) {
    sb.classList.remove("hidden");
    sb.textContent =
      `The disk is ${pct}% full and ${fmtSize(s.protected_bytes)} of it is protected. ` +
      `Leave the unit enough it may delete, or it will run out of room for new images.`;
  } else {
    sb.classList.add("hidden");
  }
}

document.getElementById("save").onclick = async () => {
  try {
    await api("/api/protected", {
      method: "POST",
      body: JSON.stringify({ paths: [...state.picked] }),
    });
    showToast(`Saved — ${state.picked.size} folder(s) protected`, "ok");
    refresh();
  } catch (err) { showToast(err.message, "error"); }
};

refresh();
loadDir("");
setInterval(refresh, 15000);
