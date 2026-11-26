/* DropDrawer Admin console.
 *
 * Rendering rule: every node is built with DOM APIs (h()) and text goes through
 * textContent. Nothing here uses innerHTML, so user-controlled values (names,
 * emails, file names) can never be parsed as markup. The server's CSP forbids
 * inline script as a second line of defence.
 */
"use strict";
(() => {
  // ---------------------------------------------------------------------------
  // DOM helpers
  // ---------------------------------------------------------------------------
  const $ = (id) => document.getElementById(id);

  function h(tag, props, ...children) {
    const el = document.createElement(tag);
    if (props) {
      for (const [key, value] of Object.entries(props)) {
        if (value === undefined || value === null || value === false) continue;
        if (key === "class") el.className = value;
        else if (key === "text") el.textContent = value;
        else if (key === "dataset") Object.assign(el.dataset, value);
        else if (key.startsWith("on") && typeof value === "function") el.addEventListener(key.slice(2), value);
        else if (key === "value") el.value = value;
        else if (key === "checked" || key === "disabled" || key === "selected") el[key] = Boolean(value);
        else el.setAttribute(key, value === true ? "" : String(value));
      }
    }
    append(el, children);
    return el;
  }

  function append(el, children) {
    for (const child of children) {
      if (child === null || child === undefined || child === false) continue;
      if (Array.isArray(child)) append(el, child);
      else el.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
  }

  const SVG_NS = "http://www.w3.org/2000/svg";
  function icon(name, cls) {
    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("class", "icon" + (cls ? " " + cls : ""));
    svg.setAttribute("aria-hidden", "true");
    const use = document.createElementNS(SVG_NS, "use");
    use.setAttribute("href", "#i-" + name);
    svg.append(use);
    return svg;
  }

  function replace(el, ...children) {
    el.replaceChildren();
    append(el, children);
  }

  // ---------------------------------------------------------------------------
  // Formatting
  // ---------------------------------------------------------------------------
  const nf = new Intl.NumberFormat("zh-CN");
  const fmtNum = (n) => nf.format(Number(n || 0));

  function fmtBytes(b) {
    b = Number(b || 0);
    if (b < 1024) return b + " B";
    const units = ["KB", "MB", "GB", "TB"];
    let v = b / 1024;
    let i = 0;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    return (v >= 100 ? v.toFixed(0) : v.toFixed(1)) + " " + units[i];
  }

  function fmtDate(iso) {
    if (!iso) return "—";
    const d = new Date(iso);
    if (isNaN(d.getTime())) return String(iso);
    const p = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  function fmtRel(iso) {
    if (!iso) return "—";
    const t = new Date(iso).getTime();
    if (isNaN(t)) return String(iso);
    const diff = (t - Date.now()) / 1000;
    const abs = Math.abs(diff);
    const suffix = diff < 0 ? "前" : "后";
    if (abs < 45) return diff < 0 ? "刚刚" : "即将";
    if (abs < 3600) return Math.round(abs / 60) + " 分钟" + suffix;
    if (abs < 86400) return Math.round(abs / 3600) + " 小时" + suffix;
    if (abs < 86400 * 30) return Math.round(abs / 86400) + " 天" + suffix;
    return fmtDate(iso);
  }

  function fmtDuration(secs) {
    secs = Math.max(0, Math.floor(secs || 0));
    const d = Math.floor(secs / 86400);
    const hh = Math.floor((secs % 86400) / 3600);
    const mm = Math.floor((secs % 3600) / 60);
    if (d > 0) return `${d} 天 ${hh} 小时`;
    if (hh > 0) return `${hh} 小时 ${mm} 分钟`;
    return `${mm} 分钟`;
  }

  function fmtHours(h) {
    if (!h) return "不限";
    if (h % 24 === 0) return h / 24 + " 天";
    return h + " 小时";
  }

  const initials = (name) => (String(name || "?").trim()[0] || "?").toUpperCase();

  const KIND_LABELS = {
    local: "服务器本地",
    google_drive: "Google Drive",
    quark: "夸克网盘",
    baidu_netdisk: "百度网盘",
    web_dav: "WebDAV",
    s3: "S3 兼容存储",
  };
  const KIND_DESC = {
    local: "文件存放在本服务器磁盘，受配额限制",
    google_drive: "用户授权自己的 Google Drive",
    quark: "使用夸克网盘 Cookie 接入",
    baidu_netdisk: "百度网盘开放平台 OAuth",
    web_dav: "任意 WebDAV 服务（NAS、Nextcloud 等）",
    s3: "AWS S3、Cloudflare R2、MinIO、阿里云 OSS 等",
  };
  const PLATFORM_LABELS = { macos: "macOS", windows: "Windows", linux: "Linux", android: "Android", ios: "iOS", web: "Web" };
  const MODE_LABELS = { p2p_only: "仅 P2P", cloud_cached: "云端缓存", server_relay: "服务器中转" };

  const AUDIT_LABELS = {
    "admin.login": "管理员登录",
    "admin.login_failed": "管理员登录失败",
    "admin.logout": "退出管理端",
    "settings.update": "修改服务器设置",
    "smtp.test": "发送测试邮件",
    "user.disable": "禁用账号",
    "user.enable": "解封账号",
    "user.reset_password": "重置密码",
    "user.sign_out": "强制下线",
    "user.policy": "修改用户策略",
    "user.delete": "删除账号",
    "user.revoke_shares": "吊销用户全部外链",
    "device.remove": "移除设备",
    "backend.remove": "移除存储",
    "item.remove": "删除抽屉条目",
    "invite.create": "生成邀请码",
    "invite.delete": "删除邀请码",
    "share.revoke": "吊销外链",
    "maintenance.cleanup": "清理过期条目",
    "maintenance.backup": "下载数据库备份",
    "admin.change_password": "修改自己的密码",
    "admin.totp_enable": "开启两步验证",
    "admin.totp_disable": "关闭两步验证",
    "admin_account.create": "创建管理员",
    "admin_account.update": "修改管理员",
    "admin_account.reset_password": "重置管理员密码",
    "admin_account.reset_totp": "重置管理员两步验证",
    "admin_account.delete": "删除管理员",
  };
  const SETTING_LABELS = {
    registration_mode: "注册模式",
    password_login_enabled: "密码登录",
    email_verification_required: "邮箱验证",
    email_allowed_domains: "域名白名单",
    email_blocked_domains: "域名黑名单",
    local_max_file_bytes: "单文件上限",
    default_user_local_quota_bytes: "默认配额",
    google: "Google 登录",
    smtp: "SMTP",
    features: "功能开关",
    share_policy: "外链策略",
    storage_policy: "存储策略",
    limits: "用量限制",
    announcement: "全站公告",
    client_policy: "客户端版本",
    "google.client_secret": "Google 密钥",
    "smtp.password": "SMTP 密码",
  };
  const auditDangerous = (a) => /failed|delete|disable|remove|revoke/.test(a);

  function auditDetail(entry) {
    if (!entry.detail) return "";
    if (entry.action === "settings.update") {
      return entry.detail.split(",").map((k) => SETTING_LABELS[k] || k).join("、");
    }
    return entry.detail;
  }

  // ---------------------------------------------------------------------------
  // API
  // ---------------------------------------------------------------------------
  class ApiError extends Error {
    constructor(status, message) { super(message); this.status = status; }
  }

  async function api(path, { method = "GET", body } = {}) {
    const opts = { method, credentials: "same-origin", headers: {} };
    if (body !== undefined) {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    const resp = await fetch(path, opts);
    const text = await resp.text();
    if (resp.status === 401 && !path.endsWith("/login") && !path.endsWith("/session")) {
      showLogin("登录已过期，请重新输入管理员密钥");
      throw new ApiError(401, "管理员会话已失效");
    }
    if (!resp.ok) throw new ApiError(resp.status, text || resp.statusText);
    if (!text) return null;
    try { return JSON.parse(text); } catch { return text; }
  }

  async function run(button, task, okMessage) {
    if (button) button.classList.add("busy");
    try {
      const result = await task();
      if (okMessage) toast(okMessage);
      return result;
    } catch (err) {
      if (err.status !== 401) toast(err.message || String(err), "err");
      return undefined;
    } finally {
      if (button) button.classList.remove("busy");
    }
  }

  // ---------------------------------------------------------------------------
  // UI primitives
  // ---------------------------------------------------------------------------
  function toast(message, kind = "ok") {
    const el = h("div", { class: "toast " + kind, role: kind === "err" ? "alert" : "status" },
      icon(kind === "err" ? "alert" : "check"), h("span", { text: message }));
    $("toasts").append(el);
    setTimeout(() => {
      el.classList.add("leaving");
      setTimeout(() => el.remove(), 220);
    }, kind === "err" ? 5200 : 3200);
  }

  function pill(text, kind, withDot = true) {
    return h("span", { class: "pill" + (kind ? " " + kind : "") }, withDot ? h("span", { class: "dot" }) : null, text);
  }

  function btn(label, { kind, size, iconName, onclick, title, disabled, type } = {}) {
    const cls = ["btn", kind, size, label ? null : "icon-only"].filter(Boolean).join(" ");
    return h("button", { class: cls, type: type || "button", onclick, title, "aria-label": title || null, disabled },
      iconName ? icon(iconName) : null, label ? h("span", { text: label }) : null);
  }

  function switchEl({ id, checked, disabled, onchange, label }) {
    const input = h("input", { type: "checkbox", role: "switch", id, checked, disabled, "aria-label": label || null });
    input.addEventListener("change", () => onchange(input.checked));
    return h("label", { class: "switch" }, input, h("span", { class: "track" }), h("span", { class: "thumb" }));
  }

  function row({ title, desc, control, badges, disabled, cls }) {
    return h("div", { class: "row" + (disabled ? " disabled" : "") + (cls ? " " + cls : "") },
      h("div", null,
        h("div", { class: "row-title" }, title, badges || null),
        desc ? h("div", { class: "row-desc" }, desc) : null),
      control ? h("div", { class: "row-control" }, control) : null);
  }

  function callout(kind, text) {
    return h("div", { class: "callout " + (kind || "") }, icon(kind ? "alert" : "info"), h("div", null, text));
  }

  function empty(iconName, text) {
    return h("div", { class: "empty" }, icon(iconName), text);
  }

  function searchBox(placeholder, value, oninput, id) {
    const input = h("input", { class: "input search", type: "search", placeholder, value, id, "aria-label": placeholder });
    input.addEventListener("input", () => oninput(input.value));
    return h("div", { class: "search-wrap" }, icon("search"), input);
  }

  function segmented(options, active, onchange) {
    return h("div", { class: "segmented", role: "tablist" },
      options.map(([value, label]) => h("button", {
        type: "button",
        role: "tab",
        class: value === active ? "active" : null,
        "aria-selected": value === active ? "true" : "false",
        onclick: () => onchange(value),
      }, label)));
  }

  function table(columns, rows, { onRowClick, emptyIcon = "search", emptyText = "暂无数据" } = {}) {
    if (!rows.length) return h("div", { class: "table-card" }, empty(emptyIcon, emptyText));
    return h("div", { class: "table-card" }, h("div", { class: "table-scroll" },
      h("table", { class: "table" },
        h("thead", null, h("tr", null, columns.map((c) => h("th", { class: c.cls || null }, c.label)))),
        h("tbody", null, rows.map((r) => {
          const tr = h("tr", { class: onRowClick ? "clickable" : null },
            columns.map((c) => h("td", { class: c.cls || null }, c.render(r))));
          if (onRowClick) {
            tr.tabIndex = 0;
            tr.addEventListener("click", (e) => { if (!e.target.closest("button, a")) onRowClick(r); });
            tr.addEventListener("keydown", (e) => { if (e.key === "Enter") onRowClick(r); });
          }
          return tr;
        })))));
  }

  // Overlays ------------------------------------------------------------------
  let overlayStack = [];

  function pushOverlay(node, onClose) {
    const entry = { node, onClose, previousFocus: document.activeElement };
    overlayStack.push(entry);
    $("overlayRoot").append(node);
    return () => closeOverlay(entry);
  }

  function closeOverlay(entry) {
    const idx = overlayStack.indexOf(entry);
    if (idx === -1) return;
    overlayStack.splice(idx, 1);
    entry.node.remove();
    if (entry.onClose) entry.onClose();
    if (entry.previousFocus && entry.previousFocus.focus) entry.previousFocus.focus();
  }

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && overlayStack.length) closeOverlay(overlayStack[overlayStack.length - 1]);
  });

  function dialog({ title, body, actions }) {
    return new Promise((resolve) => {
      let close;
      let result;
      const finish = (value) => { result = value; close(); };
      const node = h("div", { class: "dialog-wrap" },
        h("div", { class: "scrim", onclick: () => finish(undefined) }),
        h("div", { class: "dialog", role: "dialog", "aria-modal": "true", "aria-label": title },
          h("h3", { text: title }),
          h("div", { class: "dialog-body" }, body),
          h("div", { class: "dialog-actions" }, actions.map((a) =>
            btn(a.label, { kind: a.kind, onclick: () => finish(a.value) })))));
      close = pushOverlay(node, () => resolve(result));
      const focusTarget = node.querySelector("input, textarea") || node.querySelector(".dialog-actions .btn:last-child");
      if (focusTarget) setTimeout(() => focusTarget.focus(), 20);
    });
  }

  async function confirmDialog(title, message, { confirmText = "确认", danger = false } = {}) {
    const result = await dialog({
      title,
      body: h("p", { text: message }),
      actions: [{ label: "取消", value: false, kind: "ghost" }, { label: confirmText, value: true, kind: danger ? "danger" : "primary" }],
    });
    return result === true;
  }

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  const S = {
    page: "overview",
    settings: null,
    draft: null,
    secrets: { google: "", smtp: "" },
    overview: null,
    system: null,
    users: [],
    invites: [],
    shares: [],
    audit: [],
    userQuery: "",
    userFilter: "all",
    shareQuery: "",
    shareFilter: "all",
    auditQuery: "",
    testEmailTo: "",
    inviteForm: { note: "", max_uses: 1, expires_hours: 168 },
    session: null,
    clients: [],
    admins: [],
    adminForm: { username: "", password: "", role: "admin" },
  };

  const clone = (v) => JSON.parse(JSON.stringify(v));
  const getPath = (obj, path) => path.split(".").reduce((o, k) => (o == null ? undefined : o[k]), obj);
  function setPath(obj, path, value) {
    const keys = path.split(".");
    const last = keys.pop();
    const target = keys.reduce((o, k) => o[k], obj);
    target[last] = value;
  }

  function isDirty() {
    if (!S.draft || !S.settings) return false;
    return S.secrets.google !== "" || S.secrets.smtp !== "" || JSON.stringify(S.draft) !== JSON.stringify(S.settings);
  }

  function updateSavebar() {
    $("savebar").classList.toggle("show", isDirty());
  }

  /** Update a draft setting. Re-render when other controls depend on it. */
  function setDraft(path, value, { rerender = false } = {}) {
    setPath(S.draft, path, value);
    updateSavebar();
    if (rerender) renderPage({ keepScroll: true });
  }

  window.addEventListener("beforeunload", (e) => {
    if (isDirty()) { e.preventDefault(); e.returnValue = ""; }
  });

  function buildSettingsPayload() {
    const d = S.draft;
    return {
      registration_mode: d.registration_mode,
      password_login_enabled: d.password_login_enabled,
      email_verification_required: d.email_verification_required,
      email_allowed_domains: d.email_allowed_domains,
      email_blocked_domains: d.email_blocked_domains,
      local_max_file_bytes: d.local_max_file_bytes,
      default_user_local_quota_bytes: d.default_user_local_quota_bytes,
      google: {
        enabled: d.google.enabled,
        client_id: d.google.client_id,
        client_secret: S.secrets.google || null,
        redirect_uri: d.google.redirect_uri,
      },
      smtp: {
        enabled: d.smtp.enabled,
        host: d.smtp.host,
        port: Number(d.smtp.port) || 587,
        security: d.smtp.security,
        username: d.smtp.username,
        password: S.secrets.smtp || null,
        from_address: d.smtp.from_address,
        from_name: d.smtp.from_name,
      },
      features: d.features,
      share_policy: d.share_policy,
      storage_policy: d.storage_policy,
      limits: d.limits,
      announcement: d.announcement,
      client_policy: d.client_policy,
    };
  }

  function acceptSettings(settings) {
    S.settings = settings;
    S.draft = clone(settings);
    S.secrets = { google: "", smtp: "" };
    updateSavebar();
  }

  async function saveSettings() {
    const button = $("saveBtn");
    const saved = await run(button, () => api("/api/admin/settings", { method: "PUT", body: buildSettingsPayload() }), "设置已保存并立即生效");
    if (saved) {
      acceptSettings(saved);
      renderNav();
      renderPage({ keepScroll: true });
      loadOverview();
      loadAudit();
    }
  }

  function discardSettings() {
    acceptSettings(S.settings);
    renderPage({ keepScroll: true });
    toast("已放弃未保存的更改");
  }

  $("saveBtn").addEventListener("click", saveSettings);
  $("discardBtn").addEventListener("click", discardSettings);

  // Draft-bound controls ---------------------------------------------------------
  function draftSwitch(path, { id, disabled, rerender, label, invert } = {}) {
    const value = Boolean(getPath(S.draft, path));
    return switchEl({
      id: id || "sw-" + path.replace(/\./g, "-"),
      checked: invert ? !value : value,
      disabled,
      label,
      onchange: (v) => setDraft(path, invert ? !v : v, { rerender }),
    });
  }

  function draftText(path, { placeholder, type = "text", autocomplete } = {}) {
    const input = h("input", { class: "input", type, placeholder, value: getPath(S.draft, path) ?? "", id: "tx-" + path.replace(/\./g, "-"), autocomplete: autocomplete || "off" });
    input.addEventListener("input", () => setDraft(path, input.value.trim()));
    return input;
  }

  function secretInput(key, saved, placeholder) {
    const input = h("input", {
      class: "input",
      type: "password",
      value: S.secrets[key],
      autocomplete: "new-password",
      placeholder: saved ? "已保存 · 留空表示不修改" : placeholder,
      id: "secret-" + key,
    });
    input.addEventListener("input", () => { S.secrets[key] = input.value; updateSavebar(); });
    return input;
  }

  /** Numeric input bound to a draft path. `scale` converts display units to stored units. */
  function draftNumber(path, { unit, scale = 1, placeholder = "不限", min = 0, step = "any" } = {}) {
    const stored = getPath(S.draft, path);
    const shown = stored == null ? "" : String(Math.round((stored / scale) * 100) / 100);
    const input = h("input", { class: "input", type: "number", min, step, inputmode: "decimal", placeholder, value: shown, id: "num-" + path.replace(/\./g, "-") });
    input.addEventListener("input", () => {
      const v = parseFloat(input.value);
      setDraft(path, Number.isFinite(v) && v > 0 ? Math.round(v * scale) : null);
    });
    return h("div", { class: "input-unit" }, input, unit ? h("span", { text: unit }) : null);
  }

  function field(label, control, extra) {
    return h("div", { class: "field" }, h("label", null, label, extra || null), control);
  }

  // ---------------------------------------------------------------------------
  // Pages
  // ---------------------------------------------------------------------------
  const PAGES = {
    overview: { group: null, label: "总览", icon: "overview", title: "总览", desc: "服务器运行状态与关键指标", render: renderOverview },
    access: { group: "配置", label: "注册与登录", icon: "key", title: "注册与登录", desc: "控制谁能注册、用什么方式登录，修改保存后立即对所有客户端生效", render: renderAccess, settings: true },
    features: { group: "配置", label: "功能与限额", icon: "sliders", title: "功能与限额", desc: "开关服务器功能、限制存储类型并设置每个用户的用量上限", render: renderFeatures, settings: true },
    mail: { group: "配置", label: "邮件服务", icon: "mail", title: "邮件服务", desc: "SMTP 发信用于注册验证码与找回密码", render: renderMail, settings: true },
    users: { group: "管理", label: "用户", icon: "users", title: "用户", desc: "账号状态、会话、设备、存储与个人策略", render: renderUsers, count: () => S.users.length },
    shares: { group: "管理", label: "公网外链", icon: "link", title: "公网外链", desc: "审查全站外链并一键吊销", render: renderShares, count: () => S.shares.length },
    clients: { group: "配置", label: "客户端与公告", icon: "megaphone", title: "客户端与公告", desc: "向所有客户端发布公告，查看版本分布并设置最低版本", render: renderClients, settings: true },
    audit: { group: "管理", label: "审计日志", icon: "log", title: "审计日志", desc: "管理员的每一次操作都会记录在这里（保留最近 5000 条）", render: renderAudit },
    admins: { group: "管理", label: "管理员", icon: "badge", title: "管理员", desc: "创建管理员账号、分配角色，并查看两步验证状态", render: renderAdmins, superOnly: true },
    me: { group: null, hidden: true, label: "我的账号", icon: "badge", title: "我的账号", desc: "修改密码与两步验证", render: renderMe },
  };
  // Keep the sidebar grouped: configuration pages first, then management.
  const NAV_ORDER = ["overview", "access", "features", "mail", "clients", "users", "shares", "admins", "audit"];

  const isSuper = () => S.session && S.session.role === "super";
  const isReadonly = () => S.session && S.session.role === "viewer";
  const ROLE_LABELS = { super: "超级管理员", admin: "管理员", viewer: "只读" };

  function renderNav() {
    const nav = $("nav");
    const items = [];
    let lastGroup = null;
    for (const key of NAV_ORDER) {
      const page = PAGES[key];
      if (page.superOnly && !isSuper()) continue;
      if (page.group !== lastGroup && page.group) items.push(h("div", { class: "nav-label", text: page.group }));
      lastGroup = page.group;
      const count = page.count ? page.count() : null;
      items.push(h("a", {
        class: "nav-item" + (S.page === key ? " active" : ""),
        href: "#/" + key,
        "aria-current": S.page === key ? "page" : null,
      }, icon(page.icon), h("span", { text: page.label }), count != null ? h("span", { class: "count", text: fmtNum(count) }) : null));
    }
    replace(nav, items);
    if (S.session) {
      $("meName").textContent = S.session.is_owner ? "密钥登录" : S.session.actor;
      $("meRole").textContent = (ROLE_LABELS[S.session.role] || S.session.role) + (S.session.totp_enabled ? " · 两步验证" : "");
      $("meAvatar").textContent = S.session.is_owner ? "K" : initials(S.session.actor);
      $("meLink").classList.toggle("active", S.page === "me");
    }
    if (S.system) {
      replace($("serverChip"), h("span", { class: "dot ok" }), h("span", { text: `v${S.system.version} · 已运行 ${fmtDuration(S.system.uptime_secs)}` }));
    }
  }

  function renderPage({ keepScroll = false } = {}) {
    const page = PAGES[S.page] || PAGES.overview;
    const focusedId = document.activeElement && document.activeElement.id;
    const scrollY = window.scrollY;
    document.body.dataset.page = S.page;
    $("pageTitle").textContent = page.title;
    $("pageDesc").textContent = page.desc;
    document.title = page.title + " · DropDrawer Admin";
    replace($("pageActions"));
    const node = page.render();
    if (isReadonly() && S.page !== "me") {
      node.prepend(h("div", { class: "callout readonly-banner" }, icon("eye"), h("div", { text: "你是只读管理员：可以查看所有数据，但不能修改设置或执行管理操作。" })));
    }
    if (keepScroll) node.style.animation = "none";
    replace($("pageRoot"), node);
    if (keepScroll) window.scrollTo(0, scrollY);
    if (focusedId) {
      const el = document.getElementById(focusedId);
      if (el && el.focus) el.focus({ preventScroll: true });
    }
  }

  function setActions(...nodes) {
    replace($("pageActions"), nodes);
  }

  // Refetch the data a page shows whenever it is opened, so it never goes stale.
  const PAGE_LOADERS = {
    overview: () => loadOverview(),
    users: () => refreshUsers(),
    shares: () => loadShares(),
    audit: () => loadAudit(),
    clients: () => loadClients(),
    admins: () => loadAdmins(),
    me: () => loadSession(),
  };
  let booted = false;

  function navigate() {
    const key = (location.hash.replace(/^#\/?/, "") || "overview").split("?")[0];
    S.page = PAGES[key] && !(PAGES[key].superOnly && !isSuper()) ? key : "overview";
    renderNav();
    renderPage();
    window.scrollTo(0, 0);
    if (booted && PAGE_LOADERS[S.page]) PAGE_LOADERS[S.page]();
  }

  async function loadOverview() {
    const results = await run(null, () => Promise.all([api("/api/admin/overview"), api("/api/admin/system")]));
    if (!results) return;
    [S.overview, S.system] = results;
    renderNav();
    if (S.page === "overview") renderPage({ keepScroll: true });
  }
  window.addEventListener("hashchange", navigate);

  // Overview ---------------------------------------------------------------------
  function renderOverview() {
    setActions(btn("刷新", { iconName: "refresh", onclick: (e) => refreshAll(e.currentTarget, true) }));
    const o = S.overview;
    const sys = S.system;
    const st = S.settings;
    if (!o || !st) return h("div", { class: "page" }, h("div", { class: "skeleton" }));

    const kpi = (iconName, label, value, unit, sub) => h("div", { class: "kpi" },
      h("div", { class: "kpi-label" }, icon(iconName), label),
      h("div", { class: "kpi-value" }, value, unit ? h("small", { text: unit }) : null),
      h("div", { class: "kpi-sub", text: sub }));

    const kpis = h("div", { class: "kpis" },
      kpi("users", "注册用户", fmtNum(o.total_users), null,
        `近 7 天新增 ${fmtNum(o.new_users_7d)}` + (o.disabled_users ? ` · 已禁用 ${fmtNum(o.disabled_users)}` : "")),
      kpi("monitor", "在线用户", fmtNum(o.online_users), null, `${fmtNum(o.online_connections)} 个连接 · 登记设备 ${fmtNum(o.total_devices)} 台`),
      kpi("file", "抽屉条目", fmtNum(o.total_items), null, `共 ${fmtBytes(o.total_item_bytes)} · 云端 ${fmtBytes(o.cloud_item_bytes)}`),
      kpi("link", "公网外链", fmtNum(o.total_shares), null, `累计下载 ${fmtNum(o.total_share_downloads)} 次`),
      kpi("database", "存储后端", fmtNum(o.total_backends), null, `24 小时内到期 ${fmtNum(o.items_expiring_24h)} 项`));

    const regLabel = { open: "开放注册", invite_only: "仅限邀请码", closed: "已关闭" }[st.registration_mode];
    const policy = (label, value, state, page) => h("button", { class: "policy-item", type: "button", onclick: () => { location.hash = "#/" + page; } },
      h("span", { class: "dot " + state }), h("span", { class: "label", text: label }), h("span", { class: "value", text: value }), icon("arrow-right", "faint"));
    const f = st.features;
    const policies = h("div", { class: "card" },
      h("div", { class: "card-head" }, h("div", null, h("h2", { text: "当前生效的策略" }), h("p", { text: "客户端通过 /api/auth/config 实时读取" }))),
      h("div", { class: "policy-list" },
        policy("新用户注册", regLabel, st.registration_mode === "closed" ? "danger" : st.registration_mode === "invite_only" ? "warn" : "ok", "access"),
        policy("账号密码登录", st.password_login_enabled ? "开启" : "关闭", st.password_login_enabled ? "ok" : "", "access"),
        policy("Google 登录", st.google.enabled ? (f.google_signup_enabled ? "开启 · 允许自动建号" : "开启 · 仅已有账号") : "未启用", st.google.enabled ? "accent" : "", "access"),
        policy("邮箱找回密码", f.password_reset_enabled ? (sys && sys.smtp_ready ? "开启" : "开启 · SMTP 未就绪") : "关闭", f.password_reset_enabled && sys && sys.smtp_ready ? "ok" : f.password_reset_enabled ? "warn" : "", "access"),
        policy("云端中转上传", f.cloud_upload_enabled ? "开启" : "关闭（仅 P2P）", f.cloud_upload_enabled ? "ok" : "warn", "features"),
        policy("公网外链", !f.share_access_enabled ? "访问已暂停" : f.share_create_enabled ? "开启" : "禁止新建", !f.share_access_enabled ? "danger" : f.share_create_enabled ? "ok" : "warn", "features"),
        policy("存储类型", st.storage_policy.disabled_backend_kinds.length ? `已停用 ${st.storage_policy.disabled_backend_kinds.length} 种` : "全部可用", st.storage_policy.disabled_backend_kinds.length ? "warn" : "ok", "features"),
        policy("内网地址拦截", st.storage_policy.block_private_endpoints ? "开启" : "关闭", st.storage_policy.block_private_endpoints ? "ok" : "", "features")));

    const total = o.backend_kinds.reduce((s, k) => s + k.count, 0);
    const maxCount = Math.max(1, ...o.backend_kinds.map((k) => k.count));
    const kinds = h("div", { class: "card" },
      h("div", { class: "card-head" }, h("div", null, h("h2", { text: "存储类型分布" }), h("p", { text: "按后端数量统计，悬停查看占比" }))),
      o.backend_kinds.length
        ? h("div", { class: "bars", role: "list" }, o.backend_kinds.map((k) => {
          const pct = Math.round((k.count / total) * 100);
          const fill = h("div", { class: "bar-fill" });
          fill.style.width = Math.max(3, (k.count / maxCount) * 100) + "%";
          return h("div", { class: "bar-row", role: "listitem", title: `${KIND_LABELS[k.kind] || k.kind}：${k.count} 个后端（${pct}%）` },
            h("span", { class: "name", text: KIND_LABELS[k.kind] || k.kind }),
            h("div", { class: "bar-track" }, fill),
            h("span", { class: "val", text: fmtNum(k.count) }));
        }))
        : empty("database", "还没有用户添加存储后端"));

    const sysCard = h("div", { class: "card" },
      h("div", { class: "card-head" }, h("div", null, h("h2", { text: "系统" }))),
      sys ? h("dl", { class: "kv" },
        h("dt", { text: "版本" }), h("dd", { text: `v${sys.version}` }),
        h("dt", { text: "平台" }), h("dd", { text: `${sys.os} / ${sys.arch}` }),
        h("dt", { text: "已运行" }), h("dd", { text: fmtDuration(sys.uptime_secs) }),
        h("dt", { text: "数据库" }), h("dd", { text: fmtBytes(sys.database_bytes) }),
        h("dt", { text: "本地存储" }), h("dd", { text: sys.local_storage_bytes == null ? "文件过多，未统计" : `${fmtBytes(sys.local_storage_bytes)} · ${fmtNum(sys.local_storage_files)} 个文件` }),
        h("dt", { text: "存储目录" }), h("dd", { class: "mono", text: sys.local_storage_dir }),
        h("dt", { text: "SMTP" }), h("dd", null, sys.smtp_ready ? pill("就绪", "ok") : pill("未配置")),
        h("dt", { text: "管理员密钥" }), h("dd", null, sys.admin_token_hashed ? pill("Argon2 哈希", "ok") : pill("明文", "warn")))
        : h("div", { class: "skeleton" }),
      sys && !sys.admin_token_hashed
        ? h("div", { class: "callout warn" }, icon("alert"), h("div", null, "管理员密钥以明文配置。建议改为 Argon2 哈希（",
          h("code", { text: "echo -n '密钥' | argon2 \"$(openssl rand -base64 16)\" -e -id" }), "）后填入 DROPDRAWER_ADMIN_TOKEN。"))
        : null);
    if (sys && !sys.admin_token_hashed) sysCard.lastChild.style.marginTop = "14px";

    const recent = h("div", { class: "card" },
      h("div", { class: "card-head" },
        h("div", null, h("h2", { text: "最近操作" })),
        h("a", { class: "btn ghost sm", href: "#/audit" }, "全部", icon("arrow-right"))),
      o.recent_audit.length
        ? h("div", { class: "timeline" }, o.recent_audit.map((e) => h("div", { class: "timeline-item" },
          h("span", { class: "dot " + (auditDangerous(e.action) ? "danger" : "accent") }),
          h("div", { class: "what" }, h("b", { text: AUDIT_LABELS[e.action] || e.action }), e.target ? h("span", { text: " · " + e.target }) : null),
          h("span", { class: "when", title: fmtDate(e.at), text: fmtRel(e.at) }))))
        : empty("log", "暂无操作记录"));

    const maintenance = h("div", { class: "card" },
      h("div", { class: "card-head" }, h("div", null, h("h2", { text: "维护" }), h("p", { text: "过期条目会按服务端的清理周期自动删除，也可以现在执行一次" }))),
      btn("立即清理过期条目", {
        iconName: "broom",
        onclick: async (e) => {
          const r = await run(e.currentTarget, () => api("/api/admin/maintenance/cleanup", { method: "POST" }));
          if (r) { toast(r.cleaned ? `已清理 ${r.cleaned} 个过期条目` : "没有需要清理的过期条目"); refreshAll(); }
        },
      }),
      isSuper() ? h("div", { class: "toolbar" },
        h("a", { class: "btn", href: "/api/admin/maintenance/backup", download: "" }, icon("download"), "下载数据库备份"),
        h("span", { class: "meta", text: "包含账号与存储凭据，请妥善保管；不含文件本体" })) : null);
    maintenance.lastChild && maintenance.lastChild.classList && maintenance.lastChild.classList.contains("toolbar") && (maintenance.lastChild.style.marginTop = "12px");

    return h("div", { class: "page" },
      kpis,
      h("div", { class: "grid-3" }, policies, h("div", { class: "page" }, kinds, maintenance)),
      h("div", { class: "grid-3" }, recent, sysCard));
  }

  // Registration & sign-in -------------------------------------------------------
  function renderAccess() {
    const d = S.draft;
    if (!d) return h("div", { class: "page" });
    const regOpen = d.registration_mode !== "closed";
    const smtpReady = S.system ? S.system.smtp_ready : d.smtp.enabled;

    const setReg = (open, invite) => setDraft("registration_mode", !open ? "closed" : invite ? "invite_only" : "open", { rerender: true });

    const registration = h("div", { class: "group" },
      row({
        title: "允许新用户注册",
        desc: "关闭后注册入口从所有客户端隐藏，已有账号不受影响。",
        control: switchEl({ id: "reg-open", checked: regOpen, label: "允许新用户注册", onchange: (v) => setReg(v, d.registration_mode === "invite_only") }),
      }),
      row({
        title: "需要邀请码",
        desc: "注册时必须填写下方生成的有效邀请码。",
        disabled: !regOpen,
        control: switchEl({ id: "reg-invite", checked: d.registration_mode === "invite_only", disabled: !regOpen, label: "需要邀请码", onchange: (v) => setReg(true, v) }),
      }),
      row({
        title: "注册必须验证邮箱",
        desc: "注册时发送 6 位验证码到邮箱，需要先配置邮件服务。",
        badges: !smtpReady ? pill("SMTP 未就绪", "warn") : null,
        control: draftSwitch("email_verification_required", { label: "注册必须验证邮箱" }),
      }),
      h("div", { class: "row stack" },
        h("div", { class: "fields" },
          field("允许的邮箱域名（留空不限）", domainArea("email_allowed_domains", "company.com, edu.cn")),
          field("禁止的邮箱域名", domainArea("email_blocked_domains", "tempmail.com")))));

    const google = d.google;
    const login = h("div", { class: "group" },
      row({ title: "账号密码登录", desc: "关闭后只能使用 Google 等第三方方式登录，至少要保留一种登录方式。", control: draftSwitch("password_login_enabled", { label: "账号密码登录" }) }),
      row({ title: "邮箱找回密码", desc: "允许用户通过邮箱验证码自助重置密码，重置后该账号的其他会话会全部下线。", badges: !smtpReady ? pill("SMTP 未就绪", "warn") : null, control: draftSwitch("features.password_reset_enabled", { label: "邮箱找回密码" }) }),
      row({ title: "Google 登录", desc: "客户端登录页显示「使用 Google 登录」。", control: draftSwitch("google.enabled", { rerender: true, label: "Google 登录" }) }),
      google.enabled ? h("div", { class: "row stack sub" },
        h("div", { class: "fields" },
          field("Client ID", draftText("google.client_id", { placeholder: "xxxx.apps.googleusercontent.com" })),
          field("Client Secret", secretInput("google", google.has_client_secret, "GOCSPX-…"), google.has_client_secret ? pill("已保存", "ok") : null)),
        field("Redirect URI（需以 /api/auth/google/callback 结尾）", draftText("google.redirect_uri", { placeholder: "https://drop.example.com/api/auth/google/callback" }))) : null,
      row({
        title: "Google 首次登录自动创建账号",
        desc: "关闭后只有已绑定 Google 的账号能登录。自动建号同样受注册开关与邮箱域名规则约束。",
        disabled: !google.enabled,
        control: draftSwitch("features.google_signup_enabled", { disabled: !google.enabled, label: "Google 自动创建账号" }),
      }));

    return h("div", { class: "page" },
      sectionTitle("新用户注册"), registration,
      sectionTitle("登录方式"), login,
      sectionTitle("邀请码", "注册需要邀请码时使用；可设置使用次数与有效期"), renderInvites());
  }

  function sectionTitle(title, desc) {
    return h("div", { class: "section-title" }, h("h2", { text: title }), desc ? h("p", { text: desc }) : null);
  }

  function domainArea(path, placeholder) {
    const area = h("textarea", { class: "textarea", placeholder, id: "ta-" + path, rows: 2 });
    area.value = (getPath(S.draft, path) || []).join(", ");
    area.addEventListener("input", () => {
      const list = [...new Set(area.value.split(/[\s,;]+/).map((s) => s.trim().replace(/^@/, "").toLowerCase()).filter(Boolean))];
      setDraft(path, list);
    });
    return area;
  }

  function inviteStatus(inv) {
    if (inv.expires_at && new Date(inv.expires_at) <= new Date()) return pill("已过期", "danger");
    if (inv.used_count >= inv.max_uses) return pill("已用完");
    return pill("可用", "ok");
  }

  function renderInvites() {
    const form = S.inviteForm;
    const note = h("input", { class: "input", placeholder: "例如：研发团队", value: form.note, id: "inv-note" });
    note.addEventListener("input", () => { form.note = note.value; });
    const uses = h("input", { class: "input", type: "number", min: 1, value: form.max_uses, id: "inv-uses" });
    uses.addEventListener("input", () => { form.max_uses = Math.max(1, parseInt(uses.value, 10) || 1); });
    const hours = h("input", { class: "input", type: "number", min: 0, value: form.expires_hours, placeholder: "0 = 永久", id: "inv-hours" });
    hours.addEventListener("input", () => { form.expires_hours = Math.max(0, parseInt(hours.value, 10) || 0); });

    const create = btn("生成邀请码", {
      kind: "primary",
      iconName: "plus",
      onclick: async (e) => {
        const rec = await run(e.currentTarget, () => api("/api/admin/invites", {
          method: "POST",
          body: { note: form.note.trim() || null, max_uses: form.max_uses, expires_hours: form.expires_hours || null },
        }));
        if (rec) {
          form.note = "";
          S.invites = await api("/api/admin/invites");
          renderPage({ keepScroll: true });
          copyText(rec.code, `已生成并复制邀请码 ${rec.code}`);
        }
      },
    });

    const list = table([
      { label: "邀请码", render: (i) => h("span", { class: "code-chip", text: i.code }) },
      { label: "备注", render: (i) => h("span", { class: i.note ? null : "faint", text: i.note || "—" }) },
      { label: "使用", cls: "num", render: (i) => `${i.used_count} / ${i.max_uses}` },
      { label: "有效期至", render: (i) => h("span", { class: "nowrap", text: i.expires_at ? fmtDate(i.expires_at) : "永久" }) },
      { label: "状态", render: inviteStatus },
      {
        label: "", cls: "actions", render: (i) => [
          btn("", { size: "sm", iconName: "copy", title: "复制邀请码", onclick: () => copyText(i.code) }),
          btn("", {
            size: "sm", kind: "danger", iconName: "trash", title: "删除邀请码",
            onclick: async (e) => {
              if (!(await confirmDialog("删除邀请码", `删除后 ${i.code} 立即失效。`, { confirmText: "删除", danger: true }))) return;
              if ((await run(e.currentTarget, () => api("/api/admin/invites/" + encodeURIComponent(i.code), { method: "DELETE" }), "邀请码已删除")) !== undefined) {
                S.invites = await api("/api/admin/invites");
                renderPage({ keepScroll: true });
              }
            },
          }),
        ],
      },
    ], S.invites, { emptyIcon: "ticket", emptyText: "还没有邀请码" });

    return h("div", { class: "page" },
      h("div", { class: "card" }, h("div", { class: "inline-form" },
        field("备注（可选）", note), field("可用次数", uses), field("有效期（小时）", hours), create)),
      list);
  }

  async function copyText(text, message) {
    try {
      await navigator.clipboard.writeText(text);
      toast(message || "已复制到剪贴板");
    } catch {
      toast("复制失败，请手动选择复制", "err");
    }
  }

  // Features & limits ----------------------------------------------------------
  function renderFeatures() {
    const d = S.draft;
    if (!d) return h("div", { class: "page" });
    const f = d.features;

    const transfer = h("div", { class: "group" },
      row({ title: "云端中转上传", desc: "允许把文件上传到服务器本地或云盘。关闭后只能在在线设备之间 P2P 直传，已上传的文件仍可下载。", control: draftSwitch("features.cloud_upload_enabled", { label: "云端中转上传" }) }),
      row({ title: "创建公网外链", desc: "允许用户为抽屉里的文件生成公开下载链接。", control: draftSwitch("features.share_create_enabled", { rerender: true, label: "创建公网外链" }) }),
      row({ title: "公网外链访问", desc: "关闭后所有已有外链暂时无法打开，重新开启即可恢复。", badges: !f.share_access_enabled ? pill("已暂停", "danger") : null, control: draftSwitch("features.share_access_enabled", { rerender: true, label: "公网外链访问" }) }),
      row({ title: "外链必须设置提取码", disabled: !f.share_create_enabled, control: draftSwitch("share_policy.require_passcode", { disabled: !f.share_create_enabled, label: "外链必须设置提取码" }) }),
      row({ title: "外链最长有效期", desc: "用户设置更长或选择永久时会按此上限创建。", disabled: !f.share_create_enabled, control: draftNumber("share_policy.max_expires_hours", { unit: "小时", step: 1 }) }),
      row({ title: "单个外链最多下载次数", disabled: !f.share_create_enabled, control: draftNumber("share_policy.max_downloads_cap", { unit: "次", step: 1 }) }));

    const disabledKinds = new Set(d.storage_policy.disabled_backend_kinds);
    const kinds = h("div", { class: "group" },
      Object.keys(KIND_LABELS).map((kind) => row({
        title: KIND_LABELS[kind],
        desc: KIND_DESC[kind],
        control: switchEl({
          id: "kind-" + kind,
          checked: !disabledKinds.has(kind),
          label: "允许 " + KIND_LABELS[kind],
          onchange: (on) => {
            const next = new Set(S.draft.storage_policy.disabled_backend_kinds);
            if (on) next.delete(kind); else next.add(kind);
            setDraft("storage_policy.disabled_backend_kinds", Object.keys(KIND_LABELS).filter((k) => next.has(k)));
          },
        }),
      })),
      row({
        title: "拦截内网存储地址",
        desc: "拒绝指向 127.0.0.1、10.x、192.168.x、169.254.x 等内网或本机地址的 WebDAV / S3，防止服务器被用来探测内网。在局域网内自用 NAS 的部署请保持关闭。",
        control: draftSwitch("storage_policy.block_private_endpoints", { label: "拦截内网存储地址" }),
      }));

    const MB = 1024 * 1024;
    const GB = 1024 * MB;
    const limits = h("div", { class: "group" },
      row({ title: "单文件上传上限", desc: "仅限制上传到服务器本地存储的文件。", control: draftNumber("local_max_file_bytes", { unit: "MB", scale: MB }) }),
      row({ title: "每个用户的本地存储配额", desc: "服务器本地磁盘的总配额，可在用户详情里单独调整。", control: draftNumber("default_user_local_quota_bytes", { unit: "GB", scale: GB }) }),
      row({ title: "每个用户最多设备数", desc: "超出后新设备无法登记，已登记的设备不受影响。", control: draftNumber("limits.max_devices_per_user", { unit: "台", step: 1 }) }),
      row({ title: "每个用户最多抽屉条目", control: draftNumber("limits.max_items_per_user", { unit: "项", step: 1 }) }),
      row({ title: "条目默认保留时长", desc: "客户端没有指定时使用，留空为 7 天（168 小时）。", control: draftNumber("limits.default_item_ttl_hours", { unit: "小时", step: 1, placeholder: "168" }) }),
      row({ title: "条目最长保留时长", desc: "到期后自动删除，客户端设置更长时按此上限。", control: draftNumber("limits.max_item_ttl_hours", { unit: "小时", step: 1 }) }));

    return h("div", { class: "page" },
      sectionTitle("传输与分享"), transfer,
      sectionTitle("允许的存储类型", "停用后无法新增该类型，也不能再上传到已有的该类后端，已存文件仍可下载"), kinds,
      sectionTitle("配额与限制", "留空或填 0 表示不限"), limits);
  }

  // Mail ------------------------------------------------------------------------
  function renderMail() {
    const d = S.draft;
    if (!d) return h("div", { class: "page" });
    const smtp = d.smtp;
    const security = h("select", { class: "select", id: "smtp-security" },
      [["start_tls", "STARTTLS（587）"], ["tls", "SSL / TLS（465）"], ["none", "不加密（25）"]].map(([v, l]) => h("option", { value: v, selected: smtp.security === v }, l)));
    security.addEventListener("change", () => {
      const port = { start_tls: 587, tls: 465, none: 25 }[security.value];
      const known = [587, 465, 25].includes(Number(S.draft.smtp.port));
      setDraft("smtp.security", security.value);
      if (known) setDraft("smtp.port", port, { rerender: true });
    });
    const port = h("input", { class: "input", type: "number", min: 1, max: 65535, value: smtp.port, id: "smtp-port" });
    port.addEventListener("input", () => setDraft("smtp.port", parseInt(port.value, 10) || 587));

    const testTo = h("input", { class: "input", type: "email", placeholder: "you@example.com", value: S.testEmailTo, id: "smtp-test-to" });
    testTo.addEventListener("input", () => { S.testEmailTo = testTo.value.trim(); });
    const sendTest = btn("发送测试邮件", {
      iconName: "mail",
      onclick: (e) => {
        if (!S.testEmailTo) { toast("请先填写收件邮箱", "err"); testTo.focus(); return; }
        const payload = buildSettingsPayload().smtp;
        run(e.currentTarget, () => api("/api/admin/smtp/test", { method: "POST", body: { to: S.testEmailTo, smtp: payload } }), "测试邮件已发出，请查收");
      },
    });

    return h("div", { class: "page" },
      h("div", { class: "group" },
        row({ title: "启用 SMTP 发信", desc: "开启后可使用注册邮箱验证与邮箱找回密码。", control: draftSwitch("smtp.enabled", { rerender: true, label: "启用 SMTP 发信" }) }),
        h("div", { class: "row stack" + (smtp.enabled ? "" : " disabled") },
          h("div", { class: "fields" },
            field("SMTP 主机", draftText("smtp.host", { placeholder: "smtp.example.com" })),
            field("加密方式", security),
            field("端口", port),
            field("用户名", draftText("smtp.username", { placeholder: "noreply@example.com" })),
            field("密码 / 授权码", secretInput("smtp", smtp.has_password, "SMTP 密码"), smtp.has_password ? pill("已保存", "ok") : null),
            field("发件人邮箱", draftText("smtp.from_address", { placeholder: "noreply@example.com", type: "email" })),
            field("发件人名称", draftText("smtp.from_name", { placeholder: "DropDrawer" }))))),
      sectionTitle("连通性测试", "使用当前表单里的配置发送（无需先保存）"),
      h("div", { class: "card" }, h("div", { class: "inline-form" },
        h("div", { class: "field" }, h("label", { text: "收件邮箱" }), testTo), h("span"), h("span"), sendTest)));
  }

  // Users -------------------------------------------------------------------------
  function userMatches(u) {
    const q = S.userQuery.trim().toLowerCase();
    if (q && !(u.username.toLowerCase().includes(q) || (u.email || "").toLowerCase().includes(q) || (u.note || "").toLowerCase().includes(q))) return false;
    switch (S.userFilter) {
      case "online": return u.online_devices > 0;
      case "disabled": return u.disabled;
      case "restricted": return u.upload_blocked || u.share_blocked || u.local_quota_bytes != null;
      default: return true;
    }
  }

  function userStatus(u) {
    if (u.disabled) return pill("已禁用", "danger");
    if (u.online_devices > 0) return pill(`在线 · ${u.online_devices}`, "ok");
    return pill("离线");
  }

  function renderUsers() {
    setActions(btn("刷新", { iconName: "refresh", onclick: (e) => refreshUsers(e.currentTarget) }));
    const counts = {
      all: S.users.length,
      online: S.users.filter((u) => u.online_devices > 0).length,
      disabled: S.users.filter((u) => u.disabled).length,
      restricted: S.users.filter((u) => u.upload_blocked || u.share_blocked || u.local_quota_bytes != null).length,
    };
    const toolbar = h("div", { class: "toolbar" },
      searchBox("搜索用户名、邮箱或备注", S.userQuery, (v) => { S.userQuery = v; updateTable(); }, "q-users"),
      segmented([["all", `全部 ${counts.all}`], ["online", `在线 ${counts.online}`], ["disabled", `已禁用 ${counts.disabled}`], ["restricted", `受限 ${counts.restricted}`]],
        S.userFilter, (v) => { S.userFilter = v; renderPage({ keepScroll: true }); }));

    const tableHost = h("div");
    function updateTable() {
      replace(tableHost, table([
        {
          label: "用户", render: (u) => h("div", { class: "user-cell" },
            h("div", { class: "avatar" + (u.disabled ? " muted" : "") , text: initials(u.username) }),
            h("div", { class: "truncate" },
              h("div", { class: "cell-main truncate", text: u.username }),
              h("div", { class: "cell-sub truncate", text: u.email || "未绑定邮箱" }))),
        },
        {
          label: "登录方式", render: (u) => h("div", { class: "pills" },
            u.google_linked ? pill("Google", "accent", false) : pill("密码", null, false),
            u.email_verified ? pill("邮箱已验证", "ok", false) : null),
        },
        { label: "设备", cls: "num", render: (u) => `${u.online_devices} / ${u.device_count}` },
        { label: "条目 / 云端", cls: "num", render: (u) => h("div", null, h("div", { text: fmtNum(u.item_count) }), h("div", { class: "cell-sub", text: fmtBytes(u.storage_bytes) })) },
        {
          label: "限制", render: (u) => {
            const tags = [];
            if (u.upload_blocked) tags.push(pill("禁止上传", "warn", false));
            if (u.share_blocked) tags.push(pill("禁止外链", "warn", false));
            if (u.local_quota_bytes != null) tags.push(pill("配额 " + fmtBytes(u.local_quota_bytes), null, false));
            return tags.length ? h("div", { class: "pills" }, tags) : h("span", { class: "faint", text: "—" });
          },
        },
        { label: "最近登录", render: (u) => h("span", { class: "nowrap", title: u.last_login_at ? fmtDate(u.last_login_at) : null, text: u.last_login_at ? fmtRel(u.last_login_at) : "—" }) },
        { label: "状态", render: userStatus },
      ], S.users.filter(userMatches), { onRowClick: (u) => openUserDrawer(u.id), emptyIcon: "users", emptyText: S.users.length ? "没有匹配的用户" : "还没有注册用户" }));
    }
    updateTable();
    return h("div", { class: "page" }, toolbar, tableHost);
  }

  async function refreshUsers(button) {
    const users = await run(button, () => api("/api/admin/users"));
    if (users) { S.users = users; renderNav(); if (S.page === "users") renderPage({ keepScroll: true }); }
  }

  // User drawer ---------------------------------------------------------------
  let drawerState = null;

  async function openUserDrawer(id, tab = "overview") {
    const detail = await run(null, () => api("/api/admin/users/" + encodeURIComponent(id)));
    if (!detail) return;
    if (drawerState) {
      drawerState.detail = detail;
      drawerState.tab = tab;
      renderDrawer();
      return;
    }
    drawerState = { id, detail, tab, host: h("div") };
    drawerState.close = pushOverlay(drawerState.host, () => { drawerState = null; });
    renderDrawer();
  }

  async function reloadDrawer() {
    if (!drawerState) return;
    const detail = await run(null, () => api("/api/admin/users/" + encodeURIComponent(drawerState.id)));
    if (detail && drawerState) { drawerState.detail = detail; renderDrawer(); }
    refreshUsers();
  }

  function renderDrawer() {
    const { detail, tab } = drawerState;
    const u = detail.user;
    const userPath = "/api/admin/users/" + encodeURIComponent(u.id);

    const actions = h("div", { class: "drawer-actions" },
      btn("强制下线", {
        iconName: "power", size: "sm",
        onclick: async (e) => {
          if (!(await confirmDialog("强制下线", `「${u.username}」在所有设备上的登录会立即失效，需要重新登录。`, { confirmText: "强制下线" }))) return;
          if (await run(e.currentTarget, () => api(userPath + "/sign-out", { method: "POST" }), "已强制下线")) reloadDrawer();
        },
      }),
      btn("重置密码", { iconName: "key", size: "sm", onclick: () => resetPasswordDialog(u) }),
      btn(u.disabled ? "解封账号" : "禁用账号", {
        iconName: u.disabled ? "check" : "ban", size: "sm", kind: u.disabled ? null : "danger",
        onclick: async (e) => {
          const disable = !u.disabled;
          if (disable && !(await confirmDialog("禁用账号", `「${u.username}」将无法登录，在线设备立即断开，名下外链同时失效。`, { confirmText: "禁用", danger: true }))) return;
          if (await run(e.currentTarget, () => api(userPath + "/disable", { method: "POST", body: { disabled: disable } }), disable ? "账号已禁用" : "账号已恢复")) reloadDrawer();
        },
      }));

    const tabs = [
      ["overview", "概况", null],
      ["devices", "设备", detail.devices.length],
      ["storage", "存储", detail.backends.length],
      ["items", "条目", u.item_count],
      ["shares", "外链", detail.shares.length],
    ];
    const tabBar = h("div", { class: "tabs", role: "tablist" }, tabs.map(([key, label, count]) => h("button", {
      type: "button", role: "tab", class: tab === key ? "active" : null, "aria-selected": tab === key ? "true" : "false",
      onclick: () => { drawerState.tab = key; renderDrawer(); },
    }, label, count != null ? h("span", { class: "count", text: fmtNum(count) }) : null)));

    const body = { overview: drawerOverview, devices: drawerDevices, storage: drawerStorage, items: drawerItems, shares: drawerShares }[tab](detail, userPath);

    replace(drawerState.host,
      h("div", { class: "scrim", onclick: () => drawerState && drawerState.close() }),
      h("aside", { class: "drawer", role: "dialog", "aria-modal": "true", "aria-label": "用户详情" },
        h("div", { class: "drawer-head" },
          h("div", { class: "drawer-title" },
            h("div", { class: "avatar lg" + (u.disabled ? " muted" : ""), text: initials(u.username) }),
            h("div", null,
              h("h2", { text: u.username }),
              h("div", { class: "sub", text: [u.email || "未绑定邮箱", "注册于 " + fmtDate(u.created_at)].join(" · ") })),
            btn("", { kind: "ghost", iconName: "x", title: "关闭", onclick: () => drawerState.close() })),
          h("div", { class: "pills" }, userStatus(u), u.google_linked ? pill("Google", "accent", false) : null, u.email_verified ? pill("邮箱已验证", "ok", false) : null),
          actions,
          tabBar),
        h("div", { class: "drawer-body" }, body)));
  }

  function drawerOverview(detail, userPath) {
    const u = detail.user;
    const policy = clone(detail.policy);
    const GB = 1024 * 1024 * 1024;

    const quota = h("input", {
      class: "input", type: "number", min: 0, step: "any", id: "pol-quota",
      placeholder: S.settings.default_user_local_quota_bytes ? `默认 ${fmtBytes(S.settings.default_user_local_quota_bytes)}` : "默认不限",
      value: policy.local_quota_bytes ? String(Math.round((policy.local_quota_bytes / GB) * 100) / 100) : "",
    });
    quota.addEventListener("input", () => {
      const v = parseFloat(quota.value);
      policy.local_quota_bytes = Number.isFinite(v) && v > 0 ? Math.round(v * GB) : null;
    });
    const note = h("textarea", { class: "textarea", rows: 2, placeholder: "仅管理员可见", id: "pol-note" });
    note.value = policy.note || "";
    note.addEventListener("input", () => { policy.note = note.value; });

    const savePolicy = btn("保存用户策略", {
      kind: "primary",
      onclick: async (e) => {
        if (await run(e.currentTarget, () => api(userPath + "/policy", { method: "PUT", body: policy }), "用户策略已保存")) reloadDrawer();
      },
    });

    return [
      h("div", { class: "mini-stats" },
        miniStat("设备", `${u.online_devices} / ${u.device_count}`),
        miniStat("抽屉条目", fmtNum(u.item_count)),
        miniStat("云端占用", fmtBytes(u.storage_bytes)),
        miniStat("配额", detail.effective_local_quota_bytes ? fmtBytes(detail.effective_local_quota_bytes) : "不限"),
        miniStat("最近登录", u.last_login_at ? fmtRel(u.last_login_at) : "—")),
      sectionTitle("用户策略", "覆盖服务器默认设置，仅对该用户生效"),
      h("div", { class: "group" },
        row({ title: "本地存储配额", desc: "留空则使用服务器默认配额。", control: h("div", { class: "input-unit" }, quota, h("span", { text: "GB" })) }),
        row({ title: "禁止上传到云端", desc: "该用户只能使用 P2P 直传。", control: switchEl({ id: "pol-upload", checked: policy.upload_blocked, label: "禁止上传到云端", onchange: (v) => { policy.upload_blocked = v; } }) }),
        row({ title: "禁止创建外链", desc: "已有外链不受影响，可在「外链」页吊销。", control: switchEl({ id: "pol-share", checked: policy.share_blocked, label: "禁止创建外链", onchange: (v) => { policy.share_blocked = v; } }) }),
        h("div", { class: "row stack" }, field("管理员备注", note))),
      h("div", null, savePolicy),
      h("div", { class: "danger-zone" },
        h("div", null, h("div", { class: "row-title", text: "删除账号" }), h("div", { class: "row-desc", text: "永久删除账号、设备、存储配置、抽屉文件与外链，无法恢复。" })),
        btn("删除账号", {
          kind: "danger", iconName: "trash",
          onclick: async (e) => {
            const ok = await typedConfirm("删除账号", `此操作会永久删除「${u.username}」及其全部云端文件。请输入用户名确认：`, u.username);
            if (!ok) return;
            if ((await run(e.currentTarget, () => api(userPath, { method: "DELETE" }), `已删除「${u.username}」`)) !== undefined) {
              drawerState.close();
              refreshAll();
            }
          },
        })),
    ];
  }

  function miniStat(label, value) {
    return h("div", { class: "mini-stat" }, h("div", { class: "label", text: label }), h("div", { class: "value", text: value }));
  }

  function drawerDevices(detail, userPath) {
    if (!detail.devices.length) return empty("monitor", "该用户还没有登记设备");
    return [
      callout(null, "移除后该设备会立即断开，旧的登录凭据也无法再登记这台设备，用户需要在设备上重新登录。"),
      h("div", { class: "list" }, detail.devices.map((d) => h("div", { class: "list-item" },
        h("div", { class: "list-icon" }, icon(["ios", "android"].includes(d.platform) ? "phone" : "monitor")),
        h("div", { class: "grow" },
          h("div", { class: "title", text: d.name }),
          h("div", { class: "meta", text: [PLATFORM_LABELS[d.platform] || d.platform, d.app_version ? "v" + d.app_version : "版本未知", d.has_p2p ? "支持 P2P" : "无 P2P 节点", "最后活跃 " + fmtRel(d.last_seen_at)].join(" · ") })),
        d.online ? pill("在线", "ok") : pill("离线"),
        btn("", {
          size: "sm", kind: "danger", iconName: "trash", title: "移除设备",
          onclick: async (e) => {
            if (!(await confirmDialog("移除设备", `移除「${d.name}」？该设备需要重新登录才能再次使用。`, { confirmText: "移除", danger: true }))) return;
            if ((await run(e.currentTarget, () => api(`${userPath}/devices/${encodeURIComponent(d.id)}`, { method: "DELETE" }), "设备已移除")) !== undefined) reloadDrawer();
          },
        })))),
    ];
  }

  function drawerStorage(detail, userPath) {
    if (!detail.backends.length) return empty("database", "该用户还没有配置存储，上传时会自动使用服务器本地存储");
    const disabled = new Set(S.settings.storage_policy.disabled_backend_kinds);
    return h("div", { class: "list" }, detail.backends.map((b) => h("div", { class: "list-item" },
      h("div", { class: "list-icon" }, icon(b.kind === "local" ? "server" : "cloud")),
      h("div", { class: "grow" },
        h("div", { class: "title", text: b.name }),
        h("div", { class: "meta", text: (KIND_LABELS[b.kind] || b.kind) + " · " + b.display_target })),
      b.is_default ? pill("默认", "accent", false) : null,
      disabled.has(b.kind) ? pill("类型已停用", "warn", false) : null,
      btn("", {
        size: "sm", kind: "danger", iconName: "trash", title: "移除存储",
        onclick: async (e) => {
          if (!(await confirmDialog("移除存储配置", `移除「${b.name}」？只删除配置，不会删除云盘里的文件；引用它的抽屉条目将无法再从云端下载。`, { confirmText: "移除", danger: true }))) return;
          if ((await run(e.currentTarget, () => api(`${userPath}/backends/${encodeURIComponent(b.id)}`, { method: "DELETE" }), "存储配置已移除")) !== undefined) reloadDrawer();
        },
      }))));
  }

  function drawerItems(detail, userPath) {
    const items = detail.items;
    if (!items.length) return empty("file", "抽屉是空的");
    return [
      items.length >= 300 ? callout(null, "仅显示最近 300 个条目。") : null,
      h("div", { class: "list" }, items.map((it) => h("div", { class: "list-item" },
        h("div", { class: "list-icon" }, icon(it.kind === "text" ? "text" : "file")),
        h("div", { class: "grow" },
          h("div", { class: "title", text: it.kind === "text" ? "文本片段" : it.name }),
          h("div", { class: "meta", text: [fmtBytes(it.size), it.cloud_ready ? "已在云端" : MODE_LABELS[it.transfer_mode] || it.transfer_mode, "创建于 " + fmtRel(it.created_at), it.expires_at ? fmtRel(it.expires_at) + "到期" : null].filter(Boolean).join(" · ") })),
        btn("", {
          size: "sm", kind: "danger", iconName: "trash", title: "删除条目",
          onclick: async (e) => {
            if (!(await confirmDialog("删除条目", "条目会从该用户所有设备的抽屉中移除，云端文件一并删除。", { confirmText: "删除", danger: true }))) return;
            if ((await run(e.currentTarget, () => api(`${userPath}/items/${encodeURIComponent(it.id)}`, { method: "DELETE" }), "条目已删除")) !== undefined) reloadDrawer();
          },
        })))),
    ];
  }

  function drawerShares(detail, userPath) {
    if (!detail.shares.length) return empty("link", "该用户没有外链");
    return [
      h("div", null, btn("吊销全部外链", {
        kind: "danger", iconName: "ban",
        onclick: async (e) => {
          if (!(await confirmDialog("吊销全部外链", `吊销「${detail.user.username}」的 ${detail.shares.length} 个外链？`, { confirmText: "全部吊销", danger: true }))) return;
          const r = await run(e.currentTarget, () => api(userPath + "/shares", { method: "DELETE" }));
          if (r) { toast(`已吊销 ${r.revoked} 个外链`); reloadDrawer(); loadShares(); }
        },
      })),
      h("div", { class: "list" }, detail.shares.map((s) => h("div", { class: "list-item" },
        h("div", { class: "list-icon" }, icon(s.has_passcode ? "lock" : "link")),
        h("div", { class: "grow" },
          h("div", { class: "title" }, h("a", { href: "/s/" + encodeURIComponent(s.code), target: "_blank", rel: "noopener noreferrer", text: s.title || "/s/" + s.code })),
          h("div", { class: "meta", text: [`下载 ${s.download_count}${s.max_downloads ? " / " + s.max_downloads : ""}`, s.expires_at ? "有效期至 " + fmtDate(s.expires_at) : "永久有效", "创建于 " + fmtRel(s.created_at)].join(" · ") })),
        shareState(s),
        btn("", {
          size: "sm", kind: "danger", iconName: "ban", title: "吊销外链",
          onclick: async (e) => {
            if ((await run(e.currentTarget, () => api("/api/admin/shares/" + encodeURIComponent(s.code), { method: "DELETE" }), "外链已吊销")) !== undefined) { reloadDrawer(); loadShares(); }
          },
        })))),
    ];
  }

  function randomPassword() {
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
    const bytes = crypto.getRandomValues(new Uint8Array(14));
    return Array.from(bytes, (b) => alphabet[b % alphabet.length]).join("");
  }

  async function resetPasswordDialog(u) {
    const input = h("input", { class: "input mono", type: "text", value: randomPassword(), autocomplete: "off", "aria-label": "新密码" });
    const body = h("div", { class: "page" },
      h("p", { text: `为「${u.username}」设置新密码（至少 6 位）。保存后该用户所有设备会被强制下线。` }),
      h("div", { class: "toolbar" }, h("div", { class: "search-wrap" }, input),
        btn("", { iconName: "dice", title: "重新生成", onclick: () => { input.value = randomPassword(); } }),
        btn("", { iconName: "copy", title: "复制", onclick: () => copyText(input.value) })));
    const result = await dialog({
      title: "重置密码",
      body,
      actions: [{ label: "取消", value: false, kind: "ghost" }, { label: "重置密码", value: true, kind: "primary" }],
    });
    if (!result) return;
    const pwd = input.value;
    if (pwd.length < 6) { toast("密码长度不能少于 6 位", "err"); return; }
    const ok = await run(null, () => api(`/api/admin/users/${encodeURIComponent(u.id)}/reset-password`, { method: "POST", body: { new_password: pwd } }));
    if (ok) {
      copyText(pwd, "密码已重置，新密码已复制到剪贴板");
      reloadDrawer();
    }
  }

  async function typedConfirm(title, message, expected) {
    const input = h("input", { class: "input", type: "text", placeholder: expected, autocomplete: "off", "aria-label": "确认输入" });
    const result = await dialog({
      title,
      body: [h("p", { text: message }), input],
      actions: [{ label: "取消", value: false, kind: "ghost" }, { label: "永久删除", value: true, kind: "danger" }],
    });
    if (!result) return false;
    if (input.value.trim() !== expected) { toast("输入的内容不匹配，已取消", "err"); return false; }
    return true;
  }

  // Shares ------------------------------------------------------------------------
  function shareExpired(s) {
    return (s.expires_at && new Date(s.expires_at) <= new Date()) || (s.max_downloads != null && s.download_count >= s.max_downloads);
  }

  function shareState(s) {
    if (S.settings && !S.settings.features.share_access_enabled) return pill("已暂停", "danger");
    return shareExpired(s) ? pill("已失效") : pill("有效", "ok");
  }

  function renderShares() {
    setActions(btn("刷新", { iconName: "refresh", onclick: (e) => loadShares(e.currentTarget) }));
    const filtered = () => {
      const q = S.shareQuery.trim().toLowerCase();
      return S.shares.filter((s) => {
        if (q && !(s.code.toLowerCase().includes(q) || s.owner_username.toLowerCase().includes(q) || s.item_name.toLowerCase().includes(q))) return false;
        if (S.shareFilter === "active") return !shareExpired(s);
        if (S.shareFilter === "expired") return shareExpired(s);
        if (S.shareFilter === "passcode") return s.has_passcode;
        return true;
      });
    };
    const host = h("div");
    const meta = h("span", { class: "meta" });
    const render = () => {
      const rows = filtered();
      meta.textContent = `${rows.length} 条` + (S.shares.length >= 1000 ? "（最多显示 1000 条）" : "");
      replace(host, table([
      { label: "外链", render: (s) => h("a", { class: "mono", href: "/s/" + encodeURIComponent(s.code), target: "_blank", rel: "noopener noreferrer", text: "/s/" + s.code }) },
      { label: "内容", render: (s) => h("div", { class: "truncate" }, h("div", { class: "cell-main truncate", text: s.item_name }), h("div", { class: "cell-sub", text: fmtBytes(s.item_size) })) },
      { label: "创建者", render: (s) => h("button", { class: "btn ghost sm", type: "button", onclick: () => openUserDrawer(s.owner_id, "shares") }, s.owner_username) },
      { label: "下载", cls: "num", render: (s) => `${fmtNum(s.download_count)}${s.max_downloads ? " / " + fmtNum(s.max_downloads) : ""}` },
      { label: "有效期", render: (s) => h("div", { class: "nowrap" }, s.has_passcode ? icon("lock", "faint") : null, " ", s.expires_at ? fmtDate(s.expires_at) : "永久") },
      { label: "状态", render: shareState },
      {
        label: "", cls: "actions", render: (s) => btn("吊销", {
          size: "sm", kind: "danger",
          onclick: async (e) => {
            if (!(await confirmDialog("吊销外链", `吊销后 /s/${s.code} 立即无法访问。`, { confirmText: "吊销", danger: true }))) return;
            if ((await run(e.currentTarget, () => api("/api/admin/shares/" + encodeURIComponent(s.code), { method: "DELETE" }), "外链已吊销")) !== undefined) loadShares();
          },
        }),
      },
    ], rows, { emptyIcon: "link", emptyText: S.shares.length ? "没有匹配的外链" : "还没有人创建外链" }));
    };
    render();
    const accessPaused = S.settings && !S.settings.features.share_access_enabled;
    return h("div", { class: "page" },
      accessPaused ? callout("warn", "公网外链访问已在「功能与限额」中暂停，以下外链当前都无法打开。") : null,
      h("div", { class: "toolbar" },
        searchBox("搜索外链码、文件名或创建者", S.shareQuery, (v) => { S.shareQuery = v; render(); }, "q-shares"),
        segmented([["all", "全部"], ["active", "有效"], ["expired", "已失效"], ["passcode", "有提取码"]], S.shareFilter, (v) => { S.shareFilter = v; renderPage({ keepScroll: true }); }),
        h("span", { class: "spacer" }),
        meta),
      host);
  }

  async function loadShares(button) {
    const shares = await run(button, () => api("/api/admin/shares"));
    if (shares) { S.shares = shares; renderNav(); if (S.page === "shares") renderPage({ keepScroll: true }); }
  }

  // Audit -------------------------------------------------------------------------
  function renderAudit() {
    setActions(btn("刷新", { iconName: "refresh", onclick: (e) => loadAudit(e.currentTarget) }));
    const host = h("div");
    const meta = h("span", { class: "meta" });
    const render = () => {
      const q = S.auditQuery.trim().toLowerCase();
      const rows = S.audit.filter((e) => !q || [AUDIT_LABELS[e.action] || e.action, e.target, auditDetail(e), e.ip].some((v) => (v || "").toLowerCase().includes(q)));
      meta.textContent = `${rows.length} 条`;
      replace(host, table([
        { label: "时间", render: (e) => h("span", { class: "nowrap", title: fmtDate(e.at), text: fmtDate(e.at) }) },
        { label: "操作", render: (e) => h("span", { class: "nowrap" }, h("span", { class: "dot " + (auditDangerous(e.action) ? "danger" : "accent") }), " ", AUDIT_LABELS[e.action] || e.action) },
        { label: "对象", render: (e) => h("span", { class: "truncate", text: e.target || "—" }) },
        { label: "详情", render: (e) => h("span", { class: "muted truncate", text: auditDetail(e) || "—" }) },
        { label: "IP", render: (e) => h("span", { class: "mono faint", text: e.ip || "—" }) },
      ], rows, { emptyIcon: "log", emptyText: "暂无记录" }));
    };
    render();
    return h("div", { class: "page" },
      h("div", { class: "toolbar" },
        searchBox("搜索操作、对象或 IP", S.auditQuery, (v) => { S.auditQuery = v; render(); }, "q-audit"),
        h("span", { class: "spacer" }), meta),
      host);
  }

  async function loadAudit(button) {
    const audit = await run(button, () => api("/api/admin/audit?limit=500"));
    if (audit) { S.audit = audit; if (S.page === "audit") renderPage({ keepScroll: true }); }
  }

  // Clients & announcement ---------------------------------------------------------
  async function loadClients(button) {
    const clients = await run(button, () => api("/api/admin/clients"));
    if (clients) { S.clients = clients; if (S.page === "clients") renderPage({ keepScroll: true }); }
  }

  function announcementPreview(a) {
    const level = a.level || "info";
    return h("div", { class: "ann-preview " + level },
      icon(level === "info" ? "info" : "alert"),
      h("div", null,
        h("div", { class: "t", text: a.title || "（无标题）" }),
        a.message ? h("div", { class: "m", text: a.message }) : null));
  }

  function renderClients() {
    setActions(btn("刷新", { iconName: "refresh", onclick: (e) => loadClients(e.currentTarget) }));
    const d = S.draft;
    if (!d) return h("div", { class: "page" });
    const a = d.announcement;

    const title = h("input", { class: "input", id: "ann-title", maxlength: 80, placeholder: "例如：今晚 23:00 维护", value: a.title });
    const message = h("textarea", { class: "textarea", id: "ann-message", rows: 3, maxlength: 1000, placeholder: "公告内容，客户端会以横幅显示，用户可以关闭" });
    message.value = a.message;
    const previewHost = h("div", null, announcementPreview(a));
    const refreshPreview = () => replace(previewHost, announcementPreview(S.draft.announcement));
    title.addEventListener("input", () => { setDraft("announcement.title", title.value); refreshPreview(); });
    message.addEventListener("input", () => { setDraft("announcement.message", message.value); refreshPreview(); });

    const announcement = h("div", { class: "group" },
      row({ title: "发布公告", desc: "开启后在所有已登录客户端顶部显示。修改内容会让已关闭横幅的用户再次看到。", control: draftSwitch("announcement.enabled", { label: "发布公告" }) }),
      row({
        title: "级别",
        control: segmented([["info", "通知"], ["warning", "警告"], ["critical", "紧急"]], a.level || "info",
          (v) => { setDraft("announcement.level", v, { rerender: true }); }),
      }),
      h("div", { class: "row stack" }, field("标题", title), field("内容", message), field("预览", previewHost)));

    const minVersion = h("input", { class: "input", id: "min-version", placeholder: "不限制", value: d.client_policy.min_version || "" });
    minVersion.addEventListener("input", () => setDraft("client_policy.min_version", minVersion.value.trim() || null));
    const policy = h("div", { class: "group" },
      row({
        title: "最低客户端版本",
        desc: "低于此版本（或未上报版本的旧客户端）登录后无法登记设备，会提示用户更新。留空表示不限制。",
        control: h("div", { class: "input-unit" }, minVersion),
      }));

    const minimum = d.client_policy.min_version;
    const below = (v) => {
      if (!minimum) return false;
      if (!v) return true;
      const p = (x) => x.replace(/^v/i, "").split(/[+\-\s]/)[0].split(".").map((n) => parseInt(n, 10) || 0);
      const [x, y] = [p(v), p(minimum)];
      for (let i = 0; i < Math.max(x.length, y.length); i++) {
        if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) < (y[i] || 0);
      }
      return false;
    };
    const versions = table([
      { label: "平台", render: (r) => PLATFORM_LABELS[r.platform] || r.platform },
      { label: "版本", render: (r) => h("span", { class: r.version ? "mono" : "faint", text: r.version ? "v" + r.version : "未上报（旧版本）" }) },
      { label: "设备", cls: "num", render: (r) => fmtNum(r.devices) },
      { label: "近 30 天活跃", cls: "num", render: (r) => fmtNum(r.active_devices) },
      { label: "状态", render: (r) => (below(r.version) ? pill("低于最低版本", "warn") : pill("可用", "ok")) },
    ], S.clients, { emptyIcon: "monitor", emptyText: "还没有设备登记" });

    return h("div", { class: "page" },
      sectionTitle("全站公告"), announcement,
      sectionTitle("版本要求"), policy,
      sectionTitle("客户端版本分布", "按设备最近一次登记时上报的版本统计"), versions);
  }

  // Administrators -------------------------------------------------------------------
  async function loadAdmins(button) {
    if (!isSuper()) return;
    const admins = await run(button, () => api("/api/admin/admins"));
    if (admins) { S.admins = admins; if (S.page === "admins") renderPage({ keepScroll: true }); }
  }

  function renderAdmins() {
    setActions(btn("刷新", { iconName: "refresh", onclick: (e) => loadAdmins(e.currentTarget) }));
    const form = S.adminForm;
    const name = h("input", { class: "input", id: "adm-name", placeholder: "例如：ops", value: form.username, autocomplete: "off" });
    name.addEventListener("input", () => { form.username = name.value; });
    const pwd = h("input", { class: "input mono", id: "adm-pwd", type: "text", placeholder: "至少 10 位", value: form.password, autocomplete: "off" });
    pwd.addEventListener("input", () => { form.password = pwd.value; });
    const role = h("select", { class: "select", id: "adm-role" },
      [["admin", "管理员"], ["viewer", "只读"], ["super", "超级管理员"]].map(([v, l]) => h("option", { value: v, selected: form.role === v }, l)));
    role.addEventListener("change", () => { form.role = role.value; });

    const create = btn("创建管理员", {
      kind: "primary", iconName: "plus",
      onclick: async (e) => {
        const rec = await run(e.currentTarget, () => api("/api/admin/admins", { method: "POST", body: { username: form.username.trim(), password: form.password, role: form.role } }), "管理员已创建");
        if (rec) {
          copyText(`${rec.username} / ${form.password}`, "管理员已创建，账号与初始密码已复制");
          S.adminForm = { username: "", password: "", role: "admin" };
          loadAdmins();
        }
      },
    });

    const roleSelect = (a) => {
      const sel = h("select", { class: "select", "aria-label": "角色" },
        [["super", "超级管理员"], ["admin", "管理员"], ["viewer", "只读"]].map(([v, l]) => h("option", { value: v, selected: a.role === v }, l)));
      sel.addEventListener("change", async () => {
        if ((await run(null, () => api("/api/admin/admins/" + encodeURIComponent(a.id), { method: "PUT", body: { role: sel.value, disabled: a.disabled } }), "角色已更新，该管理员需重新登录")) !== undefined) loadAdmins();
      });
      return sel;
    };

    const isMe = (a) => S.session && S.session.actor === a.username && !S.session.is_owner;
    const list = table([
      {
        label: "管理员", render: (a) => h("div", { class: "user-cell" },
          h("div", { class: "avatar" + (a.disabled ? " muted" : ""), text: initials(a.username) }),
          h("div", null, h("div", { class: "cell-main", text: a.username + (isMe(a) ? "（我）" : "") }), h("div", { class: "cell-sub", text: "创建于 " + fmtDate(a.created_at) }))),
      },
      { label: "角色", render: (a) => (isMe(a) ? pill(ROLE_LABELS[a.role], "accent", false) : roleSelect(a)) },
      { label: "两步验证", render: (a) => (a.totp_enabled ? pill("已开启", "ok") : pill("未开启", "warn")) },
      { label: "最近登录", render: (a) => h("span", { class: "nowrap", text: a.last_login_at ? fmtRel(a.last_login_at) : "从未" }) },
      { label: "状态", render: (a) => (a.disabled ? pill("已停用", "danger") : pill("正常", "ok")) },
      {
        label: "", cls: "actions", render: (a) => (isMe(a) ? h("a", { class: "btn sm", href: "#/me" }, "我的账号") : [
          btn(a.disabled ? "启用" : "停用", {
            size: "sm",
            onclick: async (e) => {
              if ((await run(e.currentTarget, () => api("/api/admin/admins/" + encodeURIComponent(a.id), { method: "PUT", body: { role: a.role, disabled: !a.disabled } }), a.disabled ? "已启用" : "已停用并强制下线")) !== undefined) loadAdmins();
            },
          }),
          btn("", {
            size: "sm", iconName: "key", title: "重置密码",
            onclick: async () => {
              const input = h("input", { class: "input mono", type: "text", value: randomPassword() + randomPassword().slice(0, 4), "aria-label": "新密码" });
              const ok = await dialog({ title: "重置管理员密码", body: [h("p", { text: `为「${a.username}」设置新密码（至少 10 位），其所有会话会被强制下线。` }), input], actions: [{ label: "取消", value: false, kind: "ghost" }, { label: "重置", value: true, kind: "primary" }] });
              if (!ok) return;
              if (await run(null, () => api(`/api/admin/admins/${encodeURIComponent(a.id)}/reset-password`, { method: "POST", body: { new_password: input.value } }))) copyText(input.value, "密码已重置并复制到剪贴板");
            },
          }),
          a.totp_enabled ? btn("", {
            size: "sm", iconName: "shield", title: "重置两步验证",
            onclick: async (e) => {
              if (!(await confirmDialog("重置两步验证", `关闭「${a.username}」的两步验证（例如手机丢失时）。对方下次登录后可重新设置。`, { confirmText: "重置" }))) return;
              if ((await run(e.currentTarget, () => api(`/api/admin/admins/${encodeURIComponent(a.id)}/reset-totp`, { method: "POST" }), "两步验证已重置")) !== undefined) loadAdmins();
            },
          }) : null,
          btn("", {
            size: "sm", kind: "danger", iconName: "trash", title: "删除管理员",
            onclick: async (e) => {
              if (!(await confirmDialog("删除管理员", `删除「${a.username}」？其会话立即失效。`, { confirmText: "删除", danger: true }))) return;
              if ((await run(e.currentTarget, () => api("/api/admin/admins/" + encodeURIComponent(a.id), { method: "DELETE" }), "管理员已删除")) !== undefined) loadAdmins();
            },
          }),
        ]),
      },
    ], S.admins, { emptyIcon: "badge", emptyText: "还没有管理员账号，当前只能用管理员密钥登录" });

    return h("div", { class: "page" },
      callout(null, "超级管理员可以管理管理员账号与下载备份；管理员可以修改设置和治理用户；只读管理员只能查看。管理员密钥（DROPDRAWER_ADMIN_TOKEN）始终拥有超级管理员权限，适合作为应急入口。"),
      h("div", { class: "card" }, h("div", { class: "inline-form" }, field("用户名", name), field("初始密码", pwd), field("角色", role), create)),
      list);
  }

  // My account ---------------------------------------------------------------------
  let totpEnrollment = null;

  function renderMe() {
    const sess = S.session;
    if (!sess) return h("div", { class: "page" });
    if (sess.is_owner) {
      return h("div", { class: "page" },
        callout(null, "你正在使用管理员密钥（DROPDRAWER_ADMIN_TOKEN）登录，这个身份没有个人账号，密码与两步验证不适用。建议在「管理员」页为自己创建一个超级管理员账号并开启两步验证，日常用账号登录，密钥只作应急使用。"),
        isSuper() ? h("div", null, h("a", { class: "btn primary", href: "#/admins" }, icon("badge"), "前往管理员页")) : null);
    }

    const current = h("input", { class: "input", type: "password", autocomplete: "current-password", id: "me-cur" });
    const next = h("input", { class: "input", type: "password", autocomplete: "new-password", id: "me-new", placeholder: "至少 10 位" });
    const changePwd = btn("修改密码", {
      kind: "primary",
      onclick: async (e) => {
        if ((await run(e.currentTarget, () => api("/api/admin/me/password", { method: "POST", body: { current_password: current.value, new_password: next.value } }), "密码已修改，其他设备上的会话已退出")) !== undefined) {
          current.value = ""; next.value = "";
        }
      },
    });

    let totpSection;
    if (sess.totp_enabled) {
      const code = h("input", { class: "input mono", inputmode: "numeric", maxlength: 7, placeholder: "当前验证码", id: "me-totp-off" });
      totpSection = h("div", { class: "group" },
        row({ title: "两步验证已开启", badges: pill("已保护", "ok"), desc: "登录时需要输入身份验证器中的验证码。关闭需要验证一次当前验证码。" }),
        h("div", { class: "row" }, code, btn("关闭两步验证", {
          kind: "danger",
          onclick: async (e) => {
            if ((await run(e.currentTarget, () => api("/api/admin/me/totp/disable", { method: "POST", body: { code: code.value } }), "两步验证已关闭")) !== undefined) loadSession();
          },
        })));
    } else if (totpEnrollment) {
      const code = h("input", { class: "input mono totp-input", inputmode: "numeric", maxlength: 7, placeholder: "000000", id: "me-totp-on" });
      totpSection = h("div", { class: "group" },
        h("div", { class: "row stack" },
          h("div", { class: "row-desc", text: "1. 用 Google Authenticator、1Password、Microsoft Authenticator 等应用扫描二维码，或手动输入密钥。" }),
          h("div", { class: "qr-box" },
            totpEnrollment.qr_data_uri ? h("img", { src: totpEnrollment.qr_data_uri, alt: "两步验证二维码" }) : null,
            h("div", { class: "page" },
              h("div", { class: "secret-chip", text: totpEnrollment.secret.replace(/(.{4})/g, "$1 ").trim() }),
              btn("复制密钥", { size: "sm", iconName: "copy", onclick: () => copyText(totpEnrollment.secret) }))),
          h("div", { class: "row-desc", text: "2. 输入应用中显示的 6 位验证码完成绑定。" }),
          h("div", { class: "toolbar" }, h("div", { class: "search-wrap" }, code), btn("确认开启", {
            kind: "primary",
            onclick: async (e) => {
              if ((await run(e.currentTarget, () => api("/api/admin/me/totp/enable", { method: "POST", body: { code: code.value } }), "两步验证已开启")) !== undefined) {
                totpEnrollment = null;
                loadSession();
              }
            },
          }), btn("取消", { kind: "ghost", onclick: () => { totpEnrollment = null; renderPage({ keepScroll: true }); } }))));
    } else {
      totpSection = h("div", { class: "group" },
        row({
          title: "两步验证未开启",
          badges: pill("建议开启", "warn"),
          desc: "开启后，即使密码泄露，没有你的手机也无法登录管理控制台。",
          control: btn("开始设置", {
            kind: "primary", iconName: "shield",
            onclick: async (e) => {
              const setup = await run(e.currentTarget, () => api("/api/admin/me/totp/setup", { method: "POST" }));
              if (setup) { totpEnrollment = setup; renderPage({ keepScroll: true }); }
            },
          }),
        }));
    }

    return h("div", { class: "page" },
      h("div", { class: "card" }, h("div", { class: "user-cell" },
        h("div", { class: "avatar lg", text: initials(sess.actor) }),
        h("div", null, h("h2", { text: sess.actor }), h("div", { class: "pills" }, pill(ROLE_LABELS[sess.role] || sess.role, "accent", false))))),
      sectionTitle("两步验证"), totpSection,
      sectionTitle("修改密码", "修改后其他设备上的管理端会话会退出"),
      h("div", { class: "card" }, h("div", { class: "inline-form" }, field("当前密码", current), field("新密码", next), h("span"), changePwd)));
  }

  // ---------------------------------------------------------------------------
  // Boot
  // ---------------------------------------------------------------------------
  async function refreshAll(button, notify) {
    const results = await run(button, () => Promise.all([
      api("/api/admin/overview"),
      api("/api/admin/system"),
      api("/api/admin/settings"),
      api("/api/admin/users"),
      api("/api/admin/invites"),
      api("/api/admin/shares"),
      api("/api/admin/audit?limit=500"),
      api("/api/admin/clients"),
      isSuper() ? api("/api/admin/admins") : Promise.resolve([]),
    ]));
    if (!results) return false;
    const [overview, system, settings, users, invites, shares, audit, clients, admins] = results;
    Object.assign(S, { overview, system, users, invites, shares, audit, clients, admins });
    if (!isDirty()) acceptSettings(settings); else S.settings = settings;
    renderNav();
    renderPage({ keepScroll: true });
    if (notify) toast("数据已刷新");
    return true;
  }

  function showLogin(message) {
    $("appView").hidden = true;
    $("savebar").classList.remove("show");
    while (overlayStack.length) closeOverlay(overlayStack[overlayStack.length - 1]);
    $("loginView").hidden = false;
    $("loginError").textContent = message || "";
    setLoginStep(loginMode === "token" ? "token" : "account");
  }

  async function loadSession() {
    const session = await api("/api/admin/session");
    S.session = session;
    document.body.classList.toggle("readonly", session.role === "viewer");
    renderNav();
    if (S.page === "me") renderPage({ keepScroll: true });
    return session;
  }

  async function showApp() {
    await loadSession();
    $("loginView").hidden = true;
    $("appView").hidden = false;
    booted = false;
    navigate();
    await refreshAll();
    booted = true;
  }

  // Login: "account" (username + password), "totp" (second step), or "token".
  let loginMode = "account";

  function setLoginStep(step) {
    loginMode = step;
    $("accountFields").hidden = step !== "account";
    $("totpFields").hidden = step !== "totp";
    $("tokenFields").hidden = step !== "token";
    const tokenMode = step === "token";
    $("modeToken").classList.toggle("active", tokenMode);
    $("modeAccount").classList.toggle("active", !tokenMode);
    $("modeToken").setAttribute("aria-selected", String(tokenMode));
    $("modeAccount").setAttribute("aria-selected", String(!tokenMode));
    $("loginSubmit").textContent = step === "totp" ? "验证并登录" : "登录";
    const focus = { account: $("loginUser").value ? "loginPassword" : "loginUser", totp: "loginTotp", token: "loginToken" }[step];
    setTimeout(() => $(focus).focus(), 30);
  }

  $("modeAccount").addEventListener("click", () => { $("loginError").textContent = ""; setLoginStep("account"); });
  $("modeToken").addEventListener("click", () => { $("loginError").textContent = ""; setLoginStep("token"); });

  $("loginForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const button = $("loginSubmit");
    const body = loginMode === "token"
      ? { token: $("loginToken").value }
      : { username: $("loginUser").value.trim(), password: $("loginPassword").value, totp_code: loginMode === "totp" ? $("loginTotp").value.replace(/\s+/g, "") : null };
    button.classList.add("busy");
    $("loginError").textContent = "";
    try {
      await api("/api/admin/login", { method: "POST", body });
      for (const id of ["loginToken", "loginPassword", "loginTotp"]) $(id).value = "";
      if (loginMode === "totp") setLoginStep("account");
      await showApp();
    } catch (err) {
      if (err.message === "TOTP_REQUIRED") {
        setLoginStep("totp");
      } else {
        $("loginError").textContent = err.message || "登录失败";
        if (loginMode === "totp") { $("loginTotp").value = ""; $("loginTotp").focus(); }
      }
    } finally {
      button.classList.remove("busy");
    }
  });

  $("logoutBtn").addEventListener("click", async () => {
    if (isDirty() && !(await confirmDialog("退出登录", "还有未保存的设置，退出后会丢失。", { confirmText: "仍然退出", danger: true }))) return;
    try { await api("/api/admin/logout", { method: "POST" }); } catch { /* ignore */ }
    S.draft = null;
    S.settings = null;
    S.session = null;
    document.body.classList.remove("readonly");
    showLogin();
  });

  (async function boot() {
    try {
      await api("/api/admin/session");
    } catch {
      showLogin();
      return;
    }
    await showApp();
  })();
})();
