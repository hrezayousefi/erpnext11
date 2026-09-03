#!/usr/bin/env bash
# =============================================================================
# setup_phase7.sh — UI/UX + Role Workspaces + CEO Dashboard (FULL REWRITE v4)
# ERPNext v15 / Frappe v15 | File-First | Idempotent
#
# ROOT CAUSE FIXED IN v4 (proven from browser console):
#   frappe.get_route() on a workspace returns ["Workspaces", "CEO Dashboard"],
#   NOT ["ceo-dashboard"]. The v3 guard therefore always returned false and
#   removed the KPI strip immediately. v4 detects the workspace correctly,
#   binds the router lazily, retries until the DOM host exists, and keeps a
#   cheap watchdog so the panel always appears.
#
# DELIBERATE DESIGN CHANGES (announced):
#   - CEO workspace content no longer embeds native number_card/chart blocks
#     (they render blank on this install). Number Card / Dashboard Chart docs
#     REMAIN in the database and in fixtures, unchanged.
#   - KPI values come from one whitelisted server API with SQL aggregation.
#   - Mini charts are drawn with plain CSS (also avoids the upstream RTL
#     chart-legend bug seen in the standard Projects module).
#
# UNTOUCHED (golden rules):
#   posting_date / Workflow / Permission / Validation / phases 2..6
# =============================================================================
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=utf-8

export SITE_NAME="transport-dev.local"
export BENCH_DIR="${HOME}/frappe-bench"
export APP="transport_ir"
export PKG="${BENCH_DIR}/apps/${APP}/${APP}"
export MOD="${PKG}/iran_transport"
export HOOKS="${PKG}/hooks.py"
export NOW_TS
NOW_TS="$(date '+%Y-%m-%d %H:%M:%S').000000"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${YELLOW}======== $* ========${NC}"; }

write_utf8() {
  local target="$1"; local tmp; tmp="$(mktemp)"
  cat >"$tmp"; mkdir -p "$(dirname "$target")"; mv -f "$tmp" "$target"
  log "write: $target"
}

[[ -d "$BENCH_DIR" ]] || err "Bench not found"
[[ -d "${BENCH_DIR}/apps/${APP}" ]] || err "transport_ir not found"
[[ -f "${MOD}/doctype/transport_case/transport_case.json" ]] || err "phase 6 missing"
cd "$BENCH_DIR"
bench use "$SITE_NAME" 2>/dev/null || true

# =============================================================================
step "0) bench services"
if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "bench already running"
else
  nohup bench start >>/tmp/bench-start-phase7.log 2>&1 &
  log "bench start pid=$!"; sleep 12
fi

# non-fatal realtime diagnostic (explains the socket.io console errors)
if ss -lnt 2>/dev/null | grep -q ':9000[[:space:]]'; then
  log "socketio port 9000 is listening"
else
  warn "socketio port 9000 NOT listening — realtime/notifications will error in console."
  warn "This does NOT affect the CEO dashboard. Fix later with: bench setup socketio && bench restart"
fi

# =============================================================================
step "0b) preflight"
for dt in "Trade Case" "Transport Case" "Transport Waybill" "Transport Weighbridge" "Transport Bijak" "Transport Clearance"; do
  cnt="$(bench --site "$SITE_NAME" execute frappe.db.count --args "[\"DocType\", {\"name\": \"${dt}\"}]" 2>/dev/null | tail -1 | tr -d '[:space:]')"
  [[ "$cnt" == "1" ]] || err "DocType missing: ${dt}"
done
log "preflight OK"

# =============================================================================
step "1) Icon sprite (six distinct symbols) — unchanged, proven working"
mkdir -p "${PKG}/public/icons"
write_utf8 "${PKG}/public/icons/transport_sprite.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" style="display:none" aria-hidden="true">
  <symbol id="icon-tir-dashboard" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <path d="M3 3v18h18"></path><path d="M7 14l3-3 3 3 5-6"></path><path d="M18 8h2v2"></path>
  </symbol>
  <symbol id="icon-tir-finance" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <path d="M3 10l9-6 9 6"></path><path d="M4 10v9"></path><path d="M20 10v9"></path>
    <path d="M8 10v9"></path><path d="M12 10v9"></path><path d="M16 10v9"></path><path d="M2 21h20"></path>
  </symbol>
  <symbol id="icon-tir-truck" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <rect x="1" y="3" width="15" height="13"></rect>
    <polygon points="16 8 20 8 23 11 23 16 16 16 16 8"></polygon>
    <circle cx="5.5" cy="18.5" r="2.5"></circle><circle cx="18.5" cy="18.5" r="2.5"></circle>
  </symbol>
  <symbol id="icon-tir-buy" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <path d="M1 3h3l2.4 12.4a2 2 0 0 0 2 1.6h8.6a2 2 0 0 0 2-1.6L23 6H5"></path>
    <circle cx="9" cy="20" r="1.5"></circle><circle cx="18" cy="20" r="1.5"></circle>
  </symbol>
  <symbol id="icon-tir-sell" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <path d="M20.6 13.4L13.4 20.6a2 2 0 0 1-2.8 0l-7-7A2 2 0 0 1 3 12.2V5a2 2 0 0 1 2-2h7.2a2 2 0 0 1 1.4.6l7 7a2 2 0 0 1 0 2.8z"></path>
    <circle cx="7.5" cy="7.5" r="1.5"></circle>
  </symbol>
  <symbol id="icon-tir-customs" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <path d="M12 2l8 3v6c0 5-3.4 8.6-8 11-4.6-2.4-8-6-8-11V5z"></path><path d="M9 12l2 2 4-4"></path>
  </symbol>
</svg>
EOF

# =============================================================================
step "2) ensure_icons.js — sprite injector (kept, proven to load)"
mkdir -p "${PKG}/public/js"
write_utf8 "${PKG}/public/js/ensure_icons.js" << 'EOF'
/* transport_ir — inject the app icon sprite (proven working on this install). */
(function () {
	"use strict";

	var SPRITE_URL = "/assets/transport_ir/icons/transport_sprite.svg";
	var MARKER_ID = "transport-ir-icon-sprite";

	function inject() {
		if (document.getElementById(MARKER_ID)) return;
		if (!document.body) return;
		fetch(SPRITE_URL, { credentials: "same-origin" })
			.then(function (r) { if (!r.ok) throw new Error("sprite " + r.status); return r.text(); })
			.then(function (txt) {
				if (document.getElementById(MARKER_ID)) return;
				var w = document.createElement("div");
				w.id = MARKER_ID;
				w.style.display = "none";
				w.innerHTML = txt;
				document.body.insertBefore(w, document.body.firstChild);
				console.log("[transport_ir] icon sprite injected");
			})
			.catch(function (e) { console.warn("[transport_ir] sprite inject failed:", e); });
	}

	$(function () { setTimeout(inject, 300); });
	$(document).on("app_ready startup", function () { setTimeout(inject, 300); });
})();
EOF

# =============================================================================
step "3) ceo_dashboard_kpi.js — GUARANTEED KPI panel (route bug fixed)"
write_utf8 "${PKG}/public/js/ceo_dashboard_kpi.js" << 'EOF'
/* transport_ir — CEO dashboard KPI panel (phase 7 v4).
 *
 * Why this file exists:
 *   Native Workspace Number Card / Dashboard Chart widgets render blank on
 *   this install. This panel fetches one aggregated payload from the server
 *   and renders deterministic tiles + CSS bars. No chart library, so the
 *   upstream Persian/RTL legend bug cannot occur here.
 *
 * v4 root-cause fix:
 *   In Frappe v15 a workspace route is ["Workspaces", "CEO Dashboard"].
 *   v3 compared route[0] to "ceo-dashboard" and always failed.
 */
(function () {
	"use strict";

	var PANEL_ID = "tir-ceo-kpi";
	var TARGET = "ceo-dashboard";
	var VERSION = "p7 v4";

	console.log("[transport_ir][" + VERSION + "] desk kpi module loaded");

	/* ---------------- helpers ---------------- */

	function slug(value) {
		return String(value || "")
			.trim()
			.toLowerCase()
			.replace(/\s+/g, "-");
	}

	function current_workspace() {
		var route = [];
		try { route = frappe.get_route() || []; } catch (e) { route = []; }

		// Frappe v15 workspace route: ["Workspaces", "CEO Dashboard"]
		if (route.length >= 2 && slug(route[0]) === "workspaces") {
			return String(route[1]);
		}
		// Older/alternate shapes
		if (route.length >= 2 && slug(route[0]) === "workspace") {
			return String(route[1]);
		}
		// URL fallback: /app/ceo-dashboard
		var m = (window.location.pathname || "").match(/^\/app\/([^\/?#]+)/);
		if (m) {
			try { return decodeURIComponent(m[1]); } catch (e) { return m[1]; }
		}
		return route.length ? String(route[0]) : "";
	}

	function on_target_page() {
		return slug(current_workspace()) === TARGET;
	}

	function find_host() {
		var selectors = [
			".layout-main-section .workspace-content",
			".workspace-content",
			".layout-main-section",
			".page-body .layout-main-section",
			".page-container .layout-main-section",
			".layout-main"
		];
		for (var i = 0; i < selectors.length; i++) {
			var $el = $(selectors[i]).filter(":visible").first();
			if ($el.length) return $el;
		}
		return $();
	}

	function fa_number(value, decimals) {
		var n = Number(value || 0);
		try {
			return new Intl.NumberFormat("fa-IR", {
				minimumFractionDigits: 0,
				maximumFractionDigits: decimals === undefined ? 0 : decimals
			}).format(n);
		} catch (e) {
			return String(Math.round(n));
		}
	}

	function esc(value) {
		try { return frappe.utils.escape_html(String(value === undefined ? "" : value)); }
		catch (e) { return String(value === undefined ? "" : value); }
	}

	/* ---------------- rendering ---------------- */

	var COUNT_TILES = [
		{ key: "in_transit",        label: "بارهای در حال حمل",   state: "In Transit",          color: "#4C7CF3" },
		{ key: "pending_transport", label: "منتظر راننده",          state: "Pending Transport",   color: "#F0AD4E" },
		{ key: "waiting_bijak",     label: "منتظر بیجک",            state: "Waiting Bijak",       color: "#F0AD4E" },
		{ key: "waiting_clearance", label: "منتظر ترخیص",           state: "Waiting Clearance",   color: "#E67E22" },
		{ key: "pending_payment",   label: "منتظر پرداخت",          state: "Pending Payment",     color: "#8E5BE8" },
		{ key: "pending_finance",   label: "منتظر بستن مالی",       state: "Pending Finance Close", color: "#5D6D7E" },
		{ key: "completed",         label: "پرونده‌های تکمیل‌شده",   state: "Completed",           color: "#2CA66F" },
		{ key: "total",             label: "کل پرونده‌های حمل",     state: "",                    color: "#34495E" }
	];

	var TOTAL_TILES = [
		{ key: "tonnage",   label: "تناژ حمل‌شده (تن)", color: "#2CA66F", decimals: 1 },
		{ key: "profit",    label: "سود پرونده‌های بسته", color: "#148F77", decimals: 0 },
		{ key: "freight",   label: "هزینه کرایه",        color: "#3498DB", decimals: 0 },
		{ key: "customs",   label: "هزینه گمرک",         color: "#D35400", decimals: 0 },
		{ key: "clearance", label: "هزینه ترخیص",        color: "#9B59B6", decimals: 0 }
	];

	function tile_html(label, value, color, state, decimals) {
		var clickable = state ? ' data-state="' + esc(state) + '" role="button" tabindex="0"' : "";
		var extra = state ? " tir-kpi__tile--click" : "";
		return (
			'<div class="tir-kpi__tile' + extra + '" style="border-top-color:' + color + '"' + clickable + ">" +
			'<div class="tir-kpi__label">' + esc(label) + "</div>" +
			'<div class="tir-kpi__value">' + fa_number(value, decimals) + "</div>" +
			"</div>"
		);
	}

	function bars_html(title, rows) {
		if (!rows || !rows.length) {
			return (
				'<div class="tir-kpi__chart">' +
				'<div class="tir-kpi__chart-title">' + esc(title) + "</div>" +
				'<div class="tir-kpi__empty">داده‌ای برای نمایش وجود ندارد.</div></div>'
			);
		}
		var max = 0;
		rows.forEach(function (r) { max = Math.max(max, Number(r.value || 0)); });
		if (max <= 0) max = 1;

		var body = rows.map(function (r) {
			var pct = Math.max(2, Math.round((Number(r.value || 0) / max) * 100));
			return (
				'<div class="tir-kpi__row">' +
				'<div class="tir-kpi__row-label" title="' + esc(r.label) + '">' + esc(r.label) + "</div>" +
				'<div class="tir-kpi__row-track"><div class="tir-kpi__row-bar" style="width:' + pct + '%"></div></div>' +
				'<div class="tir-kpi__row-val">' + fa_number(r.value, 1) + "</div>" +
				"</div>"
			);
		}).join("");

		return (
			'<div class="tir-kpi__chart">' +
			'<div class="tir-kpi__chart-title">' + esc(title) + "</div>" +
			body +
			"</div>"
		);
	}

	function paint(data) {
		var $panel = $("#" + PANEL_ID);
		if (!$panel.length) return;

		var counts = data.counts || {};
		var totals = data.totals || {};
		var charts = data.charts || {};

		var tiles = COUNT_TILES.map(function (t) {
			return tile_html(t.label, counts[t.key], t.color, t.state, 0);
		}).concat(
			TOTAL_TILES.map(function (t) {
				return tile_html(t.label, totals[t.key], t.color, "", t.decimals);
			})
		).join("");

		var html =
			'<div class="tir-kpi__section-title">شاخص‌های عملیاتی</div>' +
			'<div class="tir-kpi__grid">' + tiles + "</div>" +
			'<div class="tir-kpi__section-title">تحلیل پرونده‌های تکمیل‌شده</div>' +
			'<div class="tir-kpi__bars">' +
			bars_html("تناژ به تفکیک مرز", charts.by_border) +
			bars_html("تناژ به تفکیک کارخانه", charts.by_factory) +
			bars_html("سود به تفکیک مشتری", charts.by_customer) +
			"</div>";

		$panel.html(html);

		$panel.find(".tir-kpi__tile--click").on("click keypress", function (e) {
			if (e.type === "keypress" && e.which !== 13 && e.which !== 32) return;
			var state = $(this).data("state");
			if (!state) return;
			frappe.set_route("List", "Transport Case", { workflow_state: state });
		});

		console.log("[transport_ir][" + VERSION + "] KPI panel rendered");
	}

	function render(attempt) {
		attempt = attempt || 0;

		if (!on_target_page()) {
			$("#" + PANEL_ID).remove();
			return;
		}

		var $host = find_host();
		if (!$host.length) {
			if (attempt < 24) {
				setTimeout(function () { render(attempt + 1); }, 250);
			} else {
				console.warn("[transport_ir][" + VERSION + "] no DOM host found for KPI panel");
			}
			return;
		}

		if ($host.find("#" + PANEL_ID).length) return;

		$host.prepend(
			'<section id="' + PANEL_ID + '" class="tir-kpi">' +
			'<div class="tir-kpi__loading">در حال بارگذاری شاخص‌های مدیریتی…</div>' +
			"</section>"
		);

		frappe.call({
			method: "transport_ir.iran_transport.api.ceo_kpi.get_ceo_kpi",
			type: "GET",
			callback: function (r) {
				if (r && r.message) {
					paint(r.message);
				} else {
					$("#" + PANEL_ID).html('<div class="tir-kpi__empty">پاسخی از سرور دریافت نشد.</div>');
				}
			},
			error: function (e) {
				console.warn("[transport_ir][" + VERSION + "] kpi api failed:", e);
				$("#" + PANEL_ID).html('<div class="tir-kpi__empty">دریافت شاخص‌ها ناموفق بود.</div>');
			}
		});
	}

	function bind_router() {
		if (window.__tir_p7_router_bound) return;
		if (!window.frappe || !frappe.router || !frappe.router.on) return;
		frappe.router.on("change", function () { setTimeout(function () { render(0); }, 200); });
		window.__tir_p7_router_bound = true;
		console.log("[transport_ir][" + VERSION + "] router bound");
	}

	function watchdog() {
		bind_router();
		if (on_target_page() && !$("#" + PANEL_ID).length) {
			render(0);
		}
	}

	$(function () {
		setTimeout(watchdog, 400);
		setInterval(watchdog, 1500);
	});
	$(document).on("app_ready startup page-change", function () {
		setTimeout(watchdog, 300);
	});
})();
EOF

# =============================================================================
step "4) CSS (progress bar + KPI panel)"
mkdir -p "${PKG}/public/css"
write_utf8 "${PKG}/public/css/phase7_transport_ui.css" << 'EOF'
/* ---------- Transport Case progress bar ---------- */
.transport-phase7-progress {
  direction: rtl; margin: 0 0 18px; padding: 14px 16px;
  border: 1px solid var(--border-color, #d1d8dd); border-radius: 10px;
  background: var(--card-bg, #fff); box-shadow: 0 1px 3px rgba(0, 0, 0, .04);
}
.transport-phase7-progress__head { display: flex; justify-content: space-between; align-items: center; gap: 12px; margin-bottom: 10px; }
.transport-phase7-progress__title { font-weight: 700; color: var(--heading-color, #1f272e); }
.transport-phase7-progress__meta { font-size: 12px; color: var(--text-muted, #6c7680); margin-top: 4px; }
.transport-phase7-progress__state { font-size: 12px; font-weight: 700; border-radius: 999px; padding: 4px 10px; }
.transport-phase7-progress__state--primary { color: #1a4f96; background: #e8f1ff; }
.transport-phase7-progress__state--warning { color: #855c00; background: #fff3cd; }
.transport-phase7-progress__state--success { color: #0c6b3d; background: #def7e8; }
.transport-phase7-progress__state--danger  { color: #9d1d1d; background: #fde7e7; }
.transport-phase7-progress__track { width: 100%; height: 10px; overflow: hidden; border-radius: 999px; background: #e9edf0; }
.transport-phase7-progress__bar { height: 100%; border-radius: inherit; transition: width .25s ease; }
.transport-phase7-progress__bar--primary { background: #4c7cf3; }
.transport-phase7-progress__bar--warning { background: #f0ad4e; }
.transport-phase7-progress__bar--success { background: #2ca66f; }
.transport-phase7-progress__bar--danger  { background: #df4b4b; }
.transport-phase7-progress__caption { margin-top: 9px; color: var(--text-muted, #6c7680); font-size: 12px; }
@media (max-width: 576px) { .transport-phase7-progress__head { align-items: flex-start; flex-direction: column; } }

/* ---------- CEO KPI panel ---------- */
.tir-kpi { direction: rtl; margin: 0 0 22px; }
.tir-kpi__loading, .tir-kpi__empty {
  font-size: 12px; color: var(--text-muted, #6c7680);
  padding: 10px 14px; border: 1px dashed var(--border-color, #d1d8dd); border-radius: 10px;
}
.tir-kpi__section-title { font-weight: 700; margin: 6px 0 10px; color: var(--heading-color, #1f272e); }
.tir-kpi__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(158px, 1fr)); gap: 10px; }
.tir-kpi__tile {
  padding: 12px 14px; border: 1px solid var(--border-color, #d1d8dd);
  border-top: 3px solid #4c7cf3; border-radius: 10px;
  background: var(--card-bg, #fff); transition: box-shadow .15s ease, transform .15s ease;
}
.tir-kpi__tile--click { cursor: pointer; }
.tir-kpi__tile--click:hover { box-shadow: 0 3px 10px rgba(0,0,0,.08); transform: translateY(-1px); }
.tir-kpi__label { font-size: 12px; color: var(--text-muted, #6c7680); }
.tir-kpi__value { font-size: 20px; font-weight: 700; margin-top: 6px; color: var(--heading-color, #1f272e); }
.tir-kpi__bars { display: grid; grid-template-columns: repeat(auto-fit, minmax(290px, 1fr)); gap: 12px; margin-top: 4px; }
.tir-kpi__chart {
  padding: 12px 14px; border: 1px solid var(--border-color, #d1d8dd);
  border-radius: 10px; background: var(--card-bg, #fff);
}
.tir-kpi__chart-title { font-weight: 700; font-size: 13px; margin-bottom: 10px; }
.tir-kpi__row { display: flex; align-items: center; gap: 8px; margin: 7px 0; }
.tir-kpi__row-label { flex: 0 0 96px; font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.tir-kpi__row-track { flex: 1; height: 8px; background: #e9edf0; border-radius: 999px; overflow: hidden; }
.tir-kpi__row-bar { height: 100%; background: #4c7cf3; border-radius: inherit; }
.tir-kpi__row-val { flex: 0 0 auto; font-size: 12px; color: var(--text-muted, #6c7680); min-width: 46px; text-align: left; }
EOF

# =============================================================================
step "5) Server API: transport_ir.iran_transport.api.ceo_kpi"
mkdir -p "${MOD}/api"
write_utf8 "${MOD}/api/__init__.py" << 'EOF'
# API package
EOF
write_utf8 "${MOD}/api/ceo_kpi.py" << 'EOF'
"""Aggregated KPI payload for the CEO dashboard panel.

Read-only. Does not alter documents, workflow, permissions or fields.
"""
from __future__ import annotations

import frappe
from frappe import _
from frappe.utils import flt, now_datetime

ALLOWED_ROLES = {
    "CEO",
    "System Manager",
    "Financial Manager",
    "Finance Supervisor",
    "Transport Supervisor",
}

COUNT_STATES = {
    "in_transit": "In Transit",
    "pending_transport": "Pending Transport",
    "waiting_bijak": "Waiting Bijak",
    "waiting_clearance": "Waiting Clearance",
    "pending_payment": "Pending Payment",
    "pending_finance": "Pending Finance Close",
    "completed": "Completed",
}

GROUPS = (
    ("by_border", "border", "actual_tonnage"),
    ("by_factory", "supplier_factory", "actual_tonnage"),
    ("by_customer", "customer", "estimated_profit"),
)


def _guard():
    roles = set(frappe.get_roles())
    if not (roles & ALLOWED_ROLES):
        frappe.throw(
            _("شما به شاخص‌های مدیریتی دسترسی ندارید."),
            frappe.PermissionError,
        )


def _counts():
    rows = frappe.db.sql(
        """
        select ifnull(workflow_state, 'Draft') as state, count(*) as cnt
        from `tabTransport Case`
        group by ifnull(workflow_state, 'Draft')
        """,
        as_dict=True,
    )
    by_state = {r.state: int(r.cnt or 0) for r in rows}

    result = {key: by_state.get(state, 0) for key, state in COUNT_STATES.items()}
    result["total"] = sum(by_state.values())
    return result


def _totals():
    row = frappe.db.sql(
        """
        select
            ifnull(sum(actual_tonnage), 0)   as tonnage,
            ifnull(sum(estimated_profit), 0) as profit,
            ifnull(sum(freight_cost), 0)     as freight,
            ifnull(sum(customs_cost), 0)     as customs,
            ifnull(sum(clearance_cost), 0)   as clearance
        from `tabTransport Case`
        where workflow_state = 'Completed'
        """,
        as_dict=True,
    )
    data = row[0] if row else {}
    return {
        "tonnage": flt(data.get("tonnage")),
        "profit": flt(data.get("profit")),
        "freight": flt(data.get("freight")),
        "customs": flt(data.get("customs")),
        "clearance": flt(data.get("clearance")),
    }


def _group(group_field, value_field, limit=8):
    # group_field / value_field come from the module-level GROUPS constant only.
    rows = frappe.db.sql(
        """
        select
            ifnull(nullif(`{gf}`, ''), '—') as label,
            ifnull(sum(`{vf}`), 0) as value
        from `tabTransport Case`
        where workflow_state = 'Completed'
        group by ifnull(nullif(`{gf}`, ''), '—')
        having value <> 0
        order by value desc
        limit {lim}
        """.format(gf=group_field, vf=value_field, lim=int(limit)),
        as_dict=True,
    )
    return [{"label": r.label, "value": flt(r.value)} for r in rows]


@frappe.whitelist()
def get_ceo_kpi():
    """Return one aggregated payload for the CEO dashboard panel."""
    _guard()

    charts = {}
    for key, group_field, value_field in GROUPS:
        try:
            charts[key] = _group(group_field, value_field)
        except Exception:
            charts[key] = []

    return {
        "counts": _counts(),
        "totals": _totals(),
        "charts": charts,
        "generated_on": str(now_datetime()),
    }
EOF

# =============================================================================
step "6) hooks.py (two JS files + CSS + merged fixtures)"
python3 << 'PYEOF'
import ast, os, re
p = os.environ["HOOKS"]
src = open(p, encoding="utf-8").read()
src = re.sub(r"# --- PHASE7_HOOKS_START ---.*?# --- PHASE7_HOOKS_END ---\n?", "", src, flags=re.DOTALL)
if "app_include_icons" in src:
    src = re.sub(r'^.*app_include_icons.*$', '', src, flags=re.M)
if not re.search(r"^fixtures\s*=", src, flags=re.M):
    src += "\n\nfixtures = []\n"

addition = '''
# --- PHASE7_HOOKS_START ---
_p7_js = globals().get("app_include_js", [])
app_include_js = list(_p7_js) if isinstance(_p7_js, (list, tuple)) else [_p7_js]
for _f in [
    "/assets/transport_ir/js/ensure_icons.js",
    "/assets/transport_ir/js/ceo_dashboard_kpi.js",
]:
    if _f not in app_include_js:
        app_include_js.append(_f)

_p7_css = globals().get("app_include_css", [])
app_include_css = list(_p7_css) if isinstance(_p7_css, (list, tuple)) else [_p7_css]
if "/assets/transport_ir/css/phase7_transport_ui.css" not in app_include_css:
    app_include_css.append("/assets/transport_ir/css/phase7_transport_ui.css")

fixtures = list(fixtures) if isinstance(fixtures, (list, tuple)) else []
fixtures = [f for f in fixtures if not (isinstance(f, dict) and f.get("dt") in (
    "Client Script", "Translation", "Number Card", "Dashboard Chart", "Kanban Board"))]
fixtures.extend([
    {"dt": "Client Script", "filters": [["name", "in", [
        "Trade Case UX", "Transport Case UX Phase6",
        "Transport Case UX Phase7", "Transport Case List UX Phase7"]]]},
    {"dt": "Translation", "filters": [["language", "=", "fa"]]},
    {"dt": "Number Card", "filters": [["module", "=", "Iran Transport"]]},
    {"dt": "Dashboard Chart", "filters": [["module", "=", "Iran Transport"]]},
    {"dt": "Kanban Board", "filters": [["name", "=", "Transport Case Workflow Board"]]},
])
# --- PHASE7_HOOKS_END ---
'''
open(p, "w", encoding="utf-8").write(src + addition)
ast.parse(open(p, encoding="utf-8").read())
print("hooks updated + syntax OK")
PYEOF

# =============================================================================
step "7) Six role-based Workspaces (CEO content = links only, panel via JS)"
python3 << 'PYEOF'
import json, os
mod = os.environ["MOD"]; now = os.environ["NOW_TS"]
base = os.path.join(mod, "workspace")

def link(label, target):
    return {"type": "Link", "label": label, "link_type": "DocType", "link_to": target,
            "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""}
def card(label, count):
    return {"type": "Card Break", "label": label, "link_count": count,
            "hidden": 0, "onboard": 0, "is_query_report": 0}
def shortcut(label, target, color):
    return {"type": "DocType", "label": label, "link_to": target, "doc_view": "List",
            "color": color, "format": "", "stats_filter": ""}
def content_cards(names):
    return [{"id": f"p7-card-{i}", "type": "card", "data": {"card_name": n, "col": 4}}
            for i, n in enumerate(names, 1)]

def ceo_content():
    # DELIBERATE: no native number_card / chart blocks here.
    # The guaranteed KPI panel is rendered by ceo_dashboard_kpi.js.
    return [
        {"id": "p7-ceo-title", "type": "header",
         "data": {"text": "<span class=\"h4\">داشبورد مدیریت حمل و نقل</span>", "col": 12}},
    ] + content_cards(["پرونده‌ها و گزارش‌ها"])

def workspace(folder, name, label, icon, roles, seq, links, shortcuts, content):
    roles = list(roles)
    if "System Manager" not in roles:
        roles.append("System Manager")
    d = os.path.join(base, folder); os.makedirs(d, exist_ok=True)
    ip = os.path.join(d, "__init__.py")
    if not os.path.exists(ip):
        open(ip, "w", encoding="utf-8").write("# Workspace package\n")
    data = {
        "charts": [], "content": json.dumps(content, ensure_ascii=False, separators=(",", ":")),
        "creation": now, "doctype": "Workspace", "for_user": "", "hide_custom": 0,
        "icon": icon, "is_default": 0, "is_hidden": 0, "is_standard": 1,
        "label": label, "links": links, "modified": now, "modified_by": "Administrator",
        "module": "Iran Transport", "name": name, "number_cards": [], "owner": "Administrator",
        "parent_page": "", "public": 1, "quick_lists": [], "restrict_to_domain": "",
        "roles": [{"role": r} for r in roles], "sequence_id": seq,
        "shortcuts": shortcuts, "title": label,
    }
    json.dump(data, open(os.path.join(d, f"{folder}.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print("workspace written:", folder, "| icon:", icon)

workspace("ceo_dashboard", "CEO Dashboard", "CEO Dashboard", "tir-dashboard", ["CEO"], 10.0,
    [card("پرونده‌ها و گزارش‌ها", 5), link("Transport Case", "Transport Case"),
     link("Trade Case", "Trade Case"), link("Transport Waybill", "Transport Waybill"),
     link("Carrier", "Carrier"), link("Border", "Border")],
    [shortcut("Transport Case", "Transport Case", "Blue"), shortcut("Trade Case", "Trade Case", "Green")],
    ceo_content())

workspace("finance", "Finance", "Finance", "tir-finance",
    ["Financial Manager", "Finance Supervisor", "Finance User", "Legal Reviewer",
     "Treasury User", "Receivables User", "Document Signer"], 11.0,
    [card("کارتابل مالی و بازرگانی", 2), link("Trade Case", "Trade Case"),
     link("Transport Case", "Transport Case"), card("اسناد و مرجع", 4),
     link("Transport Waybill", "Transport Waybill"), link("Carrier", "Carrier"),
     link("Driver", "Driver"), link("Border", "Border")],
    [shortcut("Trade Case", "Trade Case", "Green"), shortcut("Transport Case", "Transport Case", "Blue")],
    content_cards(["کارتابل مالی و بازرگانی", "اسناد و مرجع"]))

workspace("iran_transport", "Iran Transport", "Iran Transport", "tir-truck",
    ["Transport Supervisor"], 20.0,
    [card("عملیات حمل", 5), link("Transport Case", "Transport Case"),
     link("Transport Waybill", "Transport Waybill"), link("Transport Weighbridge", "Transport Weighbridge"),
     link("Transport Bijak", "Transport Bijak"), link("Transport Clearance", "Transport Clearance"),
     card("اطلاعات پایه", 6), link("Driver", "Driver"), link("Vehicle", "Vehicle"),
     link("Carrier", "Carrier"), link("Border", "Border"),
     link("Customs Broker", "Customs Broker"), link("Border Representative", "Border Representative"),
     card("بازرگانی", 1), link("Trade Case", "Trade Case")],
    [shortcut("Transport Case", "Transport Case", "Blue"), shortcut("Trade Case", "Trade Case", "Green")],
    content_cards(["عملیات حمل", "اطلاعات پایه", "بازرگانی"]))

workspace("transport_purchase", "Transport Purchase", "Transport Purchase", "tir-buy",
    ["Transport User - Purchase"], 21.0,
    [card("کارتابل حمل خرید", 3), link("Transport Case", "Transport Case"),
     link("Transport Waybill", "Transport Waybill"), link("Transport Bijak", "Transport Bijak"),
     card("اطلاعات پایه", 4), link("Driver", "Driver"), link("Vehicle", "Vehicle"),
     link("Carrier", "Carrier"), link("Border", "Border")],
    [shortcut("Transport Case", "Transport Case", "Blue"), shortcut("Transport Waybill", "Transport Waybill", "Orange")],
    content_cards(["کارتابل حمل خرید", "اطلاعات پایه"]))

workspace("transport_sales", "Transport Sales", "Transport Sales", "tir-sell",
    ["Transport User - Sales"], 22.0,
    [card("کارتابل حمل فروش", 3), link("Transport Case", "Transport Case"),
     link("Transport Waybill", "Transport Waybill"), link("Transport Weighbridge", "Transport Weighbridge"),
     card("اطلاعات پایه", 4), link("Driver", "Driver"), link("Vehicle", "Vehicle"),
     link("Carrier", "Carrier"), link("Border", "Border")],
    [shortcut("Transport Case", "Transport Case", "Blue"), shortcut("Transport Weighbridge", "Transport Weighbridge", "Purple")],
    content_cards(["کارتابل حمل فروش", "اطلاعات پایه"]))

workspace("customs", "Customs", "Customs", "tir-customs", ["Customs Officer"], 23.0,
    [card("کارتابل گمرک و ترخیص", 4), link("Transport Case", "Transport Case"),
     link("Transport Bijak", "Transport Bijak"), link("Transport Clearance", "Transport Clearance"),
     link("Transport Weighbridge", "Transport Weighbridge"), card("اطلاعات پایه گمرک", 3),
     link("Border", "Border"), link("Customs Broker", "Customs Broker"),
     link("Border Representative", "Border Representative")],
    [shortcut("Transport Case", "Transport Case", "Blue"), shortcut("Transport Clearance", "Transport Clearance", "Red")],
    content_cards(["کارتابل گمرک و ترخیص", "اطلاعات پایه گمرک"]))
PYEOF

# =============================================================================
step "8) Translations + Client Scripts (merged, non-destructive)"
mkdir -p "${PKG}/fixtures"
python3 << 'PYEOF'
import json, os
from copy import deepcopy
pkg = os.environ["PKG"]; now = os.environ["NOW_TS"]
fx = os.path.join(pkg, "fixtures")

def load(fn):
    p = os.path.join(fx, fn)
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else []
def dump(fn, rows):
    json.dump(rows, open(os.path.join(fx, fn), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("fixture written:", fn, f"({len(rows)} rows)")

tr = load("translation.json")
by = {(r.get("language"), r.get("source_text")): r for r in tr
      if isinstance(r, dict) and r.get("language") and r.get("source_text")}

rows = [
    ("fa-ws-iran-transport", "Iran Transport", "حمل و نقل"),
    ("fa-ws-ceo-dashboard", "CEO Dashboard", "داشبورد مدیرعامل"),
    ("fa-ws-finance", "Finance", "مالی"),
    ("fa-ws-transport-purchase", "Transport Purchase", "حمل خرید"),
    ("fa-ws-transport-sales", "Transport Sales", "حمل فروش"),
    ("fa-ws-customs", "Customs", "گمرک"),
    ("fa-transport-case", "Transport Case", "پرونده حمل"),
    ("fa-trade-case", "Trade Case", "پرونده تجاری"),
    ("fa-transport-waybill", "Transport Waybill", "بارنامه حمل"),
    ("fa-transport-weighbridge", "Transport Weighbridge", "باسکول حمل"),
    ("fa-transport-bijak", "Transport Bijak", "بیجک حمل"),
    ("fa-transport-clearance", "Transport Clearance", "ترخیص حمل"),
    ("fa-state-draft", "Draft", "پیش‌نویس"),
    ("fa-state-pending-supervisor", "Pending Supervisor Review", "در انتظار بررسی سرپرست"),
    ("fa-state-pending-transport", "Pending Transport", "در انتظار عملیات حمل"),
    ("fa-state-driver-assigned", "Driver Assigned", "راننده تخصیص یافت"),
    ("fa-state-waybill-issued", "Waybill Issued", "بارنامه صادر شد"),
    ("fa-state-in-transit", "In Transit", "در حال حمل"),
    ("fa-state-waiting-weighbridge", "Waiting Weighbridge", "در انتظار باسکول"),
    ("fa-state-waiting-bijak", "Waiting Bijak", "در انتظار بیجک"),
    ("fa-state-waiting-clearance", "Waiting Clearance", "در انتظار ترخیص"),
    ("fa-state-cleared", "Cleared", "ترخیص شد"),
    ("fa-state-delivered", "Delivered", "تحویل شد"),
    ("fa-state-pending-payment", "Pending Payment", "در انتظار پرداخت"),
    ("fa-state-pending-finance-close", "Pending Finance Close", "در انتظار بستن مالی"),
    ("fa-state-completed", "Completed", "تکمیل‌شده"),
    ("fa-state-on-hold", "On Hold", "معلق"),
    ("fa-state-cancelled", "Cancelled", "لغوشده"),
    ("fa-state-rejected", "Rejected", "ردشده"),
    ("fa-kpi-in-transit", "Transport KPI - In Transit", "بارهای در حال حمل"),
    ("fa-kpi-pending-driver", "Transport KPI - Pending Driver", "در انتظار راننده"),
    ("fa-kpi-waiting-bijak", "Transport KPI - Waiting Bijak", "در انتظار بیجک"),
    ("fa-kpi-waiting-clearance", "Transport KPI - Waiting Clearance", "در انتظار ترخیص"),
    ("fa-kpi-pending-payment", "Transport KPI - Pending Payment", "در انتظار پرداخت"),
    ("fa-kpi-completed-cases", "Transport KPI - Completed Cases", "پرونده‌های تکمیل‌شده"),
    ("fa-kpi-completed-tonnage", "Transport KPI - Completed Tonnage", "تناژ حمل‌شده"),
    ("fa-kpi-completed-profit", "Transport KPI - Completed Profit", "سود پرونده‌های بسته"),
    ("fa-kpi-completed-freight", "Transport KPI - Completed Freight", "هزینه کرایه"),
    ("fa-kpi-completed-customs", "Transport KPI - Completed Customs", "هزینه گمرک"),
    ("fa-kpi-completed-clearance", "Transport KPI - Completed Clearance", "هزینه ترخیص"),
    ("fa-chart-tonnage-border", "Transport KPI - Tonnage by Border", "تناژ به تفکیک مرز"),
    ("fa-chart-tonnage-factory", "Transport KPI - Tonnage by Factory", "تناژ به تفکیک کارخانه"),
    ("fa-chart-profit-customer", "Transport KPI - Profit by Customer", "سود به تفکیک مشتری"),
]
for nm, s, d in rows:
    r = deepcopy(by.get(("fa", s), {}))
    r.update({"doctype": "Translation", "name": r.get("name") or nm, "language": "fa",
              "source_text": s, "translated_text": d, "modified": now})
    by[("fa", s)] = r
dump("translation.json", sorted(by.values(), key=lambda x: (x.get("language",""), x.get("source_text",""))))

cs = load("client_script.json")
cs_by = {r.get("name"): r for r in cs if isinstance(r, dict) and r.get("name")}

form_script = r"""
(() => {
    "use strict";
    const progress = { "Draft": 5, "Pending Supervisor Review": 10, "Pending Transport": 20, "Driver Assigned": 30,
        "Waybill Issued": 40, "In Transit": 50, "Waiting Weighbridge": 60, "Waiting Bijak": 70,
        "Waiting Clearance": 78, "Cleared": 85, "Delivered": 90, "Pending Payment": 94,
        "Pending Finance Close": 97, "Completed": 100, "On Hold": 35, "Cancelled": 0, "Rejected": 0 };
    const stateClass = { "Completed": "success", "Cleared": "success", "Delivered": "success",
        "Cancelled": "danger", "Rejected": "danger", "On Hold": "warning",
        "Pending Supervisor Review": "warning", "Pending Transport": "warning",
        "Waiting Weighbridge": "warning", "Waiting Bijak": "warning",
        "Waiting Clearance": "warning", "Pending Payment": "warning", "Pending Finance Close": "warning" };
    const color = (s) => stateClass[s] || "primary";
    function render(frm) {
        if (frm.is_new()) { frm.$wrapper.find(".transport-phase7-progress").remove(); return; }
        const st = frm.doc.workflow_state || "Draft";
        const pct = progress[st] || 0;
        const assignee = frm.doc.assigned_user ? ("مسئول: " + frm.doc.assigned_user) : "";
        frm.$wrapper.find(".transport-phase7-progress").remove();
        const html = `
            <section class="transport-phase7-progress">
                <div class="transport-phase7-progress__head">
                    <div>
                        <span class="transport-phase7-progress__title">وضعیت پرونده حمل</span>
                        <div class="transport-phase7-progress__meta">${frappe.utils.escape_html(assignee)}</div>
                    </div>
                    <span class="transport-phase7-progress__state transport-phase7-progress__state--${color(st)}">${frappe.utils.escape_html(__(st))}</span>
                </div>
                <div class="transport-phase7-progress__track" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${pct}">
                    <div class="transport-phase7-progress__bar transport-phase7-progress__bar--${color(st)}" style="width:${pct}%"></div>
                </div>
                <div class="transport-phase7-progress__caption">پیشرفت تقریبی عملیات: ${pct}٪</div>
            </section>`;
        const $l = frm.$wrapper.find(".form-layout").first();
        if ($l.length) { $l.before(html); }
    }
    frappe.ui.form.on("Transport Case", { refresh(frm) { render(frm); }, workflow_state(frm) { render(frm); } });
})();
"""

list_script = r"""
(() => {
    "use strict";
    const role = (n) => frappe.user.has_role(n);
    function filters() {
        if (role("Transport User - Purchase")) return [["Transport Case", "case_type", "=", "خرید"]];
        if (role("Transport User - Sales")) return [["Transport Case", "case_type", "=", "فروش"]];
        if (role("Customs Officer")) return [["Transport Case", "workflow_state", "in", ["Waiting Bijak", "Waiting Clearance"]]];
        if (role("Finance Supervisor") || role("Financial Manager")) return [["Transport Case", "workflow_state", "=", "Pending Finance Close"]];
        return [];
    }
    const s = frappe.listview_settings["Transport Case"] || {};
    const prev = s.onload;
    s.onload = function (lv) {
        if (typeof prev === "function") prev(lv);
        if (lv.__p7_done) return;
        lv.__p7_done = true;
        setTimeout(() => {
            if (frappe.route_options && Object.keys(frappe.route_options).length) return;
            const f = filters();
            if (!f.length || !lv.filter_area) return;
            try { lv.filter_area.add(f); lv.refresh(); } catch (e) { console.warn("[transport_ir] filter skipped", e); }
        }, 100);
    };
    frappe.listview_settings["Transport Case"] = s;
})();
"""

for r in [
    {"doctype": "Client Script", "name": "Transport Case UX Phase7", "dt": "Transport Case",
     "view": "Form", "enabled": 1, "script": form_script, "modified": now},
    {"doctype": "Client Script", "name": "Transport Case List UX Phase7", "dt": "Transport Case",
     "view": "List", "enabled": 1, "script": list_script, "modified": now},
]:
    old = deepcopy(cs_by.get(r["name"], {})); old.update(r); cs_by[r["name"]] = old
dump("client_script.json", sorted(cs_by.values(), key=lambda x: x.get("name","")))
print("fixtures OK")
PYEOF

# =============================================================================
step "9) UI provisioner (KPI docs kept in DB + safe Kanban + workspaces)"
write_utf8 "${MOD}/setup_ui_phase7.py" << 'EOF'
"""Phase 7 UI provisioning (v4).

Number Card and Dashboard Chart documents are still created and kept in the
database (and exported through fixtures). They are simply not embedded into
the CEO workspace content, because native widget rendering is unreliable on
this install. The visible KPI panel is produced by ceo_dashboard_kpi.js.
"""
from __future__ import annotations
import json
import frappe

NUMBER_CARDS = [
    {"name": "Transport KPI - In Transit", "function": "Count", "state": "In Transit", "color": "#4C7CF3"},
    {"name": "Transport KPI - Pending Driver", "function": "Count", "state": "Pending Transport", "color": "#F0AD4E"},
    {"name": "Transport KPI - Waiting Bijak", "function": "Count", "state": "Waiting Bijak", "color": "#F0AD4E"},
    {"name": "Transport KPI - Waiting Clearance", "function": "Count", "state": "Waiting Clearance", "color": "#E67E22"},
    {"name": "Transport KPI - Pending Payment", "function": "Count", "state": "Pending Payment", "color": "#8E5BE8"},
    {"name": "Transport KPI - Completed Cases", "function": "Count", "state": "Completed", "color": "#2CA66F"},
    {"name": "Transport KPI - Completed Tonnage", "function": "Sum", "field": "actual_tonnage", "state": "Completed", "color": "#2CA66F"},
    {"name": "Transport KPI - Completed Profit", "function": "Sum", "field": "estimated_profit", "state": "Completed", "color": "#148F77"},
    {"name": "Transport KPI - Completed Freight", "function": "Sum", "field": "freight_cost", "state": "Completed", "color": "#3498DB"},
    {"name": "Transport KPI - Completed Customs", "function": "Sum", "field": "customs_cost", "state": "Completed", "color": "#D35400"},
    {"name": "Transport KPI - Completed Clearance", "function": "Sum", "field": "clearance_cost", "state": "Completed", "color": "#9B59B6"},
]

DASHBOARD_CHARTS = [
    {"name": "Transport KPI - Tonnage by Border", "group_by": "border", "value": "actual_tonnage", "aggregate": "Sum"},
    {"name": "Transport KPI - Tonnage by Factory", "group_by": "supplier_factory", "value": "actual_tonnage", "aggregate": "Sum"},
    {"name": "Transport KPI - Profit by Customer", "group_by": "customer", "value": "estimated_profit", "aggregate": "Sum"},
]

# Safe Kanban: no Draft / On Hold / Cancelled / Rejected, so drag & drop
# cannot hit the phase-6 stage guards.
KANBAN_STATES = [
    "Pending Transport", "Driver Assigned", "Waybill Issued", "In Transit",
    "Waiting Weighbridge", "Waiting Bijak", "Waiting Clearance",
    "Cleared", "Delivered", "Pending Payment", "Pending Finance Close", "Completed",
]

WORKSPACE_FILES = [
    ("CEO Dashboard", "ceo_dashboard", "ceo_dashboard.json"),
    ("Finance", "finance", "finance.json"),
    ("Iran Transport", "iran_transport", "iran_transport.json"),
    ("Transport Purchase", "transport_purchase", "transport_purchase.json"),
    ("Transport Sales", "transport_sales", "transport_sales.json"),
    ("Customs", "customs", "customs.json"),
]


def _set(doc, field, value):
    if doc.meta.has_field(field):
        setattr(doc, field, value)


def _save(doc):
    doc.flags.ignore_permissions = True
    doc.flags.ignore_links = True
    doc.insert(ignore_permissions=True) if doc.is_new() else doc.save(ignore_permissions=True)


def _wf(state):
    return json.dumps([["Transport Case", "workflow_state", "=", state, False]], ensure_ascii=False)


def ensure_module_binding():
    if not frappe.db.exists("Module Def", "Iran Transport"):
        frappe.throw("Module Def 'Iran Transport' missing — phase 3 incomplete.")
    module = frappe.get_doc("Module Def", "Iran Transport")
    if module.meta.has_field("app_name") and module.app_name != "transport_ir":
        module.app_name = "transport_ir"
        _save(module)


def ensure_number_cards():
    for spec in NUMBER_CARDS:
        doc = (frappe.get_doc("Number Card", spec["name"])
               if frappe.db.exists("Number Card", spec["name"])
               else frappe.new_doc("Number Card"))
        if doc.is_new():
            doc.name = spec["name"]
        _set(doc, "label", spec["name"])
        _set(doc, "type", "Document Type")
        _set(doc, "document_type", "Transport Case")
        _set(doc, "function", spec["function"])
        _set(doc, "filters_json", _wf(spec["state"]))
        _set(doc, "is_public", 1)
        _set(doc, "module", "Iran Transport")
        _set(doc, "color", spec["color"])
        _set(doc, "stats_time_interval", "Daily")
        if spec["function"] != "Count":
            _set(doc, "aggregate_function_based_on", spec["field"])
        _save(doc)


def ensure_charts():
    completed = _wf("Completed")
    for spec in DASHBOARD_CHARTS:
        doc = (frappe.get_doc("Dashboard Chart", spec["name"])
               if frappe.db.exists("Dashboard Chart", spec["name"])
               else frappe.new_doc("Dashboard Chart"))
        if doc.is_new():
            doc.name = spec["name"]
        _set(doc, "chart_name", spec["name"])
        _set(doc, "chart_type", "Group By")
        _set(doc, "document_type", "Transport Case")
        _set(doc, "group_by_based_on", spec["group_by"])
        _set(doc, "group_by_type", spec["aggregate"])
        _set(doc, "aggregate_function_based_on", spec["value"])
        _set(doc, "filters_json", completed)
        _set(doc, "is_public", 1)
        _set(doc, "module", "Iran Transport")
        _set(doc, "type", "Bar")
        _set(doc, "number_of_groups", 10)
        _save(doc)


def ensure_kanban():
    name = "Transport Case Workflow Board"
    board = (frappe.get_doc("Kanban Board", name)
             if frappe.db.exists("Kanban Board", name)
             else frappe.new_doc("Kanban Board"))
    if board.is_new():
        board.name = name
    _set(board, "kanban_board_name", name)
    _set(board, "reference_doctype", "Transport Case")
    _set(board, "field_name", "workflow_state")
    _set(board, "private", 0)
    if board.meta.has_field("columns"):
        board.set("columns", [])
        for state in KANBAN_STATES:
            board.append("columns", {"column_name": state, "status": "Active"})
    _save(board)


def sync_workspace(name, folder, filename):
    path = frappe.get_app_path("transport_ir", "iran_transport", "workspace", folder, filename)
    data = json.load(open(path, encoding="utf-8"))
    doc = (frappe.get_doc("Workspace", name)
           if frappe.db.exists("Workspace", name)
           else frappe.new_doc("Workspace"))
    if doc.is_new():
        doc.name = name
    for field in ["label", "title", "module", "public", "icon", "content", "sequence_id",
                  "parent_page", "for_user", "is_hidden", "hide_custom", "is_standard", "is_default"]:
        if field in data and doc.meta.has_field(field):
            setattr(doc, field, data[field])
    for table in ["links", "shortcuts", "charts", "number_cards", "quick_lists", "roles"]:
        if doc.meta.has_field(table):
            doc.set(table, [])
    for row in data.get("links", []):
        doc.append("links", row)
    for row in data.get("shortcuts", []):
        doc.append("shortcuts", row)
    for row in data.get("roles", []):
        doc.append("roles", row)
    _save(doc)


def setup_ui_phase7(commit=True):
    frappe.flags.in_patch = True
    ensure_module_binding()
    ensure_number_cards()
    ensure_charts()
    ensure_kanban()
    for stale in ["داشبورد مدیرعامل", "امور مالی", "مدیریت حمل",
                  "حمل خریـد", "حمل فـروش", "گمرک و ترخیص"]:
        if frappe.db.exists("Workspace", stale):
            try:
                frappe.delete_doc("Workspace", stale, ignore_permissions=True, force=True)
            except Exception:
                pass
    for name, folder, filename in WORKSPACE_FILES:
        sync_workspace(name, folder, filename)
    if commit:
        frappe.db.commit()
    frappe.clear_cache()
    print("Phase 7 UI provisioned successfully")
EOF

# =============================================================================
step "10) Migration patch (post_model_sync)"
mkdir -p "${PKG}/patches/v1_0"
touch "${PKG}/patches/__init__.py" "${PKG}/patches/v1_0/__init__.py"
write_utf8 "${PKG}/patches/v1_0/phase7_ui.py" << 'EOF'
from transport_ir.iran_transport.setup_ui_phase7 import setup_ui_phase7


def execute():
    setup_ui_phase7(commit=False)
EOF
PATCHES="${PKG}/patches.txt"
touch "$PATCHES"
grep -q '^\[post_model_sync\]' "$PATCHES" || printf '\n[post_model_sync]\n' >> "$PATCHES"
ENTRY="transport_ir.patches.v1_0.phase7_ui"
grep -qxF "$ENTRY" "$PATCHES" || printf '%s\n' "$ENTRY" >> "$PATCHES"
log "patch registered"

# =============================================================================
step "11) verify_phase7.py (server-side, includes live API call)"
write_utf8 "${MOD}/verify_phase7.py" << 'EOF'
import json
import os

import frappe


def verify_phase7():
    passed, failed = [], []

    def check(name, condition, detail=""):
        (passed if condition else failed).append(name)
        print(("✅ PASS" if condition else "❌ FAIL") + f": {name}" + (f" — {detail}" if detail else ""))

    # ---------- assets ----------
    sprite = frappe.get_app_path("transport_ir", "public", "icons", "transport_sprite.svg")
    icons_js = frappe.get_app_path("transport_ir", "public", "js", "ensure_icons.js")
    kpi_js = frappe.get_app_path("transport_ir", "public", "js", "ceo_dashboard_kpi.js")

    check("sprite file exists", os.path.exists(sprite))
    check("ensure_icons.js exists", os.path.exists(icons_js))
    check("ceo_dashboard_kpi.js exists", os.path.exists(kpi_js))

    if os.path.exists(kpi_js):
        body = open(kpi_js, encoding="utf-8").read()
        check("kpi js detects Workspaces route", 'slug(route[0]) === "workspaces"' in body)
        check("kpi js has watchdog", "setInterval(watchdog" in body)
        check("kpi js calls server api", "api.ceo_kpi.get_ceo_kpi" in body)

    hooks_js = [str(h) for h in (frappe.get_hooks("app_include_js") or [])]
    check("ensure_icons.js hooked", any("ensure_icons" in h for h in hooks_js))
    check("ceo_dashboard_kpi.js hooked", any("ceo_dashboard_kpi" in h for h in hooks_js))
    hooks_css = [str(h) for h in (frappe.get_hooks("app_include_css") or [])]
    check("phase7 css hooked", any("phase7_transport_ui" in h for h in hooks_css))

    # ---------- module binding ----------
    check("Module Def exists", bool(frappe.db.exists("Module Def", "Iran Transport")))
    if frappe.db.exists("Module Def", "Iran Transport"):
        module = frappe.get_doc("Module Def", "Iran Transport")
        if module.meta.has_field("app_name"):
            check("Module Def app_name = transport_ir", module.app_name == "transport_ir", str(module.app_name))

    # ---------- workspaces ----------
    expected = {
        "CEO Dashboard": ("tir-dashboard", {"CEO", "System Manager"}),
        "Finance": ("tir-finance", {"Financial Manager", "Finance Supervisor", "Finance User",
                                    "Legal Reviewer", "Treasury User", "Receivables User",
                                    "Document Signer", "System Manager"}),
        "Iran Transport": ("tir-truck", {"Transport Supervisor", "System Manager"}),
        "Transport Purchase": ("tir-buy", {"Transport User - Purchase", "System Manager"}),
        "Transport Sales": ("tir-sell", {"Transport User - Sales", "System Manager"}),
        "Customs": ("tir-customs", {"Customs Officer", "System Manager"}),
    }
    for ws_name, (icon, roles) in expected.items():
        exists = bool(frappe.db.exists("Workspace", ws_name))
        check(f"Workspace {ws_name}", exists)
        if not exists:
            continue
        doc = frappe.get_doc("Workspace", ws_name)
        check(f"{ws_name} icon={icon}", doc.icon == icon, str(doc.icon))
        check(f"{ws_name} public", int(doc.public or 0) == 1)
        check(f"{ws_name} not hidden", int(doc.is_hidden or 0) == 0)
        check(f"{ws_name} roles exact", {r.role for r in doc.roles} == roles,
              str(sorted({r.role for r in doc.roles})))
        check(f"{ws_name} shortcuts", len(doc.shortcuts or []) >= 1)
        check(f"{ws_name} links", len(doc.links or []) >= 3)

    # CEO content must NOT embed native widgets (deliberate design)
    if frappe.db.exists("Workspace", "CEO Dashboard"):
        try:
            blocks = json.loads(frappe.db.get_value("Workspace", "CEO Dashboard", "content") or "[]")
        except Exception:
            blocks = []
        types = {b.get("type") for b in blocks if isinstance(b, dict)}
        check("CEO content has no native number_card blocks", "number_card" not in types, str(sorted(types)))
        check("CEO content has no native chart blocks", "chart" not in types, str(sorted(types)))

    # ---------- KPI documents still present ----------
    check("11 Number Card docs", frappe.db.count("Number Card", {"module": "Iran Transport"}) >= 11)
    check("3 Dashboard Chart docs", frappe.db.count("Dashboard Chart", {"module": "Iran Transport"}) >= 3)

    # ---------- live API ----------
    try:
        from transport_ir.iran_transport.api.ceo_kpi import get_ceo_kpi
        payload = get_ceo_kpi()
        check("api returns dict", isinstance(payload, dict))
        check("api has counts", isinstance(payload.get("counts"), dict))
        check("api has totals", isinstance(payload.get("totals"), dict))
        check("api has charts", isinstance(payload.get("charts"), dict))
        for key in ["in_transit", "pending_transport", "waiting_bijak",
                    "waiting_clearance", "pending_payment", "completed", "total"]:
            check(f"api count key {key}", key in (payload.get("counts") or {}))
        for key in ["tonnage", "profit", "freight", "customs", "clearance"]:
            check(f"api total key {key}", key in (payload.get("totals") or {}))
        for key in ["by_border", "by_factory", "by_customer"]:
            check(f"api chart key {key}", key in (payload.get("charts") or {}))
    except Exception as exc:
        check(f"api get_ceo_kpi callable ({exc})", False)

    # ---------- kanban + scripts + translations ----------
    kb = "Transport Case Workflow Board"
    check("Kanban exists", bool(frappe.db.exists("Kanban Board", kb)))
    if frappe.db.exists("Kanban Board", kb):
        board = frappe.get_doc("Kanban Board", kb)
        if board.meta.has_field("columns"):
            names = {c.column_name for c in (board.columns or [])}
            check("Kanban excludes Draft", "Draft" not in names)
            check("Kanban excludes Cancelled", "Cancelled" not in names)
            check("Kanban has In Transit", "In Transit" in names)

    check("Form Script", bool(frappe.db.exists("Client Script", "Transport Case UX Phase7")))
    check("List Script", bool(frappe.db.exists("Client Script", "Transport Case List UX Phase7")))

    for source, target in [
        ("Transport Waybill", "بارنامه حمل"),
        ("Transport Weighbridge", "باسکول حمل"),
        ("Transport Bijak", "بیجک حمل"),
        ("Transport Clearance", "ترخیص حمل"),
        ("CEO Dashboard", "داشبورد مدیرعامل"),
        ("Iran Transport", "حمل و نقل"),
    ]:
        check(f"fa translation {source}", bool(frappe.db.exists(
            "Translation", {"language": "fa", "source_text": source, "translated_text": target})))

    # ---------- guarantee: phase 6 untouched ----------
    meta = frappe.get_meta("Transport Case")
    pd = meta.get_field("posting_date")
    check("posting_date still exists (untouched)", bool(pd))
    check("workflow still active", bool(frappe.db.get_value(
        "Workflow", "Transport Case Workflow", "is_active")))

    print(f"\nPassed: {len(passed)} | Failed: {len(failed)}")
    if failed:
        for item in failed:
            print("  -", item)
        frappe.throw("Phase 7 verification failed")
    print("🎉 Phase 7 (v4) checks passed")
EOF

# =============================================================================
step "12) Pre-migrate integrity"
python3 << 'PYEOF'
import ast, json, os, sys
mod = os.environ["MOD"]; pkg = os.environ["PKG"]

for py in [os.path.join(mod, "api", "ceo_kpi.py"),
           os.path.join(mod, "setup_ui_phase7.py"),
           os.path.join(mod, "verify_phase7.py")]:
    ast.parse(open(py, encoding="utf-8").read())
    print("python OK:", py)

files = [os.path.join(mod, f"workspace/{f}/{f}.json") for f in
         ["ceo_dashboard", "finance", "iran_transport",
          "transport_purchase", "transport_sales", "customs"]]
files += [os.path.join(pkg, "fixtures/translation.json"),
          os.path.join(pkg, "fixtures/client_script.json")]

bad = []
for path in files:
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception as exc:
        bad.append(f"{path}: {exc}")
        continue
    rows = data if isinstance(data, list) else [data]
    for i, row in enumerate(rows):
        if not isinstance(row, dict) or not row.get("doctype") or not row.get("name"):
            bad.append(f"{path}[{i}]")

if bad:
    print("PRE-MIGRATE FAILED:")
    for b in bad:
        print(" -", b)
    sys.exit(1)
print("pre-migrate checks OK")
PYEOF

# =============================================================================
step "13) Build + migrate + provision + verify"
bench build --app "$APP" || warn "bench build failed — rerun manually"
bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache
bench --site "$SITE_NAME" execute transport_ir.iran_transport.setup_ui_phase7.setup_ui_phase7
bench --site "$SITE_NAME" clear-cache
bench --site "$SITE_NAME" execute transport_ir.iran_transport.verify_phase7.verify_phase7

for f in "js/ensure_icons.js" "js/ceo_dashboard_kpi.js" "icons/transport_sprite.svg" "css/phase7_transport_ui.css"; do
  if [[ -e "sites/assets/${APP}/${f}" ]]; then
    log "asset OK: /assets/${APP}/${f}"
  else
    warn "asset MISSING: /assets/${APP}/${f} — run: bench build --app ${APP} --force"
  fi
done

# =============================================================================
step "14) Git commit + BACKLOG note"
cd "${BENCH_DIR}/apps/${APP}"
grep -q "RTL chart legend" BACKLOG.md 2>/dev/null || cat >> BACKLOG.md << 'EOF'

## محدودیت‌های شناخته‌شده بالادستی (Out of Scope)
- نمودارهای ماژول استاندارد Projects در زبان fa، legend فارسی را با حروف
  جداسازی‌شده رندر می‌کنند. باگ کتابخانه نمودار فرپ (RTL shaping) است،
  نه اپ transport_ir. نمودارهای فاز ۷ ما با CSS رسم می‌شوند و این مشکل را ندارند.
- ویجت‌های بومی Number Card / Dashboard Chart در Workspace این نصب رندر نمی‌شوند.
  اسناد آن‌ها در دیتابیس و fixtures حفظ شده‌اند؛ نمایش از طریق پنل اختصاصی
  ceo_dashboard_kpi.js انجام می‌شود. اگر در نسخه‌های بعدی فرپ اصلاح شد،
  می‌توان بلوک‌ها را دوباره به content اضافه کرد.
- realtime (socket.io روی پورت ۹۰۰۰) در این محیط در دسترس نیست؛
  اعلان‌های لحظه‌ای تا رفع آن کار نمی‌کنند. ربطی به فاز ۷ ندارد.
EOF
git add -A
git commit -m "phase 7 v4: fix workspace route detection, server-side KPI api, guaranteed CEO panel" || warn "nothing to commit"

step "DONE"
cat <<FINAL

${GREEN}═══════════════════════════════════════════════════════════════${NC}
${GREEN}  PHASE 7 v4 — علت ریشه‌ای رفع شد${NC}
${GREEN}═══════════════════════════════════════════════════════════════${NC}

علت واقعی خالی ماندن داشبورد:
  frappe.get_route() روی Workspace برابر ["Workspaces","CEO Dashboard"] است،
  نه ["ceo-dashboard"]. شرط نسخه ۳ همیشه false می‌شد و پنل را پاک می‌کرد.

رفع‌شده در v4:
  ✅ تشخیص صحیح Workspace (+ fallback از روی URL)
  ✅ اتصال router به‌صورت تأخیری + watchdog هر ۱.۵ ثانیه
  ✅ تلاش مجدد تا پیدا شدن محل تزریق در DOM
  ✅ API سروری get_ceo_kpi (یک درخواست، تجمیع SQL، کنترل نقش)
  ✅ نمودارها با CSS (بدون باگ RTL)
  ✅ کاشی‌ها کلیک‌پذیر → لیست فیلترشده

دست‌نخورده:
  ⏭ posting_date / Workflow / Permission / Validation / فازهای ۲ تا ۶

${YELLOW}─────────── چک‌لیست مرورگر ───────────${NC}

  ۱) Logout → Incognito → Ctrl+Shift+R
  ۲) Console باید نشان دهد:
       [transport_ir][p7 v4] desk kpi module loaded
       [transport_ir][p7 v4] router bound
       [transport_ir][p7 v4] KPI panel rendered
  ۳) /app/ceo-dashboard → کاشی‌های عددی + سه نمودار میله‌ای
  ۴) کلیک روی «بارهای در حال حمل» → لیست فیلترشده باز شود
  ۵) سایدبار: شش آیکون متفاوت
  ۶) فرم Transport Case: نوار پیشرفت + مسئول

اگر باز هم پنل نیامد، فقط این یک خط را در Console بزنید و نتیجه را بفرستید:
  frappe.get_route()

FINAL
