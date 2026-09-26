/* GitHub 虚拟机管理工作台 —— 前端逻辑（原生 JS，零依赖） */
"use strict";

var DATA = null;          // 最近一次 /api/overview 的结果
var RUN_TAB = "keepalive"; // 运行日志当前 tab（workflow：keepalive | coordinator）
var RUN_ACC = "all";       // 运行日志当前账号筛选（"all" = 全部账号分组视图；否则是账号 owner）
var RUNS_LIMIT = 0;        // 日志表格行数上限（0 = 不限；「缩略」时 = 每账号 5）
var TIMER = null;
var BUSY = false;
var STALE_RETRY = null;    // 收到「陈旧快照」后的补拉定时器（后端在后台重建，稍后取新值）

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

/* ------------------------------------------------------------ 下载（导出 / .rdp） */
// 入口带了 ?token= 时给下载 URL 也带上（Cookie 之外的双保险；正常情况 Cookie 已够）
function withToken(url) {
  var m = /[?&]token=([^&]+)/.exec(location.search);
  if (!m) return url;
  return url + (url.indexOf("?") >= 0 ? "&" : "?") + "token=" + m[1];
}

// 通用「下载」：fetch + blob，而不是直接 location.href —— 后端报错时能弹 toast，
// 而不是把一坨 JSON / 401 页面甩到新标签页。文件名优先从 Content-Disposition 取。
function downloadFrom(url, fallbackName, okMsg) {
  fetch(url).then(function (r) {
    if (!r.ok) {
      return r.text().then(function (t) {
        var msg = t;
        try { var j = JSON.parse(t); if (j && j.error) msg = j.error; } catch (_) {}
        throw new Error(msg || ("HTTP " + r.status));
      });
    }
    var cd = r.headers.get("Content-Disposition") || "";
    var fm = /filename="?([^";]+)"?/i.exec(cd);
    var fn = fm ? fm[1] : (fallbackName || "download");
    return r.blob().then(function (b) { return { b: b, fn: fn }; });
  }).then(function (o) {
    var a = document.createElement("a");
    a.href = URL.createObjectURL(o.b);
    a.download = o.fn;
    document.body.appendChild(a);
    a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 1500);
    toast(okMsg || ("已下载 <span class='mono'>" + esc(o.fn) + "</span>"), "ok");
  }).catch(function (e) {
    toast("下载失败：" + esc(e.message), "bad", 12000);
  });
}

// 导出当前面板数据：走后端 /api/export（响应带 Content-Disposition: attachment）。
function exportData(what, format) {
  var url = withToken("/api/export?what=" + encodeURIComponent(what) +
                      "&format=" + encodeURIComponent(format));
  toast("正在导出 " + esc(what) + "（" + esc(String(format).toUpperCase()) + "）…", "info", 8000);
  downloadFrom(url, "workbench-" + what + "." + format, null);
}

// 下载 .rdp 到**本机** —— 远端部署时「一键登录」的正解：服务端不弹窗（无头，弹了也看不到），
// 只把连接参数渲染成 .rdp，由浏览器保存到你的电脑，双击即用本机 mstsc 连接。
function downloadRdp(ip, host) {
  if (!ip) return;
  var url = withToken("/api/rdp/download?ip=" + encodeURIComponent(ip) +
                      "&host=" + encodeURIComponent(host || ""));
  toast("正在生成并下载 .rdp…", "info", 6000);
  downloadFrom(url, "RDP-" + (host || ip) + ".rdp",
    "已下载 <span class='mono'>.rdp</span> —— <b>双击</b>即可用本机远程桌面连接" +
    "<br><span class='muted'>证书警告已在文件里关掉（authentication level=0）</span>");
}

// 本机命令提示：服务端不知道你本地是什么系统，所以按**浏览器所在系统**给一条可粘贴的命令。
function localRdpCmd(c) {
  var p = localPlatform();
  var ip = c.ip || "", u = c.username || "", pw = c.password || "";
  if (p.indexOf("win") >= 0) return "mstsc /v:" + ip;
  if (p.indexOf("mac") >= 0) return 'open "rdp://full%20address=s:' + ip + "&username=s:" + u + '"';
  return "xfreerdp /v:" + ip + " /u:" + u + " /p:" + pw + " /cert:ignore /dynamic-resolution";
}

/* ------------------------------------------------------------ 拉数据 */
// 收到「陈旧快照」后，稍后补拉一次：后端正在后台重建，早点把新值取回来（别一直看旧值）。
// 若正好撞上一次在途请求（BUSY）就顺延，别把这次补拉丢了。
function scheduleStaleRetry(ms) {
  if (STALE_RETRY) return;
  STALE_RETRY = setTimeout(function () {
    STALE_RETRY = null;
    if (BUSY) { scheduleStaleRetry(ms); return; }
    load(false);
  }, ms || 5000);
}
function load(force) {
  if (BUSY) return;
  BUSY = true;
  var url = "/api/overview" + (force ? "?refresh=1" : "");
  api(url).then(function (d) {
    if (d.warming) {
      // 首屏骨架：后端还在构建第一份数据 —— 先别渲染（免得把「0 台机器」当真），
      // 只提示「正在加载」并稍后轮询；构建好之后就能拿到完整数据。
      var el0 = $("#last-updated");
      el0.textContent = "正在加载数据…";
      el0.title = "后端正在构建首屏数据（首次约几秒；之后每次刷新都是秒回）";
      scheduleStaleRetry(2000);
      return;
    }
    DATA = d;
    render();
    // 后端现在返回的是「快照」：陈旧时会先把旧值秒回、再在后台重建。
    // 所以「更新于」要用数据自己的生成时间（generated_at），而不是「这次请求到达的时间」。
    var when = d.generated_at ? new Date(d.generated_at) : new Date();
    var el = $("#last-updated");
    var txt = "更新于 " + when.toLocaleTimeString("zh-CN");
    if (d.stale) {
      txt += " · 后台刷新中…";
      el.title = "当前显示的是约 " + (d.age_seconds || 0) + " 秒前的快照；后端正在后台拉取最新数据，稍后自动更新";
      scheduleStaleRetry();
    } else {
      el.title = "数据生成于 " + (d.generated_at || "?") + "（服务 v" + (d.version || "?") + "）";
    }
    el.textContent = txt;
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
  updateFoldAllLabel();
  renderAccounts();
  renderRunAccTabs();
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
    { k: "恢复异常", v: (s.machines_data_bad || 0) + " 数据 · " + (s.machines_snapshot_bad || 0) + " 快照",
      s: "未从 139 拉取成功的机器数", cls: (s.machines_data_bad || s.machines_snapshot_bad) ? "bad" : "good" },
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

/* 数据/快照「恢复状态」徽章。
   数据来自机器上的 _state\restore-status.json（脚本侧 remote-lib.ps1 的 Set-RestoreStatus 写入，
   按 data / snapshot 两个作用域合并）。这是 acc-1 事故之后新增的一列 —— 那台机器没从 139 云盘
   拉到数据，界面却显示「已同步」，所以这里把「没拉到 / 拉取失败 / 网络抖动待重试」直接摆到台面上。
   口径与后端 server.py 的 restore_kind() 保持一致：
     OK / PARTIAL      → ok   已还原（PARTIAL = 部分还原）
     EMPTY / SKIPPED   → mute 139 上确无数据（终态，不是错误）
     TRANSIENT/PENDING → warn 网络抖动 / 正在后台拉取，保活循环会自动重试
     FAILED / AUTH     → bad  失败 / 鉴权异常，需要人工处理 */
function restoreKind(st) {
  st = String(st || "").toUpperCase();
  if (st === "OK" || st === "PARTIAL") return "ok";
  if (st === "EMPTY" || st === "SKIPPED") return "mute";
  if (st === "TRANSIENT" || st === "PENDING") return "warn";
  if (st === "FAILED" || st === "AUTH") return "bad";
  return "mute";
}

function restoreLine(label, obj) {
  var st = String((obj && obj.status) || "").toUpperCase();
  if (!st) return "";
  var reason = String((obj && obj.reason) || "").trim();
  var when = bjTime((obj && obj.at_utc) || "");
  var tip = label + "：" + st + (reason ? "　原因：" + reason : "") + (when ? "　记录于 " + when : "");
  return '<span data-tip="' + esc(tip) + '">' + badge(label + " " + st, restoreKind(st)) + "</span>";
}

function restoreBadge(restore) {
  restore = restore || {};
  var d = restore.data || {}, s = restore.snapshot || {};
  if (!d.status && !s.status) {
    return '<span class="muted" data-tip="机器上还没有 _state\\restore-status.json' +
      '（未运行新脚本，或 SMB 读不到机器上的状态文件）">—</span>';
  }
  var html = "";
  if (d.status) html += '<div class="rs">' + restoreLine("数据", d) + "</div>";
  if (s.status) html += '<div class="rs">' + restoreLine("快照", s) + "</div>";
  return html;
}

// ---------------- 状态栏「状态详情」折叠 ----------------
// 状态栏 = 徽标（在线 / 运行中 / 已结束…）+ 一行详情（run 号 / 起跑时间 / 运行时长）。
// 详情行是 nowrap 的，机器一多就把表格撑得很宽 —— 所以给它加折叠：点徽标旁的小箭头收起/展开。
// 折叠状态记在 localStorage，自动刷新后保持（否则每次刷新都弹回来，等于没有）。

// 稳定行键：池内机器用 account_id，Tailscale 节点用 dns_name / ip。取不到就不给折叠箭头。
function machineKey(m) {
  return String(m.account_id || m.dns_name || m.ip || m.hostname || "");
}

var FOLD_DETAILS = (function () {
  var KEY = "wb.foldDetails";
  var map = {};
  try { map = JSON.parse(localStorage.getItem(KEY) || "{}") || {}; } catch (e) { map = {}; }
  function save() { try { localStorage.setItem(KEY, JSON.stringify(map)); } catch (e) { /* 隐私模式等：忽略 */ } }
  return {
    has: function (k) { return !!(k && map[k]); },
    toggle: function (k) {
      if (!k) return false;
      if (map[k]) { delete map[k]; } else { map[k] = 1; }
      save();
      return !!map[k];
    },
    setAll: function (keys, on) {
      (keys || []).forEach(function (k) {
        if (!k) return;
        if (on) { map[k] = 1; } else { delete map[k]; }
      });
      save();
    },
    count: function (keys) {
      return (keys || []).filter(function (k) { return !!map[k]; }).length;
    }
  };
})();

// 当前表里所有可折叠行的键（Tailscale 节点 + 池内机器）。
function collectMachineKeys() {
  var all = (DATA.machines || []).concat(DATA.pool_machines || []);
  return all.map(machineKey).filter(function (k) { return !!k; });
}

// 状态栏单元格：徽标 + 折叠箭头 + 详情行。detailHtml 为空则原样返回徽标（没有可折叠的东西）。
function statusCell(badgeHtml, detailHtml, key) {
  if (!detailHtml) return badgeHtml;
  key = key || "";
  var folded = FOLD_DETAILS.has(key);
  var caret = key
    ? '<button type="button" class="fold-caret" data-fold="' + esc(key) + '"' +
      ' aria-expanded="' + (folded ? "false" : "true") + '"' +
      ' title="' + (folded ? "展开" : "折叠") + '状态详情">' +
      (folded ? "\u25B8" : "\u25BE") + "</button>"
    : "";
  return '<div class="st-wrap' + (folded ? " folded" : "") + '">' +
    '<span class="st-head">' + badgeHtml + caret + "</span>" +
    '<div class="st-detail">' + detailHtml + "</div>" +
    "</div>";
}

// 点小箭头：折叠/展开这一行的状态详情（就地改 DOM，不重绘整表 —— 免得表格闪一下）。
function toggleFoldDetail(btn) {
  var key = btn.getAttribute("data-fold") || "";
  if (!key) return;
  var folded = FOLD_DETAILS.toggle(key);
  var wrap = btn.closest(".st-wrap");
  if (wrap) wrap.classList.toggle("folded", folded);
  btn.textContent = folded ? "\u25B8" : "\u25BE";
  btn.setAttribute("aria-expanded", folded ? "false" : "true");
  btn.title = (folded ? "展开" : "折叠") + "状态详情";
  updateFoldAllLabel();
}

// 「折叠详情 / 展开详情」按钮的文案：全部收起时才显示「展开详情」。
function updateFoldAllLabel() {
  var el = $("#btn-fold-all");
  if (!el) return;
  var keys = collectMachineKeys();
  var allFolded = keys.length > 0 && FOLD_DETAILS.count(keys) === keys.length;
  el.textContent = allFolded ? "展开详情" : "折叠详情";
  el.disabled = keys.length === 0;
}

// 一键登录按钮：远端部署（DATA.config.rdp_local）时文案改成「下载 .rdp」
// —— 点击 = 把 .rdp 下载到**你本机**（服务端无头，弹不出你能看到的窗口）；
// 本机部署时是「一键登录」—— 服务端直接弹 mstsc。
function rdpBtn(ip, hostLabel, rCls, rTip) {
  var local = !!(DATA && DATA.config && DATA.config.rdp_local);
  var tip = local
    ? "工作台部署在远端服务器，无法在你本机弹窗 —— 点击把 .rdp 下载到你电脑，双击即可连接"
    : (rTip || "");
  return '<button class="btn btn-mini ' + (rCls || "btn-primary") + '" data-rdp="' + esc(ip) +
    '" data-host="' + esc(hostLabel) + '"' + (tip ? ' data-tip="' + esc(tip) + '"' : "") + ">" +
    (local ? "下载 .rdp" : "一键登录") + "</button>";
}

// 池内机器行：账号池状态说这台「已派发/在跑」，但本机 Tailscale 视图看不到它的节点。
// 存在的意义 —— 机器不会因为 tailnet 掉线就从面板里整台消失（那正是「像少了几台机器」的元凶）。
// 徽标由 machine_state 决定：job in_progress 就是「运行中」，绝不写死「Tailscale 未上线」
// —— 否则会出现「GitHub 说 job 在跑、面板说没在跑」的自相矛盾（Tailscale 看不到 ≠ 机器没在跑）。
function poolOnlyRow(m) {
  var label = [m.account_id, m.pool_owner].filter(function (x) { return !!x; }).join(" · ") || "未命名账号";
  var stMap = { in_progress: "Actions job 运行中", queued: "排队中", pending: "等待启动",
                waiting: "等待中", requested: "已请求", action_required: "待处理",
                completed: "已结束", cancelled: "已取消", skipped: "已跳过",
                failure: "已失败", timed_out: "已超时" };
  var stText = stMap[m.run_status] || (m.run_status || "无 run 状态");
  var state = m.machine_state || "unknown";
  var since = m.since ? (bjTime(m.since) || m.since) : "";
  // IP 兜底来源：这台机器自己的 Actions job 日志（workflow 第 0c 步自报 Tailscale IP）。
  // 本机 tailnet 看不到该节点时这是唯一能拿到 IP 的路子 —— pool-state 里根本没有 IP 字段。
  var ip = m.ip || "";
  var ipNote = ip ? "（来自该机器的 Actions job 日志）" : "";
  var badgeHtml, tip;
  if (state === "running") {
    // 一次性 runner 的存在性 = job 的存在性：job 在跑 ⇒ 机器在跑。
    badgeHtml = badge("运行中", "ok");
    tip = "GitHub Actions 的 job 仍是 in_progress —— 这台机器确实在运行。" +
      "本机 Tailscale 视图看不到它的节点（tailnet 状态同步滞后 / 节点掉线都可能），" +
      (ip ? "IP 是从它自己的 job 日志里读出来的。" : "IP 也读不到（job 日志拿不到）。") +
      "点右侧「运行日志」可看实时进度。";
  } else if (state === "dispatched") {
    badgeHtml = badge("已派发 · 排队中", "warn");
    tip = "账号池已把这台派出去，但 job 还没进入运行（排队 / 等待启动）。" +
      "本机 Tailscale 视图也还没看到它的节点。" + (ip ? "IP 已从 job 日志读到。" : "");
  } else if (state === "ended") {
    badgeHtml = badge("已结束", "mute");
    tip = "这个池槽位对应的 run 已经结束，机器应已销毁 —— Tailscale 上看不到它的节点是正常的。";
  } else {
    badgeHtml = badge("已派发 · 状态未知", "warn");
    tip = "账号池里这个槽位被占用，但拿不到对应 run 的状态（例如 fork 仓库不可读 / run_id 缺失）。" +
      "本机 Tailscale 视图也看不到它的节点。";
  }
  var detail = '<div class="uptime muted">' + esc(stText) +
    (m.run_id ? " · run " + esc(String(m.run_id)) : "") +
    (since ? " · 自 " + esc(since) : "") + "</div>";
  var st = statusCell(badgeHtml, detail, machineKey(m));

  // IP 列：有就显示真 IP（来源写进 tooltip），没有才留「—」并说明为什么。
  var ipCell = ip
    ? '<span class="mono" data-tip="该 IP 来自这台机器自己的 Actions job 日志（第 0c 步机器自报 ' +
      'Tailscale IP: ' + esc(ip) + '）。本机 tailnet 视图看不到它的节点，所以用日志兜底。">' +
      esc(ip) + "</span>"
    : '<span class="none" data-tip="拿不到 IP：本机 tailnet 看不到该节点，且读不到它的 Actions job 日志' +
      '（fork 仓库不可读 / run 还没开始 / 日志已过期）。机器是否在跑以「状态」列的 Actions job 为准。">—</span>';

  // 操作列：一键登录 + 查看信息（有 IP 才有）+ 运行日志。
  // 可达性是后端现探的（TCP 3389，60 秒缓存）—— 不可达时按钮转黄并说明原因，
  // 而不是假装能连（机器已销毁时点了必然失败，说清楚比让用户白等强）。
  var hostLabel = m.account_id || m.pool_owner || ip;
  var ops = [];
  if (ip) {
    var rTip = m.reachable === true
      ? "刚探测过 " + ip + ":3389 是通的，直接连。"
      : (m.reachable === false
          ? "IP 已知" + ipNote + "，但刚探测 3389 不通 —— 机器可能已销毁 / tailnet 掉线。" +
            "点了大概率连不上，进度以「运行日志」为准。"
          : "IP 已知" + ipNote + "。未做端口探测。");
    var rCls = m.reachable === false ? "btn-warn" : "btn-primary";
    ops.push(rdpBtn(ip, hostLabel, rCls, rTip));
    ops.push('<button class="btn btn-mini btn-ghost" data-info="' + esc(ip) +
             '" data-host="' + esc(hostLabel) + '">查看信息</button>');
  }
  if (m.run_url) {
    ops.push('<a class="btn btn-mini btn-ghost" href="' + esc(m.run_url) +
             '" target="_blank" rel="noopener">运行日志</a>');
  }
  var opsHtml = ops.length ? ops.join(" ") : '<span class="none">—</span>';
  return "<tr>" +
    '<td class="strong"><span data-tip="' + esc(tip) + '">' + esc(label) + "</span>" +
    '<div class="acct muted">池内机器 · ' + esc(m.role || "?") + "</div></td>" +
    '<td class="mono">' + ipCell + "</td>" +
    "<td>" + st + "</td>" +
    "<td>" + roleBadge(m.role) + "</td>" +
    '<td><span class="none">—</span></td>' +
    '<td><span class="none">—</span></td>' +
    '<td><span class="none">—</span></td>' +
    '<td class="right ops-cell">' + opsHtml + "</td>" +
    "</tr>";
}

function renderMachines() {
  var nodes = DATA.machines || [];        // Tailscale 节点
  var poolOnly = DATA.pool_machines || []; // 账号池说「已派发/在跑」、但 Tailscale 上看不到的机器
  var all = nodes.concat(poolOnly);
  var onlyOnline = $("#only-online").checked;
  // 「只看在线」不该把「在跑但本机 Tailscale 看不到」的池内机器一起藏掉 —— 那正是最需要看见的。
  // 只有「已结束」的池槽位既不在线也没在跑，勾选时才跟着藏起来。
  var rows = onlyOnline
    ? all.filter(function (m) { return m.online || (m.pool_only && m.machine_state !== "ended"); })
    : all;
  var tb = $("#tbl-machines tbody");
  $("#machines-empty").hidden = rows.length > 0;
  var onlineN = nodes.filter(function (m) { return m.online; }).length;
  var poolRunning = poolOnly.filter(function (m) { return m.machine_state === "running"; }).length;
  var metaEl = $("#machines-meta");
  var metaParts = [];
  if (nodes.length) {
    metaParts.push("在线 " + onlineN + " / 共 " + nodes.length + " 个节点（前缀 " +
      ((DATA.config || {}).machine_prefix || "") + "*）");
  }
  if (poolOnly.length) {
    metaParts.push("另有 " + poolOnly.length + " 台池内机器" +
      (poolRunning ? "（" + poolRunning + " 台运行中）" : "") + "，本机 Tailscale 视图未看到其节点");
  }
  metaEl.textContent = metaParts.join(" · ");
  // 离线节点基本都是一次性 Actions runner 跑完没从 tailnet 摘掉的残留（不是故障）。
  metaEl.title = nodes.length
    ? ("前缀 " + ((DATA.config || {}).machine_prefix || "") + "* 的 Tailscale 节点。"
       + "离线节点多为一次性 runner 结束后残留在 tailnet 里的记录（机器已销毁，不是故障）；"
       + "可在 Tailscale 控制台按最后在线时间清理。"
       + "另：「池内机器」行来自账号池状态 —— 机器是否在跑以它的 Actions job 为准"
       + "（job in_progress 就是「运行中」）；本机 tailnet 看不到它的节点不代表机器没在跑。")
    : "";

  tb.innerHTML = rows.map(function (m) {
    if (m.pool_only) return poolOnlyRow(m);
    var online = !!m.online;
    // 节点唯一名：一次性 runner 的 HostName 全是 github-rdp-server，
    // 只有 Tailscale 的 DNSName 带去重后缀（github-rdp-server-11）能区分是哪台。
    var nodeName = m.dns_name || m.hostname || "";
    var hostTip = "Tailscale 节点 " + (nodeName || "?") +
      (m.dns_name && m.hostname ? "（设备主机名 " + m.hostname + "）" : "") +
      " · IP " + (m.ip || "?");
    var stBadge = online
      ? badge("在线" + (m.active ? " · 活跃" : ""), "ok")
      : badge("离线", "bad");
    // 状态栏附加：正在运行的时长（起于远端 _state\job-start.txt）—— 和池内机器一样可折叠
    var stDetail = "";
    if (online) {
      stDetail = m.uptime_human
        ? '<div class="uptime" title="起于 ' + esc(m.started_utc || "?") + '">运行 ' + esc(m.uptime_human) + "</div>"
        : '<div class="uptime muted" title="读不到 _state\\job-start.txt（需 SMB 可读）">运行 —</div>';
    }
    var st = statusCell(stBadge, stDetail, machineKey(m));
    // 快照列 = 时间徽章（第一行）+ 一键备份按钮（第二行）。
    // 原来是「时间 · 文件数」挤在一个徽章里（自然宽 163px），是整张表最宽的一列，
    // 也是横向滚动条的主要来源；文件数移到 tooltip（见上 snapTip），
    // 列宽需求 183 → 98px，行高也不再被撑到三行。
    var snapTop = '<span class="none">—</span>';
    var snapFoot = "";
    if (m.snapshot && m.snapshot.ok) {
      var sn = m.snapshot;
      var snapTime = bjTime(sn.created) || sn.created_local || "";   // 实时北京时间（UTC+8）
      var snapTip = "快照生成时间（实时北京时间 UTC+8）" + (sn.mode ? "，模式 " + sn.mode : "") +
        "。原始 UTC：" + (sn.created || "?") +
        (typeof sn.files === "number" ? "　文件数 " + sn.files : "");
      snapTop = '<span data-tip="' + esc(snapTip) + '">' +
        (sn.stale ? badge(snapTime || "快照", "warn") : badge(snapTime || "快照", "ok")) + "</span>";
    } else if (m.snapshot) {
      snapTop = '<span class="none" title="未读到 _snapshot/manifest.json">无快照</span>';
    }
    // 快照栏附「一键备份」按钮（仅在线机器 —— 需经 SMB 把请求文件写到机器上）
    // 合并版：一次点击 = ① 增量同步到 139（rclone copy --update：只传新增/有变化的文件，
    // 已存在的相同文件跳过 → 不重复上传，也不删远端）② 抓一次快速快照并推送。
    if (online) {
      var br = m.backup_request || {};
      if (br.pending) {
        snapFoot += '<div class="backup-box">' +
          '<button class="btn btn-mini btn-backup pending" disabled><i class="spin"></i> 备份中</button>' +
          '<div class="muted backup-note" data-tip="请求已于 ' + esc(br.requested_at || "刚刚") +
          ' 下发（by ' + esc(br.requested_by || "workbench") +
          '）。机器保活循环每分钟取走执行，完成后此行会恢复为可点击">已下发，等待执行</div></div>';
      } else {
        snapFoot += '<div class="backup-box">' +
          '<button class="btn btn-mini btn-backup" data-backup="' + esc(m.ip) +
          '" data-host="' + esc(m.hostname) +
          '" data-tip="立即在机器上执行：① 把数据目录（D:\\a\\cloud-rdp）下新增/有变化的文件增量上传到 139 云盘（rclone copy --update：已存在的相同文件会跳过、不重复上传，也不删远端）② 抓一次快速快照并推送。机器保活循环每分钟取走一次，通常 ≤1 分钟开始，约 1~3 分钟完成">☁ 一键备份</button>' +
          "</div>";
      }
    }
    // 文件数与按钮同一行、放不下就自动折行（flex-wrap）
    var snap = snapTop + (snapFoot ? '<div class="snap-foot">' + snapFoot + "</div>" : "");
    var lastSeen = online ? '<span class="none">—</span>'
      : '<span class="muted" title="最后在线（实时北京时间 UTC+8）；原始 UTC：' + esc(m.last_seen || "?") + '">' +
        esc(bjTime(m.last_seen) || m.last_seen_human || "未知") + "</span>";
    var ops = online
      ? rdpBtn(m.ip, nodeName, "btn-primary", "") +
        ' <button class="btn btn-mini btn-ghost" data-info="' + esc(m.ip) + '" data-host="' + esc(nodeName) + '">查看信息</button>'
      : '<span class="none">离线</span>';
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
      "<td class=\"strong\"><span data-tip=\"" + esc(hostTip) + "\">" + esc(nodeName || "-") + "</span>" + acct + "</td>" +
      '<td class="mono">' + esc(m.ip || "-") + "</td>" +
      "<td>" + st + "</td>" +
      "<td>" + roleBadge(m.role) + "</td>" +
      "<td>" + restoreBadge(m.restore) + "</td>" +
      "<td>" + snap + "</td>" +
      "<td>" + lastSeen + "</td>" +
      '<td class="right ops-cell">' + ops + "</td>" +
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
    if (a.provisioning) {
      // 刚添加、后台正在自动部署 —— 此刻 Secret 还没写完，别误报成红色「缺失」
      secret = badge("部署中…", "info");
    } else if (a.secret_present === true) {
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
    // 「在跑」必须分清「真在跑」和「排队中」——
    // 老的 alive_count 口径是「**未结束**的 run 数」，把 pending / queued 也算进去；
    // 但排队中的 run 还没分到 runner、机器根本没起来，Tailscale 上没有节点，
    // 「机器运行实况」里自然看不到 → 两个面板会「打架」（瑀子 2026-09-24 反馈）。
    // 后端现在把 in_progress（真在跑）与 queued（排队中）拆开给，这里如实分开展示。
    if (a.running_count !== null && a.running_count !== undefined) {
      var monRun = '<span class="mon-num" title="真在跑：GitHub run 状态 = in_progress（机器已起来，' +
        '「机器运行实况」里能看到对应节点）">在跑 ' + esc(a.running_count) + " 台</span>";
      if (a.queued_count) {
        monRun += ' <span class="mon-queued" title="已派发但还在排队（pending / queued / waiting / requested）：' +
          'GitHub 还没分配 runner，机器尚未启动，所以「机器运行实况」里看不到它 —— 等前一台跑完才会起。' +
          '（本仓库 windows-rdp.yml 配了 concurrency，同仓库串行，第二次派发会排队）">排队 ' +
          esc(a.queued_count) + " 台</span>";
      }
      mon.push(monRun);
    } else if (a.alive_count !== null && a.alive_count !== undefined) {
      mon.push('<span class="mon-num" title="未结束的 run 数（含排队中）—— 旧版协调器未区分「真在跑 / 排队中」">' +
        "在跑 " + esc(a.alive_count) + " 台</span>");
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

// ------------------------------------------------------------ 日志：分账号
// 每个账号 = 一个 fork，各跑各的 run。后端 get_runs(include_accounts=True) 把每个账号
// 的 run 归到 runs.accounts[] 里（hub 账号复用主仓库那份，不重复请求）。
// 旧后端没有 runs.accounts → 退回「只有主仓库一组」的老行为，页面不会空。
function accountByOwner(owner) {
  var list = (DATA.accounts || {}).accounts || [];
  for (var i = 0; i < list.length; i++) {
    if (list[i].owner === owner) return list[i];
  }
  return null;
}

// 当前该渲染哪些「账号组」（受 RUN_ACC 筛选）
function runGroups() {
  var r = DATA.runs || {};
  var list = r.accounts;
  if (!list || !list.length) {
    return [{ id: "", owner: "", repo: "", hub: true, token_source: "hub",
              ok: r.ok !== false, error: r.error || "", runs: r[RUN_TAB] || [], fallback: null }];
  }
  var groups = list.map(function (a) {
    return { id: a.id || "", owner: a.owner || "", repo: a.repo || "", hub: !!a.hub,
             token_source: a.token_source || "none", ok: a.ok !== false,
             error: a.error || "", runs: a[RUN_TAB] || [], fallback: a.fallback_run || null };
  });
  if (RUN_ACC !== "all") {
    groups = groups.filter(function (g) { return g.owner === RUN_ACC; });
  }
  return groups;
}

var TOKEN_SRC_LABEL = {
  hub: "主仓库 Token",
  local: "本机 Token",
  anon: "匿名只读",
  none: "无 Token"
};

// run 状态 → 中文（表头 tooltip 一直是中文口径，以前却渲染英文原值，对不上）
var RUN_STATE_LABEL = {
  in_progress: "进行中", queued: "排队", waiting: "排队", requested: "排队", pending: "排队",
  success: "成功", failure: "失败", timed_out: "超时", startup_failure: "启动失败",
  cancelled: "取消", skipped: "跳过", neutral: "无结论", action_required: "需处理", stale: "陈旧"
};
// 排队中的 run 机器还没起来 → 用琥珀色，和蓝色「进行中」区分开（同「在跑/排队」的口径）
var RUN_QUEUED_STATES = ["queued", "waiting", "requested", "pending"];

// 一条 run 行（8 列）
function runRow(x) {
  var status = x.status || "";
  var kind = RUN_QUEUED_STATES.indexOf(status) >= 0 ? "warn"
    : (status === "in_progress" ? "info"
      : (x.conclusion === "success" ? "ok" : (x.conclusion === "cancelled" ? "warn" : "bad")));
  var raw = status + (x.conclusion ? " / " + x.conclusion : "");
  var st = '<span title="原始状态：' + esc(raw || "-") + '">' +
    badge(RUN_STATE_LABEL[x.state] || x.state || "-", kind) + "</span>";
  var ev = x.event === "schedule" ? badge("定时", "mute") : badge(x.event || "-", "info");
  var num = (x.number === null || x.number === undefined || x.number === "") ? "—" : "#" + x.number;
  return "<tr>" +
    '<td class="mono">' + esc(num) + "</td>" +
    "<td>" + st + "</td>" +
    "<td>" + ev + "</td>" +
    '<td class="nowrap"><span title="北京时间（UTC+8）；原始 UTC：' + esc(x.created_at) + '">' +
      esc(bjTime(x.created_at) || x.created_beijing || "-") + "</span></td>" +
    '<td class="mono nowrap">' + esc(x.duration) + "</td>" +
    '<td class="mono">' + esc(x.head_sha) + "</td>" +
    '<td class="dim">' + esc(x.title || "-") + "</td>" +
    '<td class="right">' + (x.url
      ? '<a href="' + esc(x.url) + '" target="_blank" rel="noopener">日志</a>'
      : '<span class="none">—</span>') + "</td>" +
    "</tr>";
}

// 组内提示行（无记录 / 读取失败）
function runNoteRow(text) {
  return '<tr class="run-note"><td colspan="8" class="muted">' + esc(text) + "</td></tr>";
}

// 分组表头（跨 8 列）：账号 · owner/repo + 角色 + 在跑/排队 + 数据源 + 条数
function runGroupHead(g, n) {
  var acc = accountByOwner(g.owner) || {};
  var bits = ['<span class="rg-id">' + esc(g.id || "主仓库") + "</span>"];
  if (g.owner) {
    bits.push('<span class="mono dim">' + esc(g.owner + (g.repo ? "/" + g.repo : "")) + "</span>");
  }
  if (acc.role) bits.push(roleBadge(acc.role));
  if (acc.running_count !== null && acc.running_count !== undefined) {
    bits.push('<span class="mono" title="真在跑：GitHub run 状态 = in_progress">在跑 ' +
      esc(acc.running_count) + " 台</span>");
    if (acc.queued_count) {
      bits.push('<span class="mon-queued" title="已派发但还在排队（机器尚未启动）">排队 ' +
        esc(acc.queued_count) + " 台</span>");
    }
  }
  var src = TOKEN_SRC_LABEL[g.token_source];
  if (src) {
    bits.push('<span class="src-tag" title="读取该账号 fork 的 run 所用凭证：' +
      esc(g.token_source === "anon" ? "匿名（公开仓库可读，额度低）"
        : (g.token_source === "none" ? "没有可用 Token，读不到" : "PAT")) + '">' +
      esc(src) + "</span>");
  }
  bits.push('<span class="muted">' + esc(n) + " 条</span>");
  return '<tr class="run-group"><td colspan="8">' + bits.join(" ") + "</td></tr>";
}

// 账号筛选按钮（按 pool-config 的账号动态生成；只有 1 组时整行隐藏）
function renderRunAccTabs() {
  var el = $("#run-acc-tabs");
  var sub = $("#runs-sub");
  if (!el) return;
  var list = (DATA.runs || {}).accounts || [];
  if (list.length <= 1) {
    el.innerHTML = "";
    if (sub) sub.hidden = true;
    RUN_ACC = "all";
    return;
  }
  if (sub) sub.hidden = false;
  // 选中的账号被删掉/停用了 → 回到「全部账号」
  var owners = list.map(function (a) { return a.owner; });
  if (RUN_ACC !== "all" && owners.indexOf(RUN_ACC) < 0) RUN_ACC = "all";

  var html = '<button class="tab' + (RUN_ACC === "all" ? " active" : "") +
    '" data-acc="all" data-tip="所有账号的运行记录（按账号分组）">全部账号</button>';
  html += list.map(function (a) {
    var nm = a.id || a.owner;
    return '<button class="tab' + (RUN_ACC === a.owner ? " active" : "") +
      '" data-acc="' + esc(a.owner) + '" data-tip="只看 ' +
      esc(nm + " · " + a.owner + "/" + a.repo) + ' 的运行记录">' + esc(nm) + "</button>";
  }).join("");
  el.innerHTML = html;
}

function renderRuns() {
  var r = DATA.runs || {};
  var groups = runGroups();
  var tb = $("#tbl-runs tbody");
  var hasAny = groups.some(function (g) { return (g.runs || []).length > 0 || !!g.fallback; });

  if (!r.ok && !hasAny) {
    tb.innerHTML = '<tr><td colspan="8" class="empty">' + esc(r.error || "读取失败") + "</td></tr>";
    $("#runs-empty").hidden = true;
    return;
  }
  $("#runs-empty").hidden = hasAny;

  // 只有「全部账号」才画分组表头；单账号视图下省掉，表格更紧凑
  var multi = groups.length > 1;
  var html = "";
  groups.forEach(function (g) {
    var runs = g.runs || [];
    // 「缩略」时**每个账号各留最近 N 条**（不是总共 N 条）—— 否则账号一多就只剩头几个账号
    var shown = runs, hidden = 0;
    if (RUNS_LIMIT > 0 && runs.length > RUNS_LIMIT) {
      shown = runs.slice(0, RUNS_LIMIT);
      hidden = runs.length - RUNS_LIMIT;
    }
    if (multi) html += runGroupHead(g, runs.length);
    if (!g.ok && !shown.length) {
      html += runNoteRow((g.error || "读取失败") +
        (g.fallback ? "　·　下面是池状态记录的最近一次运行：" : ""));
      if (g.fallback) html += runRow(g.fallback);
    } else if (!shown.length) {
      html += runNoteRow("暂无运行记录");
    } else {
      html += shown.map(runRow).join("");
    }
    if (hidden > 0) {
      html += '<tr class="more-row"><td colspan="8" class="muted">本账号已缩略：另有 ' +
        esc(hidden) + " 条未显示 —— 点右上角「展开全部」查看</td></tr>";
    }
  });
  tb.innerHTML = html;

  var meta = $("#runs-meta");
  if (meta) {
    var cnt = 0;
    groups.forEach(function (g) { cnt += (g.runs || []).length; });
    if (RUN_ACC === "all") {
      meta.textContent = groups.length + " 个账号 · 共 " + cnt + " 条记录";
    } else {
      var g0 = groups[0];
      meta.textContent = g0 ? ((g0.id || g0.owner) + " · 共 " + cnt + " 条记录") : "";
    }
  }
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

function localPlatform() {
  return String((navigator.userAgentData && navigator.userAgentData.platform) ||
                navigator.platform || navigator.userAgent || "").toLowerCase();
}
function localOsName() {
  var p = localPlatform();
  if (p.indexOf("win") >= 0) return "Windows";
  if (p.indexOf("mac") >= 0) return "macOS";
  return "Linux";
}

function showConnInfo(ip, host) {
  var title = "连接信息" + (host ? " · " + host : "");
  openModal(title, '<div class="muted">读取中…</div>');
  api("/api/conn-info?ip=" + encodeURIComponent(ip)).then(function (c) {
    var rows =
      connRow("Tailscale IP :", c.ip || ip) +
      connRow("Username     :", c.username || "") +
      connRow("Password     :", c.password || "");

    // ---- 远端部署：服务端是无头机，弹不出你能看到的窗口 → 把连接交给本机 ----
    // 两条路：① 下载 .rdp（双击即连，最省事）② 复制一条本机命令（Linux/macOS 常用）。
    if (c.local_target) {
      var cmd = localRdpCmd(c);
      var html =
        '<div class="conn-list">' + rows + "</div>" +
        '<div class="conn-note">' +
          '<div class="muted">工作台部署在<b>远端服务器</b>（' + esc(c.is_windows ? "Windows" : "Linux") +
            "），<b>无法在你本机弹窗</b>。点「下载 .rdp」把文件存到你的电脑，<b>双击</b>即可连接" +
            "（证书警告已在文件里关掉）。</div>" +
          '<div class="muted">或在你本机（' + esc(localOsName()) + '）执行这条命令：</div>' +
          '<div class="conn-cmd"><span class="mono" data-copy="' + esc(cmd) +
            '" title="点击复制">' + esc(cmd) + "</span></div>" +
        "</div>" +
        '<div class="conn-foot">' +
          '<button class="btn btn-primary btn-mini" data-rdp-download="' + esc(ip) +
            '" data-host="' + esc(host || "") + '">下载 .rdp</button>' +
          '<button class="btn btn-mini" data-copy-all="1">复制全部</button>' +
          '<span class="muted">点任意一行可复制该值</span>' +
        "</div>";
      openModal(title, html);
      return;
    }

    // ---- 本机部署（Windows）：服务端就在你机器上，直接弹 mstsc ----
    var mode = c.launch_mode || "mstsc";
    var modeLabel = mode === "file"
      ? "打开 .rdp 文件（2026-04 更新后会弹「安全警告」）"
      : "mstsc /v: 命令行（不触发 .rdp 安全警告）";
    var d = c.default_rdp || {};
    // Default.rdp 是 mstsc 写的 UTF-16LE+BOM 隐藏文件 —— 后端现在按真实编码读，
    // 这里把编码 / 路径如实透出来，免得再出现「明明已是 0 却报未设置」那种对不上。
    var rdpMeta = [];
    if (d.encoding) rdpMeta.push("编码 " + d.encoding);
    if (d.path) rdpMeta.push(d.path);
    var rdpMetaTip = rdpMeta.length
      ? '<div class="muted" title="' + esc(rdpMeta.join(" · ")) + '">Default.rdp：' +
        esc(rdpMeta.join(" · ")) + "</div>"
      : "";
    var authLine = "";
    var fixBtn = "";
    // 证书警告（Default.rdp authentication level）只对 Windows 本机 mstsc 有意义 ——
    // 远端/Linux 部署下不显示，免得给一个「修了也没用」的按钮。
    if (c.auth_check !== false && mode !== "file") {
      if (d.auth_zero) {
        authLine = '<div class="muted">证书警告：已关闭（Default.rdp authentication level=0）</div>';
      } else {
        var lv = (d.auth_level === null || d.auth_level === undefined) ? "未设置" : String(d.auth_level);
        authLine = '<div class="warn-line">证书警告未关闭（Default.rdp authentication level=' +
          esc(lv) + '）—— 连接自签证书机器时会弹「无法验证身份」</div>';
        fixBtn = '<button class="btn btn-mini" data-fix-default="1" data-ip="' + esc(ip) +
          '" data-host="' + esc(host || "") + '">修复证书警告</button>';
      }
    }
    var html =
      '<div class="conn-list">' + rows + "</div>" +
      '<div class="conn-note">' +
        '<div class="muted">唤起方式：' + esc(modeLabel) + "</div>" +
        authLine +
        rdpMetaTip +
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

  // 数据导出下拉菜单
  var expMenu = $("#export-menu"), expList = $("#export-list"), expBtn = $("#btn-export");
  if (expBtn) {
    expBtn.addEventListener("click", function (e) {
      e.stopPropagation();
      expList.hidden = !expList.hidden;
    });
    expList.addEventListener("click", function (e) {
      var b = e.target.closest("button[data-export]");
      if (!b) return;
      expList.hidden = true;
      exportData(b.dataset.export, b.dataset.format || "json");
    });
    document.addEventListener("click", function (e) {
      if (!expMenu.contains(e.target)) expList.hidden = true;
    });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") expList.hidden = true; });
  }
  // 一键折叠 / 展开所有行的状态详情（机器多时不用一行行点）
  var foldAllBtn = $("#btn-fold-all");
  if (foldAllBtn) {
    foldAllBtn.addEventListener("click", function () {
      var keys = collectMachineKeys();
      var allFolded = keys.length > 0 && FOLD_DETAILS.count(keys) === keys.length;
      FOLD_DETAILS.setAll(keys, !allFolded);
      renderMachines();
      updateFoldAllLabel();
    });
  }

  $("#run-tabs").addEventListener("click", function (e) {
    var b = e.target.closest(".tab");
    if (!b) return;
    RUN_TAB = b.dataset.tab;
    Array.prototype.forEach.call(this.querySelectorAll(".tab"), function (t) {
      t.classList.toggle("active", t === b);
    });
    renderRuns();
  });

  // 账号筛选（全部账号 / 单个账号）
  var accTabs = $("#run-acc-tabs");
  if (accTabs) {
    accTabs.addEventListener("click", function (e) {
      var b = e.target.closest(".tab");
      if (!b) return;
      RUN_ACC = b.dataset.acc || "all";
      renderRunAccTabs();
      renderRuns();
    });
  }

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
    var pat = ($("#acc-pat").value || "").trim();
    var enabled = $("#acc-enabled").checked;
    var autoDeploy = $("#acc-autodeploy").checked;
    var msg = $("#acc-add-msg");
    if (!owner || !repo) {
      msg.textContent = "owner / repo 要填";
      return;
    }
    if (!pat) {
      msg.textContent = "PAT 必填（该账号自己的 Personal Access Token，需 repo + workflow 权限）";
      return;
    }
    var btn = $("#btn-add-submit");
    btn.disabled = true;
    msg.textContent = autoDeploy ? "添加并开始自动部署…" : "添加中…";
    api("/api/accounts/add", {
      method: "POST",
      body: JSON.stringify({ owner: owner, repo: repo, token_secret: secret, id: id,
                             enabled: enabled, pat: pat, auto_deploy: autoDeploy })
    }).then(function (res) {
      toast("已添加账号 " + esc(owner) + "（" + esc(res.id) + "）", "ok");
      if (res.secret_auto) toast("Secret 名已自动分配：" + esc(res.token_secret), "info", 8000);
      if (res.verify_note) toast(esc(res.verify_note), "warn", 8000);
      $("#form-add-account").reset();
      $("#acc-repo").value = "cloud-rdp";
      $("#acc-enabled").checked = true;
      $("#acc-autodeploy").checked = true;
      msg.textContent = "";
      $("#form-add-account").hidden = true;
      load(true);
      if (res.auto_deploy && res.job_id) {
        startProvisionView(res.job_id, owner);
      } else if (res.hint) {
        toast(esc(res.hint), "info", 12000);
      }
    }).catch(function (err) {
      msg.textContent = "失败：" + err.message;
    }).then(function () { btn.disabled = false; });
  });

  // ---------------- 自动部署进度（轮询后台任务） ----------------
  var PROV_TIMER = null, PROV_JOB = "";
  var PROV_STEP_NAMES = {
    config: "写入配置", verify_pat: "校验 PAT", save_pat: "留存 PAT",
    hub_secret: "写 hub Secret", fork: "建 fork", actions: "开 Actions",
    secrets_sync: "复制机器密钥", push_config: "推送配置", dispatch: "触发协调器",
    error: "异常"
  };
  function provStepName(k) { return PROV_STEP_NAMES[k] || k; }

  function renderProvision(job) {
    $("#prov-panel").hidden = false;
    var running = job.status === "running";
    $("#prov-title").textContent = "部署进度 · " + job.owner;
    $("#prov-status").textContent = running ? "进行中…"
      : (job.status === "done" ? (job.summary || "完成") : ("失败 —— " + (job.summary || "")));
    $("#prov-status").className = "muted";
    var steps = job.steps || [];
    var html = steps.map(function (s) {
      var cls = s.ok ? "ok" : "bad";
      var ico = s.ok ? "✓" : "✕";
      var extra = s.note ? ' <span class="ps-note">（' + esc(s.note) + "）</span>" : "";
      var ts = s.ts ? bjTime(s.ts) : "";
      return '<li class="' + cls + '"><span class="ps-ico">' + ico + "</span>" +
        '<span class="ps-name">' + esc(provStepName(s.step)) + "</span>" +
        '<span class="ps-detail">' + esc(s.detail || "") + extra + "</span>" +
        (ts ? '<span class="ps-ts">' + esc(ts) + "</span>" : "") + "</li>";
    }).join("");
    if (running) {
      html += '<li class="run"><span class="ps-ico">⋯</span><span class="ps-name">处理中</span>' +
        '<span class="ps-detail">正在执行下一步（复制密钥那步要等几分钟）…</span></li>';
    }
    $("#prov-steps").innerHTML = html;
  }

  function pollProvision(jobId) {
    api("/api/accounts/provision?id=" + encodeURIComponent(jobId)).then(function (res) {
      var job = res.job || {};
      renderProvision(job);
      if (job.status === "running") {
        PROV_TIMER = setTimeout(function () { pollProvision(jobId); }, 2500);
      } else {
        PROV_TIMER = null;
        if (job.status === "done") {
          toast("自动部署完成：" + esc(job.summary || ""), "ok", 9000);
        } else {
          toast("自动部署有步骤失败：" + esc(job.summary || ""), "bad", 12000);
        }
        load(true);
      }
    }).catch(function (err) {
      $("#prov-status").textContent = "读取进度失败：" + err.message;
      PROV_TIMER = null;
    });
  }

  function startProvisionView(jobId, owner) {
    if (PROV_TIMER) { clearTimeout(PROV_TIMER); PROV_TIMER = null; }
    PROV_JOB = jobId;
    renderProvision({ owner: owner, status: "running", steps: [] });
    pollProvision(jobId);
  }

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
    if (b.classList.contains("fold-caret")) { toggleFoldDetail(b); return; }
    if (b.dataset.backup) { doBackup(b); return; }
    if (b.dataset.info) { showConnInfo(b.dataset.info, b.dataset.host || ""); return; }
    var ip = b.dataset.rdp || b.dataset.rdpfile;
    var host = b.dataset.host || "";
    var launch = !!b.dataset.rdp;
    if (!ip) return;
    // 远端部署：服务端是无头机，弹不出你能看到的窗口 —— 「一键登录」改成把 .rdp
    // 直接下到**你本机**（一次点击 = 浏览器保存文件，双击即连）。
    if (launch && DATA && DATA.config && DATA.config.rdp_local) { downloadRdp(ip, host); return; }
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

  // 连接信息弹窗：关闭 / 复制 / 下载 .rdp（远端）/ 弹窗内一键登录（本机）
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
      fx.innerHTML = '<i class="spin"></i> 修复中';
      api("/api/rdp/default", { method: "POST" }).then(function (r) {
        if (r.ok) {
          toast("已修复：" + esc(r.note || "Default.rdp authentication level=0"), "ok");
          // 重开弹窗 —— 不然「证书警告未关闭」那行还挂在那儿，看着像没修好
          showConnInfo(fx.dataset.ip || "", fx.dataset.host || "");
        } else {
          toast("修复失败：" + esc(r.note || "未知错误"), "bad", 12000);
          fx.disabled = false;
          fx.textContent = "修复证书警告";
        }
      }).catch(function (err) {
        toast("修复失败：" + esc(err.message), "bad", 12000);
        fx.disabled = false;
        fx.textContent = "修复证书警告";
      });
      return;
    }
    var dl = e.target.closest("[data-rdp-download]");
    if (dl) { downloadRdp(dl.dataset.rdpDownload, dl.dataset.host || ""); return; }
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
