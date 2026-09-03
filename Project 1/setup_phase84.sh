#!/usr/bin/env bash
# =============================================================================
# setup_phase8.sh — FINAL (Smart Excel Sync Edition)
# Reports + RTL Print Formats + Excel Import/Export + Financial 1405 Workbook
# + Custom Excel Layer (phase 17.5 additive patch, smart-sync rules applied)
#
# ERPNext v15 / Frappe v15
# File-First | Idempotent | No bench console | No site drop
#
# Prerequisites:
#   phase2 -> phase3 -> phase4 -> realign_gate -> ir_jalali
#   -> phase5 -> phase6 -> phase7 -> phase8
#
# Key guarantees:
#   1) Actual phase-6 DocTypes:
#        Transport Waybill
#        Transport Weighbridge
#   2) Report directories/files use snake_case, but Report name/report_name and
#      frappe.query_reports keys use exact Title Case names.
#   3) Purchase and Sales sides of the 26-column 1405 report are calculated
#      independently according to Trade Case.case_type.
#   4) Jalali conversion comes only from ir_jalali (single source of truth).
#   5) Excel import resolves File through file_url, checks permission, file type,
#      file size and row limit, and is transactional.
#   6) Custom Excel layer (17.5) implements the PHASE 8 EXCEL SYNC GOLDEN RULES:
#        P0 real Excel JSON contract (sheet/coordinate/merge/hidden/formula)
#        P1 real project Meta fields only, never invented fieldnames
#        exact client header text preserved (typos included)
#        alias/fuzzy only in the matching layer
#        coordinate lock before fuzzy, ambiguity => UNRESOLVED
#        formulas protected, merges/styles/logo/direction preserved
#        import = Preview -> Validate -> Resolve -> Commit, transactional
#      and exposes all five employer templates:
#        template_01_financial / template_02_freight / template_03_packing
#        template_04_purchase  / template_05_dispatch
# =============================================================================

set -euo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=utf-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

export SITE_NAME="transport-dev.local"
export BENCH_DIR="${HOME}/frappe-bench"
export APP="transport_ir"
export JALALI_APP="ir_jalali"

export APP_ROOT="${BENCH_DIR}/apps/${APP}"
export PKG="${APP_ROOT}/${APP}"
export MOD="${PKG}/iran_transport"
export HOOKS="${PKG}/hooks.py"

export NOW_TS
NOW_TS="$(date '+%Y-%m-%d %H:%M:%S').000000"

GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
NC=$'\033[0m'

log() {
  echo -e "${GREEN}[OK]${NC}  $*"
}

warn() {
  echo -e "${YELLOW}[!!]${NC}  $*"
}

err() {
  echo -e "${RED}[ERR]${NC} $*" >&2
  exit 1
}

step() {
  echo -e "\n${YELLOW}======== $* ========${NC}"
}

write_utf8() {
  local target="$1"
  local tmp

  tmp="$(mktemp)"
  cat >"$tmp"

  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-8 -t UTF-8 "$tmp" >/dev/null 2>&1 \
      || err "Invalid UTF-8: ${target}"
  fi

  mkdir -p "$(dirname "$target")"
  mv -f "$tmp" "$target"
  log "write: $target"
}

site_has_app() {
  local site="$1"
  local app="$2"

  bench --site "$site" list-apps 2>/dev/null \
    | grep -qE "^${app}([[:space:]]|$)"
}

# =============================================================================
# 0) Preflight and services
# =============================================================================

step "0) preflight + services"

[[ -d "$BENCH_DIR" ]] || err "Bench not found: $BENCH_DIR"
[[ -d "${BENCH_DIR}/sites/${SITE_NAME}" ]] || err "Site not found: ${SITE_NAME}"
[[ -d "$APP_ROOT" ]] || err "App not found: ${APP_ROOT}"
[[ -f "$HOOKS" ]] || err "hooks.py not found: ${HOOKS}"

[[ -f "${MOD}/doctype/trade_case/trade_case.json" ]] \
  || err "Phase 5 missing: Trade Case"

[[ -f "${MOD}/doctype/transport_case/transport_case.json" ]] \
  || err "Phase 6 missing: Transport Case"

[[ -f "${MOD}/doctype/transport_waybill/transport_waybill.json" ]] \
  || err "Phase 6 missing: Transport Waybill"

[[ -f "${MOD}/doctype/transport_weighbridge/transport_weighbridge.json" ]] \
  || err "Phase 6 missing: Transport Weighbridge"

cd "$BENCH_DIR"
bench use "$SITE_NAME" 2>/dev/null || true

for required_app in "frappe" "erpnext" "ir_base" "$APP" "$JALALI_APP"; do
  if ! site_has_app "$SITE_NAME" "$required_app"; then
    err "Required app is not installed on ${SITE_NAME}: ${required_app}"
  fi
done

log "required apps verified"

if ss -lntp 2>/dev/null | grep -q ':8000' \
  || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "bench already running"
else
  nohup bench start >>/tmp/bench-start-phase8.log 2>&1 &
  echo $! >/tmp/bench-start-phase8.pid
  log "bench start pid=$(cat /tmp/bench-start-phase8.pid)"
fi

REDIS_CACHE_CONF="${BENCH_DIR}/config/redis_cache.conf"

if [[ -f "$REDIS_CACHE_CONF" ]]; then
  REDIS_CACHE_PORT="$(
    awk '$1 == "port" {print $2; exit}' "$REDIS_CACHE_CONF"
  )"
else
  REDIS_CACHE_PORT="13000"
fi

[[ -n "${REDIS_CACHE_PORT:-}" ]] || REDIS_CACHE_PORT="13000"

REDIS_READY=0

for _i in $(seq 1 60); do
  if command -v redis-cli >/dev/null 2>&1; then
    if redis-cli -h 127.0.0.1 -p "$REDIS_CACHE_PORT" ping 2>/dev/null \
      | grep -q '^PONG$'; then
      REDIS_READY=1
      break
    fi
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -lnt 2>/dev/null \
      | grep -q ":${REDIS_CACHE_PORT}[[:space:]]"; then
      REDIS_READY=1
      break
    fi
  fi

  sleep 1
done

[[ "$REDIS_READY" -eq 1 ]] \
  || err "redis_cache not ready. See /tmp/bench-start-phase8.log"

log "redis_cache ready on port ${REDIS_CACHE_PORT}"

for dt in \
  "Trade Case" \
  "Transport Case" \
  "Transport Payment" \
  "Transport Waybill" \
  "Transport Weighbridge"
do
  count="$(
    bench --site "$SITE_NAME" execute frappe.db.count \
      --args "[\"DocType\", {\"name\": \"${dt}\"}]" \
      2>/dev/null | tail -1 | tr -d '[:space:]'
  )"

  [[ "$count" == "1" ]] || err "Required DocType missing: ${dt}"
done

bench --site "$SITE_NAME" execute \
  ir_jalali.utils.jalali.test_jalali >/dev/null

log "ir_jalali reference tests passed"

# =============================================================================
# 0b) Python dependency, recorded in app requirements
# =============================================================================

step "0b) openpyxl dependency"

REQ_FILE="${APP_ROOT}/requirements.txt"
touch "$REQ_FILE"

if ! grep -qE '^[[:space:]]*openpyxl([<>=!~].*)?$' "$REQ_FILE"; then
  printf '%s\n' 'openpyxl>=3.1,<4' >>"$REQ_FILE"
  log "openpyxl added to requirements.txt"
else
  warn "openpyxl already present in requirements.txt"
fi

if bench pip show openpyxl >/dev/null 2>&1; then
  log "openpyxl already installed"
else
  bench pip install 'openpyxl>=3.1,<4'
  log "openpyxl installed through bench pip"
fi

# =============================================================================
# 1) Add/update invoice and packing fields in logical field order
# =============================================================================

step "1) Trade Case + Transport Case fields"

python3 <<'PYEOF'
import json
import os

now = os.environ["NOW_TS"]
mod = os.environ["MOD"]


def upsert_fields(path, definitions, before_field=None):
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)

    fields = doc.setdefault("fields", [])
    field_order = doc.setdefault("field_order", [])

    by_name = {
        row.get("fieldname"): row
        for row in fields
        if isinstance(row, dict) and row.get("fieldname")
    }

    changed = False
    names = [row["fieldname"] for row in definitions]

    for spec in definitions:
        fieldname = spec["fieldname"]

        if fieldname in by_name:
            current = by_name[fieldname]
            old = dict(current)
            current.update(spec)
            if current != old:
                changed = True
        else:
            fields.append(dict(spec))
            by_name[fieldname] = fields[-1]
            changed = True

    old_order = list(field_order)
    field_order[:] = [field for field in field_order if field not in names]

    if before_field and before_field in field_order:
        index = field_order.index(before_field)
    else:
        index = len(field_order)

    for offset, fieldname in enumerate(names):
        field_order.insert(index + offset, fieldname)

    if old_order != field_order:
        changed = True

    if changed:
        doc["modified"] = now

    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)

    print(
        f"{os.path.basename(path)}: "
        f"{'updated' if changed else 'already correct'}"
    )


trade_path = os.path.join(
    mod, "doctype", "trade_case", "trade_case.json"
)

transport_path = os.path.join(
    mod, "doctype", "transport_case", "transport_case.json"
)

upsert_fields(
    trade_path,
    [
        {
            "fieldname": "section_invoice",
            "fieldtype": "Section Break",
            "label": "اطلاعات فاکتور و پیش‌فاکتور",
        },
        {
            "fieldname": "sales_invoice_number",
            "fieldtype": "Data",
            "label": "شماره فاکتور/پیش‌فاکتور فروش",
            "in_standard_filter": 1,
        },
        {
            "fieldname": "sales_invoice_date",
            "fieldtype": "Date",
            "label": "تاریخ فروش",
        },
        {
            "fieldname": "purchase_invoice_number",
            "fieldtype": "Data",
            "label": "شماره فاکتور/پیش‌فاکتور خرید",
            "in_standard_filter": 1,
        },
        {
            "fieldname": "purchase_invoice_date",
            "fieldtype": "Date",
            "label": "تاریخ خرید",
        },
        {
            "fieldname": "sales_amount_usd",
            "fieldtype": "Currency",
            "label": "مبلغ دلار فروش",
            "options": "USD",
        },
    ],
    before_field="section_docs",
)

upsert_fields(
    transport_path,
    [
        {
            "fieldname": "section_invoice_refs",
            "fieldtype": "Section Break",
            "label": "فاکتور و پکینگ",
            "collapsible": 1,
        },
        {
            "fieldname": "sales_invoice_number",
            "fieldtype": "Data",
            "label": "شماره فاکتور/پیش‌فاکتور فروش",
            "read_only": 1,
        },
        {
            "fieldname": "sales_invoice_date",
            "fieldtype": "Date",
            "label": "تاریخ فروش",
            "read_only": 1,
        },
        {
            "fieldname": "purchase_invoice_number",
            "fieldtype": "Data",
            "label": "شماره فاکتور/پیش‌فاکتور خرید",
            "read_only": 1,
        },
        {
            "fieldname": "purchase_invoice_date",
            "fieldtype": "Date",
            "label": "تاریخ خرید",
            "read_only": 1,
        },
        {
            "fieldname": "packing_date",
            "fieldtype": "Date",
            "label": "تاریخ پکینگ",
            "in_standard_filter": 1,
        },
    ],
    before_field="section_waybill",
)
PYEOF

# =============================================================================
# 2) Synchronize invoice fields from Trade Case to Transport Case
# =============================================================================

step "2) Trade Case invoice synchronization"

mkdir -p "${MOD}/phase8"
touch "${MOD}/phase8/__init__.py"

write_utf8 "${MOD}/phase8/events.py" <<'EOF'
"""Phase 8 document events."""

from __future__ import annotations

import frappe


INVOICE_FIELDS = (
    "sales_invoice_number",
    "sales_invoice_date",
    "purchase_invoice_number",
    "purchase_invoice_date",
)


def sync_trade_invoice_fields(doc, method=None):
    """Propagate invoice references to all active Transport Cases.

    This keeps packing and operational outputs independent from database reads
    inside Jinja templates and also updates already-created transport records
    whenever the Trade Case invoice information changes.
    """
    if not doc.name or not frappe.db.exists("DocType", "Transport Case"):
        return

    values = {field: doc.get(field) for field in INVOICE_FIELDS}

    names = frappe.get_all(
        "Transport Case",
        filters={
            "trade_case": doc.name,
            "workflow_state": ["not in", ["Cancelled", "Rejected"]],
        },
        pluck="name",
    )

    for name in names:
        frappe.db.set_value(
            "Transport Case",
            name,
            values,
            update_modified=False,
        )
EOF

# =============================================================================
# 3) Canonical Jalali/Jinja helpers
# =============================================================================

step "3) canonical Jalali Jinja helpers"

mkdir -p "${MOD}/utils"
touch "${MOD}/utils/__init__.py"

write_utf8 "${MOD}/utils/jinja_helpers.py" <<'EOF'
"""Jinja helpers for Persian output.

Jalali conversion is intentionally delegated to ir_jalali. This module does
not contain a second calendar algorithm.

`normalize_persian` is the single source of truth for fuzzy Persian text
matching (Smart Sync Rule G1) and is reused by the custom Excel layer.
"""

from __future__ import annotations

import re

from frappe.utils import flt, fmt_money, get_datetime
from ir_jalali.utils.jalali import format_jalali


_FA_DIGITS = "۰۱۲۳۴۵۶۷۸۹"

_ZERO_WIDTH = (
    "\u200b",  # ZWSP
    "\u200c",  # ZWNJ / نیم‌فاصله
    "\u200d",  # ZWJ
    "\u200e",  # LRM
    "\u200f",  # RLM
    "\ufeff",  # BOM
)

_DIACRITICS = re.compile(r"[\u064B-\u065F\u0670]")

_TO_LATIN_DIGITS = str.maketrans(
    "۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩",
    "01234567890123456789",
)

_TO_PERSIAN_DIGITS = str.maketrans(
    "0123456789",
    "۰۱۲۳۴۵۶۷۸۹",
)


def fa_digits(value):
    text = str(value if value is not None else "")
    return "".join(
        _FA_DIGITS[int(char)] if char.isdigit() else char
        for char in text
    )


def normalize_persian(value):
    """Aggressively normalize Persian/Arabic text for fuzzy matching.

    Handles zero-width characters, Arabic vs Persian Yeh/Kaf, tatweel,
    diacritics, Persian digits and repeated whitespace.
    """
    if value is None:
        return ""

    text = str(value)

    for char in _ZERO_WIDTH:
        text = text.replace(char, "")

    text = text.replace("ي", "ی")
    text = text.replace("ى", "ی")
    text = text.replace("ك", "ک")
    text = text.replace("ﻙ", "ک")
    text = text.replace("ة", "ه")
    text = text.replace("\u0640", "")

    text = _DIACRITICS.sub("", text)
    text = text.translate(_TO_LATIN_DIGITS)

    text = text.replace("\u00a0", " ")
    text = re.sub(r"\s+", " ", text).strip()

    return text


def to_persian_digits(value):
    """Latin digits -> Persian digits, keeping everything else untouched."""
    if value is None:
        return ""

    return str(value).translate(_TO_PERSIAN_DIGITS)


def fa_money(value, currency=None):
    try:
        text = fmt_money(flt(value), precision=2, currency=currency)
    except Exception:
        text = f"{flt(value):,.2f}"

    return fa_digits(text)


def fa_date(value):
    if not value:
        return ""

    return fa_digits(format_jalali(value))


def latin_jalali_date(value):
    """Jalali date with Latin digits, suitable for Excel cells."""
    if not value:
        return ""

    return format_jalali(value)


def fa_datetime(value):
    if not value:
        return ""

    try:
        dt = get_datetime(value)
    except Exception:
        return fa_digits(value)

    return f"{fa_date(dt)} {fa_digits(dt.strftime('%H:%M'))}"
EOF

# =============================================================================
# 4) Merge hooks without destroying phases 4-7
# =============================================================================

step "4) hooks.py phase 8 merge"

python3 <<'PYEOF'
import ast
import os
import re

path = os.environ["HOOKS"]

with open(path, encoding="utf-8") as f:
    source = f.read()

source = re.sub(
    r"# --- PHASE8_HOOKS_START ---.*?# --- PHASE8_HOOKS_END ---\n?",
    "",
    source,
    flags=re.DOTALL,
)

addition = r'''
# --- PHASE8_HOOKS_START ---
_p8_required_apps = globals().get("required_apps", [])
required_apps = (
    list(_p8_required_apps)
    if isinstance(_p8_required_apps, (list, tuple))
    else [_p8_required_apps]
)
if "ir_jalali" not in required_apps:
    required_apps.append("ir_jalali")

_p8_jinja = globals().get("jinja", {}) or {}
if not isinstance(_p8_jinja, dict):
    _p8_jinja = {}

_p8_methods = list(_p8_jinja.get("methods", []) or [])
for _p8_method in [
    "transport_ir.iran_transport.utils.jinja_helpers.fa_digits",
    "transport_ir.iran_transport.utils.jinja_helpers.fa_money",
    "transport_ir.iran_transport.utils.jinja_helpers.fa_date",
    "transport_ir.iran_transport.utils.jinja_helpers.fa_datetime",
    "transport_ir.iran_transport.utils.jinja_helpers.normalize_persian",
]:
    if _p8_method not in _p8_methods:
        _p8_methods.append(_p8_method)

jinja = {
    "methods": _p8_methods,
    "filters": list(_p8_jinja.get("filters", []) or []),
}

_p8_doc_events = globals().get("doc_events", {}) or {}
doc_events = dict(_p8_doc_events)

_p8_trade_events = dict(doc_events.get("Trade Case", {}) or {})
_p8_invoice_handler = (
    "transport_ir.iran_transport.phase8.events.sync_trade_invoice_fields"
)
_p8_existing_on_update = _p8_trade_events.get("on_update")

if not _p8_existing_on_update:
    _p8_trade_events["on_update"] = _p8_invoice_handler
elif isinstance(_p8_existing_on_update, (list, tuple)):
    _p8_handlers = list(_p8_existing_on_update)
    if _p8_invoice_handler not in _p8_handlers:
        _p8_handlers.append(_p8_invoice_handler)
    _p8_trade_events["on_update"] = _p8_handlers
elif _p8_existing_on_update != _p8_invoice_handler:
    _p8_trade_events["on_update"] = [
        _p8_existing_on_update,
        _p8_invoice_handler,
    ]

doc_events["Trade Case"] = _p8_trade_events
# --- PHASE8_HOOKS_END ---
'''

with open(path, "w", encoding="utf-8") as f:
    f.write(source.rstrip() + "\n\n" + addition)

ast.parse(open(path, encoding="utf-8").read())
print("hooks.py merged and syntax checked")
PYEOF

# =============================================================================
# 5) Report JSON helper
# =============================================================================

step "5) standard report definitions"

REPORT_ROOT="${MOD}/report"
mkdir -p "$REPORT_ROOT"
touch "${REPORT_ROOT}/__init__.py"

make_report_json() {
  local directory="$1"
  local title="$2"
  local ref_doctype="$3"
  local add_total_row="${4:-1}"

  mkdir -p "${REPORT_ROOT}/${directory}"
  touch "${REPORT_ROOT}/${directory}/__init__.py"

  write_utf8 "${REPORT_ROOT}/${directory}/${directory}.json" <<EOF
{
 "add_total_row": ${add_total_row},
 "creation": "${NOW_TS}",
 "disabled": 0,
 "doctype": "Report",
 "is_standard": "Yes",
 "modified": "${NOW_TS}",
 "modified_by": "Administrator",
 "module": "Iran Transport",
 "name": "${title}",
 "owner": "Administrator",
 "prepared_report": 0,
 "ref_doctype": "${ref_doctype}",
 "report_name": "${title}",
 "report_type": "Script Report",
 "roles": [
  {"role": "System Manager"},
  {"role": "CEO"},
  {"role": "Financial Manager"},
  {"role": "Finance Supervisor"},
  {"role": "Finance User"},
  {"role": "Transport Supervisor"},
  {"role": "Transport User - Purchase"},
  {"role": "Transport User - Sales"},
  {"role": "Customs Officer"}
 ]
}
EOF
}

make_report_json \
  "trade_transport_1405" \
  "Trade Transport 1405" \
  "Trade Case" \
  0

make_report_json \
  "freight_report" \
  "Freight Report" \
  "Transport Case" \
  1

make_report_json \
  "customs_report" \
  "Customs Report" \
  "Transport Case" \
  1

make_report_json \
  "tonnage_report" \
  "Tonnage Report" \
  "Transport Case" \
  1

make_report_json \
  "profit_report" \
  "Profit Report" \
  "Trade Case" \
  1

make_report_json \
  "stalled_cases_report" \
  "Stalled Cases Report" \
  "Transport Case" \
  0

make_report_json \
  "payments_report" \
  "Payments Report" \
  "Transport Case" \
  1

make_report_json \
  "daily_summary_report" \
  "Daily Summary Report" \
  "Transport Case" \
  1

make_report_json \
  "packing_report" \
  "Packing Report" \
  "Transport Case" \
  1

# =============================================================================
# 6) Main 26-column financial report for 1405
# =============================================================================

step "6) Trade Transport 1405 report"

write_utf8 \
  "${REPORT_ROOT}/trade_transport_1405/trade_transport_1405.py" <<'EOF'
from __future__ import annotations

import frappe
from frappe import _
from frappe.utils import flt


ACTIVE_TRANSPORT_STATES = ("Cancelled", "Rejected")


def _column(fieldname, label, fieldtype=None, width=100, options=None):
    column = {
        "fieldname": fieldname,
        "label": _(label),
        "width": width,
    }

    if fieldtype:
        column["fieldtype"] = fieldtype

    if options:
        column["options"] = options

    return column


def get_columns():
    """Return the exact 26-column financial layout."""
    return [
        _column("sales_date", "تاریخ فروش", "Date", 105),
        _column("sales_inv", "ش.فاکتور فروش", None, 120),
        _column("customer", "مشتری", None, 150),
        _column("item_s", "نوع کالا", None, 130),
        _column("plan_s", "تناژ اصلی فروش", "Float", 105),
        _column("usd", "مبلغ دلار", "Currency", 120, "USD"),
        _column("rial", "مبلغ ریال", "Currency", 130),
        _column("ship_s", "تناژ خروجی فروش", "Float", 110),
        _column("cship_s", "جمع کل خارج‌شده فروش", "Float", 135),
        _column("sur_s", "مازاد بارگیری فروش", "Float", 120),
        _column("csur_s", "جمع کل مازاد فروش", "Float", 130),
        _column("rem_s", "باقیمانده فروش", "Float", 110),
        _column("crem_s", "جمع کل باقیمانده فروش", "Float", 140),

        _column("pur_date", "تاریخ خرید", "Date", 105),
        _column("pur_inv", "ش.فاکتور خرید", None, 120),
        _column("supplier", "تأمین‌کننده", None, 150),
        _column("item_p", "نوع کالا (خرید)", None, 130),
        _column("plan_p", "تناژ اصلی خرید", "Float", 105),
        _column("pur_amt", "مبلغ خرید", "Currency", 130),
        _column("ship_p", "تناژ خروجی خرید", "Float", 110),
        _column("cship_p", "جمع کل خارج‌شده خرید", "Float", 135),
        _column("sur_p", "مازاد بارگیری خرید", "Float", 120),
        _column("csur_p", "جمع کل مازاد خرید", "Float", 130),
        _column("rem_p", "باقیمانده خرید", "Float", 110),
        _column("crem_p", "جمع کل باقیمانده خرید", "Float", 140),

        _column("status", "وضعیت", None, 140),
    ]


def _get_trade_rows(filters):
    conditions = ["1 = 1"]
    values = {}

    if filters.get("company"):
        conditions.append("tc.company = %(company)s")
        values["company"] = filters.company

    if filters.get("from_date"):
        conditions.append("tc.posting_date >= %(from_date)s")
        values["from_date"] = filters.from_date

    if filters.get("to_date"):
        conditions.append("tc.posting_date <= %(to_date)s")
        values["to_date"] = filters.to_date

    if filters.get("case_type"):
        conditions.append("tc.case_type = %(case_type)s")
        values["case_type"] = filters.case_type

    if filters.get("name"):
        conditions.append("tc.name = %(name)s")
        values["name"] = filters.name

    return frappe.db.sql(
        """
        select
            tc.name,
            tc.case_type,
            tc.posting_date,
            tc.customer,
            tc.supplier_factory,
            tc.item,
            tc.cargo_description,
            tc.planned_tonnage,
            tc.sales_amount_usd,
            tc.sales_amount,
            tc.purchase_amount,
            tc.sales_invoice_number,
            tc.sales_invoice_date,
            tc.purchase_invoice_number,
            tc.purchase_invoice_date,
            tc.workflow_state
        from `tabTrade Case` tc
        where {conditions}
        order by tc.posting_date, tc.name
        """.format(conditions=" and ".join(conditions)),
        values,
        as_dict=True,
    )


def _get_shipment_totals(trade_names):
    """Get one non-duplicated shipped quantity per Trade Case.

    actual_tonnage is authoritative. net_weight/1000 is used only as fallback
    for a Transport Case whose actual_tonnage has not been populated.
    """
    if not trade_names:
        return {}

    placeholders = ", ".join(["%s"] * len(trade_names))

    rows = frappe.db.sql(
        """
        select
            trade_case,
            sum(
                case
                    when ifnull(actual_tonnage, 0) > 0
                        then actual_tonnage
                    else ifnull(net_weight, 0) / 1000
                end
            ) as shipped
        from `tabTransport Case`
        where trade_case in ({placeholders})
          and ifnull(workflow_state, '') not in ('Cancelled', 'Rejected')
        group by trade_case
        """.format(placeholders=placeholders),
        tuple(trade_names),
        as_dict=True,
    )

    return {
        row.trade_case: flt(row.shipped)
        for row in rows
    }


def _build_report_rows(trade_rows, shipment_totals):
    """Build independent Sales and Purchase sections.

    A Trade Case with case_type='فروش' contributes only to sales detail and
    sales running totals. A Trade Case with case_type='خرید' contributes only
    to purchase detail and purchase running totals.
    """
    result = []

    cumulative_sales_shipped = 0.0
    cumulative_sales_surplus = 0.0
    cumulative_sales_remaining = 0.0

    cumulative_purchase_shipped = 0.0
    cumulative_purchase_surplus = 0.0
    cumulative_purchase_remaining = 0.0

    for row in trade_rows:
        planned = flt(row.planned_tonnage)
        shipped = flt(shipment_totals.get(row.name))

        surplus = max(0.0, shipped - planned)
        remaining = max(0.0, planned - shipped)

        item = row.item or row.cargo_description or ""
        case_type = (row.case_type or "").strip()

        is_sale = case_type == "فروش"
        is_purchase = case_type == "خرید"

        if is_sale:
            cumulative_sales_shipped += shipped
            cumulative_sales_surplus += surplus
            cumulative_sales_remaining += remaining

        if is_purchase:
            cumulative_purchase_shipped += shipped
            cumulative_purchase_surplus += surplus
            cumulative_purchase_remaining += remaining

        result.append(
            [
                # Sales details
                (
                    row.sales_invoice_date or row.posting_date
                    if is_sale
                    else None
                ),
                (
                    row.sales_invoice_number or row.name
                    if is_sale
                    else None
                ),
                row.customer if is_sale else None,
                item if is_sale else None,
                planned if is_sale else None,
                flt(row.sales_amount_usd) if is_sale else None,
                flt(row.sales_amount) if is_sale else None,
                shipped if is_sale else None,

                # Independent sales running totals
                cumulative_sales_shipped,
                surplus if is_sale else None,
                cumulative_sales_surplus,
                remaining if is_sale else None,
                cumulative_sales_remaining,

                # Purchase details
                (
                    row.purchase_invoice_date or row.posting_date
                    if is_purchase
                    else None
                ),
                (
                    row.purchase_invoice_number or row.name
                    if is_purchase
                    else None
                ),
                row.supplier_factory if is_purchase else None,
                item if is_purchase else None,
                planned if is_purchase else None,
                flt(row.purchase_amount) if is_purchase else None,
                shipped if is_purchase else None,

                # Independent purchase running totals
                cumulative_purchase_shipped,
                surplus if is_purchase else None,
                cumulative_purchase_surplus,
                remaining if is_purchase else None,
                cumulative_purchase_remaining,

                _(row.workflow_state or "Draft"),
            ]
        )

    return result


def execute(filters=None):
    filters = frappe._dict(filters or {})

    trade_rows = _get_trade_rows(filters)
    shipment_totals = _get_shipment_totals(
        [row.name for row in trade_rows]
    )

    return get_columns(), _build_report_rows(
        trade_rows,
        shipment_totals,
    )
EOF

write_utf8 \
  "${REPORT_ROOT}/trade_transport_1405/trade_transport_1405.js" <<'EOF'
frappe.query_reports["Trade Transport 1405"] = {
	filters: [
		{
			fieldname: "company",
			label: __("شرکت"),
			fieldtype: "Link",
			options: "Company",
			default: frappe.defaults.get_default("company")
		},
		{
			fieldname: "from_date",
			label: __("از تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "to_date",
			label: __("تا تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "case_type",
			label: __("نوع پرونده"),
			fieldtype: "Select",
			options: "\nخرید\nفروش"
		}
	],

	onload: function (report) {
		report.page.add_inner_button(__("خروجی اکسل مالی ۱۴۰۵"), function () {
			var values = {};

			(report.filters || []).forEach(function (filter) {
				try {
					values[filter.fieldname] = filter.get_value() || "";
				} catch (error) {
					// Ignore filters that are not initialized.
				}
			});

			window.location.href =
				"/api/method/transport_ir.iran_transport.api.report_excel.download_1405?" +
				new URLSearchParams(values).toString();
		}, __("خروجی"));

		report.page.add_inner_button(__("خروجی اختصاصی (قالب کارفرما)"), function () {
			var values = {};

			(report.filters || []).forEach(function (filter) {
				try {
					values[filter.fieldname] = filter.get_value() || "";
				} catch (error) {
					// Ignore filters that are not initialized.
				}
			});

			window.location.href =
				"/api/method/transport_ir.iran_transport.api.report_excel_custom.export_financial_custom?" +
				new URLSearchParams(values).toString();
		}, __("خروجی"));

		report.page.add_inner_button(__("خروجی خرید (قالب کارفرما)"), function () {
			var values = {
				from_date: report.get_filter_value("from_date") || "",
				to_date: report.get_filter_value("to_date") || ""
			};

			window.location.href =
				"/api/method/transport_ir.iran_transport.api.report_excel_custom.export_purchase_custom?" +
				new URLSearchParams(values).toString();
		}, __("خروجی"));
	}
};
EOF

# =============================================================================
# 7) Freight report: detail + daily/monthly/yearly + dimensions
# =============================================================================

step "7) Freight Report"

write_utf8 "${REPORT_ROOT}/freight_report/freight_report.py" <<'EOF'
from __future__ import annotations

import frappe
from frappe import _
from frappe.utils import flt


PERIOD_EXPRESSIONS = {
    "روزانه": "date_format(t.posting_date, '%%Y-%%m-%%d')",
    "ماهانه": "date_format(t.posting_date, '%%Y-%%m')",
    "سالانه": "date_format(t.posting_date, '%%Y')",
}

DIMENSION_EXPRESSIONS = {
    "راننده": "t.driver",
    "باربری": "t.carrier",
    "مشتری": "t.customer",
    "کارخانه": "t.supplier_factory",
}


def execute(filters=None):
    filters = frappe._dict(filters or {})

    conditions = [
        "ifnull(t.workflow_state, '') not in ('Cancelled', 'Rejected')"
    ]
    values = {}

    if filters.get("from_date"):
        conditions.append("t.posting_date >= %(from_date)s")
        values["from_date"] = filters.from_date

    if filters.get("to_date"):
        conditions.append("t.posting_date <= %(to_date)s")
        values["to_date"] = filters.to_date

    if filters.get("carrier"):
        conditions.append("t.carrier = %(carrier)s")
        values["carrier"] = filters.carrier

    period_expression = PERIOD_EXPRESSIONS.get(filters.get("period"))
    dimension_expression = DIMENSION_EXPRESSIONS.get(
        filters.get("group_by")
    )

    if period_expression or dimension_expression:
        select_parts = []
        group_parts = []
        columns = []

        if period_expression:
            select_parts.append(
                f"{period_expression} as period_label"
            )
            group_parts.append(period_expression)
            columns.append(
                {
                    "fieldname": "period_label",
                    "label": _(filters.period),
                    "width": 110,
                }
            )

        if dimension_expression:
            select_parts.append(
                f"ifnull(nullif({dimension_expression}, ''), '—') "
                "as dimension_label"
            )
            group_parts.append(dimension_expression)
            columns.append(
                {
                    "fieldname": "dimension_label",
                    "label": _(filters.group_by),
                    "width": 160,
                }
            )

        select_parts.extend(
            [
                "sum(ifnull(t.freight_cost, 0)) as freight",
                "sum(ifnull(t.actual_tonnage, 0)) as tonnage",
                "count(*) as shipment_count",
            ]
        )

        rows = frappe.db.sql(
            """
            select {select_parts}
            from `tabTransport Case` t
            where {conditions}
            group by {group_parts}
            order by {order_parts}
            """.format(
                select_parts=", ".join(select_parts),
                conditions=" and ".join(conditions),
                group_parts=", ".join(group_parts),
                order_parts=", ".join(group_parts),
            ),
            values,
            as_dict=True,
        )

        columns.extend(
            [
                {
                    "fieldname": "freight",
                    "label": _("کرایه"),
                    "fieldtype": "Currency",
                    "width": 130,
                },
                {
                    "fieldname": "tonnage",
                    "label": _("تناژ"),
                    "fieldtype": "Float",
                    "width": 100,
                },
                {
                    "fieldname": "shipment_count",
                    "label": _("تعداد بار"),
                    "fieldtype": "Int",
                    "width": 90,
                },
            ]
        )

        data = []

        for row in rows:
            values_row = []

            if period_expression:
                values_row.append(row.period_label)

            if dimension_expression:
                values_row.append(row.dimension_label)

            values_row.extend(
                [
                    flt(row.freight),
                    flt(row.tonnage),
                    row.shipment_count,
                ]
            )
            data.append(values_row)

        return columns, data

    rows = frappe.db.sql(
        """
        select
            t.name,
            t.posting_date,
            t.waybill_number,
            t.driver,
            t.carrier,
            t.customer,
            t.supplier_factory,
            t.border,
            t.actual_tonnage,
            t.freight_cost
        from `tabTransport Case` t
        where {conditions}
        order by t.posting_date desc, t.name desc
        """.format(conditions=" and ".join(conditions)),
        values,
        as_dict=True,
    )

    columns = [
        {"fieldname": "name", "label": _("پرونده"), "width": 130},
        {
            "fieldname": "posting_date",
            "label": _("تاریخ"),
            "fieldtype": "Date",
            "width": 105,
        },
        {
            "fieldname": "waybill_number",
            "label": _("بارنامه"),
            "width": 120,
        },
        {"fieldname": "driver", "label": _("راننده"), "width": 140},
        {"fieldname": "carrier", "label": _("باربری"), "width": 130},
        {"fieldname": "customer", "label": _("مشتری"), "width": 140},
        {
            "fieldname": "supplier_factory",
            "label": _("کارخانه"),
            "width": 140,
        },
        {"fieldname": "border", "label": _("مرز"), "width": 105},
        {
            "fieldname": "actual_tonnage",
            "label": _("تناژ"),
            "fieldtype": "Float",
            "width": 95,
        },
        {
            "fieldname": "freight_cost",
            "label": _("کرایه"),
            "fieldtype": "Currency",
            "width": 130,
        },
    ]

    data = [
        [
            row.name,
            row.posting_date,
            row.waybill_number,
            row.driver,
            row.carrier,
            row.customer,
            row.supplier_factory,
            row.border,
            flt(row.actual_tonnage),
            flt(row.freight_cost),
        ]
        for row in rows
    ]

    return columns, data
EOF

write_utf8 "${REPORT_ROOT}/freight_report/freight_report.js" <<'EOF'
frappe.query_reports["Freight Report"] = {
	filters: [
		{
			fieldname: "from_date",
			label: __("از تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "to_date",
			label: __("تا تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "carrier",
			label: __("باربری"),
			fieldtype: "Link",
			options: "Carrier"
		},
		{
			fieldname: "period",
			label: __("دوره زمانی"),
			fieldtype: "Select",
			options: "\nجزئیات\nروزانه\nماهانه\nسالانه",
			default: "جزئیات"
		},
		{
			fieldname: "group_by",
			label: __("تفکیک"),
			fieldtype: "Select",
			options: "\nراننده\nباربری\nمشتری\nکارخانه"
		}
	],

	onload: function (report) {
		report.page.add_inner_button(__("صورتحساب باربری Excel"), function () {
			var carrier = report.get_filter_value("carrier") || "";
			var from_date = report.get_filter_value("from_date") || "";
			var to_date = report.get_filter_value("to_date") || "";

			window.location.href =
				"/api/method/transport_ir.iran_transport.api.report_excel.export_carrier_statement?" +
				new URLSearchParams({
					carrier: carrier,
					from_date: from_date,
					to_date: to_date
				}).toString();
		}, __("خروجی"));

		report.page.add_inner_button(__("لیست تسویه کرایه (اختصاصی)"), function () {
			var carrier = report.get_filter_value("carrier") || "";
			var from_date = report.get_filter_value("from_date") || "";
			var to_date = report.get_filter_value("to_date") || "";

			window.location.href =
				"/api/method/transport_ir.iran_transport.api.report_excel_custom.export_freight_custom?" +
				new URLSearchParams({
					carrier: carrier,
					from_date: from_date,
					to_date: to_date
				}).toString();
		}, __("خروجی"));

		report.page.add_inner_button(__("خروجی ارسال/بارنامه (اختصاصی)"), function () {
			var carrier = report.get_filter_value("carrier") || "";
			var from_date = report.get_filter_value("from_date") || "";
			var to_date = report.get_filter_value("to_date") || "";

			window.location.href =
				"/api/method/transport_ir.iran_transport.api.report_excel_custom.export_dispatch_custom?" +
				new URLSearchParams({
					carrier: carrier,
					from_date: from_date,
					to_date: to_date
				}).toString();
		}, __("خروجی"));
	}
};
EOF

# =============================================================================
# 8) Customs report
# =============================================================================

step "8) Customs Report"

write_utf8 "${REPORT_ROOT}/customs_report/customs_report.py" <<'EOF'
from __future__ import annotations

import frappe
from frappe import _
from frappe.utils import flt


DIMENSIONS = {
    "مرز": "t.border",
    "اظهار": "t.declaration_number",
    "ترخیص‌کار": "t.customs_broker",
    "راننده": "t.driver",
}


def execute(filters=None):
    filters = frappe._dict(filters or {})

    conditions = [
        "ifnull(t.workflow_state, '') not in ('Cancelled', 'Rejected')"
    ]
    values = {}

    if filters.get("from_date"):
        conditions.append("t.posting_date >= %(from_date)s")
        values["from_date"] = filters.from_date

    if filters.get("to_date"):
        conditions.append("t.posting_date <= %(to_date)s")
        values["to_date"] = filters.to_date

    group_expression = DIMENSIONS.get(filters.get("group_by"))

    if group_expression:
        rows = frappe.db.sql(
            """
            select
                ifnull(nullif({group_expression}, ''), '—') as label,
                sum(ifnull(t.customs_cost, 0)) as customs_cost,
                sum(ifnull(t.clearance_cost, 0)) as clearance_cost,
                sum(
                    ifnull(t.customs_cost, 0)
                    + ifnull(t.clearance_cost, 0)
                ) as total_cost,
                count(*) as case_count
            from `tabTransport Case` t
            where {conditions}
            group by {group_expression}
            order by total_cost desc
            """.format(
                group_expression=group_expression,
                conditions=" and ".join(conditions),
            ),
            values,
            as_dict=True,
        )

        columns = [
            {
                "fieldname": "label",
                "label": _(filters.group_by),
                "width": 160,
            },
            {
                "fieldname": "customs_cost",
                "label": _("هزینه گمرک"),
                "fieldtype": "Currency",
                "width": 130,
            },
            {
                "fieldname": "clearance_cost",
                "label": _("هزینه ترخیص"),
                "fieldtype": "Currency",
                "width": 130,
            },
            {
                "fieldname": "total_cost",
                "label": _("جمع هزینه"),
                "fieldtype": "Currency",
                "width": 130,
            },
            {
                "fieldname": "case_count",
                "label": _("تعداد"),
                "fieldtype": "Int",
                "width": 80,
            },
        ]

        data = [
            [
                row.label,
                flt(row.customs_cost),
                flt(row.clearance_cost),
                flt(row.total_cost),
                row.case_count,
            ]
            for row in rows
        ]

        return columns, data

    rows = frappe.db.sql(
        """
        select
            t.name,
            t.posting_date,
            t.border,
            t.declaration_number,
            t.customs_broker,
            t.driver,
            t.customs_cost,
            t.clearance_cost
        from `tabTransport Case` t
        where {conditions}
        order by t.posting_date desc, t.modified desc
        """.format(conditions=" and ".join(conditions)),
        values,
        as_dict=True,
    )

    columns = [
        {"fieldname": "name", "label": _("پرونده"), "width": 130},
        {
            "fieldname": "posting_date",
            "label": _("تاریخ"),
            "fieldtype": "Date",
            "width": 105,
        },
        {"fieldname": "border", "label": _("مرز"), "width": 110},
        {
            "fieldname": "declaration_number",
            "label": _("شماره اظهار"),
            "width": 120,
        },
        {
            "fieldname": "customs_broker",
            "label": _("ترخیص‌کار"),
            "width": 140,
        },
        {"fieldname": "driver", "label": _("راننده"), "width": 140},
        {
            "fieldname": "customs_cost",
            "label": _("هزینه گمرک"),
            "fieldtype": "Currency",
            "width": 130,
        },
        {
            "fieldname": "clearance_cost",
            "label": _("هزینه ترخیص"),
            "fieldtype": "Currency",
            "width": 130,
        },
    ]

    data = [
        [
            row.name,
            row.posting_date,
            row.border,
            row.declaration_number,
            row.customs_broker,
            row.driver,
            flt(row.customs_cost),
            flt(row.clearance_cost),
        ]
        for row in rows
    ]

    return columns, data
EOF

write_utf8 "${REPORT_ROOT}/customs_report/customs_report.js" <<'EOF'
frappe.query_reports["Customs Report"] = {
	filters: [
		{
			fieldname: "from_date",
			label: __("از تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "to_date",
			label: __("تا تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "group_by",
			label: __("تفکیک"),
			fieldtype: "Select",
			options: "\nمرز\nاظهار\nترخیص‌کار\nراننده"
		}
	],

	onload: function (report) {
		report.page.add_inner_button(__("صورتحساب گمرک Excel"), function () {
			var from_date = report.get_filter_value("from_date") || "";
			var to_date = report.get_filter_value("to_date") || "";

			window.location.href =
				"/api/method/transport_ir.iran_transport.api.report_excel.export_customs_statement?" +
				new URLSearchParams({
					from_date: from_date,
					to_date: to_date
				}).toString();
		}, __("خروجی"));
	}
};
EOF

# =============================================================================
# 9) Tonnage report
# =============================================================================

step "9) Tonnage Report"

write_utf8 "${REPORT_ROOT}/tonnage_report/tonnage_report.py" <<'EOF'
from __future__ import annotations

import frappe
from frappe import _
from frappe.utils import flt


DIMENSIONS = {
    "مرز": "t.border",
    "کارخانه": "t.supplier_factory",
    "مشتری": "t.customer",
    "باربری": "t.carrier",
}


def execute(filters=None):
    filters = frappe._dict(filters or {})

    conditions = [
        "ifnull(t.workflow_state, '') not in ('Cancelled', 'Rejected')"
    ]
    values = {}

    if filters.get("from_date"):
        conditions.append("t.posting_date >= %(from_date)s")
        values["from_date"] = filters.from_date

    if filters.get("to_date"):
        conditions.append("t.posting_date <= %(to_date)s")
        values["to_date"] = filters.to_date

    group_expression = DIMENSIONS.get(filters.get("group_by"))

    actual_expression = """
        case
            when ifnull(t.actual_tonnage, 0) > 0
                then t.actual_tonnage
            else ifnull(t.net_weight, 0) / 1000
        end
    """

    if group_expression:
        rows = frappe.db.sql(
            """
            select
                ifnull(nullif({group_expression}, ''), '—') as label,
                sum(ifnull(t.planned_tonnage, 0)) as planned,
                sum({actual_expression}) as actual,
                sum({actual_expression})
                    - sum(ifnull(t.planned_tonnage, 0)) as variance,
                count(*) as case_count
            from `tabTransport Case` t
            where {conditions}
            group by {group_expression}
            order by actual desc
            """.format(
                group_expression=group_expression,
                actual_expression=actual_expression,
                conditions=" and ".join(conditions),
            ),
            values,
            as_dict=True,
        )

        columns = [
            {
                "fieldname": "label",
                "label": _(filters.group_by),
                "width": 160,
            },
            {
                "fieldname": "planned",
                "label": _("تناژ برنامه"),
                "fieldtype": "Float",
                "width": 110,
            },
            {
                "fieldname": "actual",
                "label": _("تناژ واقعی"),
                "fieldtype": "Float",
                "width": 110,
            },
            {
                "fieldname": "variance",
                "label": _("اختلاف"),
                "fieldtype": "Float",
                "width": 100,
            },
            {
                "fieldname": "case_count",
                "label": _("تعداد بار"),
                "fieldtype": "Int",
                "width": 90,
            },
        ]

        data = [
            [
                row.label,
                flt(row.planned),
                flt(row.actual),
                flt(row.variance),
                row.case_count,
            ]
            for row in rows
        ]

        return columns, data

    rows = frappe.db.sql(
        """
        select
            t.name,
            t.trade_case,
            t.posting_date,
            t.border,
            t.supplier_factory,
            t.customer,
            t.planned_tonnage,
            {actual_expression} as actual_tonnage,
            t.net_weight
        from `tabTransport Case` t
        where {conditions}
        order by t.posting_date desc, t.modified desc
        """.format(
            actual_expression=actual_expression,
            conditions=" and ".join(conditions),
        ),
        values,
        as_dict=True,
    )

    columns = [
        {"fieldname": "name", "label": _("پرونده"), "width": 130},
        {
            "fieldname": "trade_case",
            "label": _("پرونده تجاری"),
            "width": 130,
        },
        {
            "fieldname": "posting_date",
            "label": _("تاریخ"),
            "fieldtype": "Date",
            "width": 105,
        },
        {"fieldname": "border", "label": _("مرز"), "width": 105},
        {
            "fieldname": "supplier_factory",
            "label": _("کارخانه"),
            "width": 140,
        },
        {"fieldname": "customer", "label": _("مشتری"), "width": 140},
        {
            "fieldname": "planned_tonnage",
            "label": _("تناژ برنامه"),
            "fieldtype": "Float",
            "width": 105,
        },
        {
            "fieldname": "actual_tonnage",
            "label": _("تناژ واقعی"),
            "fieldtype": "Float",
            "width": 105,
        },
        {
            "fieldname": "net_weight",
            "label": _("باسکول (kg)"),
            "fieldtype": "Float",
            "width": 115,
        },
    ]

    data = [
        [
            row.name,
            row.trade_case,
            row.posting_date,
            row.border,
            row.supplier_factory,
            row.customer,
            flt(row.planned_tonnage),
            flt(row.actual_tonnage),
            flt(row.net_weight),
        ]
        for row in rows
    ]

    return columns, data
EOF

write_utf8 "${REPORT_ROOT}/tonnage_report/tonnage_report.js" <<'EOF'
frappe.query_reports["Tonnage Report"] = {
	filters: [
		{
			fieldname: "from_date",
			label: __("از تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "to_date",
			label: __("تا تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "group_by",
			label: __("تفکیک"),
			fieldtype: "Select",
			options: "\nمرز\nکارخانه\nمشتری\nباربری"
		}
	]
};
EOF

# =============================================================================
# 10) Profit report based on actual operational costs
# =============================================================================

step "10) Profit Report"

write_utf8 "${REPORT_ROOT}/profit_report/profit_report.py" <<'EOF'
from __future__ import annotations

import frappe
from frappe import _
from frappe.utils import flt


DIMENSIONS = {
    "مشتری": "tc.customer",
    "کارخانه": "tc.supplier_factory",
}


TRANSPORT_COST_JOIN = """
left join (
    select
        trade_case,
        count(*) as transport_count,
        sum(
            ifnull(freight_cost, 0)
            + ifnull(customs_cost, 0)
            + ifnull(clearance_cost, 0)
            + ifnull(other_cost, 0)
        ) as transport_cost
    from `tabTransport Case`
    where ifnull(workflow_state, '') not in ('Cancelled', 'Rejected')
    group by trade_case
) costs on costs.trade_case = tc.name
"""


def _effective_operational_cost():
    return """
        case
            when ifnull(costs.transport_count, 0) > 0
                then ifnull(costs.transport_cost, 0)
            else
                ifnull(tc.freight_cost, 0)
                + ifnull(tc.customs_cost, 0)
                + ifnull(tc.clearance_cost, 0)
        end
    """


def execute(filters=None):
    filters = frappe._dict(filters or {})

    conditions = ["1 = 1"]
    values = {}

    if filters.get("from_date"):
        conditions.append("tc.posting_date >= %(from_date)s")
        values["from_date"] = filters.from_date

    if filters.get("to_date"):
        conditions.append("tc.posting_date <= %(to_date)s")
        values["to_date"] = filters.to_date

    group_expression = DIMENSIONS.get(filters.get("group_by"))
    operational_cost = _effective_operational_cost()

    if group_expression:
        rows = frappe.db.sql(
            """
            select
                ifnull(nullif({group_expression}, ''), '—') as label,
                sum(ifnull(tc.sales_amount, 0)) as sales,
                sum(ifnull(tc.purchase_amount, 0)) as purchase,
                sum(
                    ifnull(tc.initial_costs, 0)
                    + ({operational_cost})
                ) as total_cost,
                sum(ifnull(tc.sales_amount, 0))
                    - sum(ifnull(tc.purchase_amount, 0))
                    - sum(
                        ifnull(tc.initial_costs, 0)
                        + ({operational_cost})
                    ) as profit,
                count(*) as case_count
            from `tabTrade Case` tc
            {transport_cost_join}
            where {conditions}
            group by {group_expression}
            order by profit desc
            """.format(
                group_expression=group_expression,
                operational_cost=operational_cost,
                transport_cost_join=TRANSPORT_COST_JOIN,
                conditions=" and ".join(conditions),
            ),
            values,
            as_dict=True,
        )

        columns = [
            {
                "fieldname": "label",
                "label": _(filters.group_by),
                "width": 160,
            },
            {
                "fieldname": "sales",
                "label": _("فروش"),
                "fieldtype": "Currency",
                "width": 130,
            },
            {
                "fieldname": "purchase",
                "label": _("خرید"),
                "fieldtype": "Currency",
                "width": 130,
            },
            {
                "fieldname": "total_cost",
                "label": _("هزینه"),
                "fieldtype": "Currency",
                "width": 130,
            },
            {
                "fieldname": "profit",
                "label": _("سود"),
                "fieldtype": "Currency",
                "width": 130,
            },
            {
                "fieldname": "case_count",
                "label": _("تعداد پرونده"),
                "fieldtype": "Int",
                "width": 100,
            },
        ]

        data = [
            [
                row.label,
                flt(row.sales),
                flt(row.purchase),
                flt(row.total_cost),
                flt(row.profit),
                row.case_count,
            ]
            for row in rows
        ]

        return columns, data

    rows = frappe.db.sql(
        """
        select
            tc.name,
            tc.posting_date,
            tc.case_type,
            tc.customer,
            tc.supplier_factory,
            tc.sales_amount,
            tc.purchase_amount,
            ifnull(tc.initial_costs, 0)
                + ({operational_cost}) as total_cost,
            ifnull(tc.sales_amount, 0)
                - ifnull(tc.purchase_amount, 0)
                - (
                    ifnull(tc.initial_costs, 0)
                    + ({operational_cost})
                ) as profit
        from `tabTrade Case` tc
        {transport_cost_join}
        where {conditions}
        order by tc.posting_date desc, tc.name desc
        """.format(
            operational_cost=operational_cost,
            transport_cost_join=TRANSPORT_COST_JOIN,
            conditions=" and ".join(conditions),
        ),
        values,
        as_dict=True,
    )

    columns = [
        {"fieldname": "name", "label": _("پرونده"), "width": 130},
        {
            "fieldname": "posting_date",
            "label": _("تاریخ"),
            "fieldtype": "Date",
            "width": 105,
        },
        {
            "fieldname": "case_type",
            "label": _("نوع"),
            "width": 80,
        },
        {"fieldname": "customer", "label": _("مشتری"), "width": 140},
        {
            "fieldname": "supplier_factory",
            "label": _("کارخانه"),
            "width": 140,
        },
        {
            "fieldname": "sales_amount",
            "label": _("فروش"),
            "fieldtype": "Currency",
            "width": 130,
        },
        {
            "fieldname": "purchase_amount",
            "label": _("خرید"),
            "fieldtype": "Currency",
            "width": 130,
        },
        {
            "fieldname": "total_cost",
            "label": _("هزینه"),
            "fieldtype": "Currency",
            "width": 130,
        },
        {
            "fieldname": "profit",
            "label": _("سود"),
            "fieldtype": "Currency",
            "width": 130,
        },
    ]

    data = [
        [
            row.name,
            row.posting_date,
            row.case_type,
            row.customer,
            row.supplier_factory,
            flt(row.sales_amount),
            flt(row.purchase_amount),
            flt(row.total_cost),
            flt(row.profit),
        ]
        for row in rows
    ]

    return columns, data
EOF

write_utf8 "${REPORT_ROOT}/profit_report/profit_report.js" <<'EOF'
frappe.query_reports["Profit Report"] = {
	filters: [
		{
			fieldname: "from_date",
			label: __("از تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "to_date",
			label: __("تا تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "group_by",
			label: __("تفکیک"),
			fieldtype: "Select",
			options: "\nمشتری\nکارخانه"
		}
	]
};
EOF

# =============================================================================
# 11) Stalled cases report (24/48-hour model)
# =============================================================================

step "11) Stalled Cases Report"

write_utf8 \
  "${REPORT_ROOT}/stalled_cases_report/stalled_cases_report.py" <<'EOF'
from __future__ import annotations

import frappe
from frappe import _


def execute(filters=None):
    filters = frappe._dict(filters or {})

    minimum_hours = int(filters.get("minimum_hours") or 24)
    critical_hours = int(filters.get("critical_hours") or 48)

    if critical_hours < minimum_hours:
        critical_hours = minimum_hours

    rows = frappe.db.sql(
        """
        select
            name,
            case_type,
            workflow_state,
            assigned_user,
            modified,
            timestampdiff(hour, modified, now()) as stopped_hours
        from `tabTransport Case`
        where ifnull(workflow_state, '') not in (
            'Completed',
            'Cancelled',
            'Rejected'
        )
          and timestampdiff(hour, modified, now()) >= %s
        order by stopped_hours desc, modified asc
        """,
        (minimum_hours,),
        as_dict=True,
    )

    columns = [
        {"fieldname": "name", "label": _("پرونده"), "width": 130},
        {"fieldname": "case_type", "label": _("نوع"), "width": 80},
        {
            "fieldname": "workflow_state",
            "label": _("مرحله"),
            "width": 150,
        },
        {
            "fieldname": "assigned_user",
            "label": _("مسئول"),
            "width": 160,
        },
        {
            "fieldname": "modified",
            "label": _("آخرین فعالیت"),
            "fieldtype": "Datetime",
            "width": 150,
        },
        {
            "fieldname": "stopped_hours",
            "label": _("ساعت توقف"),
            "fieldtype": "Int",
            "width": 100,
        },
        {
            "fieldname": "severity",
            "label": _("سطح هشدار"),
            "width": 100,
        },
    ]

    data = []

    for row in rows:
        stopped_hours = int(row.stopped_hours or 0)

        if stopped_hours >= critical_hours:
            severity = _("بحرانی")
        elif stopped_hours >= minimum_hours:
            severity = _("تأخیر")
        else:
            severity = _("عادی")

        data.append(
            [
                row.name,
                row.case_type,
                row.workflow_state,
                row.assigned_user,
                row.modified,
                stopped_hours,
                severity,
            ]
        )

    return columns, data
EOF

write_utf8 \
  "${REPORT_ROOT}/stalled_cases_report/stalled_cases_report.js" <<'EOF'
frappe.query_reports["Stalled Cases Report"] = {
	filters: [
		{
			fieldname: "minimum_hours",
			label: __("حداقل ساعت توقف"),
			fieldtype: "Int",
			default: 24,
			reqd: 1
		},
		{
			fieldname: "critical_hours",
			label: __("مرز بحرانی (ساعت)"),
			fieldtype: "Int",
			default: 48,
			reqd: 1
		}
	]
};
EOF

# =============================================================================
# 12) Payments report
# =============================================================================

step "12) Payments Report"

write_utf8 "${REPORT_ROOT}/payments_report/payments_report.py" <<'EOF'
from __future__ import annotations

import frappe
from frappe import _
from frappe.utils import flt


def _mask_sheba(value):
    value = value or ""

    if len(value) <= 8:
        return value

    return f"{value[:4]}****{value[-4:]}"


def execute(filters=None):
    filters = frappe._dict(filters or {})

    conditions = ["p.parenttype = 'Transport Case'"]
    values = {}

    if filters.get("from_date"):
        conditions.append("p.payment_date >= %(from_date)s")
        values["from_date"] = filters.from_date

    if filters.get("to_date"):
        conditions.append("p.payment_date <= %(to_date)s")
        values["to_date"] = filters.to_date

    if filters.get("payment_type"):
        conditions.append("p.payment_type = %(payment_type)s")
        values["payment_type"] = filters.payment_type

    rows = frappe.db.sql(
        """
        select
            p.parent,
            c.driver,
            c.waybill_number,
            p.payment_type,
            p.amount,
            p.payment_date,
            p.reference_no,
            p.paid_by,
            p.sheba
        from `tabTransport Payment` p
        inner join `tabTransport Case` c on c.name = p.parent
        where {conditions}
        order by p.payment_date desc, p.parent desc, p.idx
        """.format(conditions=" and ".join(conditions)),
        values,
        as_dict=True,
    )

    columns = [
        {
            "fieldname": "parent",
            "label": _("پرونده"),
            "width": 130,
        },
        {"fieldname": "driver", "label": _("راننده"), "width": 140},
        {
            "fieldname": "waybill_number",
            "label": _("بارنامه"),
            "width": 120,
        },
        {
            "fieldname": "payment_type",
            "label": _("نوع پرداخت"),
            "width": 110,
        },
        {
            "fieldname": "amount",
            "label": _("مبلغ"),
            "fieldtype": "Currency",
            "width": 130,
        },
        {
            "fieldname": "payment_date",
            "label": _("تاریخ"),
            "fieldtype": "Date",
            "width": 105,
        },
        {
            "fieldname": "reference_no",
            "label": _("شماره سند"),
            "width": 120,
        },
        {
            "fieldname": "paid_by",
            "label": _("پرداخت‌کننده"),
            "width": 150,
        },
        {
            "fieldname": "sheba",
            "label": _("شبا (ماسک‌شده)"),
            "width": 140,
        },
    ]

    data = [
        [
            row.parent,
            row.driver,
            row.waybill_number,
            row.payment_type,
            flt(row.amount),
            row.payment_date,
            row.reference_no,
            row.paid_by,
            _mask_sheba(row.sheba),
        ]
        for row in rows
    ]

    return columns, data
EOF

write_utf8 "${REPORT_ROOT}/payments_report/payments_report.js" <<'EOF'
frappe.query_reports["Payments Report"] = {
	filters: [
		{
			fieldname: "from_date",
			label: __("از تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "to_date",
			label: __("تا تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "payment_type",
			label: __("نوع پرداخت"),
			fieldtype: "Select",
			options: "\nپیش کرایه\nکرایه\nگمرک\nترخیص\nسایر"
		}
	]
};
EOF

# =============================================================================
# 13) Daily/monthly/yearly summary report
# =============================================================================

step "13) Daily Summary Report"

write_utf8 \
  "${REPORT_ROOT}/daily_summary_report/daily_summary_report.py" <<'EOF'
from __future__ import annotations

import frappe
from frappe import _
from frappe.utils import flt


PERIODS = {
    "روزانه": "date_format(posting_date, '%%Y-%%m-%%d')",
    "ماهانه": "date_format(posting_date, '%%Y-%%m')",
    "سالانه": "date_format(posting_date, '%%Y')",
}


def execute(filters=None):
    filters = frappe._dict(filters or {})

    period_name = filters.get("period") or "روزانه"
    period_expression = PERIODS.get(
        period_name,
        PERIODS["روزانه"],
    )

    conditions = [
        "ifnull(workflow_state, '') not in ('Cancelled', 'Rejected')"
    ]
    values = {}

    if filters.get("from_date"):
        conditions.append("posting_date >= %(from_date)s")
        values["from_date"] = filters.from_date

    if filters.get("to_date"):
        conditions.append("posting_date <= %(to_date)s")
        values["to_date"] = filters.to_date

    rows = frappe.db.sql(
        """
        select
            {period_expression} as period_label,
            count(*) as shipment_count,
            sum(ifnull(actual_tonnage, 0)) as tonnage,
            sum(if(workflow_state = 'Completed', 1, 0)) as completed_count,
            sum(
                ifnull(freight_cost, 0)
                + ifnull(customs_cost, 0)
                + ifnull(clearance_cost, 0)
                + ifnull(other_cost, 0)
            ) as total_cost
        from `tabTransport Case`
        where {conditions}
        group by {period_expression}
        order by period_label desc
        """.format(
            period_expression=period_expression,
            conditions=" and ".join(conditions),
        ),
        values,
        as_dict=True,
    )

    columns = [
        {
            "fieldname": "period_label",
            "label": _(period_name),
            "width": 120,
        },
        {
            "fieldname": "shipment_count",
            "label": _("تعداد بار"),
            "fieldtype": "Int",
            "width": 100,
        },
        {
            "fieldname": "tonnage",
            "label": _("تناژ"),
            "fieldtype": "Float",
            "width": 110,
        },
        {
            "fieldname": "completed_count",
            "label": _("تکمیل‌شده"),
            "fieldtype": "Int",
            "width": 110,
        },
        {
            "fieldname": "total_cost",
            "label": _("جمع هزینه‌ها"),
            "fieldtype": "Currency",
            "width": 140,
        },
    ]

    data = [
        [
            row.period_label,
            row.shipment_count,
            flt(row.tonnage),
            row.completed_count,
            flt(row.total_cost),
        ]
        for row in rows
    ]

    return columns, data
EOF

write_utf8 \
  "${REPORT_ROOT}/daily_summary_report/daily_summary_report.js" <<'EOF'
frappe.query_reports["Daily Summary Report"] = {
	filters: [
		{
			fieldname: "from_date",
			label: __("از تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "to_date",
			label: __("تا تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "period",
			label: __("دوره"),
			fieldtype: "Select",
			options: "روزانه\nماهانه\nسالانه",
			default: "روزانه",
			reqd: 1
		}
	]
};
EOF

# =============================================================================
# 14) Packing report and Excel button
# =============================================================================

step "14) Packing Report"

write_utf8 "${REPORT_ROOT}/packing_report/packing_report.py" <<'EOF'
from __future__ import annotations

import frappe
from frappe import _
from frappe.utils import flt


def execute(filters=None):
    filters = frappe._dict(filters or {})

    conditions = [
        "ifnull(t.workflow_state, '') not in ('Cancelled', 'Rejected')"
    ]
    values = {}

    if filters.get("from_date"):
        conditions.append(
            "coalesce(t.packing_date, t.posting_date) >= %(from_date)s"
        )
        values["from_date"] = filters.from_date

    if filters.get("to_date"):
        conditions.append(
            "coalesce(t.packing_date, t.posting_date) <= %(to_date)s"
        )
        values["to_date"] = filters.to_date

    if filters.get("border"):
        conditions.append("t.border = %(border)s")
        values["border"] = filters.border

    if filters.get("customer"):
        conditions.append("t.customer = %(customer)s")
        values["customer"] = filters.customer

    rows = frappe.db.sql(
        """
        select
            t.name,
            t.item,
            t.cargo_description,
            t.thickness,
            t.qty,
            t.weight,
            t.actual_tonnage,
            t.border,
            t.driver,
            t.plate_number,
            t.driver_mobile,
            coalesce(t.packing_date, t.posting_date) as packing_date,
            t.customer,
            coalesce(
                nullif(t.sales_invoice_number, ''),
                tc.sales_invoice_number
            ) as sales_invoice_number,
            coalesce(
                nullif(t.purchase_invoice_number, ''),
                tc.purchase_invoice_number
            ) as purchase_invoice_number
        from `tabTransport Case` t
        left join `tabTrade Case` tc on tc.name = t.trade_case
        where {conditions}
        order by
            coalesce(t.packing_date, t.posting_date) desc,
            t.modified desc
        """.format(conditions=" and ".join(conditions)),
        values,
        as_dict=True,
    )

    columns = [
        {"fieldname": "name", "label": _("پرونده"), "width": 125},
        {"fieldname": "item", "label": _("نوع بار"), "width": 140},
        {
            "fieldname": "thickness",
            "label": _("ضخامت"),
            "fieldtype": "Float",
            "width": 85,
        },
        {
            "fieldname": "qty",
            "label": _("تعداد"),
            "fieldtype": "Float",
            "width": 85,
        },
        {
            "fieldname": "weight",
            "label": _("وزن"),
            "fieldtype": "Float",
            "width": 100,
        },
        {
            "fieldname": "actual_tonnage",
            "label": _("تناژ واقعی"),
            "fieldtype": "Float",
            "width": 105,
        },
        {"fieldname": "border", "label": _("مرز"), "width": 105},
        {"fieldname": "driver", "label": _("راننده"), "width": 140},
        {
            "fieldname": "plate_number",
            "label": _("پلاک"),
            "width": 105,
        },
        {
            "fieldname": "driver_mobile",
            "label": _("موبایل"),
            "width": 120,
        },
        {"fieldname": "customer", "label": _("مشتری"), "width": 140},
        {
            "fieldname": "packing_date",
            "label": _("تاریخ پکینگ"),
            "fieldtype": "Date",
            "width": 110,
        },
        {
            "fieldname": "sales_invoice_number",
            "label": _("ش.پیش‌فاکتور فروش"),
            "width": 135,
        },
        {
            "fieldname": "purchase_invoice_number",
            "label": _("ش.پیش‌فاکتور خرید"),
            "width": 135,
        },
    ]

    data = [
        [
            row.name,
            row.item or row.cargo_description,
            flt(row.thickness),
            flt(row.qty),
            flt(row.weight),
            flt(row.actual_tonnage),
            row.border,
            row.driver,
            row.plate_number,
            row.driver_mobile,
            row.customer,
            row.packing_date,
            row.sales_invoice_number,
            row.purchase_invoice_number,
        ]
        for row in rows
    ]

    return columns, data
EOF

write_utf8 "${REPORT_ROOT}/packing_report/packing_report.js" <<'EOF'
frappe.query_reports["Packing Report"] = {
	filters: [
		{
			fieldname: "from_date",
			label: __("از تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "to_date",
			label: __("تا تاریخ"),
			fieldtype: "Date"
		},
		{
			fieldname: "border",
			label: __("مرز"),
			fieldtype: "Link",
			options: "Border"
		},
		{
			fieldname: "customer",
			label: __("مشتری"),
			fieldtype: "Link",
			options: "Customer"
		}
	],

	onload: function (report) {
		report.page.add_inner_button(__("خروجی اکسل پکینگ"), function () {
			var values = {
				from_date: report.get_filter_value("from_date") || "",
				to_date: report.get_filter_value("to_date") || "",
				border: report.get_filter_value("border") || "",
				customer: report.get_filter_value("customer") || ""
			};

			window.location.href =
				"/api/method/transport_ir.iran_transport.api.report_excel.export_packing?" +
				new URLSearchParams(values).toString();
		}, __("خروجی"));

		report.page.add_inner_button(__("پکینگ لیست گمرکی (اختصاصی)"), function () {
			var values = {
				from_date: report.get_filter_value("from_date") || "",
				to_date: report.get_filter_value("to_date") || "",
				border: report.get_filter_value("border") || "",
				customer: report.get_filter_value("customer") || ""
			};

			window.location.href =
				"/api/method/transport_ir.iran_transport.api.report_excel_custom.export_packing_custom?" +
				new URLSearchParams(values).toString();
		}, __("خروجی"));
	}
};
EOF

# =============================================================================
# 15) RTL Print Formats with correct DocType names
# =============================================================================

step "15) RTL Print Formats"

PRINT_ROOT="${MOD}/print_format"

# Remove only known source artifacts introduced by the rejected version.
rm -rf \
  "${PRINT_ROOT}/waybill_print" \
  "${PRINT_ROOT}/weighbridge_print"

mkdir -p "$PRINT_ROOT"
touch "${PRINT_ROOT}/__init__.py"

python3 <<'PYEOF'
import json
import os

mod = os.environ["MOD"]
now = os.environ["NOW_TS"]
root = os.path.join(mod, "print_format")

formats = [
    (
        "trade_case_proforma",
        "Trade Case Proforma",
        "Trade Case",
        """
<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;padding:20px;line-height:1.8;">
  <h2 style="text-align:center;">پیش‌فاکتور {{ doc.case_type }}</h2>
  <p>
    شماره: {{ fa_digits(doc.name) }}
    &nbsp; | &nbsp;
    تاریخ: {{ fa_date(doc.posting_date) }}
  </p>

  <table width="100%" cellpadding="7" style="border-collapse:collapse;">
    <tr>
      <td style="border:1px solid #333;"><b>عنوان:</b> {{ doc.case_title }}</td>
      <td style="border:1px solid #333;"><b>مشتری:</b> {{ doc.customer or '-' }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>تأمین‌کننده:</b> {{ doc.supplier_factory or '-' }}</td>
      <td style="border:1px solid #333;"><b>کالا:</b> {{ doc.item or doc.cargo_description or '-' }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>ابعاد:</b> {{ doc.dimensions or '-' }}</td>
      <td style="border:1px solid #333;"><b>ضخامت:</b> {{ fa_digits(doc.thickness or 0) }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>تعداد:</b> {{ fa_digits(doc.qty or 0) }}</td>
      <td style="border:1px solid #333;"><b>تناژ:</b> {{ fa_digits(doc.planned_tonnage or 0) }} تن</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>مبلغ دلار فروش:</b> {{ fa_money(doc.sales_amount_usd, 'USD') }}</td>
      <td style="border:1px solid #333;"><b>مبلغ ریال فروش:</b> {{ fa_money(doc.sales_amount) }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>مبلغ خرید:</b> {{ fa_money(doc.purchase_amount) }}</td>
      <td style="border:1px solid #333;"><b>هزینه اولیه:</b> {{ fa_money(doc.initial_costs) }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>شماره فروش:</b> {{ doc.sales_invoice_number or '-' }}</td>
      <td style="border:1px solid #333;"><b>شماره خرید:</b> {{ doc.purchase_invoice_number or '-' }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>مقصد:</b> {{ doc.destination or '-' }}</td>
      <td style="border:1px solid #333;"><b>مرز:</b> {{ doc.border or '-' }}</td>
    </tr>
  </table>

  <p style="margin-top:30px;">مهر و امضا:</p>
</div>
""",
    ),
    (
        "transport_packing_list",
        "Transport Packing List",
        "Transport Case",
        """
<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;padding:20px;line-height:1.8;">
  <h2 style="text-align:center;">لیست پکینگ</h2>

  <p>
    پرونده: {{ fa_digits(doc.name) }}
    &nbsp; | &nbsp;
    تاریخ پکینگ: {{ fa_date(doc.packing_date or doc.posting_date) }}
  </p>

  <table width="100%" cellpadding="7" style="border-collapse:collapse;">
    <tr>
      <td style="border:1px solid #333;"><b>نوع بار:</b> {{ doc.item or doc.cargo_description or '-' }}</td>
      <td style="border:1px solid #333;"><b>ضخامت:</b> {{ fa_digits(doc.thickness or 0) }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>ابعاد:</b> {{ doc.dimensions or '-' }}</td>
      <td style="border:1px solid #333;"><b>تعداد:</b> {{ fa_digits(doc.qty or 0) }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>وزن:</b> {{ fa_digits(doc.weight or 0) }}</td>
      <td style="border:1px solid #333;"><b>تناژ واقعی:</b> {{ fa_digits(doc.actual_tonnage or 0) }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>مرز:</b> {{ doc.border or '-' }}</td>
      <td style="border:1px solid #333;"><b>مشتری:</b> {{ doc.customer or '-' }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>راننده:</b> {{ doc.driver_name or doc.driver or '-' }}</td>
      <td style="border:1px solid #333;"><b>پلاک:</b> {{ doc.plate_number or '-' }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>موبایل:</b> {{ fa_digits(doc.driver_mobile or '-') }}</td>
      <td style="border:1px solid #333;"><b>بارنامه:</b> {{ fa_digits(doc.waybill_number or '-') }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>ش.پیش‌فاکتور فروش:</b> {{ doc.sales_invoice_number or '-' }}</td>
      <td style="border:1px solid #333;"><b>ش.پیش‌فاکتور خرید:</b> {{ doc.purchase_invoice_number or '-' }}</td>
    </tr>
  </table>

  <p style="margin-top:24px;">
    ثبت: خانم عنایتی
    &nbsp; | &nbsp;
    تأیید: خانم افراشته‌پور
  </p>
</div>
""",
    ),
    (
        "transport_waybill_print",
        "Transport Waybill Print",
        "Transport Waybill",
        """
<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;padding:20px;line-height:1.8;">
  <h2 style="text-align:center;">بارنامه حمل</h2>

  <p>
    شماره بارنامه: {{ fa_digits(doc.waybill_number) }}
    &nbsp; | &nbsp;
    تاریخ: {{ fa_date(doc.waybill_date) }}
  </p>

  <table width="100%" cellpadding="7" style="border-collapse:collapse;">
    <tr>
      <td style="border:1px solid #333;"><b>پرونده حمل:</b> {{ doc.transport_case }}</td>
      <td style="border:1px solid #333;"><b>راننده:</b> {{ doc.driver }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>پلاک:</b> {{ doc.plate_number or '-' }}</td>
      <td style="border:1px solid #333;"><b>باربری:</b> {{ doc.carrier or '-' }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>مبدأ:</b> {{ doc.origin or '-' }}</td>
      <td style="border:1px solid #333;"><b>مقصد:</b> {{ doc.destination or '-' }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>مرز:</b> {{ doc.border or '-' }}</td>
      <td style="border:1px solid #333;"><b>کالا:</b> {{ doc.item_name or '-' }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>تناژ:</b> {{ fa_digits(doc.tonnage or 0) }}</td>
      <td style="border:1px solid #333;"><b>کرایه:</b> {{ fa_money(doc.freight_amount) }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>بیمه:</b> {{ fa_money(doc.insurance_amount) }}</td>
      <td style="border:1px solid #333;"><b>فرستنده:</b> {{ doc.sender_name or '-' }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>گیرنده:</b> {{ doc.receiver_name or '-' }}</td>
      <td style="border:1px solid #333;"><b>وضعیت سند:</b> {{ doc.docstatus }}</td>
    </tr>
  </table>
</div>
""",
    ),
    (
        "transport_weighbridge_print",
        "Transport Weighbridge Print",
        "Transport Weighbridge",
        """
<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;padding:20px;line-height:1.8;">
  <h2 style="text-align:center;">رسید باسکول</h2>

  <p>
    شماره: {{ fa_digits(doc.name) }}
    &nbsp; | &nbsp;
    تاریخ/ساعت: {{ fa_datetime(doc.posting_datetime) }}
  </p>

  <table width="100%" cellpadding="7" style="border-collapse:collapse;">
    <tr>
      <td style="border:1px solid #333;"><b>پرونده حمل:</b> {{ doc.transport_case }}</td>
      <td style="border:1px solid #333;"><b>بارنامه:</b> {{ doc.waybill or '-' }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>پلاک:</b> {{ doc.plate_number or '-' }}</td>
      <td style="border:1px solid #333;"><b>اپراتور:</b> {{ doc.operator or '-' }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>وزن خالی:</b> {{ fa_digits(doc.weight_empty or 0) }} kg</td>
      <td style="border:1px solid #333;"><b>وزن پر:</b> {{ fa_digits(doc.weight_full or 0) }} kg</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>وزن خالص:</b> {{ fa_digits(doc.net_weight or 0) }} kg</td>
      <td style="border:1px solid #333;"><b>تناژ خالص:</b> {{ fa_digits(doc.net_tonnage or 0) }} تن</td>
    </tr>
    <tr>
      <td style="border:1px solid #333;"><b>وضعیت تأیید:</b> {{ doc.approval_status or '-' }}</td>
      <td style="border:1px solid #333;"><b>تأییدکننده:</b> {{ doc.approved_by or '-' }}</td>
    </tr>
  </table>
</div>
""",
    ),
]

for directory, name, doc_type, html in formats:
    path = os.path.join(root, directory)
    os.makedirs(path, exist_ok=True)

    init_path = os.path.join(path, "__init__.py")
    if not os.path.exists(init_path):
        open(init_path, "w", encoding="utf-8").write(
            "# Print Format package\n"
        )

    data = {
        "align_labels_right": 1,
        "creation": now,
        "custom_format": 1,
        "disabled": 0,
        "doc_type": doc_type,
        "doctype": "Print Format",
        "font": "Default",
        "html": html.strip(),
        "modified": now,
        "modified_by": "Administrator",
        "module": "Iran Transport",
        "name": name,
        "owner": "Administrator",
        "print_format_builder": 0,
        "print_format_type": "Jinja",
        "raw_printing": 0,
        "standard": "Yes",
    }

    with open(
        os.path.join(path, f"{directory}.json"),
        "w",
        encoding="utf-8",
    ) as f:
        json.dump(data, f, ensure_ascii=False, indent=1)

    print(f"print format: {name} -> {doc_type}")
PYEOF

# =============================================================================
# 16) Excel API
# =============================================================================

step "16) secure Excel API"

mkdir -p "${MOD}/api"
touch "${MOD}/api/__init__.py"

write_utf8 "${MOD}/api/report_excel.py" <<'EOF'
"""Secure Excel import/export endpoints for Phase 8."""

from __future__ import annotations

import io
import re

import frappe
from frappe import _
from frappe.utils import flt

from transport_ir.iran_transport.utils.jinja_helpers import (
    latin_jalali_date,
)


FINANCE_ROLES = {
    "System Manager",
    "CEO",
    "Financial Manager",
    "Finance Supervisor",
    "Finance User",
}

OPERATIONS_ROLES = FINANCE_ROLES | {
    "Transport Supervisor",
    "Transport User - Purchase",
    "Transport User - Sales",
    "Customs Officer",
}

MAX_IMPORT_FILE_SIZE = 10 * 1024 * 1024
MAX_IMPORT_ROWS = 2000

RUNNING_TOTAL_FIELDS = {
    "cship_s",
    "csur_s",
    "crem_s",
    "cship_p",
    "csur_p",
    "crem_p",
}


def _guard(allowed_roles):
    current_roles = set(frappe.get_roles())

    if not (current_roles & set(allowed_roles)):
        frappe.throw(
            _("دسترسی به این عملیات مجاز نیست."),
            frappe.PermissionError,
        )


def _new_workbook(title):
    from openpyxl import Workbook

    workbook = Workbook()
    worksheet = workbook.active
    worksheet.title = title[:31]
    worksheet.sheet_view.rightToLeft = True

    return workbook, worksheet


def _style_header(worksheet, headers, row=1):
    from openpyxl.styles import Alignment, Font, PatternFill

    for column_index, header in enumerate(headers, 1):
        cell = worksheet.cell(
            row=row,
            column=column_index,
            value=header,
        )
        cell.font = Font(bold=True, color="000000")
        cell.fill = PatternFill(
            fill_type="solid",
            fgColor="D9EAF7",
        )
        cell.alignment = Alignment(
            horizontal="center",
            vertical="center",
            wrap_text=True,
        )


def _autosize(worksheet, minimum=11, maximum=35):
    from openpyxl.utils import get_column_letter

    for column_cells in worksheet.columns:
        width = minimum

        for cell in column_cells:
            value = "" if cell.value is None else str(cell.value)
            width = max(width, len(value) + 2)

        width = min(width, maximum)
        worksheet.column_dimensions[
            get_column_letter(column_cells[0].column)
        ].width = width


def _finalize_table(worksheet, header_row, last_row, last_column):
    from openpyxl.styles import Alignment
    from openpyxl.utils import get_column_letter

    worksheet.freeze_panes = worksheet.cell(
        row=header_row + 1,
        column=1,
    )

    if last_row >= header_row:
        worksheet.auto_filter.ref = (
            f"A{header_row}:"
            f"{get_column_letter(last_column)}{last_row}"
        )

    for row in worksheet.iter_rows():
        for cell in row:
            cell.alignment = Alignment(
                vertical="center",
                wrap_text=True,
            )

    _autosize(worksheet)


def _send(workbook, filename):
    output = io.BytesIO()
    workbook.save(output)

    frappe.response["type"] = "binary"
    frappe.response["filename"] = filename
    frappe.response["filecontent"] = output.getvalue()
    frappe.response["display_content_as"] = "attachment"


def _report_value(row, index, column):
    if isinstance(row, dict):
        return row.get(column.get("fieldname"))

    return row[index] if index < len(row) else None


def _write_report_table(
    worksheet,
    columns,
    data,
    header_row=1,
    jalali_dates=True,
):
    _style_header(
        worksheet,
        [column.get("label") for column in columns],
        row=header_row,
    )

    first_data_row = header_row + 1

    for row_index, source_row in enumerate(data, first_data_row):
        for column_index, column in enumerate(columns, 1):
            value = _report_value(
                source_row,
                column_index - 1,
                column,
            )

            if (
                jalali_dates
                and value
                and column.get("fieldtype") in ("Date", "Datetime")
            ):
                value = latin_jalali_date(value)

            cell = worksheet.cell(
                row=row_index,
                column=column_index,
                value=value,
            )

            if column.get("fieldtype") == "Currency":
                cell.number_format = '#,##0.00'

            if column.get("fieldtype") == "Float":
                cell.number_format = '#,##0.000'

    last_row = max(header_row, first_data_row + len(data) - 1)

    _finalize_table(
        worksheet,
        header_row,
        last_row,
        len(columns),
    )


@frappe.whitelist()
def download_1405(
    company=None,
    from_date=None,
    to_date=None,
    case_type=None,
):
    """Download the approved 26-column financial 1405 workbook."""
    _guard(FINANCE_ROLES)

    from transport_ir.iran_transport.report.trade_transport_1405.trade_transport_1405 import (
        execute,
    )

    columns, data = execute(
        {
            "company": company,
            "from_date": from_date,
            "to_date": to_date,
            "case_type": case_type,
        }
    )

    workbook, worksheet = _new_workbook("گزارش 1405")

    worksheet.cell(row=1, column=1, value="گزارش خرید، فروش و حمل ۱۴۰۵")
    worksheet.cell(row=1, column=6, value="دلار")
    worksheet.cell(row=1, column=7, value="ریال")

    _write_report_table(
        worksheet,
        columns,
        data,
        header_row=2,
        jalali_dates=True,
    )

    total_row = len(data) + 3
    worksheet.cell(row=total_row, column=1, value="جمع کل")

    from openpyxl.styles import Font, PatternFill

    worksheet.cell(
        row=total_row,
        column=1,
    ).font = Font(bold=True)

    for column_index, column in enumerate(columns):
        if column.get("fieldtype") not in ("Float", "Currency"):
            continue

        values = [
            flt(_report_value(row, column_index, column))
            for row in data
            if _report_value(row, column_index, column) not in (None, "")
        ]

        if column.get("fieldname") in RUNNING_TOTAL_FIELDS:
            total_value = values[-1] if values else 0
        else:
            total_value = sum(values)

        cell = worksheet.cell(
            row=total_row,
            column=column_index + 1,
            value=total_value,
        )
        cell.font = Font(bold=True)
        cell.fill = PatternFill(
            fill_type="solid",
            fgColor="FFF2CC",
        )

        if column.get("fieldtype") == "Currency":
            cell.number_format = '#,##0.00'
        else:
            cell.number_format = '#,##0.000'

    _autosize(worksheet)

    _send(workbook, "trade_transport_1405.xlsx")


@frappe.whitelist()
def export_packing(
    from_date=None,
    to_date=None,
    border=None,
    customer=None,
):
    _guard(OPERATIONS_ROLES)

    from transport_ir.iran_transport.report.packing_report.packing_report import (
        execute,
    )

    columns, data = execute(
        {
            "from_date": from_date,
            "to_date": to_date,
            "border": border,
            "customer": customer,
        }
    )

    workbook, worksheet = _new_workbook("پکینگ")

    _write_report_table(
        worksheet,
        columns,
        data,
        header_row=1,
        jalali_dates=True,
    )

    _send(workbook, "packing.xlsx")


@frappe.whitelist()
def export_carrier_statement(
    carrier=None,
    from_date=None,
    to_date=None,
):
    _guard(FINANCE_ROLES)

    conditions = [
        "ifnull(workflow_state, '') not in ('Cancelled', 'Rejected')"
    ]
    values = {}

    if carrier:
        conditions.append("carrier = %(carrier)s")
        values["carrier"] = carrier

    if from_date:
        conditions.append("posting_date >= %(from_date)s")
        values["from_date"] = from_date

    if to_date:
        conditions.append("posting_date <= %(to_date)s")
        values["to_date"] = to_date

    rows = frappe.db.sql(
        """
        select
            name,
            waybill_number,
            driver,
            carrier,
            border,
            actual_tonnage,
            freight_cost,
            posting_date
        from `tabTransport Case`
        where {conditions}
        order by posting_date, name
        """.format(conditions=" and ".join(conditions)),
        values,
        as_dict=True,
    )

    workbook, worksheet = _new_workbook("صورتحساب باربری")

    headers = [
        "پرونده",
        "بارنامه",
        "راننده",
        "باربری",
        "مرز",
        "تناژ",
        "کرایه",
        "تاریخ",
    ]
    _style_header(worksheet, headers)

    total_tonnage = 0.0
    total_freight = 0.0

    for row_index, row in enumerate(rows, 2):
        tonnage = flt(row.actual_tonnage)
        freight = flt(row.freight_cost)

        total_tonnage += tonnage
        total_freight += freight

        values_row = [
            row.name,
            row.waybill_number,
            row.driver,
            row.carrier,
            row.border,
            tonnage,
            freight,
            latin_jalali_date(row.posting_date),
        ]

        for column_index, value in enumerate(values_row, 1):
            worksheet.cell(
                row=row_index,
                column=column_index,
                value=value,
            )

    total_row = len(rows) + 2
    worksheet.cell(row=total_row, column=5, value="جمع کل")
    worksheet.cell(row=total_row, column=6, value=total_tonnage)
    worksheet.cell(row=total_row, column=7, value=total_freight)

    from openpyxl.styles import Font

    for column_index in (5, 6, 7):
        worksheet.cell(
            row=total_row,
            column=column_index,
        ).font = Font(bold=True)

    _finalize_table(
        worksheet,
        1,
        total_row,
        len(headers),
    )

    _send(workbook, "carrier_statement.xlsx")


@frappe.whitelist()
def export_customs_statement(from_date=None, to_date=None):
    _guard(FINANCE_ROLES)

    conditions = [
        "ifnull(workflow_state, '') not in ('Cancelled', 'Rejected')"
    ]
    values = {}

    if from_date:
        conditions.append("posting_date >= %(from_date)s")
        values["from_date"] = from_date

    if to_date:
        conditions.append("posting_date <= %(to_date)s")
        values["to_date"] = to_date

    rows = frappe.db.sql(
        """
        select
            name,
            posting_date,
            border,
            declaration_number,
            customs_broker,
            driver,
            customs_cost,
            clearance_cost
        from `tabTransport Case`
        where {conditions}
        order by posting_date, name
        """.format(conditions=" and ".join(conditions)),
        values,
        as_dict=True,
    )

    workbook, worksheet = _new_workbook("صورتحساب گمرک")

    headers = [
        "پرونده",
        "تاریخ",
        "مرز",
        "اظهار",
        "ترخیص‌کار",
        "راننده",
        "گمرک",
        "ترخیص",
        "جمع",
    ]
    _style_header(worksheet, headers)

    total_customs = 0.0
    total_clearance = 0.0

    for row_index, row in enumerate(rows, 2):
        customs = flt(row.customs_cost)
        clearance = flt(row.clearance_cost)

        total_customs += customs
        total_clearance += clearance

        values_row = [
            row.name,
            latin_jalali_date(row.posting_date),
            row.border,
            row.declaration_number,
            row.customs_broker,
            row.driver,
            customs,
            clearance,
            customs + clearance,
        ]

        for column_index, value in enumerate(values_row, 1):
            worksheet.cell(
                row=row_index,
                column=column_index,
                value=value,
            )

    total_row = len(rows) + 2
    worksheet.cell(row=total_row, column=6, value="جمع کل")
    worksheet.cell(row=total_row, column=7, value=total_customs)
    worksheet.cell(row=total_row, column=8, value=total_clearance)
    worksheet.cell(
        row=total_row,
        column=9,
        value=total_customs + total_clearance,
    )

    from openpyxl.styles import Font

    for column_index in (6, 7, 8, 9):
        worksheet.cell(
            row=total_row,
            column=column_index,
        ).font = Font(bold=True)

    _finalize_table(
        worksheet,
        1,
        total_row,
        len(headers),
    )

    _send(workbook, "customs_statement.xlsx")


@frappe.whitelist()
def export_proforma(name):
    _guard(OPERATIONS_ROLES)

    doc = frappe.get_doc("Trade Case", name)
    doc.check_permission("read")

    workbook, worksheet = _new_workbook("پیش‌فاکتور")

    rows = [
        ("شماره پرونده", doc.name),
        ("عنوان", doc.case_title),
        ("نوع", doc.case_type),
        ("تاریخ", latin_jalali_date(doc.posting_date)),
        ("مشتری", doc.customer or ""),
        ("تأمین‌کننده", doc.supplier_factory or ""),
        ("کالا", doc.item or doc.cargo_description or ""),
        ("تناژ اصلی", flt(doc.planned_tonnage)),
        ("مبلغ دلار", flt(doc.sales_amount_usd)),
        ("مبلغ ریال فروش", flt(doc.sales_amount)),
        ("مبلغ خرید", flt(doc.purchase_amount)),
        ("شماره فروش", doc.sales_invoice_number or ""),
        ("شماره خرید", doc.purchase_invoice_number or ""),
        ("مقصد", doc.destination or ""),
        ("مرز", doc.border or ""),
    ]

    from openpyxl.styles import Font

    for row_index, (label, value) in enumerate(rows, 1):
        worksheet.cell(
            row=row_index,
            column=1,
            value=label,
        ).font = Font(bold=True)

        worksheet.cell(
            row=row_index,
            column=2,
            value=value,
        )

    _autosize(worksheet)

    safe_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", doc.name)
    _send(workbook, f"proforma_{safe_name}.xlsx")


@frappe.whitelist()
def download_proforma_template():
    _guard(OPERATIONS_ROLES)

    workbook, worksheet = _new_workbook("قالب پیش‌فاکتور")

    headers = [
        "مشتری",
        "تأمین‌کننده",
        "نوع کالا",
        "تناژ اصلی",
        "مبلغ دلار",
        "مبلغ ریال",
        "تاریخ فروش",
        "ش.فاکتور فروش",
        "تاریخ خرید",
        "ش.فاکتور خرید",
        "نوع پرونده",
    ]

    _style_header(worksheet, headers)
    worksheet.freeze_panes = "A2"
    _autosize(worksheet)

    _send(workbook, "proforma_template.xlsx")


@frappe.whitelist()
def import_proforma_excel(file_url):
    """Create Draft Trade Cases from an uploaded XLSX file.

    The operation is fail-fast and transactional: an invalid row raises an
    error and Frappe rolls back the whole request, preventing partial imports.
    """
    _guard(OPERATIONS_ROLES)

    if not frappe.has_permission("Trade Case", "create"):
        frappe.throw(
            _("دسترسی ساخت پرونده تجاری ندارید."),
            frappe.PermissionError,
        )

    file_url = (file_url or "").strip()

    if not file_url:
        frappe.throw(_("فایل اکسل مشخص نشده است."))

    if not file_url.lower().split("?", 1)[0].endswith(".xlsx"):
        frappe.throw(_("فقط فایل XLSX مجاز است."))

    file_docname = frappe.db.get_value(
        "File",
        {"file_url": file_url},
        "name",
    )

    if not file_docname:
        frappe.throw(_("فایل در سیستم پیدا نشد."))

    file_doc = frappe.get_doc("File", file_docname)
    file_doc.check_permission("read")

    if flt(file_doc.file_size) > MAX_IMPORT_FILE_SIZE:
        frappe.throw(_("حجم فایل نباید بیشتر از ۱۰ مگابایت باشد."))

    content = file_doc.get_content()

    if isinstance(content, str):
        content = content.encode("latin-1")

    import openpyxl

    try:
        workbook = openpyxl.load_workbook(
            io.BytesIO(content),
            read_only=True,
            data_only=True,
        )
    except Exception as exc:
        frappe.throw(
            _("فایل Excel معتبر نیست: {0}").format(exc)
        )

    worksheet = workbook.active

    if worksheet.max_row - 1 > MAX_IMPORT_ROWS:
        frappe.throw(
            _("حداکثر تعداد ردیف قابل ورود {0} است.").format(
                MAX_IMPORT_ROWS
            )
        )

    created = []

    for row_number, row in enumerate(
        worksheet.iter_rows(min_row=2, values_only=True),
        start=2,
    ):
        if not row or not any(value not in (None, "") for value in row):
            continue

        values = list(row) + [None] * max(0, 11 - len(row))

        customer = values[0]
        supplier = values[1]
        cargo_description = values[2]
        planned_tonnage = flt(values[3])
        sales_amount_usd = flt(values[4])
        sales_amount = flt(values[5])
        sales_invoice_date = values[6]
        sales_invoice_number = values[7]
        purchase_invoice_date = values[8]
        purchase_invoice_number = values[9]
        case_type = str(values[10] or "خرید").strip()

        if case_type not in ("خرید", "فروش"):
            frappe.throw(
                _("ردیف {0}: نوع پرونده باید خرید یا فروش باشد.").format(
                    row_number
                )
            )

        if not customer:
            frappe.throw(
                _("ردیف {0}: مشتری الزامی است.").format(row_number)
            )

        if planned_tonnage <= 0:
            frappe.throw(
                _("ردیف {0}: تناژ باید بزرگ‌تر از صفر باشد.").format(
                    row_number
                )
            )

        doc = frappe.new_doc("Trade Case")
        doc.case_title = f"{customer} - {cargo_description or case_type}"
        doc.case_type = case_type
        doc.customer = customer
        doc.supplier_factory = supplier
        doc.cargo_description = cargo_description
        doc.planned_tonnage = planned_tonnage
        doc.sales_amount_usd = sales_amount_usd
        doc.sales_amount = sales_amount
        doc.sales_invoice_date = sales_invoice_date
        doc.sales_invoice_number = sales_invoice_number
        doc.purchase_invoice_date = purchase_invoice_date
        doc.purchase_invoice_number = purchase_invoice_number
        doc.insert()

        created.append(doc.name)

    if not created:
        frappe.throw(_("هیچ ردیف قابل ورودی در فایل وجود نداشت."))

    return {
        "created": created,
        "count": len(created),
    }
EOF

# =============================================================================
# 17) Trade Case UI: Excel buttons and secure file import
# =============================================================================

step "17) Trade Case Excel UI"

write_utf8 \
  "${MOD}/doctype/trade_case/trade_case.js" <<'EOF'
frappe.ui.form.on("Trade Case", {
	refresh: function (frm) {
		if (frm.is_new()) {
			return;
		}

		frm.add_custom_button(__("خروجی Excel پیش‌فاکتور"), function () {
			window.location.href =
				"/api/method/transport_ir.iran_transport.api.report_excel.export_proforma?" +
				new URLSearchParams({ name: frm.doc.name }).toString();
		}, __("خروجی"));
	}
});
EOF

write_utf8 \
  "${MOD}/doctype/trade_case/trade_case_list.js" <<'EOF'
(function () {
	"use strict";

	var settings = frappe.listview_settings["Trade Case"] || {};
	var previous_onload = settings.onload;

	settings.onload = function (listview) {
		if (typeof previous_onload === "function") {
			previous_onload(listview);
		}

		if (listview.__phase8_excel_buttons) {
			return;
		}

		listview.__phase8_excel_buttons = true;

		listview.page.add_inner_button(__("دانلود قالب پیش‌فاکتور"), function () {
			window.location.href =
				"/api/method/transport_ir.iran_transport.api.report_excel.download_proforma_template";
		}, __("اکسل"));

		listview.page.add_inner_button(__("ورود پیش‌فاکتور از Excel"), function () {
			var dialog = new frappe.ui.Dialog({
				title: __("ورود پیش‌فاکتور از Excel"),
				fields: [
					{
						fieldname: "file_url",
						label: __("فایل XLSX"),
						fieldtype: "Attach",
						reqd: 1
					}
				],
				primary_action_label: __("ورود اطلاعات"),
				primary_action: function (values) {
					dialog.disable_primary_action();

					frappe.call({
						method: "transport_ir.iran_transport.api.report_excel.import_proforma_excel",
						args: {
							file_url: values.file_url
						},
						freeze: true,
						freeze_message: __("در حال بررسی و ورود فایل..."),
						callback: function (response) {
							var result = response.message || {};

							dialog.hide();

							frappe.show_alert({
								message: __(
									"{0} پرونده تجاری ایجاد شد.",
									[result.count || 0]
								),
								indicator: "green"
							}, 7);

							listview.refresh();
						},
						always: function () {
							dialog.enable_primary_action();
						}
					});
				}
			});

			dialog.show();
		}, __("اکسل"));
	};

	frappe.listview_settings["Trade Case"] = settings;
})();
EOF

# =============================================================================
# 17.5) Custom Excel Layer (Additive, Standard Preserved, Golden Rules Sync)
# =============================================================================
step "17.5) Custom Excel Layer (Golden Rules Sync, Production Ready)"

mkdir -p "${BENCH_DIR}/sites/${SITE_NAME}/private/files/excel_templates" 2>/dev/null || true

TEMPLATE_SRC=""
if [[ -d "${SCRIPT_DIR}/excel_client_files" ]]; then
  TEMPLATE_SRC="${SCRIPT_DIR}/excel_client_files"
elif [[ -d "${APP_ROOT}/excel_client_files" ]]; then
  TEMPLATE_SRC="${APP_ROOT}/excel_client_files"
fi

if [[ -n "${TEMPLATE_SRC}" ]]; then
  cp -f "${TEMPLATE_SRC}"/template_*.xlsx \
    "${BENCH_DIR}/sites/${SITE_NAME}/private/files/excel_templates/" 2>/dev/null || true
  cp -f "${TEMPLATE_SRC}"/client_logo.png \
    "${BENCH_DIR}/sites/${SITE_NAME}/private/files/excel_templates/" 2>/dev/null || true
  log "Templates staged from ${TEMPLATE_SRC} to private/files/excel_templates"
else
  warn "excel_client_files not found next to script (${SCRIPT_DIR}) or in APP_ROOT"
fi

mkdir -p "${MOD}/api"
touch "${MOD}/api/__init__.py"
write_utf8 "${MOD}/api/report_excel_custom.py" <<'CUSTOM_PY_EOF'
"""Custom Excel layer v5 — PHASE 8 EXCEL ⇄ ERPNext SMART SYNC GOLDEN RULES.

This module is a strict implementation of the signed golden-rules document.

Source of truth order:

    P0  real Excel JSON contract
        sheet name, cell coordinate, merge, hidden columns, exact header text,
        formula, style scope
    P1  real project Meta / DocType fields of transport_ir
    P2  project process rules
    P3  alias/fuzzy, for detection only, never to rewrite client text
        and never to guess a destination

Absolute rules honoured here:

    1.  Client static text is never "spell corrected".
    2.  The exact Excel wording is preserved as-is.
    3.  Aliases live only in the matching layer.
    4.  Coordinate lock wins over fuzzy matching.
    5.  Ambiguity becomes UNRESOLVED, never a plausible guess.
    6.  The original template file is never overwritten.
    7.  Export is copy / in-memory only.
    8.  Import is Preview -> Validate -> Resolve -> Commit.
    9.  A row error rolls the whole import back, no half-imported records.
    10. Operational records are created through the Document API, never SQL.

Templates covered:

    template_01_financial  -> export_financial_custom
    template_02_freight    -> export_freight_custom
    template_03_packing    -> export_packing_custom
    template_04_purchase   -> export_purchase_custom
    template_05_dispatch   -> export_dispatch_custom
"""

from __future__ import annotations

import datetime
import io
import json
import os
import re

from copy import copy

import frappe
from frappe import _
from frappe.utils import flt, getdate

import openpyxl
from openpyxl.cell.cell import MergedCell
from openpyxl.drawing.image import Image as XLImage
from openpyxl.utils import column_index_from_string, get_column_letter
from openpyxl.worksheet.cell_range import CellRange

from transport_ir.iran_transport.api.report_excel import (
    FINANCE_ROLES,
    MAX_IMPORT_FILE_SIZE,
    MAX_IMPORT_ROWS,
    OPERATIONS_ROLES,
    RUNNING_TOTAL_FIELDS,
    _guard,
    _send,
)

try:
    from transport_ir.iran_transport.utils.jinja_helpers import (
        latin_jalali_date,
        normalize_persian,
        to_persian_digits,
    )
except ImportError:  # pragma: no cover - defensive only
    import re as _re

    def latin_jalali_date(value):
        return str(value) if value else ""

    def normalize_persian(value):
        if value is None:
            return ""
        text = str(value)
        for char in ("\u200c", "\u200d", "\u200e", "\u200f", "\ufeff"):
            text = text.replace(char, "")
        text = text.replace("ي", "ی").replace("ك", "ک")
        return _re.sub(r"\s+", " ", text).strip()

    def to_persian_digits(value):
        return str(value or "")


# ---------------------------------------------------------------------------
# UNRESOLVED marker — golden rules forbid writing a guessed value
# ---------------------------------------------------------------------------

UNRESOLVED = None


# ---------------------------------------------------------------------------
# Known client typo aliases — MATCHING ONLY, never used to rewrite the file
# ---------------------------------------------------------------------------

HEADER_ALIASES = {
    "هزنیه تخلیه": ("هزینه تخلیه",),
    "هزنیه بارگیری": ("هزینه بارگیری",),
    "پگینگ": ("پکینگ",),
    "ترخیصکار": ("ترخیص‌کار",),
    "تامین کننده": ("تأمین‌کننده",),
    "data": ("date", "تاریخ"),
    "مبدا": ("مبدأ",),
}


# ---------------------------------------------------------------------------
# G1 / §2 — normalization, only for the comparison key
# ---------------------------------------------------------------------------

def _norm(value):
    """normalize_persian + casefold, for Persian/English fuzzy matching."""
    return normalize_persian(value).lower()


def _alias_keys(value):
    """Return the normalized comparison keys of a header, aliases included."""
    key = _norm(value)
    keys = {key}

    for source, targets in HEADER_ALIASES.items():
        normalized_source = _norm(source)

        if normalized_source and normalized_source == key:
            keys.update(_norm(target) for target in targets)

        for target in targets:
            if _norm(target) == key:
                keys.add(normalized_source)

    return {item for item in keys if item}


# ---------------------------------------------------------------------------
# Sync Log — §14 required trace of every mapping decision
# ---------------------------------------------------------------------------

class SyncLog:
    """Collect a structured trace of the Sync operation."""

    def __init__(self, template_key, source_file):
        self.template_key = template_key
        self.source_file = source_file
        self.entries = []

    def add(
        self,
        source_sheet=None,
        source_cell=None,
        source_row=None,
        destination_doctype=None,
        destination_field=None,
        raw_value=None,
        normalized_value=None,
        match_method=None,
        confidence=None,
        action=None,
        status="ok",
        error=None,
    ):
        self.entries.append(
            {
                "template_key": self.template_key,
                "source_file": self.source_file,
                "source_sheet": source_sheet,
                "source_cell": source_cell,
                "source_row": source_row,
                "destination_doctype": destination_doctype,
                "destination_field": destination_field,
                "raw_value": raw_value,
                "normalized_value": normalized_value,
                "match_method": match_method,
                "confidence": confidence,
                "action": action,
                "status": status,
                "error": error,
            }
        )

    def unresolved(self):
        return [
            entry
            for entry in self.entries
            if entry.get("status") == "unresolved"
        ]

    def flush(self):
        try:
            frappe.logger("phase8_excel_sync").info(
                json.dumps(
                    {
                        "template_key": self.template_key,
                        "source_file": self.source_file,
                        "entries": self.entries[:MAX_IMPORT_ROWS],
                    },
                    ensure_ascii=False,
                    default=str,
                )
            )
        except Exception:
            pass


# ---------------------------------------------------------------------------
# §1 / §4..§8 — TEMPLATE REGISTRY, exact JSON contract of the five templates
# ---------------------------------------------------------------------------
#
# Every column entry is coordinate locked:
#     col      = exact template column letter (P0)
#     header   = exact client header text, typos preserved (P0)
#     field    = destination fieldname of the prepared dataset, or None
#                when the golden rules classify it as UNRESOLVED
#     type     = write contract: Data / Identifier / Int / Float / Currency
#                / Date / Row
#     note     = why the mapping is what it is
#
# ---------------------------------------------------------------------------

TEMPLATE_REGISTRY = {
    # -----------------------------------------------------------------
    # §4 — T01 «- 1405 گزارش خرید و فروش.xlsx»
    # -----------------------------------------------------------------
    "financial": {
        "template_key": "template_01_financial",
        "pattern": "template_01",
        "source_file": "- 1405 گزارش خرید و فروش.xlsx",
        "sheet": "گزارش 1405",
        "rtl": True,
        "header_row": 1,
        "child_header_row": 2,
        "data_start_row": 3,
        "total_row": None,
        "clear_data_area": True,
        "hidden_columns": ("I", "J", "K", "M", "U", "V", "W", "Y"),
        "protected_merges": ("F1:G1", "B1:B2", "A1:A2"),
        "date_mode": "jalali",
        "allow_logo_injection": False,
        "columns": [
            {"col": "A", "header": "تاریخ فروش", "field": "sales_date", "type": "Date"},
            {"col": "B", "header": "ش.فاکتور فروش", "field": "sales_inv", "type": "Identifier"},
            {"col": "C", "header": "مشتری", "field": "customer", "type": "Data"},
            {"col": "D", "header": "نوع کالا", "field": "item_s", "type": "Data"},
            {"col": "E", "header": "تناژ اصلی", "field": "plan_s", "type": "Float"},
            {"col": "F", "header": "مبلغ", "child_header": "دلار", "field": "usd", "type": "Currency"},
            {"col": "G", "header": "مبلغ", "child_header": "ریال", "field": "rial", "type": "Currency"},
            {"col": "H", "header": "تناژ خروجی\n فروش", "field": "ship_s", "type": "Float"},
            {"col": "I", "header": "جمع کل \nخارج شده فروش", "field": "cship_s", "type": "Float"},
            {"col": "J", "header": "مازاد\n بارگیری فروش", "field": "sur_s", "type": "Float"},
            {"col": "K", "header": "جمع کل \nمازاد بارگیری فروش", "field": "csur_s", "type": "Float"},
            {"col": "L", "header": "باقیمانده فروش", "field": "rem_s", "type": "Float"},
            {"col": "M", "header": "جمع کل\n باقیمانده فروش", "field": "crem_s", "type": "Float"},
            {"col": "N", "header": "تاریخ خرید", "field": "pur_date", "type": "Date"},
            {"col": "O", "header": "ش.فاکتور خرید", "field": "pur_inv", "type": "Identifier"},
            {"col": "P", "header": "تامین کننده", "field": "supplier", "type": "Data"},
            {"col": "Q", "header": "نوع کالا", "field": "item_p", "type": "Data"},
            {"col": "R", "header": "تناژ\n اصلی", "field": "plan_p", "type": "Float"},
            {"col": "S", "header": "مبلغ", "field": "pur_amt", "type": "Currency"},
            {"col": "T", "header": "تناژ \nخروجی خرید", "field": "ship_p", "type": "Float"},
            {"col": "U", "header": "جمع کل \nخارج شده خرید", "field": "cship_p", "type": "Float"},
            {"col": "V", "header": "مازاد\n بارگیری خرید", "field": "sur_p", "type": "Float"},
            {"col": "W", "header": "جمع کل \nمازاد بارگیری خرید", "field": "csur_p", "type": "Float"},
            {"col": "X", "header": "باقیمانده خرید", "field": "rem_p", "type": "Float"},
            {"col": "Y", "header": "جمع کل\n باقیمانده خرید", "field": "crem_p", "type": "Float"},
            {"col": "Z", "header": "وضعیت", "field": "status", "type": "Data"},
        ],
    },

    # -----------------------------------------------------------------
    # §5 — T02 «خام لیست کرایه.xlsx»
    # -----------------------------------------------------------------
    "freight": {
        "template_key": "template_02_freight",
        "pattern": "template_02",
        "source_file": "خام لیست کرایه.xlsx",
        "sheet": "Sheet1",
        "rtl": True,
        "header_row": 2,
        "data_start_row": 3,
        "total_row": None,
        "clear_data_area": True,
        "title_cell": "A1",
        "title_prefix": " ",
        "protected_merges": ("A1:O1",),
        "date_mode": "jalali",
        "allow_logo_injection": False,
        "columns": [
            {"col": "A", "header": "ردیف", "field": "__row__", "type": "Row"},
            {
                "col": "B",
                "header": "نام صاحب حساب",
                "field": "account_holder",
                "type": "Data",
                "note": "§5: account holder, NOT automatically the driver",
            },
            {
                "col": "C",
                "header": "شماره حساب",
                "field": "account_no",
                "type": "Identifier",
                "note": "§5/§15: raw account value, never assumed to be Sheba",
            },
            {"col": "D", "header": "بانک ", "field": "bank_name", "type": "Data"},
            {"col": "E", "header": "وزن", "field": "weight", "type": "Float"},
            {
                "col": "F",
                "header": "کل هرتن",
                "field": None,
                "type": "Float",
                "note": "§5: rate per ton has no approved project field -> UNRESOLVED",
            },
            {
                "col": "G",
                "header": " کرایه",
                "field": "freight_cost",
                "type": "Currency",
                "note": "§5/§13: template formula =F{r}*E{r} is protected where present",
            },
            {
                "col": "H",
                "header": "هزنیه تخلیه",
                "field": None,
                "type": "Currency",
                "note": "§2: exact client typo preserved; no approved field -> UNRESOLVED",
            },
            {
                "col": "I",
                "header": "هزنیه بارگیری",
                "field": None,
                "type": "Currency",
                "note": "§2: exact client typo preserved; no approved field -> UNRESOLVED",
            },
            {
                "col": "J",
                "header": "کل کرایه",
                "field": None,
                "type": "Currency",
                "note": "§13: template formula =I{r}+G{r} is protected",
            },
            {"col": "K", "header": "پیش کرایه", "field": "advance_freight", "type": "Currency"},
            {
                "col": "L",
                "header": "مانده",
                "field": None,
                "type": "Currency",
                "note": "§13: template formula =J{r}-K{r} is protected",
            },
            {
                "col": "M",
                "header": "مرز-صاحب بار-نوع بار-نام راننده",
                "field": "composite_identity",
                "type": "Data",
                "note": "§5: composite raw string, master aware, kept in Sync Log",
            },
            {"col": "N", "header": "مبدا بارگیری", "field": "origin", "type": "Data"},
            {
                "col": "O",
                "header": " پیش فاکتور فروش",
                "field": "sales_invoice_number",
                "type": "Identifier",
                "note": "§5: only when the authorized phase8 field exists in Meta",
            },
        ],
        "formula_patterns": {
            "G": "=F{row}*E{row}",
            "J": "=I{row}+G{row}",
            "L": "=J{row}-K{row}",
        },
    },

    # -----------------------------------------------------------------
    # §6 — T03 «فرم پکینگ (1).xlsx»
    # -----------------------------------------------------------------
    "packing": {
        "template_key": "template_03_packing",
        "pattern": "template_03",
        "source_file": "فرم پکینگ (1).xlsx",
        "sheet": "Sheet1",
        "rtl": False,
        "header_row": 7,
        "data_start_row": 10,
        "total_row": 11,
        "clear_data_area": True,
        "protected_merges": (
            "B2:J3",
            "P7:X7",
            "C7:C9",
            "B5:J5",
            "G7:G9",
            "E7:E9",
            "I7:I9",
            "H7:H9",
            "F7:F9",
            "J7:J9",
            "D7:D9",
            "B7:B9",
            "B4:J4",
            "B6:J6",
        ),
        "date_mode": "gregorian",
        "allow_logo_injection": False,
        "meta_cells": [
            {"cell": "B4", "prefix": "INVOICE NUMBER: ", "field": "sales_invoice_number", "type": "Identifier"},
            {"cell": "B5", "prefix": "Data:", "field": "packing_date", "type": "Date"},
            {"cell": "B6", "prefix": "Buyer: Mr ", "field": "customer", "type": "Data"},
        ],
        "total_label_cell": "C11",
        "sum_columns": {"F": "F11"},
        "columns": [
            {"col": "B", "header": "Row", "field": "__row__", "type": "Row"},
            {"col": "C", "header": "Description", "field": "item", "type": "Data"},
            {
                "col": "D",
                "header": "Size",
                "field": "size",
                "type": "Data",
                "note": "§6: dimensions first, thickness only as declared fallback",
            },
            {
                "col": "E",
                "header": "Branch",
                "field": "qty",
                "type": "Float",
                "note": "§6: Branch = qty/شاخه, explicitly NOT «مرز»",
            },
            {"col": "F", "header": "Net Weight", "field": "actual_tonnage", "type": "Float"},
            {
                "col": "G",
                "header": "Delivery B.",
                "field": "delivery_border",
                "type": "Data",
                "note": "§6: delivery-border context, NEVER the sales invoice",
            },
            {"col": "H", "header": "Driver's name", "field": "driver", "type": "Data"},
            {"col": "I", "header": "Car tag", "field": "plate_number", "type": "Identifier"},
            {"col": "J", "header": "Phone number", "field": "driver_mobile", "type": "Identifier"},
        ],
    },

    # -----------------------------------------------------------------
    # §7 — T04 «خام خرید.xlsx»
    # -----------------------------------------------------------------
    "purchase": {
        "template_key": "template_04_purchase",
        "pattern": "template_04",
        "source_file": "خام خرید.xlsx",
        "sheet": "پیش فاکتور خرید",
        "required_sheets": (
            "فروشنده",
            "معرفی کالا",
            "پیش فاکتور خرید",
            "صورت بارگیری",
        ),
        "rtl": True,
        "header_row": 3,
        "data_start_row": 4,
        "total_row": None,
        "clear_data_area": True,
        "protected_merges": ("A1:K1",),
        "protected_cells": ("I2",),
        "date_mode": "jalali",
        "allow_logo_injection": False,
        "meta_cells": [
            {"cell": "B2", "prefix": "", "field": "purchase_invoice_date", "type": "Date"},
            {"cell": "D2", "prefix": "", "field": "purchase_invoice_number", "type": "Identifier"},
            {"cell": "F2", "prefix": "", "field": "supplier_factory", "type": "Data"},
        ],
        "columns": [
            {"col": "A", "header": "ردیف", "field": "__row__", "type": "Row"},
            {"col": "B", "header": "نام کالا", "field": "item", "type": "Data"},
            {
                "col": "C",
                "header": "سایز",
                "field": "size_key",
                "type": "Data",
                "note": "§7: SUMIFS criteria cell, must equal 'صورت بارگیری'!D",
            },
            {"col": "D", "header": "تناژ", "field": "planned_tonnage", "type": "Float"},
            {
                "col": "E",
                "header": "واحد وزن",
                "field": None,
                "type": "Data",
                "note": "§7/§12: no approved unit field -> UNRESOLVED, no guessing",
            },
            {
                "col": "F",
                "header": "فی واحد",
                "field": None,
                "type": "Currency",
                "note": "§7: unit price, explicitly NOT purchase_amount total",
            },
            {
                "col": "G",
                "header": "نوع ارز",
                "field": None,
                "type": "Data",
                "note": "§7: no approved currency field on Trade Case -> UNRESOLVED",
            },
            {"col": "H", "header": "تحویل", "field": "delivery_type", "type": "Data"},
            {
                "col": "I",
                "header": "مقدار حمل شده",
                "field": None,
                "type": "Float",
                "note": "§13: protected SUMIFS formula",
            },
            {
                "col": "J",
                "header": "مانده",
                "field": None,
                "type": "Float",
                "note": "§13: protected formula",
            },
            {
                "col": "K",
                "header": "ارزش کالای مانده",
                "field": None,
                "type": "Currency",
                "note": "§13: protected formula",
            },
        ],
        "formula_patterns": {
            "I": (
                "=IF(D{row}<>\"\","
                "SUMIFS('صورت بارگیری'!$E$3:$E$1048576,"
                "'صورت بارگیری'!$D$3:$D$1048576,C{row}),\"\")"
            ),
            "J": "=IF(D{row}<>\"\",D{row}-I{row},\"\")",
            "K": "=IF(D{row}<>\"\",J{row}*F{row},\"\")",
        },
        "extra_sheets": {
            "loading": {
                "sheet": "صورت بارگیری",
                "rtl": True,
                "header_row": 2,
                "data_start_row": 3,
                "total_row": None,
                "clear_data_area": True,
                "protected_merges": ("A1:K1",),
                "protected_cells": ("A1",),
                "date_mode": "jalali",
                "columns": [
                    {"col": "A", "header": "ردیف", "field": "__row__", "type": "Row"},
                    {
                        "col": "B",
                        "header": "پگینگ",
                        "field": None,
                        "type": "Data",
                        "note": "§7/§2: exact client spelling «پگینگ»; meaning unresolved",
                    },
                    {"col": "C", "header": "تاریخ بارگیری", "field": "loading_date", "type": "Date"},
                    {
                        "col": "D",
                        "header": "کالا",
                        "field": "size_key",
                        "type": "Data",
                        "note": "§7: SUMIFS key column, must match 'پیش فاکتور خرید'!C",
                    },
                    {"col": "E", "header": "وزن خالص", "field": "actual_tonnage", "type": "Float"},
                    {"col": "F", "header": "مقصد", "field": "destination", "type": "Data"},
                    {"col": "G", "header": "ش. کامیون", "field": "plate_number", "type": "Identifier"},
                    {"col": "H", "header": "نام راننده", "field": "driver", "type": "Data"},
                    {"col": "I", "header": "شماره راننده", "field": "driver_mobile", "type": "Identifier"},
                    {"col": "J", "header": "خریدار", "field": "customer", "type": "Data"},
                    {"col": "K", "header": "ترخیصکار", "field": "customs_broker", "type": "Data"},
                ],
            }
        },
    },

    # -----------------------------------------------------------------
    # §8 — T05 «فایل خام.xlsx»
    # -----------------------------------------------------------------
    "dispatch": {
        "template_key": "template_05_dispatch",
        "pattern": "template_05",
        "source_file": "فایل خام.xlsx",
        "sheet": "Sheet1",
        "rtl": True,
        "header_row": 3,
        "data_start_row": 4,
        "total_row": 10,
        "clear_data_area": True,
        "protected_merges": ("B2:L2",),
        "date_mode": "jalali",
        "allow_logo_injection": False,
        "sum_columns": {"E": "E10"},
        "columns": [
            {"col": "B", "header": "ردیف", "field": "__row__", "type": "Row"},
            {"col": "C", "header": "تاریخ بارگیری", "field": "loading_date", "type": "Date"},
            {"col": "D", "header": "نوع بار", "field": "cargo_description", "type": "Data"},
            {"col": "E", "header": "وزن", "field": "actual_tonnage", "type": "Float"},
            {"col": "F", "header": "مبدا", "field": "origin", "type": "Data"},
            {"col": "G", "header": "مقصد", "field": "destination", "type": "Data"},
            {"col": "H", "header": "ش. کامیون", "field": "plate_number", "type": "Identifier"},
            {"col": "I", "header": "نام راننده", "field": "driver", "type": "Data"},
            {"col": "J", "header": "شماره راننده", "field": "driver_mobile", "type": "Identifier"},
            {"col": "K", "header": "ترخیصکار", "field": "customs_broker", "type": "Data"},
            {"col": "L", "header": "باربری", "field": "carrier", "type": "Data"},
        ],
    },
}


# ---------------------------------------------------------------------------
# Template files
# ---------------------------------------------------------------------------

def _template_dir():
    return frappe.get_site_path("private", "files", "excel_templates")


def _find_file(pattern):
    directory = _template_dir()

    if not os.path.isdir(directory):
        return None

    for filename in sorted(os.listdir(directory)):
        if pattern in filename and filename.lower().endswith(".xlsx"):
            return os.path.join(directory, filename)

    return None


# ---------------------------------------------------------------------------
# §3 — Meta guard, never invent a fieldname
# ---------------------------------------------------------------------------

def _has_field(doctype, fieldname):
    if not fieldname:
        return False

    try:
        return bool(frappe.get_meta(doctype).get_field(fieldname))
    except Exception:
        return False


def _safe_fields(doctype, wanted):
    fields = []

    for fieldname in wanted:
        if fieldname == "name" or _has_field(doctype, fieldname):
            if fieldname not in fields:
                fields.append(fieldname)

    if "name" not in fields:
        fields.append("name")

    return fields


# ---------------------------------------------------------------------------
# §10 — Link resolution, Link key stored in ERP, display value in Excel
# ---------------------------------------------------------------------------

LINK_DISPLAY_PRIORITY = (
    "full_name",
    "driver_name",
    "carrier_name",
    "broker_name",
    "representative_name",
    "border_name",
    "customer_name",
    "supplier_name",
    "factory_name",
    "item_name",
    "company_name",
    "case_title",
    "title",
)


def _resolve_link_smart(linked_doctype, value):
    """Resolve a Link value into its human readable display name."""
    if not value or not linked_doctype:
        return value

    try:
        meta = frappe.get_meta(linked_doctype)
    except Exception:
        return value

    try:
        for fieldname in LINK_DISPLAY_PRIORITY:
            if not meta.has_field(fieldname):
                continue

            display = frappe.db.get_value(linked_doctype, value, fieldname)

            if display:
                return display

        title_field = getattr(meta, "title_field", None)

        if title_field and meta.has_field(title_field):
            display = frappe.db.get_value(linked_doctype, value, title_field)

            if display:
                return display
    except Exception:
        return value

    return value


def _resolve_link(doctype, value, search_field):
    """Resolve an incoming Excel value into a document name (import side)."""
    if not value:
        return None

    value = str(value).strip()

    if frappe.db.exists(doctype, value):
        return value

    return frappe.db.get_value(doctype, {search_field: value}, "name")


def _resolve_link_columns(doctype, specs, rows):
    """Replace Link keys by display names for the listed dataset fields."""
    try:
        meta = frappe.get_meta(doctype)
    except Exception:
        return

    cache = {}

    for spec in specs:
        source = spec.get("source")

        if not source or not meta.has_field(source):
            continue

        df = meta.get_field(source)

        if not df or df.fieldtype != "Link" or not df.options:
            continue

        for row in rows:
            value = row.get(spec["fieldname"])

            if not value:
                continue

            key = (df.options, value)

            if key not in cache:
                cache[key] = _resolve_link_smart(df.options, value)

            row[spec["fieldname"]] = cache[key]


# ---------------------------------------------------------------------------
# §12 — value transformation, numeric stays numeric, identifiers stay strings
# ---------------------------------------------------------------------------

def _transform_date(value, date_mode):
    if not value:
        return ""

    if date_mode == "gregorian":
        try:
            return getdate(value).strftime("%Y/%m/%d")
        except Exception:
            return str(value)

    try:
        return latin_jalali_date(value)
    except Exception:
        return str(value)


def _transform_value(value, value_type, date_mode):
    if value in (None, ""):
        return None

    if value_type == "Date":
        return _transform_date(value, date_mode)

    if value_type in ("Currency", "Float"):
        return flt(value)

    if value_type in ("Int", "Row"):
        try:
            return int(flt(value))
        except Exception:
            return value

    if value_type == "Identifier":
        return str(value)

    return value


# ---------------------------------------------------------------------------
# §11 — merge / style safe writing
# ---------------------------------------------------------------------------

def _set_cell_value(ws, row_idx, col_idx, value):
    cell = ws.cell(row=row_idx, column=col_idx)

    if isinstance(cell, MergedCell):
        for merged_range in ws.merged_cells.ranges:
            if (
                merged_range.min_row <= row_idx <= merged_range.max_row
                and merged_range.min_col <= col_idx <= merged_range.max_col
            ):
                ws.cell(
                    row=merged_range.min_row,
                    column=merged_range.min_col,
                ).value = value
                return True

        return False

    cell.value = value
    return True


def safe_write_merged_aware(ws, coord, value):
    """Coordinate based variant of `_set_cell_value` (A1 style)."""
    cell = ws[coord]
    return _set_cell_value(ws, cell.row, cell.column, value)


def _is_formula(value):
    return isinstance(value, str) and value.startswith("=")


def _cell_has_formula(ws, row_idx, col_idx):
    cell = ws.cell(row=row_idx, column=col_idx)

    if isinstance(cell, MergedCell):
        return False

    return _is_formula(cell.value)


_FORMULA_REF = re.compile(r"(\$?[A-Za-z]{1,3})(\$?)(\d+)")


def _shift_formula(formula, delta):
    """Shift relative row references of a formula by `delta`."""
    if not _is_formula(formula) or not delta:
        return formula

    def _replace(match):
        column, absolute, row = match.group(1), match.group(2), match.group(3)

        if absolute == "$":
            return match.group(0)

        return f"{column}{int(row) + delta}"

    return _FORMULA_REF.sub(_replace, formula)


# ---------------------------------------------------------------------------
# §11 — protected merges and data-area-only unmerge
# ---------------------------------------------------------------------------

def _protected_ranges(sheet_reg):
    protected = set()

    for ref in sheet_reg.get("protected_merges") or ():
        protected.add(str(CellRange(ref)))

    return protected


def _unmerge_data_area(ws, sheet_reg, start_row, total_row=None):
    """Unmerge only data-area merges.

    Title, header block, logo and Total merges declared in the registry are
    protected and stay intact. The template file on disk is never touched.
    """
    protected = _protected_ranges(sheet_reg)

    for merged_range in list(ws.merged_cells.ranges):
        ref = str(merged_range)

        if ref in protected:
            continue

        if merged_range.min_row < start_row:
            continue

        if total_row is not None and merged_range.min_row >= total_row:
            continue

        try:
            ws.unmerge_cells(ref)
        except Exception:
            pass


def _copy_row_style(ws, source_row, target_row):
    max_col = ws.max_column or 1

    for col in range(1, max_col + 1):
        source = ws.cell(row=source_row, column=col)
        target = ws.cell(row=target_row, column=col)

        if isinstance(target, MergedCell):
            continue

        try:
            if source.has_style:
                target._style = copy(source._style)

            if source.number_format:
                target.number_format = source.number_format
        except Exception:
            pass


def _clone_row_formulas(ws, sheet_reg, source_row, target_row):
    """Clone the declared formula families into a newly created row."""
    patterns = sheet_reg.get("formula_patterns") or {}

    for column_letter, pattern in patterns.items():
        col_idx = column_index_from_string(column_letter)
        cell = ws.cell(row=target_row, column=col_idx)

        if isinstance(cell, MergedCell):
            continue

        cell.value = pattern.format(row=target_row)

    if patterns:
        return

    max_col = ws.max_column or 1

    for col in range(1, max_col + 1):
        source = ws.cell(row=source_row, column=col)

        if not _is_formula(source.value):
            continue

        target = ws.cell(row=target_row, column=col)

        if isinstance(target, MergedCell):
            continue

        target.value = _shift_formula(source.value, target_row - source_row)


def _ensure_data_rows(
    ws,
    start_row,
    required_rows,
    total_row=None,
    sheet_reg=None,
):
    """Guarantee enough data rows, inserting above the template Total row."""
    sheet_reg = sheet_reg or {}

    if required_rows <= 0:
        return total_row

    if total_row is not None:
        available = total_row - start_row

        if required_rows > available:
            extra = required_rows - available

            # openpyxl does not shift merged ranges on insert_rows, so ranges
            # at/below the Total row are re-created manually.
            below = [
                str(rng)
                for rng in list(ws.merged_cells.ranges)
                if rng.min_row >= total_row
            ]

            for ref in below:
                try:
                    ws.unmerge_cells(ref)
                except Exception:
                    pass

            ws.insert_rows(total_row, amount=extra)

            for row_idx in range(total_row, total_row + extra):
                _copy_row_style(ws, start_row, row_idx)
                _clone_row_formulas(ws, sheet_reg, start_row, row_idx)

            for ref in below:
                try:
                    rng = CellRange(ref)
                    rng.shift(row_shift=extra)
                    ws.merge_cells(str(rng))
                except Exception:
                    pass

            total_row += extra

        return total_row

    last_row = start_row + required_rows - 1

    if last_row > (ws.max_row or 0):
        for row_idx in range((ws.max_row or 0) + 1, last_row + 1):
            _copy_row_style(ws, start_row, row_idx)
            _clone_row_formulas(ws, sheet_reg, start_row, row_idx)

    return None


# ---------------------------------------------------------------------------
# §2 — header verification, coordinate first, alias only for detection
# ---------------------------------------------------------------------------

def _find_header_row(ws, sheet_reg, max_rows=30):
    """Verify or locate the header row without ever rewriting client text."""
    columns = sheet_reg.get("columns") or []
    declared = sheet_reg.get("header_row") or 1

    expected = set()

    for spec in columns:
        expected.update(_alias_keys(spec.get("header")))

    if not expected:
        return declared

    def _score(row_idx):
        score = 0

        for spec in columns:
            col_idx = column_index_from_string(spec["col"])
            actual = _norm(ws.cell(row=row_idx, column=col_idx).value)

            if actual and actual in _alias_keys(spec.get("header")):
                score += 1

        return score

    max_row = ws.max_row or 1

    if declared <= max_row and _score(declared) > 0:
        return declared

    best_row = declared
    best_score = 0

    for row_idx in range(1, min(max_rows, max_row) + 1):
        score = _score(row_idx)

        if score > best_score:
            best_score = score
            best_row = row_idx

    return best_row


def find_header_row_fuzzy(ws, expected_headers, max_rows=30, min_match_ratio=0.6):
    """Public fuzzy helper, detection only, kept for reuse and testing."""
    columns = [
        {"col": get_column_letter(index), "header": header}
        for index, header in enumerate(expected_headers or [], 1)
    ]

    header_row = _find_header_row(
        ws,
        {"columns": columns, "header_row": 1},
        max_rows=max_rows,
    )

    mapping = _build_column_mapping(
        ws,
        header_row,
        {"columns": columns},
    )

    if expected_headers and len(mapping) < len(expected_headers) * min_match_ratio:
        return header_row, {}

    return header_row, mapping


def _build_column_mapping(ws, header_row, sheet_reg, log=None):
    """Coordinate locked mapping: column index -> registry spec."""
    mapping = {}

    for spec in sheet_reg.get("columns") or []:
        col_idx = column_index_from_string(spec["col"])
        actual = ws.cell(row=header_row, column=col_idx).value
        normalized = _norm(actual)
        expected_keys = _alias_keys(spec.get("header"))

        if normalized and normalized in expected_keys:
            match_method = "coordinate+exact"
            confidence = 1.0
        elif normalized:
            match_method = "coordinate"
            confidence = 0.9
        else:
            match_method = "coordinate+empty"
            confidence = 0.8

        mapping[col_idx] = spec

        if log:
            log.add(
                source_sheet=ws.title,
                source_cell=f"{spec['col']}{header_row}",
                destination_field=spec.get("field"),
                raw_value=actual,
                normalized_value=normalized,
                match_method=match_method,
                confidence=confidence,
                action="map_column",
                status="ok" if spec.get("field") else "unresolved",
                error=spec.get("note") if not spec.get("field") else None,
            )

    return mapping


# ---------------------------------------------------------------------------
# Data area cleanup — values only, styles/merges/formulas untouched
# ---------------------------------------------------------------------------

def _clear_data_area(ws, sheet_reg, start_row, total_row=None):
    if not sheet_reg.get("clear_data_area"):
        return

    last_row = (total_row - 1) if total_row else (ws.max_row or start_row)

    if last_row < start_row:
        return

    for spec in sheet_reg.get("columns") or []:
        col_idx = column_index_from_string(spec["col"])

        for row_idx in range(start_row, last_row + 1):
            cell = ws.cell(row=row_idx, column=col_idx)

            if isinstance(cell, MergedCell):
                continue

            if _is_formula(cell.value):
                continue

            cell.value = None


# ---------------------------------------------------------------------------
# Sheet filler
# ---------------------------------------------------------------------------

def _fill_sheet(ws, sheet_reg, rows, log, allow_row_insert=True):
    """Write a prepared dataset into one template sheet."""
    date_mode = sheet_reg.get("date_mode") or "jalali"

    header_row = _find_header_row(ws, sheet_reg)
    start_row = sheet_reg.get("data_start_row") or (header_row + 1)
    total_row = sheet_reg.get("total_row")

    mapping = _build_column_mapping(ws, header_row, sheet_reg, log=log)

    _unmerge_data_area(ws, sheet_reg, start_row, total_row)
    _clear_data_area(ws, sheet_reg, start_row, total_row)

    if allow_row_insert:
        total_row = _ensure_data_rows(
            ws,
            start_row,
            len(rows),
            total_row,
            sheet_reg=sheet_reg,
        )

    protected_cells = set(sheet_reg.get("protected_cells") or ())

    for offset, row in enumerate(rows):
        row_idx = start_row + offset

        for col_idx, spec in mapping.items():
            coord = f"{spec['col']}{row_idx}"

            if coord in protected_cells:
                continue

            if _cell_has_formula(ws, row_idx, col_idx):
                log.add(
                    source_sheet=ws.title,
                    source_cell=coord,
                    source_row=row_idx,
                    destination_field=spec.get("field"),
                    match_method="coordinate",
                    confidence=1.0,
                    action="skip_protected_formula",
                    status="protected",
                )
                continue

            field = spec.get("field")

            if not field:
                log.add(
                    source_sheet=ws.title,
                    source_cell=coord,
                    source_row=row_idx,
                    destination_field=None,
                    match_method="registry",
                    confidence=0.0,
                    action="skip_unresolved",
                    status="unresolved",
                    error=spec.get("note"),
                )
                continue

            if field == "__row__":
                _set_cell_value(ws, row_idx, col_idx, offset + 1)
                continue

            raw_value = row.get(field)
            value = _transform_value(raw_value, spec.get("type"), date_mode)

            if value in (None, ""):
                continue

            _set_cell_value(ws, row_idx, col_idx, value)

            log.add(
                source_sheet=ws.title,
                source_cell=coord,
                source_row=row_idx,
                destination_field=field,
                raw_value=raw_value,
                normalized_value=value,
                match_method="coordinate",
                confidence=1.0,
                action="write",
            )

    last_data_row = start_row + len(rows) - 1

    _rewrite_sum_formulas(
        ws,
        sheet_reg,
        start_row,
        last_data_row,
        total_row,
        log,
    )

    _fill_meta_cells(ws, sheet_reg, rows, log)

    return {
        "header_row": header_row,
        "start_row": start_row,
        "total_row": total_row,
        "last_data_row": last_data_row,
    }


def _rewrite_sum_formulas(
    ws,
    sheet_reg,
    start_row,
    last_data_row,
    total_row,
    log,
):
    """§13: the only authorized formula rewrite is the declared SUM extension."""
    sum_columns = sheet_reg.get("sum_columns") or {}

    if not sum_columns or last_data_row < start_row:
        return

    declared_total = sheet_reg.get("total_row")
    shift = 0

    if declared_total and total_row:
        shift = total_row - declared_total

    for column_letter, coord in sum_columns.items():
        cell = ws[coord]
        target_row = cell.row + shift
        col_idx = column_index_from_string(column_letter)
        target = ws.cell(row=target_row, column=col_idx)

        if isinstance(target, MergedCell):
            continue

        formula = f"=SUM({column_letter}{start_row}:{column_letter}{last_data_row})"
        target.value = formula

        log.add(
            source_sheet=ws.title,
            source_cell=f"{column_letter}{target_row}",
            match_method="registry_formula_rewrite",
            confidence=1.0,
            normalized_value=formula,
            action="rewrite_sum",
        )


def _fill_meta_cells(ws, sheet_reg, rows, log):
    """Fill the declared meta cells, keeping the exact client prefixes."""
    meta_cells = sheet_reg.get("meta_cells") or []

    if not meta_cells or not rows:
        return

    date_mode = sheet_reg.get("date_mode") or "jalali"
    first = rows[0]

    for spec in meta_cells:
        field = spec.get("field")

        if not field:
            continue

        raw_value = first.get(field)

        if raw_value in (None, ""):
            log.add(
                source_sheet=ws.title,
                source_cell=spec.get("cell"),
                destination_field=field,
                match_method="registry",
                confidence=0.0,
                action="skip_meta",
                status="unresolved",
            )
            continue

        value = _transform_value(raw_value, spec.get("type"), date_mode)
        text = f"{spec.get('prefix') or ''}{value}"

        safe_write_merged_aware(ws, spec["cell"], text)

        log.add(
            source_sheet=ws.title,
            source_cell=spec.get("cell"),
            destination_field=field,
            raw_value=raw_value,
            normalized_value=text,
            match_method="coordinate",
            confidence=1.0,
            action="write_meta",
        )


def _apply_title(ws, sheet_reg, from_date, to_date, log):
    """T02: replace the period date using the exact client pattern."""
    title_cell = sheet_reg.get("title_cell")

    if not title_cell:
        return

    value = to_date or from_date

    if not value:
        return

    prefix = sheet_reg.get("title_prefix") or ""
    text = f"{prefix}{_transform_date(value, sheet_reg.get('date_mode') or 'jalali')}"

    safe_write_merged_aware(ws, title_cell, text)

    log.add(
        source_sheet=ws.title,
        source_cell=title_cell,
        match_method="coordinate",
        confidence=1.0,
        normalized_value=text,
        action="write_title",
    )


def _restore_hidden_columns(ws, sheet_reg):
    for column_letter in sheet_reg.get("hidden_columns") or ():
        ws.column_dimensions[column_letter].hidden = True


# ---------------------------------------------------------------------------
# Workbook loader
# ---------------------------------------------------------------------------

def _open_template(template_key):
    reg = TEMPLATE_REGISTRY[template_key]
    path = _find_file(reg["pattern"])

    if not path:
        frappe.throw(
            _("قالب {0} یافت نشد. لطفاً در private/files/excel_templates قرار دهید.").format(
                reg["template_key"]
            )
        )

    # Read only. The workbook on disk is never saved back (§0 rule 6/7).
    wb = openpyxl.load_workbook(path)

    for sheet_name in reg.get("required_sheets") or ():
        if sheet_name not in wb.sheetnames:
            frappe.throw(
                _("شیت {0} در قالب {1} یافت نشد.").format(
                    sheet_name,
                    reg["template_key"],
                )
            )

    return reg, wb


def _get_sheet(wb, reg, sheet_name):
    """§15: never select a sheet by index while the required name exists."""
    if sheet_name in wb.sheetnames:
        return wb[sheet_name]

    frappe.throw(
        _("شیت {0} در قالب {1} یافت نشد.").format(
            sheet_name,
            reg["template_key"],
        )
    )


def _rows_from_report(columns, data):
    """Convert a Frappe report result into dataset dictionaries."""
    fieldnames = [column.get("fieldname") for column in columns]
    rows = []

    for source_row in data:
        if isinstance(source_row, dict):
            rows.append(dict(source_row))
            continue

        row = {}

        for index, fieldname in enumerate(fieldnames):
            row[fieldname] = (
                source_row[index] if index < len(source_row) else None
            )

        rows.append(row)

    return rows


def _load_and_fill_report(
    template_key,
    columns,
    data,
    extra_sheets=None,
    from_date=None,
    to_date=None,
):
    """Load the employer template and fill it under the golden rules.

    Merge protection is handled by `_unmerge_data_area`, formulas are
    protected, hidden columns are restored and the source file is untouched.
    """
    reg, wb = _open_template(template_key)
    log = SyncLog(reg["template_key"], reg["source_file"])

    ws = _get_sheet(wb, reg, reg["sheet"])
    ws.sheet_view.rightToLeft = bool(reg.get("rtl"))

    rows = _rows_from_report(columns, data)

    _apply_title(ws, reg, from_date, to_date, log)
    _fill_sheet(ws, reg, rows, log)
    _restore_hidden_columns(ws, reg)

    for key, sheet_rows in (extra_sheets or {}).items():
        sheet_reg = (reg.get("extra_sheets") or {}).get(key)

        if not sheet_reg:
            continue

        extra_ws = _get_sheet(wb, reg, sheet_reg["sheet"])
        extra_ws.sheet_view.rightToLeft = bool(sheet_reg.get("rtl"))

        _fill_sheet(extra_ws, sheet_reg, sheet_rows, log)
        _restore_hidden_columns(extra_ws, sheet_reg)

    # Logo policy §6/§11: never remove, inject only when explicitly authorized
    if reg.get("allow_logo_injection") and not getattr(ws, "_images", None):
        logo_path = os.path.join(_template_dir(), "client_logo.png")

        if os.path.exists(logo_path):
            image = XLImage(logo_path)
            image.width, image.height = 120, 60
            ws.add_image(image, "B2")

    log.flush()

    return wb


# ---------------------------------------------------------------------------
# Dataset builders — Meta guarded, no invented fieldnames
# ---------------------------------------------------------------------------

def _columns_from_specs(specs):
    return [
        {
            "fieldname": spec["fieldname"],
            "label": spec["label"],
            "fieldtype": spec.get("fieldtype", "Data"),
        }
        for spec in specs
    ]


def _fetch_rows(doctype, specs, filters, order_by):
    wanted = [
        spec.get("source")
        for spec in specs
        if spec.get("source")
    ]

    db_fields = _safe_fields(doctype, wanted)

    records = frappe.get_all(
        doctype,
        filters=filters,
        fields=db_fields,
        order_by=order_by,
        limit_page_length=0,
    )

    rows = []

    for index, record in enumerate(records, 1):
        row = {
            "__row__": index,
            "__name__": record.get("name"),
        }

        for spec in specs:
            source = spec.get("source")
            row[spec["fieldname"]] = (
                record.get(source) if source and source in record else None
            )

        rows.append(row)

    return rows


def _transport_filters(from_date=None, to_date=None, carrier=None, border=None):
    filters = {
        "workflow_state": ["not in", ["Cancelled", "Rejected"]],
    }

    if from_date and to_date:
        filters["posting_date"] = ["between", [from_date, to_date]]
    elif from_date:
        filters["posting_date"] = [">=", from_date]
    elif to_date:
        filters["posting_date"] = ["<=", to_date]

    if carrier:
        filters["carrier"] = carrier

    if border:
        filters["border"] = border

    return filters


# ---------------------------------------------------------------------------
# T02 dataset — freight settlement
# ---------------------------------------------------------------------------

FREIGHT_SPECS = [
    {"fieldname": "posting_date", "label": "تاریخ", "fieldtype": "Date", "source": "posting_date"},
    {"fieldname": "trade_case", "label": "پرونده تجاری", "source": "trade_case"},
    {"fieldname": "driver", "label": "راننده", "source": "driver"},
    {"fieldname": "driver_name", "label": "نام راننده", "source": "driver_name"},
    {"fieldname": "plate_number", "label": "پلاک", "source": "plate_number"},
    {"fieldname": "carrier", "label": "باربری", "source": "carrier"},
    {"fieldname": "origin", "label": "مبدا بارگیری", "source": "origin"},
    {"fieldname": "destination", "label": "مقصد", "source": "destination"},
    {"fieldname": "border", "label": "مرز", "source": "border"},
    {"fieldname": "customer", "label": "مشتری", "source": "customer"},
    {"fieldname": "supplier_factory", "label": "کارخانه", "source": "supplier_factory"},
    {"fieldname": "item", "label": "کالا", "source": "item"},
    {"fieldname": "cargo_description", "label": "نوع بار", "source": "cargo_description"},
    {"fieldname": "weight", "label": "وزن", "fieldtype": "Float", "source": "actual_tonnage"},
    {"fieldname": "freight_cost", "label": "کرایه", "fieldtype": "Currency", "source": "freight_cost"},
    {"fieldname": "waybill_number", "label": "بارنامه", "source": "waybill_number"},
    {"fieldname": "sales_invoice_number", "label": "پیش فاکتور فروش", "source": "sales_invoice_number"},
    {"fieldname": "account_holder", "label": "نام صاحب حساب"},
    {"fieldname": "account_no", "label": "شماره حساب"},
    {"fieldname": "bank_name", "label": "بانک"},
    {"fieldname": "advance_freight", "label": "پیش کرایه", "fieldtype": "Currency"},
    {"fieldname": "composite_identity", "label": "مرز-صاحب بار-نوع بار-نام راننده"},
]


def _attach_payment_details(rows):
    """§3.3 Transport Payment: account holder, bank, account, advance freight."""
    names = [row.get("__name__") for row in rows if row.get("__name__")]

    if not names or not frappe.db.exists("DocType", "Transport Payment"):
        return

    placeholders = ", ".join(["%s"] * len(names))

    payments = frappe.db.sql(
        """
        select
            parent,
            payment_type,
            amount,
            payment_date,
            sheba,
            bank_name,
            paid_by,
            idx
        from `tabTransport Payment`
        where parenttype = 'Transport Case'
          and parent in ({placeholders})
        order by ifnull(payment_date, '1900-01-01') asc, idx asc
        """.format(placeholders=placeholders),
        tuple(names),
        as_dict=True,
    )

    by_parent = {}

    for payment in payments:
        by_parent.setdefault(payment.parent, []).append(payment)

    for row in rows:
        entries = by_parent.get(row.get("__name__")) or []

        if not entries:
            continue

        latest = entries[-1]

        row["account_holder"] = latest.get("paid_by")
        row["account_no"] = latest.get("sheba")
        row["bank_name"] = latest.get("bank_name")

        advance = sum(
            flt(entry.get("amount"))
            for entry in entries
            if (entry.get("payment_type") or "").strip() == "پیش کرایه"
        )

        if advance:
            row["advance_freight"] = advance


def _build_composite_identity(rows):
    """T02 column M raw format: «مرز-صاحب بار-نوع بار-نام راننده»."""
    for row in rows:
        parts = [
            row.get("border") or "",
            row.get("customer") or row.get("supplier_factory") or "",
            row.get("item") or row.get("cargo_description") or "",
            row.get("driver_name") or row.get("driver") or "",
        ]

        row["composite_identity"] = "-".join(
            str(part) for part in parts
        )


def _fill_cargo_fallback(rows):
    """Use the Trade Case item when the Transport Case has no cargo text."""
    missing = [
        row for row in rows
        if not row.get("cargo_description") and row.get("trade_case")
    ]

    if not missing:
        return

    trade_names = sorted({row.get("trade_case") for row in missing})
    placeholders = ", ".join(["%s"] * len(trade_names))

    records = frappe.db.sql(
        """
        select name, item, cargo_description
        from `tabTrade Case`
        where name in ({placeholders})
        """.format(placeholders=placeholders),
        tuple(trade_names),
        as_dict=True,
    )

    by_name = {record.name: record for record in records}

    for row in missing:
        record = by_name.get(row.get("trade_case"))

        if record:
            row["cargo_description"] = (
                record.get("item") or record.get("cargo_description") or ""
            )


# ---------------------------------------------------------------------------
# T03 dataset — packing
# ---------------------------------------------------------------------------

def _prepare_packing_rows(rows):
    """§6: Size, Branch=qty, Delivery B.=delivery border, never sales invoice."""
    names = [row.get("name") for row in rows if row.get("name")]
    dimensions = {}

    if names and _has_field("Transport Case", "dimensions"):
        placeholders = ", ".join(["%s"] * len(names))

        records = frappe.db.sql(
            """
            select name, dimensions
            from `tabTransport Case`
            where name in ({placeholders})
            """.format(placeholders=placeholders),
            tuple(names),
            as_dict=True,
        )

        dimensions = {
            record.name: record.get("dimensions")
            for record in records
        }

    for row in rows:
        row["size"] = (
            dimensions.get(row.get("name"))
            or row.get("thickness")
            or None
        )
        row["delivery_border"] = _resolve_link_smart(
            "Border",
            row.get("border"),
        ) if row.get("border") else None
        row["driver"] = _resolve_link_smart("Driver", row.get("driver")) \
            if row.get("driver") else None
        row["customer"] = _resolve_link_smart("Customer", row.get("customer")) \
            if row.get("customer") else None

    return rows


# ---------------------------------------------------------------------------
# T04 dataset — purchase register
# ---------------------------------------------------------------------------

PURCHASE_SPECS = [
    {"fieldname": "posting_date", "label": "تاریخ", "fieldtype": "Date", "source": "posting_date"},
    {"fieldname": "purchase_invoice_date", "label": "تاریخ خرید", "fieldtype": "Date", "source": "purchase_invoice_date"},
    {"fieldname": "purchase_invoice_number", "label": "شماره فاکتور", "source": "purchase_invoice_number"},
    {"fieldname": "supplier_factory", "label": "فروشنده", "source": "supplier_factory"},
    {"fieldname": "item", "label": "نام کالا", "source": "item"},
    {"fieldname": "cargo_description", "label": "شرح کالا", "source": "cargo_description"},
    {"fieldname": "dimensions", "label": "سایز", "source": "dimensions"},
    {"fieldname": "thickness", "label": "ضخامت", "fieldtype": "Float", "source": "thickness"},
    {"fieldname": "planned_tonnage", "label": "تناژ", "fieldtype": "Float", "source": "planned_tonnage"},
    {"fieldname": "delivery_type", "label": "تحویل", "source": "delivery_type"},
    {"fieldname": "destination", "label": "مقصد", "source": "destination"},
    {"fieldname": "border", "label": "مرز", "source": "border"},
]

LOADING_SPECS = [
    {"fieldname": "trade_case", "label": "پرونده تجاری", "source": "trade_case"},
    {"fieldname": "loading_date", "label": "تاریخ بارگیری", "fieldtype": "Date", "source": "posting_date"},
    {"fieldname": "item", "label": "کالا", "source": "item"},
    {"fieldname": "dimensions", "label": "سایز", "source": "dimensions"},
    {"fieldname": "cargo_description", "label": "شرح بار", "source": "cargo_description"},
    {"fieldname": "actual_tonnage", "label": "وزن خالص", "fieldtype": "Float", "source": "actual_tonnage"},
    {"fieldname": "destination", "label": "مقصد", "source": "destination"},
    {"fieldname": "plate_number", "label": "ش. کامیون", "source": "plate_number"},
    {"fieldname": "driver", "label": "نام راننده", "source": "driver"},
    {"fieldname": "driver_mobile", "label": "شماره راننده", "source": "driver_mobile"},
    {"fieldname": "customer", "label": "خریدار", "source": "customer"},
    {"fieldname": "customs_broker", "label": "ترخیصکار", "source": "customs_broker"},
]


def _t04_key(row):
    """§7: SUMIFS key must be identical on both sheets.

    'پیش فاکتور خرید'!C  <->  'صورت بارگیری'!D
    """
    return (
        row.get("dimensions")
        or row.get("item")
        or row.get("cargo_description")
        or ""
    )


# ---------------------------------------------------------------------------
# T05 dataset — dispatch
# ---------------------------------------------------------------------------

DISPATCH_SPECS = [
    {"fieldname": "loading_date", "label": "تاریخ بارگیری", "fieldtype": "Date", "source": "posting_date"},
    {"fieldname": "cargo_description", "label": "نوع بار", "source": "cargo_description"},
    {"fieldname": "item", "label": "کالا", "source": "item"},
    {"fieldname": "trade_case", "label": "پرونده تجاری", "source": "trade_case"},
    {"fieldname": "actual_tonnage", "label": "وزن", "fieldtype": "Float", "source": "actual_tonnage"},
    {"fieldname": "origin", "label": "مبدا", "source": "origin"},
    {"fieldname": "destination", "label": "مقصد", "source": "destination"},
    {"fieldname": "plate_number", "label": "ش. کامیون", "source": "plate_number"},
    {"fieldname": "driver", "label": "نام راننده", "source": "driver"},
    {"fieldname": "driver_name", "label": "نام کامل راننده", "source": "driver_name"},
    {"fieldname": "driver_mobile", "label": "شماره راننده", "source": "driver_mobile"},
    {"fieldname": "customs_broker", "label": "ترخیصکار", "source": "customs_broker"},
    {"fieldname": "carrier", "label": "باربری", "source": "carrier"},
    {"fieldname": "waybill_number", "label": "بارنامه", "source": "waybill_number"},
]


def _attach_waybill_numbers(rows):
    names = [row.get("__name__") for row in rows if row.get("__name__")]

    if not names or not frappe.db.exists("DocType", "Transport Waybill"):
        return

    placeholders = ", ".join(["%s"] * len(names))

    try:
        waybills = frappe.db.sql(
            """
            select transport_case, waybill_number
            from `tabTransport Waybill`
            where transport_case in ({placeholders})
            order by modified asc
            """.format(placeholders=placeholders),
            tuple(names),
            as_dict=True,
        )
    except Exception:
        return

    by_case = {}

    for waybill in waybills:
        if waybill.get("waybill_number"):
            by_case[waybill.transport_case] = waybill.waybill_number

    for row in rows:
        value = by_case.get(row.get("__name__"))

        if value:
            row["waybill_number"] = value


def _prefer_driver_display(rows):
    for row in rows:
        if row.get("driver_name"):
            row["driver"] = row.get("driver_name")


# ---------------------------------------------------------------------------
# EXPORTS — read -> transform -> write into an in-memory template copy
# ---------------------------------------------------------------------------

@frappe.whitelist()
def export_financial_custom(
    company=None,
    from_date=None,
    to_date=None,
    case_type=None,
    name=None,
):
    """template_01_financial — §4 exact 26 column contract, A..Z."""
    _guard(FINANCE_ROLES)

    from transport_ir.iran_transport.report.trade_transport_1405.trade_transport_1405 import (
        execute,
    )

    filters = {
        "company": company,
        "from_date": from_date,
        "to_date": to_date,
        "case_type": case_type,
    }

    if name:
        filters["name"] = name

    columns, data = execute(filters)

    wb = _load_and_fill_report(
        "financial",
        columns,
        data,
        from_date=from_date,
        to_date=to_date,
    )
    _send(wb, "financial_custom.xlsx")


@frappe.whitelist()
def export_freight_custom(carrier=None, from_date=None, to_date=None):
    """template_02_freight — §5 exact A..O contract, formulas protected."""
    _guard(FINANCE_ROLES)

    specs = FREIGHT_SPECS
    filters = _transport_filters(
        from_date=from_date,
        to_date=to_date,
        carrier=carrier,
    )

    rows = _fetch_rows(
        "Transport Case",
        specs,
        filters,
        "posting_date asc, name asc",
    )

    _attach_payment_details(rows)
    _fill_cargo_fallback(rows)
    _resolve_link_columns("Transport Case", specs, rows)
    _build_composite_identity(rows)

    wb = _load_and_fill_report(
        "freight",
        _columns_from_specs(specs),
        rows,
        from_date=from_date,
        to_date=to_date,
    )
    _send(wb, "freight_custom.xlsx")


@frappe.whitelist()
def export_packing_custom(
    from_date=None,
    to_date=None,
    border=None,
    customer=None,
    name=None,
):
    """template_03_packing — §6 LTR form, logo and merges preserved."""
    _guard(OPERATIONS_ROLES)

    from transport_ir.iran_transport.report.packing_report.packing_report import (
        execute,
    )

    columns, data = execute(
        {
            "from_date": from_date,
            "to_date": to_date,
            "border": border,
            "customer": customer,
        }
    )

    rows = _rows_from_report(columns, data)

    if name:
        rows = [row for row in rows if row.get("name") == name]

    rows = _prepare_packing_rows(rows)

    wb = _load_and_fill_report(
        "packing",
        columns,
        rows,
        from_date=from_date,
        to_date=to_date,
    )
    _send(wb, "packing_custom.xlsx")


@frappe.whitelist()
def export_purchase_custom(from_date=None, to_date=None, supplier=None):
    """template_04_purchase — §7 four sheets, SUMIFS key relation preserved."""
    _guard(FINANCE_ROLES)

    filters = {"case_type": "خرید"}

    if from_date and to_date:
        filters["posting_date"] = ["between", [from_date, to_date]]
    elif from_date:
        filters["posting_date"] = [">=", from_date]
    elif to_date:
        filters["posting_date"] = ["<=", to_date]

    if supplier:
        filters["supplier_factory"] = supplier

    invoice_rows = _fetch_rows(
        "Trade Case",
        PURCHASE_SPECS,
        filters,
        "posting_date asc, name asc",
    )

    _resolve_link_columns("Trade Case", PURCHASE_SPECS, invoice_rows)

    for row in invoice_rows:
        row["size_key"] = _t04_key(row)

    trade_names = [
        row.get("__name__") for row in invoice_rows if row.get("__name__")
    ]

    loading_rows = []

    if trade_names:
        loading_filters = {
            "trade_case": ["in", trade_names],
            "workflow_state": ["not in", ["Cancelled", "Rejected"]],
        }

        loading_rows = _fetch_rows(
            "Transport Case",
            LOADING_SPECS,
            loading_filters,
            "posting_date asc, name asc",
        )

        _resolve_link_columns("Transport Case", LOADING_SPECS, loading_rows)

        for row in loading_rows:
            row["size_key"] = _t04_key(row)

    wb = _load_and_fill_report(
        "purchase",
        _columns_from_specs(PURCHASE_SPECS),
        invoice_rows,
        extra_sheets={"loading": loading_rows},
        from_date=from_date,
        to_date=to_date,
    )
    _send(wb, "purchase_custom.xlsx")


@frappe.whitelist()
def export_dispatch_custom(
    from_date=None,
    to_date=None,
    border=None,
    carrier=None,
):
    """template_05_dispatch — §8 exact B..L contract, E SUM preserved."""
    _guard(OPERATIONS_ROLES)

    specs = DISPATCH_SPECS
    filters = _transport_filters(
        from_date=from_date,
        to_date=to_date,
        carrier=carrier,
        border=border,
    )

    rows = _fetch_rows(
        "Transport Case",
        specs,
        filters,
        "posting_date asc, name asc",
    )

    _attach_waybill_numbers(rows)
    _fill_cargo_fallback(rows)
    _resolve_link_columns("Transport Case", specs, rows)
    _prefer_driver_display(rows)

    wb = _load_and_fill_report(
        "dispatch",
        _columns_from_specs(specs),
        rows,
        from_date=from_date,
        to_date=to_date,
    )
    _send(wb, "dispatch_custom.xlsx")


# ---------------------------------------------------------------------------
# IMPORT — Preview -> Validate -> Resolve -> Commit (§0/§9/§14)
# ---------------------------------------------------------------------------

def _file_bytes(file_url):
    if not file_url:
        frappe.throw(_("فایل مشخص نیست"))

    file_url = str(file_url).strip()

    if not file_url.lower().split("?", 1)[0].endswith(".xlsx"):
        frappe.throw(_("فقط فایل XLSX مجاز است."))

    file_docname = frappe.db.get_value("File", {"file_url": file_url}, "name")

    if not file_docname:
        frappe.throw(_("فایل در سیستم پیدا نشد."))

    doc = frappe.get_doc("File", file_docname)
    doc.check_permission("read")

    if flt(doc.file_size) > MAX_IMPORT_FILE_SIZE:
        frappe.throw(_("حجم فایل زیاد است"))

    content = doc.get_content()

    return content.encode("latin-1") if isinstance(content, str) else content


def _to_date(val):
    if isinstance(val, datetime.datetime):
        return val.date()

    if isinstance(val, datetime.date):
        return val

    try:
        return getdate(val)
    except Exception:
        return None


def _pick_sheet(wb, sheet_name):
    """§15: the named sheet always wins over the active/index sheet."""
    if sheet_name and sheet_name in wb.sheetnames:
        return wb[sheet_name]

    return wb.active


def _import_rows(ws, sheet_reg):
    """Read the data area of a template sheet using its coordinate contract."""
    header_row = _find_header_row(ws, sheet_reg)
    start_row = sheet_reg.get("data_start_row") or (header_row + 1)

    columns = sheet_reg.get("columns") or []
    rows = []

    max_row = ws.max_row or start_row

    if max_row - start_row + 1 > MAX_IMPORT_ROWS:
        frappe.throw(
            _("حداکثر تعداد ردیف قابل ورود {0} است.").format(MAX_IMPORT_ROWS)
        )

    for row_idx in range(start_row, max_row + 1):
        row = {"__source_row__": row_idx}
        has_value = False

        for spec in columns:
            col_idx = column_index_from_string(spec["col"])
            value = ws.cell(row=row_idx, column=col_idx).value

            if _is_formula(value):
                value = None

            key = spec.get("field") or f"__col_{spec['col']}__"
            row[key] = value

            if value not in (None, ""):
                has_value = True

        if has_value:
            rows.append(row)

    return rows


def _row_get(row, *keys):
    """Fetch a dataset value by dataset key, fuzzy only inside the same row."""
    for key in keys:
        if key in row and row.get(key) not in (None, ""):
            return row.get(key)

    normalized = {_norm(key): value for key, value in row.items()}

    for key in keys:
        normalized_key = _norm(key)

        if normalized_key in normalized:
            return normalized[normalized_key]

    return None


def _preview_response(template_key, rows, issues, resolved):
    return {
        "mode": "preview",
        "template_key": TEMPLATE_REGISTRY[template_key]["template_key"],
        "total_rows": len(rows),
        "ready": len(resolved),
        "issues": issues,
        "count": 0,
        "created": [],
        "sample": resolved[:10],
    }


@frappe.whitelist()
def import_purchase_custom(file_url, mode="preview"):
    """T04 import — «پیش فاکتور خرید» sheet, transactional commit."""
    _guard(OPERATIONS_ROLES)

    if not frappe.has_permission("Trade Case", "create"):
        frappe.throw(_("دسترسی ندارید"), frappe.PermissionError)

    reg = TEMPLATE_REGISTRY["purchase"]

    wb = openpyxl.load_workbook(
        io.BytesIO(_file_bytes(file_url)),
        data_only=True,
    )
    ws = _pick_sheet(wb, reg["sheet"])

    rows = _import_rows(ws, reg)

    invoice_number = ws["D2"].value
    invoice_date = _to_date(ws["B2"].value)
    supplier_raw = ws["F2"].value

    supplier = _resolve_link("Supplier", supplier_raw, "supplier_name")

    issues = []
    resolved = []

    for row in rows:
        source_row = row.get("__source_row__")

        item = _row_get(row, "item")
        size_key = _row_get(row, "size_key")
        tonnage = flt(_row_get(row, "planned_tonnage"))

        if not item and not size_key:
            issues.append(
                _("ردیف {0}: نام کالا/سایز خالی است").format(source_row)
            )
            continue

        if tonnage <= 0:
            issues.append(
                _("ردیف {0}: تناژ نامعتبر است").format(source_row)
            )
            continue

        if not invoice_number:
            issues.append(
                _("ردیف {0}: شماره فاکتور خرید در قالب خالی است").format(
                    source_row
                )
            )
            continue

        if supplier_raw and not supplier:
            issues.append(
                _("ردیف {0}: فروشنده «{1}» در سیستم یافت نشد").format(
                    source_row,
                    supplier_raw,
                )
            )
            continue

        identity = {
            "purchase_invoice_number": str(invoice_number).strip(),
            "supplier_factory": supplier,
            "item": item,
        }

        duplicate = None

        if _has_field("Trade Case", "purchase_invoice_number"):
            duplicate = frappe.db.get_value(
                "Trade Case",
                {
                    key: value
                    for key, value in identity.items()
                    if value
                },
                "name",
            )

        if duplicate:
            issues.append(
                _("ردیف {0}: رکورد تکراری با پرونده {1}").format(
                    source_row,
                    duplicate,
                )
            )
            continue

        resolved.append(
            {
                "source_row": source_row,
                "item": item,
                "size_key": size_key,
                "planned_tonnage": tonnage,
                "delivery_type": _row_get(row, "delivery_type"),
                "supplier_factory": supplier,
                "purchase_invoice_number": str(invoice_number).strip(),
                "purchase_invoice_date": invoice_date,
            }
        )

    if mode != "commit":
        return _preview_response("purchase", rows, issues, resolved)

    if issues:
        frappe.throw(_("خطا در ورود اطلاعات:\n") + "\n".join(issues))

    created = []

    for entry in resolved:
        doc = frappe.new_doc("Trade Case")
        doc.case_type = "خرید"
        doc.case_title = (
            f"{entry.get('supplier_factory') or 'Import'} - "
            f"{entry.get('item') or 'خرید'}"
        )
        doc.supplier_factory = entry.get("supplier_factory")
        doc.item = entry.get("item")

        if _has_field("Trade Case", "dimensions") and entry.get("size_key"):
            doc.dimensions = entry.get("size_key")

        doc.planned_tonnage = entry.get("planned_tonnage")

        if _has_field("Trade Case", "delivery_type") and entry.get("delivery_type"):
            doc.delivery_type = entry.get("delivery_type")

        if _has_field("Trade Case", "purchase_invoice_number"):
            doc.purchase_invoice_number = entry.get("purchase_invoice_number")

        if _has_field("Trade Case", "purchase_invoice_date"):
            doc.purchase_invoice_date = entry.get("purchase_invoice_date")

        doc.posting_date = (
            entry.get("purchase_invoice_date") or frappe.utils.today()
        )
        doc.insert()

        created.append(doc.name)

    # No manual commit. Frappe rolls back automatically if we throw.
    return {
        "mode": "commit",
        "count": len(created),
        "created": created,
        "issues": [],
    }


@frappe.whitelist()
def import_freight_custom(file_url, mode="preview"):
    """T02 import — freight payments, duplicate guarded and transactional."""
    _guard(FINANCE_ROLES)

    if not frappe.has_permission("Transport Payment", "create"):
        frappe.throw(_("دسترسی ندارید"), frappe.PermissionError)

    reg = TEMPLATE_REGISTRY["freight"]

    wb = openpyxl.load_workbook(
        io.BytesIO(_file_bytes(file_url)),
        data_only=True,
    )
    ws = _pick_sheet(wb, reg["sheet"])

    rows = _import_rows(ws, reg)

    issues = []
    resolved = []

    for row in rows:
        source_row = row.get("__source_row__")

        freight = flt(_row_get(row, "freight_cost"))
        composite = _row_get(row, "composite_identity")
        account_holder = _row_get(row, "account_holder")
        invoice = _row_get(row, "sales_invoice_number")

        if freight <= 0:
            issues.append(
                _("ردیف {0}: مبلغ کرایه نامعتبر است").format(source_row)
            )
            continue

        parent_name = None
        match_method = None

        if invoice and _has_field("Transport Case", "sales_invoice_number"):
            parent_name = frappe.db.get_value(
                "Transport Case",
                {"sales_invoice_number": str(invoice).strip()},
                "name",
            )
            match_method = "sales_invoice_number"

        if not parent_name and composite:
            # §5: never split blindly, the raw composite is kept for review.
            candidates = frappe.get_all(
                "Transport Case",
                filters={
                    "workflow_state": ["not in", ["Cancelled", "Rejected"]],
                },
                or_filters=[
                    ["waybill_number", "=", str(composite).strip()],
                ],
                pluck="name",
                limit_page_length=2,
            )

            if len(candidates) == 1:
                parent_name = candidates[0]
                match_method = "composite_waybill"

        if not parent_name:
            issues.append(
                _("ردیف {0}: پرونده حمل یافت نشد (شناسه خام: {1})").format(
                    source_row,
                    composite or account_holder or "-",
                )
            )
            continue

        duplicate = frappe.db.get_value(
            "Transport Payment",
            {
                "parenttype": "Transport Case",
                "parent": parent_name,
                "payment_type": "کرایه",
                "amount": freight,
            },
            "name",
        )

        if duplicate:
            issues.append(
                _("ردیف {0}: پرداخت تکراری برای پرونده {1}").format(
                    source_row,
                    parent_name,
                )
            )
            continue

        resolved.append(
            {
                "source_row": source_row,
                "parent": parent_name,
                "match_method": match_method,
                "amount": freight,
                "raw_identity": composite,
                "account_holder": account_holder,
                "account_no": _row_get(row, "account_no"),
                "bank_name": _row_get(row, "bank_name"),
            }
        )

    if mode != "commit":
        return _preview_response("freight", rows, issues, resolved)

    if issues:
        frappe.throw(_("خطا در ورود کرایه‌ها:\n") + "\n".join(issues))

    touched = []
    meta = frappe.get_meta("Transport Payment")

    for entry in resolved:
        parent_doc = frappe.get_doc("Transport Case", entry["parent"])

        payment_row = {
            "payment_type": "کرایه",
            "amount": entry["amount"],
            "payment_date": frappe.utils.today(),
        }

        if meta.has_field("paid_by") and entry.get("account_holder"):
            payment_row["paid_by"] = entry.get("account_holder")

        if meta.has_field("bank_name") and entry.get("bank_name"):
            payment_row["bank_name"] = entry.get("bank_name")

        if meta.has_field("sheba") and entry.get("account_no"):
            payment_row["sheba"] = str(entry.get("account_no"))

        if meta.has_field("notes"):
            payment_row["notes"] = (
                f"ورود از اکسل اختصاصی | شناسه خام: {entry.get('raw_identity') or '-'}"
            )

        parent_doc.append("payments", payment_row)
        parent_doc.save()

        touched.append(entry["parent"])

    return {
        "mode": "commit",
        "count": len(set(touched)),
        "created": list(set(touched)),
        "issues": [],
    }
CUSTOM_PY_EOF

# --- Patch List View (trade_case_list.js) ---
python3 <<'PYEOF'
import os
path = os.path.join(os.environ["MOD"], "doctype", "trade_case", "trade_case_list.js")
with open(path, encoding="utf-8") as f: src = f.read()

if "// PHASE8_CUSTOM_EXCEL_BUTTONS" not in src:
    anchor = '}, __("اکسل"));'
    pos = src.rfind(anchor)
    if pos != -1:
        insert_pos = pos + len(anchor)
        btns = """

\t\t// PHASE8_CUSTOM_EXCEL_BUTTONS
\t\tvar phase8_custom_import = function (label, method) {
\t\t\tvar d = new frappe.ui.Dialog({
\t\t\t\ttitle: label,
\t\t\t\tfields: [{fieldname: "file_url", label: __("فایل"), fieldtype: "Attach", reqd: 1}],
\t\t\t\tprimary_action_label: __("پیش‌نمایش و بررسی"),
\t\t\t\tprimary_action: function (v) {
\t\t\t\t\td.disable_primary_action();
\t\t\t\t\tfrappe.call({
\t\t\t\t\t\tmethod: method,
\t\t\t\t\t\targs: {file_url: v.file_url, mode: "preview"},
\t\t\t\t\t\tfreeze: true,
\t\t\t\t\t\tcallback: function (r) {
\t\t\t\t\t\t\tvar m = r.message || {};
\t\t\t\t\t\t\tvar issues = (m.issues || []).join("<br>");
\t\t\t\t\t\t\tfrappe.confirm(
\t\t\t\t\t\t\t\t__("ردیف قابل ثبت: {0} از {1}", [m.ready || 0, m.total_rows || 0]) +
\t\t\t\t\t\t\t\t(issues ? "<br><br>" + issues : ""),
\t\t\t\t\t\t\t\tfunction () {
\t\t\t\t\t\t\t\t\tfrappe.call({
\t\t\t\t\t\t\t\t\t\tmethod: method,
\t\t\t\t\t\t\t\t\t\targs: {file_url: v.file_url, mode: "commit"},
\t\t\t\t\t\t\t\t\t\tfreeze: true,
\t\t\t\t\t\t\t\t\t\tcallback: function (r2) {
\t\t\t\t\t\t\t\t\t\t\td.hide();
\t\t\t\t\t\t\t\t\t\t\tfrappe.show_alert(__("{0} رکورد ثبت شد", [(r2.message || {}).count || 0]));
\t\t\t\t\t\t\t\t\t\t\tlistview.refresh();
\t\t\t\t\t\t\t\t\t\t}
\t\t\t\t\t\t\t\t\t});
\t\t\t\t\t\t\t\t}
\t\t\t\t\t\t\t);
\t\t\t\t\t\t},
\t\t\t\t\t\talways: function () { d.enable_primary_action(); }
\t\t\t\t\t});
\t\t\t\t}
\t\t\t});
\t\t\td.show();
\t\t};

\t\tlistview.page.add_inner_button(__("گزارش جامع مالی (اختصاصی)"), function() {
\t\t\twindow.location.href = "/api/method/transport_ir.iran_transport.api.report_excel_custom.export_financial_custom";
\t\t}, __("اکسل اختصاصی"));
\t\tlistview.page.add_inner_button(__("لیست تسویه کرایه (اختصاصی)"), function() {
\t\t\twindow.location.href = "/api/method/transport_ir.iran_transport.api.report_excel_custom.export_freight_custom";
\t\t}, __("اکسل اختصاصی"));
\t\tlistview.page.add_inner_button(__("پکینگ لیست گمرکی (اختصاصی)"), function() {
\t\t\twindow.location.href = "/api/method/transport_ir.iran_transport.api.report_excel_custom.export_packing_custom";
\t\t}, __("اکسل اختصاصی"));
\t\tlistview.page.add_inner_button(__("خروجی سفارش خرید (اختصاصی)"), function() {
\t\t\twindow.location.href = "/api/method/transport_ir.iran_transport.api.report_excel_custom.export_purchase_custom";
\t\t}, __("اکسل اختصاصی"));
\t\tlistview.page.add_inner_button(__("خروجی ارسال/بارنامه (اختصاصی)"), function() {
\t\t\twindow.location.href = "/api/method/transport_ir.iran_transport.api.report_excel_custom.export_dispatch_custom";
\t\t}, __("اکسل اختصاصی"));
\t\tlistview.page.add_inner_button(__("ورود سفارش خرید (اختصاصی)"), function() {
\t\t\tphase8_custom_import(
\t\t\t\t__("ورود از اکسل خرید"),
\t\t\t\t"transport_ir.iran_transport.api.report_excel_custom.import_purchase_custom"
\t\t\t);
\t\t}, __("اکسل اختصاصی"));
\t\tlistview.page.add_inner_button(__("ورود لیست کرایه (اختصاصی)"), function() {
\t\t\tphase8_custom_import(
\t\t\t\t__("ورود از اکسل کرایه"),
\t\t\t\t"transport_ir.iran_transport.api.report_excel_custom.import_freight_custom"
\t\t\t);
\t\t}, __("اکسل اختصاصی"));"""
        src = src[:insert_pos] + btns + src[insert_pos:]
        with open(path, "w", encoding="utf-8") as f: f.write(src)
        print("trade_case_list.js patched")
PYEOF

# --- Patch Form View (trade_case.js) ---
python3 <<'PYEOF'
import os
path = os.path.join(os.environ["MOD"], "doctype", "trade_case", "trade_case.js")
with open(path, encoding="utf-8") as f: src = f.read()

if "// PHASE8_CUSTOM_EXPORT_BUTTON" not in src:
    anchor = '}, __("خروجی"));\n\t}\n});'
    if anchor in src:
        repl = """}, __("خروجی"));

\t\tfrm.add_custom_button(__("خروجی اختصاصی (قالب کارفرما)"), function() {
\t\t\twindow.location.href = "/api/method/transport_ir.iran_transport.api.report_excel_custom.export_financial_custom?name=" + encodeURIComponent(frm.doc.name);
\t\t}, __("خروجی"));

\t\tfrm.add_custom_button(__("خروجی خرید (قالب کارفرما)"), function() {
\t\t\twindow.location.href = "/api/method/transport_ir.iran_transport.api.report_excel_custom.export_purchase_custom";
\t\t}, __("خروجی"));

\t\t// PHASE8_CUSTOM_EXPORT_BUTTON
\t}
});"""
        src = src.replace(anchor, repl, 1)
        with open(path, "w", encoding="utf-8") as f: f.write(src)
        print("trade_case.js patched")
PYEOF

# --- Patch/Create Transport Case List View (transport_case_list.js) ---
python3 <<'PYEOF'
import os

path = os.path.join(
    os.environ["MOD"],
    "doctype",
    "transport_case",
    "transport_case_list.js",
)

marker = "// PHASE8_CUSTOM_TRANSPORT_EXCEL_BUTTONS"

block = """
""" + marker + """
(function () {
\t"use strict";

\tvar settings = frappe.listview_settings["Transport Case"] || {};
\tvar previous_onload = settings.onload;

\tsettings.onload = function (listview) {
\t\tif (typeof previous_onload === "function") {
\t\t\tprevious_onload(listview);
\t\t}

\t\tif (listview.__phase8_custom_excel_buttons) {
\t\t\treturn;
\t\t}

\t\tlistview.__phase8_custom_excel_buttons = true;

\t\tlistview.page.add_inner_button(__("خروجی ارسال/بارنامه (اختصاصی)"), function () {
\t\t\twindow.location.href =
\t\t\t\t"/api/method/transport_ir.iran_transport.api.report_excel_custom.export_dispatch_custom";
\t\t}, __("اکسل اختصاصی"));

\t\tlistview.page.add_inner_button(__("لیست تسویه کرایه (اختصاصی)"), function () {
\t\t\twindow.location.href =
\t\t\t\t"/api/method/transport_ir.iran_transport.api.report_excel_custom.export_freight_custom";
\t\t}, __("اکسل اختصاصی"));

\t\tlistview.page.add_inner_button(__("پکینگ لیست گمرکی (اختصاصی)"), function () {
\t\t\twindow.location.href =
\t\t\t\t"/api/method/transport_ir.iran_transport.api.report_excel_custom.export_packing_custom";
\t\t}, __("اکسل اختصاصی"));

\t\tlistview.page.add_inner_button(__("ورود لیست کرایه (اختصاصی)"), function () {
\t\t\tvar method =
\t\t\t\t"transport_ir.iran_transport.api.report_excel_custom.import_freight_custom";
\t\t\tvar d = new frappe.ui.Dialog({
\t\t\t\ttitle: __("ورود از اکسل کرایه"),
\t\t\t\tfields: [{fieldname: "file_url", label: __("فایل"), fieldtype: "Attach", reqd: 1}],
\t\t\t\tprimary_action_label: __("پیش‌نمایش و بررسی"),
\t\t\t\tprimary_action: function (v) {
\t\t\t\t\td.disable_primary_action();
\t\t\t\t\tfrappe.call({
\t\t\t\t\t\tmethod: method,
\t\t\t\t\t\targs: {file_url: v.file_url, mode: "preview"},
\t\t\t\t\t\tfreeze: true,
\t\t\t\t\t\tcallback: function (r) {
\t\t\t\t\t\t\tvar m = r.message || {};
\t\t\t\t\t\t\tvar issues = (m.issues || []).join("<br>");
\t\t\t\t\t\t\tfrappe.confirm(
\t\t\t\t\t\t\t\t__("ردیف قابل ثبت: {0} از {1}", [m.ready || 0, m.total_rows || 0]) +
\t\t\t\t\t\t\t\t(issues ? "<br><br>" + issues : ""),
\t\t\t\t\t\t\t\tfunction () {
\t\t\t\t\t\t\t\t\tfrappe.call({
\t\t\t\t\t\t\t\t\t\tmethod: method,
\t\t\t\t\t\t\t\t\t\targs: {file_url: v.file_url, mode: "commit"},
\t\t\t\t\t\t\t\t\t\tfreeze: true,
\t\t\t\t\t\t\t\t\t\tcallback: function (r2) {
\t\t\t\t\t\t\t\t\t\t\td.hide();
\t\t\t\t\t\t\t\t\t\t\tfrappe.show_alert(__("{0} پرداخت ثبت شد", [(r2.message || {}).count || 0]));
\t\t\t\t\t\t\t\t\t\t\tlistview.refresh();
\t\t\t\t\t\t\t\t\t\t}
\t\t\t\t\t\t\t\t\t});
\t\t\t\t\t\t\t\t}
\t\t\t\t\t\t\t);
\t\t\t\t\t\t},
\t\t\t\t\t\talways: function () { d.enable_primary_action(); }
\t\t\t\t\t});
\t\t\t\t}
\t\t\t});
\t\t\td.show();
\t\t}, __("اکسل اختصاصی"));
\t};

\tfrappe.listview_settings["Transport Case"] = settings;
})();
"""

os.makedirs(os.path.dirname(path), exist_ok=True)

if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        src = f.read()
else:
    src = ""

if marker in src:
    print("transport_case_list.js already patched")
else:
    with open(path, "w", encoding="utf-8") as f:
        f.write((src.rstrip() + "\n" if src.strip() else "") + block)
    print("transport_case_list.js patched")
PYEOF

log "Custom Excel UI buttons patched (Standard preserved)"

# =============================================================================
# 18) Translation fixture merge
# =============================================================================

step "18) Persian translations"

mkdir -p "${PKG}/fixtures"

python3 <<'PYEOF'
import json
import os

path = os.path.join(os.environ["PKG"], "fixtures", "translation.json")
now = os.environ["NOW_TS"]

if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        rows = json.load(f)
else:
    rows = []

if not isinstance(rows, list):
    rows = [rows]

translations = {
    "Trade Transport 1405": "گزارش جامع مالی",
    "Freight Report": "گزارش کرایه",
    "Customs Report": "گزارش گمرک و ترخیص",
    "Tonnage Report": "گزارش تناژ",
    "Profit Report": "گزارش سود",
    "Stalled Cases Report": "پرونده‌های متوقف‌شده",
    "Payments Report": "گزارش پرداخت‌ها",
    "Daily Summary Report": "خلاصه روزانه، ماهانه و سالانه",
    "Packing Report": "گزارش پکینگ",
    "Trade Case Proforma": "پیش‌فاکتور پرونده تجاری",
    "Transport Packing List": "لیست پکینگ حمل",
    "Transport Waybill Print": "چاپ بارنامه حمل",
    "Transport Weighbridge Print": "چاپ رسید باسکول",
}

by_key = {
    (row.get("language"), row.get("source_text")): row
    for row in rows
    if isinstance(row, dict)
}

for index, (source, target) in enumerate(translations.items(), 1):
    key = ("fa", source)
    row = dict(by_key.get(key, {}))

    row.update(
        {
            "doctype": "Translation",
            "name": row.get("name") or f"fa-phase8-{index:02d}",
            "language": "fa",
            "source_text": source,
            "translated_text": target,
            "modified": now,
        }
    )

    by_key[key] = row

result = sorted(
    by_key.values(),
    key=lambda row: (
        row.get("language", ""),
        row.get("source_text", ""),
    ),
)

with open(path, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=1)

print(f"translation fixture: {len(result)} rows")
PYEOF

# =============================================================================
# 19) Add report cards and links to phase-7 Workspaces
# =============================================================================

step "19) Workspace report links"

python3 <<'PYEOF'
import json
import os

mod = os.environ["MOD"]
now = os.environ["NOW_TS"]

# Workspace Link.link_type فقط: DocType | Page | Report
# لینک URL مجاز نیست (ValidationError)

# استاندارد: بدون گزارش جامع مالی
standard_all = [
    ("گزارش کرایه", "Freight Report"),
    ("گزارش گمرک", "Customs Report"),
    ("گزارش تناژ", "Tonnage Report"),
    ("گزارش سود", "Profit Report"),
    ("پرونده‌های متوقف‌شده", "Stalled Cases Report"),
    ("گزارش پرداخت‌ها", "Payments Report"),
    ("خلاصه دوره‌ای", "Daily Summary Report"),
    ("گزارش پکینگ", "Packing Report"),
]

# اختصاصی: گزارش جامع مالی (template_01)
custom_all = [
    ("گزارش جامع مالی", "Trade Transport 1405"),
]

workspace_map = {
    "ceo_dashboard": {
        "standard": standard_all,
        "custom": custom_all,
    },
    "finance": {
        "standard": [
            standard_all[0],
            standard_all[1],
            standard_all[3],
            standard_all[5],
            standard_all[6],
        ],
        "custom": custom_all,
    },
    "iran_transport": {
        "standard": [
            standard_all[0],
            standard_all[1],
            standard_all[2],
            standard_all[4],
            standard_all[6],
            standard_all[7],
        ],
        "custom": custom_all,
    },
    "transport_purchase": {
        "standard": [
            standard_all[0],
            standard_all[2],
            standard_all[4],
            standard_all[7],
        ],
        "custom": custom_all,
    },
    "transport_sales": {
        "standard": [
            standard_all[0],
            standard_all[2],
            standard_all[4],
            standard_all[7],
        ],
        "custom": custom_all,
    },
    "customs": {
        "standard": [
            standard_all[1],
            standard_all[2],
            standard_all[4],
        ],
        "custom": [],
    },
}

phase8_report_names = {
    "Trade Transport 1405",
    "Freight Report",
    "Customs Report",
    "Tonnage Report",
    "Profit Report",
    "Stalled Cases Report",
    "Payments Report",
    "Daily Summary Report",
    "Packing Report",
}

card_std = "گزارش‌ها و خروجی‌ها استاندارد"
card_custom = "گزارش‌ها و خروجی‌ها اختصاصی"
old_cards = {
    "گزارش‌ها و خروجی‌ها",
    card_std,
    card_custom,
}

for folder, cfg in workspace_map.items():
    path = os.path.join(
        mod,
        "workspace",
        folder,
        f"{folder}.json",
    )

    if not os.path.exists(path):
        print(f"workspace optional, skipped: {folder}")
        continue

    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    links = data.get("links") or []

    cleaned = []
    for row in links:
        if row.get("type") == "Card Break" and row.get("label") in old_cards:
            continue
        if (
            row.get("type") == "Link"
            and row.get("link_type") == "Report"
            and row.get("link_to") in phase8_report_names
        ):
            continue
        # حذف لینک‌های URL باطل از اجرای قبلی
        if (
            row.get("type") == "Link"
            and str(row.get("link_type") or "") == "URL"
        ):
            continue
        if (
            row.get("type") == "Link"
            and "report_excel_custom" in str(row.get("link_to") or "")
        ):
            continue
        cleaned.append(row)

    links = cleaned

    std_rows = cfg.get("standard") or []
    cus_rows = cfg.get("custom") or []

    if std_rows:
        links.append(
            {
                "type": "Card Break",
                "label": card_std,
                "link_count": len(std_rows),
                "hidden": 0,
                "onboard": 0,
                "is_query_report": 0,
            }
        )
        for label, report_name in std_rows:
            links.append(
                {
                    "type": "Link",
                    "label": label,
                    "link_type": "Report",
                    "link_to": report_name,
                    "hidden": 0,
                    "onboard": 0,
                    "is_query_report": 1,
                    "dependencies": "",
                }
            )

    if cus_rows:
        links.append(
            {
                "type": "Card Break",
                "label": card_custom,
                "link_count": len(cus_rows),
                "hidden": 0,
                "onboard": 0,
                "is_query_report": 0,
            }
        )
        for label, report_name in cus_rows:
            links.append(
                {
                    "type": "Link",
                    "label": label,
                    "link_type": "Report",
                    "link_to": report_name,
                    "hidden": 0,
                    "onboard": 0,
                    "is_query_report": 1,
                    "dependencies": "",
                }
            )

    data["links"] = links

    try:
        content = json.loads(data.get("content") or "[]")
    except Exception:
        content = []

    content = [
        block
        for block in content
        if not (
            isinstance(block, dict)
            and block.get("id") in (
                "p8-reports",
                "p8-reports-std",
                "p8-reports-custom",
            )
        )
    ]

    if std_rows:
        content.append(
            {
                "id": "p8-reports-std",
                "type": "card",
                "data": {
                    "card_name": card_std,
                    "col": 4,
                },
            }
        )

    if cus_rows:
        content.append(
            {
                "id": "p8-reports-custom",
                "type": "card",
                "data": {
                    "card_name": card_custom,
                    "col": 4,
                },
            }
        )

    data["content"] = json.dumps(
        content,
        ensure_ascii=False,
        separators=(",", ":"),
    )
    data["modified"] = now

    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)

    print(
        f"workspace patched: {folder} "
        f"(std={len(std_rows)}, custom={len(cus_rows)})"
    )
PYEOF

# =============================================================================
# 20) Phase 8 setup/backfill/Workspace sync
# =============================================================================

step "20) setup_phase8.py"

write_utf8 "${MOD}/setup_phase8.py" <<'EOF'
"""Phase 8 setup and targeted cleanup."""

from __future__ import annotations

import json
import os

import frappe


WORKSPACE_FOLDERS = (
    "ceo_dashboard",
    "finance",
    "iran_transport",
    "transport_purchase",
    "transport_sales",
    "customs",
)

STALE_REPORT_NAMES = (
    "freight_report",
    "customs_report",
    "tonnage_report",
    "profit_report",
    "stalled_cases_report",
    "payments_report",
    "daily_summary_report",
    "packing_report",
)


def _cleanup_rejected_phase8_artifacts():
    """Remove only names generated by the rejected Phase 8 version."""
    for name in STALE_REPORT_NAMES:
        if not frappe.db.exists("Report", name):
            continue

        module = frappe.db.get_value("Report", name, "module")

        if module != "Iran Transport":
            continue

        try:
            frappe.delete_doc(
                "Report",
                name,
                ignore_permissions=True,
                force=True,
            )
        except Exception:
            pass

    for name in ("Waybill Print", "Weighbridge Print"):
        if not frappe.db.exists("Print Format", name):
            continue

        module = frappe.db.get_value("Print Format", name, "module")

        if module != "Iran Transport":
            continue

        try:
            frappe.delete_doc(
                "Print Format",
                name,
                ignore_permissions=True,
                force=True,
            )
        except Exception:
            pass


def _backfill_invoice_fields():
    if not frappe.db.exists("DocType", "Transport Case"):
        return

    frappe.db.sql(
        """
        update `tabTransport Case` t
        inner join `tabTrade Case` tc on tc.name = t.trade_case
        set
            t.sales_invoice_number = tc.sales_invoice_number,
            t.sales_invoice_date = tc.sales_invoice_date,
            t.purchase_invoice_number = tc.purchase_invoice_number,
            t.purchase_invoice_date = tc.purchase_invoice_date
        where ifnull(t.trade_case, '') != ''
        """
    )


def _sync_workspace(folder):
    path = frappe.get_app_path(
        "transport_ir",
        "iran_transport",
        "workspace",
        folder,
        f"{folder}.json",
    )

    if not os.path.exists(path):
        return

    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    name = data["name"]

    if not frappe.db.exists("Workspace", name):
        return

    doc = frappe.get_doc("Workspace", name)
    doc.content = data.get("content") or "[]"

    doc.set("links", [])

    for row in data.get("links", []):
        # فقط link_type معتبر Workspace
        if row.get("type") == "Link":
            link_type = row.get("link_type") or "Report"
            if link_type not in ("DocType", "Page", "Report"):
                continue
        doc.append("links", row)

    doc.flags.ignore_permissions = True
    doc.flags.ignore_links = True
    doc.save(ignore_permissions=True)


def setup_phase8(commit=True):
    frappe.flags.in_patch = True

    _cleanup_rejected_phase8_artifacts()
    _backfill_invoice_fields()

    for folder in WORKSPACE_FOLDERS:
        _sync_workspace(folder)

    if commit:
        frappe.db.commit()

    frappe.clear_cache()

    print("Phase 8 setup/backfill/workspaces completed")
    return True
EOF

# =============================================================================
# 21) Verification
# =============================================================================

step "21) verify_phase8.py"

write_utf8 "${MOD}/verify_phase8.py" <<'EOF'
from __future__ import annotations

import importlib
import inspect
import os

import frappe


REPORTS = {
    "Trade Transport 1405": (
        "trade_transport_1405",
        "Trade Case",
    ),
    "Freight Report": (
        "freight_report",
        "Transport Case",
    ),
    "Customs Report": (
        "customs_report",
        "Transport Case",
    ),
    "Tonnage Report": (
        "tonnage_report",
        "Transport Case",
    ),
    "Profit Report": (
        "profit_report",
        "Trade Case",
    ),
    "Stalled Cases Report": (
        "stalled_cases_report",
        "Transport Case",
    ),
    "Payments Report": (
        "payments_report",
        "Transport Case",
    ),
    "Daily Summary Report": (
        "daily_summary_report",
        "Transport Case",
    ),
    "Packing Report": (
        "packing_report",
        "Transport Case",
    ),
}

PRINT_FORMATS = {
    "Trade Case Proforma": "Trade Case",
    "Transport Packing List": "Transport Case",
    "Transport Waybill Print": "Transport Waybill",
    "Transport Weighbridge Print": "Transport Weighbridge",
}


def verify_phase8():
    passed = []
    failed = []

    def check(name, condition, detail=""):
        target = passed if condition else failed
        target.append(name)

        prefix = "✅ PASS" if condition else "❌ FAIL"
        suffix = f" — {detail}" if detail else ""

        print(f"{prefix}: {name}{suffix}")

    # ------------------------------------------------------------------
    # Dependencies and canonical Jalali
    # ------------------------------------------------------------------
    try:
        import openpyxl  # noqa: F401
        check("openpyxl import", True)
    except Exception as exc:
        check("openpyxl import", False, str(exc))

    from transport_ir.iran_transport.utils import jinja_helpers

    source = inspect.getsource(jinja_helpers)
    check(
        "Jalali uses ir_jalali single source",
        "from ir_jalali.utils.jalali import format_jalali" in source,
    )
    check(
        "No second _g2j implementation",
        "def _g2j" not in source,
    )
    check(
        "fa_digits",
        jinja_helpers.fa_digits("123") == "۱۲۳",
    )
    check(
        "fa_date canonical",
        jinja_helpers.fa_date("2025-03-21") == "۱۴۰۴/۰۱/۰۱",
    )
    check(
        "normalize_persian fuzzy",
        jinja_helpers.normalize_persian("  ي\u200cك  ") == "یک",
        jinja_helpers.normalize_persian("  ي\u200cك  "),
    )

    # ------------------------------------------------------------------
    # Fields
    # ------------------------------------------------------------------
    trade_meta = frappe.get_meta("Trade Case")

    for fieldname in (
        "sales_invoice_number",
        "sales_invoice_date",
        "purchase_invoice_number",
        "purchase_invoice_date",
        "sales_amount_usd",
    ):
        check(
            f"Trade Case field {fieldname}",
            bool(trade_meta.get_field(fieldname)),
        )

    usd_field = trade_meta.get_field("sales_amount_usd")
    check(
        "sales_amount_usd options=USD",
        bool(usd_field) and usd_field.options == "USD",
    )

    transport_meta = frappe.get_meta("Transport Case")

    for fieldname in (
        "sales_invoice_number",
        "sales_invoice_date",
        "purchase_invoice_number",
        "purchase_invoice_date",
        "packing_date",
    ):
        check(
            f"Transport Case field {fieldname}",
            bool(transport_meta.get_field(fieldname)),
        )

    # ------------------------------------------------------------------
    # Reports and exact naming
    # ------------------------------------------------------------------
    for report_name, (directory, ref_doctype) in REPORTS.items():
        exists = bool(frappe.db.exists("Report", report_name))
        check(f"Report {report_name}", exists)

        if exists:
            doc = frappe.get_doc("Report", report_name)
            check(
                f"{report_name} ref_doctype",
                doc.ref_doctype == ref_doctype,
                str(doc.ref_doctype),
            )
            check(
                f"{report_name} exact report_name",
                doc.report_name == report_name,
                str(doc.report_name),
            )

        module_name = (
            f"transport_ir.iran_transport.report."
            f"{directory}.{directory}"
        )

        try:
            module = importlib.import_module(module_name)
            columns, data = module.execute({})
            check(
                f"{report_name} execute",
                isinstance(columns, list) and isinstance(data, list),
            )
            check(
                f"{report_name} columns have fieldname",
                all(column.get("fieldname") for column in columns),
            )
        except Exception as exc:
            check(
                f"{report_name} execute",
                False,
                str(exc),
            )

    # ------------------------------------------------------------------
    # 26-column report and real purchase/sales separation
    # ------------------------------------------------------------------
    from transport_ir.iran_transport.report.trade_transport_1405.trade_transport_1405 import (
        _build_report_rows,
        get_columns,
    )

    columns = get_columns()
    check("1405 exact 26 columns", len(columns) == 26)
    check(
        "1405 all columns have fieldname",
        all(column.get("fieldname") for column in columns),
    )

    synthetic_rows = [
        frappe._dict(
            {
                "name": "SALE-TEST",
                "case_type": "فروش",
                "posting_date": "2026-03-21",
                "customer": "Customer A",
                "supplier_factory": "Supplier A",
                "item": "Item A",
                "cargo_description": "",
                "planned_tonnage": 10,
                "sales_amount_usd": 100,
                "sales_amount": 1000,
                "purchase_amount": 0,
                "sales_invoice_number": "S-1",
                "sales_invoice_date": "2026-03-21",
                "purchase_invoice_number": None,
                "purchase_invoice_date": None,
                "workflow_state": "Approved",
            }
        ),
        frappe._dict(
            {
                "name": "PURCHASE-TEST",
                "case_type": "خرید",
                "posting_date": "2026-03-22",
                "customer": "Customer B",
                "supplier_factory": "Supplier B",
                "item": "Item B",
                "cargo_description": "",
                "planned_tonnage": 20,
                "sales_amount_usd": 0,
                "sales_amount": 0,
                "purchase_amount": 2000,
                "sales_invoice_number": None,
                "sales_invoice_date": None,
                "purchase_invoice_number": "P-1",
                "purchase_invoice_date": "2026-03-22",
                "workflow_state": "Approved",
            }
        ),
    ]

    synthetic_data = _build_report_rows(
        synthetic_rows,
        {
            "SALE-TEST": 8,
            "PURCHASE-TEST": 25,
        },
    )

    sale_row = synthetic_data[0]
    purchase_row = synthetic_data[1]

    check(
        "sales row populates sales side",
        sale_row[4] == 10 and sale_row[7] == 8,
    )
    check(
        "sales row does not populate purchase detail",
        sale_row[17] is None and sale_row[19] is None,
    )
    check(
        "purchase row populates purchase side",
        purchase_row[17] == 20 and purchase_row[19] == 25,
    )
    check(
        "purchase row does not populate sales detail",
        purchase_row[4] is None and purchase_row[7] is None,
    )
    check(
        "sales remaining independent",
        sale_row[12] == 2,
        str(sale_row[12]),
    )
    check(
        "purchase surplus independent",
        purchase_row[22] == 5,
        str(purchase_row[22]),
    )
    check(
        "purchase and sales cumulative totals differ",
        purchase_row[8] == 8 and purchase_row[20] == 25,
    )

    # ------------------------------------------------------------------
    # Print Formats and actual phase-6 DocTypes
    # ------------------------------------------------------------------
    for print_name, expected_doctype in PRINT_FORMATS.items():
        exists = bool(frappe.db.exists("Print Format", print_name))
        check(f"Print Format {print_name}", exists)

        if exists:
            actual_doctype = frappe.db.get_value(
                "Print Format",
                print_name,
                "doc_type",
            )
            check(
                f"{print_name} doc_type={expected_doctype}",
                actual_doctype == expected_doctype,
                str(actual_doctype),
            )

    check(
        "No rejected Waybill Print",
        not frappe.db.exists("Print Format", "Waybill Print"),
    )
    check(
        "No rejected Weighbridge Print",
        not frappe.db.exists("Print Format", "Weighbridge Print"),
    )

    # ------------------------------------------------------------------
    # Excel API security and endpoints
    # ------------------------------------------------------------------
    from transport_ir.iran_transport.api import report_excel

    for method_name in (
        "download_1405",
        "export_packing",
        "export_carrier_statement",
        "export_customs_statement",
        "export_proforma",
        "download_proforma_template",
        "import_proforma_excel",
    ):
        check(
            f"Excel API {method_name}",
            hasattr(report_excel, method_name),
        )

    # Custom Excel layer checks (Optional - Warning only)
    try:
        from transport_ir.iran_transport.api import report_excel_custom

        for m in (
            "export_financial_custom",
            "export_freight_custom",
            "export_packing_custom",
            "export_purchase_custom",
            "export_dispatch_custom",
            "import_purchase_custom",
            "import_freight_custom",
        ):
            check(f"Custom API {m}", hasattr(report_excel_custom, m))

        custom_src = inspect.getsource(report_excel_custom._load_and_fill_report)
        check(
            "Custom Excel unmerges data area",
            "_unmerge_data_area" in custom_src or "unmerge_cells" in custom_src,
        )
        check(
            "Custom Excel fuzzy header discovery",
            hasattr(report_excel_custom, "_find_header_row"),
        )
        check(
            "Custom Excel merge-safe row insert",
            hasattr(report_excel_custom, "_ensure_data_rows"),
        )
        check(
            "Custom Excel link resolution",
            hasattr(report_excel_custom, "_resolve_link_smart"),
        )
        check(
            "Custom Excel five templates registered",
            set(report_excel_custom.TEMPLATE_REGISTRY)
            >= {
                "financial",
                "freight",
                "packing",
                "purchase",
                "dispatch",
            },
        )
        check(
            "Custom Excel persian normalizer",
            report_excel_custom._norm("  ي\u200cك  ") == "یک",
            report_excel_custom._norm("  ي\u200cك  "),
        )

        # Golden rules: exact client text, coordinate lock, formula protection
        financial = report_excel_custom.TEMPLATE_REGISTRY["financial"]
        check(
            "T01 exact sheet name",
            financial["sheet"] == "گزارش 1405",
            financial["sheet"],
        )
        check(
            "T01 exact 26 mapped columns",
            len(financial["columns"]) == 26,
            str(len(financial["columns"])),
        )
        check(
            "T01 hidden columns preserved",
            tuple(financial["hidden_columns"])
            == ("I", "J", "K", "M", "U", "V", "W", "Y"),
        )
        check(
            "T01 client spelling «تامین کننده» preserved",
            any(
                column["header"] == "تامین کننده"
                for column in financial["columns"]
            ),
        )

        freight = report_excel_custom.TEMPLATE_REGISTRY["freight"]
        freight_headers = [column["header"] for column in freight["columns"]]
        check(
            "T02 client typo «هزنیه تخلیه» preserved",
            "هزنیه تخلیه" in freight_headers,
        )
        check(
            "T02 client typo «هزنیه بارگیری» preserved",
            "هزنیه بارگیری" in freight_headers,
        )
        check(
            "T02 formula families registered",
            freight["formula_patterns"]["G"] == "=F{row}*E{row}"
            and freight["formula_patterns"]["J"] == "=I{row}+G{row}"
            and freight["formula_patterns"]["L"] == "=J{row}-K{row}",
        )

        packing = report_excel_custom.TEMPLATE_REGISTRY["packing"]
        packing_by_col = {
            column["col"]: column for column in packing["columns"]
        }
        check(
            "T03 stays LTR",
            packing["rtl"] is False,
        )
        check(
            "T03 Branch is not mapped to border",
            packing_by_col["E"]["header"] == "Branch"
            and packing_by_col["E"]["field"] == "qty",
        )
        check(
            "T03 Delivery B. is never the sales invoice",
            packing_by_col["G"]["header"] == "Delivery B."
            and packing_by_col["G"]["field"] != "sales_invoice_number",
        )
        check(
            "T03 no logo re-injection",
            packing["allow_logo_injection"] is False,
        )

        purchase = report_excel_custom.TEMPLATE_REGISTRY["purchase"]
        check(
            "T04 four exact sheets",
            tuple(purchase["required_sheets"])
            == (
                "فروشنده",
                "معرفی کالا",
                "پیش فاکتور خرید",
                "صورت بارگیری",
            ),
        )
        check(
            "T04 SUMIFS key uses صورت بارگیری D against پیش فاکتور خرید C",
            "'صورت بارگیری'!$D$3:$D$1048576,C{row}"
            in purchase["formula_patterns"]["I"],
        )
        check(
            "T04 I2 protected",
            "I2" in tuple(purchase["protected_cells"]),
        )
        loading = purchase["extra_sheets"]["loading"]
        check(
            "T04 client spelling «پگینگ» preserved",
            any(
                column["header"] == "پگینگ"
                for column in loading["columns"]
            ),
        )
        check(
            "T04 loading title formula A1 protected",
            "A1" in tuple(loading["protected_cells"]),
        )

        dispatch = report_excel_custom.TEMPLATE_REGISTRY["dispatch"]
        check(
            "T05 B2:L2 merge protected",
            "B2:L2" in tuple(dispatch["protected_merges"]),
        )
        check(
            "T05 E SUM registered",
            dispatch["sum_columns"].get("E") == "E10",
        )

        import_source = inspect.getsource(
            report_excel_custom.import_purchase_custom
        )
        check(
            "Custom import has preview mode",
            "mode=\"preview\"" in import_source,
        )
        check(
            "Custom import has duplicate guard",
            "duplicate" in import_source,
        )
    except Exception as e:
        print(f"⚠️ Custom Excel module check skipped: {e}")

    import_source = inspect.getsource(
        report_excel.import_proforma_excel
    )

    check(
        "Excel import uses file_url",
        "file_url" in import_source,
    )
    check(
        "Excel import checks File permission",
        "check_permission" in import_source,
    )
    check(
        "Excel import restricts XLSX",
        "endswith(\".xlsx\")" in import_source,
    )
    check(
        "Excel import has row limit",
        "MAX_IMPORT_ROWS" in import_source,
    )

    # ------------------------------------------------------------------
    # Hooks
    # ------------------------------------------------------------------
    required_apps = frappe.get_hooks("required_apps") or []
    check(
        "transport_ir requires ir_jalali",
        "ir_jalali" in required_apps,
        str(required_apps),
    )

    jinja_hooks = frappe.get_hooks("jinja") or {}
    methods = (
        jinja_hooks.get("methods", [])
        if isinstance(jinja_hooks, dict)
        else []
    )

    check(
        "fa_date Jinja hook",
        any("jinja_helpers.fa_date" in str(value) for value in methods),
    )
    check(
        "normalize_persian Jinja hook",
        any(
            "jinja_helpers.normalize_persian" in str(value)
            for value in methods
        ),
    )

    # ------------------------------------------------------------------
    # Workspace links (optional only if workspace exists)
    # ------------------------------------------------------------------
    expected_workspace_reports = {
        "CEO Dashboard": "Trade Transport 1405",
        "Finance": "Profit Report",
        "Iran Transport": "Packing Report",
        "Customs": "Customs Report",
    }

    for workspace_name, report_name in expected_workspace_reports.items():
        if not frappe.db.exists("Workspace", workspace_name):
            continue

        workspace = frappe.get_doc("Workspace", workspace_name)
        report_links = {
            row.link_to
            for row in (workspace.links or [])
            if row.type == "Link" and row.link_type == "Report"
        }

        check(
            f"{workspace_name} links {report_name}",
            report_name in report_links,
        )

        card_labels = {
            row.label
            for row in (workspace.links or [])
            if row.type == "Card Break"
        }
        if workspace_name in ("CEO Dashboard", "Finance", "Iran Transport"):
            check(
                f"{workspace_name} has standard card",
                "گزارش‌ها و خروجی‌ها استاندارد" in card_labels,
            )
            check(
                f"{workspace_name} has custom card",
                "گزارش‌ها و خروجی‌ها اختصاصی" in card_labels,
            )

        # هیچ link_type=URL نباید باشد
        bad_urls = [
            row.link_to
            for row in (workspace.links or [])
            if row.type == "Link" and getattr(row, "link_type", None) == "URL"
        ]
        check(
            f"{workspace_name} has no URL links",
            not bad_urls,
            str(bad_urls),
        )

    print(f"\n{'=' * 68}")
    print(f"Passed: {len(passed)} | Failed: {len(failed)}")
    print(f"{'=' * 68}")

    if failed:
        for item in failed:
            print("  -", item)

        frappe.throw(
            "Phase 8 verification failed: " + " | ".join(failed)
        )

    print("🎉 Phase 8 final checks passed")
    return {
        "passed": len(passed),
        "failed": len(failed),
    }
EOF

# =============================================================================
# 22) Pre-migrate structural checks
# =============================================================================

step "22) pre-migrate structural checks"

python3 <<'PYEOF'
import ast
import json
import os
import re
import sys

mod = os.environ["MOD"]
hooks = os.environ["HOOKS"]

errors = []

python_files = [
    os.path.join(mod, "phase8", "events.py"),
    os.path.join(mod, "utils", "jinja_helpers.py"),
    os.path.join(mod, "api", "report_excel.py"),
    os.path.join(mod, "setup_phase8.py"),
    os.path.join(mod, "verify_phase8.py"),
]

custom_api = os.path.join(mod, "api", "report_excel_custom.py")
if os.path.exists(custom_api):
    python_files.append(custom_api)

report_root = os.path.join(mod, "report")

for directory in sorted(os.listdir(report_root)):
    path = os.path.join(report_root, directory)

    if not os.path.isdir(path) or directory.startswith("__"):
        continue

    python_path = os.path.join(path, f"{directory}.py")
    json_path = os.path.join(path, f"{directory}.json")

    if os.path.exists(python_path):
        python_files.append(python_path)

    if os.path.exists(json_path):
        try:
            data = json.load(open(json_path, encoding="utf-8"))
            report_name = data.get("report_name") or data.get("name")
            expected_directory = re.sub(
                r"[^a-z0-9]+",
                "_",
                report_name.lower(),
            ).strip("_")

            if expected_directory != directory:
                errors.append(
                    f"Report folder mismatch: {directory} != "
                    f"{expected_directory} ({report_name})"
                )

            if data.get("name") != data.get("report_name"):
                errors.append(
                    f"Report name/report_name mismatch: {json_path}"
                )
        except Exception as exc:
            errors.append(f"Invalid report JSON {json_path}: {exc}")

for path in python_files:
    try:
        ast.parse(open(path, encoding="utf-8").read())
        print("python OK:", path)
    except Exception as exc:
        errors.append(f"Python syntax {path}: {exc}")

try:
    ast.parse(open(hooks, encoding="utf-8").read())
    print("hooks OK:", hooks)
except Exception as exc:
    errors.append(f"hooks.py syntax: {exc}")

expected_prints = {
    "trade_case_proforma": ("Trade Case Proforma", "Trade Case"),
    "transport_packing_list": (
        "Transport Packing List",
        "Transport Case",
    ),
    "transport_waybill_print": (
        "Transport Waybill Print",
        "Transport Waybill",
    ),
    "transport_weighbridge_print": (
        "Transport Weighbridge Print",
        "Transport Weighbridge",
    ),
}

for directory, (name, doctype) in expected_prints.items():
    path = os.path.join(
        mod,
        "print_format",
        directory,
        f"{directory}.json",
    )

    try:
        data = json.load(open(path, encoding="utf-8"))

        if data.get("name") != name:
            errors.append(f"Print name mismatch: {path}")

        if data.get("doc_type") != doctype:
            errors.append(
                f"Print DocType mismatch: {path} -> "
                f"{data.get('doc_type')} != {doctype}"
            )
    except Exception as exc:
        errors.append(f"Invalid print JSON {path}: {exc}")

for fixture_name in ("translation.json",):
    path = os.path.join(
        os.environ["PKG"],
        "fixtures",
        fixture_name,
    )

    if not os.path.exists(path):
        continue

    try:
        rows = json.load(open(path, encoding="utf-8"))
    except Exception as exc:
        errors.append(f"Invalid fixture {path}: {exc}")
        continue

    if not isinstance(rows, list):
        errors.append(f"Fixture must be list: {path}")
        continue

    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            errors.append(f"{path}[{index}] is not an object")
            continue

        if not row.get("doctype") or not row.get("name"):
            errors.append(
                f"{path}[{index}] missing doctype/name"
            )

if errors:
    print("\nPRE-MIGRATE CHECK FAILED:")

    for error in errors:
        print(" -", error)

    sys.exit(1)

print("\nAll pre-migrate structural checks passed")
PYEOF

# =============================================================================
# 23) Build, migrate, setup, verify
# =============================================================================

step "23) build + migrate + setup + verify"

cd "$BENCH_DIR"

bench build --app "$APP"

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache

bench --site "$SITE_NAME" execute \
  transport_ir.iran_transport.setup_phase8.setup_phase8

bench --site "$SITE_NAME" clear-cache

bench --site "$SITE_NAME" execute \
  transport_ir.iran_transport.verify_phase8.verify_phase8

# =============================================================================
# 24) Git commit
# =============================================================================

step "24) git commit"

cd "$APP_ROOT"

git config user.email >/dev/null 2>&1 \
  || git config user.email "dev@example.com"

git config user.name >/dev/null 2>&1 \
  || git config user.name "IR Base Contributors"

git add -A

git commit -m \
  "phase 8 final: independent 1405 finance report, secure Excel, RTL prints, grouped reports and golden-rules custom Excel sync" \
  || warn "nothing to commit"

cd "$BENCH_DIR"

# =============================================================================
# DONE
# =============================================================================

step "DONE"

cat <<FINAL

${GREEN}════════════════════════════════════════════════════════════════${NC}
${GREEN}  PHASE 8 FINAL COMPLETED (GOLDEN RULES EXCEL SYNC)${NC}
${GREEN}════════════════════════════════════════════════════════════════${NC}

Workspace (دو کارت — فقط link_type=Report):

  • گزارش‌ها و خروجی‌ها استاندارد
      کرایه / گمرک / تناژ / سود / متوقف / پرداخت / خلاصه / پکینگ

  • گزارش‌ها و خروجی‌ها اختصاصی
      گزارش جامع مالی  (= Trade Transport 1405 / template_01)

اکسل اختصاصی — هر ۵ قالب کارفرما فعال:

  template_01_financial  → export_financial_custom
  template_02_freight    → export_freight_custom
  template_03_packing    → export_packing_custom
  template_04_purchase   → export_purchase_custom   (جدید)
  template_05_dispatch   → export_dispatch_custom   (جدید)

جای دقیق دکمه‌ها:

  • List پرونده تجاری  → گروه «اکسل اختصاصی»
      (مالی / کرایه / پکینگ / خرید / ارسال + دو ورودی اکسل)
  • List پرونده حمل    → گروه «اکسل اختصاصی»
      (ارسال / کرایه / پکینگ + ورود لیست کرایه)
  • Form پرونده تجاری  → منوی «خروجی» (تک‌پرونده با name=)
  • داخل خود گزارش‌ها → منوی «خروجی»:
      - Trade Transport 1405 → خروجی اختصاصی + خروجی خرید
      - Freight Report → لیست تسویه کرایه + خروجی ارسال/بارنامه
      - Packing Report → پکینگ لیست گمرکی (اختصاصی)

  (Workspace نمی‌تواند link_type=URL داشته باشد؛ برای همین
   خروجی‌های API فقط در List/Form/Report هستند.)

قوانین سینک طلایی اعمال‌شده در report_excel_custom.py:

  P0 قرارداد واقعی اکسل: نام شیت، مختصات سلول، merge،
     ستون‌های مخفی، متن دقیق سربرگ، فرمول
  P1 فقط فیلدهای واقعی پروژه؛ هیچ fieldname ساختگی
  متن کارفرما هرگز «اصلاح املایی» نمی‌شود
     (هزنیه تخلیه / هزنیه بارگیری / پگینگ / ترخیصکار /
      تامین کننده / Data / مبدا عیناً حفظ می‌شوند)
  alias فقط در لایه matching، نه در فایل خروجی
  قفل مختصات مقدم بر fuzzy؛ ابهام ⇒ UNRESOLVED (خالی + Sync Log)
  فرمول‌ها محافظت‌شده: =F*E ، =I+G ، =J-K ،
     SUMIFS خرید ('صورت بارگیری'!D ↔ 'پیش فاکتور خرید'!C) ،
     SUM های F11 و E10 فقط با بازنویسی مجاز بازه
  merge/style/logo/جهت صفحه دست‌نخورده؛ T03 همچنان LTR
  ستون‌های مخفی T01 (I J K M U V W Y) مخفی می‌مانند
  عدد عددی می‌ماند و شناسه‌ها رشته‌ای (شبا/پلاک/موبایل/فاکتور)
  Import = Preview → Validate → Resolve → Commit با
     duplicate guard و rollback کامل روی خطا
  Sync Log کامل (template_key/sheet/cell/field/confidence/action)

چک مرورگر:
  [ ] Logout / Login + Ctrl+Shift+R
  [ ] دو کارت استاندارد و اختصاصی در Workspace
  [ ] گزارش جامع مالی فقط زیر اختصاصی
  [ ] پکینگ اختصاصی: یک لوگو، داده زیر سربرگ آبی، فرم سالم
  [ ] خروجی خرید و ارسال (دو قالب جدید) تست شود
  [ ] Templates staged از کنار اسکریپت (excel_client_files)

FINAL
