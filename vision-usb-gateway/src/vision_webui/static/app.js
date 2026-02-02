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
  document.getElementById("status-line").textContent = text;
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
  const timerLine = timer.next_remaining
    ? `Next sync in: ${timer.next_remaining}`
    : "Next sync in: n/a";
  document.getElementById("status-network").textContent =
    `Network: ${net.interface || ""} ${net.address || ""} ${net.gateway || ""}\n${timerLine}`;
  setStatus("OK");
}

async function loadConfig() {
  const cfg = await api("/api/config", { method: "GET" });
  fillConfig(cfg);
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
  const payload = {
    NETBIOS_NAME: document.getElementById("NETBIOS_NAME").value,
    SMB_WORKGROUP: document.getElementById("SMB_WORKGROUP").value,
    SYNC_INTERVAL_SEC: document.getElementById("SYNC_INTERVAL_SEC").value,
    SYNC_ONBOOT_SEC: document.getElementById("SYNC_ONBOOT_SEC").value,
    SYNC_ONACTIVE_SEC: document.getElementById("SYNC_ONACTIVE_SEC").value,
    NAS_ENABLED: document.getElementById("NAS_ENABLED").value,
    NAS_REMOTE: document.getElementById("NAS_REMOTE").value,
    NAS_MOUNT: document.getElementById("NAS_MOUNT").value,
    NAS_CREDENTIALS: document.getElementById("NAS_CREDENTIALS").value,
  };
  await api("/api/config", { method: "POST", body: JSON.stringify(payload) });
  if (apply) await api("/api/apply", { method: "POST", body: "{}" });
  setStatus("Config saved" + (apply ? " and applied" : ""));
}

async function applyNetwork() {
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
  const password = document.getElementById("WEBUI_PASS").value;
  const confirm = document.getElementById("WEBUI_PASS2").value;
  await api("/api/password/webui", { method: "POST", body: JSON.stringify({ password, confirm }) });
  setStatus("Web UI password updated");
}

async function changeSmbPassword() {
  const password = document.getElementById("SMB_PASS").value;
  const confirm = document.getElementById("SMB_PASS2").value;
  await api("/api/password/smb", { method: "POST", body: JSON.stringify({ password, confirm }) });
  setStatus("SMB password updated");
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
    payload.size = document.getElementById("RESIZE_SIZE").value;
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

async function refreshStatus() {
  try {
    await loadStatus();
  } catch (err) {
    setStatus("Error: " + err.message);
  }
}

refreshStatus().then(loadConfig).catch(err => setStatus("Error: " + err.message));
setInterval(refreshStatus, 10000);
