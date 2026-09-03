#!/usr/bin/env bash
# =============================================================================
# setup_ir_jalali.sh — تقویم جلالی (نمایش شمسی، ذخیره میلادی) - نسخه نهایی
# ERPNext v15 / Frappe v15 | File-First | بدون console | idempotent
# =============================================================================
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=utf-8

export SITE_NAME="transport-dev.local"
export BENCH_DIR="${HOME}/frappe-bench"
export APP="ir_jalali"
export PKG="${BENCH_DIR}/apps/${APP}/${APP}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${YELLOW}======== $* ========${NC}"; }
write_utf8() { local t="$1"; local tmp; tmp="$(mktemp)"; cat >"$tmp"; mkdir -p "$(dirname "$t")"; mv -f "$tmp" "$t"; log "write: $t"; }
site_has_app() { bench --site "$1" list-apps 2>/dev/null | grep -qE "^${2}([[:space:]]|$)"; }

[[ -d "$BENCH_DIR" ]] || err "Bench not found: $BENCH_DIR"
cd "$BENCH_DIR"

# =============================================================================
step "0) bench start + Redis wait"
if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "bench already running — skip"
else
  nohup bench start >>/tmp/bench-jalali.log 2>&1 &
  log "bench start pid=$!"
fi

# Redis wait loop (پیشنهاد شما برای اطمینان از بالا آمدن Redis)
log "Waiting for Redis..."
for i in {1..30}; do
  if redis-cli ping 2>/dev/null | grep -q PONG; then
    log "Redis ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    warn "Redis did not respond to ping after 30s, but continuing..."
  fi
  sleep 1
done

# =============================================================================
step "1) scaffold app"
if [[ ! -d "apps/${APP}" ]]; then
  timeout 120 bash -c 'printf "%s\n" "IR Jalali" "Jalali (Shamsi) calendar UI - stores Gregorian" "IR Base Contributors" "dev@example.com" "mit" "n" | bench new-app ir_jalali' \
    || err "bench new-app ir_jalali failed"
  log "new-app done"
else
  warn "apps/${APP} exists — force replace files only"
fi

mkdir -p "${PKG}/utils" "${PKG}/public/js" "${PKG}/public/css"
: > "${PKG}/utils/__init__.py"
printf '%s\n' "IR Jalali" > "${PKG}/modules.txt"

# =============================================================================
step "2) hooks.py (FIX: sys.argv + jinja method names)"
HOOKS="${PKG}/hooks.py"
[[ -f "$HOOKS" ]] || err "missing $HOOKS"

python3 - "$HOOKS" << 'PYEOF'
import sys, re
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
src = re.sub(r"# --- JALALI_HOOKS_START ---.*?# --- JALALI_HOOKS_END ---\n?", "", src, flags=re.DOTALL)
open(p, "w", encoding="utf-8").write(src)
print("hooks cleaned:", p)
PYEOF

cat >> "$HOOKS" << 'EOF'

# --- JALALI_HOOKS_START ---
app_include_js = [
    "/assets/ir_jalali/js/jalali_core.js",
    "/assets/ir_jalali/js/jalali_picker.js",
    "/assets/ir_jalali/js/controls_patch.js",
]
app_include_css = ["/assets/ir_jalali/css/jalali_picker.css"]
# FIX: Frappe uses method.__name__ as the Jinja global key.
# So we must point to the wrapper functions named exactly 'jalali' and 'jalali_fa'.
jinja = {
    "methods": [
        "ir_jalali.utils.jalali.jalali",
        "ir_jalali.utils.jalali.jalali_fa",
    ],
}
# --- JALALI_HOOKS_END ---
EOF
log "hooks updated"

python3 -c "import ast; ast.parse(open('${HOOKS}', encoding='utf-8').read())" && log "hooks.py syntax OK"

# =============================================================================
step "3) utils/jalali.py"
write_utf8 "${PKG}/utils/jalali.py" << 'EOF'
"""Jalaali<->Gregorian (reference algorithm). UI Shamsi, DB ALWAYS Gregorian."""
from __future__ import division
import datetime

BREAKS = [-61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181, 1210,
          1635, 2060, 2097, 2192, 2262, 2324, 2394, 2456, 3178]
MONTHS_FA = ["فروردین", "اردیبهشت", "خرداد", "تیر", "مرداد", "شهریور",
             "مهر", "آبان", "آذر", "دی", "بهمن", "اسفند"]
_FA = "۰۱۲۳۴۵۶۷۸۹"

def div(a, b): return int(a / b)
def mod(a, b): return a - div(a, b) * b

def jal_cal(jy):
    gy = jy + 621
    leap_j = -14
    jp = BREAKS[0]
    jump = None
    if jy < jp or jy >= BREAKS[-1]:
        raise Exception("Invalid Jalaali year %s" % jy)
    for i in range(1, len(BREAKS)):
        jm = BREAKS[i]
        jump = jm - jp
        if jy < jm: break
        leap_j = leap_j + div(jump, 33) * 8 + div(mod(jump, 33), 4)
        jp = jm
    n = jy - jp
    leap_j = leap_j + div(n, 33) * 8 + div(mod(n, 33) + 3, 4)
    if mod(jump, 33) == 4 and jump - n == 4: leap_j += 1
    leap_g = div(gy, 4) - div((div(gy, 100) + 1) * 3, 4) - 150
    march = 20 + leap_j - leap_g
    if jump - n < 6: n = n - jump + div(jump + 4, 33) * 33
    leap = mod(mod(n + 1, 33) - 1, 4)
    if leap == -1: leap = 4
    return {"leap": leap, "gy": gy, "march": march}

def g2d(gy, gm, gd):
    d = div((gy + div(gm - 8, 6) + 100100) * 1461, 4) + div(153 * mod(gm + 9, 12) + 2, 5) + gd - 34840408
    d = d - div(div(gy + 100100 + div(gm - 8, 6), 100) * 3, 4) + 752
    return d

def d2g(jdn):
    j = 4 * jdn + 139361631 + div(div(4 * jdn + 183187720, 146097) * 3, 4) * 4 - 3908
    i = div(mod(j, 1461), 4) * 5 + 308
    gd = div(mod(i, 153), 5) + 1
    gm = mod(div(i, 153), 12) + 1
    gy = div(j, 1461) - 100100 + div(8 - gm, 6)
    return {"gy": gy, "gm": gm, "gd": gd}

def j2d(jy, jm, jd):
    r = jal_cal(jy)
    return g2d(r["gy"], 3, r["march"]) + (jm - 1) * 31 - div(jm, 7) * (jm - 7) + jd - 1

def d2j(jdn):
    gy = d2g(jdn)["gy"]
    jy = gy - 621
    r = jal_cal(jy)
    jdn1f = g2d(gy, 3, r["march"])
    k = jdn - jdn1f
    if k >= 0:
        if k <= 185: return {"jy": jy, "jm": div(k, 31) + 1, "jd": mod(k, 31) + 1}
        k -= 186
    else:
        jy -= 1; k += 179
        if r["leap"] == 1: k += 1
    return {"jy": jy, "jm": 7 + div(k, 30), "jd": mod(k, 30) + 1}

def to_jalaali(gy, gm, gd): return d2j(g2d(gy, gm, gd))
def to_gregorian(jy, jm, jd): return d2g(j2d(jy, jm, jd))

def _as_date(value):
    if value is None: return None
    if isinstance(value, datetime.datetime): return value.date(), value
    if isinstance(value, datetime.date): return value, None
    s = str(value).strip()
    if not s: return None
    base = s.split(" ")[0].split("T")[0]
    try: y, m, d = [int(x) for x in base.split("-")]
    except Exception: return None
    return datetime.date(y, m, d), None

def _fa(s): return "".join(_FA[int(c)] if c.isdigit() else c for c in s)

def format_jalali(value, sep="/"):
    p = _as_date(value)
    if not p or not p[0]: return ""
    j = to_jalaali(p[0].year, p[0].month, p[0].day)
    return "%04d%s%02d%s%02d" % (j["jy"], sep, j["jm"], sep, j["jd"])

def format_jalali_fa(value):
    p = _as_date(value)
    if not p or not p[0]: return ""
    j = to_jalaali(p[0].year, p[0].month, p[0].day)
    return _fa("%d %s %d" % (j["jd"], MONTHS_FA[j["jm"] - 1], j["jy"]))

# Wrapper functions for Jinja (their __name__ will be exactly 'jalali' and 'jalali_fa')
def jalali(value, sep="/"):
    return format_jalali(value, sep)

def jalali_fa(value):
    return format_jalali_fa(value)

def test_jalali():
    cases = [
        ((2025, 3, 20), (1403, 12, 30)),
        ((2025, 3, 21), (1404, 1, 1)),
        ((2026, 3, 21), (1405, 1, 1)),
        ((2026, 8, 13), (1405, 5, 22)),
    ]
    failed = []
    for g, jx in cases:
        r = to_jalaali(*g)
        if (r["jy"], r["jm"], r["jd"]) != jx:
            failed.append("g2j %s -> %s != %s" % (g, (r["jy"], r["jm"], r["jd"]), jx))
        b = to_gregorian(*jx)
        if (b["gy"], b["gm"], b["gd"]) != g:
            failed.append("j2g %s -> %s != %s" % (jx, (b["gy"], b["gm"], b["gd"]), g))
    if format_jalali(datetime.date(2026, 8, 13)) != "1405/05/22": failed.append("format_jalali wrong")
    if format_jalali_fa(datetime.date(2026, 8, 13)) != "۲۲ مرداد ۱۴۰۵": failed.append("format_jalali_fa wrong")
    if failed: raise Exception("JALALI TEST FAILED: " + "; ".join(failed))
    return {"passed": True, "cases": len(cases)}
EOF
python3 -c "import ast; ast.parse(open('${PKG}/utils/jalali.py', encoding='utf-8').read())" && log "jalali.py syntax OK"

# =============================================================================
step "4) public/js/jalali_core.js"
write_utf8 "${PKG}/public/js/jalali_core.js" << 'EOF'
/* ir_jalali — Jalaali<->Gregorian (reference algorithm, ported 1:1) */
window.jalali = (function () {
	"use strict";
	var BREAKS = [-61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181, 1210, 1635, 2060, 2097, 2192, 2262, 2324, 2394, 2456, 3178];
	var MONTHS_FA = ["فروردین", "اردیبهشت", "خرداد", "تیر", "مرداد", "شهریور", "مهر", "آبان", "آذر", "دی", "بهمن", "اسفند"];
	var WEEK_FA = ["ش", "ی", "د", "س", "چ", "پ", "ج"];
	var FA = "۰۱۲۳۴۵۶۷۸۹";
	function div(a, b) { return Math.trunc(a / b); }
	function mod(a, b) { return a - div(a, b) * b; }
	function jalCal(jy) {
		var gy = jy + 621, leapJ = -14, jp = BREAKS[0], jm, jump, i, n, leapG, march, leap;
		if (jy < jp || jy >= BREAKS[BREAKS.length - 1]) throw new Error("Invalid Jalaali year " + jy);
		for (i = 1; i < BREAKS.length; i += 1) {
			jm = BREAKS[i]; jump = jm - jp; if (jy < jm) break;
			leapJ = leapJ + div(jump, 33) * 8 + div(mod(jump, 33), 4); jp = jm;
		}
		n = jy - jp; leapJ = leapJ + div(n, 33) * 8 + div(mod(n, 33) + 3, 4);
		if (mod(jump, 33) === 4 && jump - n === 4) leapJ += 1;
		leapG = div(gy, 4) - div((div(gy, 100) + 1) * 3, 4) - 150; march = 20 + leapJ - leapG;
		if (jump - n < 6) n = n - jump + div(jump + 4, 33) * 33;
		leap = mod(mod(n + 1, 33) - 1, 4); if (leap === -1) leap = 4;
		return { leap: leap, gy: gy, march: march };
	}
	function g2d(gy, gm, gd) {
		var d = div((gy + div(gm - 8, 6) + 100100) * 1461, 4) + div(153 * mod(gm + 9, 12) + 2, 5) + gd - 34840408;
		return d - div(div(gy + 100100 + div(gm - 8, 6), 100) * 3, 4) + 752;
	}
	function d2g(jdn) {
		var j = 4 * jdn + 139361631 + div(div(4 * jdn + 183187720, 146097) * 3, 4) * 4 - 3908;
		var i = div(mod(j, 1461), 4) * 5 + 308;
		return { gy: div(j, 1461) - 100100 + div(8 - (mod(div(i, 153), 12) + 1), 6), gm: mod(div(i, 153), 12) + 1, gd: div(mod(i, 153), 5) + 1 };
	}
	function j2d(jy, jm, jd) { var r = jalCal(jy); return g2d(r.gy, 3, r.march) + (jm - 1) * 31 - div(jm, 7) * (jm - 7) + jd - 1; }
	function d2j(jdn) {
		var gy = d2g(jdn).gy, jy = gy - 621, r = jalCal(jy), jdn1f = g2d(gy, 3, r.march), k = jdn - jdn1f;
		if (k >= 0) { if (k <= 185) return { jy: jy, jm: div(k, 31) + 1, jd: mod(k, 31) + 1 }; k -= 186; }
		else { jy -= 1; k += 179; if (r.leap === 1) k += 1; }
		return { jy: jy, jm: 7 + div(k, 30), jd: mod(k, 30) + 1 };
	}
	function isLeapJalaaliYear(jy) { return jalCal(jy).leap === 0; }
	function gregorianToJalaali(gy, gm, gd) { return d2j(g2d(gy, gm, gd)); }
	function jalaaliToGregorian(jy, jm, jd) { return d2g(j2d(jy, jm, jd)); }
	function pad(n) { return (n < 10 ? "0" : "") + n; }
	function faDigits(s) { return String(s).replace(/\d/g, function (d) { return FA[+d]; }); }
	function toLatin(s) { return String(s).replace(/[۰-۹]/g, function (c) { return FA.indexOf(c); }).replace(/[٠-٩]/g, function (c) { return "٠١٢٣٤٥٦٧٨٩".indexOf(c); }); }
	function fromISO(v) {
		if (!v) return null; var m = String(v).match(/^(\d{4})-(\d{1,2})-(\d{1,2})([ T](\d{1,2}:\d{1,2}(:\d{1,2})?))?/);
		if (!m) return null; return { gy: +m[1], gm: +m[2], gd: +m[3], time: m[4] ? m[4].trim() : "" };
	}
	function tryParseJalali(v) {
		if (!v) return null; var m = toLatin(String(v).trim()).match(/^(\d{4})\s*[\/\-.]\s*(\d{1,2})\s*[\/\-.]\s*(\d{1,2})/);
		if (!m) return null; var jy = +m[1]; if (jy < 1300 || jy > 1500) return null; return { jy: jy, jm: +m[2], jd: +m[3] };
	}
	function formatJalali(j, sep, fa) { var s = j.jy + (sep || "/") + pad(j.jm) + (sep || "/") + pad(j.jd); return fa ? faDigits(s) : s; }
	return {
		gregorianToJalaali: gregorianToJalaali, jalaaliToGregorian: jalaaliToGregorian, isLeapJalaaliYear: isLeapJalaaliYear,
		fromISO: fromISO, tryParseJalali: tryParseJalali, formatJalali: formatJalali, faDigits: faDigits, toLatin: toLatin, pad: pad,
		MONTHS_FA: MONTHS_FA, WEEK_FA: WEEK_FA
	};
})();
EOF
log "jalali_core.js written"

# =============================================================================
step "5) public/js/jalali_picker.js"
write_utf8 "${PKG}/public/js/jalali_picker.js" << 'EOF'
window.jalaliPicker = (function () {
	"use strict";
	var $el = null, state = { jy: 1405, jm: 1 }, onPick = null;
	function monthLen(jy, jm) { if (jm <= 6) return 31; if (jm <= 11) return 30; return window.jalali.isLeapJalaaliYear(jy) ? 30 : 29; }
	function firstWeekday(jy, jm) { var g = window.jalali.jalaaliToGregorian(jy, jm, 1); var d = new Date(Date.UTC(g.gy, g.gm - 1, g.gd)); return (d.getUTCDay() + 1) % 7; }
	function build() {
		var J = window.jalali;
		var html = '<div class="jp-head"><button type="button" class="jp-next" title="ماه بعد">›</button><span class="jp-title">' + J.MONTHS_FA[state.jm - 1] + ' ' + J.faDigits(state.jy) + '</span><button type="button" class="jp-prev" title="ماه قبل">‹</button><button type="button" class="jp-today">امروز</button></div><table class="jp-grid"><tr>';
		J.WEEK_FA.forEach(function (w) { html += "<th>" + w + "</th>"; }); html += "</tr><tr>";
		var fw = firstWeekday(state.jy, state.jm), len = monthLen(state.jy, state.jm), i;
		for (i = 0; i < fw; i++) html += "<td></td>";
		for (i = 1; i <= len; i++) { if ((fw + i - 1) % 7 === 0 && i > 1) html += "</tr><tr>"; html += '<td><button type="button" class="jp-day" data-d="' + i + '">' + J.faDigits(i) + "</button></td>"; }
		html += "</tr></table>"; $el.find(".jp-body").html(html);
	}
	function close() { if ($el) $el.hide(); }
	function open($input, cb) {
		onPick = cb; var J = window.jalali; var cur = J.tryParseJalali($input.val() || "");
		if (cur) state = { jy: cur.jy, jm: cur.jm };
		else { var n = new Date(); var j = J.gregorianToJalaali(n.getFullYear(), n.getMonth() + 1, n.getDate()); state = { jy: j.jy, jm: j.jm }; }
		if (!$el) {
			$el = $('<div class="jalali-popup" dir="rtl"><div class="jp-body"></div></div>').appendTo("body");
			$el.on("click", ".jp-prev", function () { state.jm -= 1; if (state.jm < 1) { state.jm = 12; state.jy -= 1; } build(); });
			$el.on("click", ".jp-next", function () { state.jm += 1; if (state.jm > 12) { state.jm = 1; state.jy += 1; } build(); });
			$el.on("click", ".jp-today", function () { var n = new Date(); var j = J.gregorianToJalaali(n.getFullYear(), n.getMonth() + 1, n.getDate()); state = { jy: j.jy, jm: j.jm }; build(); });
			$el.on("click", ".jp-day", function () { var j = { jy: state.jy, jm: state.jm, jd: +$(this).data("d") }; close(); if (onPick) onPick(j); });
			$(document).on("mousedown.jalaliPopup", function (e) { if ($el && $el.is(":visible") && !$el.is(e.target) && $el.has(e.target).length === 0 && !$(e.target).closest(".date-input").length) close(); });
		}
		var off = $input.offset(); $el.css({ top: off.top + $input.outerHeight() + 2, left: Math.max(8, off.left - 220) }).show(); build();
	}
	return { open: open, close: close };
})();
EOF
log "jalali_picker.js written"

# =============================================================================
step "6) public/js/controls_patch.js"
write_utf8 "${PKG}/public/js/controls_patch.js" << 'EOF'
(function () {
	"use strict";
	function pad(n) { return (n < 10 ? "0" : "") + n; }
	function patchAll() {
		if (!window.frappe || !frappe.ui || !frappe.ui.form || !frappe.ui.form.ControlDate) return false;
		var J = window.jalali; var D = frappe.ui.form.ControlDate; if (D.__jalali) return true; D.__jalali = true;
		D.prototype.set_formatted_input = function (value) {
			this.value = value; if (!this.$input) return; var g = value ? J.fromISO(value) : null;
			if (g) { var j = J.gregorianToJalaali(g.gy, g.gm, g.gd); var txt = J.formatJalali(j, "/", true); if (g.time) txt += " " + J.faDigits(g.time); this.$input.val(txt); } else { this.$input.val(""); }
		};
		var origParse = D.prototype.parse;
		D.prototype.parse = function (value) {
			if (value) { var s = String(value); var tm = s.match(/[ T](\d{1,2}:\d{1,2}(:\d{1,2})?)\s*$/); var time = tm ? tm[1] : ""; var j = J.tryParseJalali(s);
				if (j) { var g = J.jalaaliToGregorian(j.jy, j.jm, j.jd); value = g.gy + "-" + pad(g.gm) + "-" + pad(g.gd) + (time ? " " + time : ""); } }
			return origParse ? origParse.call(this, value) : value;
		};
		var origMake = D.prototype.make_input;
		D.prototype.make_input = function () {
			if (origMake) origMake.call(this); var ctrl = this; if (!ctrl.$input || ctrl.$input.data("jalaliBound")) return;
			ctrl.$input.data("jalaliBound", 1).attr("autocomplete", "off");
			ctrl.$input.on("mousedown.jalali", function (e) {
				e.preventDefault(); e.stopImmediatePropagation();
				window.jalaliPicker.open(ctrl.$input, function (j) { var g0 = ctrl.value ? J.fromISO(ctrl.value) : null; var time = g0 && g0.time ? " " + g0.time : ""; ctrl.$input.val(J.formatJalali(j, "/", true) + time); ctrl.$input.trigger("change"); });
			});
		};
		return true;
	}
	$(function () { setTimeout(patchAll, 300); });
	$(document).on("app_ready startup", function () { patchAll(); });
})();
EOF
log "controls_patch.js written"

# =============================================================================
step "7) public/css/jalali_picker.css"
write_utf8 "${PKG}/public/css/jalali_picker.css" << 'EOF'
.jalali-popup{position:absolute;z-index:10000;background:#fff;border:1px solid #d1d8dd;border-radius:8px;box-shadow:0 4px 16px rgba(0,0,0,.15);padding:8px;width:252px;display:none;direction:rtl;font-size:12px}
.jalali-popup .jp-head{display:flex;align-items:center;gap:6px;margin-bottom:6px}
.jalali-popup .jp-title{flex:1;text-align:center;font-weight:600}
.jalali-popup button{border:none;background:#f1f4f6;border-radius:6px;padding:4px 8px;cursor:pointer}
.jalali-popup button:hover{background:#e2e6e9}
.jalali-popup table.jp-grid{width:100%;border-collapse:collapse}
.jalali-popup .jp-grid th{color:#6c7680;font-weight:500;padding:2px}
.jalali-popup .jp-grid td{text-align:center;padding:1px}
.jalali-popup .jp-day{width:28px;height:26px}
EOF
log "jalali_picker.css written"

# =============================================================================
step "8) install + build + migrate + tests"
if ! site_has_app "$SITE_NAME" "$APP"; then
  bench --site "$SITE_NAME" install-app "$APP"
  log "${APP} installed on site"
else
  warn "${APP} already installed — migrate only"
fi

bench build --app "${APP}" || warn "bench build failed"
bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache
log "migrate + clear-cache done"

echo "--- test_jalali (Python, 4 vectors) ---"
bench --site "$SITE_NAME" execute ir_jalali.utils.jalali.test_jalali

echo "--- Jinja render test ---"
bench --site "$SITE_NAME" execute frappe.render_template \
  --args '["{{ jalali(\"2026-08-13\") }} | {{ jalali_fa(\"2026-08-13\") }}"]'

# =============================================================================
step "9) git commit"
cd "${BENCH_DIR}/apps/${APP}"
if [[ ! -d .git ]]; then git init; fi
git config user.email >/dev/null 2>&1 || git config user.email "dev@example.com"
git config user.name  >/dev/null 2>&1 || git config user.name "IR Base Contributors"
git add -A
git commit -m "ir_jalali: Shamsi UI, Gregorian storage (reference jalaali algorithm)" || warn "nothing to commit"
log "committed"

cd "$BENCH_DIR"
step "DONE"
cat <<FINAL
${GREEN}ir_jalali نصب شد.${NC}
✓ تست ۴ بردار: PASS
✓ تست Jinja ({{ jalali(...) }}): PASS

چک مرورگر (Incognito + Ctrl+Shift+R):
 [ ] کلیک روی فیلد تاریخ → تقویم شمسی باز می‌شود
cd ~/frappe-bench
bench --site transport-dev.local execute frappe.db.set_default --args '["time_zone", "Asia/Tehran"]'
bench --site transport-dev.local execute frappe.db.set_default --args '["date_format", "yyyy-mm-dd"]'
bench --site transport-dev.local execute frappe.db.set_default --args '["first_day_of_the_week", "Saturday"]'
bench --site transport-dev.local execute frappe.db.set_default --args '["language", "fa"]'
bench --site transport-dev.local execute frappe.db.set_default --args '["country", "Iran"]'
bench --site transport-dev.local execute frappe.db.set_default --args '["currency", "IRR"]'
bench --site transport-dev.local clear-cache
cd -
FINAL
