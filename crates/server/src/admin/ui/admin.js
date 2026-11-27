/* DropDrawer Admin console.
 *
 * Rendering rule: every node is built with DOM APIs (h()) and text goes through
 * textContent. Nothing here uses innerHTML, so user-controlled values (names,
 * emails, file names) can never be parsed as markup. The server's CSP forbids
 * inline script as a second line of defence.
 */
"use strict";
(() => {
  // Strings and locale come from admin-i18n.js, loaded first.
  const { t, locale: LOCALE } = window.DDI18n;
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
  // Theme (auto / light / dark) & mobile navigation drawer
  // ---------------------------------------------------------------------------
  const THEME_KEY = "dd_admin_theme";
  const THEME_ORDER = ["auto", "light", "dark"];
  const THEME_META = {
    auto: { label: t("跟随系统"), icon: "monitor" },
    light: { label: t("浅色模式"), icon: "sun" },
    dark: { label: t("深色模式"), icon: "moon" },
  };
  const systemDarkQuery = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;

  function storedTheme() {
    try {
      const v = localStorage.getItem(THEME_KEY);
      return THEME_ORDER.includes(v) ? v : "auto";
    } catch {
      return "auto";
    }
  }

  function resolvedTheme(pref = storedTheme()) {
    if (pref === "light" || pref === "dark") return pref;
    return systemDarkQuery && !systemDarkQuery.matches ? "light" : "dark";
  }

  function syncThemeControls(pref, resolved) {
    const meta = THEME_META[pref] || THEME_META.auto;
    const loginBtn = $("loginThemeBtn");
    if (loginBtn) {
      replace(loginBtn, icon(meta.icon), h("span", { text: meta.label }));
      loginBtn.title = t("当前：{label}（点击切换）", { label: meta.label });
    }
    const mobileBtn = $("mobileThemeBtn");
    if (mobileBtn) {
      replace(mobileBtn, icon(meta.icon));
      mobileBtn.title = t("当前：{label}（点击切换）", { label: meta.label });
    }
    const sw = $("sidebarThemeSwitch");
    if (sw) {
      for (const b of sw.querySelectorAll("button[data-theme-choice]")) {
        const active = b.dataset.themeChoice === pref;
        b.classList.toggle("active", active);
        b.setAttribute("aria-pressed", active ? "true" : "false");
      }
    }
    const metaTheme = document.querySelector('meta[name="theme-color"]');
    if (metaTheme) metaTheme.setAttribute("content", resolved === "light" ? "#f4f6fa" : "#07090e");
  }

  function applyTheme(pref, { persist = true, syncTurnstile = true } = {}) {
    if (!THEME_ORDER.includes(pref)) pref = "auto";
    if (persist) {
      try { localStorage.setItem(THEME_KEY, pref); } catch { /* ignore */ }
    }
    const resolved = resolvedTheme(pref);
    document.documentElement.dataset.theme = resolved;
    syncThemeControls(pref, resolved);
    if (syncTurnstile && typeof rerenderTurnstileForTheme === "function") rerenderTurnstileForTheme();
  }

  function cycleTheme() {
    const cur = storedTheme();
    const next = THEME_ORDER[(THEME_ORDER.indexOf(cur) + 1) % THEME_ORDER.length];
    applyTheme(next);
  }

  function setMobileNavOpen(open) {
    const sidebar = $("sidebar");
    const scrim = $("sidebarScrim");
    const menuBtn = $("mobileMenuBtn");
    if (!sidebar || !scrim) return;
    sidebar.classList.toggle("open", open);
    scrim.hidden = !open;
    document.body.classList.toggle("nav-open", open);
    if (menuBtn) menuBtn.setAttribute("aria-expanded", open ? "true" : "false");
  }

  if (systemDarkQuery && systemDarkQuery.addEventListener) {
    systemDarkQuery.addEventListener("change", () => {
      if (storedTheme() === "auto") applyTheme("auto", { persist: false });
    });
  }

  // Initialize theme immediately before first paint of views.
  applyTheme(storedTheme(), { persist: false, syncTurnstile: false });

  if ($("loginThemeBtn")) $("loginThemeBtn").addEventListener("click", cycleTheme);
  if ($("mobileThemeBtn")) $("mobileThemeBtn").addEventListener("click", cycleTheme);
  if ($("sidebarThemeSwitch")) {
    $("sidebarThemeSwitch").addEventListener("click", (e) => {
      const btnEl = e.target.closest("button[data-theme-choice]");
      if (btnEl) applyTheme(btnEl.dataset.themeChoice);
    });
  }
  if ($("mobileMenuBtn")) $("mobileMenuBtn").addEventListener("click", () => setMobileNavOpen(true));
  if ($("sidebarCloseBtn")) $("sidebarCloseBtn").addEventListener("click", () => setMobileNavOpen(false));
  if ($("sidebarScrim")) $("sidebarScrim").addEventListener("click", () => setMobileNavOpen(false));
  if ($("nav")) {
    $("nav").addEventListener("click", (e) => {
      if (e.target.closest("a.nav-item")) setMobileNavOpen(false);
    });
  }
  if ($("meLink")) $("meLink").addEventListener("click", () => setMobileNavOpen(false));
  if ($("toggleLoginPassword")) {
    $("toggleLoginPassword").addEventListener("click", () => {
      const pwd = $("loginPassword");
      const btnEl = $("toggleLoginPassword");
      const show = pwd.type === "password";
      pwd.type = show ? "text" : "password";
      btnEl.setAttribute("aria-label", show ? t("隐藏密码") : t("显示密码"));
      replace(btnEl, icon(show ? "eye-off" : "eye"));
    });
  }

  // ---------------------------------------------------------------------------
  // Formatting
  // ---------------------------------------------------------------------------
  const nf = new Intl.NumberFormat(LOCALE);
  const rtf = new Intl.RelativeTimeFormat(LOCALE, { numeric: "auto" });
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
    const ts = new Date(iso).getTime();
    if (isNaN(ts)) return String(iso);
    const diff = (ts - Date.now()) / 1000;
    const abs = Math.abs(diff);
    if (abs < 45) return rtf.format(0, "second");
    if (abs < 3600) return rtf.format(Math.round(diff / 60), "minute");
    if (abs < 86400) return rtf.format(Math.round(diff / 3600), "hour");
    if (abs < 86400 * 30) return rtf.format(Math.round(diff / 86400), "day");
    return fmtDate(iso);
  }

  function fmtDuration(secs) {
    secs = Math.max(0, Math.floor(secs || 0));
    const d = Math.floor(secs / 86400);
    const hh = Math.floor((secs % 86400) / 3600);
    const mm = Math.floor((secs % 3600) / 60);
    if (d > 0) return t("{d} 天 {hh} 小时", { d, hh });
    if (hh > 0) return t("{hh} 小时 {mm} 分钟", { hh, mm });
    return t("{mm} 分钟", { mm });
  }

  function fmtHours(h) {
    if (!h) return t("不限");
    if (h % 24 === 0) return t("{n} 天", { n: h / 24 });
    return t("{n} 小时", { n: h });
  }

  const initials = (name) => (String(name || "?").trim()[0] || "?").toUpperCase();

  const KIND_LABELS = {
    local: t("服务器本地"),
    google_drive: "Google Drive",
    quark: t("夸克网盘"),
    baidu_netdisk: t("百度网盘"),
    web_dav: "WebDAV",
    s3: t("S3 兼容存储"),
  };
  const KIND_DESC = {
    local: t("文件存放在本服务器磁盘，受配额限制"),
    google_drive: t("用户授权自己的 Google Drive"),
    quark: t("使用夸克网盘 Cookie 接入"),
    baidu_netdisk: t("百度网盘开放平台 OAuth"),
    web_dav: t("任意 WebDAV 服务（NAS、Nextcloud 等）"),
    s3: t("AWS S3、Cloudflare R2、MinIO、阿里云 OSS 等"),
  };
  const PLATFORM_LABELS = { macos: "macOS", windows: "Windows", linux: "Linux", android: "Android", ios: "iOS", web: "Web" };
  const MODE_LABELS = { p2p_only: t("仅 P2P"), cloud_cached: t("云端缓存"), server_relay: t("服务器中转") };

  const AUDIT_LABELS = {
    "admin.login": t("管理员登录"),
    "admin.login_failed": t("管理员登录失败"),
    "admin.logout": t("退出管理端"),
    "settings.update": t("修改服务器设置"),
    "smtp.test": t("发送测试邮件"),
    "user.disable": t("禁用账号"),
    "user.enable": t("解封账号"),
    "user.reset_password": t("重置密码"),
    "user.sign_out": t("强制下线"),
    "user.policy": t("修改用户策略"),
    "user.delete": t("删除账号"),
    "user.revoke_shares": t("吊销用户全部外链"),
    "device.remove": t("移除设备"),
    "backend.remove": t("移除存储"),
    "item.remove": t("删除抽屉条目"),
    "invite.create": t("生成邀请码"),
    "invite.delete": t("删除邀请码"),
    "share.revoke": t("吊销外链"),
    "maintenance.cleanup": t("清理过期条目"),
    "maintenance.backup": t("下载数据库备份"),
    "admin.change_password": t("修改自己的密码"),
    "admin.totp_enable": t("开启两步验证"),
    "admin.totp_disable": t("关闭两步验证"),
    "admin_account.create": t("创建管理员"),
    "admin_account.update": t("修改管理员"),
    "admin_account.reset_password": t("重置管理员密码"),
    "admin_account.reset_totp": t("重置管理员两步验证"),
    "admin_account.delete": t("删除管理员"),
  };
  const SETTING_LABELS = {
    registration_mode: t("注册模式"),
    password_login_enabled: t("密码登录"),
    email_verification_required: t("邮箱验证"),
    email_allowed_domains: t("域名白名单"),
    email_blocked_domains: t("域名黑名单"),
    local_max_file_bytes: t("单文件上限"),
    default_user_local_quota_bytes: t("默认配额"),
    google: t("Google 登录"),
    smtp: "SMTP",
    features: t("功能开关"),
    share_policy: t("外链策略"),
    storage_policy: t("存储策略"),
    limits: t("用量限制"),
    announcement: t("全站公告"),
    client_policy: t("客户端版本"),
    "google.client_secret": t("Google 密钥"),
    "smtp.password": t("SMTP 密码"),
  };
  const auditDangerous = (a) => /failed|delete|disable|remove|revoke/.test(a);

  function auditDetail(entry) {
    if (!entry.detail) return "";
    if (entry.action === "settings.update") {
      return entry.detail.split(",").map((k) => SETTING_LABELS[k] || k).join(t("、"));
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
    const opts = { method, credentials: "same-origin", headers: { "Accept-Language": LOCALE } };
    if (body !== undefined) {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    const resp = await fetch(path, opts);
    const text = await resp.text();
    if (resp.status === 401 && !path.endsWith("/login") && !path.endsWith("/session") && !path.endsWith("/google/totp")) {
      showLogin(t("登录已过期，请重新登录"));
      throw new ApiError(401, t("管理员会话已失效"));
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

  function table(columns, rows, { onRowClick, emptyIcon = "search", emptyText = t("暂无数据") } = {}) {
    if (!rows.length) return h("div", { class: "table-card" }, empty(emptyIcon, emptyText));
    return h("div", { class: "table-card" }, h("div", { class: "table-scroll" },
      h("table", { class: "table" },
        h("thead", null, h("tr", null, columns.map((c) => h("th", { class: c.cls || null }, c.label)))),
        h("tbody", null, rows.map((r) => {
          const tr = h("tr", { class: onRowClick ? "clickable" : null },
            columns.map((c) => h("td", {
              class: c.cls || null,
              // Narrow screens show each row as a card, labelling every value.
              "data-label": typeof c.label === "string" ? c.label : "",
            }, c.render(r))));
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
    if (e.key === "Escape") {
      if (overlayStack.length) closeOverlay(overlayStack[overlayStack.length - 1]);
      else setMobileNavOpen(false);
    }
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

  async function confirmDialog(title, message, { confirmText = t("确认"), danger = false } = {}) {
    const result = await dialog({
      title,
      body: h("p", { text: message }),
      actions: [{ label: t("取消"), value: false, kind: "ghost" }, { label: confirmText, value: true, kind: danger ? "danger" : "primary" }],
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
    secrets: { google: "", smtp: "", turnstile: "" },
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
    return Object.values(S.secrets).some(Boolean) || JSON.stringify(S.draft) !== JSON.stringify(S.settings);
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
        admin_enabled: d.google.admin_enabled,
        client_id: d.google.client_id,
        client_secret: S.secrets.google || null,
        redirect_uri: d.google.redirect_uri,
      },
      admin_turnstile: {
        enabled: d.admin_turnstile.enabled,
        site_key: d.admin_turnstile.site_key,
        secret_key: S.secrets.turnstile || null,
        hostname: d.admin_turnstile.hostname,
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
    S.secrets = { google: "", smtp: "", turnstile: "" };
    updateSavebar();
  }

  async function saveSettings() {
    const button = $("saveBtn");
    const saved = await run(button, () => api("/api/admin/settings", { method: "PUT", body: buildSettingsPayload() }), t("设置已保存并立即生效"));
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
    toast(t("已放弃未保存的更改"));
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
      placeholder: saved ? t("已保存 · 留空表示不修改") : placeholder,
      id: "secret-" + key,
    });
    input.addEventListener("input", () => { S.secrets[key] = input.value; updateSavebar(); });
    return input;
  }

  /** Numeric input bound to a draft path. `scale` converts display units to stored units. */
  function draftNumber(path, { unit, scale = 1, placeholder = t("不限"), min = 0, step = "any" } = {}) {
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
    overview: { group: null, label: t("总览"), icon: "overview", title: t("总览"), desc: t("服务器运行状态与关键指标"), render: renderOverview },
    access: { group: t("配置"), label: t("注册与登录"), icon: "key", title: t("注册与登录"), desc: t("控制谁能注册、用什么方式登录，修改保存后立即对所有客户端生效"), render: renderAccess, settings: true },
    features: { group: t("配置"), label: t("功能与限额"), icon: "sliders", title: t("功能与限额"), desc: t("开关服务器功能、限制存储类型并设置每个用户的用量上限"), render: renderFeatures, settings: true },
    mail: { group: t("配置"), label: t("邮件服务"), icon: "mail", title: t("邮件服务"), desc: t("SMTP 发信用于注册验证码与找回密码"), render: renderMail, settings: true },
    users: { group: t("管理"), label: t("用户"), icon: "users", title: t("用户"), desc: t("账号状态、会话、设备、存储与个人策略"), render: renderUsers, count: () => S.users.length },
    shares: { group: t("管理"), label: t("公网外链"), icon: "link", title: t("公网外链"), desc: t("审查全站外链并一键吊销"), render: renderShares, count: () => S.shares.length },
    clients: { group: t("配置"), label: t("客户端与公告"), icon: "megaphone", title: t("客户端与公告"), desc: t("向所有客户端发布公告，查看版本分布并设置最低版本"), render: renderClients, settings: true },
    audit: { group: t("管理"), label: t("审计日志"), icon: "log", title: t("审计日志"), desc: t("管理员的每一次操作都会记录在这里（保留最近 5000 条）"), render: renderAudit },
    admins: { group: t("管理"), label: t("管理员"), icon: "badge", title: t("管理员"), desc: t("创建管理员账号、分配角色，并查看两步验证状态"), render: renderAdmins, superOnly: true },
    me: { group: null, hidden: true, label: t("我的账号"), icon: "badge", title: t("我的账号"), desc: t("修改密码与两步验证"), render: renderMe },
  };
  // Keep the sidebar grouped: configuration pages first, then management.
  const NAV_ORDER = ["overview", "access", "features", "mail", "clients", "users", "shares", "admins", "audit"];

  const isSuper = () => S.session && S.session.role === "super";
  const isReadonly = () => S.session && S.session.role === "viewer";
  const ROLE_LABELS = { super: t("超级管理员"), admin: t("管理员"), viewer: t("只读") };

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
      $("meName").textContent = S.session.actor;
      $("meRole").textContent = (ROLE_LABELS[S.session.role] || S.session.role) + (S.session.totp_enabled ? t(" · 两步验证") : "");
      $("meAvatar").textContent = initials(S.session.actor);
      $("meLink").classList.toggle("active", S.page === "me");
    }
    if (S.system) {
      replace($("serverChip"), h("span", { class: "dot ok" }), h("span", { text: t("v{version} · 已运行 {v}", { version: S.system.version, v: fmtDuration(S.system.uptime_secs) }) }));
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
      node.prepend(h("div", { class: "callout readonly-banner" }, icon("eye"), h("div", { text: t("你是只读管理员：可以查看所有数据，但不能修改设置或执行管理操作。") })));
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
    setActions(btn(t("刷新"), { iconName: "refresh", onclick: (e) => refreshAll(e.currentTarget, true) }));
    const o = S.overview;
    const sys = S.system;
    const st = S.settings;
    if (!o || !st) return h("div", { class: "page" }, h("div", { class: "skeleton" }));

    const kpi = (iconName, label, value, unit, sub) => h("div", { class: "kpi" },
      h("div", { class: "kpi-label" }, icon(iconName), label),
      h("div", { class: "kpi-value" }, value, unit ? h("small", { text: unit }) : null),
      h("div", { class: "kpi-sub", text: sub }));

    const kpis = h("div", { class: "kpis" },
      kpi("users", t("注册用户"), fmtNum(o.total_users), null,
        t("近 7 天新增 {v}", { v: fmtNum(o.new_users_7d) }) + (o.disabled_users ? t(" · 已禁用 {v}", { v: fmtNum(o.disabled_users) }) : "")),
      kpi("monitor", t("在线用户"), fmtNum(o.online_users), null, t("{v} 个连接 · 登记设备 {v2} 台", { v: fmtNum(o.online_connections), v2: fmtNum(o.total_devices) })),
      kpi("file", t("抽屉条目"), fmtNum(o.total_items), null, t("共 {v} · 云端 {v2}", { v: fmtBytes(o.total_item_bytes), v2: fmtBytes(o.cloud_item_bytes) })),
      kpi("link", t("公网外链"), fmtNum(o.total_shares), null, t("累计下载 {v} 次", { v: fmtNum(o.total_share_downloads) })),
      kpi("database", t("存储后端"), fmtNum(o.total_backends), null, t("24 小时内到期 {v} 项", { v: fmtNum(o.items_expiring_24h) })));

    const regLabel = { open: t("开放注册"), invite_only: t("仅限邀请码"), closed: t("已关闭") }[st.registration_mode];
    const policy = (label, value, state, page) => h("button", { class: "policy-item", type: "button", onclick: () => { location.hash = "#/" + page; } },
      h("span", { class: "dot " + state }), h("span", { class: "label", text: label }), h("span", { class: "value", text: value }), icon("arrow-right", "faint"));
    const f = st.features;
    const policies = h("div", { class: "card" },
      h("div", { class: "card-head" }, h("div", null, h("h2", { text: t("当前生效的策略") }), h("p", { text: t("修改后立即对所有客户端生效") }))),
      h("div", { class: "policy-list" },
        policy(t("新用户注册"), regLabel, st.registration_mode === "closed" ? "danger" : st.registration_mode === "invite_only" ? "warn" : "ok", "access"),
        policy(t("账号密码登录"), st.password_login_enabled ? t("开启") : t("关闭"), st.password_login_enabled ? "ok" : "", "access"),
        policy(t("Google 登录"), st.google.enabled ? (f.google_signup_enabled ? t("开启 · 允许自动建号") : t("开启 · 仅已有账号")) : t("未启用"), st.google.enabled ? "accent" : "", "access"),
        policy(t("邮箱找回密码"), f.password_reset_enabled ? (sys && sys.smtp_ready ? t("开启") : t("开启 · SMTP 未就绪")) : t("关闭"), f.password_reset_enabled && sys && sys.smtp_ready ? "ok" : f.password_reset_enabled ? "warn" : "", "access"),
        policy(t("云端中转上传"), f.cloud_upload_enabled ? t("开启") : t("关闭（仅 P2P）"), f.cloud_upload_enabled ? "ok" : "warn", "features"),
        policy(t("公网外链"), !f.share_access_enabled ? t("访问已暂停") : f.share_create_enabled ? t("开启") : t("禁止新建"), !f.share_access_enabled ? "danger" : f.share_create_enabled ? "ok" : "warn", "features"),
        policy(t("存储类型"), st.storage_policy.disabled_backend_kinds.length ? t("已停用 {disabled_backend_kindsLength} 种", { disabled_backend_kindsLength: st.storage_policy.disabled_backend_kinds.length }) : t("全部可用"), st.storage_policy.disabled_backend_kinds.length ? "warn" : "ok", "features"),
        policy(t("内网地址拦截"), st.storage_policy.block_private_endpoints ? t("开启") : t("关闭"), st.storage_policy.block_private_endpoints ? "ok" : "", "features")));

    const total = o.backend_kinds.reduce((s, k) => s + k.count, 0);
    const maxCount = Math.max(1, ...o.backend_kinds.map((k) => k.count));
    const kinds = h("div", { class: "card" },
      h("div", { class: "card-head" }, h("div", null, h("h2", { text: t("存储类型分布") }), h("p", { text: t("按后端数量统计，悬停查看占比") }))),
      o.backend_kinds.length
        ? h("div", { class: "bars", role: "list" }, o.backend_kinds.map((k) => {
          const pct = Math.round((k.count / total) * 100);
          const fill = h("div", { class: "bar-fill" });
          fill.style.width = Math.max(3, (k.count / maxCount) * 100) + "%";
          return h("div", { class: "bar-row", role: "listitem", title: t("{v}：{kCount} 个后端（{pct}%）", { v: KIND_LABELS[k.kind] || k.kind, kCount: k.count, pct }) },
            h("span", { class: "name", text: KIND_LABELS[k.kind] || k.kind }),
            h("div", { class: "bar-track" }, fill),
            h("span", { class: "val", text: fmtNum(k.count) }));
        }))
        : empty("database", t("还没有用户添加存储后端")));

    const sysCard = h("div", { class: "card" },
      h("div", { class: "card-head" }, h("div", null, h("h2", { text: t("系统") }))),
      sys ? h("dl", { class: "kv" },
        h("dt", { text: t("版本") }), h("dd", { text: `v${sys.version}` }),
        h("dt", { text: t("平台") }), h("dd", { text: `${sys.os} / ${sys.arch}` }),
        h("dt", { text: t("已运行") }), h("dd", { text: fmtDuration(sys.uptime_secs) }),
        h("dt", { text: t("数据库") }), h("dd", { text: fmtBytes(sys.database_bytes) }),
        h("dt", { text: t("本地存储") }), h("dd", { text: sys.local_storage_bytes == null ? t("文件过多，未统计") : t("{v} · {v2} 个文件", { v: fmtBytes(sys.local_storage_bytes), v2: fmtNum(sys.local_storage_files) }) }),
        h("dt", { text: t("存储目录") }), h("dd", { class: "mono", text: sys.local_storage_dir }),
        h("dt", { text: "SMTP" }), h("dd", null, sys.smtp_ready ? pill(t("就绪"), "ok") : pill(t("未配置"))))
        : h("div", { class: "skeleton" }));

    const recent = h("div", { class: "card" },
      h("div", { class: "card-head" },
        h("div", null, h("h2", { text: t("最近操作") })),
        h("a", { class: "btn ghost sm", href: "#/audit" }, t("全部"), icon("arrow-right"))),
      o.recent_audit.length
        ? h("div", { class: "timeline" }, o.recent_audit.map((e) => h("div", { class: "timeline-item" },
          h("span", { class: "dot " + (auditDangerous(e.action) ? "danger" : "accent") }),
          h("div", { class: "what" }, h("b", { text: AUDIT_LABELS[e.action] || e.action }), e.target ? h("span", { text: " · " + e.target }) : null),
          h("span", { class: "when", title: fmtDate(e.at), text: fmtRel(e.at) }))))
        : empty("log", t("暂无操作记录")));

    const maintenance = h("div", { class: "card" },
      h("div", { class: "card-head" }, h("div", null, h("h2", { text: t("维护") }), h("p", { text: t("过期条目会按服务端的清理周期自动删除，也可以现在执行一次") }))),
      btn(t("立即清理过期条目"), {
        iconName: "broom",
        onclick: async (e) => {
          const r = await run(e.currentTarget, () => api("/api/admin/maintenance/cleanup", { method: "POST" }));
          if (r) { toast(r.cleaned ? t("已清理 {cleaned} 个过期条目", { cleaned: r.cleaned }) : t("没有需要清理的过期条目")); refreshAll(); }
        },
      }),
      isSuper() ? h("div", { class: "toolbar" },
        h("a", { class: "btn", href: "/api/admin/maintenance/backup", download: "" }, icon("download"), t("下载数据库备份")),
        h("span", { class: "meta", text: t("包含账号与存储凭据，请妥善保管；不含文件本体") })) : null);
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
        title: t("允许新用户注册"),
        desc: t("关闭后注册入口从所有客户端隐藏，已有账号不受影响。"),
        control: switchEl({ id: "reg-open", checked: regOpen, label: t("允许新用户注册"), onchange: (v) => setReg(v, d.registration_mode === "invite_only") }),
      }),
      row({
        title: t("需要邀请码"),
        desc: t("注册时必须填写下方生成的有效邀请码。"),
        disabled: !regOpen,
        control: switchEl({ id: "reg-invite", checked: d.registration_mode === "invite_only", disabled: !regOpen, label: t("需要邀请码"), onchange: (v) => setReg(true, v) }),
      }),
      row({
        title: t("注册必须验证邮箱"),
        desc: t("注册时发送 6 位验证码到邮箱，需要先配置邮件服务。"),
        badges: !smtpReady ? pill(t("SMTP 未就绪"), "warn") : null,
        control: draftSwitch("email_verification_required", { label: t("注册必须验证邮箱") }),
      }),
      h("div", { class: "row stack" },
        h("div", { class: "fields" },
          field(t("允许的邮箱域名（留空不限）"), domainArea("email_allowed_domains", "company.com, edu.cn")),
          field(t("禁止的邮箱域名"), domainArea("email_blocked_domains", "tempmail.com")))));

    const google = d.google;
    const login = h("div", { class: "group" },
      row({ title: t("账号密码登录"), desc: t("关闭后只能使用 Google 等第三方方式登录，至少要保留一种登录方式。"), control: draftSwitch("password_login_enabled", { label: t("账号密码登录") }) }),
      row({ title: t("邮箱找回密码"), desc: t("允许用户通过邮箱验证码自助重置密码，重置后该账号的其他会话会全部下线。"), badges: !smtpReady ? pill(t("SMTP 未就绪"), "warn") : null, control: draftSwitch("features.password_reset_enabled", { label: t("邮箱找回密码") }) }),
      row({ title: t("客户端 Google 登录"), desc: t("在 DropDrawer 客户端显示 Google 登录入口。"), control: draftSwitch("google.enabled", { rerender: true, label: t("客户端 Google 登录") }) }),
      isSuper() ? row({ title: t("管理端 Google 登录"), desc: t("使用与现有管理员用户名相同的 Gmail 或 Google Workspace 邮箱登录。"), control: draftSwitch("google.admin_enabled", { rerender: true, label: t("管理端 Google 登录") }) }) : null,
      isSuper() && (google.enabled || google.admin_enabled) ? h("div", { class: "row stack sub" },
        h("div", { class: "fields" },
          field("Client ID", draftText("google.client_id", { placeholder: "xxxx.apps.googleusercontent.com" })),
          field("Client Secret", secretInput("google", google.has_client_secret, "GOCSPX-…"), google.has_client_secret ? pill(t("已保存"), "ok") : null)),
        field(t("Redirect URI（需以 /api/auth/google/callback 结尾）"), draftText("google.redirect_uri", { placeholder: "https://drop.example.com/api/auth/google/callback" }))) : null,
      row({
        title: t("Google 首次登录自动创建账号"),
        desc: t("关闭后只有已绑定 Google 的账号能登录。自动建号同样受注册开关与邮箱域名规则约束。"),
        disabled: !google.enabled,
        control: draftSwitch("features.google_signup_enabled", { disabled: !google.enabled, label: t("Google 自动创建账号") }),
      }));

    const turnstile = d.admin_turnstile;
    const adminSecurity = isSuper() ? h("div", { class: "group" },
      row({ title: "Cloudflare Turnstile", desc: t("管理台使用密码或 Google 登录前，须通过人机验证。"), control: draftSwitch("admin_turnstile.enabled", { rerender: true, label: "Cloudflare Turnstile" }) }),
      turnstile.enabled ? h("div", { class: "row stack sub" },
        h("div", { class: "fields" },
          field(t("站点密钥"), draftText("admin_turnstile.site_key")),
          field(t("服务端密钥"), secretInput("turnstile", turnstile.has_secret_key, t("留空保留已保存密钥")))),
        field(t("主机名"), draftText("admin_turnstile.hostname", { placeholder: location.hostname }))) : null) : null;

    return h("div", { class: "page" },
      sectionTitle(t("新用户注册")), registration,
      sectionTitle(t("登录方式")), login,
      adminSecurity ? sectionTitle(t("管理端人机验证")) : null, adminSecurity,
      sectionTitle(t("邀请码"), t("注册需要邀请码时使用；可设置使用次数与有效期")), renderInvites());
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
    if (inv.expires_at && new Date(inv.expires_at) <= new Date()) return pill(t("已过期"), "danger");
    if (inv.used_count >= inv.max_uses) return pill(t("已用完"));
    return pill(t("可用"), "ok");
  }

  function renderInvites() {
    const form = S.inviteForm;
    const note = h("input", { class: "input", placeholder: t("例如：研发团队"), value: form.note, id: "inv-note" });
    note.addEventListener("input", () => { form.note = note.value; });
    const uses = h("input", { class: "input", type: "number", min: 1, value: form.max_uses, id: "inv-uses" });
    uses.addEventListener("input", () => { form.max_uses = Math.max(1, parseInt(uses.value, 10) || 1); });
    const hours = h("input", { class: "input", type: "number", min: 0, value: form.expires_hours, placeholder: t("0 = 永久"), id: "inv-hours" });
    hours.addEventListener("input", () => { form.expires_hours = Math.max(0, parseInt(hours.value, 10) || 0); });

    const create = btn(t("生成邀请码"), {
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
          copyText(rec.code, t("已生成并复制邀请码 {code}", { code: rec.code }));
        }
      },
    });

    const list = table([
      { label: t("邀请码"), render: (i) => h("span", { class: "code-chip", text: i.code }) },
      { label: t("备注"), render: (i) => h("span", { class: i.note ? null : "faint", text: i.note || "—" }) },
      { label: t("使用"), cls: "num", render: (i) => `${i.used_count} / ${i.max_uses}` },
      { label: t("有效期至"), render: (i) => h("span", { class: "nowrap", text: i.expires_at ? fmtDate(i.expires_at) : t("永久") }) },
      { label: t("状态"), render: inviteStatus },
      {
        label: "", cls: "actions", render: (i) => [
          btn("", { size: "sm", iconName: "copy", title: t("复制邀请码"), onclick: () => copyText(i.code) }),
          btn("", {
            size: "sm", kind: "danger", iconName: "trash", title: t("删除邀请码"),
            onclick: async (e) => {
              if (!(await confirmDialog(t("删除邀请码"), t("删除后 {code} 立即失效。", { code: i.code }), { confirmText: t("删除"), danger: true }))) return;
              if ((await run(e.currentTarget, () => api("/api/admin/invites/" + encodeURIComponent(i.code), { method: "DELETE" }), t("邀请码已删除"))) !== undefined) {
                S.invites = await api("/api/admin/invites");
                renderPage({ keepScroll: true });
              }
            },
          }),
        ],
      },
    ], S.invites, { emptyIcon: "ticket", emptyText: t("还没有邀请码") });

    return h("div", { class: "page" },
      h("div", { class: "card" }, h("div", { class: "inline-form" },
        field(t("备注（可选）"), note), field(t("可用次数"), uses), field(t("有效期（小时）"), hours), create)),
      list);
  }

  async function copyText(text, message) {
    try {
      await navigator.clipboard.writeText(text);
      toast(message || t("已复制到剪贴板"));
    } catch {
      toast(t("复制失败，请手动选择复制"), "err");
    }
  }

  // Features & limits ----------------------------------------------------------
  function renderFeatures() {
    const d = S.draft;
    if (!d) return h("div", { class: "page" });
    const f = d.features;

    const transfer = h("div", { class: "group" },
      row({ title: t("云端中转上传"), desc: t("允许把文件上传到服务器本地或云盘。关闭后只能在在线设备之间 P2P 直传，已上传的文件仍可下载。"), control: draftSwitch("features.cloud_upload_enabled", { label: t("云端中转上传") }) }),
      row({ title: t("创建公网外链"), desc: t("允许用户为抽屉里的文件生成公开下载链接。"), control: draftSwitch("features.share_create_enabled", { rerender: true, label: t("创建公网外链") }) }),
      row({ title: t("公网外链访问"), desc: t("关闭后所有已有外链暂时无法打开，重新开启即可恢复。"), badges: !f.share_access_enabled ? pill(t("已暂停"), "danger") : null, control: draftSwitch("features.share_access_enabled", { rerender: true, label: t("公网外链访问") }) }),
      row({ title: t("外链必须设置提取码"), disabled: !f.share_create_enabled, control: draftSwitch("share_policy.require_passcode", { disabled: !f.share_create_enabled, label: t("外链必须设置提取码") }) }),
      row({ title: t("外链最长有效期"), desc: t("用户设置更长或选择永久时会按此上限创建。"), disabled: !f.share_create_enabled, control: draftNumber("share_policy.max_expires_hours", { unit: t("小时"), step: 1 }) }),
      row({ title: t("单个外链最多下载次数"), disabled: !f.share_create_enabled, control: draftNumber("share_policy.max_downloads_cap", { unit: t("次"), step: 1 }) }));

    const disabledKinds = new Set(d.storage_policy.disabled_backend_kinds);
    const kinds = h("div", { class: "group" },
      Object.keys(KIND_LABELS).map((kind) => row({
        title: KIND_LABELS[kind],
        desc: KIND_DESC[kind],
        control: switchEl({
          id: "kind-" + kind,
          checked: !disabledKinds.has(kind),
          label: t("允许 ") + KIND_LABELS[kind],
          onchange: (on) => {
            const next = new Set(S.draft.storage_policy.disabled_backend_kinds);
            if (on) next.delete(kind); else next.add(kind);
            setDraft("storage_policy.disabled_backend_kinds", Object.keys(KIND_LABELS).filter((k) => next.has(k)));
          },
        }),
      })),
      row({
        title: t("拦截内网存储地址"),
        desc: t("拒绝指向 127.0.0.1、10.x、192.168.x、169.254.x 等内网或本机地址的 WebDAV / S3，防止服务器被用来探测内网。在局域网内自用 NAS 的部署请保持关闭。"),
        control: draftSwitch("storage_policy.block_private_endpoints", { label: t("拦截内网存储地址") }),
      }));

    const MB = 1024 * 1024;
    const GB = 1024 * MB;
    const limits = h("div", { class: "group" },
      row({ title: t("单文件上传上限"), desc: t("仅限制上传到服务器本地存储的文件。"), control: draftNumber("local_max_file_bytes", { unit: "MB", scale: MB }) }),
      row({ title: t("每个用户的本地存储配额"), desc: t("服务器本地磁盘的总配额，可在用户详情里单独调整。"), control: draftNumber("default_user_local_quota_bytes", { unit: "GB", scale: GB }) }),
      row({ title: t("每个用户最多设备数"), desc: t("超出后新设备无法登记，已登记的设备不受影响。"), control: draftNumber("limits.max_devices_per_user", { unit: t("台"), step: 1 }) }),
      row({ title: t("每个用户最多抽屉条目"), control: draftNumber("limits.max_items_per_user", { unit: t("项"), step: 1 }) }),
      row({ title: t("条目默认保留时长"), desc: t("客户端没有指定时使用，留空为 7 天（168 小时）。"), control: draftNumber("limits.default_item_ttl_hours", { unit: t("小时"), step: 1, placeholder: "168" }) }),
      row({ title: t("条目最长保留时长"), desc: t("到期后自动删除，客户端设置更长时按此上限。"), control: draftNumber("limits.max_item_ttl_hours", { unit: t("小时"), step: 1 }) }));

    return h("div", { class: "page" },
      sectionTitle(t("传输与分享")), transfer,
      sectionTitle(t("允许的存储类型"), t("停用后无法新增该类型，也不能再上传到已有的该类后端，已存文件仍可下载")), kinds,
      sectionTitle(t("配额与限制"), t("留空或填 0 表示不限")), limits);
  }

  // Mail ------------------------------------------------------------------------
  function renderMail() {
    const d = S.draft;
    if (!d) return h("div", { class: "page" });
    const smtp = d.smtp;
    const security = h("select", { class: "select", id: "smtp-security" },
      [["start_tls", t("STARTTLS（587）")], ["tls", t("SSL / TLS（465）")], ["none", t("不加密（25）")]].map(([v, l]) => h("option", { value: v, selected: smtp.security === v }, l)));
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
    const sendTest = btn(t("发送测试邮件"), {
      iconName: "mail",
      onclick: (e) => {
        if (!S.testEmailTo) { toast(t("请先填写收件邮箱"), "err"); testTo.focus(); return; }
        const payload = buildSettingsPayload().smtp;
        run(e.currentTarget, () => api("/api/admin/smtp/test", { method: "POST", body: { to: S.testEmailTo, smtp: payload } }), t("测试邮件已发出，请查收"));
      },
    });

    return h("div", { class: "page" },
      h("div", { class: "group" },
        row({ title: t("启用 SMTP 发信"), desc: t("开启后可使用注册邮箱验证与邮箱找回密码。"), control: draftSwitch("smtp.enabled", { rerender: true, label: t("启用 SMTP 发信") }) }),
        h("div", { class: "row stack" + (smtp.enabled ? "" : " disabled") },
          h("div", { class: "fields" },
            field(t("SMTP 主机"), draftText("smtp.host", { placeholder: "smtp.example.com" })),
            field(t("加密方式"), security),
            field(t("端口"), port),
            field(t("用户名"), draftText("smtp.username", { placeholder: "noreply@example.com" })),
            field(t("密码 / 授权码"), secretInput("smtp", smtp.has_password, t("SMTP 密码")), smtp.has_password ? pill(t("已保存"), "ok") : null),
            field(t("发件人邮箱"), draftText("smtp.from_address", { placeholder: "noreply@example.com", type: "email" })),
            field(t("发件人名称"), draftText("smtp.from_name", { placeholder: "DropDrawer" }))))),
      sectionTitle(t("连通性测试"), t("使用当前表单里的配置发送（无需先保存）")),
      h("div", { class: "card" }, h("div", { class: "inline-form" },
        h("div", { class: "field" }, h("label", { text: t("收件邮箱") }), testTo), h("span"), h("span"), sendTest)));
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
    if (u.disabled) return pill(t("已禁用"), "danger");
    if (u.online_devices > 0) return pill(t("在线 · {online_devices}", { online_devices: u.online_devices }), "ok");
    return pill(t("离线"));
  }

  function renderUsers() {
    setActions(btn(t("刷新"), { iconName: "refresh", onclick: (e) => refreshUsers(e.currentTarget) }));
    const counts = {
      all: S.users.length,
      online: S.users.filter((u) => u.online_devices > 0).length,
      disabled: S.users.filter((u) => u.disabled).length,
      restricted: S.users.filter((u) => u.upload_blocked || u.share_blocked || u.local_quota_bytes != null).length,
    };
    const toolbar = h("div", { class: "toolbar" },
      searchBox(t("搜索用户名、邮箱或备注"), S.userQuery, (v) => { S.userQuery = v; updateTable(); }, "q-users"),
      segmented([["all", t("全部 {all}", { all: counts.all })], ["online", t("在线 {online}", { online: counts.online })], ["disabled", t("已禁用 {disabled}", { disabled: counts.disabled })], ["restricted", t("受限 {restricted}", { restricted: counts.restricted })]],
        S.userFilter, (v) => { S.userFilter = v; renderPage({ keepScroll: true }); }));

    const tableHost = h("div");
    function updateTable() {
      replace(tableHost, table([
        {
          label: t("用户"), render: (u) => h("div", { class: "user-cell" },
            h("div", { class: "avatar" + (u.disabled ? " muted" : "") , text: initials(u.username) }),
            h("div", { class: "truncate" },
              h("div", { class: "cell-main truncate", text: u.username }),
              h("div", { class: "cell-sub truncate", text: u.email || t("未绑定邮箱") }))),
        },
        {
          label: t("登录方式"), render: (u) => h("div", { class: "pills" },
            u.google_linked ? pill("Google", "accent", false) : pill(t("密码"), null, false),
            u.email_verified ? pill(t("邮箱已验证"), "ok", false) : null),
        },
        { label: t("在线 / 设备"), cls: "num", render: (u) => `${u.online_devices} / ${u.device_count}` },
        { label: t("条目 / 云端"), cls: "num", render: (u) => h("div", null, h("div", { text: fmtNum(u.item_count) }), h("div", { class: "cell-sub", text: fmtBytes(u.storage_bytes) })) },
        {
          label: t("限制"), render: (u) => {
            const tags = [];
            if (u.upload_blocked) tags.push(pill(t("禁止上传"), "warn", false));
            if (u.share_blocked) tags.push(pill(t("禁止外链"), "warn", false));
            if (u.local_quota_bytes != null) tags.push(pill(t("配额 ") + fmtBytes(u.local_quota_bytes), null, false));
            return tags.length ? h("div", { class: "pills" }, tags) : h("span", { class: "faint", text: "—" });
          },
        },
        { label: t("最近登录"), render: (u) => h("span", { class: "nowrap", title: u.last_login_at ? fmtDate(u.last_login_at) : null, text: u.last_login_at ? fmtRel(u.last_login_at) : "—" }) },
        { label: t("状态"), render: userStatus },
      ], S.users.filter(userMatches), { onRowClick: (u) => openUserDrawer(u.id), emptyIcon: "users", emptyText: S.users.length ? t("没有匹配的用户") : t("还没有注册用户") }));
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
      btn(t("强制下线"), {
        iconName: "power", size: "sm",
        onclick: async (e) => {
          if (!(await confirmDialog(t("强制下线"), t("「{username}」在所有设备上的登录会立即失效，需要重新登录。", { username: u.username }), { confirmText: t("强制下线") }))) return;
          if (await run(e.currentTarget, () => api(userPath + "/sign-out", { method: "POST" }), t("已强制下线"))) reloadDrawer();
        },
      }),
      btn(t("重置密码"), { iconName: "key", size: "sm", onclick: () => resetPasswordDialog(u) }),
      btn(u.disabled ? t("解封账号") : t("禁用账号"), {
        iconName: u.disabled ? "check" : "ban", size: "sm", kind: u.disabled ? null : "danger",
        onclick: async (e) => {
          const disable = !u.disabled;
          if (disable && !(await confirmDialog(t("禁用账号"), t("「{username}」将无法登录，在线设备立即断开，名下外链同时失效。", { username: u.username }), { confirmText: t("禁用"), danger: true }))) return;
          if (await run(e.currentTarget, () => api(userPath + "/disable", { method: "POST", body: { disabled: disable } }), disable ? t("账号已禁用") : t("账号已恢复"))) reloadDrawer();
        },
      }));

    const tabs = [
      ["overview", t("概况"), null],
      ["devices", t("设备"), detail.devices.length],
      ["storage", t("存储"), detail.backends.length],
      ["items", t("条目"), u.item_count],
      ["shares", t("外链"), detail.shares.length],
    ];
    const tabBar = h("div", { class: "tabs", role: "tablist" }, tabs.map(([key, label, count]) => h("button", {
      type: "button", role: "tab", class: tab === key ? "active" : null, "aria-selected": tab === key ? "true" : "false",
      onclick: () => { drawerState.tab = key; renderDrawer(); },
    }, label, count != null ? h("span", { class: "count", text: fmtNum(count) }) : null)));

    const body = { overview: drawerOverview, devices: drawerDevices, storage: drawerStorage, items: drawerItems, shares: drawerShares }[tab](detail, userPath);

    replace(drawerState.host,
      h("div", { class: "scrim", onclick: () => drawerState && drawerState.close() }),
      h("aside", { class: "drawer", role: "dialog", "aria-modal": "true", "aria-label": t("用户详情") },
        h("div", { class: "drawer-head" },
          h("div", { class: "drawer-title" },
            h("div", { class: "avatar lg" + (u.disabled ? " muted" : ""), text: initials(u.username) }),
            h("div", null,
              h("h2", { text: u.username }),
              h("div", { class: "sub", text: [u.email || t("未绑定邮箱"), t("注册于 ") + fmtDate(u.created_at)].join(" · ") })),
            btn("", { kind: "ghost", iconName: "x", title: t("关闭"), onclick: () => drawerState.close() })),
          h("div", { class: "pills" }, userStatus(u), u.google_linked ? pill("Google", "accent", false) : null, u.email_verified ? pill(t("邮箱已验证"), "ok", false) : null),
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
      placeholder: S.settings.default_user_local_quota_bytes ? t("默认 {v}", { v: fmtBytes(S.settings.default_user_local_quota_bytes) }) : t("默认不限"),
      value: policy.local_quota_bytes ? String(Math.round((policy.local_quota_bytes / GB) * 100) / 100) : "",
    });
    quota.addEventListener("input", () => {
      const v = parseFloat(quota.value);
      policy.local_quota_bytes = Number.isFinite(v) && v > 0 ? Math.round(v * GB) : null;
    });
    const note = h("textarea", { class: "textarea", rows: 2, placeholder: t("仅管理员可见"), id: "pol-note" });
    note.value = policy.note || "";
    note.addEventListener("input", () => { policy.note = note.value; });

    const savePolicy = btn(t("保存用户策略"), {
      kind: "primary",
      onclick: async (e) => {
        if (await run(e.currentTarget, () => api(userPath + "/policy", { method: "PUT", body: policy }), t("用户策略已保存"))) reloadDrawer();
      },
    });

    return [
      h("div", { class: "mini-stats" },
        miniStat(t("在线 / 设备"), `${u.online_devices} / ${u.device_count}`),
        miniStat(t("抽屉条目"), fmtNum(u.item_count)),
        miniStat(t("云端占用"), fmtBytes(u.storage_bytes)),
        miniStat(t("配额"), detail.effective_local_quota_bytes ? fmtBytes(detail.effective_local_quota_bytes) : t("不限")),
        miniStat(t("最近登录"), u.last_login_at ? fmtRel(u.last_login_at) : "—")),
      sectionTitle(t("用户策略"), t("覆盖服务器默认设置，仅对该用户生效")),
      h("div", { class: "group" },
        row({ title: t("本地存储配额"), desc: t("留空则使用服务器默认配额。"), control: h("div", { class: "input-unit" }, quota, h("span", { text: "GB" })) }),
        row({ title: t("禁止上传到云端"), desc: t("该用户只能使用 P2P 直传。"), control: switchEl({ id: "pol-upload", checked: policy.upload_blocked, label: t("禁止上传到云端"), onchange: (v) => { policy.upload_blocked = v; } }) }),
        row({ title: t("禁止创建外链"), desc: t("已有外链不受影响，可在「外链」页吊销。"), control: switchEl({ id: "pol-share", checked: policy.share_blocked, label: t("禁止创建外链"), onchange: (v) => { policy.share_blocked = v; } }) }),
        h("div", { class: "row stack" }, field(t("管理员备注"), note))),
      h("div", null, savePolicy),
      h("div", { class: "danger-zone" },
        h("div", null, h("div", { class: "row-title", text: t("删除账号") }), h("div", { class: "row-desc", text: t("永久删除账号、设备、存储配置、抽屉文件与外链，无法恢复。") })),
        btn(t("删除账号"), {
          kind: "danger", iconName: "trash",
          onclick: async (e) => {
            const ok = await typedConfirm(t("删除账号"), t("此操作会永久删除「{username}」及其全部云端文件。请输入用户名确认：", { username: u.username }), u.username);
            if (!ok) return;
            const button = e.currentTarget;
            const done = () => { toast(t("已删除「{username}」", { username: u.username })); drawerState.close(); refreshAll(); };
            button.classList.add("busy");
            try {
              await api(userPath, { method: "DELETE" });
              done();
            } catch (err) {
              // 409: some cloud files could not be removed and the account was kept.
              if (err.status !== 409) { if (err.status !== 401) toast(err.message || String(err), "err"); return; }
              const force = await confirmDialog(t("部分云端文件无法删除"), err.message + " " + t("强制删除后，这些文件会留在用户的云盘里，需要手动清理。"), { confirmText: t("强制删除"), danger: true });
              if (force && (await run(button, () => api(userPath + "?force=true", { method: "DELETE" }))) !== undefined) done();
            } finally {
              button.classList.remove("busy");
            }
          },
        })),
    ];
  }

  function miniStat(label, value) {
    return h("div", { class: "mini-stat" }, h("div", { class: "label", text: label }), h("div", { class: "value", text: value }));
  }

  function drawerDevices(detail, userPath) {
    if (!detail.devices.length) return empty("monitor", t("该用户还没有登记设备"));
    return [
      callout(null, t("移除后该设备会立即断开，旧的登录凭据也无法再登记这台设备，用户需要在设备上重新登录。")),
      h("div", { class: "list" }, detail.devices.map((d) => h("div", { class: "list-item" },
        h("div", { class: "list-icon" }, icon(["ios", "android"].includes(d.platform) ? "phone" : "monitor")),
        h("div", { class: "grow" },
          h("div", { class: "title", text: d.name }),
          h("div", { class: "meta", text: [PLATFORM_LABELS[d.platform] || d.platform, d.app_version ? "v" + d.app_version : t("版本未知"), d.has_p2p ? t("支持 P2P") : t("无 P2P 节点"), t("最后活跃 ") + fmtRel(d.last_seen_at)].join(" · ") })),
        d.online ? pill(t("在线"), "ok") : pill(t("离线")),
        btn("", {
          size: "sm", kind: "danger", iconName: "trash", title: t("移除设备"),
          onclick: async (e) => {
            if (!(await confirmDialog(t("移除设备"), t("移除「{dName}」？该设备需要重新登录才能再次使用。", { dName: d.name }), { confirmText: t("移除"), danger: true }))) return;
            if ((await run(e.currentTarget, () => api(`${userPath}/devices/${encodeURIComponent(d.id)}`, { method: "DELETE" }), t("设备已移除"))) !== undefined) reloadDrawer();
          },
        })))),
    ];
  }

  function drawerStorage(detail, userPath) {
    if (!detail.backends.length) return empty("database", t("该用户还没有配置存储，上传时会自动使用服务器本地存储"));
    const disabled = new Set(S.settings.storage_policy.disabled_backend_kinds);
    return h("div", { class: "list" }, detail.backends.map((b) => h("div", { class: "list-item" },
      h("div", { class: "list-icon" }, icon(b.kind === "local" ? "server" : "cloud")),
      h("div", { class: "grow" },
        h("div", { class: "title", text: b.name }),
        h("div", { class: "meta", text: (KIND_LABELS[b.kind] || b.kind) + " · " + b.display_target })),
      b.is_default ? pill(t("默认"), "accent", false) : null,
      disabled.has(b.kind) ? pill(t("类型已停用"), "warn", false) : null,
      btn("", {
        size: "sm", kind: "danger", iconName: "trash", title: t("移除存储"),
        onclick: async (e) => {
          if (!(await confirmDialog(t("移除存储配置"), t("移除「{bName}」？只删除配置，不会删除云盘里的文件；引用它的抽屉条目将无法再从云端下载。", { bName: b.name }), { confirmText: t("移除"), danger: true }))) return;
          if ((await run(e.currentTarget, () => api(`${userPath}/backends/${encodeURIComponent(b.id)}`, { method: "DELETE" }), t("存储配置已移除"))) !== undefined) reloadDrawer();
        },
      }))));
  }

  function drawerItems(detail, userPath) {
    const items = detail.items;
    if (!items.length) return empty("file", t("抽屉是空的"));
    return [
      items.length >= 300 ? callout(null, t("仅显示最近 300 个条目。")) : null,
      h("div", { class: "list" }, items.map((it) => h("div", { class: "list-item" },
        h("div", { class: "list-icon" }, icon(it.kind === "text" ? "text" : "file")),
        h("div", { class: "grow" },
          h("div", { class: "title", text: it.kind === "text" ? t("文本片段") : it.name }),
          h("div", { class: "meta", text: [fmtBytes(it.size), it.cloud_ready ? t("已在云端") : MODE_LABELS[it.transfer_mode] || it.transfer_mode, t("创建于 ") + fmtRel(it.created_at), it.expires_at ? fmtRel(it.expires_at) + t("到期") : null].filter(Boolean).join(" · ") })),
        btn("", {
          size: "sm", kind: "danger", iconName: "trash", title: t("删除条目"),
          onclick: async (e) => {
            if (!(await confirmDialog(t("删除条目"), t("条目会从该用户所有设备的抽屉中移除，云端文件一并删除。"), { confirmText: t("删除"), danger: true }))) return;
            if ((await run(e.currentTarget, () => api(`${userPath}/items/${encodeURIComponent(it.id)}`, { method: "DELETE" }), t("条目已删除"))) !== undefined) reloadDrawer();
          },
        })))),
    ];
  }

  function drawerShares(detail, userPath) {
    if (!detail.shares.length) return empty("link", t("该用户没有外链"));
    return [
      h("div", null, btn(t("吊销全部外链"), {
        kind: "danger", iconName: "ban",
        onclick: async (e) => {
          if (!(await confirmDialog(t("吊销全部外链"), t("吊销「{username}」的 {sharesLength} 个外链？", { username: detail.user.username, sharesLength: detail.shares.length }), { confirmText: t("全部吊销"), danger: true }))) return;
          const r = await run(e.currentTarget, () => api(userPath + "/shares", { method: "DELETE" }));
          if (r) { toast(t("已吊销 {revoked} 个外链", { revoked: r.revoked })); reloadDrawer(); loadShares(); }
        },
      })),
      h("div", { class: "list" }, detail.shares.map((s) => h("div", { class: "list-item" },
        h("div", { class: "list-icon" }, icon(s.has_passcode ? "lock" : "link")),
        h("div", { class: "grow" },
          h("div", { class: "title" }, h("a", { href: "/s/" + encodeURIComponent(s.code), target: "_blank", rel: "noopener noreferrer", text: s.title || "/s/" + s.code })),
          h("div", { class: "meta", text: [t("下载 {download_count}{v}", { download_count: s.download_count, v: s.max_downloads ? " / " + s.max_downloads : "" }), s.expires_at ? t("有效期至 ") + fmtDate(s.expires_at) : t("永久有效"), t("创建于 ") + fmtRel(s.created_at)].join(" · ") })),
        shareState(s),
        btn("", {
          size: "sm", kind: "danger", iconName: "ban", title: t("吊销外链"),
          onclick: async (e) => {
            if ((await run(e.currentTarget, () => api("/api/admin/shares/" + encodeURIComponent(s.code), { method: "DELETE" }), t("外链已吊销"))) !== undefined) { reloadDrawer(); loadShares(); }
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
    const input = h("input", { class: "input mono", type: "text", value: randomPassword(), autocomplete: "off", "aria-label": t("新密码") });
    const body = h("div", { class: "page" },
      h("p", { text: t("为「{username}」设置新密码（至少 6 位）。保存后该用户所有设备会被强制下线。", { username: u.username }) }),
      h("div", { class: "toolbar" }, h("div", { class: "search-wrap" }, input),
        btn("", { iconName: "dice", title: t("重新生成"), onclick: () => { input.value = randomPassword(); } }),
        btn("", { iconName: "copy", title: t("复制"), onclick: () => copyText(input.value) })));
    const result = await dialog({
      title: t("重置密码"),
      body,
      actions: [{ label: t("取消"), value: false, kind: "ghost" }, { label: t("重置密码"), value: true, kind: "primary" }],
    });
    if (!result) return;
    const pwd = input.value;
    if (pwd.length < 6) { toast(t("密码长度不能少于 6 位"), "err"); return; }
    const ok = await run(null, () => api(`/api/admin/users/${encodeURIComponent(u.id)}/reset-password`, { method: "POST", body: { new_password: pwd } }));
    if (ok) {
      copyText(pwd, t("密码已重置，新密码已复制到剪贴板"));
      reloadDrawer();
    }
  }

  async function typedConfirm(title, message, expected) {
    const input = h("input", { class: "input", type: "text", placeholder: expected, autocomplete: "off", "aria-label": t("确认输入") });
    const result = await dialog({
      title,
      body: [h("p", { text: message }), input],
      actions: [{ label: t("取消"), value: false, kind: "ghost" }, { label: t("永久删除"), value: true, kind: "danger" }],
    });
    if (!result) return false;
    if (input.value.trim() !== expected) { toast(t("输入的内容不匹配，已取消"), "err"); return false; }
    return true;
  }

  // Shares ------------------------------------------------------------------------
  function shareExpired(s) {
    return (s.expires_at && new Date(s.expires_at) <= new Date()) || (s.max_downloads != null && s.download_count >= s.max_downloads);
  }

  function shareState(s) {
    if (S.settings && !S.settings.features.share_access_enabled) return pill(t("已暂停"), "danger");
    return shareExpired(s) ? pill(t("已失效")) : pill(t("有效"), "ok");
  }

  function renderShares() {
    setActions(btn(t("刷新"), { iconName: "refresh", onclick: (e) => loadShares(e.currentTarget) }));
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
      meta.textContent = t("{rowsLength} 条", { rowsLength: rows.length }) + (S.shares.length >= 1000 ? t("（最多显示 1000 条）") : "");
      replace(host, table([
      { label: t("外链"), render: (s) => h("div", { class: "nowrap" },
        h("a", { class: "mono", href: "/s/" + encodeURIComponent(s.code), target: "_blank", rel: "noopener noreferrer", text: "/s/" + s.code }),
        s.has_passcode ? h("span", { title: t("有提取码") }, " ", icon("lock", "faint")) : null) },
      { label: t("内容"), render: (s) => h("div", { class: "truncate" }, h("div", { class: s.item_name ? "cell-main truncate" : "cell-main truncate faint", text: s.item_name || t("（已删除）") }), h("div", { class: "cell-sub", text: s.item_count > 1 ? t("{count} 个文件 · {size}", { count: s.item_count, size: fmtBytes(s.item_size) }) : fmtBytes(s.item_size) })) },
      { label: t("创建者"), render: (s) => h("button", { class: "btn ghost sm", type: "button", onclick: () => openUserDrawer(s.owner_id, "shares") }, s.owner_username) },
      { label: t("下载"), cls: "num", render: (s) => `${fmtNum(s.download_count)}${s.max_downloads ? " / " + fmtNum(s.max_downloads) : ""}` },
      { label: t("有效期"), render: (s) => h("div", { class: "nowrap", text: s.expires_at ? fmtDate(s.expires_at) : t("永久") }) },
      { label: t("状态"), render: shareState },
      {
        label: "", cls: "actions", render: (s) => btn(t("吊销"), {
          size: "sm", kind: "danger",
          onclick: async (e) => {
            if (!(await confirmDialog(t("吊销外链"), t("吊销后 /s/{code} 立即无法访问。", { code: s.code }), { confirmText: t("吊销"), danger: true }))) return;
            if ((await run(e.currentTarget, () => api("/api/admin/shares/" + encodeURIComponent(s.code), { method: "DELETE" }), t("外链已吊销"))) !== undefined) loadShares();
          },
        }),
      },
    ], rows, { emptyIcon: "link", emptyText: S.shares.length ? t("没有匹配的外链") : t("还没有人创建外链") }));
    };
    render();
    const accessPaused = S.settings && !S.settings.features.share_access_enabled;
    return h("div", { class: "page" },
      accessPaused ? callout("warn", t("公网外链访问已在「功能与限额」中暂停，以下外链当前都无法打开。")) : null,
      h("div", { class: "toolbar" },
        searchBox(t("搜索外链码、文件名或创建者"), S.shareQuery, (v) => { S.shareQuery = v; render(); }, "q-shares"),
        segmented([["all", t("全部")], ["active", t("有效")], ["expired", t("已失效")], ["passcode", t("有提取码")]], S.shareFilter, (v) => { S.shareFilter = v; renderPage({ keepScroll: true }); }),
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
    setActions(btn(t("刷新"), { iconName: "refresh", onclick: (e) => loadAudit(e.currentTarget) }));
    const host = h("div");
    const meta = h("span", { class: "meta" });
    const render = () => {
      const q = S.auditQuery.trim().toLowerCase();
      const rows = S.audit.filter((e) => !q || [AUDIT_LABELS[e.action] || e.action, e.target, auditDetail(e), e.ip].some((v) => (v || "").toLowerCase().includes(q)));
      meta.textContent = t("{rowsLength} 条", { rowsLength: rows.length });
      replace(host, table([
        { label: t("时间"), render: (e) => h("span", { class: "nowrap", title: fmtDate(e.at), text: fmtDate(e.at) }) },
        { label: t("操作"), render: (e) => h("span", { class: "nowrap" }, h("span", { class: "dot " + (auditDangerous(e.action) ? "danger" : "accent") }), " ", AUDIT_LABELS[e.action] || e.action) },
        { label: t("对象"), render: (e) => h("span", { class: "truncate", text: e.target || "—" }) },
        { label: t("详情"), render: (e) => h("span", { class: "muted truncate", text: auditDetail(e) || "—" }) },
        { label: "IP", render: (e) => h("span", { class: "mono faint", text: e.ip || "—" }) },
      ], rows, { emptyIcon: "log", emptyText: t("暂无记录") }));
    };
    render();
    return h("div", { class: "page" },
      h("div", { class: "toolbar" },
        searchBox(t("搜索操作、对象或 IP"), S.auditQuery, (v) => { S.auditQuery = v; render(); }, "q-audit"),
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
        h("div", { class: "t", text: a.title || t("（无标题）") }),
        a.message ? h("div", { class: "m", text: a.message }) : null));
  }

  function renderClients() {
    setActions(btn(t("刷新"), { iconName: "refresh", onclick: (e) => loadClients(e.currentTarget) }));
    const d = S.draft;
    if (!d) return h("div", { class: "page" });
    const a = d.announcement;

    const title = h("input", { class: "input", id: "ann-title", maxlength: 80, placeholder: t("例如：今晚 23:00 维护"), value: a.title });
    const message = h("textarea", { class: "textarea", id: "ann-message", rows: 3, maxlength: 1000, placeholder: t("公告内容，客户端会以横幅显示，用户可以关闭") });
    message.value = a.message;
    const previewHost = h("div", null, announcementPreview(a));
    const refreshPreview = () => replace(previewHost, announcementPreview(S.draft.announcement));
    title.addEventListener("input", () => { setDraft("announcement.title", title.value); refreshPreview(); });
    message.addEventListener("input", () => { setDraft("announcement.message", message.value); refreshPreview(); });

    const announcement = h("div", { class: "group" },
      row({ title: t("发布公告"), desc: t("开启后在所有已登录客户端顶部显示。修改内容会让已关闭横幅的用户再次看到。"), control: draftSwitch("announcement.enabled", { label: t("发布公告") }) }),
      row({
        title: t("级别"),
        control: segmented([["info", t("通知")], ["warning", t("警告")], ["critical", t("紧急")]], a.level || "info",
          (v) => { setDraft("announcement.level", v, { rerender: true }); }),
      }),
      h("div", { class: "row stack" }, field(t("标题"), title), field(t("内容"), message), field(t("预览"), previewHost)));

    const minVersion = h("input", { class: "input", id: "min-version", placeholder: t("不限制"), value: d.client_policy.min_version || "" });
    minVersion.addEventListener("input", () => setDraft("client_policy.min_version", minVersion.value.trim() || null));
    const policy = h("div", { class: "group" },
      row({
        title: t("最低客户端版本"),
        desc: t("低于此版本（或未上报版本的旧客户端）登录后无法登记设备，会提示用户更新。留空表示不限制。"),
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
      { label: t("平台"), render: (r) => PLATFORM_LABELS[r.platform] || r.platform },
      { label: t("版本"), render: (r) => h("span", { class: r.version ? "mono" : "faint", text: r.version ? "v" + r.version : t("未上报（旧版本）") }) },
      { label: t("设备"), cls: "num", render: (r) => fmtNum(r.devices) },
      { label: t("近 30 天活跃"), cls: "num", render: (r) => fmtNum(r.active_devices) },
      { label: t("状态"), render: (r) => (below(r.version) ? pill(t("低于最低版本"), "warn") : pill(t("可用"), "ok")) },
    ], S.clients, { emptyIcon: "monitor", emptyText: t("还没有设备登记") });

    return h("div", { class: "page" },
      sectionTitle(t("全站公告")), announcement,
      sectionTitle(t("版本要求")), policy,
      sectionTitle(t("客户端版本分布"), t("按设备最近一次登记时上报的版本统计")), versions);
  }

  // Administrators -------------------------------------------------------------------
  async function loadAdmins(button) {
    if (!isSuper()) return;
    const admins = await run(button, () => api("/api/admin/admins"));
    if (admins) { S.admins = admins; if (S.page === "admins") renderPage({ keepScroll: true }); }
  }

  function renderAdmins() {
    setActions(btn(t("刷新"), { iconName: "refresh", onclick: (e) => loadAdmins(e.currentTarget) }));
    const form = S.adminForm;
    const name = h("input", { class: "input", id: "adm-name", placeholder: t("例如：ops"), value: form.username, autocomplete: "off" });
    name.addEventListener("input", () => { form.username = name.value; });
    const pwd = h("input", { class: "input mono", id: "adm-pwd", type: "text", placeholder: t("至少 10 位"), value: form.password, autocomplete: "off" });
    pwd.addEventListener("input", () => { form.password = pwd.value; });
    const role = h("select", { class: "select", id: "adm-role" },
      [["admin", t("管理员")], ["viewer", t("只读")], ["super", t("超级管理员")]].map(([v, l]) => h("option", { value: v, selected: form.role === v }, l)));
    role.addEventListener("change", () => { form.role = role.value; });

    const create = btn(t("创建管理员"), {
      kind: "primary", iconName: "plus",
      onclick: async (e) => {
        const rec = await run(e.currentTarget, () => api("/api/admin/admins", { method: "POST", body: { username: form.username.trim(), password: form.password, role: form.role } }), t("管理员已创建"));
        if (rec) {
          copyText(`${rec.username} / ${form.password}`, t("管理员已创建，账号与初始密码已复制"));
          S.adminForm = { username: "", password: "", role: "admin" };
          loadAdmins();
        }
      },
    });

    const roleSelect = (a) => {
      const sel = h("select", { class: "select", "aria-label": t("角色") },
        [["super", t("超级管理员")], ["admin", t("管理员")], ["viewer", t("只读")]].map(([v, l]) => h("option", { value: v, selected: a.role === v }, l)));
      sel.addEventListener("change", async () => {
        if ((await run(null, () => api("/api/admin/admins/" + encodeURIComponent(a.id), { method: "PUT", body: { role: sel.value, disabled: a.disabled } }), t("角色已更新，该管理员需重新登录"))) !== undefined) loadAdmins();
      });
      return sel;
    };

    const isMe = (a) => S.session && S.session.actor === a.username;
    const list = table([
      {
        label: t("管理员"), render: (a) => h("div", { class: "user-cell" },
          h("div", { class: "avatar" + (a.disabled ? " muted" : ""), text: initials(a.username) }),
          h("div", null, h("div", { class: "cell-main", text: a.username + (isMe(a) ? t("（我）") : "") }), h("div", { class: "cell-sub", text: t("创建于 ") + fmtDate(a.created_at) }))),
      },
      { label: t("角色"), render: (a) => (isMe(a) ? pill(ROLE_LABELS[a.role], "accent", false) : roleSelect(a)) },
      { label: t("两步验证"), render: (a) => (a.totp_enabled ? pill(t("已开启"), "ok") : pill(t("未开启"), "warn")) },
      { label: t("最近登录"), render: (a) => h("span", { class: "nowrap", text: a.last_login_at ? fmtRel(a.last_login_at) : t("从未") }) },
      { label: t("状态"), render: (a) => (a.disabled ? pill(t("已停用"), "danger") : pill(t("正常"), "ok")) },
      {
        label: "", cls: "actions", render: (a) => (isMe(a) ? h("a", { class: "btn sm", href: "#/me" }, t("我的账号")) : [
          btn(a.disabled ? t("启用") : t("停用"), {
            size: "sm",
            onclick: async (e) => {
              if ((await run(e.currentTarget, () => api("/api/admin/admins/" + encodeURIComponent(a.id), { method: "PUT", body: { role: a.role, disabled: !a.disabled } }), a.disabled ? t("已启用") : t("已停用并强制下线"))) !== undefined) loadAdmins();
            },
          }),
          btn("", {
            size: "sm", iconName: "key", title: t("重置密码"),
            onclick: async () => {
              const input = h("input", { class: "input mono", type: "text", value: randomPassword() + randomPassword().slice(0, 4), "aria-label": t("新密码") });
              const ok = await dialog({ title: t("重置管理员密码"), body: [h("p", { text: t("为「{username}」设置新密码（至少 10 位），其所有会话会被强制下线。", { username: a.username }) }), input], actions: [{ label: t("取消"), value: false, kind: "ghost" }, { label: t("重置"), value: true, kind: "primary" }] });
              if (!ok) return;
              if (await run(null, () => api(`/api/admin/admins/${encodeURIComponent(a.id)}/reset-password`, { method: "POST", body: { new_password: input.value } }))) copyText(input.value, t("密码已重置并复制到剪贴板"));
            },
          }),
          a.totp_enabled ? btn("", {
            size: "sm", iconName: "shield", title: t("重置两步验证"),
            onclick: async (e) => {
              if (!(await confirmDialog(t("重置两步验证"), t("关闭「{username}」的两步验证（例如手机丢失时）。对方下次登录后可重新设置。", { username: a.username }), { confirmText: t("重置") }))) return;
              if ((await run(e.currentTarget, () => api(`/api/admin/admins/${encodeURIComponent(a.id)}/reset-totp`, { method: "POST" }), t("两步验证已重置"))) !== undefined) loadAdmins();
            },
          }) : null,
          btn("", {
            size: "sm", kind: "danger", iconName: "trash", title: t("删除管理员"),
            onclick: async (e) => {
              if (!(await confirmDialog(t("删除管理员"), t("删除「{username}」？其会话立即失效。", { username: a.username }), { confirmText: t("删除"), danger: true }))) return;
              if ((await run(e.currentTarget, () => api("/api/admin/admins/" + encodeURIComponent(a.id), { method: "DELETE" }), t("管理员已删除"))) !== undefined) loadAdmins();
            },
          }),
        ]),
      },
    ], S.admins, { emptyIcon: "badge", emptyText: t("还没有管理员账号") });

    return h("div", { class: "page" },
      callout(null, t("超级管理员可以管理管理员账号与下载备份；管理员可以修改设置和治理用户；只读管理员只能查看。如需用 Google 登录，管理员用户名须与 Google 邮箱一致。")),
      h("div", { class: "card" }, h("div", { class: "inline-form" }, field(t("用户名"), name), field(t("初始密码"), pwd), field(t("角色"), role), create)),
      list);
  }

  // My account ---------------------------------------------------------------------
  let totpEnrollment = null;

  function renderMe() {
    const sess = S.session;
    if (!sess) return h("div", { class: "page" });
    const current = h("input", { class: "input", type: "password", autocomplete: "current-password", id: "me-cur" });
    const next = h("input", { class: "input", type: "password", autocomplete: "new-password", id: "me-new", placeholder: t("至少 10 位") });
    const confirmNext = h("input", { class: "input", type: "password", autocomplete: "new-password", id: "me-new2" });
    const changePwd = btn(t("修改密码"), {
      kind: "primary",
      onclick: async (e) => {
        if (next.value !== confirmNext.value) { toast(t("两次输入的新密码不一致"), "err"); confirmNext.focus(); return; }
        if ((await run(e.currentTarget, () => api("/api/admin/me/password", { method: "POST", body: { current_password: current.value, new_password: next.value } }), t("密码已修改，其他设备上的会话已退出"))) !== undefined) {
          current.value = ""; next.value = ""; confirmNext.value = "";
        }
      },
    });

    let totpSection;
    if (sess.totp_enabled) {
      const code = h("input", { class: "input mono", inputmode: "numeric", maxlength: 7, placeholder: t("当前验证码"), id: "me-totp-off" });
      totpSection = h("div", { class: "group" },
        row({ title: t("两步验证已开启"), badges: pill(t("已保护"), "ok"), desc: t("登录时需要输入身份验证器中的验证码。关闭需要验证一次当前验证码。") }),
        h("div", { class: "row" }, code, btn(t("关闭两步验证"), {
          kind: "danger",
          onclick: async (e) => {
            if ((await run(e.currentTarget, () => api("/api/admin/me/totp/disable", { method: "POST", body: { code: code.value } }), t("两步验证已关闭"))) !== undefined) loadSession();
          },
        })));
    } else if (totpEnrollment) {
      const code = h("input", { class: "input mono totp-input", inputmode: "numeric", maxlength: 7, placeholder: "000000", id: "me-totp-on" });
      totpSection = h("div", { class: "group" },
        h("div", { class: "row stack" },
          h("div", { class: "row-desc", text: t("1. 用 Google Authenticator、1Password、Microsoft Authenticator 等应用扫描二维码，或手动输入密钥。") }),
          h("div", { class: "qr-box" },
            totpEnrollment.qr_data_uri ? h("img", { src: totpEnrollment.qr_data_uri, alt: t("两步验证二维码") }) : null,
            h("div", { class: "page" },
              h("div", { class: "secret-chip", text: totpEnrollment.secret.replace(/(.{4})/g, "$1 ").trim() }),
              btn(t("复制密钥"), { size: "sm", iconName: "copy", onclick: () => copyText(totpEnrollment.secret) }))),
          h("div", { class: "row-desc", text: t("2. 输入应用中显示的 6 位验证码完成绑定。") }),
          h("div", { class: "toolbar" }, h("div", { class: "search-wrap" }, code), btn(t("确认开启"), {
            kind: "primary",
            onclick: async (e) => {
              if ((await run(e.currentTarget, () => api("/api/admin/me/totp/enable", { method: "POST", body: { code: code.value } }), t("两步验证已开启"))) !== undefined) {
                totpEnrollment = null;
                loadSession();
              }
            },
          }), btn(t("取消"), { kind: "ghost", onclick: () => { totpEnrollment = null; renderPage({ keepScroll: true }); } }))));
    } else {
      totpSection = h("div", { class: "group" },
        row({
          title: t("两步验证未开启"),
          badges: pill(t("建议开启"), "warn"),
          desc: t("开启后，即使密码泄露，没有你的手机也无法登录管理控制台。"),
          control: btn(t("开始设置"), {
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
      sectionTitle(t("两步验证")), totpSection,
      sectionTitle(t("修改密码"), t("修改后其他设备上的管理端会话会退出")),
      h("div", { class: "card" },
        h("div", { class: "fields" }, field(t("当前密码"), current), field(t("新密码"), next), field(t("确认新密码"), confirmNext)),
        h("div", { class: "form-foot" }, changePwd)));
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
    if (notify) toast(t("数据已刷新"));
    return true;
  }

  function showLogin(message) {
    $("appView").hidden = true;
    $("savebar").classList.remove("show");
    while (overlayStack.length) closeOverlay(overlayStack[overlayStack.length - 1]);
    $("loginView").hidden = false;
    $("loginError").textContent = message || "";
    setLoginStep("account");
    void loadLoginOptions();
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

  let loginMode = "account";
  let loginOptions = null;
  let loginOptionsPromise = null;
  let turnstileId = null;
  let challengeToken = null;

  function syncLoginOptions() {
    const showGoogle = loginMode === "account" && Boolean(loginOptions?.google_enabled);
    $("loginGoogle").hidden = !showGoogle;
    if ($("loginDivider")) $("loginDivider").hidden = !showGoogle;
    $("loginChallenge").hidden = loginMode === "google-totp" || !loginOptions?.turnstile_site_key;
  }

  function renderTurnstileWidget() {
    if (!window.turnstile || !loginOptions?.turnstile_site_key) return;
    if (turnstileId !== null) {
      try { window.turnstile.remove(turnstileId); } catch { /* ignore */ }
      turnstileId = null;
    }
    challengeToken = null;
    turnstileId = window.turnstile.render($("loginChallenge"), {
      sitekey: loginOptions.turnstile_site_key,
      action: "admin_login",
      theme: resolvedTheme(),
      size: matchMedia("(max-width: 420px)").matches ? "compact" : "flexible",
      callback: (token) => { challengeToken = token; },
      "expired-callback": () => refreshChallenge(),
      "error-callback": () => { challengeToken = null; },
    });
  }

  function rerenderTurnstileForTheme() {
    if (!$("loginView").hidden && turnstileId !== null && window.turnstile) {
      try { renderTurnstileWidget(); } catch { /* ignore */ }
    }
  }

  function setLoginStep(step) {
    loginMode = step;
    const needsCode = step !== "account";
    $("accountFields").hidden = needsCode;
    $("totpFields").hidden = !needsCode;
    $("loginBack").hidden = !needsCode;
    $("loginSubmit").textContent = needsCode ? t("验证并登录") : t("登录");
    syncLoginOptions();
    const focus = needsCode ? "loginTotp" : ($("loginUser").value ? "loginPassword" : "loginUser");
    setTimeout(() => $(focus).focus(), 30);
  }

  function refreshChallenge() {
    challengeToken = null;
    if (turnstileId !== null) window.turnstile.reset(turnstileId);
  }

  function loadLoginOptions() {
    return loginOptionsPromise ??= api("/api/admin/auth/config").then((options) => {
      loginOptions = options;
      syncLoginOptions();
      if (!options.turnstile_site_key) return;
      const script = document.createElement("script");
      script.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=dropDrawerTurnstileLoaded";
      const failure = () => {
        delete window.dropDrawerTurnstileLoaded;
        $("loginError").textContent = t("人机验证加载失败，请刷新后重试");
      };
      script.addEventListener("error", failure, { once: true });
      window.dropDrawerTurnstileLoaded = () => {
        delete window.dropDrawerTurnstileLoaded;
        try {
          renderTurnstileWidget();
        } catch {
          failure();
        }
      };
      document.head.append(script);
    }).catch(() => { $("loginError").textContent = t("无法加载登录配置，请刷新后重试"); });
  }

  $("loginBack").addEventListener("click", () => {
    $("loginError").textContent = "";
    $("loginTotp").value = "";
    setLoginStep("account");
    refreshChallenge();
  });

  $("loginGoogle").addEventListener("click", async () => {
    const button = $("loginGoogle");
    button.disabled = true;
    $("loginError").textContent = "";
    try {
      const result = await api("/api/admin/google/start", { method: "POST", body: { turnstile_token: challengeToken } });
      location.assign(result.authorization_url);
    } catch (err) {
      $("loginError").textContent = err.message || t("无法开始 Google 登录");
      refreshChallenge();
    } finally {
      button.disabled = false;
    }
  });

  $("loginForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const button = $("loginSubmit");
    const code = $("loginTotp").value.replace(/\s+/g, "");
    const googleTotp = loginMode === "google-totp";
    const body = googleTotp ? { code } : {
      username: $("loginUser").value.trim(),
      password: $("loginPassword").value,
      totp_code: loginMode === "totp" ? code : null,
      turnstile_token: challengeToken,
    };
    button.disabled = true;
    button.classList.add("busy");
    $("loginError").textContent = "";
    try {
      await api(googleTotp ? "/api/admin/google/totp" : "/api/admin/login", { method: "POST", body });
      $("loginPassword").value = "";
      $("loginTotp").value = "";
      await showApp();
    } catch (err) {
      if (err.message === "TOTP_REQUIRED") {
        setLoginStep("totp");
      } else {
        $("loginError").textContent = err.message || t("登录失败");
        if (loginMode !== "account") { $("loginTotp").value = ""; $("loginTotp").focus(); }
      }
    } finally {
      if (!googleTotp) refreshChallenge();
      button.disabled = false;
      button.classList.remove("busy");
    }
  });

  $("logoutBtn").addEventListener("click", async () => {
    if (isDirty() && !(await confirmDialog(t("退出登录"), t("还有未保存的设置，退出后会丢失。"), { confirmText: t("仍然退出"), danger: true }))) return;
    try { await api("/api/admin/logout", { method: "POST" }); } catch { /* ignore */ }
    S.draft = null;
    S.settings = null;
    S.session = null;
    location.replace("/admin");
  });

  (async function boot() {
    const googleResult = new URLSearchParams(location.search).get("google");
    if (googleResult) history.replaceState(null, "", "/admin");
    if (googleResult === "totp") {
      showLogin();
      setLoginStep("google-totp");
      return;
    }
    try {
      await api("/api/admin/session");
    } catch {
      showLogin(googleResult === "failed" ? t("Google 登录失败。请确认 Google 邮箱与现有管理员账号一致，或使用密码登录。") : "");
      return;
    }
    await showApp();
  })();
})();
