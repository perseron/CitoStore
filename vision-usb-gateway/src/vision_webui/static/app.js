function getCookie(name) {
  const parts = document.cookie.split(";").map(p => p.trim());
  for (const p of parts) {
    if (p.startsWith(name + "=")) {
      return p.split("=", 2)[1];
    }
  }
  return "";
}

function isValidIPv4(s) {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s);
  if (!m) return false;
  return m.slice(1, 5).every(o => { const n = Number(o); return n >= 0 && n <= 255; });
}

async function api(path, options = {}) {
  const csrf = getCookie("csrf");
  const headers = options.headers || {};
  headers["X-CSRF"] = csrf;
  headers["Content-Type"] = "application/json";
  options.headers = headers;
  const res = await fetch(path, options);
  if (res.status === 401) {
    setStatus("\u2716 Session expired \u2014 redirecting to login");
    setTimeout(() => { window.location.href = "/login"; }, 1500);
    throw new Error("Session expired");
  }
  if (!res.ok) {
    let text;
    try {
      const json = await res.json();
      text = json.error || json.message || res.statusText;
    } catch {
      text = await res.text() || res.statusText;
    }
    throw new Error(text);
  }
  return res.json();
}

function setStatus(text) {
  const el = document.getElementById("status-line");
  el.classList.remove("status-ok", "status-warn", "status-error");
  const lower = text.toLowerCase();
  if (lower.startsWith("error") || lower.includes("failed")) {
    el.textContent = "\u2716 " + text;
    el.classList.add("status-error");
  } else if (lower.includes("warn") || lower.includes("expired")) {
    el.textContent = "\u26A0 " + text;
    el.classList.add("status-warn");
  } else {
    el.textContent = "\u2714 " + text;
    el.classList.add("status-ok");
  }
}

function setFieldValidity(el, ok, message = "") {
  const label = el.closest("label");
  if (!label) return;
  if (ok) {
    label.classList.remove("invalid");
    if (message) label.querySelector(".hint").textContent = message;
  } else {
    label.classList.add("invalid");
    if (message) label.querySelector(".hint").textContent = message;
  }
}

function validateField(el) {
  const rule = el.dataset.validate || "";
  const value = (el.value || "").trim();
  if (!rule) return true;
  if (rule.startsWith("match:")) {
    const targetId = rule.split(":", 2)[1];
    const target = document.getElementById(targetId);
    const ok = target ? value === target.value : false;
    setFieldValidity(el, ok, ok ? "must match" : "does not match");
    return ok;
  }
  if (rule === "time") {
    const ok = /^[0-9]+(ms|s|sec|secs|min|mins|h|hr|hrs|d|day|days)?$/.test(value);
    setFieldValidity(el, ok, ok ? "e.g. 30s, 2min" : "invalid time");
    return ok;
  }
  if (rule === "netbios") {
    const ok = value.length >= 1 && value.length <= 15 && /^[A-Za-z0-9_-]+$/.test(value);
    setFieldValidity(el, ok, ok ? "1-15 chars, letters/numbers/_/-" : "invalid");
    return ok;
  }
  if (rule === "nas-remote") {
    const ok = value === "" || /^\/\/[^/]+\/.+/.test(value);
    setFieldValidity(el, ok, ok ? "e.g. //nas/vision" : "invalid //host/share");
    return ok;
  }
  if (rule === "path") {
    const ok = value === "" || value.startsWith("/");
    setFieldValidity(el, ok, ok ? "absolute path" : "must start with /");
    return ok;
  }
  if (rule === "iface") {
    const ok = value.length > 0 && /^[A-Za-z0-9_.:-]+$/.test(value);
    setFieldValidity(el, ok, ok ? "e.g. eth0" : "invalid interface");
    return ok;
  }
  if (rule === "ip") {
    const method = document.getElementById("NET_METHOD")?.value || "auto";
    if (method === "auto" && value === "") {
      setFieldValidity(el, true, "required for static");
      return true;
    }
    const ok = isValidIPv4(value);
    setFieldValidity(el, ok, ok ? "IPv4" : "invalid IPv4");
    return ok;
  }
  if (rule === "ip-optional") {
    const ok = value === "" || isValidIPv4(value);
    setFieldValidity(el, ok, ok ? "optional" : "invalid IPv4");
    return ok;
  }
  if (rule === "prefix") {
    const method = document.getElementById("NET_METHOD")?.value || "auto";
    if (method === "auto" && value === "") {
      setFieldValidity(el, true, "required for static");
      return true;
    }
    const num = Number(value);
    const ok = Number.isInteger(num) && num >= 1 && num <= 32;
    setFieldValidity(el, ok, ok ? "1-32" : "invalid prefix");
    return ok;
  }
  if (rule === "dns") {
    if (value === "") {
      setFieldValidity(el, true, "optional");
      return true;
    }
    const parts = value.split(",").map(v => v.trim()).filter(v => v !== "");
    const ok = parts.length > 0 && parts.every(v => isValidIPv4(v));
    setFieldValidity(el, ok, ok ? "comma-separated IPv4" : "invalid DNS list");
    return ok;
  }
  if (rule === "size") {
    const ok = /^[0-9]+(K|M|G|T)?$/.test(value);
    setFieldValidity(el, ok, ok ? "e.g. 100G, 512M" : "invalid size");
    return ok;
  }
  if (rule === "lines") {
    const num = Number(value);
    const ok = Number.isInteger(num) && num >= 10 && num <= 2000;
    setFieldValidity(el, ok, ok ? "10-2000" : "invalid");
    return ok;
  }
  if (rule.startsWith("int-range:")) {
    const parts = rule.split(":");
    const min = Number(parts[1]);
    const max = Number(parts[2]);
    const num = Number(value);
    const ok = Number.isInteger(num) && num >= min && num <= max;
    setFieldValidity(el, ok, ok ? `${min}-${max}` : `out of range ${min}-${max}`);
    return ok;
  }
  if (rule.startsWith("float-range:")) {
    const parts = rule.split(":");
    const min = Number(parts[1]);
    const max = Number(parts[2]);
    const num = Number(value);
    const ok = !isNaN(num) && num >= min && num <= max;
    setFieldValidity(el, ok, ok ? `${min}-${max}` : `out of range ${min}-${max}`);
    return ok;
  }
  if (rule === "datetime") {
    const ok = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(value);
    setFieldValidity(el, ok, ok ? "YYYY-MM-DD HH:MM:SS" : "invalid datetime");
    return ok;
  }
  if (rule === "date") {
    const ok = /^\d{4}-\d{2}-\d{2}$/.test(value);
    setFieldValidity(el, ok, ok ? "YYYY-MM-DD" : "invalid date");
    return ok;
  }
  if (rule === "clock") {
    const ok = /^\d{2}:\d{2}:\d{2}$/.test(value);
    setFieldValidity(el, ok, ok ? "HH:MM:SS" : "invalid time");
    return ok;
  }
  if (rule === "hhmm") {
    const ok = /^\d{1,2}:\d{2}$/.test(value);
    setFieldValidity(el, ok, ok ? "HH:MM" : "invalid HH:MM");
    return ok;
  }
  if (rule === "user" || rule === "domain" || rule === "password") {
    if (rule === "password" && value !== "" && value.length < 6) {
      setFieldValidity(el, false, "min 6 chars");
      return false;
    }
    setFieldValidity(el, true, value === "" ? "optional" : "ok");
    return true;
  }
  return true;
}

function validateAll() {
  let ok = true;
  document.querySelectorAll("[data-validate]").forEach(el => {
    if (!validateField(el)) ok = false;
  });
  return ok;
}

function fillConfig(cfg) {
  for (const key of Object.keys(cfg)) {
    const el = document.getElementById(key);
    if (el) el.value = cfg[key] || "";
  }
}

function withLoading(button, asyncFn) {
  return async function(...args) {
    if (button.disabled) return;
    button.disabled = true;
    const spinner = document.createElement("span");
    spinner.className = "spinner";
    button.prepend(spinner);
    try {
      await asyncFn(...args);
    } catch (err) {
      setStatus("Error: " + err.message);
    } finally {
      button.disabled = false;
      spinner.remove();
    }
  };
}

function showModal(title, message, confirmText, requireInput) {
  return new Promise((resolve) => {
    const overlay = document.getElementById("modal-overlay");
    document.getElementById("modal-title").textContent = title;
    document.getElementById("modal-message").textContent = message;
    const input = document.getElementById("modal-input");
    const confirmBtn = document.getElementById("modal-confirm");
    const cancelBtn = document.getElementById("modal-cancel");

    if (requireInput) {
      input.classList.remove("hidden");
      input.value = "";
      input.placeholder = 'Type "' + confirmText + '" to confirm';
      confirmBtn.disabled = true;
      const handler = () => {
        confirmBtn.disabled = input.value !== confirmText;
      };
      input.addEventListener("input", handler);
      input._handler = handler;
    } else {
      input.classList.add("hidden");
      confirmBtn.disabled = false;
    }

    overlay.classList.remove("hidden");
    if (requireInput) input.focus();

    function cleanup(result) {
      overlay.classList.add("hidden");
      if (input._handler) {
        input.removeEventListener("input", input._handler);
        input._handler = null;
      }
      confirmBtn.removeEventListener("click", onConfirm);
      cancelBtn.removeEventListener("click", onCancel);
      resolve(result);
    }
    function onConfirm() { cleanup(true); }
    function onCancel() { cleanup(false); }
    confirmBtn.addEventListener("click", onConfirm);
    cancelBtn.addEventListener("click", onCancel);
  });
}

async function loadStatus() {
  const data = await api("/api/status", { method: "GET" });
  const services = data.services || {};
  const svcLines = Object.entries(services).map(
    ([name, st]) => `${name}: ${st.active}/${st.sub}`
  );
  document.getElementById("status-services").textContent = svcLines.join("\n");
  const usbUsage = data.active_usb_usage || {};
  let usbLine = `Active USB LV: ${data.active_usb_lv}`;
  if (!usbUsage.error && (usbUsage.size || usbUsage.percent || usbUsage.size_gb || usbUsage.data_percent)) {
    const size = usbUsage.size || (usbUsage.size_gb ? `${usbUsage.size_gb}G` : "n/a");
    const used = usbUsage.percent || (usbUsage.data_percent ? `${usbUsage.data_percent}%` : "n/a");
    usbLine += ` (size ${size}, used ${used})`;
  }
  document.getElementById("status-usb").textContent = usbLine;
  const net = data.network || {};
  const timer = data.sync_timer || {};
  const syncSvc = data.sync_service || {};
  const usage = data.mirror_usage || {};
  const nvme = data.nvme || {};
  const timerLine = timer.next_remaining
    ? `Next sync in: ${timer.next_remaining}`
    : "Next sync in: n/a";
  const usageLine = usage.percent
    ? `Mirror usage: ${usage.percent} (${usage.used} / ${usage.size})`
    : "Mirror usage: n/a";
  let nvmeLine = "NVMe SMART: n/a";
  if (nvme.error) {
    nvmeLine = `NVMe SMART: ${nvme.error}`;
  } else if (nvme.device) {
    const temp = nvme.temperature_c !== null && nvme.temperature_c !== undefined
      ? `${nvme.temperature_c}C`
      : "n/a";
    let used = "usage n/a";
    if (nvme.percentage_used !== undefined && nvme.percentage_used !== null) {
      used = `${nvme.percentage_used}% used`;
    } else if (nvme.data_units_written_tb !== undefined && nvme.data_units_written_tb !== null) {
      used = `${nvme.data_units_written_tb} TB written`;
    }
    const poh = nvme.power_on_hours !== undefined && nvme.power_on_hours !== null
      ? `${nvme.power_on_hours}h`
      : "n/a";
    const media = nvme.media_errors !== undefined && nvme.media_errors !== null
      ? `${nvme.media_errors}`
      : "n/a";
    const unsafe = nvme.unsafe_shutdowns !== undefined && nvme.unsafe_shutdowns !== null
      ? `${nvme.unsafe_shutdowns}`
      : "n/a";
    let nvmeStatus = "OK";
    const mediaNum = Number(nvme.media_errors);
    const usedNum = Number(nvme.percentage_used);
    if (!Number.isNaN(mediaNum) && mediaNum > 0) {
      nvmeStatus = "ERROR";
    } else if (
      (!Number.isNaN(usedNum) && usedNum >= 90) ||
      (nvme.temperature_c !== null && nvme.temperature_c !== undefined && nvme.temperature_c >= 70)
    ) {
      nvmeStatus = "WARN";
    }
    nvmeLine = `NVMe ${nvme.device}: ${nvmeStatus} | temp ${temp}, ${used}, POH ${poh}, media ${media}, unsafe ${unsafe}`;
  }
  document.getElementById("status-network").textContent =
    `Network: ${net.interface || ""} ${net.address || ""} ${net.gateway || ""}\n${timerLine}\n${usageLine}`;
  const syncRuntime = syncSvc.last_runtime_sec !== null && syncSvc.last_runtime_sec !== undefined
    ? `${syncSvc.last_runtime_sec}s`
    : "n/a";
  const syncCpu = syncSvc.cpu_total_sec !== null && syncSvc.cpu_total_sec !== undefined
    ? `${syncSvc.cpu_total_sec}s`
    : "n/a";
  const syncFinish = syncSvc.last_finish || "n/a";
  const syncResult = syncSvc.result || "unknown";
  document.getElementById("status-sync").textContent =
    `Sync last runtime: ${syncRuntime}\nSync CPU total: ${syncCpu}\nLast finish: ${syncFinish}\nResult: ${syncResult}`;
  const nvmeEl = document.getElementById("status-nvme");
  nvmeEl.textContent = nvmeLine;
  nvmeEl.classList.remove("status-ok", "status-warn", "status-error");
  if (nvmeLine.includes("ERROR")) {
    nvmeEl.classList.add("status-error");
  } else if (nvmeLine.includes("WARN")) {
    nvmeEl.classList.add("status-warn");
  } else if (nvmeLine.startsWith("NVMe")) {
    nvmeEl.classList.add("status-ok");
  }
  setStatus("OK");
}

async function loadConfig() {
  const cfg = await api("/api/config", { method: "GET" });
  fillConfig(cfg);
  const resize = document.getElementById("RESIZE_SIZE");
  if (resize && (!resize.value || resize.value.trim() === "") && cfg.USB_LV_SIZE) {
    resize.value = cfg.USB_LV_SIZE;
    validateField(resize);
  }
  const creds = await api("/api/nas-creds", { method: "GET" });
  if (creds.username !== undefined) document.getElementById("NAS_USERNAME").value = creds.username || "";
  if (creds.password !== undefined) document.getElementById("NAS_PASSWORD").value = creds.password || "";
  if (creds.domain !== undefined) document.getElementById("NAS_DOMAIN").value = creds.domain || "";
  const net = await api("/api/network", { method: "GET" });
  if (net.interface) document.getElementById("NET_IFACE").value = net.interface;
  if (net.method) document.getElementById("NET_METHOD").value = net.method === "manual" ? "manual" : "auto";
  if (net.address) {
    const addr = net.address.split(",")[0];
    const parts = addr.split("/");
    document.getElementById("NET_ADDR").value = parts[0] || "";
    document.getElementById("NET_PREFIX").value = parts[1] || "";
  }
  if (net.gateway) document.getElementById("NET_GW").value = net.gateway;
  if (net.dns) document.getElementById("NET_DNS").value = net.dns;
}

async function loadLogServices() {
  const data = await api("/api/log-services", { method: "GET" });
  const sel = document.getElementById("LOG_SERVICE");
  if (!sel || !data.services) return;
  sel.innerHTML = "";
  data.services.forEach(name => {
    const opt = document.createElement("option");
    opt.value = name;
    opt.textContent = name;
    sel.appendChild(opt);
  });
  if (!sel.value) {
    sel.value = "vision-sync.service";
  }
}

async function refreshLogs() {
  const sel = document.getElementById("LOG_SERVICE");
  const linesEl = document.getElementById("LOG_LINES");
  if (!sel || !linesEl) return;
  if (!validateField(linesEl)) {
    setStatus("Invalid log line count");
    return;
  }
  const service = sel.value;
  const lines = linesEl.value || "200";
  const data = await api(`/api/logs?service=${encodeURIComponent(service)}&lines=${encodeURIComponent(lines)}`, { method: "GET" });
  const out = data.text || "";
  document.getElementById("log-output").textContent = out || "(no output)";
}

async function saveConfig(apply = false) {
  if (!validateAll()) {
    setStatus("Fix invalid fields before saving");
    return;
  }
  const payload = {
    NETBIOS_NAME: document.getElementById("NETBIOS_NAME").value,
    SMB_WORKGROUP: document.getElementById("SMB_WORKGROUP").value,
    SYNC_INTERVAL_SEC: document.getElementById("SYNC_INTERVAL_SEC").value,
    SYNC_HI_INTERVAL_SEC: document.getElementById("SYNC_HI_INTERVAL_SEC").value,
    SYNC_ONBOOT_SEC: document.getElementById("SYNC_ONBOOT_SEC").value,
    SYNC_ONACTIVE_SEC: document.getElementById("SYNC_ONACTIVE_SEC").value,
    SYNC_SCAN_DEPTH: document.getElementById("SYNC_SCAN_DEPTH").value,
    SYNC_HOT_DIRS: document.getElementById("SYNC_HOT_DIRS").value,
    SYNC_COLD_AUDIT_DIRS_PER_RUN: document.getElementById("SYNC_COLD_AUDIT_DIRS_PER_RUN").value,
    BYDATE_USE_FILE_TIME: document.getElementById("BYDATE_USE_FILE_TIME").value,
    RAW_APPEND_ALWAYS: document.getElementById("RAW_APPEND_ALWAYS").value,
    NAS_ENABLED: document.getElementById("NAS_ENABLED").value,
    NAS_REMOTE: document.getElementById("NAS_REMOTE").value,
    NAS_MOUNT: document.getElementById("NAS_MOUNT").value,
    SWITCH_WINDOW_START: document.getElementById("SWITCH_WINDOW_START").value,
    SWITCH_WINDOW_END: document.getElementById("SWITCH_WINDOW_END").value,
    SWITCH_DELAY_SEC: document.getElementById("SWITCH_DELAY_SEC").value,
  };
  await api("/api/config", { method: "POST", body: JSON.stringify(payload) });
  await api("/api/nas-creds", {
    method: "POST",
    body: JSON.stringify({
      username: document.getElementById("NAS_USERNAME").value,
      password: document.getElementById("NAS_PASSWORD").value,
      domain: document.getElementById("NAS_DOMAIN").value,
    }),
  });
  if (apply) await api("/api/apply", { method: "POST", body: "{}" });
  setStatus("Config saved" + (apply ? " and applied" : ""));
}

async function applyNetwork() {
  if (!validateAll()) {
    setStatus("Fix invalid fields before applying network");
    return;
  }
  const rawDns = document.getElementById("NET_DNS").value;
  const dns = rawDns.split(",").map(v => v.trim()).filter(v => v).join(",");
  const payload = {
    interface: document.getElementById("NET_IFACE").value,
    method: document.getElementById("NET_METHOD").value,
    address: document.getElementById("NET_ADDR").value,
    prefix: document.getElementById("NET_PREFIX").value,
    gateway: document.getElementById("NET_GW").value,
    dns: dns,
  };
  await api("/api/network", { method: "POST", body: JSON.stringify(payload) });
  setStatus("Network updated");
}

async function changeWebuiPassword() {
  if (!validateAll()) {
    setStatus("Fix invalid fields before changing password");
    return;
  }
  const password = document.getElementById("WEBUI_PASS").value;
  const confirm = document.getElementById("WEBUI_PASS2").value;
  await api("/api/password/webui", { method: "POST", body: JSON.stringify({ password, confirm }) });
  setStatus("Web UI password updated");
}

async function changeSmbPassword() {
  if (!validateAll()) {
    setStatus("Fix invalid fields before changing password");
    return;
  }
  const password = document.getElementById("SMB_PASS").value;
  const confirm = document.getElementById("SMB_PASS2").value;
  await api("/api/password/smb", { method: "POST", body: JSON.stringify({ password, confirm }) });
  setStatus("SMB password updated");
}

async function setManualTime() {
  const dateEl = document.getElementById("MANUAL_DATE");
  const timeEl = document.getElementById("MANUAL_CLOCK");
  const ok = validateField(dateEl) && validateField(timeEl);
  if (!ok) {
    setStatus("Invalid date/time format");
    return;
  }
  const value = `${dateEl.value} ${timeEl.value}`;
  await api("/api/time", { method: "POST", body: JSON.stringify({ time: value }) });
  setStatus("Time updated");
}

const MAINTENANCE_CONFIRMATIONS = {
  "wipe":             { title: "Wipe All Data", msg: "This will erase all USB and mirror data. Configuration is preserved.", text: "WIPE ALL DATA" },
  "rebalance":        { title: "Rebalance Storage", msg: "This rebalances thin-pool storage allocation.", text: "REBALANCE" },
  "resize":           { title: "Resize USB LVs", msg: "This will resize all USB logical volumes.", text: "RESIZE" },
  "shutdown":         { title: "Safe Shutdown", msg: "The device will power off.", text: "SHUTDOWN" },
  "restore-defaults": { title: "Restore Defaults", msg: "Configuration will be reset to factory defaults. Data is preserved.", text: "RESTORE DEFAULTS" },
  "clone-usb-format": { title: "Clone USB Format", msg: "USB LVs will be reformatted.", text: "CLONE USB FORMAT" },
  "rotate":           { title: "Rotate USB Now", msg: "The active USB LV will switch to the next one.", text: null },
};

async function maintenance(action) {
  let payload = {};
  const conf = MAINTENANCE_CONFIRMATIONS[action];
  if (conf) {
    const ok = conf.text
      ? await showModal(conf.title, conf.msg, conf.text, true)
      : await showModal(conf.title, conf.msg, null, false);
    if (!ok) return;
  }
  if (action === "resize") {
    const sizeField = document.getElementById("RESIZE_SIZE");
    if (!validateField(sizeField)) {
      setStatus("Invalid resize size");
      return;
    }
    payload.size = sizeField.value;
  }
  await api(`/api/maintenance/${action}`, { method: "POST", body: JSON.stringify(payload) });
  setStatus(`${action} started`);
  if (action === "rotate") {
    setTimeout(refreshStatus, 2000);
  }
}

document.getElementById("save-config").addEventListener("click",
  withLoading(document.getElementById("save-config"), () => saveConfig(false)));
document.getElementById("apply-config").addEventListener("click",
  withLoading(document.getElementById("apply-config"), () => saveConfig(true)));
document.getElementById("apply-network").addEventListener("click",
  withLoading(document.getElementById("apply-network"), applyNetwork));
document.getElementById("save-webui-pass").addEventListener("click",
  withLoading(document.getElementById("save-webui-pass"), changeWebuiPassword));
document.getElementById("save-smb-pass").addEventListener("click",
  withLoading(document.getElementById("save-smb-pass"), changeSmbPassword));
document.getElementById("wipe").addEventListener("click",
  withLoading(document.getElementById("wipe"), () => maintenance("wipe")));
document.getElementById("rebalance").addEventListener("click",
  withLoading(document.getElementById("rebalance"), () => maintenance("rebalance")));
document.getElementById("resize-usb").addEventListener("click",
  withLoading(document.getElementById("resize-usb"), () => maintenance("resize")));
document.getElementById("restore-defaults").addEventListener("click",
  withLoading(document.getElementById("restore-defaults"), () => maintenance("restore-defaults")));
document.getElementById("clone-usb-format").addEventListener("click",
  withLoading(document.getElementById("clone-usb-format"), () => maintenance("clone-usb-format")));
document.getElementById("rotate-usb").addEventListener("click",
  withLoading(document.getElementById("rotate-usb"), () => maintenance("rotate")));
document.getElementById("shutdown").addEventListener("click",
  withLoading(document.getElementById("shutdown"), () => maintenance("shutdown")));
document.getElementById("set-time").addEventListener("click",
  withLoading(document.getElementById("set-time"), setManualTime));
document.getElementById("refresh-logs").addEventListener("click",
  withLoading(document.getElementById("refresh-logs"), refreshLogs));

async function checkSessionExpiry() {
  try {
    const me = await api("/api/me", { method: "GET" });
    if (me.session_expires) {
      const remaining = me.session_expires - Math.floor(Date.now() / 1000);
      const banner = document.getElementById("health-banner");
      if (remaining < 900 && remaining > 0) {
        const mins = Math.ceil(remaining / 60);
        banner.textContent = `Session expires in ${mins} minute${mins === 1 ? "" : "s"}. Save your work.`;
        banner.classList.remove("hidden");
        banner.classList.remove("error");
      }
    }
  } catch { /* handled by api() 401 redirect */ }
}

async function refreshStatus() {
  try {
    await loadStatus();
    const time = await api("/api/time", { method: "GET" });
    if (time && time.status) {
      document.getElementById("time-status").textContent = time.status;
    }
    const health = await api("/api/health", { method: "GET" });
    const banner = document.getElementById("health-banner");
    if (health.status && health.status !== "ok") {
      const issues = (health.issues || []).join("; ");
      banner.textContent = `Health: ${health.status}. ${issues}`;
      banner.classList.remove("hidden");
      banner.classList.toggle("error", health.status === "error");
    } else {
      banner.textContent = "";
      banner.classList.add("hidden");
    }
    await checkSessionExpiry();
  } catch (err) {
    setStatus("Error: " + err.message);
  }
}

function setManualTimeDefaults(serverTime) {
  const dateEl = document.getElementById("MANUAL_DATE");
  const timeEl = document.getElementById("MANUAL_CLOCK");
  if (serverTime) {
    const parts = serverTime.split(" ");
    if (parts.length === 2) {
      if (dateEl && !dateEl.value) dateEl.value = parts[0];
      if (timeEl && !timeEl.value) timeEl.value = parts[1];
    }
  }
  if (dateEl && !dateEl.value) {
    const now = new Date();
    const pad = (n) => String(n).padStart(2, "0");
    dateEl.value = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
  }
  if (timeEl && !timeEl.value) {
    const now = new Date();
    const pad = (n) => String(n).padStart(2, "0");
    timeEl.value = `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
  }
  if (dateEl) validateField(dateEl);
  if (timeEl) validateField(timeEl);
}

refreshStatus()
  .then(loadConfig)
  .then(loadLogServices)
  .then(async () => {
    const time = await api("/api/time", { method: "GET" });
    setManualTimeDefaults(time.server_time);
  })
  .catch(err => setStatus("Error: " + err.message));
setInterval(refreshStatus, 10000);

document.querySelectorAll("[data-validate]").forEach(el => {
  el.addEventListener("input", () => validateField(el));
});

const methodEl = document.getElementById("NET_METHOD");
if (methodEl) {
  methodEl.addEventListener("change", () => {
    ["NET_ADDR", "NET_PREFIX", "NET_GW", "NET_DNS"].forEach(id => {
      const el = document.getElementById(id);
      if (el) validateField(el);
    });
  });
}
