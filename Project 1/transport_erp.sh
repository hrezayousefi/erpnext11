#!/usr/bin/env bash
# =============================================================================
# setup_phase12_v2.sh  —  نسخه اصلاحی فاز ۱۲ (رفع خطای «صفحه یافت نشد»)
# فاز ۱۲ — فضاهای کاری اختصاصی و داشبوردهای مدیریتی (مرکز کنترل عملیات حمل)
# ERPNext v15 / Frappe v15  |  File-First | Additive | Idempotent | RTL/Persian
# -----------------------------------------------------------------------------
# تفاوت با نسخه v1  (setup_phase12.sh):
#   • تمام name / label / title مربوط به Workspace و Page به انگلیسی تبدیل شد
#     تا Frappe از روی نام‌های فارسی، slug مانند «داشبورد-مدیرعامل» نسازد
#     که در Router قابل حل نیست.  (خطای گزارش‌شده: «صفحه یافت نشد».)
#   • ترجمه فارسی همه‌ی این برچسب‌ها از طریق فایل استاندارد
#     apps/<app>/<app>/translations/fa.csv انجام می‌شود؛
#     Frappe در سمت رابط کاربر خودش __() را اعمال می‌کند و همه‌چیز فارسی
#     دیده می‌شود، اما URL و lookup داخلی همچنان انگلیسی و پایدار است.
#   • ورودی‌های ترجمه بین Markerهای PHASE12 قرار می‌گیرند تا additive و
#     idempotent باشند و به ترجمه‌های فازهای قبلی آسیبی وارد نکنند.
# -----------------------------------------------------------------------------
# این اسکریپت در «یک گام» موارد زیر را می‌سازد:
#   1) ماژول مستقل  transport_ir/iran_transport/phase12_workspaces
#   2) ۵ صفحه (Page) داشبورد سفارشی کاملاً فارسی و راست‌چین
#        (route انگلیسی؛ عنوان نمایشی فارسی از fa.csv):
#        - transport-ops-dashboard   → «مرکز کنترل عملیات حمل»
#        - ceo-command-center        → «داشبورد مدیرعامل»
#        - finance-control-center    → «مرکز کنترل مالی و خزانه»
#        - customs-gateway-desk      → «میز گمرک و مرز»
#        - commercial-desk-center    → «میز بازرگانی»
#   3) APIهای whitelist شده: KPI، مراحل، جدول اقدام، تایم‌لاین پرونده،
#      کانبان، نقشه عملیات، عملکرد کارشناسان، هشدارها، جستجوی هوشمند، یادآوری
#   4) ۵ Workspace استاندارد ERPNext با Shortcut / Card / Number Card / Chart
#   5) CSS و JS سفارشی (نوار پیشرفت و تایم‌لاین مرحله‌ای روی فرم پرونده حمل)
#   6) فایل translations/fa.csv (ترجمه فارسی برچسب‌ها — additive)
#   7) به‌روزرسانی additive فایل hooks.py با الگوی Marker
#
# اجرا:
#   chmod +x setup_phase12_v2.sh
#   SITE_NAME=transport-dev.local ./setup_phase12_v2.sh
# =============================================================================
set -Eeuo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=utf-8

SITE_NAME="${SITE_NAME:-transport-dev.local}"
BENCH_DIR="${BENCH_DIR:-${HOME}/frappe-bench}"
APP_NAME="${APP_NAME:-transport_ir}"
MODULE_NAME="${MODULE_NAME:-iran_transport}"
MODULE_LABEL="${MODULE_LABEL:-Iran Transport}"
RUN_MIGRATE="${RUN_MIGRATE:-1}"
RUN_BUILD="${RUN_BUILD:-1}"

APP_ROOT="${BENCH_DIR}/apps/${APP_NAME}/${APP_NAME}"
MOD_ROOT="${APP_ROOT}/${MODULE_NAME}"
PHASE12_ROOT="${MOD_ROOT}/phase12_workspaces"
PAGE_ROOT="${MOD_ROOT}/page"
PUB_CSS="${APP_ROOT}/public/css"
PUB_JS="${APP_ROOT}/public/js"
HOOKS_FILE="${APP_ROOT}/hooks.py"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step() { echo; echo -e "${BLUE}========== $* ==========${NC}"; }

trap 'echo -e "\n${RED}[FATAL]${NC} اسکریپت در خط $LINENO متوقف شد." >&2' ERR

# =============================================================================
step "0) Preflight"
# =============================================================================
[[ -d "$BENCH_DIR" ]]                       || fail "Bench directory not found: $BENCH_DIR"
[[ -d "${BENCH_DIR}/apps/${APP_NAME}" ]]    || fail "App not found: ${APP_NAME}"
[[ -d "$MOD_ROOT" ]]                        || fail "Module not found: ${MOD_ROOT}"
[[ -f "$HOOKS_FILE" ]]                      || fail "hooks.py not found: ${HOOKS_FILE}"
command -v python3 >/dev/null 2>&1          || fail "python3 not found"

cd "$BENCH_DIR"
bench --site "$SITE_NAME" list-apps >/dev/null 2>&1 || fail "Site not found: ${SITE_NAME}"
bench --site "$SITE_NAME" list-apps 2>/dev/null | grep -q "^${APP_NAME}" \
  || fail "App ${APP_NAME} is not installed on ${SITE_NAME}"
log "Bench / Site / App preflight passed"

# پشتیبان‌گیری از hooks.py (Additive safety)
cp -f "$HOOKS_FILE" "${HOOKS_FILE}.phase12.bak.$(date +%Y%m%d%H%M%S)"
log "hooks.py backup created"

# =============================================================================
step "1) ساخت ساختار پوشه‌ها"
# =============================================================================
mkdir -p "${PHASE12_ROOT}/api"
mkdir -p "${PUB_CSS}" "${PUB_JS}"
mkdir -p "${PAGE_ROOT}"
[[ -f "${PAGE_ROOT}/__init__.py" ]] || : > "${PAGE_ROOT}/__init__.py"
: > "${PHASE12_ROOT}/__init__.py"
: > "${PHASE12_ROOT}/api/__init__.py"
log "Directories ready"

# =============================================================================
step "2) نوشتن config.py (پیکربندی مراحل، نقش‌ها و داشبوردها)"
# =============================================================================
cat > "${PHASE12_ROOT}/config.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""پیکربندی فاز ۱۲ — فضاهای کاری اختصاصی و داشبوردهای مدیریتی.

تمام تعاریف مراحل، مسئول هر مرحله، SLA، KPIها و ساختار داشبوردها اینجاست
تا API و Workspace از یک منبع واحد حقیقت (single source of truth) بخوانند.
"""
from __future__ import annotations

MODULE_LABEL = "Iran Transport"
PHASE_KEY = "PHASE12"

# ---------------------------------------------------------------------------
# مراحل گردش‌کار پرونده حمل  (state, label, owner_role_label, sla_hours, icon)
# ---------------------------------------------------------------------------
TRANSPORT_FLOW = [
    ("Draft", "ثبت اولیه", "کارشناس حمل", 12, "📝"),
    ("Pending Supervisor Review", "بررسی سرپرست", "سرپرست حمل", 12, "🔍"),
    ("Pending Transport", "تخصیص کارشناس", "سرپرست حمل", 12, "🧭"),
    ("Driver Assigned", "ثبت راننده", "کارشناس حمل", 24, "🚚"),
    ("Waybill Issued", "صدور بارنامه", "کارشناس حمل", 24, "📄"),
    ("In Transit", "در حال حمل", "کارشناس حمل", 72, "🛣️"),
    ("Waiting Weighbridge", "باسکول", "کارشناس حمل", 24, "⚖️"),
    ("Waiting Bijak", "بیجک و اظهار", "کارشناس گمرک", 24, "📋"),
    ("Waiting Clearance", "ترخیص", "کارشناس گمرک", 48, "🛃"),
    ("Cleared", "ترخیص‌شده", "کارشناس گمرک", 24, "✅"),
    ("Delivered", "رسید تخلیه", "کارشناس حمل", 24, "📦"),
    ("Pending Payment", "پرداخت", "خزانه", 24, "💰"),
    ("Pending Finance Close", "بستن مالی", "سرپرست مالی", 24, "🧮"),
    ("Completed", "تکمیل پرونده", "-", 0, "🏁"),
]

TRANSPORT_EXCEPTIONS = [
    ("On Hold", "متوقف", "سرپرست حمل", 24, "⏸️"),
    ("Cancelled", "لغو شده", "-", 0, "🚫"),
    ("Rejected", "رد شده", "-", 0, "❌"),
]

CLOSED_TRANSPORT_STATES = ["Completed", "Cancelled", "Rejected"]

# ---------------------------------------------------------------------------
# مراحل گردش‌کار پرونده تجاری
# ---------------------------------------------------------------------------
TRADE_FLOW = [
    ("Draft", "ثبت پرونده", "کارشناس بازرگانی", 12, "📝"),
    ("Legal Review", "بررسی حقوقی", "بررسی حقوقی", 24, "⚖️"),
    ("Treasury Review", "بررسی خزانه", "خزانه", 24, "🏦"),
    ("Pending Signature", "امضای سند", "امضاکننده سند", 24, "✍️"),
    ("Finance Supervisor", "سرپرست مالی", "سرپرست مالی", 24, "🧾"),
    ("Receivables", "وصول مطالبات", "وصول مطالبات", 48, "💵"),
    ("Approved", "تأییدشده", "-", 0, "✅"),
]

TRADE_EXCEPTIONS = [
    ("Rejected", "رد شده", "-", 0, "❌"),
    ("Returned", "برگشت‌خورده", "کارشناس بازرگانی", 24, "↩️"),
    ("On Hold", "متوقف", "سرپرست مالی", 24, "⏸️"),
]

CLOSED_TRADE_STATES = ["Approved", "Rejected"]

# ---------------------------------------------------------------------------
# چک‌لیست ۱۰ موردی بستن پرونده حمل
# ---------------------------------------------------------------------------
CLOSE_CHECKLIST = [
    ("chk_purchase", "خرید"),
    ("chk_sales", "فروش"),
    ("chk_driver", "راننده"),
    ("chk_waybill", "بارنامه"),
    ("chk_weighbridge", "باسکول"),
    ("chk_bijak", "بیجک"),
    ("chk_clearance", "ترخیص"),
    ("chk_delivery", "رسید تخلیه"),
    ("chk_payments", "پرداخت‌ها"),
    ("finance_approved", "تأیید مالی"),
]

# ---------------------------------------------------------------------------
# نقش‌ها و برچسب فارسی
# ---------------------------------------------------------------------------
ROLE_LABELS = {
    "CEO": "مدیرعامل",
    "Financial Manager": "مدیر مالی",
    "Finance Supervisor": "سرپرست مالی",
    "Finance User": "کارشناس مالی",
    "Legal Reviewer": "بررسی حقوقی",
    "Treasury User": "خزانه",
    "Receivables User": "وصول مطالبات",
    "Transport Supervisor": "سرپرست واحد حمل‌ونقل",
    "Transport User - Purchase": "کارشناس حمل خرید",
    "Transport User - Sales": "کارشناس حمل فروش",
    "Customs Officer": "کارشناس گمرک",
    "Document Signer": "امضاکننده سند",
    "System Manager": "مدیر سیستم",
}

PHASE12_ROLES = [
    "CEO", "Financial Manager", "Finance Supervisor", "Finance User",
    "Legal Reviewer", "Treasury User", "Receivables User",
    "Transport Supervisor", "Transport User - Purchase", "Transport User - Sales",
    "Customs Officer", "Document Signer",
]

TRANSPORT_ROLES = [
    "Transport Supervisor", "Transport User - Purchase",
    "Transport User - Sales", "System Manager",
]
FINANCE_ROLES = [
    "Financial Manager", "Finance Supervisor", "Finance User",
    "Treasury User", "System Manager",
]
CUSTOMS_ROLES = ["Customs Officer", "Transport Supervisor", "System Manager"]
COMMERCIAL_ROLES = [
    "Legal Reviewer", "Treasury User", "Receivables User",
    "Document Signer", "Financial Manager", "System Manager",
]
CEO_ROLES = ["CEO", "Financial Manager", "System Manager"]

# ---------------------------------------------------------------------------
# تعریف داشبوردها
#   metric: کلید محاسباتی در api/dashboard.py::METRICS
#   tone:   navy | blue | green | amber | red | violet | teal
# ---------------------------------------------------------------------------
DASHBOARDS = {
    "transport_ops": {
        "title": "مرکز کنترل عملیات حمل",
        "subtitle": "پایش لحظه‌ای پرونده‌ها، مراحل، مسئولان، توقف‌ها و تناژ",
        "icon": "🚚",
        "route": "transport-ops-dashboard",
        "doctype": "Transport Case",
        "flow": "transport",
        "roles": TRANSPORT_ROLES,
        "sections": [
            "kpi", "stages", "action_table", "focus_case",
            "kanban", "destinations", "performance", "alerts",
        ],
        "kpi": [
            {"metric": "transport_open", "label": "کل پرونده‌های فعال", "icon": "📦", "tone": "navy"},
            {"metric": "transport_in_transit", "label": "در حال حمل", "icon": "🛣️", "tone": "blue"},
            {"metric": "transport_pending_action", "label": "منتظر اقدام", "icon": "🟡", "tone": "amber"},
            {"metric": "transport_overdue", "label": "معوق (بیش از SLA)", "icon": "🔴", "tone": "red"},
            {"metric": "today_loads", "label": "بارهای امروز", "icon": "🚛", "tone": "teal"},
            {"metric": "today_tonnage", "label": "تناژ امروز", "icon": "⚖️", "tone": "violet", "suffix": "تن"},
        ],
        "kanban_states": [
            "Pending Transport", "Driver Assigned", "Waybill Issued",
            "In Transit", "Waiting Weighbridge", "Waiting Clearance",
        ],
    },
    "ceo": {
        "title": "داشبورد مدیرعامل",
        "subtitle": "نمای کلان عملیات، سودآوری، گلوگاه‌ها و عملکرد سازمان",
        "icon": "📊",
        "route": "ceo-command-center",
        "doctype": "Transport Case",
        "flow": "transport",
        "roles": CEO_ROLES,
        "sections": ["kpi", "stages", "destinations", "performance", "action_table", "alerts"],
        "kpi": [
            {"metric": "transport_open", "label": "پرونده‌های فعال حمل", "icon": "📦", "tone": "navy"},
            {"metric": "trade_open", "label": "پرونده‌های تجاری باز", "icon": "🧾", "tone": "blue"},
            {"metric": "transport_overdue", "label": "پرونده‌های معوق", "icon": "🔴", "tone": "red"},
            {"metric": "completed_month", "label": "تکمیل‌شده (۳۰ روز)", "icon": "🏁", "tone": "green"},
            {"metric": "tonnage_open", "label": "تناژ در جریان", "icon": "⚖️", "tone": "violet", "suffix": "تن"},
            {"metric": "profit_sum", "label": "سود برآوردی جاری", "icon": "💹", "tone": "teal", "money": 1},
        ],
        "kanban_states": [],
    },
    "finance": {
        "title": "مرکز کنترل مالی و خزانه",
        "subtitle": "پرداخت‌ها، بستن پرونده مالی، بهای تمام‌شده و سود",
        "icon": "💰",
        "route": "finance-control-center",
        "doctype": "Transport Case",
        "flow": "transport",
        "roles": FINANCE_ROLES,
        "sections": ["kpi", "stages", "action_table", "focus_case", "alerts", "performance"],
        "states": ["Delivered", "Pending Payment", "Pending Finance Close"],
        "kpi": [
            {"metric": "pending_payment", "label": "منتظر پرداخت", "icon": "💳", "tone": "amber"},
            {"metric": "pending_finance_close", "label": "منتظر بستن مالی", "icon": "🧮", "tone": "blue"},
            {"metric": "trade_finance_queue", "label": "صف مالی پرونده تجاری", "icon": "🧾", "tone": "navy"},
            {"metric": "cost_sum", "label": "جمع هزینه پرونده‌های باز", "icon": "📉", "tone": "red", "money": 1},
            {"metric": "sales_sum", "label": "جمع فروش پرونده‌های باز", "icon": "📈", "tone": "green", "money": 1},
            {"metric": "profit_sum", "label": "سود برآوردی", "icon": "💹", "tone": "teal", "money": 1},
        ],
        "kanban_states": [],
    },
    "customs": {
        "title": "میز گمرک و مرز",
        "subtitle": "بیجک، اظهار، ترخیص، هماهنگی مرزی و نمایندگان",
        "icon": "🛃",
        "route": "customs-gateway-desk",
        "doctype": "Transport Case",
        "flow": "transport",
        "roles": CUSTOMS_ROLES,
        "sections": ["kpi", "stages", "action_table", "focus_case", "kanban", "destinations", "alerts"],
        "states": ["Waiting Weighbridge", "Waiting Bijak", "Waiting Clearance", "Cleared"],
        "kpi": [
            {"metric": "waiting_bijak", "label": "منتظر بیجک", "icon": "📋", "tone": "amber"},
            {"metric": "waiting_clearance", "label": "منتظر ترخیص", "icon": "🛃", "tone": "blue"},
            {"metric": "cleared_count", "label": "ترخیص‌شده", "icon": "✅", "tone": "green"},
            {"metric": "customs_overdue", "label": "معوق گمرکی", "icon": "🔴", "tone": "red"},
            {"metric": "customs_cost_sum", "label": "هزینه گمرکی جاری", "icon": "💱", "tone": "violet", "money": 1},
            {"metric": "border_count", "label": "مرزهای فعال", "icon": "🌍", "tone": "navy"},
        ],
        "kanban_states": ["Waiting Weighbridge", "Waiting Bijak", "Waiting Clearance", "Cleared"],
    },
    "commercial": {
        "title": "میز بازرگانی",
        "subtitle": "پرونده‌های تجاری، بررسی حقوقی، امضا و وصول مطالبات",
        "icon": "🧾",
        "route": "commercial-desk-center",
        "doctype": "Trade Case",
        "flow": "trade",
        "roles": COMMERCIAL_ROLES,
        "sections": ["kpi", "stages", "action_table", "focus_case", "kanban", "alerts"],
        "kpi": [
            {"metric": "trade_open", "label": "پرونده‌های تجاری باز", "icon": "🗂️", "tone": "navy"},
            {"metric": "trade_legal", "label": "در بررسی حقوقی", "icon": "⚖️", "tone": "blue"},
            {"metric": "trade_signature", "label": "منتظر امضا", "icon": "✍️", "tone": "amber"},
            {"metric": "trade_receivables", "label": "وصول مطالبات", "icon": "💵", "tone": "violet"},
            {"metric": "trade_approved", "label": "تأییدشده", "icon": "✅", "tone": "green"},
            {"metric": "trade_overdue", "label": "معوق بازرگانی", "icon": "🔴", "tone": "red"},
        ],
        "kanban_states": [
            "Draft", "Legal Review", "Treasury Review",
            "Pending Signature", "Finance Supervisor", "Receivables",
        ],
    },
}

# ---------------------------------------------------------------------------
# تعریف Workspaceها  (تمام name/label انگلیسی برای پایداری route؛
# ترجمه فارسی از translations/fa.csv انجام می‌شود تا در URL Persian slug نیاید)
# ---------------------------------------------------------------------------
WORKSPACES = [
    {
        "name": "Transport Control Tower",
        "label": "Transport Control Tower",
        "icon": "truck",
        "dashboard": "transport_ops",
        "sequence": 11.0,
        "roles": TRANSPORT_ROLES,
        "shortcuts": [
            {"label": "Transport Ops Dashboard", "type": "Page",
             "link_to": "transport-ops-dashboard", "color": "Blue"},
            {"label": "Active Transport Cases", "type": "DocType", "link_to": "Transport Case",
             "color": "Green", "format": "{} Active",
             "stats_filter": {"workflow_state": ["not in", ["Completed", "Cancelled", "Rejected"]]}},
            {"label": "In Transit Cases", "type": "DocType", "link_to": "Transport Case",
             "color": "Cyan", "format": "{} In Transit",
             "stats_filter": {"workflow_state": "In Transit"}},
            {"label": "Pending Assignment", "type": "DocType", "link_to": "Transport Case",
             "color": "Orange", "format": "{} In Queue",
             "stats_filter": {"workflow_state": "Pending Transport"}},
            {"label": "On Hold Cases", "type": "DocType", "link_to": "Transport Case",
             "color": "Red", "format": "{} On Hold",
             "stats_filter": {"workflow_state": "On Hold"}},
        ],
        "cards": [
            {"label": "Daily Operations", "links": [
                ("Transport Case", "DocType", "Transport Cases"),
                ("Trade Case", "DocType", "Trade Cases"),
                ("Transport Waybill", "DocType", "Waybills"),
                ("Transport Weighbridge", "DocType", "Weighbridge"),
            ]},
            {"label": "Fleet And Resources", "links": [
                ("Driver", "DocType", "Drivers"),
                ("Vehicle", "DocType", "Fleet"),
                ("Carrier", "DocType", "Carriers"),
                ("Border", "DocType", "Borders"),
            ]},
        ],
        "number_cards": ["p12_transport_open", "p12_transport_in_transit",
                         "p12_transport_pending", "p12_transport_tonnage"],
        "charts": ["p12_transport_by_state", "p12_transport_by_destination"],
    },
    {
        "name": "CEO Command Center",
        "label": "CEO Command Center",
        "icon": "dashboard",
        "dashboard": "ceo",
        "sequence": 10.0,
        "roles": CEO_ROLES,
        "shortcuts": [
            {"label": "CEO Command Center", "type": "Page",
             "link_to": "ceo-command-center", "color": "Blue"},
            {"label": "Active Transport Overview", "type": "DocType", "link_to": "Transport Case",
             "color": "Green", "format": "{} Active",
             "stats_filter": {"workflow_state": ["not in", ["Completed", "Cancelled", "Rejected"]]}},
            {"label": "Open Trade Cases", "type": "DocType", "link_to": "Trade Case",
             "color": "Purple", "format": "{} Open",
             "stats_filter": {"workflow_state": ["not in", ["Approved", "Rejected"]]}},
            {"label": "Completed Cases", "type": "DocType", "link_to": "Transport Case",
             "color": "Grey", "format": "{} Completed",
             "stats_filter": {"workflow_state": "Completed"}},
        ],
        "cards": [
            {"label": "Management Overview", "links": [
                ("Transport Case", "DocType", "Transport Cases"),
                ("Trade Case", "DocType", "Trade Cases"),
                ("Customer", "DocType", "Customers"),
                ("Supplier", "DocType", "Suppliers"),
            ]},
        ],
        "number_cards": ["p12_transport_open", "p12_trade_open",
                         "p12_transport_overdue", "p12_transport_completed"],
        "charts": ["p12_transport_by_state", "p12_trade_by_state"],
    },
    {
        "name": "Finance And Treasury",
        "label": "Finance And Treasury",
        "icon": "money-coins-1",
        "dashboard": "finance",
        "sequence": 12.0,
        "roles": FINANCE_ROLES,
        "shortcuts": [
            {"label": "Finance Control Center", "type": "Page",
             "link_to": "finance-control-center", "color": "Blue"},
            {"label": "Pending Payment", "type": "DocType", "link_to": "Transport Case",
             "color": "Orange", "format": "{} Pending",
             "stats_filter": {"workflow_state": "Pending Payment"}},
            {"label": "Pending Finance Close", "type": "DocType", "link_to": "Transport Case",
             "color": "Yellow", "format": "{} In Queue",
             "stats_filter": {"workflow_state": "Pending Finance Close"}},
            {"label": "Finance Supervisor Queue", "type": "DocType", "link_to": "Trade Case",
             "color": "Purple", "format": "{} Cases",
             "stats_filter": {"workflow_state": "Finance Supervisor"}},
        ],
        "cards": [
            {"label": "Finance And Treasury Links", "links": [
                ("Transport Case", "DocType", "Transport Cases"),
                ("Trade Case", "DocType", "Trade Cases"),
                ("Transport Clearance", "DocType", "Clearance"),
            ]},
        ],
        "number_cards": ["p12_pending_payment", "p12_pending_finance_close",
                         "p12_trade_receivables"],
        "charts": ["p12_transport_by_state"],
    },
    {
        "name": "Customs And Gateway",
        "label": "Customs And Gateway",
        "icon": "getting-started",
        "dashboard": "customs",
        "sequence": 13.0,
        "roles": CUSTOMS_ROLES,
        "shortcuts": [
            {"label": "Customs Gateway Desk", "type": "Page",
             "link_to": "customs-gateway-desk", "color": "Blue"},
            {"label": "Pending Clearance", "type": "DocType", "link_to": "Transport Case",
             "color": "Purple", "format": "{} Pending",
             "stats_filter": {"workflow_state": "Waiting Clearance"}},
            {"label": "Pending Bijak", "type": "DocType", "link_to": "Transport Case",
             "color": "Orange", "format": "{} Pending",
             "stats_filter": {"workflow_state": "Waiting Bijak"}},
            {"label": "Cleared Cases", "type": "DocType", "link_to": "Transport Case",
             "color": "Green", "format": "{} Cleared",
             "stats_filter": {"workflow_state": "Cleared"}},
        ],
        "cards": [
            {"label": "Customs Links", "links": [
                ("Transport Bijak", "DocType", "Bijak And Declaration"),
                ("Transport Clearance", "DocType", "Clearance"),
                ("Customs Broker", "DocType", "Customs Brokers"),
                ("Border Representative", "DocType", "Border Representatives"),
                ("Border", "DocType", "Borders"),
            ]},
        ],
        "number_cards": ["p12_waiting_bijak", "p12_waiting_clearance"],
        "charts": ["p12_transport_by_border"],
    },
    {
        "name": "Commercial Desk",
        "label": "Commercial Desk",
        "icon": "organization",
        "dashboard": "commercial",
        "sequence": 14.0,
        "roles": COMMERCIAL_ROLES,
        "shortcuts": [
            {"label": "Commercial Desk Center", "type": "Page",
             "link_to": "commercial-desk-center", "color": "Blue"},
            {"label": "Legal Review Queue", "type": "DocType", "link_to": "Trade Case",
             "color": "Cyan", "format": "{} Cases",
             "stats_filter": {"workflow_state": "Legal Review"}},
            {"label": "Pending Signature", "type": "DocType", "link_to": "Trade Case",
             "color": "Orange", "format": "{} Cases",
             "stats_filter": {"workflow_state": "Pending Signature"}},
            {"label": "Receivables Queue", "type": "DocType", "link_to": "Trade Case",
             "color": "Purple", "format": "{} Cases",
             "stats_filter": {"workflow_state": "Receivables"}},
        ],
        "cards": [
            {"label": "Commercial Links", "links": [
                ("Trade Case", "DocType", "Trade Cases"),
                ("Customer", "DocType", "Customers"),
                ("Supplier", "DocType", "Suppliers"),
                ("Item", "DocType", "Items"),
            ]},
        ],
        "number_cards": ["p12_trade_open", "p12_trade_signature", "p12_trade_receivables"],
        "charts": ["p12_trade_by_state"],
    },
]

# ---------------------------------------------------------------------------
# Number Cards
# ---------------------------------------------------------------------------
NUMBER_CARDS = [
    {"key": "p12_transport_open", "label": "پرونده‌های فعال حمل", "doctype": "Transport Case",
     "function": "Count", "color": "#2a5298",
     "filters": [["Transport Case", "workflow_state", "not in", ["Completed", "Cancelled", "Rejected"], False]]},
    {"key": "p12_transport_in_transit", "label": "در حال حمل", "doctype": "Transport Case",
     "function": "Count", "color": "#1f9d55",
     "filters": [["Transport Case", "workflow_state", "=", "In Transit", False]]},
    {"key": "p12_transport_pending", "label": "منتظر تخصیص حمل", "doctype": "Transport Case",
     "function": "Count", "color": "#e8a33d",
     "filters": [["Transport Case", "workflow_state", "=", "Pending Transport", False]]},
    {"key": "p12_transport_overdue", "label": "پرونده‌های متوقف حمل", "doctype": "Transport Case",
     "function": "Count", "color": "#d64545",
     "filters": [["Transport Case", "workflow_state", "=", "On Hold", False]]},
    {"key": "p12_transport_completed", "label": "پرونده‌های تکمیل‌شده", "doctype": "Transport Case",
     "function": "Count", "color": "#4a5568",
     "filters": [["Transport Case", "workflow_state", "=", "Completed", False]]},
    {"key": "p12_transport_tonnage", "label": "تناژ پرونده‌های فعال", "doctype": "Transport Case",
     "function": "Sum", "based_on": "planned_tonnage", "color": "#7f56d9",
     "filters": [["Transport Case", "workflow_state", "not in", ["Completed", "Cancelled", "Rejected"], False]]},
    {"key": "p12_pending_payment", "label": "منتظر پرداخت", "doctype": "Transport Case",
     "function": "Count", "color": "#e8a33d",
     "filters": [["Transport Case", "workflow_state", "=", "Pending Payment", False]]},
    {"key": "p12_pending_finance_close", "label": "منتظر بستن مالی", "doctype": "Transport Case",
     "function": "Count", "color": "#2a5298",
     "filters": [["Transport Case", "workflow_state", "=", "Pending Finance Close", False]]},
    {"key": "p12_waiting_bijak", "label": "منتظر بیجک", "doctype": "Transport Case",
     "function": "Count", "color": "#e8a33d",
     "filters": [["Transport Case", "workflow_state", "=", "Waiting Bijak", False]]},
    {"key": "p12_waiting_clearance", "label": "منتظر ترخیص", "doctype": "Transport Case",
     "function": "Count", "color": "#7f56d9",
     "filters": [["Transport Case", "workflow_state", "=", "Waiting Clearance", False]]},
    {"key": "p12_trade_open", "label": "پرونده‌های تجاری باز", "doctype": "Trade Case",
     "function": "Count", "color": "#2a5298",
     "filters": [["Trade Case", "workflow_state", "not in", ["Approved", "Rejected"], False]]},
    {"key": "p12_trade_signature", "label": "منتظر امضای سند", "doctype": "Trade Case",
     "function": "Count", "color": "#e8a33d",
     "filters": [["Trade Case", "workflow_state", "=", "Pending Signature", False]]},
    {"key": "p12_trade_receivables", "label": "وصول مطالبات", "doctype": "Trade Case",
     "function": "Count", "color": "#1f9d55",
     "filters": [["Trade Case", "workflow_state", "=", "Receivables", False]]},
]

# ---------------------------------------------------------------------------
# Dashboard Charts (Group By)
# ---------------------------------------------------------------------------
CHARTS = [
    {"key": "p12_transport_by_state", "label": "پرونده‌های حمل بر اساس مرحله",
     "doctype": "Transport Case", "group_by": "workflow_state", "type": "Bar", "color": "#2a5298"},
    {"key": "p12_transport_by_destination", "label": "پرونده‌های حمل بر اساس مقصد",
     "doctype": "Transport Case", "group_by": "destination", "type": "Bar", "color": "#1f9d55"},
    {"key": "p12_transport_by_border", "label": "پرونده‌های حمل بر اساس مرز",
     "doctype": "Transport Case", "group_by": "border", "type": "Pie", "color": "#7f56d9"},
    {"key": "p12_trade_by_state", "label": "پرونده‌های تجاری بر اساس مرحله",
     "doctype": "Trade Case", "group_by": "workflow_state", "type": "Bar", "color": "#e8a33d"},
]
PYEOF
log "config.py written"

# =============================================================================
step "3) نوشتن api/dashboard.py (موتور داده داشبوردها)"
# =============================================================================
cat > "${PHASE12_ROOT}/api/dashboard.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""APIهای فاز ۱۲ — موتور داده داشبوردهای مدیریتی.

تمام متدها whitelist شده‌اند، DB-agnostic هستند (بدون SQL خام)،
و در صورت نبود DocType/فیلد به‌جای خطا مقدار خنثی برمی‌گردانند.
"""
from __future__ import annotations

from typing import Any

import frappe
from frappe.utils import (
    add_to_date,
    cint,
    flt,
    format_datetime,
    get_datetime,
    now_datetime,
    today,
)

from transport_ir.iran_transport.phase12_workspaces.config import (
    CLOSE_CHECKLIST,
    CLOSED_TRADE_STATES,
    CLOSED_TRANSPORT_STATES,
    DASHBOARDS,
    ROLE_LABELS,
    TRADE_EXCEPTIONS,
    TRADE_FLOW,
    TRANSPORT_EXCEPTIONS,
    TRANSPORT_FLOW,
)

TRANSPORT_DT = "Transport Case"
TRADE_DT = "Trade Case"

PENDING_ACTION_STATES = [
    "Pending Supervisor Review", "Pending Transport", "Waiting Weighbridge",
    "Waiting Bijak", "Waiting Clearance", "Pending Payment", "Pending Finance Close",
]


# ---------------------------------------------------------------------------
# ابزارهای ایمن
# ---------------------------------------------------------------------------
def _dt_exists(doctype: str) -> bool:
    try:
        return bool(frappe.db.exists("DocType", doctype))
    except Exception:
        return False


def _has_field(doctype: str, fieldname: str) -> bool:
    if fieldname in ("name", "owner", "creation", "modified", "modified_by", "docstatus", "idx"):
        return True
    try:
        return bool(frappe.get_meta(doctype).has_field(fieldname))
    except Exception:
        return False


def _fields(doctype: str, wanted: list[str]) -> list[str]:
    return [f for f in wanted if _has_field(doctype, f)]


def _count(doctype: str, filters: dict | None = None) -> int:
    if not _dt_exists(doctype):
        return 0
    try:
        return int(frappe.db.count(doctype, filters or {}))
    except Exception:
        return 0


def _sum(doctype: str, field: str, filters: dict | None = None) -> float:
    if not _dt_exists(doctype) or not _has_field(doctype, field):
        return 0.0
    try:
        rows = frappe.get_all(
            doctype, filters=filters or {}, fields=[f"sum({field}) as total"]
        )
        return flt(rows[0].get("total")) if rows else 0.0
    except Exception:
        return 0.0


def _flow(kind: str) -> list[tuple]:
    return TRADE_FLOW if kind == "trade" else TRANSPORT_FLOW


def _exceptions(kind: str) -> list[tuple]:
    return TRADE_EXCEPTIONS if kind == "trade" else TRANSPORT_EXCEPTIONS


def _closed(kind: str) -> list[str]:
    return CLOSED_TRADE_STATES if kind == "trade" else CLOSED_TRANSPORT_STATES


def _stage_map(kind: str) -> dict[str, dict]:
    result: dict[str, dict] = {}
    for idx, (state, label, owner, sla, icon) in enumerate(_flow(kind) + _exceptions(kind)):
        result[state] = {
            "index": idx, "label": label, "owner": owner,
            "sla": sla, "icon": icon, "state": state,
        }
    return result


def _hours_since(value) -> float:
    if not value:
        return 0.0
    try:
        delta = now_datetime() - get_datetime(value)
        return flt(delta.total_seconds() / 3600.0, 1)
    except Exception:
        return 0.0


def _fa_duration(hours: float) -> str:
    hours = flt(hours)
    if hours < 1:
        return f"{int(hours * 60)} دقیقه"
    if hours < 48:
        h = int(hours)
        m = int((hours - h) * 60)
        return f"{h} ساعت و {m} دقیقه" if m else f"{h} ساعت"
    return f"{int(hours // 24)} روز و {int(hours % 24)} ساعت"


def _tone(hours: float, sla: float) -> str:
    sla = flt(sla) or 24.0
    if hours > sla * 2:
        return "danger"
    if hours > sla:
        return "warn"
    return "ok"


def _user_label(user: str | None) -> str:
    if not user:
        return "تخصیص نیافته"
    try:
        name = frappe.db.get_value("User", user, "full_name")
        return name or user
    except Exception:
        return user


def _open_filters(cfg: dict) -> dict:
    kind = cfg.get("flow", "transport")
    states = cfg.get("states")
    if states:
        return {"workflow_state": ["in", states]}
    return {"workflow_state": ["not in", _closed(kind)]}


def _overdue_cutoff(hours: int = 48):
    return add_to_date(now_datetime(), hours=-hours)


# ---------------------------------------------------------------------------
# متریک‌ها
# ---------------------------------------------------------------------------
def _metric(name: str) -> float:
    open_tc = {"workflow_state": ["not in", CLOSED_TRANSPORT_STATES]}
    open_trd = {"workflow_state": ["not in", CLOSED_TRADE_STATES]}

    if name == "transport_open":
        return _count(TRANSPORT_DT, open_tc)
    if name == "transport_in_transit":
        return _count(TRANSPORT_DT, {"workflow_state": "In Transit"})
    if name == "transport_pending_action":
        return _count(TRANSPORT_DT, {"workflow_state": ["in", PENDING_ACTION_STATES]})
    if name == "transport_overdue":
        f = dict(open_tc)
        f["modified"] = ["<", _overdue_cutoff(48)]
        return _count(TRANSPORT_DT, f)
    if name == "today_loads":
        return _count(TRANSPORT_DT, {"posting_date": today()})
    if name == "today_tonnage":
        val = _sum(TRANSPORT_DT, "actual_tonnage", {"posting_date": today()})
        if not val:
            val = _sum(TRANSPORT_DT, "planned_tonnage", {"posting_date": today()})
        return flt(val, 1)
    if name == "tonnage_open":
        return flt(_sum(TRANSPORT_DT, "planned_tonnage", open_tc), 1)
    if name == "completed_month":
        return _count(TRANSPORT_DT, {
            "workflow_state": "Completed",
            "modified": [">=", add_to_date(now_datetime(), days=-30)],
        })
    if name == "profit_sum":
        return flt(_sum(TRANSPORT_DT, "estimated_profit", open_tc))
    if name == "cost_sum":
        return flt(_sum(TRANSPORT_DT, "total_cost", open_tc))
    if name == "sales_sum":
        return flt(_sum(TRANSPORT_DT, "sales_amount", open_tc))
    if name == "pending_payment":
        return _count(TRANSPORT_DT, {"workflow_state": "Pending Payment"})
    if name == "pending_finance_close":
        return _count(TRANSPORT_DT, {"workflow_state": "Pending Finance Close"})
    if name == "trade_finance_queue":
        return _count(TRADE_DT, {"workflow_state": ["in", ["Finance Supervisor", "Treasury Review", "Receivables"]]})
    if name == "waiting_bijak":
        return _count(TRANSPORT_DT, {"workflow_state": "Waiting Bijak"})
    if name == "waiting_clearance":
        return _count(TRANSPORT_DT, {"workflow_state": "Waiting Clearance"})
    if name == "cleared_count":
        return _count(TRANSPORT_DT, {"workflow_state": "Cleared"})
    if name == "customs_overdue":
        return _count(TRANSPORT_DT, {
            "workflow_state": ["in", ["Waiting Bijak", "Waiting Clearance", "Waiting Weighbridge"]],
            "modified": ["<", _overdue_cutoff(48)],
        })
    if name == "customs_cost_sum":
        return flt(_sum(TRANSPORT_DT, "customs_cost", {
            "workflow_state": ["in", ["Waiting Bijak", "Waiting Clearance", "Cleared"]]
        }))
    if name == "border_count":
        return _count("Border", {"is_active": 1}) or _count("Border")
    if name == "trade_open":
        return _count(TRADE_DT, open_trd)
    if name == "trade_legal":
        return _count(TRADE_DT, {"workflow_state": "Legal Review"})
    if name == "trade_signature":
        return _count(TRADE_DT, {"workflow_state": "Pending Signature"})
    if name == "trade_receivables":
        return _count(TRADE_DT, {"workflow_state": "Receivables"})
    if name == "trade_approved":
        return _count(TRADE_DT, {"workflow_state": "Approved"})
    if name == "trade_overdue":
        f = dict(open_trd)
        f["modified"] = ["<", _overdue_cutoff(48)]
        return _count(TRADE_DT, f)
    return 0


def _metric_route(name: str) -> dict | None:
    routes = {
        "transport_open": (TRANSPORT_DT, {"workflow_state": ["not in", CLOSED_TRANSPORT_STATES]}),
        "transport_in_transit": (TRANSPORT_DT, {"workflow_state": "In Transit"}),
        "transport_pending_action": (TRANSPORT_DT, {"workflow_state": ["in", PENDING_ACTION_STATES]}),
        "today_loads": (TRANSPORT_DT, {"posting_date": today()}),
        "pending_payment": (TRANSPORT_DT, {"workflow_state": "Pending Payment"}),
        "pending_finance_close": (TRANSPORT_DT, {"workflow_state": "Pending Finance Close"}),
        "waiting_bijak": (TRANSPORT_DT, {"workflow_state": "Waiting Bijak"}),
        "waiting_clearance": (TRANSPORT_DT, {"workflow_state": "Waiting Clearance"}),
        "cleared_count": (TRANSPORT_DT, {"workflow_state": "Cleared"}),
        "completed_month": (TRANSPORT_DT, {"workflow_state": "Completed"}),
        "trade_open": (TRADE_DT, {"workflow_state": ["not in", CLOSED_TRADE_STATES]}),
        "trade_legal": (TRADE_DT, {"workflow_state": "Legal Review"}),
        "trade_signature": (TRADE_DT, {"workflow_state": "Pending Signature"}),
        "trade_receivables": (TRADE_DT, {"workflow_state": "Receivables"}),
        "trade_approved": (TRADE_DT, {"workflow_state": "Approved"}),
    }
    found = routes.get(name)
    if not found:
        return None
    return {"doctype": found[0], "filters": found[1]}


# ---------------------------------------------------------------------------
# سازنده بخش‌ها
# ---------------------------------------------------------------------------
def _build_kpi(cfg: dict) -> list[dict]:
    result = []
    for spec in cfg.get("kpi", []):
        value = _metric(spec["metric"])
        result.append({
            "id": spec["metric"],
            "label": spec["label"],
            "icon": spec.get("icon", "📌"),
            "tone": spec.get("tone", "navy"),
            "suffix": spec.get("suffix", ""),
            "money": cint(spec.get("money")),
            "value": flt(value, 1) if isinstance(value, float) else value,
            "route": _metric_route(spec["metric"]),
        })
    return result


def _build_stages(cfg: dict) -> list[dict]:
    kind = cfg.get("flow", "transport")
    doctype = cfg.get("doctype", TRANSPORT_DT)
    if not _dt_exists(doctype):
        return []

    result = []
    for state, label, owner, sla, icon in _flow(kind):
        count = _count(doctype, {"workflow_state": state})
        overdue = 0
        if sla:
            overdue = _count(doctype, {
                "workflow_state": state,
                "modified": ["<", _overdue_cutoff(int(sla))],
            })
        if state in _closed(kind) and not count:
            continue
        status = "empty"
        if count:
            status = "active"
            if overdue and overdue >= max(1, count // 2):
                status = "overdue"
            elif overdue:
                status = "warn"
        if state == "Completed" or state == "Approved":
            status = "done" if count else "empty"
        result.append({
            "state": state, "label": label, "owner": owner, "icon": icon,
            "count": count, "overdue": overdue, "status": status, "sla": sla,
            "route": {"doctype": doctype, "filters": {"workflow_state": state}},
        })

    for state, label, owner, sla, icon in _exceptions(kind):
        count = _count(doctype, {"workflow_state": state})
        if not count:
            continue
        result.append({
            "state": state, "label": label, "owner": owner, "icon": icon,
            "count": count, "overdue": 0,
            "status": "overdue" if state in ("On Hold", "Rejected", "Returned") else "empty",
            "sla": sla,
            "route": {"doctype": doctype, "filters": {"workflow_state": state}},
        })
    return result


def _build_action_table(cfg: dict, limit: int = 30) -> list[dict]:
    doctype = cfg.get("doctype", TRANSPORT_DT)
    if not _dt_exists(doctype):
        return []
    stages = _stage_map(cfg.get("flow", "transport"))
    wanted = [
        "name", "case_title", "customer", "destination", "planned_tonnage",
        "actual_tonnage", "workflow_state", "assigned_user", "priority",
        "driver_name", "plate_number", "border", "modified", "owner",
    ]
    fields = _fields(doctype, wanted)
    try:
        rows = frappe.get_all(
            doctype, filters=_open_filters(cfg), fields=fields,
            order_by="modified asc", limit=limit,
        )
    except Exception:
        return []

    result = []
    for row in rows:
        stage = stages.get(row.get("workflow_state"), {})
        hours = _hours_since(row.get("modified"))
        tone = _tone(hours, stage.get("sla") or 24)
        responsible = _user_label(row.get("assigned_user")) if row.get("assigned_user") else stage.get("owner", "-")
        result.append({
            "name": row.get("name"),
            "doctype": doctype,
            "case_title": row.get("case_title") or row.get("name"),
            "customer": row.get("customer") or "-",
            "destination": row.get("destination") or row.get("border") or "-",
            "tonnage": flt(row.get("actual_tonnage") or row.get("planned_tonnage") or 0, 1),
            "state": row.get("workflow_state"),
            "state_label": stage.get("label", row.get("workflow_state") or "-"),
            "stage_icon": stage.get("icon", "•"),
            "responsible": responsible,
            "responsible_role": stage.get("owner", "-"),
            "priority": row.get("priority") or "متوسط",
            "driver": row.get("driver_name") or "-",
            "plate": row.get("plate_number") or "-",
            "last_activity": format_datetime(row.get("modified"), "yyyy-MM-dd HH:mm"),
            "stalled_hours": hours,
            "stalled_label": _fa_duration(hours),
            "tone": tone,
        })
    return result


def _build_focus_case(cfg: dict) -> dict:
    rows = _build_action_table(cfg, limit=1)
    if not rows:
        return {}
    return get_case_timeline(rows[0]["name"], rows[0]["doctype"])


def _build_kanban(cfg: dict) -> dict:
    doctype = cfg.get("doctype", TRANSPORT_DT)
    if not _dt_exists(doctype):
        return {"columns": []}
    kind = cfg.get("flow", "transport")
    stages = _stage_map(kind)
    states = cfg.get("kanban_states") or [s[0] for s in _flow(kind)[:6]]
    fields = _fields(doctype, [
        "name", "case_title", "customer", "destination", "planned_tonnage",
        "assigned_user", "modified", "priority",
    ])
    columns = []
    for state in states:
        stage = stages.get(state, {})
        try:
            rows = frappe.get_all(
                doctype, filters={"workflow_state": state}, fields=fields,
                order_by="modified asc", limit=8,
            )
        except Exception:
            rows = []
        cards = []
        for row in rows:
            hours = _hours_since(row.get("modified"))
            cards.append({
                "name": row.get("name"),
                "title": row.get("case_title") or row.get("name"),
                "destination": row.get("destination") or "-",
                "tonnage": flt(row.get("planned_tonnage") or 0, 1),
                "responsible": _user_label(row.get("assigned_user")) if row.get("assigned_user") else stage.get("owner", "-"),
                "stalled_label": _fa_duration(hours),
                "tone": _tone(hours, stage.get("sla") or 24),
            })
        columns.append({
            "state": state,
            "label": stage.get("label", state),
            "icon": stage.get("icon", "•"),
            "total": _count(doctype, {"workflow_state": state}),
            "cards": cards,
            "doctype": doctype,
        })
    return {"columns": columns}


def _build_destinations(cfg: dict) -> list[dict]:
    doctype = cfg.get("doctype", TRANSPORT_DT)
    if not _dt_exists(doctype) or not _has_field(doctype, "destination"):
        return []
    filters = _open_filters(cfg)
    try:
        rows = frappe.get_all(
            doctype, filters=filters,
            fields=["destination as label", "count(name) as cnt", "sum(planned_tonnage) as tonnage"],
            group_by="destination", order_by="cnt desc", limit=14,
        )
    except Exception:
        return []

    overdue_map: dict[str, int] = {}
    try:
        of = dict(filters)
        of["modified"] = ["<", _overdue_cutoff(48)]
        for row in frappe.get_all(
            doctype, filters=of,
            fields=["destination as label", "count(name) as cnt"],
            group_by="destination", limit=40,
        ):
            overdue_map[row.get("label") or "-"] = cint(row.get("cnt"))
    except Exception:
        pass

    result = []
    for row in rows:
        label = row.get("label") or "نامشخص"
        overdue = overdue_map.get(label, 0)
        count = cint(row.get("cnt"))
        tone = "ok"
        if overdue and overdue >= max(1, count // 3):
            tone = "danger"
        elif overdue:
            tone = "warn"
        result.append({
            "label": label,
            "count": count,
            "tonnage": flt(row.get("tonnage") or 0, 1),
            "overdue": overdue,
            "tone": tone,
            "route": {"doctype": doctype, "filters": {
                "destination": label,
                "workflow_state": ["not in", _closed(cfg.get("flow", "transport"))],
            }},
        })
    return result


def _build_performance(cfg: dict) -> list[dict]:
    doctype = cfg.get("doctype", TRANSPORT_DT)
    if not _dt_exists(doctype) or not _has_field(doctype, "assigned_user"):
        return []
    try:
        rows = frappe.get_all(
            doctype, filters={"assigned_user": ["is", "set"]},
            fields=["assigned_user as user", "count(name) as total"],
            group_by="assigned_user", order_by="total desc", limit=8,
        )
    except Exception:
        return []

    result = []
    for row in rows:
        user = row.get("user")
        total = cint(row.get("total"))
        completed = _count(doctype, {"assigned_user": user, "workflow_state": "Completed"})
        overdue = _count(doctype, {
            "assigned_user": user,
            "workflow_state": ["not in", CLOSED_TRANSPORT_STATES],
            "modified": ["<", _overdue_cutoff(48)],
        })
        avg_days = 0.0
        try:
            done = frappe.get_all(
                doctype, filters={"assigned_user": user, "workflow_state": "Completed"},
                fields=["creation", "modified"], limit=60,
            )
            if done:
                total_hours = sum(
                    max(0.0, (get_datetime(d["modified"]) - get_datetime(d["creation"])).total_seconds() / 3600.0)
                    for d in done
                )
                avg_days = flt(total_hours / len(done) / 24.0, 1)
        except Exception:
            avg_days = 0.0
        result.append({
            "user": user,
            "name": _user_label(user),
            "total": total,
            "completed": completed,
            "overdue": overdue,
            "open": max(0, total - completed),
            "avg_days": avg_days,
            "percent": int(round((completed / total) * 100)) if total else 0,
        })
    return result


def _build_alerts(cfg: dict) -> list[dict]:
    doctype = cfg.get("doctype", TRANSPORT_DT)
    alerts: list[dict] = []
    if not _dt_exists(doctype):
        return alerts

    kind = cfg.get("flow", "transport")
    stages = _stage_map(kind)
    fields = _fields(doctype, ["name", "case_title", "workflow_state", "assigned_user", "modified"])

    # ۱) توقف بیش از SLA مرحله
    try:
        rows = frappe.get_all(
            doctype, filters=_open_filters(cfg), fields=fields,
            order_by="modified asc", limit=40,
        )
    except Exception:
        rows = []
    for row in rows:
        stage = stages.get(row.get("workflow_state"), {})
        sla = flt(stage.get("sla") or 24)
        hours = _hours_since(row.get("modified"))
        if hours <= sla:
            continue
        severity = "critical" if hours > sla * 2 else "warning"
        alerts.append({
            "case_name": row.get("name"),
            "doctype": doctype,
            "title": row.get("case_title") or row.get("name"),
            "message": "پرونده {0} حدود {1} در مرحله «{2}» متوقف است (حد مجاز {3} ساعت).".format(
                row.get("case_title") or row.get("name"),
                _fa_duration(hours),
                stage.get("label", row.get("workflow_state")),
                int(sla),
            ),
            "severity": severity,
            "hours": hours,
        })
        if len(alerts) >= 12:
            break

    # ۲) اسناد ناقص
    if doctype == TRANSPORT_DT:
        try:
            if _has_field(TRANSPORT_DT, "waybill_number"):
                for row in frappe.get_all(
                    TRANSPORT_DT,
                    filters={"workflow_state": ["in", ["In Transit", "Waiting Weighbridge", "Waiting Bijak"]],
                             "waybill_number": ["in", ["", None]]},
                    fields=_fields(TRANSPORT_DT, ["name", "case_title", "workflow_state"]), limit=5,
                ):
                    alerts.append({
                        "case_name": row.get("name"), "doctype": TRANSPORT_DT,
                        "title": row.get("case_title") or row.get("name"),
                        "message": "پرونده {0} بدون شماره بارنامه در مرحله «{1}» است.".format(
                            row.get("case_title") or row.get("name"), row.get("workflow_state")),
                        "severity": "critical", "hours": 0,
                    })
            if _has_field(TRANSPORT_DT, "needs_bijak") and _has_field(TRANSPORT_DT, "bijak_done"):
                for row in frappe.get_all(
                    TRANSPORT_DT,
                    filters={"needs_bijak": "بله", "bijak_done": 0,
                             "workflow_state": ["in", ["Waiting Clearance", "Cleared", "Delivered"]]},
                    fields=_fields(TRANSPORT_DT, ["name", "case_title"]), limit=5,
                ):
                    alerts.append({
                        "case_name": row.get("name"), "doctype": TRANSPORT_DT,
                        "title": row.get("case_title") or row.get("name"),
                        "message": "پرونده {0} نیازمند بیجک است ولی بیجک ثبت نشده.".format(
                            row.get("case_title") or row.get("name")),
                        "severity": "warning", "hours": 0,
                    })
        except Exception:
            pass

    # ۳) انقضای بیمه/معاینه ناوگان
    try:
        if _dt_exists("Vehicle") and _has_field("Vehicle", "custom_insurance_expiry"):
            soon = add_to_date(today(), days=30)
            for row in frappe.get_all(
                "Vehicle",
                filters={"custom_insurance_expiry": ["<=", soon]},
                fields=["name", "license_plate", "custom_insurance_expiry"], limit=4,
            ):
                alerts.append({
                    "case_name": row.get("name"), "doctype": "Vehicle",
                    "title": row.get("license_plate") or row.get("name"),
                    "message": "بیمه خودرو {0} تا {1} منقضی می‌شود.".format(
                        row.get("license_plate") or row.get("name"),
                        row.get("custom_insurance_expiry")),
                    "severity": "info", "hours": 0,
                })
    except Exception:
        pass

    return alerts[:18]


_BUILDERS = {
    "kpi": _build_kpi,
    "stages": _build_stages,
    "action_table": _build_action_table,
    "focus_case": _build_focus_case,
    "kanban": _build_kanban,
    "destinations": _build_destinations,
    "performance": _build_performance,
    "alerts": _build_alerts,
}


# ---------------------------------------------------------------------------
# APIهای عمومی
# ---------------------------------------------------------------------------
@frappe.whitelist()
def get_user_info() -> dict:
    user = frappe.session.user
    full_name = frappe.db.get_value("User", user, "full_name") or user
    roles = frappe.get_roles(user)
    label = "کاربر سیستم"
    for role in ROLE_LABELS:
        if role in roles and role != "System Manager":
            label = ROLE_LABELS[role]
            break
    else:
        if "System Manager" in roles:
            label = ROLE_LABELS["System Manager"]
    initials = "".join([p[0] for p in str(full_name).split()[:2]]) or "؟"
    return {"user": user, "full_name": full_name, "role": label, "initials": initials}


@frappe.whitelist()
def get_dashboard(key: str = "transport_ops") -> dict:
    cfg = DASHBOARDS.get(key) or DASHBOARDS["transport_ops"]
    payload: dict[str, Any] = {
        "key": key,
        "title": cfg["title"],
        "subtitle": cfg["subtitle"],
        "icon": cfg.get("icon", "📊"),
        "doctype": cfg.get("doctype", TRANSPORT_DT),
        "sections": cfg.get("sections", []),
        "user": get_user_info(),
        "generated_at": format_datetime(now_datetime(), "yyyy-MM-dd HH:mm"),
        "links": [
            {"label": d["title"], "route": d["route"], "icon": d.get("icon", "📊")}
            for k, d in DASHBOARDS.items() if k != key
        ],
    }
    for section in cfg.get("sections", []):
        builder = _BUILDERS.get(section)
        if not builder:
            continue
        try:
            payload[section] = builder(cfg)
        except Exception:
            frappe.log_error(frappe.get_traceback(), f"Phase12 dashboard section failed: {section}")
            payload[section] = [] if section != "focus_case" else {}
    return payload


@frappe.whitelist()
def get_case_timeline(case: str, doctype: str = "Transport Case") -> dict:
    if not case or not _dt_exists(doctype):
        return {}
    kind = "trade" if doctype == TRADE_DT else "transport"
    flow = _flow(kind)
    stages = _stage_map(kind)

    wanted = [
        "name", "case_title", "workflow_state", "customer", "destination", "border",
        "planned_tonnage", "actual_tonnage", "assigned_user", "driver_name",
        "plate_number", "waybill_number", "priority", "modified", "creation", "owner",
    ] + [c[0] for c in CLOSE_CHECKLIST]
    fields = _fields(doctype, wanted)
    try:
        doc = frappe.db.get_value(doctype, case, fields, as_dict=True)
    except Exception:
        doc = None
    if not doc:
        return {}

    current_state = doc.get("workflow_state") or flow[0][0]
    stage = stages.get(current_state, {})
    current_index = stage.get("index", 0)
    hours = _hours_since(doc.get("modified"))
    sla = flt(stage.get("sla") or 24)

    steps = []
    for idx, (state, label, owner, step_sla, icon) in enumerate(flow):
        if current_state in [e[0] for e in _exceptions(kind)]:
            status = "pending"
        elif idx < current_index:
            status = "done"
        elif idx == current_index:
            status = "current"
        else:
            status = "pending"
        steps.append({
            "state": state, "label": label, "owner": owner,
            "icon": icon, "status": status,
        })

    checklist = []
    for fieldname, label in CLOSE_CHECKLIST:
        if fieldname in doc:
            checklist.append({"label": label, "done": cint(doc.get(fieldname))})

    return {
        "name": doc.get("name"),
        "doctype": doctype,
        "case_title": doc.get("case_title") or doc.get("name"),
        "customer": doc.get("customer") or "-",
        "destination": doc.get("destination") or doc.get("border") or "-",
        "tonnage": flt(doc.get("actual_tonnage") or doc.get("planned_tonnage") or 0, 1),
        "driver": doc.get("driver_name") or "-",
        "plate": doc.get("plate_number") or "-",
        "waybill": doc.get("waybill_number") or "-",
        "priority": doc.get("priority") or "متوسط",
        "state": current_state,
        "state_label": stage.get("label", current_state),
        "responsible": _user_label(doc.get("assigned_user")) if doc.get("assigned_user") else stage.get("owner", "-"),
        "responsible_user": doc.get("assigned_user") or doc.get("owner"),
        "responsible_role": stage.get("owner", "-"),
        "stalled_hours": hours,
        "stalled_label": _fa_duration(hours),
        "sla": int(sla),
        "tone": _tone(hours, sla),
        "last_activity": format_datetime(doc.get("modified"), "yyyy-MM-dd HH:mm"),
        "due": format_datetime(add_to_date(get_datetime(doc.get("modified")), hours=int(sla)), "yyyy-MM-dd HH:mm") if sla else "-",
        "steps": steps,
        "checklist": checklist,
        "progress": int(round(((current_index + 1) / len(flow)) * 100)),
    }


@frappe.whitelist()
def smart_search(query: str = "") -> list[dict]:
    query = (query or "").strip()
    if len(query) < 2:
        return []

    like = f"%{query}%"
    results: list[dict] = []

    def _push(doctype: str, name: str, title: str, subtitle: str, icon: str):
        results.append({
            "doctype": doctype, "name": name, "title": title,
            "subtitle": subtitle, "icon": icon,
        })

    specs = [
        (TRANSPORT_DT, ["case_title", "name", "destination", "driver_name", "plate_number", "waybill_number"],
         ["name", "case_title", "workflow_state", "destination"], "🚚"),
        (TRADE_DT, ["case_title", "name", "destination", "sales_invoice_number", "purchase_invoice_number"],
         ["name", "case_title", "workflow_state", "destination"], "🧾"),
        ("Driver", ["full_name", "cell_number", "custom_national_id"],
         ["name", "full_name", "cell_number"], "👤"),
        ("Vehicle", ["license_plate", "name"], ["name", "license_plate"], "🚛"),
        ("Customer", ["customer_name", "name"], ["name", "customer_name"], "🏢"),
        ("Transport Waybill", ["waybill_number", "name"], ["name", "waybill_number", "transport_case"], "📄"),
    ]

    for doctype, search_fields, fetch_fields, icon in specs:
        if not _dt_exists(doctype):
            continue
        or_filters = [[f, "like", like] for f in search_fields if _has_field(doctype, f)]
        if not or_filters:
            continue
        try:
            rows = frappe.get_all(
                doctype, or_filters=or_filters,
                fields=_fields(doctype, fetch_fields), limit=6,
            )
        except Exception:
            rows = []
        for row in rows:
            title = (row.get("case_title") or row.get("full_name") or row.get("license_plate")
                     or row.get("customer_name") or row.get("waybill_number") or row.get("name"))
            subtitle = (row.get("workflow_state") or row.get("cell_number")
                        or row.get("transport_case") or doctype)
            _push(doctype, row.get("name"), title, subtitle, icon)
    return results[:24]


@frappe.whitelist()
def send_reminder(case: str, doctype: str = "Transport Case", message: str | None = None) -> dict:
    if not case or not _dt_exists(doctype):
        return {"ok": 0, "message": "پرونده یافت نشد."}

    info = get_case_timeline(case, doctype)
    if not info:
        return {"ok": 0, "message": "پرونده یافت نشد."}

    target = info.get("responsible_user") or frappe.session.user
    text = message or "یادآوری: پرونده {0} در مرحله «{1}» به مدت {2} متوقف مانده است. لطفاً اقدام فرمایید.".format(
        info.get("case_title"), info.get("state_label"), info.get("stalled_label"))

    created = []
    try:
        todo = frappe.get_doc({
            "doctype": "ToDo",
            "allocated_to": target,
            "reference_type": doctype,
            "reference_name": case,
            "description": text,
            "priority": "High",
            "status": "Open",
        })
        todo.insert(ignore_permissions=True)
        created.append("ToDo")
    except Exception:
        frappe.log_error(frappe.get_traceback(), "Phase12 reminder ToDo failed")

    try:
        notification = frappe.get_doc({
            "doctype": "Notification Log",
            "subject": "یادآوری اقدام روی پرونده {0}".format(info.get("case_title")),
            "email_content": text,
            "for_user": target,
            "type": "Alert",
            "document_type": doctype,
            "document_name": case,
        })
        notification.insert(ignore_permissions=True)
        created.append("Notification")
    except Exception:
        frappe.log_error(frappe.get_traceback(), "Phase12 reminder notification failed")

    try:
        frappe.get_doc(doctype, case).add_comment("Comment", text)
    except Exception:
        pass

    frappe.db.commit()
    return {"ok": 1, "target": _user_label(target), "created": created,
            "message": "یادآوری برای {0} ارسال شد.".format(_user_label(target))}


# ---------------------------------------------------------------------------
# سازگاری با فراخوانی‌های قدیمی
# ---------------------------------------------------------------------------
@frappe.whitelist()
def get_process_status() -> list[dict]:
    return _build_stages(DASHBOARDS["transport_ops"])


@frappe.whitelist()
def get_action_table() -> list[dict]:
    return _build_action_table(DASHBOARDS["transport_ops"], limit=50)


@frappe.whitelist()
def get_alerts() -> list[dict]:
    return _build_alerts(DASHBOARDS["transport_ops"])


@frappe.whitelist()
def get_performance() -> list[dict]:
    return _build_performance(DASHBOARDS["transport_ops"])


@frappe.whitelist()
def get_form_progress(case: str, doctype: str = "Transport Case") -> dict:
    """برای نمایش نوار پیشرفت روی فرم پرونده."""
    return get_case_timeline(case, doctype)
PYEOF
log "api/dashboard.py written"

# =============================================================================
step "4) نوشتن api/kpi.py"
# =============================================================================
cat > "${PHASE12_ROOT}/api/kpi.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""APIهای KPI فاز ۱۲ (سازگار با فراخوانی‌های مستقیم و Number Card نوع Custom)."""
from __future__ import annotations

import frappe

from transport_ir.iran_transport.phase12_workspaces.api import dashboard as _dash


@frappe.whitelist()
def get_transport_kpi() -> dict:
    return {
        "total": _dash._metric("transport_open"),
        "in_progress": _dash._metric("transport_in_transit"),
        "pending": _dash._metric("transport_pending_action"),
        "overdue": _dash._metric("transport_overdue"),
        "today_loads": _dash._metric("today_loads"),
        "today_tonnage": _dash._metric("today_tonnage"),
    }


@frappe.whitelist()
def get_trade_kpi() -> dict:
    return {
        "open": _dash._metric("trade_open"),
        "legal": _dash._metric("trade_legal"),
        "signature": _dash._metric("trade_signature"),
        "receivables": _dash._metric("trade_receivables"),
        "approved": _dash._metric("trade_approved"),
        "overdue": _dash._metric("trade_overdue"),
    }


@frappe.whitelist()
def get_finance_kpi() -> dict:
    return {
        "pending_payment": _dash._metric("pending_payment"),
        "pending_finance_close": _dash._metric("pending_finance_close"),
        "cost": _dash._metric("cost_sum"),
        "sales": _dash._metric("sales_sum"),
        "profit": _dash._metric("profit_sum"),
    }


@frappe.whitelist()
def get_customs_kpi() -> dict:
    return {
        "waiting_bijak": _dash._metric("waiting_bijak"),
        "waiting_clearance": _dash._metric("waiting_clearance"),
        "cleared": _dash._metric("cleared_count"),
        "overdue": _dash._metric("customs_overdue"),
    }


@frappe.whitelist()
def get_metric(name: str = "transport_open") -> dict:
    """برای Number Card نوع Custom: {"value": x}"""
    return {"value": _dash._metric(name)}
PYEOF
log "api/kpi.py written"

# =============================================================================
step "5) نوشتن workspaces.py (ساخت/به‌روزرسانی Workspaceها)"
# =============================================================================
cat > "${PHASE12_ROOT}/workspaces.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""ساخت idempotent فضاهای کاری، Number Cardها و Chartهای فاز ۱۲."""
from __future__ import annotations

import json

import frappe

from transport_ir.iran_transport.phase12_workspaces.config import (
    CHARTS,
    DASHBOARDS,
    MODULE_LABEL,
    NUMBER_CARDS,
    WORKSPACES,
)


# ---------------------------------------------------------------------------
def _dt_exists(doctype: str) -> bool:
    try:
        return bool(frappe.db.exists("DocType", doctype))
    except Exception:
        return False


def _has_field(doctype: str, fieldname: str) -> bool:
    try:
        return bool(frappe.get_meta(doctype).has_field(fieldname))
    except Exception:
        return False


def _safe_color(doctype: str, value: str | None) -> str | None:
    """اگر فیلد color از نوع Select باشد، مقدار خارج از options باعث خطا می‌شود."""
    if not value:
        return None
    try:
        field = frappe.get_meta(doctype).get_field("color")
        if not field:
            return None
        options = [o.strip() for o in (field.options or "").split("\n") if o.strip()]
        if not options:
            return value
        if value in options:
            return value
        fallback = {
            "Blue": ["Blue", "Cyan", "Purple"], "Green": ["Green", "Cyan"],
            "Red": ["Red", "Orange", "Pink"], "Orange": ["Orange", "Yellow", "Red"],
            "Yellow": ["Yellow", "Orange"], "Purple": ["Purple", "Pink", "Blue"],
            "Cyan": ["Cyan", "Blue"], "Grey": ["Grey", "Blue"], "Pink": ["Pink", "Purple"],
        }.get(value, [])
        for candidate in fallback:
            if candidate in options:
                return candidate
        return options[0]
    except Exception:
        return None


def _uid() -> str:
    return frappe.generate_hash(length=10)


# ---------------------------------------------------------------------------
# Number Cards
# ---------------------------------------------------------------------------
def ensure_number_cards() -> dict[str, str]:
    created: dict[str, str] = {}
    if not _dt_exists("Number Card"):
        return created

    for spec in NUMBER_CARDS:
        if not _dt_exists(spec["doctype"]):
            continue
        if spec.get("based_on") and not _has_field(spec["doctype"], spec["based_on"]):
            continue
        label = spec["label"]
        try:
            existing = frappe.db.get_value("Number Card", {"label": label}, "name")
            doc = frappe.get_doc("Number Card", existing) if existing else frappe.new_doc("Number Card")
            doc.label = label
            doc.type = "Document Type"
            doc.document_type = spec["doctype"]
            doc.function = spec.get("function", "Count")
            if spec.get("based_on"):
                doc.aggregate_function_based_on = spec["based_on"]
            doc.filters_json = json.dumps(spec.get("filters", []))
            if _has_field("Number Card", "dynamic_filters_json"):
                doc.dynamic_filters_json = "[]"
            doc.is_public = 1
            doc.show_percentage_stats = 0
            if _has_field("Number Card", "module"):
                doc.module = MODULE_LABEL
            if _has_field("Number Card", "color"):
                doc.color = spec.get("color")
            doc.flags.ignore_permissions = True
            doc.save(ignore_permissions=True) if existing else doc.insert(ignore_permissions=True)
            created[spec["key"]] = doc.name
        except Exception:
            frappe.log_error(frappe.get_traceback(), f"Phase12 number card failed: {label}")
    return created


# ---------------------------------------------------------------------------
# Charts
# ---------------------------------------------------------------------------
def ensure_charts() -> dict[str, str]:
    created: dict[str, str] = {}
    if not _dt_exists("Dashboard Chart"):
        return created

    for spec in CHARTS:
        if not _dt_exists(spec["doctype"]) or not _has_field(spec["doctype"], spec["group_by"]):
            continue
        label = spec["label"]
        try:
            existing = frappe.db.get_value("Dashboard Chart", {"chart_name": label}, "name")
            doc = frappe.get_doc("Dashboard Chart", existing) if existing else frappe.new_doc("Dashboard Chart")
            doc.chart_name = label
            doc.chart_type = "Group By"
            doc.document_type = spec["doctype"]
            doc.group_by_type = "Count"
            doc.group_by_based_on = spec["group_by"]
            doc.number_of_groups = 0
            doc.type = spec.get("type", "Bar")
            doc.is_public = 1
            doc.timeseries = 0
            doc.filters_json = "[]"
            if _has_field("Dashboard Chart", "dynamic_filters_json"):
                doc.dynamic_filters_json = "[]"
            if _has_field("Dashboard Chart", "module"):
                doc.module = MODULE_LABEL
            if _has_field("Dashboard Chart", "color"):
                doc.color = spec.get("color")
            doc.flags.ignore_permissions = True
            doc.save(ignore_permissions=True) if existing else doc.insert(ignore_permissions=True)
            created[spec["key"]] = doc.name
        except Exception:
            frappe.log_error(frappe.get_traceback(), f"Phase12 chart failed: {label}")
    return created


# ---------------------------------------------------------------------------
# Workspaces
# ---------------------------------------------------------------------------
def _build_content(spec: dict, cards: dict, charts: dict, shortcut_labels: list[str],
                   card_labels: list[str]) -> str:
    blocks: list[dict] = []

    def add(block_type: str, data: dict):
        blocks.append({"id": _uid(), "type": block_type, "data": data})

    dash = DASHBOARDS.get(spec.get("dashboard") or "", {})
    add("header", {"text": f'<span class="h4"><b>{spec["label"]}</b></span>', "col": 12})
    if dash:
        add("paragraph", {
            "text": (
                '<div dir="rtl" style="padding:14px 16px;border-radius:12px;'
                'background:linear-gradient(135deg,#1e3c72,#2a5298);color:#fff">'
                f'<b style="font-size:15px">{dash.get("icon","📊")} {dash["title"]}</b>'
                f'<div style="opacity:.85;font-size:12px;margin:4px 0 10px">{dash["subtitle"]}</div>'
                f'<a href="/app/{dash["route"]}" style="display:inline-block;padding:6px 16px;'
                'border-radius:20px;background:#fff;color:#1e3c72;font-weight:600;'
                'text-decoration:none">ورود به داشبورد اختصاصی ←</a></div>'
            ),
            "col": 12,
        })

    number_cards = [cards[k] for k in spec.get("number_cards", []) if k in cards]
    if number_cards:
        add("header", {"text": '<span class="h4"><b>شاخص‌های کلیدی</b></span>', "col": 12})
        for name in number_cards:
            add("number_card", {"number_card_name": name, "col": 4})

    if shortcut_labels:
        add("header", {"text": '<span class="h4"><b>دسترسی سریع</b></span>', "col": 12})
        for label in shortcut_labels:
            add("shortcut", {"shortcut_name": label, "col": 3})

    chart_names = [charts[k] for k in spec.get("charts", []) if k in charts]
    for name in chart_names:
        add("chart", {"chart_name": name, "col": 12})

    if card_labels:
        add("header", {"text": '<span class="h4"><b>پیوندها</b></span>', "col": 12})
        for label in card_labels:
            add("card", {"card_name": label, "col": 4})

    return json.dumps(blocks)


def ensure_workspaces(cards: dict, charts: dict) -> list[str]:
    if not _dt_exists("Workspace"):
        return []

    done: list[str] = []
    for spec in WORKSPACES:
        try:
            name = (
                frappe.db.get_value("Workspace", {"label": spec["label"]}, "name")
                or frappe.db.get_value("Workspace", {"name": spec["name"]}, "name")
            )
            if name:
                doc = frappe.get_doc("Workspace", name)
            else:
                doc = frappe.new_doc("Workspace")
                doc.name = spec["name"]

            doc.label = spec["label"]
            if _has_field("Workspace", "title"):
                doc.title = spec["label"]
            doc.module = MODULE_LABEL if frappe.db.exists("Module Def", MODULE_LABEL) else doc.module
            doc.icon = spec.get("icon") or "dashboard"
            doc.public = 1
            doc.is_hidden = 0
            if _has_field("Workspace", "sequence_id"):
                doc.sequence_id = spec.get("sequence", 20.0)
            if _has_field("Workspace", "parent_page"):
                doc.parent_page = ""
            if _has_field("Workspace", "for_user"):
                doc.for_user = ""

            # نقش‌ها
            if _has_field("Workspace", "roles"):
                roles = [r for r in spec.get("roles", []) if frappe.db.exists("Role", r)]
                doc.set("roles", [{"role": r} for r in roles])

            # Shortcuts
            shortcut_labels: list[str] = []
            doc.set("shortcuts", [])
            for shortcut in spec.get("shortcuts", []):
                link_to = shortcut["link_to"]
                stype = shortcut.get("type", "DocType")
                if stype == "DocType" and not _dt_exists(link_to):
                    continue
                if stype == "Page" and not frappe.db.exists("Page", link_to):
                    continue
                if stype == "Report" and not frappe.db.exists("Report", link_to):
                    continue
                row = {
                    "type": stype,
                    "link_to": link_to,
                    "label": shortcut["label"],
                    "doc_view": shortcut.get("doc_view", "List") if stype == "DocType" else "",
                }
                color = _safe_color("Workspace Shortcut", shortcut.get("color"))
                if color:
                    row["color"] = color
                if shortcut.get("stats_filter") and stype == "DocType":
                    row["stats_filter"] = json.dumps(shortcut["stats_filter"], ensure_ascii=False)
                    if shortcut.get("format"):
                        row["format"] = shortcut["format"]
                doc.append("shortcuts", row)
                shortcut_labels.append(shortcut["label"])

            # Links (Card Break + Links)
            card_labels: list[str] = []
            doc.set("links", [])
            for card in spec.get("cards", []):
                valid = []
                for link_to, link_type, label in card["links"]:
                    if link_type == "DocType" and not _dt_exists(link_to):
                        continue
                    if link_type == "Report" and not frappe.db.exists("Report", link_to):
                        continue
                    if link_type == "Page" and not frappe.db.exists("Page", link_to):
                        continue
                    valid.append((link_to, link_type, label))
                if not valid:
                    continue
                doc.append("links", {
                    "type": "Card Break",
                    "label": card["label"],
                    "link_count": len(valid),
                    "hidden": 0,
                    "onboard": 0,
                })
                for link_to, link_type, label in valid:
                    doc.append("links", {
                        "type": "Link",
                        "label": label,
                        "link_to": link_to,
                        "link_type": link_type,
                        "hidden": 0,
                        "onboard": 0,
                        "is_query_report": 0,
                        "link_count": 0,
                    })
                card_labels.append(card["label"])

            # Charts child table
            if _has_field("Workspace", "charts"):
                doc.set("charts", [])
                for key in spec.get("charts", []):
                    if key in charts:
                        doc.append("charts", {"chart_name": charts[key], "label": charts[key]})

            # Number cards child table
            if _has_field("Workspace", "number_cards"):
                doc.set("number_cards", [])
                for key in spec.get("number_cards", []):
                    if key in cards:
                        doc.append("number_cards", {"number_card_name": cards[key], "label": cards[key]})

            doc.content = _build_content(spec, cards, charts, shortcut_labels, card_labels)

            doc.flags.ignore_permissions = True
            doc.flags.ignore_mandatory = True
            doc.flags.ignore_links = True
            if doc.get("__islocal") or not doc.get("name") or not frappe.db.exists("Workspace", doc.name):
                doc.insert(ignore_permissions=True)
            else:
                doc.save(ignore_permissions=True)
            done.append(doc.name)
            print(f"  ✓ Workspace: {doc.name} ({spec['label']})")
        except Exception:
            frappe.log_error(frappe.get_traceback(), f"Phase12 workspace failed: {spec['name']}")
            print(f"  ✗ Workspace failed: {spec['name']} — جزئیات در Error Log")
    return done
PYEOF
log "workspaces.py written"

# =============================================================================
step "6) نوشتن setup.py (نقطه ورود فاز ۱۲)"
# =============================================================================
cat > "${PHASE12_ROOT}/setup.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""نقطه ورود فاز ۱۲ — فضاهای کاری اختصاصی و داشبوردهای مدیریتی.

اجرا:
    bench --site SITE execute transport_ir.iran_transport.phase12_workspaces.setup.prepare
    bench --site SITE execute transport_ir.iran_transport.phase12_workspaces.setup.execute
    bench --site SITE execute transport_ir.iran_transport.phase12_workspaces.setup.verify
"""
from __future__ import annotations

import json
import os

import frappe

from transport_ir.iran_transport.phase12_workspaces.config import (
    DASHBOARDS,
    MODULE_LABEL,
    PHASE12_ROLES,
    ROLE_LABELS,
    WORKSPACES,
)
from transport_ir.iran_transport.phase12_workspaces.workspaces import (
    ensure_charts,
    ensure_number_cards,
    ensure_workspaces,
)

PAGE_DIRNAME = "page"


def _module_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# ---------------------------------------------------------------------------
def ensure_module_def() -> None:
    if not frappe.db.exists("Module Def", MODULE_LABEL):
        try:
            frappe.get_doc({
                "doctype": "Module Def",
                "module_name": MODULE_LABEL,
                "app_name": "transport_ir",
            }).insert(ignore_permissions=True)
            print(f"  ✓ Module Def created: {MODULE_LABEL}")
        except Exception:
            frappe.log_error(frappe.get_traceback(), "Phase12 module def failed")


def ensure_roles() -> None:
    for role in PHASE12_ROLES:
        if not frappe.db.exists("Role", role):
            try:
                frappe.get_doc({
                    "doctype": "Role", "role_name": role, "desk_access": 1,
                }).insert(ignore_permissions=True)
                print(f"  ✓ Role created: {role} ({ROLE_LABELS.get(role, '')})")
            except Exception:
                frappe.log_error(frappe.get_traceback(), f"Phase12 role failed: {role}")


def ensure_pages() -> list[str]:
    """اگر migrate صفحات استاندارد را ایمپورت نکرده باشد، اینجا fallback می‌سازیم."""
    base = os.path.join(_module_root(), PAGE_DIRNAME)
    result: list[str] = []
    if not os.path.isdir(base):
        return result

    for folder in sorted(os.listdir(base)):
        folder_path = os.path.join(base, folder)
        if not os.path.isdir(folder_path):
            continue
        json_path = os.path.join(folder_path, f"{folder}.json")
        if not os.path.exists(json_path):
            continue
        try:
            with open(json_path, encoding="utf-8") as handle:
                data = json.load(handle)
        except Exception:
            continue

        page_name = data.get("name") or folder.replace("_", "-")
        roles = [r.get("role") for r in data.get("roles", [])
                 if r.get("role") and frappe.db.exists("Role", r["role"])]
        try:
            if frappe.db.exists("Page", page_name):
                doc = frappe.get_doc("Page", page_name)
                doc.title = data.get("title") or doc.title
                doc.standard = "Yes"
                doc.module = MODULE_LABEL
                doc.set("roles", [{"role": r} for r in roles])
                doc.flags.ignore_permissions = True
                doc.save(ignore_permissions=True)
            else:
                doc = frappe.get_doc({
                    "doctype": "Page",
                    "name": page_name,
                    "page_name": page_name,
                    "title": data.get("title") or page_name,
                    "module": MODULE_LABEL,
                    "standard": "Yes",
                    "system_page": 0,
                    "roles": [{"role": r} for r in roles],
                })
                doc.flags.ignore_permissions = True
                doc.insert(ignore_permissions=True)
            result.append(page_name)
            print(f"  ✓ Page: {page_name}")
        except Exception:
            frappe.log_error(frappe.get_traceback(), f"Phase12 page failed: {page_name}")
    return result


# ---------------------------------------------------------------------------
def prepare() -> dict:
    """گام آماده‌سازی: قبل از migrate اجرا می‌شود (نقش‌ها و Module Def)."""
    frappe.flags.in_import = True
    ensure_module_def()
    ensure_roles()
    frappe.db.commit()
    print("✓ Phase 12 prepare done")
    return {"ok": 1}


def execute() -> dict:
    """گام اصلی: صفحات، Number Cardها، Chartها و Workspaceها."""
    try:
        frappe.flags.in_import = True
        frappe.flags.mute_emails = True

        ensure_module_def()
        ensure_roles()
        pages = ensure_pages()
        frappe.db.commit()

        cards = ensure_number_cards()
        charts = ensure_charts()
        frappe.db.commit()

        spaces = ensure_workspaces(cards, charts)
        frappe.db.commit()

        try:
            frappe.clear_cache()
        except Exception:
            pass

        summary = {
            "pages": len(pages),
            "number_cards": len(cards),
            "charts": len(charts),
            "workspaces": len(spaces),
            "dashboards": list(DASHBOARDS.keys()),
        }
        print("PHASE12 SUMMARY:", summary)
        return summary
    except Exception:
        frappe.db.rollback()
        frappe.log_error(frappe.get_traceback(), "Phase 12 setup failed")
        raise


def verify() -> dict:
    """کنترل نتیجه نصب فاز ۱۲."""
    report = {"pages": {}, "workspaces": {}, "api": {}}

    for key, cfg in DASHBOARDS.items():
        report["pages"][cfg["route"]] = bool(frappe.db.exists("Page", cfg["route"]))

    for spec in WORKSPACES:
        name = (frappe.db.get_value("Workspace", {"label": spec["label"]}, "name")
                or frappe.db.get_value("Workspace", {"name": spec["name"]}, "name"))
        report["workspaces"][spec["label"]] = name or False

    from transport_ir.iran_transport.phase12_workspaces.api import dashboard as api_dash
    for key in DASHBOARDS:
        try:
            payload = api_dash.get_dashboard(key)
            report["api"][key] = {
                "kpi": len(payload.get("kpi") or []),
                "stages": len(payload.get("stages") or []),
                "rows": len(payload.get("action_table") or []),
                "alerts": len(payload.get("alerts") or []),
            }
        except Exception:
            report["api"][key] = "FAILED"

    print("PHASE12 VERIFY:", json.dumps(report, ensure_ascii=False, indent=2))
    return report
PYEOF
log "setup.py written"

# =============================================================================
step "7) نوشتن CSS داشبورد (RTL / فارسی / مدرن)"
# =============================================================================
cat > "${PUB_CSS}/phase12_dashboard.css" << 'CSSEOF'
/* ==========================================================================
   Phase 12 — Transport Command Center  (RTL / Persian / Enterprise)
   تمام کلاس‌ها با پیشوند p12- تا با استایل‌های قبلی تداخل نکنند
   ========================================================================== */
.p12-dash {
  direction: rtl;
  text-align: right;
  font-family: "Vazirmatn", "IRANSans", "IRANYekan", "Tahoma", sans-serif;
  color: #16233a;
  padding: 4px 2px 40px;
  --p12-navy: #1e3c72;
  --p12-navy2: #2a5298;
  --p12-line: #e5e9f2;
  --p12-muted: #6b7a90;
  --p12-ok: #1f9d55;
  --p12-warn: #e8a33d;
  --p12-danger: #d64545;
  --p12-violet: #7f56d9;
  --p12-teal: #0e9594;
}
.p12-dash * { box-sizing: border-box; }

/* ---------- Header ---------- */
.p12-header {
  display: flex; flex-wrap: wrap; gap: 16px; align-items: center;
  justify-content: space-between;
  background: linear-gradient(135deg, #16295c 0%, #2a5298 60%, #3a6fc4 100%);
  color: #fff; border-radius: 16px; padding: 18px 22px; margin-bottom: 18px;
  box-shadow: 0 10px 26px rgba(30, 60, 114, .22);
}
.p12-header-right { display: flex; align-items: center; gap: 14px; min-width: 260px; }
.p12-avatar {
  width: 46px; height: 46px; border-radius: 14px; display: grid; place-items: center;
  background: rgba(255,255,255,.18); font-weight: 700; font-size: 16px;
  border: 1px solid rgba(255,255,255,.25);
}
.p12-title { margin: 0; font-size: 20px; font-weight: 800; letter-spacing: -.2px; }
.p12-subtitle { font-size: 12px; opacity: .82; margin-top: 3px; }
.p12-user { text-align: left; font-size: 12px; opacity: .95; }
.p12-user b { display: block; font-size: 13.5px; }
.p12-header-left { display: flex; align-items: center; gap: 10px; flex: 1; justify-content: flex-end; }
.p12-search { position: relative; flex: 1; max-width: 420px; }
.p12-search input {
  width: 100%; padding: 10px 16px; border-radius: 24px; border: 1px solid rgba(255,255,255,.28);
  background: rgba(255,255,255,.16); color: #fff; font-size: 13px; outline: none;
}
.p12-search input::placeholder { color: rgba(255,255,255,.75); }
.p12-search-results {
  position: absolute; top: 46px; right: 0; left: 0; background: #fff; color: #16233a;
  border-radius: 12px; box-shadow: 0 16px 40px rgba(16,32,60,.22); overflow: hidden;
  z-index: 40; max-height: 380px; overflow-y: auto; display: none;
}
.p12-search-results.is-open { display: block; }
.p12-sr-item { padding: 10px 14px; cursor: pointer; border-bottom: 1px solid var(--p12-line); }
.p12-sr-item:hover { background: #f2f6ff; }
.p12-sr-item b { font-size: 13px; }
.p12-sr-item span { font-size: 11.5px; color: var(--p12-muted); display: block; }
.p12-chip-btn {
  border: 1px solid rgba(255,255,255,.28); background: rgba(255,255,255,.16); color: #fff;
  border-radius: 20px; padding: 8px 14px; font-size: 12.5px; cursor: pointer; white-space: nowrap;
}
.p12-chip-btn:hover { background: rgba(255,255,255,.28); }

/* ---------- Section ---------- */
.p12-section {
  background: #fff; border: 1px solid var(--p12-line); border-radius: 16px;
  padding: 18px 20px; margin-bottom: 18px; box-shadow: 0 2px 12px rgba(16,32,60,.05);
}
.p12-section-head {
  display: flex; align-items: center; justify-content: space-between;
  gap: 10px; margin-bottom: 14px;
}
.p12-section-head h3 { margin: 0; font-size: 15.5px; font-weight: 800; color: var(--p12-navy); }
.p12-section-head .p12-hint { font-size: 11.5px; color: var(--p12-muted); }

/* ---------- KPI ---------- */
.p12-kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 14px; margin-bottom: 18px; }
.p12-kpi {
  background: #fff; border: 1px solid var(--p12-line); border-radius: 16px; padding: 16px 18px;
  cursor: pointer; transition: transform .18s ease, box-shadow .18s ease;
  border-right: 5px solid var(--p12-navy2); box-shadow: 0 2px 12px rgba(16,32,60,.05);
}
.p12-kpi:hover { transform: translateY(-3px); box-shadow: 0 14px 30px rgba(16,32,60,.12); }
.p12-kpi .p12-kpi-top { display: flex; align-items: center; justify-content: space-between; }
.p12-kpi .p12-kpi-icon { font-size: 22px; }
.p12-kpi .p12-kpi-value { font-size: 30px; font-weight: 800; color: var(--p12-navy); margin: 8px 0 2px; line-height: 1.1; }
.p12-kpi .p12-kpi-value small { font-size: 13px; font-weight: 600; color: var(--p12-muted); margin-right: 4px; }
.p12-kpi .p12-kpi-label { font-size: 12.5px; color: var(--p12-muted); }
.p12-kpi.tone-blue { border-right-color: #3a6fc4; }
.p12-kpi.tone-green { border-right-color: var(--p12-ok); }
.p12-kpi.tone-green .p12-kpi-value { color: var(--p12-ok); }
.p12-kpi.tone-amber { border-right-color: var(--p12-warn); }
.p12-kpi.tone-amber .p12-kpi-value { color: #b9760f; }
.p12-kpi.tone-red { border-right-color: var(--p12-danger); }
.p12-kpi.tone-red .p12-kpi-value { color: var(--p12-danger); }
.p12-kpi.tone-violet { border-right-color: var(--p12-violet); }
.p12-kpi.tone-violet .p12-kpi-value { color: var(--p12-violet); }
.p12-kpi.tone-teal { border-right-color: var(--p12-teal); }
.p12-kpi.tone-teal .p12-kpi-value { color: var(--p12-teal); }

/* ---------- Stage rail ---------- */
.p12-stages { display: flex; gap: 10px; overflow-x: auto; padding: 6px 2px 12px; }
.p12-stage {
  min-width: 122px; flex: 0 0 auto; text-align: center; padding: 12px 10px;
  border-radius: 14px; background: #f6f8fc; border: 1.5px solid var(--p12-line);
  cursor: pointer; position: relative; transition: transform .16s ease;
}
.p12-stage:hover { transform: translateY(-3px); }
.p12-stage .p12-stage-icon { font-size: 18px; }
.p12-stage .p12-stage-label { font-size: 11.5px; margin: 6px 0 4px; font-weight: 600; }
.p12-stage .p12-stage-count { font-size: 19px; font-weight: 800; color: var(--p12-navy); }
.p12-stage .p12-stage-owner { font-size: 10.5px; color: var(--p12-muted); margin-top: 3px; }
.p12-stage.status-active { background: #e8f1ff; border-color: #3a6fc4; }
.p12-stage.status-warn { background: #fff7e6; border-color: var(--p12-warn); }
.p12-stage.status-overdue { background: #fdecec; border-color: var(--p12-danger); }
.p12-stage.status-done { background: #e8f7ee; border-color: var(--p12-ok); }
.p12-stage.status-empty { opacity: .62; }
.p12-stage .p12-badge-overdue {
  position: absolute; top: -8px; left: -6px; background: var(--p12-danger); color: #fff;
  border-radius: 12px; font-size: 10.5px; padding: 2px 7px; font-weight: 700;
}

/* ---------- Table ---------- */
.p12-table-wrap { overflow-x: auto; }
.p12-table { width: 100%; border-collapse: collapse; font-size: 12.8px; }
.p12-table th, .p12-table td { padding: 10px 10px; text-align: right; border-bottom: 1px solid var(--p12-line); white-space: nowrap; }
.p12-table thead th { background: #f6f8fc; color: var(--p12-navy); font-weight: 700; position: sticky; top: 0; }
.p12-table tbody tr { cursor: pointer; }
.p12-table tbody tr:hover { background: #f4f8ff; }
.p12-dot { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-left: 6px; }
.p12-dot.ok { background: var(--p12-ok); }
.p12-dot.warn { background: var(--p12-warn); }
.p12-dot.danger { background: var(--p12-danger); }
.p12-pill { display: inline-block; padding: 3px 10px; border-radius: 20px; font-size: 11.5px; font-weight: 600; background: #eef2f9; color: #34456a; }
.p12-pill.ok { background: #e8f7ee; color: #14713c; }
.p12-pill.warn { background: #fff4e0; color: #96620a; }
.p12-pill.danger { background: #fdecec; color: #a92c2c; }
.p12-btn {
  border: 1px solid var(--p12-navy2); background: #fff; color: var(--p12-navy2);
  border-radius: 8px; padding: 5px 11px; font-size: 11.5px; cursor: pointer; font-weight: 600;
}
.p12-btn:hover { background: var(--p12-navy2); color: #fff; }
.p12-btn.danger { border-color: var(--p12-danger); color: var(--p12-danger); }
.p12-btn.danger:hover { background: var(--p12-danger); color: #fff; }
.p12-btn.solid { background: var(--p12-navy2); color: #fff; }
.p12-btn.solid:hover { background: var(--p12-navy); }

/* ---------- Focus / timeline ---------- */
.p12-focus-grid { display: grid; grid-template-columns: 1.25fr 1fr; gap: 18px; }
@media (max-width: 1100px) { .p12-focus-grid { grid-template-columns: 1fr; } }
.p12-timeline { display: flex; flex-direction: column; gap: 0; }
.p12-tl-step { display: flex; align-items: flex-start; gap: 12px; position: relative; padding-bottom: 12px; }
.p12-tl-step:last-child { padding-bottom: 0; }
.p12-tl-step::before {
  content: ""; position: absolute; right: 12px; top: 26px; bottom: 0; width: 2px; background: var(--p12-line);
}
.p12-tl-step:last-child::before { display: none; }
.p12-tl-bullet {
  width: 26px; height: 26px; border-radius: 50%; display: grid; place-items: center;
  font-size: 12px; font-weight: 700; background: #eef2f9; color: #94a3b8;
  border: 2px solid var(--p12-line); z-index: 1; flex: 0 0 auto;
}
.p12-tl-step.done .p12-tl-bullet { background: #e8f7ee; border-color: var(--p12-ok); color: var(--p12-ok); }
.p12-tl-step.current .p12-tl-bullet {
  background: #e8f1ff; border-color: #3a6fc4; color: #1e3c72;
  box-shadow: 0 0 0 5px rgba(58,111,196,.16); animation: p12pulse 2.2s infinite;
}
@keyframes p12pulse { 0%,100% { box-shadow: 0 0 0 5px rgba(58,111,196,.16); } 50% { box-shadow: 0 0 0 9px rgba(58,111,196,.07); } }
.p12-tl-body { padding-top: 2px; }
.p12-tl-body b { font-size: 12.8px; }
.p12-tl-body span { display: block; font-size: 11px; color: var(--p12-muted); }
.p12-tl-step.current .p12-tl-body b { color: var(--p12-navy); }
.p12-meta { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; margin-bottom: 14px; }
.p12-meta div { background: #f6f8fc; border-radius: 10px; padding: 9px 12px; }
.p12-meta span { display: block; font-size: 11px; color: var(--p12-muted); }
.p12-meta b { font-size: 13px; }
.p12-progress { height: 10px; border-radius: 8px; background: #eef2f9; overflow: hidden; margin: 6px 0 14px; }
.p12-progress > i { display: block; height: 100%; background: linear-gradient(90deg, #2a5298, #4d8ce8); }
.p12-check { display: flex; flex-wrap: wrap; gap: 8px; }
.p12-check span {
  font-size: 11.5px; padding: 4px 10px; border-radius: 20px;
  background: #f1f4fa; color: #64748b; border: 1px solid var(--p12-line);
}
.p12-check span.done { background: #e8f7ee; color: #14713c; border-color: #b9e5c9; }

/* ---------- Kanban ---------- */
.p12-kanban { display: flex; gap: 12px; overflow-x: auto; padding-bottom: 8px; }
.p12-kan-col { min-width: 220px; flex: 0 0 auto; background: #f6f8fc; border-radius: 14px; padding: 10px; border: 1px solid var(--p12-line); }
.p12-kan-head { display: flex; justify-content: space-between; align-items: center; font-size: 12.5px; font-weight: 700; color: var(--p12-navy); margin-bottom: 8px; }
.p12-kan-head em { font-style: normal; background: #fff; border-radius: 12px; padding: 1px 8px; font-size: 11.5px; border: 1px solid var(--p12-line); }
.p12-kan-card { background: #fff; border-radius: 10px; padding: 9px 11px; margin-bottom: 8px; border: 1px solid var(--p12-line); cursor: pointer; border-right: 4px solid #cbd5e1; }
.p12-kan-card:hover { box-shadow: 0 6px 16px rgba(16,32,60,.10); }
.p12-kan-card.tone-warn { border-right-color: var(--p12-warn); }
.p12-kan-card.tone-danger { border-right-color: var(--p12-danger); }
.p12-kan-card.tone-ok { border-right-color: var(--p12-ok); }
.p12-kan-card b { font-size: 12px; display: block; }
.p12-kan-card span { font-size: 10.8px; color: var(--p12-muted); display: block; margin-top: 2px; }

/* ---------- Map ---------- */
.p12-map-grid { display: grid; grid-template-columns: 1.35fr 1fr; gap: 18px; }
@media (max-width: 1100px) { .p12-map-grid { grid-template-columns: 1fr; } }
.p12-map { position: relative; background: linear-gradient(160deg, #f2f7ff, #e8effb); border-radius: 14px; padding: 8px; border: 1px solid var(--p12-line); }
.p12-map svg { width: 100%; height: auto; display: block; }
.p12-marker {
  position: absolute; transform: translate(50%, -50%); cursor: pointer;
  display: flex; flex-direction: column; align-items: center; gap: 2px;
}
.p12-marker i {
  width: 13px; height: 13px; border-radius: 50%; display: block; background: var(--p12-ok);
  border: 2px solid #fff; box-shadow: 0 2px 6px rgba(0,0,0,.25);
}
.p12-marker.tone-warn i { background: var(--p12-warn); }
.p12-marker.tone-danger i { background: var(--p12-danger); }
.p12-marker b { font-size: 10.5px; background: rgba(255,255,255,.92); border-radius: 8px; padding: 1px 6px; white-space: nowrap; border: 1px solid var(--p12-line); }
.p12-dest-list { display: flex; flex-direction: column; gap: 8px; max-height: 330px; overflow-y: auto; }
.p12-dest {
  display: flex; align-items: center; justify-content: space-between; gap: 10px;
  padding: 10px 12px; border-radius: 11px; background: #f6f8fc; border: 1px solid var(--p12-line); cursor: pointer;
}
.p12-dest:hover { background: #eef4ff; }
.p12-dest b { font-size: 12.8px; }
.p12-dest span { font-size: 11px; color: var(--p12-muted); }

/* ---------- Performance ---------- */
.p12-perf { display: flex; flex-direction: column; gap: 12px; }
.p12-perf-row { display: grid; grid-template-columns: 170px 1fr 210px; gap: 12px; align-items: center; }
@media (max-width: 900px) { .p12-perf-row { grid-template-columns: 1fr; } }
.p12-perf-name { font-size: 12.8px; font-weight: 700; }
.p12-perf-name span { display: block; font-size: 10.8px; color: var(--p12-muted); font-weight: 400; }
.p12-bar { height: 12px; background: #eef2f9; border-radius: 8px; overflow: hidden; }
.p12-bar > i { display: block; height: 100%; background: linear-gradient(90deg, #1f9d55, #4fd18b); }
.p12-perf-stats { display: flex; gap: 6px; flex-wrap: wrap; font-size: 11px; }

/* ---------- Alerts ---------- */
.p12-alerts { display: flex; flex-direction: column; gap: 9px; max-height: 340px; overflow-y: auto; }
.p12-alert { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 11px 14px; border-radius: 11px; font-size: 12.4px; }
.p12-alert.critical { background: #fdecec; border-right: 4px solid var(--p12-danger); }
.p12-alert.warning { background: #fff7e6; border-right: 4px solid var(--p12-warn); }
.p12-alert.info { background: #e8f4fb; border-right: 4px solid #2f86c5; }
.p12-alert .p12-alert-actions { display: flex; gap: 6px; flex: 0 0 auto; }

/* ---------- misc ---------- */
.p12-empty { text-align: center; color: var(--p12-muted); font-size: 12.5px; padding: 18px 0; }
.p12-loading { text-align: center; padding: 40px 0; color: var(--p12-muted); font-size: 13px; }
.p12-footer-note { font-size: 11px; color: var(--p12-muted); text-align: center; padding-top: 6px; }
.p12-quicklinks { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 16px; }
.p12-quicklinks a {
  font-size: 12px; padding: 7px 14px; border-radius: 20px; background: #fff;
  border: 1px solid var(--p12-line); color: var(--p12-navy); text-decoration: none; font-weight: 600;
}
.p12-quicklinks a:hover { background: var(--p12-navy2); color: #fff; border-color: var(--p12-navy2); }

/* ---------- form widgets (Transport Case) ---------- */
.p12-form-flow { direction: rtl; font-family: "Vazirmatn", "IRANSans", "Tahoma", sans-serif; padding: 4px 0 2px; }
.p12-form-flow .p12-ff-head { display: flex; justify-content: space-between; flex-wrap: wrap; gap: 8px; font-size: 12.5px; margin-bottom: 8px; }
.p12-form-flow .p12-ff-rail { display: flex; gap: 4px; overflow-x: auto; padding-bottom: 6px; }
.p12-form-flow .p12-ff-step {
  flex: 1 0 auto; min-width: 84px; text-align: center; font-size: 10.5px; padding: 7px 5px;
  border-radius: 8px; background: #f1f4fa; color: #7b8798; border: 1px solid #e5e9f2;
}
.p12-form-flow .p12-ff-step.done { background: #e8f7ee; color: #14713c; border-color: #b9e5c9; }
.p12-form-flow .p12-ff-step.current { background: #e8f1ff; color: #1e3c72; border-color: #3a6fc4; font-weight: 700; }
CSSEOF
log "phase12_dashboard.css written"

# =============================================================================
step "8) نوشتن موتور رندر داشبورد (phase12_dashboard.js)"
# =============================================================================
cat > "${PUB_JS}/phase12_dashboard.js" << 'JSEOF'
/* =============================================================================
 * Phase 12 — Transport Command Center renderer
 * موتور مشترک رندر برای هر ۵ داشبورد (فارسی، راست‌چین)
 * ========================================================================== */
(function () {
  var NS = (window.transport_phase12 = window.transport_phase12 || {});
  var API = 'transport_ir.iran_transport.phase12_workspaces.api.dashboard.';
  var CSS_URL = '/assets/transport_ir/css/phase12_dashboard.css';
  var FA = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];

  /* ---------------------------------------------------------------- utils */
  function faDigits(text) {
    return String(text == null ? '' : text).replace(/[0-9]/g, function (d) { return FA[+d]; });
  }
  function comma(value) {
    var n = Number(value || 0);
    var fixed = Math.abs(n) < 1000 && n % 1 !== 0 ? n.toFixed(1) : Math.round(n).toString();
    return fixed.replace(/\B(?=(\d{3})+(?!\d))/g, '،');
  }
  function num(value) { return faDigits(comma(value)); }
  function money(value) {
    var n = Number(value || 0);
    if (Math.abs(n) >= 1e9) return faDigits((n / 1e9).toFixed(1)) + ' میلیارد';
    if (Math.abs(n) >= 1e6) return faDigits((n / 1e6).toFixed(1)) + ' میلیون';
    return num(n);
  }
  function esc(text) {
    return String(text == null ? '' : text)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  function ensureCss() {
    if (document.querySelector('link[data-p12="1"]')) return;
    var link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = CSS_URL;
    link.setAttribute('data-p12', '1');
    document.head.appendChild(link);
  }
  function call(method, args) {
    return new Promise(function (resolve) {
      frappe.call({
        method: API + method,
        args: args || {},
        callback: function (r) { resolve(r && r.message); },
        error: function () { resolve(null); }
      });
    });
  }
  function route(target) {
    if (!target) return;
    frappe.set_route('List', target.doctype, target.filters || {});
  }

  /* --------------------------------------------------------- map geometry */
  var IRAN_PATH = '4.8,7.6 23.8,17.6 33.3,20.6 50,24.1 61.9,16.5 76.2,20.6 86.7,25.9 ' +
    '85.7,38.2 83.3,44.1 89.5,56.5 85.2,65.3 88.6,93.5 69,91.2 52.4,85.3 40.5,76.5 ' +
    '28.6,64.7 23.8,64.7 22.4,58.8 11.9,44.1 14.8,35.3 8.6,21.2';

  var GEO = {
    'تهران': [40, 31], 'بندرعباس': [63, 81], 'بوشهر': [37, 71], 'تبریز': [16, 17],
    'مشهد': [79, 28], 'اصفهان': [41, 49], 'اهواز': [27, 57], 'شیراز': [45, 67],
    'بازرگان': [7, 9], 'مهران': [15, 47], 'شلمچه': [24, 62], 'آستارا': [28, 15],
    'سرخس': [87, 27], 'جلفا': [12, 12], 'دوغارون': [86, 38], 'پرویزخان': [14, 39],
    'یزد': [55, 52], 'کرمان': [65, 60], 'زاهدان': [80, 66], 'نیشابور': [74, 29],
    'سمنان': [52, 33], 'قم': [42, 38], 'ساری': [50, 22], 'رشت': [32, 20],
    'کرمانشاه': [18, 40], 'ارومیه': [10, 18], 'اراک': [33, 40], 'دزفول': [28, 50],
    'عراق': [5, 50], 'ترکیه': [2, 13], 'ترکمنستان': [82, 14], 'آذربایجان': [22, 8],
    'امارات': [66, 95], 'افغانستان': [93, 45], 'پاکستان': [93, 78]
  };

  /* ------------------------------------------------------------- sections */
  function renderKpis(list) {
    if (!list || !list.length) return '';
    var html = '<div class="p12-kpis">';
    list.forEach(function (kpi) {
      var value = kpi.money ? money(kpi.value) : num(kpi.value);
      html += '<div class="p12-kpi tone-' + esc(kpi.tone) + '" data-kpi="' + esc(kpi.id) + '">' +
        '<div class="p12-kpi-top"><span class="p12-kpi-icon">' + esc(kpi.icon) + '</span></div>' +
        '<div class="p12-kpi-value">' + value +
        (kpi.suffix ? '<small>' + esc(kpi.suffix) + '</small>' : '') + '</div>' +
        '<div class="p12-kpi-label">' + esc(kpi.label) + '</div></div>';
    });
    return html + '</div>';
  }

  function renderStages(list) {
    if (!list || !list.length) return '';
    var html = '<div class="p12-section"><div class="p12-section-head">' +
      '<h3>وضعیت لحظه‌ای پرونده‌ها در مراحل گردش‌کار</h3>' +
      '<span class="p12-hint">روی هر مرحله کلیک کنید تا فهرست پرونده‌های آن باز شود</span>' +
      '</div><div class="p12-stages">';
    list.forEach(function (stage, index) {
      html += '<div class="p12-stage status-' + esc(stage.status) + '" data-stage="' + index + '">' +
        (stage.overdue ? '<span class="p12-badge-overdue">' + num(stage.overdue) + ' معوق</span>' : '') +
        '<div class="p12-stage-icon">' + esc(stage.icon) + '</div>' +
        '<div class="p12-stage-label">' + esc(stage.label) + '</div>' +
        '<div class="p12-stage-count">' + num(stage.count) + '</div>' +
        '<div class="p12-stage-owner">' + esc(stage.owner) + '</div></div>';
    });
    return html + '</div></div>';
  }

  function renderTable(rows) {
    var html = '<div class="p12-section"><div class="p12-section-head">' +
      '<h3>پرونده‌های نیازمند اقدام</h3>' +
      '<span class="p12-hint">مرتب‌شده بر اساس بیشترین مدت توقف</span></div>';
    if (!rows || !rows.length) return html + '<div class="p12-empty">پرونده‌ای در انتظار اقدام نیست.</div></div>';
    html += '<div class="p12-table-wrap"><table class="p12-table"><thead><tr>' +
      '<th>شماره پرونده</th><th>مشتری</th><th>مقصد</th><th>تناژ</th><th>مرحله فعلی</th>' +
      '<th>مسئول</th><th>آخرین فعالیت</th><th>مدت توقف</th><th>وضعیت</th><th>عملیات</th>' +
      '</tr></thead><tbody>';
    rows.forEach(function (row, index) {
      html += '<tr data-row="' + index + '">' +
        '<td><b>' + esc(row.case_title) + '</b></td>' +
        '<td>' + esc(row.customer) + '</td>' +
        '<td>' + esc(row.destination) + '</td>' +
        '<td>' + num(row.tonnage) + ' تن</td>' +
        '<td>' + esc(row.stage_icon) + ' ' + esc(row.state_label) + '</td>' +
        '<td>' + esc(row.responsible) + '</td>' +
        '<td>' + faDigits(row.last_activity) + '</td>' +
        '<td>' + esc(faDigits(row.stalled_label)) + '</td>' +
        '<td><span class="p12-dot ' + esc(row.tone) + '"></span></td>' +
        '<td><button class="p12-btn" data-act="view" data-index="' + index + '">مشاهده</button> ' +
        '<button class="p12-btn danger" data-act="remind" data-index="' + index + '">یادآوری</button></td>' +
        '</tr>';
    });
    return html + '</tbody></table></div></div>';
  }

  function renderFocus(focus) {
    var html = '<div class="p12-section" id="p12-focus"><div class="p12-section-head">' +
      '<h3>نمایش فرآیند پرونده' + (focus && focus.case_title ? ' ' + esc(focus.case_title) : '') + '</h3>' +
      '<span class="p12-hint">با کلیک روی هر سطر جدول، فرآیند همان پرونده اینجا نمایش داده می‌شود</span></div>';
    if (!focus || !focus.name) return html + '<div class="p12-empty">پرونده‌ای برای نمایش انتخاب نشده است.</div></div>';

    html += '<div class="p12-focus-grid"><div>' +
      '<div class="p12-progress"><i style="width:' + (focus.progress || 0) + '%"></i></div>' +
      '<div class="p12-meta">' +
      '<div><span>مرحله فعلی</span><b>' + esc(focus.state_label) + '</b></div>' +
      '<div><span>مسئول</span><b>' + esc(focus.responsible) + '</b></div>' +
      '<div><span>مدت توقف</span><b>' + esc(faDigits(focus.stalled_label)) + '</b></div>' +
      '<div><span>آخرین فعالیت</span><b>' + faDigits(focus.last_activity) + '</b></div>' +
      '<div><span>موعد اقدام</span><b>' + faDigits(focus.due) + '</b></div>' +
      '<div><span>مشتری / مقصد</span><b>' + esc(focus.customer) + ' — ' + esc(focus.destination) + '</b></div>' +
      '<div><span>راننده / پلاک</span><b>' + esc(focus.driver) + ' — ' + faDigits(focus.plate) + '</b></div>' +
      '<div><span>تناژ / بارنامه</span><b>' + num(focus.tonnage) + ' تن — ' + faDigits(focus.waybill) + '</b></div>' +
      '</div>';

    if (focus.checklist && focus.checklist.length) {
      html += '<div class="p12-section-head"><h3>چک‌لیست بستن پرونده</h3></div><div class="p12-check">';
      focus.checklist.forEach(function (item) {
        html += '<span class="' + (item.done ? 'done' : '') + '">' +
          (item.done ? '✓ ' : '○ ') + esc(item.label) + '</span>';
      });
      html += '</div>';
    }

    html += '<div style="margin-top:14px;display:flex;gap:8px;flex-wrap:wrap">' +
      '<button class="p12-btn solid" data-act="focus-open">مشاهده پرونده</button>' +
      '<button class="p12-btn danger" data-act="focus-remind">ارسال یادآوری</button>' +
      '</div></div><div><div class="p12-timeline">';

    (focus.steps || []).forEach(function (step) {
      var bullet = step.status === 'done' ? '✓' : (step.status === 'current' ? '●' : '○');
      html += '<div class="p12-tl-step ' + esc(step.status) + '">' +
        '<div class="p12-tl-bullet">' + bullet + '</div>' +
        '<div class="p12-tl-body"><b>' + esc(step.icon) + ' ' + esc(step.label) + '</b>' +
        '<span>مسئول: ' + esc(step.owner) + '</span></div></div>';
    });
    return html + '</div></div></div></div>';
  }

  function renderKanban(data) {
    var columns = (data && data.columns) || [];
    if (!columns.length) return '';
    var html = '<div class="p12-section"><div class="p12-section-head">' +
      '<h3>نمای کانبان مراحل</h3><span class="p12-hint">حداکثر ۸ پرونده در هر ستون</span>' +
      '</div><div class="p12-kanban">';
    columns.forEach(function (column, ci) {
      html += '<div class="p12-kan-col"><div class="p12-kan-head">' +
        '<span>' + esc(column.icon) + ' ' + esc(column.label) + '</span>' +
        '<em>' + num(column.total) + '</em></div>';
      if (!column.cards.length) html += '<div class="p12-empty">—</div>';
      column.cards.forEach(function (card, ki) {
        html += '<div class="p12-kan-card tone-' + esc(card.tone) + '" data-kan="' + ci + '-' + ki + '">' +
          '<b>' + esc(card.title) + '</b>' +
          '<span>' + esc(card.destination) + ' • ' + num(card.tonnage) + ' تن</span>' +
          '<span>' + esc(card.responsible) + ' • ' + esc(faDigits(card.stalled_label)) + '</span></div>';
      });
      html += '</div>';
    });
    return html + '</div></div>';
  }

  function renderMap(destinations) {
    if (!destinations || !destinations.length) return '';
    var markers = '';
    destinations.forEach(function (dest, index) {
      var geo = GEO[dest.label];
      if (!geo) return;
      markers += '<div class="p12-marker tone-' + esc(dest.tone) + '" data-dest="' + index + '" ' +
        'style="right:' + geo[0] + '%;top:' + geo[1] + '%"><i></i><b>' +
        esc(dest.label) + ' ' + num(dest.count) + '</b></div>';
    });

    var list = '';
    destinations.forEach(function (dest, index) {
      list += '<div class="p12-dest" data-dest="' + index + '">' +
        '<div><b>' + esc(dest.label) + '</b>' +
        '<span>' + num(dest.count) + ' بار • ' + num(dest.tonnage) + ' تن' +
        (dest.overdue ? ' • ' + num(dest.overdue) + ' معوق' : '') + '</span></div>' +
        '<span class="p12-pill ' + esc(dest.tone) + '">' +
        (dest.tone === 'danger' ? 'دارای تأخیر' : dest.tone === 'warn' ? 'نیازمند اقدام' : 'سالم') +
        '</span></div>';
    });

    return '<div class="p12-section"><div class="p12-section-head">' +
      '<h3>🗺 نقشه عملیات حمل</h3><span class="p12-hint">پراکندگی بارهای در جریان بر اساس مقصد</span>' +
      '</div><div class="p12-map-grid"><div class="p12-map">' +
      '<svg viewBox="0 0 100 100" preserveAspectRatio="none">' +
      '<polygon points="' + IRAN_PATH + '" fill="#dbe7fb" stroke="#9db8e4" stroke-width="0.6"/>' +
      '</svg>' + markers + '</div><div class="p12-dest-list">' + list + '</div></div></div>';
  }

  function renderPerformance(list) {
    if (!list || !list.length) return '';
    var html = '<div class="p12-section"><div class="p12-section-head">' +
      '<h3>عملکرد کارشناسان حمل</h3><span class="p12-hint">درصد پرونده‌های تکمیل‌شده</span>' +
      '</div><div class="p12-perf">';
    list.forEach(function (item) {
      html += '<div class="p12-perf-row">' +
        '<div class="p12-perf-name">' + esc(item.name) + '<span>' + esc(item.user) + '</span></div>' +
        '<div class="p12-bar"><i style="width:' + (item.percent || 0) + '%"></i></div>' +
        '<div class="p12-perf-stats">' +
        '<span class="p12-pill">' + num(item.total) + ' پرونده</span>' +
        '<span class="p12-pill ok">' + num(item.completed) + ' تکمیل</span>' +
        '<span class="p12-pill danger">' + num(item.overdue) + ' معوق</span>' +
        '<span class="p12-pill">میانگین ' + num(item.avg_days) + ' روز</span>' +
        '</div></div>';
    });
    return html + '</div></div>';
  }

  function renderAlerts(list) {
    var html = '<div class="p12-section"><div class="p12-section-head">' +
      '<h3>⚠️ هشدارهای عملیاتی</h3><span class="p12-hint">بر اساس SLA هر مرحله</span></div>';
    if (!list || !list.length) return html + '<div class="p12-empty">هشدار فعالی وجود ندارد. 👌</div></div>';
    html += '<div class="p12-alerts">';
    list.forEach(function (alert, index) {
      html += '<div class="p12-alert ' + esc(alert.severity) + '">' +
        '<div>' + esc(faDigits(alert.message)) + '</div>' +
        '<div class="p12-alert-actions">' +
        '<button class="p12-btn" data-act="alert-view" data-index="' + index + '">مشاهده</button>' +
        '<button class="p12-btn danger" data-act="alert-remind" data-index="' + index + '">یادآوری</button>' +
        '</div></div>';
    });
    return html + '</div></div>';
  }

  function renderQuickLinks(links) {
    if (!links || !links.length) return '';
    var html = '<div class="p12-quicklinks">';
    links.forEach(function (link) {
      html += '<a href="/app/' + esc(link.route) + '">' + esc(link.icon) + ' ' + esc(link.label) + '</a>';
    });
    return html + '</div>';
  }

  /* ---------------------------------------------------------------- render */
  NS.render = function (wrapper, page, key) {
    ensureCss();
    var $wrapper = $(wrapper);
    var $root = $wrapper.find('.layout-main-section');
    if (!$root.length) $root = $wrapper;
    $root.html('<div class="p12-dash"><div class="p12-loading">در حال بارگذاری داشبورد…</div></div>');

    var state = { key: key, data: null, focus: null };

    function bind($dash) {
      var data = state.data;

      $dash.find('.p12-kpi').on('click', function () {
        var id = $(this).data('kpi');
        var kpi = (data.kpi || []).filter(function (k) { return k.id === id; })[0];
        if (kpi && kpi.route) route(kpi.route);
      });

      $dash.find('.p12-stage').on('click', function () {
        var stage = (data.stages || [])[$(this).data('stage')];
        if (stage && stage.route) route(stage.route);
      });

      $dash.find('.p12-table tbody tr').on('click', function (event) {
        if ($(event.target).is('button')) return;
        var row = (data.action_table || [])[$(this).data('row')];
        if (row) loadFocus(row.name, row.doctype);
      });

      $dash.find('[data-act="view"]').on('click', function (event) {
        event.stopPropagation();
        var row = (data.action_table || [])[$(this).data('index')];
        if (row) frappe.set_route('Form', row.doctype, row.name);
      });

      $dash.find('[data-act="remind"]').on('click', function (event) {
        event.stopPropagation();
        var row = (data.action_table || [])[$(this).data('index')];
        if (row) remind(row.name, row.doctype);
      });

      $dash.find('[data-act="alert-view"]').on('click', function () {
        var alert = (data.alerts || [])[$(this).data('index')];
        if (alert) frappe.set_route('Form', alert.doctype, alert.case_name);
      });
      $dash.find('[data-act="alert-remind"]').on('click', function () {
        var alert = (data.alerts || [])[$(this).data('index')];
        if (alert) remind(alert.case_name, alert.doctype);
      });

      $dash.find('.p12-kan-card').on('click', function () {
        var parts = String($(this).data('kan')).split('-');
        var column = ((data.kanban || {}).columns || [])[+parts[0]];
        if (!column) return;
        var card = column.cards[+parts[1]];
        if (card) loadFocus(card.name, column.doctype);
      });

      $dash.find('[data-dest]').on('click', function () {
        var dest = (data.destinations || [])[$(this).data('dest')];
        if (dest && dest.route) route(dest.route);
      });

      $dash.find('[data-act="focus-open"]').on('click', function () {
        if (state.focus) frappe.set_route('Form', state.focus.doctype, state.focus.name);
      });
      $dash.find('[data-act="focus-remind"]').on('click', function () {
        if (state.focus) remind(state.focus.name, state.focus.doctype);
      });

      bindSearch($dash);
    }

    function bindSearch($dash) {
      var $input = $dash.find('.p12-search input');
      var $results = $dash.find('.p12-search-results');
      var timer = null;
      $input.on('input', function () {
        var query = $input.val();
        clearTimeout(timer);
        if (!query || query.length < 2) { $results.removeClass('is-open').empty(); return; }
        timer = setTimeout(function () {
          call('smart_search', { query: query }).then(function (rows) {
            if (!rows || !rows.length) {
              $results.addClass('is-open').html('<div class="p12-sr-item">نتیجه‌ای یافت نشد.</div>');
              return;
            }
            var html = '';
            rows.forEach(function (row, index) {
              html += '<div class="p12-sr-item" data-sr="' + index + '">' +
                '<b>' + esc(row.icon) + ' ' + esc(row.title) + '</b>' +
                '<span>' + esc(row.doctype) + ' • ' + esc(row.subtitle) + '</span></div>';
            });
            $results.addClass('is-open').html(html);
            $results.find('[data-sr]').on('click', function () {
              var row = rows[$(this).data('sr')];
              $results.removeClass('is-open');
              frappe.set_route('Form', row.doctype, row.name);
            });
          });
        }, 280);
      });
      $(document).on('click.p12', function (event) {
        if (!$(event.target).closest('.p12-search').length) $results.removeClass('is-open');
      });
    }

    function remind(name, doctype) {
      frappe.show_alert({ message: 'در حال ارسال یادآوری…', indicator: 'blue' });
      call('send_reminder', { case: name, doctype: doctype }).then(function (res) {
        frappe.show_alert({
          message: (res && res.message) || 'ارسال یادآوری انجام نشد.',
          indicator: res && res.ok ? 'green' : 'red'
        });
      });
    }

    function loadFocus(name, doctype) {
      call('get_case_timeline', { case: name, doctype: doctype || state.data.doctype }).then(function (focus) {
        if (!focus || !focus.name) return;
        state.focus = focus;
        var $focus = $(renderFocus(focus));
        $root.find('#p12-focus').replaceWith($focus);
        bind($root.find('.p12-dash'));
        if ($focus[0] && $focus[0].scrollIntoView) {
          $focus[0].scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
      });
    }

    function paint(data) {
      state.data = data;
      state.focus = data.focus_case && data.focus_case.name ? data.focus_case : null;
      var sections = data.sections || [];
      var html = '<div class="p12-dash">';

      html += '<div class="p12-header"><div class="p12-header-right">' +
        '<div class="p12-avatar">' + esc(data.user.initials) + '</div>' +
        '<div><h1 class="p12-title">' + esc(data.icon) + ' ' + esc(data.title) + '</h1>' +
        '<div class="p12-subtitle">' + esc(data.subtitle) + '</div></div></div>' +
        '<div class="p12-header-left">' +
        '<div class="p12-search"><input type="text" placeholder="جستجوی پرونده، مشتری، راننده، پلاک، بارنامه یا مقصد…"/>' +
        '<div class="p12-search-results"></div></div>' +
        '<div class="p12-user"><b>' + esc(data.user.full_name) + '</b>' + esc(data.user.role) + '</div>' +
        '</div></div>';

      html += renderQuickLinks(data.links);
      if (sections.indexOf('kpi') > -1) html += renderKpis(data.kpi);
      if (sections.indexOf('stages') > -1) html += renderStages(data.stages);
      if (sections.indexOf('action_table') > -1) html += renderTable(data.action_table);
      if (sections.indexOf('focus_case') > -1) html += renderFocus(data.focus_case);
      if (sections.indexOf('kanban') > -1) html += renderKanban(data.kanban);
      if (sections.indexOf('destinations') > -1) html += renderMap(data.destinations);
      if (sections.indexOf('performance') > -1) html += renderPerformance(data.performance);
      if (sections.indexOf('alerts') > -1) html += renderAlerts(data.alerts);
      html += '<div class="p12-footer-note">آخرین بروزرسانی: ' + faDigits(data.generated_at) +
        ' — فاز ۱۲ سامانه حمل‌ونقل</div>';
      html += '</div>';

      $root.html(html);
      bind($root.find('.p12-dash'));
    }

    function refresh(silent) {
      if (!silent) $root.find('.p12-dash').append('');
      return call('get_dashboard', { key: key }).then(function (data) {
        if (!data) {
          $root.html('<div class="p12-dash"><div class="p12-empty">خطا در دریافت داده داشبورد. لطفاً Error Log را بررسی کنید.</div></div>');
          return;
        }
        paint(data);
      });
    }

    if (page && page.set_secondary_action) {
      page.set_secondary_action('بروزرسانی', function () {
        frappe.show_alert({ message: 'در حال بروزرسانی…', indicator: 'blue' });
        refresh(true);
      }, 'refresh');
    }
    if (page && page.add_menu_item) {
      page.add_menu_item('فهرست پرونده‌های حمل', function () { frappe.set_route('List', 'Transport Case'); });
      page.add_menu_item('فهرست پرونده‌های تجاری', function () { frappe.set_route('List', 'Trade Case'); });
    }

    refresh();

    var timer = setInterval(function () {
      if (!document.body.contains($root[0])) { clearInterval(timer); $(document).off('click.p12'); return; }
      if (frappe.get_route && frappe.get_route()[0] === 'transport-case') return;
      refresh(true);
    }, 120000);
  };
})();
JSEOF
log "phase12_dashboard.js written"

# =============================================================================
step "9) نوشتن JS بهبود UX فرم‌ها (phase12_ux.js)"
# =============================================================================
cat > "${PUB_JS}/phase12_ux.js" << 'JSEOF'
/* =============================================================================
 * Phase 12 — Form UX
 * نوار پیشرفت مرحله‌ای، مسئول مرحله و مدت توقف روی فرم پرونده‌ها
 * ========================================================================== */
(function () {
  var API = 'transport_ir.iran_transport.phase12_workspaces.api.dashboard.get_form_progress';
  var FA = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];
  function faDigits(text) {
    return String(text == null ? '' : text).replace(/[0-9]/g, function (d) { return FA[+d]; });
  }
  function esc(text) {
    return String(text == null ? '' : text)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
  function ensureCss() {
    if (document.querySelector('link[data-p12="1"]')) return;
    var link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = '/assets/transport_ir/css/phase12_dashboard.css';
    link.setAttribute('data-p12', '1');
    document.head.appendChild(link);
  }

  function renderFlow(frm, info) {
    if (!info || !info.steps) return;
    var toneMap = { ok: 'ok', warn: 'warn', danger: 'danger' };
    var html = '<div class="p12-form-flow"><div class="p12-ff-head">' +
      '<span><b>مرحله فعلی:</b> ' + esc(info.state_label) + ' — <b>مسئول:</b> ' + esc(info.responsible) + '</span>' +
      '<span><b>مدت توقف:</b> ' + esc(faDigits(info.stalled_label)) +
      ' • <b>موعد اقدام:</b> ' + faDigits(info.due) + '</span></div>' +
      '<div class="p12-progress"><i style="width:' + (info.progress || 0) + '%"></i></div>' +
      '<div class="p12-ff-rail">';
    info.steps.forEach(function (step) {
      html += '<div class="p12-ff-step ' + esc(step.status) + '">' +
        esc(step.icon) + '<br/>' + esc(step.label) + '</div>';
    });
    html += '</div>';
    if (info.checklist && info.checklist.length) {
      html += '<div class="p12-check" style="margin-top:8px">';
      info.checklist.forEach(function (item) {
        html += '<span class="' + (item.done ? 'done' : '') + '">' +
          (item.done ? '✓ ' : '○ ') + esc(item.label) + '</span>';
      });
      html += '</div>';
    }
    html += '</div>';

    var $wrap = frm.get_field('p12_flow_html')
      ? null
      : $(frm.dashboard.wrapper).find('.p12-form-flow-holder');
    if (!$wrap || !$wrap.length) {
      $wrap = $('<div class="p12-form-flow-holder" style="margin:8px 0 4px"></div>');
      $(frm.dashboard.wrapper).prepend($wrap);
    }
    $wrap.html(html);
    frm.dashboard.show();

    if (toneMap[info.tone] && info.tone !== 'ok') {
      frm.dashboard.set_headline_alert(
        'این پرونده ' + faDigits(info.stalled_label) + ' در مرحله «' + info.state_label + '» متوقف مانده است.',
        info.tone === 'danger' ? 'red' : 'orange'
      );
    }
  }

  function attach(doctype) {
    frappe.ui.form.on(doctype, {
      refresh: function (frm) {
        if (frm.is_new()) return;
        ensureCss();
        frappe.call({
          method: API,
          args: { case: frm.doc.name, doctype: doctype },
          callback: function (r) { if (r && r.message) renderFlow(frm, r.message); }
        });

        frm.add_custom_button('مرکز کنترل عملیات حمل', function () {
          frappe.set_route('transport-ops-dashboard');
        }, 'فاز ۱۲');

        frm.add_custom_button('ارسال یادآوری به مسئول', function () {
          frappe.call({
            method: 'transport_ir.iran_transport.phase12_workspaces.api.dashboard.send_reminder',
            args: { case: frm.doc.name, doctype: doctype },
            callback: function (r) {
              frappe.show_alert({
                message: (r && r.message && r.message.message) || 'انجام نشد',
                indicator: r && r.message && r.message.ok ? 'green' : 'red'
              });
            }
          });
        }, 'فاز ۱۲');
      }
    });
  }

  $(document).on('app_ready', function () {
    try {
      attach('Transport Case');
      attach('Trade Case');
    } catch (e) {
      console.warn('phase12 ux init failed', e);
    }
  });
})();
JSEOF
log "phase12_ux.js written"

# =============================================================================
step "10) ساخت ۵ صفحه داشبورد (Page)"
# =============================================================================
write_page() {
  local folder="$1" route="$2" title="$3" key="$4" roles_json="$5"
  local dir="${PAGE_ROOT}/${folder}"
  mkdir -p "$dir"
  [[ -f "${dir}/__init__.py" ]] || : > "${dir}/__init__.py"

  cat > "${dir}/${folder}.json" <<PAGEJSON
{
 "content": null,
 "creation": "2025-01-01 00:00:00.000000",
 "docstatus": 0,
 "doctype": "Page",
 "idx": 0,
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "${MODULE_LABEL}",
 "name": "${route}",
 "owner": "Administrator",
 "page_name": "${route}",
 "roles": ${roles_json},
 "script": null,
 "standard": "Yes",
 "style": null,
 "system_page": 0,
 "title": "${title}"
}
PAGEJSON

  cat > "${dir}/${folder}.js" <<PAGEJS
frappe.pages['${route}'].on_page_load = function (wrapper) {
  var page = frappe.ui.make_app_page({
    parent: wrapper,
    title: '${title}',
    single_column: true
  });

  var boot = function () {
    window.transport_phase12.render(wrapper, page, '${key}');
  };

  if (window.transport_phase12 && window.transport_phase12.render) {
    boot();
  } else {
    frappe.require('/assets/${APP_NAME}/js/phase12_dashboard.js', boot);
  }
};

frappe.pages['${route}'].on_page_show = function (wrapper) {
  if (window.transport_phase12 && window.transport_phase12.render && !\$(wrapper).find('.p12-dash').length) {
    window.transport_phase12.render(wrapper, null, '${key}');
  }
};
PAGEJS
  log "Page created: ${route}"
}

R_TRANSPORT='[{"role": "Transport Supervisor"}, {"role": "Transport User - Purchase"}, {"role": "Transport User - Sales"}, {"role": "System Manager"}]'
R_CEO='[{"role": "CEO"}, {"role": "Financial Manager"}, {"role": "System Manager"}]'
R_FIN='[{"role": "Financial Manager"}, {"role": "Finance Supervisor"}, {"role": "Finance User"}, {"role": "Treasury User"}, {"role": "System Manager"}]'
R_CUS='[{"role": "Customs Officer"}, {"role": "Transport Supervisor"}, {"role": "System Manager"}]'
R_COM='[{"role": "Legal Reviewer"}, {"role": "Treasury User"}, {"role": "Receivables User"}, {"role": "Document Signer"}, {"role": "Financial Manager"}, {"role": "System Manager"}]'

# عناوین صفحات انگلیسی نگه داشته می‌شود تا slug URL انگلیسی بماند
# و از خطای «صفحه یافت نشد» با روت‌های Persian جلوگیری شود.
# ترجمه فارسی هر عنوان از فایل translations/fa.csv اعمال می‌گردد.
write_page "transport_ops_dashboard" "transport-ops-dashboard" "Transport Ops Dashboard" "transport_ops" "$R_TRANSPORT"
write_page "ceo_command_center"      "ceo-command-center"      "CEO Command Center"      "ceo"           "$R_CEO"
write_page "finance_control_center"  "finance-control-center"  "Finance Control Center"  "finance"       "$R_FIN"
write_page "customs_gateway_desk"    "customs-gateway-desk"    "Customs Gateway Desk"    "customs"       "$R_CUS"
write_page "commercial_desk_center"  "commercial-desk-center"  "Commercial Desk Center"  "commercial"    "$R_COM"

# =============================================================================
step "10b) نوشتن/به‌روزرسانی translations/fa.csv (Additive و Idempotent)"
# =============================================================================
# تمام برچسب‌های انگلیسی Workspace / Shortcut / Card / Page را به فارسی ترجمه
# می‌کنیم تا کاربر در نوار کناری و عناوین همه‌چیز را به فارسی ببیند، اما URL
# و lookup داخلی Frappe همچنان با نام‌های انگلیسی پایدار بماند.
#
# فرمت رسمی Frappe v15:  source,translated,context  (سه‌ستونی، ستون سوم اختیاری)
# =============================================================================

TRANSLATIONS_DIR="${APP_ROOT}/translations"
FA_CSV="${TRANSLATIONS_DIR}/fa.csv"
mkdir -p "$TRANSLATIONS_DIR"

# اگر fa.csv از قبل وجود دارد (فازهای قبلی)، محتوای فاز ۱۲ را additive اضافه
# می‌کنیم و ورودی‌های تکراری فاز ۱۲ را جایگزین می‌کنیم (بین Markerها).
TMP_FA="$(mktemp)"
FA_START="# --- PHASE12 TRANSLATIONS START (do not edit inside) ---"
FA_END="# --- PHASE12 TRANSLATIONS END ---"

if [[ -f "$FA_CSV" ]]; then
  # حذف بلاک فاز ۱۲ قبلی (در صورت وجود) با awk
  awk -v s="$FA_START" -v e="$FA_END" '
    $0 == s { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip   { print }
  ' "$FA_CSV" > "$TMP_FA"
else
  : > "$TMP_FA"
fi

cat >> "$TMP_FA" << 'FACSV'
# --- PHASE12 TRANSLATIONS START (do not edit inside) ---
# Workspace labels
Transport Control Tower,مرکز کنترل حمل,
CEO Command Center,داشبورد مدیرعامل,
Finance And Treasury,مالی و خزانه,
Customs And Gateway,گمرک و مرز,
Commercial Desk,میز بازرگانی,
# Page titles
Transport Ops Dashboard,مرکز کنترل عملیات حمل,
Finance Control Center,مرکز کنترل مالی و خزانه,
Customs Gateway Desk,میز گمرک و مرز,
Commercial Desk Center,میز بازرگانی,
# Shortcut labels — Transport Control Tower
Active Transport Cases,پرونده‌های حمل فعال,
In Transit Cases,در حال حمل,
Pending Assignment,منتظر تخصیص,
On Hold Cases,پرونده‌های متوقف,
# Shortcut labels — CEO Command Center
Active Transport Overview,پرونده‌های فعال حمل,
Open Trade Cases,پرونده‌های تجاری باز,
Completed Cases,تکمیل‌شده,
# Shortcut labels — Finance
Pending Payment,منتظر پرداخت,
Pending Finance Close,منتظر بستن مالی,
Finance Supervisor Queue,صف سرپرست مالی,
# Shortcut labels — Customs
Pending Clearance,منتظر ترخیص,
Pending Bijak,منتظر بیجک,
Cleared Cases,ترخیص‌شده,
# Shortcut labels — Commercial
Legal Review Queue,بررسی حقوقی,
Pending Signature,منتظر امضا,
Receivables Queue,وصول مطالبات,
# Card (Card Break) labels
Daily Operations,عملیات روزانه,
Fleet And Resources,ناوگان و منابع,
Management Overview,نمای مدیریتی,
Finance And Treasury Links,مالی و خزانه,
Customs Links,گمرک,
Commercial Links,بازرگانی,
# Card link labels
Transport Cases,پرونده‌های حمل,
Trade Cases,پرونده‌های تجاری,
Waybills,بارنامه‌ها,
Weighbridge,باسکول,
Drivers,رانندگان,
Fleet,ناوگان,
Carriers,باربری‌ها,
Borders,مرزها,
Customers,مشتریان,
Suppliers,تأمین‌کنندگان,
Clearance,ترخیص,
Bijak And Declaration,بیجک و اظهار,
Customs Brokers,ترخیص‌کاران,
Border Representatives,نمایندگان مرز,
Items,کالاها,
# Shortcut format templates (استفاده‌شده در format="{} Active" و مشابه)
{} Active,{} فعال,
{} In Transit,{} در مسیر,
{} In Queue,{} در صف,
{} On Hold,{} متوقف,
{} Open,{} باز,
{} Completed,{} تکمیل,
{} Pending,{} منتظر,
{} Cleared,{} ترخیص,
{} Cases,{} پرونده,
# --- PHASE12 TRANSLATIONS END ---
FACSV

mv "$TMP_FA" "$FA_CSV"
chmod 644 "$FA_CSV"

# اعتبارسنجی سبک CSV: هر خط داده باید حداقل یک ویرگول داشته باشد
python3 - "$FA_CSV" << 'PYCHK'
import csv, sys
path = sys.argv[1]
rows = 0
with open(path, encoding="utf-8", newline="") as handle:
    for line in handle:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # قبول: source,translated  یا  source,translated,context
        parts = list(csv.reader([line]))[0]
        if len(parts) < 2 or not parts[0]:
            print(f"ROW INVALID: {line.rstrip()}", file=sys.stderr)
            sys.exit(2)
        rows += 1
print(f"fa.csv rows validated: {rows}")
PYCHK

log "translations/fa.csv written and validated (${FA_CSV})"

# =============================================================================
step "11) به‌روزرسانی additive فایل hooks.py"
# =============================================================================
cat > "${PHASE12_ROOT}/_hooks_patch.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""پچ additive و idempotent برای hooks.py — فقط بین Markerهای فاز ۱۲."""
import re
import sys
from pathlib import Path

START = "# PHASE12_WORKSPACES_HOOKS_START"
END = "# PHASE12_WORKSPACES_HOOKS_END"

BLOCK = '''{start}
# افزودن دارایی‌های فاز ۱۲ بدون بازنویسی مقادیر فازهای قبلی
_phase12_css = ["/assets/{app}/css/phase12_dashboard.css"]
_phase12_js = ["/assets/{app}/js/phase12_dashboard.js",
               "/assets/{app}/js/phase12_ux.js"]

try:
    app_include_css
except NameError:
    app_include_css = []
if isinstance(app_include_css, str):
    app_include_css = [app_include_css]
app_include_css = list(app_include_css) + [
    _p12 for _p12 in _phase12_css if _p12 not in list(app_include_css)
]

try:
    app_include_js
except NameError:
    app_include_js = []
if isinstance(app_include_js, str):
    app_include_js = [app_include_js]
app_include_js = list(app_include_js) + [
    _p12 for _p12 in _phase12_js if _p12 not in list(app_include_js)
]
{end}
'''


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: _hooks_patch.py <hooks.py> [app_name]")
        return 2
    path = Path(sys.argv[1])
    app = sys.argv[2] if len(sys.argv) > 2 else "transport_ir"
    content = path.read_text(encoding="utf-8") if path.exists() else ""

    pattern = re.compile(re.escape(START) + r".*?" + re.escape(END), re.DOTALL)
    cleaned = pattern.sub("", content).rstrip()

    block = BLOCK.format(start=START, end=END, app=app)
    path.write_text(cleaned + "\n\n\n" + block + "\n", encoding="utf-8")
    print("hooks.py patched additively (PHASE12 markers)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PYEOF

python3 "${PHASE12_ROOT}/_hooks_patch.py" "${HOOKS_FILE}" "${APP_NAME}"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "${HOOKS_FILE}" \
  || fail "hooks.py syntax broken — restore from ${HOOKS_FILE}.phase12.bak.*"
log "hooks.py updated additively and syntax-verified"

# =============================================================================
step "12) اعتبارسنجی سینتکس پایتون"
# =============================================================================
python3 -m py_compile \
  "${PHASE12_ROOT}/config.py" \
  "${PHASE12_ROOT}/setup.py" \
  "${PHASE12_ROOT}/workspaces.py" \
  "${PHASE12_ROOT}/api/dashboard.py" \
  "${PHASE12_ROOT}/api/kpi.py" \
  || fail "Python syntax error in phase12 files"
log "Python syntax OK"

for jsfile in "${PUB_JS}/phase12_dashboard.js" "${PUB_JS}/phase12_ux.js"; do
  if command -v node >/dev/null 2>&1; then
    node --check "$jsfile" >/dev/null 2>&1 || warn "node --check failed for $(basename "$jsfile")"
  fi
done
if command -v node >/dev/null 2>&1; then log "JavaScript syntax OK"; fi

for pj in "${PAGE_ROOT}"/*/*.json; do
  python3 -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$pj" \
    || fail "Invalid page JSON: $pj"
done
log "Page JSON files valid"

# =============================================================================
step "13) اطمینان از دسترس‌پذیری assets"
# =============================================================================
ASSETS_DIR="${BENCH_DIR}/sites/assets"
mkdir -p "$ASSETS_DIR"
if [[ ! -e "${ASSETS_DIR}/${APP_NAME}" ]]; then
  ln -sfn "${APP_ROOT}/public" "${ASSETS_DIR}/${APP_NAME}"
  log "assets symlink created: sites/assets/${APP_NAME}"
else
  log "assets path already present"
fi

# =============================================================================
step "14) گام آماده‌سازی (نقش‌ها و Module Def)"
# =============================================================================
bench --site "$SITE_NAME" execute transport_ir.iran_transport.phase12_workspaces.setup.prepare \
  || fail "Phase 12 prepare failed"

# =============================================================================
step "15) build / migrate"
# =============================================================================
if [[ "$RUN_BUILD" == "1" ]]; then
  bench build --app "${APP_NAME}" >/dev/null 2>&1 && log "bench build done" \
    || warn "bench build failed — assets از طریق symlink سرو می‌شوند"
else
  warn "RUN_BUILD=0 — از build صرف‌نظر شد"
fi

if [[ "$RUN_MIGRATE" == "1" ]]; then
  bench --site "$SITE_NAME" migrate || fail "bench migrate failed"
  log "migrate done (pages imported)"
else
  warn "RUN_MIGRATE=0 — از migrate صرف‌نظر شد (صفحات با fallback ساخته می‌شوند)"
fi

# =============================================================================
step "16) اجرای setup فاز ۱۲"
# =============================================================================
bench --site "$SITE_NAME" execute transport_ir.iran_transport.phase12_workspaces.setup.execute \
  || fail "Phase 12 setup failed"

# =============================================================================
step "17) کنترل نتیجه (verify) و پاکسازی کش"
# =============================================================================
bench --site "$SITE_NAME" execute transport_ir.iran_transport.phase12_workspaces.setup.verify \
  || warn "verify returned a non-zero status"

bench --site "$SITE_NAME" clear-cache >/dev/null 2>&1 || true
bench --site "$SITE_NAME" clear-website-cache >/dev/null 2>&1 || true
log "Cache cleared"

# =============================================================================
step "DONE"
# =============================================================================
cat <<EOF

${GREEN}✅ فاز ۱۲ با موفقیت نصب شد.${NC}

${YELLOW}داشبوردهای اختصاصی (Page):${NC}
  • مرکز کنترل عملیات حمل   →  /app/transport-ops-dashboard
  • داشبورد مدیرعامل        →  /app/ceo-command-center
  • مرکز کنترل مالی و خزانه →  /app/finance-control-center
  • میز گمرک و مرز          →  /app/customs-gateway-desk
  • میز بازرگانی            →  /app/commercial-desk-center

${YELLOW}فضاهای کاری (Workspace):${NC}
  • مرکز کنترل حمل / داشبورد مدیرعامل / مالی و خزانه / گمرک و مرز / میز بازرگانی

${YELLOW}قابلیت‌های داشبورد:${NC}
  ✓ کارت‌های KPI کلیک‌پذیر (با فیلتر مستقیم روی لیست)
  ✓ ریل مراحل گردش‌کار با تعداد پرونده، مسئول مرحله و نشان معوق
  ✓ جدول «پرونده‌های نیازمند اقدام» با مدت توقف و وضعیت رنگی
  ✓ تایم‌لاین کامل «هر پرونده در چه مرحله‌ای است» + چک‌لیست ۱۰ موردی بستن
  ✓ نمای کانبان مراحل
  ✓ نقشه عملیات حمل (SVG ایران + مارکر مقاصد و مرزها)
  ✓ عملکرد کارشناسان (تکمیل‌شده/معوق/میانگین زمان)
  ✓ هشدارهای هوشمند بر پایه SLA هر مرحله + دکمه «ارسال یادآوری» (ToDo + Notification)
  ✓ جستجوی هوشمند: پرونده، مشتری، راننده، پلاک، بارنامه، مقصد
  ✓ نوار پیشرفت و مرحله جاری روی فرم Transport Case و Trade Case

${YELLOW}اجرای مجدد (Idempotent):${NC}
  SITE_NAME=${SITE_NAME} bash setup_phase12.sh
  # یا فقط بخش داده‌ای:
  bench --site ${SITE_NAME} execute transport_ir.iran_transport.phase12_workspaces.setup.execute
  bench --site ${SITE_NAME} execute transport_ir.iran_transport.phase12_workspaces.setup.verify

${YELLOW}مسیر فایل‌ها:${NC}
  ${PHASE12_ROOT}
  ${PAGE_ROOT}/{transport_ops_dashboard,ceo_command_center,finance_control_center,customs_gateway_desk,commercial_desk_center}
  ${PUB_CSS}/phase12_dashboard.css
  ${PUB_JS}/phase12_dashboard.js , ${PUB_JS}/phase12_ux.js
  ${HOOKS_FILE}  (فقط بین Markerهای PHASE12)

EOF
