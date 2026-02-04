function getCookie(name) {
  const parts = document.cookie.split(";").map(p => p.trim());
  for (const p of parts) {
    if (p.startsWith(name + "=")) {
      return p.split("=", 2)[1];
    }
  }
  return "";
}

async function api(path, options = {}) {
  const csrf = getCookie("csrf");
  const headers = options.headers || {};
  headers["X-CSRF"] = csrf;
  headers["Content-Type"] = "application/json";
  options.headers = headers;
  const res = await fetch(path, options);
  if (!res.ok) {
    const text = await res.text();
    throw new Error(text || res.statusText);
  }
  return res.json();
}

function setStatus(text) {
  const el = document.getElementById("status-line");
  el.textContent = text;
  el.classList.remove("status-ok", "status-warn", "status-error");
  if (text.toLowerCase().startsWith("error")) {
    el.classList.add("status-error");
  } else if (text.toLowerCase().includes("warn")) {
    el.classList.add("status-warn");
  } else {
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
    const ok = /^(\d{1,3}\.){3}\d{1,3}$/.test(value);
    setFieldValidity(el, ok, ok ? "IPv4" : "invalid IPv4");
    return ok;
  }
  if (rule === "ip-optional") {
    const ok = value === "" || /^(\d{1,3}\.){3}\d{1,3}$/.test(value);
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
    const ok = value.split(",").every(v => /^(\d{1,3}\.){3}\d{1,3}$/.test(v.trim()));
    setFieldValidity(el, ok, ok ? "comma-separated IPv4" : "invalid DNS list");
    return ok;
  }
  if (rule === "size") {
    const ok = /^[0-9]+(K|M|G|T)?$/.test(value);
    setFieldValidity(el, ok, ok ? "e.g. 100G, 512M" : "invalid size");
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

async function loadStatus() {
  const data = await api("/api/status", { method: "GET" });
  const services = data.services || {};
  const svcLines = Object.entries(services).map(
    ([name, st]) => `${name}: ${st.active}/${st.sub}`
  );
  document.getElementById("status-services").textContent = svcLines.join("\n");
  document.getElementById("status-usb").textContent = `Active USB LV: ${data.active_usb_lv}`;
  const net = data.network || {};
  const timer = data.sync_timer || {};
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
  const nvmeEl = document.getElementById("status-nvme");
  nvmeEl.textContent = nvmeLine;
  nvmeEl.classList.remove("status-ok", "status-warn", "status-error");
  if (nvmeLine.startsWith("NVMe") && nvmeLine.includes("ERROR")) {
    nvmeEl.classList.add("status-error");
  } else if (nvmeLine.startsWith("NVMe") && nvmeLine.includes("WARN")) {
    nvmeEl.classList.add("status-warn");
  } else if (nvmeLine.startsWith("NVMe")) {
    nvmeEl.classList.add("status-ok");
  }
  setStatus("OK");
}

async function loadConfig() {
  const cfg = await api("/api/config", { method: "GET" });
  fillConfig(cfg);
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

async function saveConfig(apply = false) {
  if (!validateAll()) {
    setStatus("Fix invalid fields before saving");
    return;
  }
  const payload = {
    NETBIOS_NAME: document.getElementById("NETBIOS_NAME").value,
    SMB_WORKGROUP: document.getElementById("SMB_WORKGROUP").value,
    SYNC_INTERVAL_SEC: document.getElementById("SYNC_INTERVAL_SEC").value,
    SYNC_ONBOOT_SEC: document.getElementById("SYNC_ONBOOT_SEC").value,
    SYNC_ONACTIVE_SEC: document.getElementById("SYNC_ONACTIVE_SEC").value,
    BYDATE_USE_FILE_TIME: document.getElementById("BYDATE_USE_FILE_TIME").value,
    RAW_APPEND_ALWAYS: document.getElementById("RAW_APPEND_ALWAYS").value,
    NAS_ENABLED: document.getElementById("NAS_ENABLED").value,
    NAS_REMOTE: document.getElementById("NAS_REMOTE").value,
    NAS_MOUNT: document.getElementById("NAS_MOUNT").value,
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
  const payload = {
    interface: document.getElementById("NET_IFACE").value,
    method: document.getElementById("NET_METHOD").value,
    address: document.getElementById("NET_ADDR").value,
    prefix: document.getElementById("NET_PREFIX").value,
    gateway: document.getElementById("NET_GW").value,
    dns: document.getElementById("NET_DNS").value,
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

async function maintenance(action) {
  let payload = {};
  if (action === "wipe") {
    const ok = prompt('Type "WIPE ALL DATA" to confirm.');
    if (ok !== "WIPE ALL DATA") return;
  }
  if (action === "rebalance") {
    const ok = prompt('Type "REBALANCE" to confirm.');
    if (ok !== "REBALANCE") return;
  }
  if (action === "resize") {
    const ok = prompt('Type "RESIZE" to confirm.');
    if (ok !== "RESIZE") return;
    const sizeField = document.getElementById("RESIZE_SIZE");
    if (!validateField(sizeField)) {
      setStatus("Invalid resize size");
      return;
    }
    payload.size = document.getElementById("RESIZE_SIZE").value;
  }
  if (action === "shutdown") {
    const ok = prompt('Type "SHUTDOWN" to confirm.');
    if (ok !== "SHUTDOWN") return;
  }
  await api(`/api/maintenance/${action}`, { method: "POST", body: JSON.stringify(payload) });
  setStatus(`${action} started`);
}

document.getElementById("save-config").addEventListener("click", () => saveConfig(false));
document.getElementById("apply-config").addEventListener("click", () => saveConfig(true));
document.getElementById("apply-network").addEventListener("click", applyNetwork);
document.getElementById("save-webui-pass").addEventListener("click", changeWebuiPassword);
document.getElementById("save-smb-pass").addEventListener("click", changeSmbPassword);
document.getElementById("wipe").addEventListener("click", () => maintenance("wipe"));
document.getElementById("rebalance").addEventListener("click", () => maintenance("rebalance"));
document.getElementById("resize-usb").addEventListener("click", () => maintenance("resize"));
document.getElementById("shutdown").addEventListener("click", () => maintenance("shutdown"));
document.getElementById("set-time").addEventListener("click", setManualTime);

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
  } catch (err) {
    setStatus("Error: " + err.message);
  }
}

function setManualTimeDefaults() {
  const now = new Date();
  const pad = (n) => String(n).padStart(2, "0");
  const date = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
  const clock = `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
  const dateEl = document.getElementById("MANUAL_DATE");
  const timeEl = document.getElementById("MANUAL_CLOCK");
  if (dateEl && !dateEl.value) dateEl.value = date;
  if (timeEl && !timeEl.value) timeEl.value = clock;
  if (dateEl) validateField(dateEl);
  if (timeEl) validateField(timeEl);
}

refreshStatus()
  .then(loadConfig)
  .then(setManualTimeDefaults)
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
