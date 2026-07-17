// USB export page. Stands alone from app.js: this page lives outside the admin
// password wall (it signs in with the SMB password an operator already has), so
// it must not depend on anything the config UI loads.
//
// The mirror pane is read-only by design — an operator may take production data
// off the unit, never delete it. Copies run in a transient systemd unit on the
// unit itself, so closing this page does not abort a multi-hour transfer.

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
    setTimeout(() => { window.location.href = "/export"; }, 1200);
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

const usbState = { mirror: "", usb: "", picked: new Set(), present: false };

function fmtSize(n) {
  if (n === undefined || n === null) return "";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return n.toFixed(i ? 1 : 0) + " " + u[i];
}

function renderCrumb(el, root, path) {
  const parts = path ? path.split("/") : [];
  const bits = [`<a href="#" data-root="${root}" data-path="">${root === "mirror" ? "mirror" : "usb"}</a>`];
  parts.forEach((p, i) => {
    bits.push(`<a href="#" data-root="${root}" data-path="${parts.slice(0, i + 1).join("/")}">${p}</a>`);
  });
  el.innerHTML = bits.join(" / ");
  el.querySelectorAll("a").forEach((a) => {
    a.onclick = (e) => { e.preventDefault(); loadDir(a.dataset.root, a.dataset.path); };
  });
}

async function loadDir(root, path) {
  const listEl = document.getElementById(root === "mirror" ? "mirror-list" : "usb-list");
  try {
    const d = await api(`/api/usb-export/list?root=${root}&path=${encodeURIComponent(path || "")}`);
    usbState[root] = d.path;
    renderCrumb(document.getElementById(root === "mirror" ? "mirror-crumb" : "usb-crumb"), root, d.path);
    const rows = d.entries.map((e) => {
      const full = d.path ? `${d.path}/${e.name}` : e.name;
      const box = root === "mirror"
        ? `<input type="checkbox" data-path="${full}"${usbState.picked.has(full) ? " checked" : ""}>`
        : "";
      const name = e.dir
        ? `<a href="#" data-root="${root}" data-path="${full}"><b>${e.name}/</b></a>`
        : e.name;
      return `<div class="file-row">${box} ${name} <span class="hint">${e.dir ? "" : fmtSize(e.size)}</span></div>`;
    });
    listEl.innerHTML = rows.join("") || '<div class="hint">(empty)</div>';
    listEl.querySelectorAll("a").forEach((a) => {
      a.onclick = (e) => { e.preventDefault(); loadDir(a.dataset.root, a.dataset.path); };
    });
    listEl.querySelectorAll("input[type=checkbox]").forEach((c) => {
      c.onchange = () => {
        if (c.checked) usbState.picked.add(c.dataset.path);
        else usbState.picked.delete(c.dataset.path);
      };
    });
  } catch (err) {
    listEl.innerHTML = `<div class="hint">${err.message}</div>`;
  }
}

// "0:01:23" -> "1m 23s left". rsync's own estimate: it knows the total up front
// (--no-inc-recursive) and the current rate, which is a better guess than
// anything recomputed from percentages sampled every 5s.
function fmtEta(eta) {
  const p = (eta || "").split(":").map(Number);
  if (p.length !== 3 || p.some(isNaN)) return "";
  const [h, m, s] = p;
  if (h) return `${h}h ${m}m left`;
  if (m) return `${m}m ${s}s left`;
  return s > 0 ? `${s}s left` : "finishing…";
}

function renderProgress(job) {
  const bar = document.getElementById("usb-progress");
  const p = (job && job.progress) || {};
  const has = typeof p.percent === "number";

  if (job && job.running) {
    bar.classList.remove("hidden");
    bar.innerHTML = has
      ? `<div class="prog-head"><b>Copying… ${p.percent}%</b>` +
        `<span>${p.rate} · ${fmtEta(p.eta)}</span></div>` +
        `<div class="prog-track"><div class="prog-fill" style="width:${p.percent}%"></div></div>`
      : "<b>Copying…</b> <span class='hint'>counting files…</span>";
    return;
  }
  if (!bar.classList.contains("hidden")) {
    const ok = job && job.result === "success";
    bar.innerHTML = ok
      ? "<b>Copy finished.</b> Press <b>Safely remove</b> before unplugging."
      : `<b>Copy ended:</b> ${(job && job.result) || "unknown"}`;
    loadDir("usb", usbState.usb);
    setTimeout(() => bar.classList.add("hidden"), 8000);
  }
}

async function refreshUsbExport() {
  let s;
  try {
    s = await api("/api/usb-export/status");
  } catch { return false; }
  const changed = s.present !== usbState.present;
  usbState.present = s.present;
  document.getElementById("usb-none").classList.toggle("hidden", s.present);
  document.getElementById("usb-present").classList.toggle("hidden", !s.present);
  if (!s.present) { setStatus("No drive plugged in"); return false; }

  // get_disk_usage returns df's own human-readable strings ("118G"), not bytes.
  const u = s.usage || {};
  document.getElementById("usb-info").textContent =
    `${s.device} · ${s.fstype}${s.label ? " · " + s.label : ""} · ` +
    `${u.avail || "?"} free of ${u.size || "?"} (${u.percent || "?"} used)` +
    (s.write_through ? " · write-through: safe to unplug, slower" : "");
  setStatus("Drive ready");
  if (changed) { usbState.picked.clear(); loadDir("mirror", ""); loadDir("usb", ""); }

  const job = await api("/api/usb-export/job").catch(() => null);
  renderProgress(job);
  const busy = !!(job && job.running);
  document.getElementById("usb-copy").disabled = busy;
  document.getElementById("usb-eject").disabled = busy;
  document.getElementById("usb-mkdir").disabled = busy;
  return busy;
}

document.getElementById("usb-copy").onclick = async () => {
  if (!usbState.picked.size) { showToast("Nothing selected", "error"); return; }
  const items = [...usbState.picked].map((p) => ({ root: "mirror", path: p }));
  try {
    await api("/api/usb-export/copy", {
      method: "POST",
      body: JSON.stringify({ items, dest: usbState.usb }),
    });
    showToast(`Copying ${items.length} item(s) to the USB drive`, "ok");
    refreshUsbExport();
  } catch (err) { showToast(err.message, "error"); }
};

document.getElementById("usb-mkdir").onclick = async () => {
  const name = prompt("New folder name:");
  if (!name) return;
  try {
    await api("/api/usb-export/mkdir", {
      method: "POST",
      body: JSON.stringify({ name: name.trim(), path: usbState.usb }),
    });
    showToast(`Folder created: ${name.trim()}`, "ok");
    loadDir("usb", usbState.usb);
  } catch (err) { showToast(err.message, "error"); }
};

document.getElementById("usb-eject").onclick = async () => {
  try {
    await api("/api/usb-export/eject", { method: "POST" });
    showToast("Drive flushed and unmounted — safe to unplug", "ok");
    usbState.present = false;
    refreshUsbExport();
  } catch (err) { showToast(err.message, "error"); }
};

// A progress bar wants to move, but polling twice a second forever just to watch
// an idle drive is waste. Chase the copy, idle the rest of the time.
async function pollLoop() {
  const busy = await refreshUsbExport();
  setTimeout(pollLoop, busy ? 1000 : 5000);
}
pollLoop();
