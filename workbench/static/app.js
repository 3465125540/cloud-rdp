/* 智能体工作台 —— 前端逻辑（原生 JS，零依赖） */
"use strict";

var DATA = null;          // 最近一次 /api/overview 的结果
var RUN_TAB = "keepalive"; // 运行日志当前 tab
var TIMER = null;
var BUSY = false;

/* ------------------------------------------------------------ 小工具 */
function $(sel) { return document.querySelector(sel); }
function esc(s) {
  return String(s === null || s === undefined ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
function toast(msg, kind, ms) {
  var t = $("#toast");
  t.className = "toast " + (kind || "");
  t.innerHTML = msg;
  t.hidden = false;
  clearTimeout(t._h);
  t._h = setTimeout(function () { t.hidden = true; }, ms || 4200);
}
function badge(text, kind) {
  return '<span class="badge ' + (kind || "mute") + '">' + esc(text) + "</span>";
}
function api(path, opts) {
  opts = opts || {};
  opts.headers = Object.assign({ "Content-Type": "application/json" }, opts.headers || {});
  return fetch(path, opts).then(function (r) {
    return r.json().then(function (j) {
      if (!r.ok && j && j.error) { throw new Error(j.error); }
      return j;
    });
  });
}

/* ------------------------------------------------------------ 拉数据 */
function load(force) {
  if (BUSY) return;
  BUSY = true;
  var url = "/api/overview" + (force ? "?refresh=1" : "");
  api(url).then(function (d) {
    DATA = d;
    render();
    $("#last-updated").textContent = "更新于 " + new Date().toLocaleTimeString("zh-CN");
  }).catch(function (e) {
    toast("拉取失败：" + esc(e.message), "bad");
  }).then(function () {
    BUSY = false;
  });
}

/* ------------------------------------------------------------ 渲染 */
function render() {
  if (!DATA) return;
  renderHead();
  renderStats();
  renderMachines();
  renderAccounts();
  renderRuns();
  renderErrors();
}

function renderHead() {
  var c = DATA.config || {};
  $("#brand-sub").textContent = (c.repo || "-") + "  ·  " + (c.ref || "-") +
    "  ·  token " + (c.token_present ? "已发现" : "未发现") + "  ·  代理 " + (c.proxy || "直连");

  var pills = [];
  var errs = DATA.errors || [];
  function hasErr(kw) { return errs.some(function (e) { return e.indexOf(kw) === 0; }); }

  pills.push('<span class="pill ' + (hasErr("GitHub") ? "bad" : "ok") + '"><i class="dot"></i>GitHub API</span>');
  pills.push('<span class="pill ' + (hasErr("Tailscale") ? "bad" : "ok") + '"><i class="dot"></i>Tailscale</span>');
  pills.push('<span class="pill ' + (hasErr("池状态") ? "warn" : "ok") + '"><i class="dot"></i>池状态</span>');
  pills.push('<span class="pill ' + (hasErr("账号池") ? "warn" : "ok") + '"><i class="dot"></i>账号池配置</span>');
  $("#link-pills").innerHTML = pills.join("");
}

function renderStats() {
  var s = DATA.stats || {};
  var target = s.target_machines;
  var online = s.machines_online || 0;
  var machinesCls = (target && online >= target) ? "good" : (online > 0 ? "warn" : "bad");

  var items = [
    { k: "在线机器", v: online + (s.machines_total ? " / " + s.machines_total : ""),
      s: target ? ("目标 " + target + " 台") : "", cls: machinesCls },
    { k: "池角色", v: (s.machines_primary || 0) + " 主 · " + (s.machines_standby || 0) + " 备",
      s: "主唯一写 139，备只读热备", cls: "" },
    { k: "账号", v: (s.accounts_enabled || 0) + " / " + (s.accounts_total || 0),
      s: "已启用 / 总数", cls: "" },
    { k: "目标台数", v: target === null || target === undefined ? "—" : target,
      s: "pool-config.json · target_machines", cls: "" }
  ];
  $("#stats").innerHTML = items.map(function (i) {
    return '<div class="stat ' + i.cls + '"><div class="k">' + esc(i.k) + '</div>' +
      '<div class="v">' + esc(i.v) + '</div><div class="s">' + esc(i.s) + "</div></div>";
  }).join("");
}

function roleBadge(role) {
  if (role === "primary") return badge("主 primary", "primary");
  if (role === "standby") return badge("备 standby", "info");
  if (role === "standalone") return badge("单机", "mute");
  return '<span class="muted">—</span>';
}

function renderMachines() {
  var all = DATA.machines || [];
  var onlyOnline = $("#only-online").checked;
  var rows = onlyOnline ? all.filter(function (m) { return m.online; }) : all;
  var tb = $("#tbl-machines tbody");
  $("#machines-empty").hidden = rows.length > 0;
  var onlineN = all.filter(function (m) { return m.online; }).length;
  $("#machines-meta").textContent = all.length
    ? ("在线 " + onlineN + " / 共 " + all.length + " 个节点（前缀 " + ((DATA.config || {}).machine_prefix || "") + "*）")
    : "";

  tb.innerHTML = rows.map(function (m) {
    var online = !!m.online;
    var st = online
      ? badge("在线" + (m.active ? " · 活跃" : ""), "ok")
      : badge("离线", "bad");
    var snap = '<span class="muted">—</span>';
    if (m.snapshot && m.snapshot.ok) {
      var sn = m.snapshot;
      var parts = [];
      if (sn.age_human) parts.push(sn.age_human);
      if (sn.files !== null && sn.files !== undefined) parts.push(sn.files + " 文件");
      snap = (sn.stale ? badge(parts.join(" · "), "warn") : badge(parts.join(" · "), "ok"));
    } else if (m.snapshot) {
      snap = '<span class="muted" title="未读到 _snapshot/manifest.json">无快照</span>';
    }
    var lastSeen = online ? '<span class="muted">—</span>'
      : '<span class="muted">' + esc(m.last_seen_human || "未知") + "</span>";
    var ops = online
      ? '<button class="btn btn-mini btn-primary" data-rdp="' + esc(m.ip) + '" data-host="' + esc(m.hostname) + '">一键登录</button>' +
        ' <button class="btn btn-mini btn-ghost" data-rdpfile="' + esc(m.ip) + '" data-host="' + esc(m.hostname) + '">仅生成</button>'
      : '<span class="muted">离线</span>';
    return "<tr>" +
      "<td class=\"strong\">" + esc(m.hostname || "-") + "</td>" +
      '<td class="mono">' + esc(m.ip || "-") + "</td>" +
      "<td>" + st + "</td>" +
      "<td>" + roleBadge(m.role) + "</td>" +
      "<td>" + snap + "</td>" +
      "<td>" + lastSeen + "</td>" +
      '<td class="right nowrap">' + ops + "</td>" +
      "</tr>";
  }).join("");
}

function tokenStateBadge(ts) {
  if (ts === "ok") return badge("凭证正常", "ok");
  if (ts === "missing") return badge("缺 Secret", "bad");
  if (ts === "query_failed") return badge("查询失败", "warn");
  if (ts === "disabled") return badge("已停用", "mute");
  return '<span class="muted">—</span>';
}

function runStateKind(state) {
  if (state === "success") return "ok";
  if (state === "in_progress" || state === "queued") return "info";
  if (state === "failure" || state === "cancelled" || state === "timed_out") return "bad";
  return "mute";
}

function renderAccounts() {
  var acc = DATA.accounts || {};
  var rows = acc.accounts || [];
  var tb = $("#tbl-accounts tbody");
  $("#accounts-empty").hidden = rows.length > 0;

  var bits = [];
  if (acc.ok) {
    bits.push(rows.length + " 个账号");
    if (acc.monitor_available) {
      bits.push("监测数据 " + (acc.state_age_human || "?") + (acc.state_via ? "（" + acc.state_via + "）" : ""));
    } else {
      bits.push("暂无监测数据（等协调器发布）");
    }
    if (!acc.secrets_readable) bits.push("Secret 列表读不到（需 repo 权限 Token）");
  }
  $("#accounts-meta").textContent = bits.join("  ·  ");

  if (!acc.ok) {
    tb.innerHTML = '<tr><td colspan="5" class="empty">' + esc(acc.error || "读取失败") + "</td></tr>";
    return;
  }
  tb.innerHTML = rows.map(function (a) {
    var secret;
    if (a.secret_present === true) secret = badge("已配置", "ok");
    else if (a.secret_present === false) secret = badge("缺失", "bad");
    else secret = '<span class="muted">未知</span>';

    // ---- 实时监测列：凭证状态 + 在跑机数 + 最近一次 run ----
    var mon = [tokenStateBadge(a.token_state)];
    if (a.alive_count !== null && a.alive_count !== undefined) {
      mon.push('<span class="mon-num">在跑 ' + esc(a.alive_count) + " 台</span>");
    }
    if (a.last_run) {
      mon.push('<span class="mon-run">' + badge(a.last_run.state || "-", runStateKind(a.last_run.state)) +
        (a.last_run.created_human ? ' <span class="muted">' + esc(a.last_run.created_human) + "</span>" : "") + "</span>");
    } else if (a.source && a.source !== "none") {
      mon.push('<span class="muted">无运行记录</span>');
    }
    if (a.source === "live") mon.push('<span class="src-tag" title="工作台用本机 Token 实时探测">实时</span>');
    var note = "";
    if (a.report_note && a.token_state !== "ok") {
      note = '<div class="muted mon-note">' + esc(a.report_note) + "</div>";
    }

    var name = esc(a.owner || "-");
    if (a.placeholder) name += ' <span class="muted">(待填)</span>';

    return "<tr>" +
      '<td class="strong">' + name + '<div class="muted mono">' + esc(a.id || "") + "</div></td>" +
      "<td>" + secret + '<div class="muted mono">' + esc(a.token_secret || "") + "</div></td>" +
      "<td>" + roleBadge(a.role) + "</td>" +
      '<td class="mon-cell">' + mon.join(" ") + note + "</td>" +
      '<td class="right"><label class="toggle"><input type="checkbox" data-acc="' + esc(a.id) + '"' +
        (a.enabled ? " checked" : "") + '><span class="slider"></span></label></td>' +
      "</tr>";
  }).join("");
}

function renderRuns() {
  var r = DATA.runs || {};
  var rows = r[RUN_TAB] || [];
  var tb = $("#tbl-runs tbody");
  $("#runs-empty").hidden = rows.length > 0;
  if (!r.ok && (!rows || !rows.length)) {
    tb.innerHTML = '<tr><td colspan="8" class="empty">' + esc(r.error || "读取失败") + "</td></tr>";
    return;
  }
  tb.innerHTML = rows.map(function (x) {
    var st = badge(x.state || "-", x.in_progress ? "info" : (x.conclusion === "success" ? "ok" : (x.conclusion === "cancelled" ? "warn" : "bad")));
    var ev = x.event === "schedule" ? badge("定时", "mute") : badge(x.event || "-", "info");
    return "<tr>" +
      '<td class="mono">#' + esc(x.number) + "</td>" +
      "<td>" + st + "</td>" +
      "<td>" + ev + "</td>" +
      '<td class="nowrap"><span title="' + esc(x.created_at) + '">' + esc(x.created_human) + "</span></td>" +
      '<td class="mono nowrap">' + esc(x.duration) + "</td>" +
      '<td class="mono">' + esc(x.head_sha) + "</td>" +
      '<td class="dim">' + esc(x.title || "-") + "</td>" +
      '<td class="right">' + (x.url ? '<a href="' + esc(x.url) + '" target="_blank" rel="noopener">日志</a>' : '<span class="muted">—</span>') + "</td>" +
      "</tr>";
  }).join("");
}

function renderErrors() {
  var errs = DATA.errors || [];
  $("#errors").innerHTML = errs.map(function (e) {
    return '<div class="err-line">' + esc(e) + "</div>";
  }).join("");
  $("#foot-meta").textContent = "workbench v" + (DATA.version || "?") +
    "  ·  数据生成于 " + (DATA.generated_at || "") +
    "  ·  账号池配置：" + ((DATA.config || {}).pool_config_path || "-");
}

/* ------------------------------------------------------------ 自动刷新 */
function setTimer() {
  if (TIMER) { clearInterval(TIMER); TIMER = null; }
  if (!$("#auto-refresh").checked) return;
  var secs = (DATA && DATA.config && DATA.config.auto_refresh_seconds) || 30;
  TIMER = setInterval(function () { load(false); }, Math.max(10, secs) * 1000);
}

/* ------------------------------------------------------------ 事件 */
function bind() {
  $("#btn-refresh").addEventListener("click", function () { load(true); });
  $("#btn-refresh2").addEventListener("click", function () { load(true); });
  $("#auto-refresh").addEventListener("change", setTimer);
  $("#only-online").addEventListener("change", renderMachines);

  $("#run-tabs").addEventListener("click", function (e) {
    var b = e.target.closest(".tab");
    if (!b) return;
    RUN_TAB = b.dataset.tab;
    Array.prototype.forEach.call(this.querySelectorAll(".tab"), function (t) {
      t.classList.toggle("active", t === b);
    });
    renderRuns();
  });

  // 新增账号
  $("#btn-add-account").addEventListener("click", function () {
    var f = $("#form-add-account");
    f.hidden = !f.hidden;
    if (!f.hidden) $("#acc-owner").focus();
  });
  $("#btn-add-cancel").addEventListener("click", function () {
    $("#form-add-account").hidden = true;
    $("#acc-add-msg").textContent = "";
  });
  $("#form-add-account").addEventListener("submit", function (e) {
    e.preventDefault();
    var owner = ($("#acc-owner").value || "").trim();
    var repo = ($("#acc-repo").value || "").trim();
    var secret = ($("#acc-secret").value || "").trim();
    var id = ($("#acc-id").value || "").trim();
    var enabled = $("#acc-enabled").checked;
    var msg = $("#acc-add-msg");
    if (!owner || !repo || !secret) {
      msg.textContent = "owner / repo / Secret 名都要填";
      return;
    }
    var btn = $("#btn-add-submit");
    btn.disabled = true;
    msg.textContent = "添加中…";
    api("/api/accounts/add", {
      method: "POST",
      body: JSON.stringify({ owner: owner, repo: repo, token_secret: secret, id: id, enabled: enabled })
    }).then(function (res) {
      toast("已添加账号 " + esc(owner) + "（" + esc(res.id) + "）", "ok");
      if (res.verify_note) toast(esc(res.verify_note), "warn", 8000);
      if (res.hint) toast(esc(res.hint), "info", 12000);
      $("#form-add-account").reset();
      $("#acc-repo").value = "cloud-rdp";
      $("#acc-enabled").checked = true;
      msg.textContent = "";
      $("#form-add-account").hidden = true;
      load(true);
    }).catch(function (err) {
      msg.textContent = "失败：" + err.message;
    }).then(function () { btn.disabled = false; });
  });

  // 账号启用/停用
  $("#tbl-accounts").addEventListener("change", function (e) {
    var cb = e.target.closest("input[data-acc]");
    if (!cb) return;
    var id = cb.dataset.acc, on = cb.checked;
    cb.disabled = true;
    api("/api/accounts/toggle", { method: "POST", body: JSON.stringify({ id: id, enabled: on }) })
      .then(function () {
        toast("账号 " + esc(id) + " 已" + (on ? "启用" : "停用"), "ok");
        load(true);
      })
      .catch(function (err) {
        cb.checked = !on;
        toast("改账号状态失败：" + esc(err.message), "bad");
      })
      .then(function () { cb.disabled = false; });
  });

  // 一键登录 / 生成 .rdp
  $("#tbl-machines").addEventListener("click", function (e) {
    var b = e.target.closest("button");
    if (!b) return;
    var ip = b.dataset.rdp || b.dataset.rdpfile;
    var host = b.dataset.host || "";
    var launch = !!b.dataset.rdp;
    if (!ip) return;
    b.disabled = true;
    api("/api/rdp", { method: "POST", body: JSON.stringify({ ip: ip, hostname: host, launch: launch }) })
      .then(function (res) {
        var msg = (launch ? "已唤起远程桌面：" : "已生成 .rdp：") + "<br><span class='mono'>" + esc(res.path) + "</span>";
        if (res.cred_stored) msg += "<br><span class='muted'>凭据已预存（免手输密码）</span>";
        else if (res.cred_error) msg += "<br><span class='muted'>凭据未预存：" + esc(res.cred_error) + "</span>";
        if (res.launch_error) msg += "<br><span class='muted'>" + esc(res.launch_error) + "</span>";
        toast(msg, "ok");
      })
      .catch(function (err) { toast("登录失败：" + esc(err.message), "bad"); })
      .then(function () { b.disabled = false; });
  });

  // 操作台
  document.querySelector(".ops").addEventListener("click", function (e) {
    var b = e.target.closest("button[data-act]");
    if (!b) return;
    var act = b.dataset.act;
    var payload;
    if (act === "coordinator") {
      if (!confirm("立即触发一次账号池协调器巡检？")) return;
      payload = { target: "coordinator", inputs: { dry_run: "false" } };
    } else if (act === "coordinator-dry") {
      payload = { target: "coordinator", inputs: { dry_run: "true" } };
    } else if (act === "keepalive") {
      var dur = parseInt($("#inp-duration").value, 10) || 350;
      if (!confirm("派发一台保活机，时长 " + dur + " 分钟？")) return;
      payload = { target: "keepalive", inputs: {
        duration_minutes: String(dur),
        install_apps: $("#inp-install").checked ? "true" : "false",
        migrate_139: $("#inp-migrate").checked ? "true" : "false"
      } };
    } else { return; }

    b.disabled = true;
    var old = b.innerHTML;
    b.innerHTML = '<i class="spin"></i> 派发中';
    api("/api/dispatch", { method: "POST", body: JSON.stringify(payload) })
      .then(function (res) {
        toast("已触发 " + esc(res.workflow || payload.target) + "（约 10~60 秒后出现在运行日志）", "ok");
        setTimeout(function () { load(true); }, 12000);
      })
      .catch(function (err) { toast("派发失败：" + esc(err.message), "bad"); })
      .then(function () { b.disabled = false; b.innerHTML = old; });
  });
}

/* ------------------------------------------------------------ 启动 */
bind();
load(false);
setTimeout(setTimer, 1200);
