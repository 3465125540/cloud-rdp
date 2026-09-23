/* GitHub 虚拟机管理工作台 —— 前端逻辑（原生 JS，零依赖） */
"use strict";

var DATA = null;          // 最近一次 /api/overview 的结果
var RUN_TAB = "keepalive"; // 运行日志当前 tab
var RUNS_LIMIT = 0;        // 日志表格行数上限（0 = 不限；「缩略」时 = 5）
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
function pad2(n) { return (n < 10 ? "0" : "") + n; }
// 把后端给的 UTC ISO 时间换算成北京时间字符串，形如 "2026/9/22-20:16"。
// 在前端本地换算 → 不依赖后端是否已升级（旧后端只给 state_updated / created_at 也正确）。
function bjTime(iso) {
  if (!iso) return "";
  var t = Date.parse(iso);
  if (isNaN(t)) return "";
  var d = new Date(t + 8 * 3600 * 1000);   // 先 +8h，再用 UTC getter 读 → 与浏览器本地时区无关
  return d.getUTCFullYear() + "/" + (d.getUTCMonth() + 1) + "/" + d.getUTCDate() +
    "-" + pad2(d.getUTCHours()) + ":" + pad2(d.getUTCMinutes());
}
// 后端返回的不是 JSON（多半是 HTML）时的统一提示。
// 常见于「当前页面不是由工作台后端提供的」——比如用静态预览面板打开、或直接双击 index.html：
// 此时 /api/... 会落到那个静态服务器上，返回它的 HTML，而不是工作台的 JSON。
function notJsonError(ct, text) {
  var head = String(text || "").trim().replace(/\s+/g, " ").slice(0, 60);
  return new Error("后端没有返回 JSON（Content-Type=" + (ct || "未知") +
    "，开头是「" + head + "…」）。这说明当前页面不是由工作台后端在提供：请用浏览器直接打开 " +
    "http://127.0.0.1:8899 （不要用静态预览面板，也不要直接双击 index.html）。");
}
function api(path, opts) {
  opts = opts || {};
  opts.headers = Object.assign({ "Content-Type": "application/json" }, opts.headers || {});
  return fetch(path, opts).then(function (r) {
    var ct = (r.headers.get("Content-Type") || "").toLowerCase();
    if (ct.indexOf("json") < 0) {
      return r.text().then(function (t) { throw notJsonError(ct, t); });
    }
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
    toast("拉取失败：" + esc(e.message), "bad", 12000);
    if (!DATA) {
      // 首次就失败：把原因常驻在页面上（别让它几秒后消失），并给出正确入口
      $("#brand-sub").textContent = "未连上工作台后端";
      $("#errors").innerHTML =
        '<div class="err-line">' + esc(e.message) + "</div>" +
        '<div class="err-line">当前页面：' + esc(location.href) + "</div>" +
        '<div class="err-line">正确入口：<a href="http://127.0.0.1:8899" target="_blank">' +
        "http://127.0.0.1:8899</a>（用浏览器直接打开；不要用应用内预览面板）</div>";
    }
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

  pills.push('<span class="pill ' + (hasErr("GitHub") ? "bad" : "ok") + '" data-tip="GitHub API：拉取运行记录 / Secrets / 账号信息。红点 = 本次拉取失败（详见页脚错误）"><i class="dot"></i>GitHub API</span>');
  pills.push('<span class="pill ' + (hasErr("Tailscale") ? "bad" : "ok") + '" data-tip="Tailscale：发现组网内的机器节点（「机器运行实况」列表的来源）"><i class="dot"></i>Tailscale</span>');
  pills.push('<span class="pill ' + (hasErr("池状态") ? "warn" : "ok") + '" data-tip="池状态：协调器发布的权威状态（账号角色 / 在跑机器）。黄点 = 暂无数据或读取失败"><i class="dot"></i>池状态</span>');
  pills.push('<span class="pill ' + (hasErr("账号池") ? "warn" : "ok") + '" data-tip="账号池配置：scripts/pool-config.json（账号、Secret 名、目标台数）"><i class="dot"></i>账号池配置</span>');
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
    // 状态栏附加：正在运行的时长（起于远端 _state\job-start.txt）
    if (online) {
      st += m.uptime_human
        ? '<div class="uptime" title="起于 ' + esc(m.started_utc || "?") + '">运行 ' + esc(m.uptime_human) + "</div>"
        : '<div class="uptime muted" title="读不到 _state\\job-start.txt（需 SMB 可读）">运行 —</div>';
    }
    var snap = '<span class="muted">—</span>';
    if (m.snapshot && m.snapshot.ok) {
      var sn = m.snapshot;
      var snapTime = bjTime(sn.created) || sn.created_local || "";   // 实时北京时间（UTC+8）
      var parts = [];
      if (snapTime) parts.push(snapTime);
      if (typeof sn.files === "number") parts.push(sn.files + " 文件");
      var snapTip = "快照生成时间（实时北京时间 UTC+8）" + (sn.mode ? "，模式 " + sn.mode : "") +
        "。原始 UTC：" + (sn.created || "?");
      snap = '<span data-tip="' + esc(snapTip) + '">' +
        (sn.stale ? badge(parts.join(" · "), "warn") : badge(parts.join(" · "), "ok")) + "</span>";
    } else if (m.snapshot) {
      snap = '<span class="muted" title="未读到 _snapshot/manifest.json">无快照</span>';
    }
    // 快照栏附「一键备份」按钮（仅在线机器 —— 需经 SMB 把请求文件写到机器上）
    // 合并版：一次点击 = ① 增量同步到 139（rclone copy --update：只传新增/有变化的文件，
    // 已存在的相同文件跳过 → 不重复上传，也不删远端）② 抓一次快速快照并推送。
    if (online) {
      var br = m.backup_request || {};
      if (br.pending) {
        snap += '<div class="backup-box">' +
          '<button class="btn btn-mini btn-backup pending" disabled><i class="spin"></i> 备份中</button>' +
          '<div class="muted backup-note" data-tip="请求已于 ' + esc(br.requested_at || "刚刚") +
          ' 下发（by ' + esc(br.requested_by || "workbench") +
          '）。机器保活循环每分钟取走执行，完成后此行会恢复为可点击">已下发，等待执行</div></div>';
      } else {
        snap += '<div class="backup-box">' +
          '<button class="btn btn-mini btn-backup" data-backup="' + esc(m.ip) +
          '" data-host="' + esc(m.hostname) +
          '" data-tip="立即在机器上执行：① 把数据目录（D:\\a\\cloud-rdp）下新增/有变化的文件增量上传到 139 云盘（rclone copy --update：已存在的相同文件会跳过、不重复上传，也不删远端）② 抓一次快速快照并推送。机器保活循环每分钟取走一次，通常 ≤1 分钟开始，约 1~3 分钟完成">☁ 一键备份</button>' +
          "</div>";
      }
    }
    var lastSeen = online ? '<span class="muted">—</span>'
      : '<span class="muted" title="最后在线（实时北京时间 UTC+8）；原始 UTC：' + esc(m.last_seen || "?") + '">' +
        esc(bjTime(m.last_seen) || m.last_seen_human || "未知") + "</span>";
    var ops = online
      ? '<button class="btn btn-mini btn-primary" data-rdp="' + esc(m.ip) + '" data-host="' + esc(m.hostname) + '">一键登录</button>' +
        ' <button class="btn btn-mini btn-ghost" data-info="' + esc(m.ip) + '" data-host="' + esc(m.hostname) + '">查看信息</button>'
      : '<span class="muted">离线</span>';
    // 主机列第二行：机器归属的账号
    //   来源① 池机器写的 _state\pool-info.txt（pool_owner）→ 映射成账号池 id
    //   来源② 单机/老机器：runner 工作区 .git\config 的 origin owner（owner_source 标明来源）
    var acct = "";
    if (m.account_id || m.pool_owner) {
      var label = [m.account_id, m.pool_owner].filter(function (x) { return !!x; }).join(" · ");
      var src = m.owner_source ? "，来源：" + m.owner_source : "";
      acct = '<div class="acct muted" title="该机器由这个账号派发' + esc(src) + '">' + esc(label) + "</div>";
    } else if (online) {
      acct = '<div class="acct muted" title="读不到机器上的归属信息（SMB 鉴权失败 / 机器未就绪）">账号未知</div>';
    }
    return "<tr>" +
      "<td class=\"strong\">" + esc(m.hostname || "-") + acct + "</td>" +
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
      // 实时北京时间（绝对时间，UTC+8）：前端从原始 UTC 换算，旧后端（只给 state_updated）也正确
      var bj = bjTime(acc.state_updated) || acc.state_updated_beijing || "?";
      bits.push("监测数据 " + bj + " 北京" + (acc.state_via ? "（" + acc.state_via + "）" : ""));
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
    if (a.secret_present === true) {
      secret = badge("已配置", "ok");
      if (a.secret_via === "pool_tokens") secret += ' <span class="muted" title="token 来自 hub 仓库的 JSON Secret POOL_TOKENS">(JSON)</span>';
    } else if (a.secret_present === false) {
      secret = badge("缺失", "bad");
    } else if (a.secret_via === "pool_tokens") {
      secret = '<span class="muted" title="hub 仓库存在 POOL_TOKENS（JSON）；其值 GitHub 永不回显，无法确认是否含本账号。以「凭证」列的协调器巡检结果为准">可能已配置</span>';
    } else {
      secret = '<span class="muted">未知</span>';
    }

    // ---- 实时监测列：凭证状态 + 在跑机数 + 最近一次 run ----
    var mon = [tokenStateBadge(a.token_state)];
    if (a.alive_count !== null && a.alive_count !== undefined) {
      mon.push('<span class="mon-num">在跑 ' + esc(a.alive_count) + " 台</span>");
    }
    if (a.last_run) {
      var lrj = bjTime(a.last_run.created_at) || a.last_run.created_beijing || "";
      mon.push('<span class="mon-run">' + badge(a.last_run.state || "-", runStateKind(a.last_run.state)) +
        (lrj ? ' <span class="muted" title="北京时间（UTC+8）；原始 UTC：' +
          esc(a.last_run.created_at || "?") + '">' + esc(lrj) + "</span>" : "") + "</span>");
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
  var all = r[RUN_TAB] || [];
  var tb = $("#tbl-runs tbody");
  $("#runs-empty").hidden = all.length > 0;
  if (!r.ok && !all.length) {
    tb.innerHTML = '<tr><td colspan="8" class="empty">' + esc(r.error || "读取失败") + "</td></tr>";
    return;
  }
  // 「缩略」时只渲染最近 N 条，其余折叠成一行提示
  var rows = all, hidden = 0;
  if (RUNS_LIMIT > 0 && all.length > RUNS_LIMIT) {
    rows = all.slice(0, RUNS_LIMIT);
    hidden = all.length - RUNS_LIMIT;
  }
  var html = rows.map(function (x) {
    var st = badge(x.state || "-", x.in_progress ? "info" : (x.conclusion === "success" ? "ok" : (x.conclusion === "cancelled" ? "warn" : "bad")));
    var ev = x.event === "schedule" ? badge("定时", "mute") : badge(x.event || "-", "info");
    return "<tr>" +
      '<td class="mono">#' + esc(x.number) + "</td>" +
      "<td>" + st + "</td>" +
      "<td>" + ev + "</td>" +
      '<td class="nowrap"><span title="北京时间（UTC+8）；原始 UTC：' + esc(x.created_at) + '">' + esc(bjTime(x.created_at) || x.created_beijing || "-") + "</span></td>" +
      '<td class="mono nowrap">' + esc(x.duration) + "</td>" +
      '<td class="mono">' + esc(x.head_sha) + "</td>" +
      '<td class="dim">' + esc(x.title || "-") + "</td>" +
      '<td class="right">' + (x.url ? '<a href="' + esc(x.url) + '" target="_blank" rel="noopener">日志</a>' : '<span class="muted">—</span>') + "</td>" +
      "</tr>";
  }).join("");
  if (hidden > 0) {
    html += '<tr class="more-row"><td colspan="8" class="muted">已缩略：仅显示最近 ' +
      RUNS_LIMIT + " 条，另有 " + hidden + " 条未显示 —— 点右上角「展开全部」查看</td></tr>";
  }
  tb.innerHTML = html;
}

function renderErrors() {
  var errs = DATA.errors || [];
  $("#errors").innerHTML = errs.map(function (e) {
    return '<div class="err-line">' + esc(e) + "</div>";
  }).join("");
  $("#foot-meta").textContent = "workbench v" + (DATA.version || "?") +
    (DATA.started_at ? "（服务启动于 " + DATA.started_at + "）" : "") +
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

/* ------------------------------------------------------------ 卡片「缩略」 */
// 任何带 data-collapse="<key>" 的按钮：点击切换所在 .card 的形态，状态记进 localStorage。
//   * 普通卡片：收起 / 展开整个 card-body（.card.collapsed）
//   * 带 data-limit="N" 的卡片：缩略 = 只显示表格前 N 行（不隐藏卡片）—— 日志板块用
function initCollapse() {
  Array.prototype.forEach.call(document.querySelectorAll("[data-collapse]"), function (btn) {
    var key = "wb.collapse." + btn.dataset.collapse;
    var card = btn.closest(".card");
    if (!card) return;
    var limit = parseInt(btn.dataset.limit, 10) || 0;
    var collapsed = false;

    function apply(c) {
      collapsed = c;
      if (limit > 0) {
        RUNS_LIMIT = c ? limit : 0;
        card.classList.toggle("rows-limited", c);
        btn.innerHTML = c ? "展开全部 &#9662;" : "缩略 &#9652;";
        btn.title = c ? "展开全部日志" : "缩略为最近 " + limit + " 条";
      } else {
        card.classList.toggle("collapsed", c);
        btn.innerHTML = c ? "展开 &#9662;" : "缩略 &#9652;";
        btn.title = c ? "展开表格" : "缩略 / 展开表格";
      }
      btn.setAttribute("aria-expanded", c ? "false" : "true");
      if (limit > 0 && DATA) renderRuns();   // 立即按新的行数上限重渲染
    }

    var saved = null;
    try { saved = localStorage.getItem(key); } catch (e) {}
    apply(saved === "1");
    btn.addEventListener("click", function () {
      apply(!collapsed);
      try { localStorage.setItem(key, collapsed ? "1" : "0"); } catch (e) {}
    });
  });
}

/* ------------------------------------------------------------ 连接信息弹窗 */
function openModal(title, html) {
  $("#modal-title").textContent = title;
  $("#modal-body").innerHTML = html;
  $("#modal").hidden = false;
}
function closeModal() { $("#modal").hidden = true; }

function copyText(t) {
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(t);
      return true;
    }
  } catch (e) {}
  try {
    var ta = document.createElement("textarea");
    ta.value = t;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    document.execCommand("copy");
    document.body.removeChild(ta);
    return true;
  } catch (e) { return false; }
}

function connRow(label, value) {
  return '<div class="conn-row"><span class="conn-k">' + esc(label) + "</span>" +
    '<span class="conn-v mono" data-copy="' + esc(value) + '" title="点击复制">' + esc(value) + "</span></div>";
}

function showConnInfo(ip, host) {
  var title = "连接信息" + (host ? " · " + host : "");
  openModal(title, '<div class="muted">读取中…</div>');
  api("/api/conn-info?ip=" + encodeURIComponent(ip)).then(function (c) {
    var mode = c.launch_mode || "mstsc";
    var modeLabel = mode === "file"
      ? "打开 .rdp 文件（2026-04 更新后会弹「安全警告」）"
      : "mstsc /v: 命令行（不触发 .rdp 安全警告）";
    var d = c.default_rdp || {};
    var authLine = "";
    var fixBtn = "";
    if (mode !== "file") {
      if (d.auth_zero) {
        authLine = '<div class="muted">证书警告：已关闭（Default.rdp authentication level=0）</div>';
      } else {
        var lv = (d.auth_level === null || d.auth_level === undefined) ? "未设置" : String(d.auth_level);
        authLine = '<div class="warn-line">证书警告未关闭（Default.rdp authentication level=' +
          esc(lv) + '）—— 连接自签证书机器时会弹「无法验证身份」</div>';
        fixBtn = '<button class="btn btn-mini" data-fix-default="1">修复证书警告</button>';
      }
    }
    var html =
      '<div class="conn-list">' +
        connRow("Tailscale IP :", c.ip || ip) +
        connRow("Username     :", c.username || "") +
        connRow("Password     :", c.password || "") +
      "</div>" +
      '<div class="conn-note">' +
        '<div class="muted">唤起方式：' + esc(modeLabel) + "</div>" +
        authLine +
      "</div>" +
      '<div class="conn-foot">' +
        '<button class="btn btn-primary btn-mini" data-conn-login="' + esc(ip) +
          '" data-host="' + esc(host || "") + '">一键登录</button>' +
        fixBtn +
        '<button class="btn btn-mini" data-copy-all="1">复制全部</button>' +
        '<span class="muted">点任意一行可复制该值</span>' +
      "</div>";
    openModal(title, html);
  }).catch(function (e) {
    openModal(title, '<div class="err-line">' + esc(e.message) + "</div>");
  });
}

/* ------------------------------------------------------------ 一键备份 */
// 机器是 GitHub Actions runner，没有对外命令通道；工作台经 SMB 把请求文件写到机器上，
// 机器的保活循环每分钟取走 → 执行「同步用户数据到 139 + 快速快照推送」。
function doBackup(btn) {
  var ip = btn.dataset.backup, host = btn.dataset.host || "";
  if (!confirm("对「" + (host || ip) + "」执行一键备份？\n\n将在机器上：\n" +
               "  · 把数据目录（D:\\a\\cloud-rdp）下新增/有变化的文件增量同步到 139 云盘\n" +
               "    （rclone copy --update：已存在的相同文件跳过、不重复上传，也不删远端）\n" +
               "  · 抓一次快速快照并推送\n\n通常 1~3 分钟完成。")) return;
  btn.disabled = true;
  var old = btn.innerHTML;
  btn.innerHTML = '<i class="spin"></i> 下发中';
  api("/api/backup", { method: "POST", body: JSON.stringify({ ip: ip }) })
    .then(function (res) {
      toast("已下发备份请求" + (host ? "（" + esc(host) + "）" : "") +
        "<br><span class='muted'>" + esc(res.note || "机器将在 ≤1 分钟内执行") + "</span>", "ok", 9000);
      setTimeout(function () { load(true); }, 8000);   // 稍后刷新，让按钮切到「已下发」
    })
    .catch(function (err) {
      toast("一键备份失败：" + esc(err.message), "bad", 10000);
      btn.disabled = false;
      btn.innerHTML = old;
    });
}

/* ------------------------------------------------------------ 悬浮提示（data-tip） */
// 任何带 data-tip="..." 的元素，鼠标停留时在它附近浮出一段说明（纯文本，\n 换行）。
function initTips() {
  var tip = $("#tip");
  if (!tip) return;
  var cur = null;
  function place(el) {
    tip.hidden = false;
    var r = el.getBoundingClientRect();
    var tw = tip.offsetWidth, th = tip.offsetHeight;
    var left = r.left + r.width / 2 - tw / 2;
    left = Math.max(8, Math.min(left, window.innerWidth - tw - 8));
    var top = r.top - th - 9;
    if (top < 8) top = r.bottom + 9;            // 上方放不下 → 放到下面
    tip.style.left = left + "px";
    tip.style.top = top + "px";
  }
  function show(el) {
    var t = el.getAttribute("data-tip");
    if (!t) return;
    cur = el;
    tip.innerHTML = esc(t).replace(/\n/g, "<br>");
    place(el);
  }
  function hide() { cur = null; tip.hidden = true; }

  document.addEventListener("mouseover", function (e) {
    var el = e.target.closest && e.target.closest("[data-tip]");
    if (el) { if (el !== cur) show(el); }
    else if (cur) hide();
  });
  document.addEventListener("mouseout", function (e) {
    if (!cur) return;
    var to = e.relatedTarget;                    // 移到同一提示元素内部的子节点不算离开
    if (to && to.closest && to.closest("[data-tip]") === cur) return;
    hide();
  });
  document.addEventListener("scroll", hide, true);
  window.addEventListener("blur", hide);
  window.addEventListener("resize", hide);
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

  // 一键登录 / 查看连接信息
  $("#tbl-machines").addEventListener("click", function (e) {
    var b = e.target.closest("button");
    if (!b) return;
    if (b.dataset.backup) { doBackup(b); return; }
    if (b.dataset.info) { showConnInfo(b.dataset.info, b.dataset.host || ""); return; }
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
        if (res.launch_note) msg += "<br><span class='muted'>" + esc(res.launch_note) + "</span>";
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

  // 连接信息弹窗：关闭 / 复制 / 弹窗内一键登录
  $("#modal").addEventListener("click", function (e) {
    if (e.target.closest("[data-modal-close]")) { closeModal(); return; }
    var cv = e.target.closest("[data-copy]");
    if (cv) { copyText(cv.dataset.copy); toast("已复制：" + esc(cv.dataset.copy), "ok"); return; }
    if (e.target.closest("[data-copy-all]")) {
      var lines = [];
      Array.prototype.forEach.call(this.querySelectorAll(".conn-row"), function (r) {
        lines.push(r.querySelector(".conn-k").textContent + " " + r.querySelector(".conn-v").textContent);
      });
      copyText(lines.join("\n"));
      toast("已复制连接信息", "ok");
      return;
    }
    var fx = e.target.closest("[data-fix-default]");
    if (fx) {
      fx.disabled = true;
      api("/api/rdp/default", { method: "POST" }).then(function (r) {
        if (r.ok) toast("已修复：" + esc(r.note || "Default.rdp authentication level=0"), "ok");
        else toast("修复失败：" + esc(r.note || "未知错误"), "bad");
      }).catch(function (err) { toast("修复失败：" + esc(err.message), "bad"); })
        .then(function () { fx.disabled = false; });
      return;
    }
    var lb = e.target.closest("[data-conn-login]");
    if (lb) {
      lb.disabled = true;
      api("/api/rdp", { method: "POST", body: JSON.stringify({
        ip: lb.dataset.connLogin, hostname: lb.dataset.host || "", launch: true }) })
        .then(function (res) {
          var msg = "已唤起远程桌面：<br><span class='mono'>" + esc(res.path) + "</span>";
          if (res.cred_stored) msg += "<br><span class='muted'>凭据已预存（免手输密码）</span>";
          if (res.launch_note) msg += "<br><span class='muted'>" + esc(res.launch_note) + "</span>";
          toast(msg, "ok");
          closeModal();
        })
        .catch(function (err) { toast("登录失败：" + esc(err.message), "bad"); })
        .then(function () { lb.disabled = false; });
    }
  });
  document.addEventListener("keydown", function (e) { if (e.key === "Escape") closeModal(); });

  // 卡片「缩略」按钮（日志板块等）
  initCollapse();

  // 子词条悬浮说明（data-tip）
  initTips();
}

/* ------------------------------------------------------------ 启动 */
bind();
load(false);
setTimeout(setTimer, 1200);
