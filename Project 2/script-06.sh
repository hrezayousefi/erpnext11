#!/usr/bin/env bash
# =============================================================================
# script-06.sh — گردش‌کار یکپارچه + گارد امضا + دفتر بدهی کارخانه
# بازسازی هدایت‌شده — Iran Trade ERP | ERPNext v15 / Frappe v15
# -----------------------------------------------------------------------------
# این اسکریپت می‌سازد:
#   1) یک گردش‌کار یکپارچه برای Trade Case (نه دو گردش‌کار جدا و قاطی)
#      Draft → Legal Review → Treasury Review → Pending Signature →
#      Finance Supervisor Approval → Receivables → Approved
#      + Waiting Supply / Returned / On Hold / Rejected / Cancelled / Completed
#      * مسیرهای استثنا (رد/تعلیق/لغو) از «همه» مراحل میانی در دسترس‌اند.
#      * تعلیق به «وضعیت قبلی» بازمی‌گردد، نه همیشه به Draft.
#      * دلیل رد/تعلیق/لغو اجباری است.
#   2) گارد امضا — اصلاح باگ ریشه‌ای «وارونگی»:
#      ورود به مرحله امضا آزاد | خروج از آن بدون سند امضاشده مسدود.
#      آپلود سند امضاشده مجاز برای Document Signer و Finance Supervisor
#      (طبق واقعیت: نهال‌پرور برگه سپیدار را چاپ و پس از امضا بارگذاری می‌کند).
#   3) گارد چک‌لیست حقوقی (۵ قلم) و چک‌لیست سرپرست مالی (۶ قلم)
#   4) ★ پیامک «بازگشت به سرپرست مالی» دقیقاً پیش از رسیدن پرونده به میز
#      نهال‌پرور، برای همان مدیرعامل دستوردهنده (فقط اطلاع، بدون هیچ لینک)
#   5) Factory Shortfall Ledger — دفتر بدهی کارخانه با قابلیت تسویه بعدی
#
# هیچ فایلی از فازهای قبل خراب نمی‌شود. اجرای مجدد بی‌خطر است.
# =============================================================================
set -euo pipefail
export LANG=C.UTF-8; export LC_ALL=C.UTF-8; export PYTHONIOENCODING=utf-8

export SITE_NAME="${SITE_NAME:-transport-dev.local}"
export BENCH_DIR="${BENCH_DIR:-${HOME}/frappe-bench}"
export APP="iran_trade_erp"
export PKG="${BENCH_DIR}/apps/${APP}/${APP}"
export MOD="${PKG}/iran_trade"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${YELLOW}======== $* ========${NC}"; }
write_utf8() { local t="$1"; local tmp; tmp="$(mktemp)"; cat >"$tmp"; mkdir -p "$(dirname "$t")"; mv -f "$tmp" "$t"; log "write: $t"; }

[[ -d "$BENCH_DIR" ]] || err "Bench یافت نشد"; cd "$BENCH_DIR"

step "0) سرویس‌ها"
if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "bench در حال اجراست"
else nohup bench start >>/tmp/bench-start-itc06.log 2>&1 & log "pid=$!"; sleep 12; fi
RC="${BENCH_DIR}/config/redis_cache.conf"
RP="$( [[ -f "$RC" ]] && awk '$1=="port"{print $2; exit}' "$RC" || echo 13000 )"; [[ -n "$RP" ]] || RP=13000
R=0; for _i in $(seq 1 60); do
  if command -v redis-cli >/dev/null 2>&1 && redis-cli -h 127.0.0.1 -p "$RP" ping 2>/dev/null | grep -q '^PONG$'; then R=1; break; fi
  if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ":${RP}[[:space:]]"; then R=1; break; fi
  sleep 1; done
[[ "$R" -eq 1 ]] || err "redis آماده نشد"
bench use "$SITE_NAME" 2>/dev/null || true

step "0b) پیش‌نیاز — ABORT در نبود Anchor"
[[ -f "${MOD}/notification/core.py" ]] || err "ABORT: سرویس اعلان نیست. ابتدا script-05.sh"
[[ -f "${MOD}/doctype/trade_case/trade_case.py" ]] || err "ABORT: Trade Case نیست"
grep -q "SCRIPT05_HOOKS_START" "${PKG}/hooks.py" || err "ABORT: بلوک SCRIPT05 در hooks.py نیست"
log "پیش‌نیازها تایید شد"

mk_dt() { mkdir -p "${MOD}/doctype/$1"; : > "${MOD}/doctype/$1/__init__.py"; }

# =============================================================================
step "1) دفتر بدهی کارخانه (Factory Shortfall Ledger)"
mk_dt factory_shortfall_ledger
write_utf8 "${MOD}/doctype/factory_shortfall_ledger/factory_shortfall_ledger.json" << 'EOF'
{
 "actions": [], "autoname": "naming_series:", "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["naming_series", "supplier_factory", "trade_case", "item", "cb_1",
                 "shortfall_tonnage", "shortfall_amount_base", "ledger_status", "created_on",
                 "sb_2", "settled_on", "settled_by_user", "cb_2", "settled_reference", "notes"],
 "fields": [
  {"default": "FSL-.YYYY.-.####", "fieldname": "naming_series", "fieldtype": "Select", "hidden": 1, "label": "سری", "options": "FSL-.YYYY.-.####"},
  {"fieldname": "supplier_factory", "fieldtype": "Link", "in_list_view": 1, "in_standard_filter": 1, "label": "کارخانه / تأمین‌کننده", "options": "Supplier", "reqd": 1},
  {"fieldname": "trade_case", "fieldtype": "Link", "in_list_view": 1, "label": "پرونده مبدأ", "options": "Trade Case", "reqd": 1},
  {"fieldname": "item", "fieldtype": "Link", "in_list_view": 1, "label": "کالا", "options": "Item"},
  {"fieldname": "cb_1", "fieldtype": "Column Break"},
  {"fieldname": "shortfall_tonnage", "fieldtype": "Float", "in_list_view": 1, "label": "تناژ کسری", "reqd": 1},
  {"fieldname": "shortfall_amount_base", "fieldtype": "Currency", "label": "ارزش کسری (پایه ریالی)"},
  {"default": "باز", "fieldname": "ledger_status", "fieldtype": "Select", "in_list_view": 1, "in_standard_filter": 1, "label": "وضعیت", "options": "باز\nتسویه‌شده", "reqd": 1},
  {"fieldname": "created_on", "fieldtype": "Datetime", "label": "تاریخ ثبت", "read_only": 1},
  {"fieldname": "sb_2", "fieldtype": "Section Break", "label": "تسویه"},
  {"fieldname": "settled_on", "fieldtype": "Datetime", "label": "تاریخ تسویه", "read_only": 1},
  {"fieldname": "settled_by_user", "fieldtype": "Link", "label": "تسویه توسط", "options": "User", "read_only": 1},
  {"fieldname": "cb_2", "fieldtype": "Column Break"},
  {"fieldname": "settled_reference", "fieldtype": "Link", "label": "پرونده جبران‌کننده", "options": "Trade Case"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "توضیح"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Factory Shortfall Ledger", "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "read": 1, "write": 1, "report": 1, "export": 1, "print": 1, "role": "System Manager"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "export": 1, "role": "Finance Supervisor"},
  {"read": 1, "write": 1, "report": 1, "role": "Financial Manager"},
  {"read": 1, "report": 1, "role": "Finance User"},
  {"read": 1, "report": 1, "role": "Transport Supervisor"},
  {"read": 1, "report": 1, "role": "CEO"}
 ],
 "sort_field": "modified", "sort_order": "DESC", "track_changes": 1
}
EOF
write_utf8 "${MOD}/doctype/factory_shortfall_ledger/factory_shortfall_ledger.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
دفتر بدهی کارخانه — نیازمندی کاملاً جدید (در هیچ نسل قبلی وجود نداشت).

واقعیت روزمره: باسکول دقیق است اما بارگیری مطابق انتظار نیست.
۱۰۰ تن خریداری می‌شود، ۴ تریلی می‌رود، هرکدام ۲۴ تن ⇒ ۹۶ تن.
فاکتور خرید هرگز صفر نمی‌شود.

راه‌حل: بستن دستی با دلیل + ثبت کسری به‌عنوان طلب رسمی از همان کارخانه،
با امکان تسویه بعدی و ارجاع به معامله جبرانی.
"""
import frappe
from frappe import _
from frappe.model.document import Document
from frappe.utils import flt, now_datetime


class FactoryShortfallLedger(Document):
    def before_insert(self):
        if not self.created_on:
            self.created_on = now_datetime()

    def validate(self):
        if flt(self.shortfall_tonnage) <= 0:
            frappe.throw(_("تناژ کسری باید بزرگ‌تر از صفر باشد."))
        if self.ledger_status == "تسویه‌شده" and not self.settled_reference and not self.notes:
            frappe.throw(_("برای تسویه، «پرونده جبران‌کننده» یا توضیح الزامی است."))


def record_shortfall_from_case(case_doc, snapshot):
    """
    ثبت خودکار کسری در لحظه بستن دستی پرونده.
    فقط ردیف‌های «خرید» طلب از کارخانه ایجاد می‌کنند.
    """
    if not case_doc.supplier_factory:
        frappe.log_error(
            title="کسری بدون کارخانه ثبت نشد",
            message="پرونده {0} کارخانه/تأمین‌کننده ندارد؛ دفتر بدهی ساخته نشد.".format(case_doc.name),
        )
        return []

    created = []
    for row in snapshot or []:
        if row.get("row_kind") != "خرید":
            continue
        if frappe.db.exists("Factory Shortfall Ledger",
                            {"trade_case": case_doc.name, "item": row.get("item"),
                             "ledger_status": "باز"}):
            continue
        unit_base = 0.0
        for it in case_doc.items or []:
            if it.name == row.get("row") and flt(it.tonnage):
                unit_base = flt(it.base_amount) / flt(it.tonnage)
                break
        d = frappe.new_doc("Factory Shortfall Ledger")
        d.supplier_factory = case_doc.supplier_factory
        d.trade_case = case_doc.name
        d.item = row.get("item")
        d.shortfall_tonnage = flt(row.get("remaining"), 3)
        d.shortfall_amount_base = flt(unit_base * flt(row.get("remaining")), 2)
        d.ledger_status = "باز"
        d.notes = case_doc.manual_close_reason
        d.flags.ignore_permissions = True
        d.insert(ignore_permissions=True)
        created.append(d.name)
        _notify_shortfall(d)
    return created


def _notify_shortfall(doc):
    try:
        from iran_trade_erp.iran_trade.notification.core import notify
        notify("factory_shortfall.recorded", doc.doctype, doc.name, {
            "shortfall_tonnage": doc.shortfall_tonnage,
            "supplier_factory": doc.supplier_factory,
        })
    except Exception:
        frappe.log_error(title="اعلان کسری کارخانه ارسال نشد", message=frappe.get_traceback())


@frappe.whitelist()
def settle_shortfall(name, settled_reference=None, notes=None):
    """صفر کردن یک ردیف کسری وقتی کارخانه بعداً جبران کرد."""
    roles = set(frappe.get_roles())
    if not roles.intersection({"Finance Supervisor", "Financial Manager", "System Manager"}):
        frappe.throw(_("فقط سرپرست/مدیر مالی می‌تواند کسری را تسویه کند."))
    d = frappe.get_doc("Factory Shortfall Ledger", name)
    if d.ledger_status == "تسویه‌شده":
        return {"status": "already_settled"}
    if not settled_reference and not (notes or "").strip():
        frappe.throw(_("برای تسویه، «پرونده جبران‌کننده» یا توضیح الزامی است."))
    d.settled_reference = settled_reference
    d.notes = (d.notes or "") + ("\n" + notes if notes else "")
    d.settled_on = now_datetime()
    d.settled_by_user = frappe.session.user
    d.ledger_status = "تسویه‌شده"
    d.save()
    frappe.db.commit()
    return {"status": "settled"}


@frappe.whitelist()
def factory_debt_summary(supplier=None):
    """گزارش تجمیعی «جمع بدهکاری هر کارخانه»."""
    if not frappe.has_permission("Factory Shortfall Ledger", "read"):
        frappe.throw(_("دسترسی لازم را ندارید."))
    cond = "AND supplier_factory = %(s)s" if supplier else ""
    return frappe.db.sql(
        """SELECT supplier_factory,
                  SUM(CASE WHEN ledger_status='باز' THEN shortfall_tonnage ELSE 0 END) AS open_tonnage,
                  SUM(CASE WHEN ledger_status='باز' THEN shortfall_amount_base ELSE 0 END) AS open_amount,
                  SUM(shortfall_tonnage) AS total_tonnage,
                  COUNT(*) AS rows_count
           FROM `tabFactory Shortfall Ledger`
           WHERE 1=1 {0}
           GROUP BY supplier_factory
           ORDER BY open_tonnage DESC""".format(cond),
        {"s": supplier}, as_dict=True,
    )
EOF

# =============================================================================
step "2) وضعیت‌های گردش‌کار (نام فنی انگلیسی، برچسب فارسی از fa.csv)"
write_utf8 "${PKG}/fixtures/workflow_state.json" << 'EOF'
[
 {"doctype": "Workflow State", "name": "Draft", "workflow_state_name": "Draft", "style": ""},
 {"doctype": "Workflow State", "name": "Waiting Supply", "workflow_state_name": "Waiting Supply", "style": "Warning"},
 {"doctype": "Workflow State", "name": "Legal Review", "workflow_state_name": "Legal Review", "style": "Info"},
 {"doctype": "Workflow State", "name": "Treasury Review", "workflow_state_name": "Treasury Review", "style": "Info"},
 {"doctype": "Workflow State", "name": "Pending Signature", "workflow_state_name": "Pending Signature", "style": "Warning"},
 {"doctype": "Workflow State", "name": "Finance Supervisor Approval", "workflow_state_name": "Finance Supervisor Approval", "style": "Info"},
 {"doctype": "Workflow State", "name": "Receivables", "workflow_state_name": "Receivables", "style": "Info"},
 {"doctype": "Workflow State", "name": "Approved", "workflow_state_name": "Approved", "style": "Success"},
 {"doctype": "Workflow State", "name": "Loading In Progress", "workflow_state_name": "Loading In Progress", "style": "Primary"},
 {"doctype": "Workflow State", "name": "Pending Finance Close", "workflow_state_name": "Pending Finance Close", "style": "Warning"},
 {"doctype": "Workflow State", "name": "Completed", "workflow_state_name": "Completed", "style": "Success"},
 {"doctype": "Workflow State", "name": "Returned", "workflow_state_name": "Returned", "style": "Warning"},
 {"doctype": "Workflow State", "name": "On Hold", "workflow_state_name": "On Hold", "style": "Warning"},
 {"doctype": "Workflow State", "name": "Rejected", "workflow_state_name": "Rejected", "style": "Danger"},
 {"doctype": "Workflow State", "name": "Cancelled", "workflow_state_name": "Cancelled", "style": "Danger"}
]
EOF

# ساخت برنامه‌نویسی‌شده گردش‌کار (allow_edit تک‌نقشی است — قاعده Frappe v15)
write_utf8 "${MOD}/workflow/install_workflow.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
نصب Idempotent گردش‌کار یکپارچه پرونده بازرگانی.

قاعده حیاتی Frappe v15: allow_edit و allowed در هر ردیف «تک‌نقشی» هستند
(Link، نه Select چندمقداره). برای چند نقش، چند ردیف لازم است.

action در Workflow Transition یک Link به «Workflow Action Master» است؛
بدون ساخت قبلی رکورد Action، LinkValidationError رخ می‌دهد.
"""
import frappe

WORKFLOW_NAME = "Trade Case Workflow"

# (state, doc_status, allow_edit)
STATES = [
    ("Draft", 0, "Finance User"),
    ("Draft", 0, "Finance Supervisor"),
    ("Waiting Supply", 0, "Finance Supervisor"),
    ("Legal Review", 0, "Legal Reviewer"),
    ("Treasury Review", 0, "Treasury User"),
    ("Pending Signature", 0, "Document Signer"),
    ("Pending Signature", 0, "Finance Supervisor"),   # نهال‌پرور سند امضاشده را بارگذاری می‌کند
    ("Finance Supervisor Approval", 0, "Finance Supervisor"),
    ("Receivables", 0, "Receivables User"),
    ("Approved", 0, "Transport Supervisor"),
    ("Loading In Progress", 0, "Transport Supervisor"),
    ("Pending Finance Close", 0, "Finance Supervisor"),
    ("Completed", 0, "Finance Supervisor"),
    ("Returned", 0, "Finance User"),
    ("On Hold", 0, "Finance Supervisor"),
    ("Rejected", 0, "Finance Supervisor"),
    ("Cancelled", 0, "Finance Supervisor"),
]

STATE_STYLES = {
    "Draft": "",
    "Waiting Supply": "Warning",
    "Legal Review": "Info",
    "Treasury Review": "Info",
    "Pending Signature": "Warning",
    "Finance Supervisor Approval": "Info",
    "Receivables": "Info",
    "Approved": "Success",
    "Loading In Progress": "Primary",
    "Pending Finance Close": "Warning",
    "Completed": "Success",
    "Returned": "Warning",
    "On Hold": "Warning",
    "Rejected": "Danger",
    "Cancelled": "Danger",
}

MID_STATES = ["Draft", "Waiting Supply", "Legal Review", "Treasury Review",
              "Pending Signature", "Finance Supervisor Approval", "Receivables",
              "Approved", "Loading In Progress", "Pending Finance Close"]

# (state, action, next_state, allowed_role, condition)
TRANSITIONS = [
    ("Draft", "ارسال به حقوقی", "Legal Review", "Finance User", ""),
    ("Draft", "پارک در انتظار تأمین کالا", "Waiting Supply", "Finance Supervisor", ""),
    ("Waiting Supply", "آزادسازی و ادامه", "Draft", "Finance Supervisor", ""),

    ("Legal Review", "تایید حقوقی", "Treasury Review", "Legal Reviewer", ""),
    ("Legal Review", "بازگشت به مالی", "Returned", "Legal Reviewer", ""),

    ("Treasury Review", "تایید خزانه", "Pending Signature", "Treasury User", ""),
    ("Treasury Review", "بازگشت به مالی", "Returned", "Treasury User", ""),

    ("Pending Signature", "امضا شد", "Finance Supervisor Approval", "Document Signer", ""),
    ("Pending Signature", "ثبت امضا توسط سرپرست مالی", "Finance Supervisor Approval", "Finance Supervisor", ""),

    ("Finance Supervisor Approval", "تایید سرپرست", "Receivables", "Finance Supervisor", ""),
    ("Finance Supervisor Approval", "بازگشت به مالی", "Returned", "Finance Supervisor", ""),

    ("Receivables", "تایید وصول", "Approved", "Receivables User", ""),
    ("Receivables", "بازگشت به سرپرست", "Finance Supervisor Approval", "Receivables User", ""),

    ("Approved", "شروع بارگیری", "Loading In Progress", "Transport Supervisor", ""),
    ("Loading In Progress", "تکمیل بارگیری", "Pending Finance Close", "Transport Supervisor", ""),
    ("Pending Finance Close", "بستن پرونده", "Completed", "Finance Supervisor", ""),
    ("Pending Finance Close", "بستن توسط مدیر مالی", "Completed", "Financial Manager", ""),

    ("Returned", "بازگشت به پیش‌نویس", "Draft", "Finance User", ""),
    ("On Hold", "از سرگیری", "Draft", "Finance Supervisor", ""),
]


def _exception_transitions():
    """رد / تعلیق / لغو از «همه» مراحل میانی — نه فقط از Draft."""
    out = []
    for st in MID_STATES:
        out.append((st, "رد پرونده", "Rejected", "Finance Supervisor", ""))
        out.append((st, "تعلیق پرونده", "On Hold", "Finance Supervisor", ""))
        out.append((st, "لغو پرونده", "Cancelled", "Finance Supervisor", ""))
    return out


def _ensure_workflow_state(name, style=""):
    """Workflow State باید قبل از لینک شدن در Workflow وجود داشته باشد."""
    if frappe.db.exists("Workflow State", name):
        return
    doc = frappe.new_doc("Workflow State")
    doc.workflow_state_name = name
    if style:
        doc.style = style
    doc.flags.ignore_permissions = True
    doc.insert(ignore_permissions=True)


def _ensure_workflow_action(name):
    """
    action در Workflow Transition یک Link به Workflow Action Master است.
    بدون این رکوردها: LinkValidationError: Could not find Action: ...
    """
    if frappe.db.exists("Workflow Action Master", name):
        return
    doc = frappe.new_doc("Workflow Action Master")
    doc.workflow_action_name = name
    doc.flags.ignore_permissions = True
    doc.insert(ignore_permissions=True)


def install():
    all_transitions = TRANSITIONS + _exception_transitions()

    # ۱) وضعیت‌ها
    for state, _ds, _role in STATES:
        _ensure_workflow_state(state, STATE_STYLES.get(state, ""))
    for state in MID_STATES:
        _ensure_workflow_state(state, STATE_STYLES.get(state, ""))
    for _s, _a, nxt, _r, _c in all_transitions:
        _ensure_workflow_state(nxt, STATE_STYLES.get(nxt, ""))

    # ۲) اکشن‌ها (Link اجباری Frappe v15)
    for _s, action, _n, _r, _c in all_transitions:
        _ensure_workflow_action(action)

    frappe.db.commit()

    if frappe.db.exists("Workflow", WORKFLOW_NAME):
        wf = frappe.get_doc("Workflow", WORKFLOW_NAME)
    else:
        wf = frappe.new_doc("Workflow")
        wf.name = WORKFLOW_NAME
        wf.workflow_name = WORKFLOW_NAME

    wf.document_type = "Trade Case"
    wf.workflow_state_field = "workflow_state"
    wf.is_active = 1
    wf.send_email_alert = 0
    wf.override_status = 0

    wf.set("states", [])
    for state, docstatus, role in STATES:
        if not frappe.db.exists("Role", role):
            continue
        wf.append("states", {
            "state": state, "doc_status": docstatus, "allow_edit": role,
        })

    wf.set("transitions", [])
    for state, action, nxt, role, cond in all_transitions:
        if not frappe.db.exists("Role", role):
            continue
        wf.append("transitions", {
            "state": state, "action": action, "next_state": nxt,
            "allowed": role, "allow_self_approval": 1,
            "condition": cond or None,
        })

    wf.flags.ignore_permissions = True
    wf.save(ignore_permissions=True)
    frappe.db.commit()
    return {"states": len(wf.states), "transitions": len(wf.transitions)}
EOF

# =============================================================================
step "3) گاردهای گردش‌کار (امضا، چک‌لیست‌ها، دلایل اجباری) + پیامک بازگشت"
write_utf8 "${MOD}/workflow/guards.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
گاردهای گردش‌کار پرونده بازرگانی.

★ اصلاح باگ ریشه‌ای «گارد امضای وارونه»:
   در Frappe ابتدا وضعیت جدید ست می‌شود سپس validate اجرا می‌شود.
   نسخه قبل، «Pending Signature» را جزو وضعیت‌های نیازمند سند گذاشته بود؛
   یعنی ورود به مرحله امضا بدون سند غیرممکن می‌شد — دقیقاً وارونه.
   قاعده درست: ورود آزاد، خروج مسدود.
"""
import frappe
from frappe import _

STATE_SIGNATURE = "Pending Signature"
# خروج از مرحله امضا فقط به این وضعیت‌ها ممکن است و سند امضاشده لازم دارد
STATES_AFTER_SIGNATURE = ("Finance Supervisor Approval", "Receivables", "Approved",
                          "Loading In Progress", "Pending Finance Close", "Completed")

LEGAL_CHECKS = [
    ("chk_legal_purchase_contract", "بررسی قرارداد خرید"),
    ("chk_legal_sales_contract", "بررسی قرارداد فروش"),
    ("chk_legal_obligations", "بررسی تعهدات طرفین"),
    ("chk_legal_requirements", "بررسی الزامات قانونی"),
    ("chk_legal_documents", "کنترل اسناد"),
]
SUPERVISOR_CHECKS = [
    ("chk_sup_purchase", "کنترل خرید"),
    ("chk_sup_sales", "کنترل فروش"),
    ("chk_sup_prices", "کنترل قیمت‌ها"),
    ("chk_sup_documents", "کنترل اسناد"),
    ("chk_sup_signatures", "کنترل امضاها"),
    ("chk_sup_costs", "کنترل هزینه‌ها"),
]


def _previous_state(doc):
    if not doc.name or doc.is_new():
        return None
    return frappe.db.get_value("Trade Case", doc.name, "workflow_state")


def on_validate(doc, method=None):
    """تنها نقطه اعمال گاردهای گذار — بدون هیچ هوک موازی."""
    new_state = doc.workflow_state
    old_state = _previous_state(doc)
    if new_state == old_state:
        return

    _guard_signature_exit(doc, old_state, new_state)
    _guard_legal_checklist(doc, old_state, new_state)
    _guard_supervisor_checklist(doc, old_state, new_state)
    _guard_reasons(doc, new_state)
    _remember_hold_state(doc, old_state, new_state)

    doc.flags.ite_state_change = (old_state, new_state)


def _guard_signature_exit(doc, old_state, new_state):
    """ورود به مرحله امضا آزاد است؛ خروج بدون سند امضاشده ممنوع."""
    if old_state == STATE_SIGNATURE and new_state in STATES_AFTER_SIGNATURE:
        if not doc.signed_document:
            frappe.throw(_(
                "تا زمانی که «سند امضاشده» بارگذاری نشود، گردش‌کار از مرحله امضا "
                "جلوتر نمی‌رود. برگه سپیدار باید پس از امضای مدیرعامل بارگذاری شود."
            ))


def _guard_legal_checklist(doc, old_state, new_state):
    if old_state == "Legal Review" and new_state == "Treasury Review":
        missing = [label for f, label in LEGAL_CHECKS if not doc.get(f)]
        if missing:
            frappe.throw(_("تایید حقوقی ممکن نیست؛ موارد زیر تیک نخورده‌اند: ") + "، ".join(missing))


def _guard_supervisor_checklist(doc, old_state, new_state):
    if old_state == "Finance Supervisor Approval" and new_state == "Receivables":
        missing = [label for f, label in SUPERVISOR_CHECKS if not doc.get(f)]
        if missing:
            frappe.throw(_("تایید سرپرست مالی ممکن نیست؛ موارد زیر تیک نخورده‌اند: ") + "، ".join(missing))


def _guard_reasons(doc, new_state):
    if new_state == "Rejected" and not (doc.rejection_reason or "").strip():
        frappe.throw(_("ثبت «دلیل رد» الزامی است."))
    if new_state == "On Hold" and not (doc.hold_reason or "").strip():
        frappe.throw(_("ثبت «دلیل تعلیق» الزامی است."))
    if new_state == "Cancelled" and not (doc.cancel_reason or "").strip():
        frappe.throw(_("ثبت «علت لغو» الزامی است."))


def _remember_hold_state(doc, old_state, new_state):
    """تعلیق باید به وضعیت قبلی بازگردد، نه همیشه به Draft."""
    if new_state == "On Hold" and old_state:
        doc.hold_previous_state = old_state


def on_update(doc, method=None):
    """اعلان‌ها پس از ذخیره — هرگز سند مرجع را دوباره save نمی‌کنند."""
    change = doc.flags.get("ite_state_change")
    if not change:
        return
    old_state, new_state = change
    from iran_trade_erp.iran_trade.notification.core import notify

    if new_state == "Pending Signature":
        notify("trade_case.ready_for_signature", doc.doctype, doc.name, {})
    elif old_state == "Pending Signature" and new_state == "Finance Supervisor Approval":
        notify("trade_case.document_signed", doc.doctype, doc.name, {})
        # ★ دقیقاً پیش از رسیدن پرونده به میز نهال‌پرور:
        #    پیامک صرفاً اطلاع‌رسانی برای همان مدیرعامل دستوردهنده
        notify("trade_case.back_to_finance_supervisor", doc.doctype, doc.name,
               {"outcome": "تأیید شد", "reason": "سند امضا و بارگذاری شد"})
    elif new_state == "Returned":
        reason = doc.rejection_reason or doc.legal_notes or doc.treasury_notes or "-"
        event = "trade_case.legal_rejected" if old_state == "Legal Review" else "trade_case.treasury_rejected"
        notify(event, doc.doctype, doc.name, {"reason": reason})
        notify("trade_case.back_to_finance_supervisor", doc.doctype, doc.name,
               {"outcome": "بازگشت داده شد", "reason": reason})
    elif new_state == "Waiting Supply":
        notify("trade_case.waiting_supply", doc.doctype, doc.name,
               {"reason": doc.hold_reason or ""})
    elif new_state == "Approved":
        notify("trade_case.final_approved", doc.doctype, doc.name, {})
    elif new_state == "Completed":
        notify("trade_case.completed", doc.doctype, doc.name, {})
    elif new_state == "Rejected":
        notify("trade_case.back_to_finance_supervisor", doc.doctype, doc.name,
               {"outcome": "رد شد", "reason": doc.rejection_reason or "-"})


@frappe.whitelist()
def upload_signed_document(name, file_url):
    """
    بارگذاری سند امضاشده — مجاز برای امضاکننده سند و سرپرست مالی،
    فقط در همین مرحله (به سرپرست مالی در این وضعیت خاص دسترسی نوشتن داده شده).
    """
    roles = set(frappe.get_roles())
    if not roles.intersection({"Document Signer", "Finance Supervisor", "CEO", "System Manager"}):
        frappe.throw(_("فقط امضاکننده سند یا سرپرست مالی می‌تواند سند امضاشده را بارگذاری کند."))
    if not file_url:
        frappe.throw(_("فایل سند امضاشده انتخاب نشده است."))
    doc = frappe.get_doc("Trade Case", name)
    if doc.workflow_state != STATE_SIGNATURE:
        frappe.throw(_("بارگذاری سند امضاشده فقط در مرحله «منتظر امضا» مجاز است."))
    doc.signed_document = file_url
    doc.document_type = "سند امضاشده"
    doc.save()
    frappe.db.commit()
    return {"ok": True}
EOF

# =============================================================================
step "4) ثبت hooks (SCRIPT06) — ادغام با حفظ هوک‌های قبلی"
python3 - "$PKG" << 'PYEOF'
import io, os, re, sys
pkg = sys.argv[1]
p = os.path.join(pkg, "hooks.py")
src = io.open(p, encoding="utf-8").read()
if "# --- SCRIPT05_HOOKS_START ---" not in src:
    raise SystemExit("ABORT: anchor SCRIPT05 missing")
S, E = "# --- SCRIPT06_HOOKS_START ---", "# --- SCRIPT06_HOOKS_END ---"
src = re.sub(re.escape(S) + r".*?" + re.escape(E), "", src, flags=re.S)
block = S + '''
_ite_ev = globals().get("doc_events", {}) or {}
_ite_ev.setdefault("Trade Case", {})
for _evt, _fn in (
    ("validate", "iran_trade_erp.iran_trade.workflow.guards.on_validate"),
    ("on_update", "iran_trade_erp.iran_trade.workflow.guards.on_update"),
):
    _cur = _ite_ev["Trade Case"].get(_evt)
    if _cur is None:
        _ite_ev["Trade Case"][_evt] = _fn
    elif isinstance(_cur, list):
        if _fn not in _cur:
            _cur.append(_fn)
    elif _cur != _fn:
        _ite_ev["Trade Case"][_evt] = [_cur, _fn]
doc_events = _ite_ev

fixtures = (globals().get("fixtures", []) or []) + [
    {"dt": "Workflow State", "filters": [["name", "in", [
        "Draft", "Waiting Supply", "Legal Review", "Treasury Review", "Pending Signature",
        "Finance Supervisor Approval", "Receivables", "Approved", "Loading In Progress",
        "Pending Finance Close", "Completed", "Returned", "On Hold", "Rejected", "Cancelled"]]]},
]
''' + E + "\n"
io.open(p, "w", encoding="utf-8").write(src.rstrip() + "\n\n" + block)

t = os.path.join(pkg, "translations", "fa.csv")
rows = [
 "Factory Shortfall Ledger,دفتر بدهی کارخانه,",
 "Trade Case Workflow,گردش‌کار پرونده بازرگانی,",
 "Draft,پیش‌نویس,", "Waiting Supply,در انتظار تأمین کالا,",
 "Legal Review,بررسی حقوقی,", "Treasury Review,بررسی خزانه,",
 "Pending Signature,منتظر امضا,", "Finance Supervisor Approval,تایید سرپرست مالی,",
 "Receivables,وصول مطالبات,", "Approved,تاییدشده,",
 "Loading In Progress,در حال بارگیری,", "Pending Finance Close,در انتظار بستن مالی,",
 "Completed,تکمیل‌شده,", "Returned,بازگشت‌داده‌شده,", "On Hold,معلق,",
 "Rejected,ردشده,", "Cancelled,لغوشده,",
]
cur = io.open(t, encoding="utf-8").read() if os.path.exists(t) else ""
have = set(l.split(",")[0] for l in cur.splitlines() if l.strip())
add = [r for r in rows if r.split(",")[0] not in have]
if add:
    io.open(t, "a", encoding="utf-8").write("\n".join(add) + "\n")
print("SCRIPT06 hooks + fa.csv ok")
PYEOF

# اطمینان از وجود __init__.py برای پکیج workflow
: > "${MOD}/workflow/__init__.py"

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" execute iran_trade_erp.iran_trade.workflow.install_workflow.install
bench --site "$SITE_NAME" clear-cache

# =============================================================================
step "5) Verify داخلی — گردش‌کار واقعی، نه ادعا"
write_utf8 "${PKG}/verify_script06.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
from frappe.model.workflow import apply_workflow
from frappe.utils import flt, nowdate


def _ceo():
    r = frappe.get_all("Has Role", filters={"role": "CEO", "parenttype": "User"}, pluck="parent")
    return [x for x in r if x not in ("Administrator", "Guest")][0]


def _item():
    n = "TEST-STEEL-COIL"
    if not frappe.db.exists("Item", n):
        it = frappe.new_doc("Item"); it.item_code = n; it.item_name = "ورق فولادی آزمایشی"
        it.item_group = frappe.db.get_value("Item Group", {"is_group": 0}, "name") or "All Item Groups"
        it.stock_uom = "Kg"; it.is_stock_item = 0
        it.flags.ignore_permissions = True; it.insert(ignore_permissions=True)
    return n


def _ensure_supplier_group():
    """Supplier Group برگ — بدون فرض «All Supplier Groups» (همان الگوی Item Group)."""
    leaf = frappe.db.get_value("Supplier Group", {"is_group": 0}, "name")
    if leaf:
        return leaf
    any_g = frappe.db.get_value("Supplier Group", {}, "name")
    if any_g:
        return any_g
    root_name = "All Supplier Groups"
    if not frappe.db.exists("Supplier Group", root_name):
        root = frappe.get_doc({
            "doctype": "Supplier Group",
            "supplier_group_name": root_name,
            "is_group": 1,
        })
        root.flags.ignore_permissions = True
        root.flags.ignore_mandatory = True
        try:
            root.insert(ignore_permissions=True)
        except Exception:
            pass
        frappe.db.commit()
    child_name = "Local"
    if not frappe.db.exists("Supplier Group", child_name):
        child = frappe.get_doc({
            "doctype": "Supplier Group",
            "supplier_group_name": child_name,
            "is_group": 0,
            "parent_supplier_group": root_name if frappe.db.exists("Supplier Group", root_name) else None,
        })
        child.flags.ignore_permissions = True
        child.flags.ignore_mandatory = True
        child.insert(ignore_permissions=True)
        frappe.db.commit()
        return child_name
    return frappe.db.get_value("Supplier Group", {}, "name")


def _supplier():
    n = "کارخانه آزمایشی فولاد"
    if frappe.db.exists("Supplier", n):
        return n
    group = _ensure_supplier_group()
    s = frappe.new_doc("Supplier")
    s.supplier_name = n
    s.supplier_group = group
    s.flags.ignore_permissions = True
    s.flags.ignore_mandatory = True
    s.insert(ignore_permissions=True)
    frappe.db.commit()
    return n


def _new_case(title="پرونده گردش‌کار آزمایشی"):
    c = frappe.new_doc("Trade Case")
    c.case_title = title; c.case_type = "خرید"; c.requested_by = _ceo()
    c.company = frappe.db.get_value("Company", {}, "name"); c.posting_date = nowdate()
    c.supplier_factory = _supplier()
    c.append("items", {"row_kind": "خرید", "item": _item(), "tonnage": 100,
                       "price": 10000000, "transaction_currency": "IRR"})
    c.flags.ignore_permissions = True
    c.insert(ignore_permissions=True)
    return c


def run():
    passed = failed = 0

    def chk(t, c):
        nonlocal passed, failed
        if c:
            passed += 1; print("  [PASS] " + t)
        else:
            failed += 1; print("  [FAIL] " + t)

    frappe.set_user("Administrator")

    chk("گردش‌کار یکپارچه ساخته شد", frappe.db.exists("Workflow", "Trade Case Workflow") is not None)
    wf = frappe.get_doc("Workflow", "Trade Case Workflow")
    chk("گردش‌کار فعال است", wf.is_active == 1)

    states = {s.state for s in wf.states}
    chk("وضعیت رسمی «Waiting Supply» وجود دارد", "Waiting Supply" in states)

    tr = [(t.state, t.next_state) for t in wf.transitions]
    chk("Rejected از مراحل میانی قابل دسترسی است",
        len([1 for s, n in tr if n == "Rejected"]) >= 8)
    chk("لغو از مراحل میانی ممکن است",
        len([1 for s, n in tr if n == "Cancelled"]) >= 8)
    chk("تعلیق از مراحل میانی ممکن است",
        len([1 for s, n in tr if n == "On Hold"]) >= 8)
    chk("هر ردیف allow_edit فقط یک نقش دارد (قاعده Frappe v15)",
        all("\n" not in (s.allow_edit or "") for s in wf.states))

    # --- گارد امضا: ورود آزاد، خروج مسدود ---
    c = _new_case()
    apply_workflow(c, "ارسال به حقوقی")
    c.reload()
    for f, _l in [("chk_legal_purchase_contract", 1), ("chk_legal_sales_contract", 1),
                  ("chk_legal_obligations", 1), ("chk_legal_requirements", 1),
                  ("chk_legal_documents", 1)]:
        c.set(f, 1)
    c.save(ignore_permissions=True)
    apply_workflow(c, "تایید حقوقی")
    c.reload()
    entered = False
    try:
        apply_workflow(c, "تایید خزانه")   # ورود به Pending Signature بدون سند
        c.reload()
        entered = (c.workflow_state == "Pending Signature")
    except Exception as e:
        print("      ورود مسدود شد:", str(e)[:80])
    chk("ورود به مرحله امضا بدون سند آزاد است (رفع گارد وارونه)", entered)

    blocked = False
    try:
        apply_workflow(c, "امضا شد")
    except Exception:
        blocked = True
    chk("خروج از مرحله امضا بدون سند امضاشده مسدود است", blocked)

    c.reload()
    c.signed_document = "/files/test-signed.pdf"
    c.save(ignore_permissions=True)
    apply_workflow(c, "امضا شد")
    c.reload()
    chk("پس از بارگذاری سند، خروج از مرحله امضا ممکن است",
        c.workflow_state == "Finance Supervisor Approval")

    # پیامک بازگشت به سرپرست مالی برای مدیرعامل دستوردهنده
    sent = frappe.db.count("Notification Dispatch Log",
                           {"event_key": "trade_case.back_to_finance_supervisor",
                            "reference_name": c.name})
    chk("★ اعلان «بازگشت به سرپرست مالی» برای مدیرعامل دستوردهنده ارسال شد", sent >= 1)

    # چک‌لیست سرپرست مالی
    blocked = False
    try:
        apply_workflow(c, "تایید سرپرست")
    except Exception:
        blocked = True
    chk("تایید سرپرست بدون چک‌لیست کامل مسدود است", blocked)

    c.reload()
    for f in ("chk_sup_purchase", "chk_sup_sales", "chk_sup_prices",
              "chk_sup_documents", "chk_sup_signatures", "chk_sup_costs"):
        c.set(f, 1)
    c.save(ignore_permissions=True)
    apply_workflow(c, "تایید سرپرست")
    c.reload()
    chk("با چک‌لیست کامل، تایید سرپرست انجام شد", c.workflow_state == "Receivables")

    apply_workflow(c, "تایید وصول")
    c.reload()
    chk("پرونده به «تاییدشده» رسید", c.workflow_state == "Approved")

    # دلیل اجباری تعلیق + بازگشت به وضعیت قبلی
    blocked = False
    try:
        apply_workflow(c, "تعلیق پرونده")
    except Exception:
        blocked = True
    chk("تعلیق بدون دلیل مسدود است (سناریوی منفی)", blocked)
    c.reload(); c.hold_reason = "در انتظار هماهنگی کارخانه"
    c.save(ignore_permissions=True)
    apply_workflow(c, "تعلیق پرونده")
    c.reload()
    chk("وضعیت پیش از تعلیق ذخیره شد", c.hold_previous_state == "Approved")

    # --- دفتر بدهی کارخانه ---
    from iran_trade_erp.iran_trade.doctype.factory_shortfall_ledger.factory_shortfall_ledger import (
        settle_shortfall, factory_debt_summary,
    )
    from iran_trade_erp.iran_trade.doctype.trade_case.trade_case import manual_close

    c2 = _new_case("پرونده کسری کارخانه")
    c2.items[0].shipped_tonnage = 96
    c2.flags.ignore_permissions = True
    c2.save(ignore_permissions=True)
    res = manual_close(c2.name, "باسکول ۹۶ تن از ۱۰۰ تن — کسری تحویل کارخانه")
    chk("سناریوی ۱۰۰ تن / ۴ تریلی ۲۴ تنی: کسری ۴ تن محاسبه شد",
        abs(flt(res["snapshot"][0]["remaining"]) - 4.0) < 0.001)

    led = frappe.get_all("Factory Shortfall Ledger", filters={"trade_case": c2.name},
                         fields=["name", "shortfall_tonnage", "ledger_status"])
    chk("کسری در دفتر بدهی کارخانه ثبت شد", len(led) == 1 and flt(led[0].shortfall_tonnage) == 4.0)
    chk("وضعیت اولیه دفتر «باز» است", led[0].ledger_status == "باز")

    summary = factory_debt_summary()
    chk("گزارش تجمیعی بدهکاری کارخانه‌ها کار می‌کند", any(flt(r["open_tonnage"]) >= 4 for r in summary))

    settle_shortfall(led[0].name, notes="در معامله بعدی جبران شد")
    chk("کسری قابل تسویه بعدی است",
        frappe.db.get_value("Factory Shortfall Ledger", led[0].name, "ledger_status") == "تسویه‌شده")

    print("\n  Passed: %d | Failed: %d" % (passed, failed))
    if failed:
        raise Exception("verify_script06 FAILED: %d" % failed)
    return "OK"
EOF

bench --site "$SITE_NAME" execute iran_trade_erp.verify_script06.run

cat <<FINAL

============================================================
 script-06.sh با موفقیت تمام شد
------------------------------------------------------------
 گردش‌کار    : یکپارچه، با استثنا از همه مراحل میانی
 گارد امضا  : ورود آزاد | خروج مسدود  (باگ وارونگی رفع شد)
 چک‌لیست‌ها  : حقوقی ۵ قلم | سرپرست مالی ۶ قلم — گارد واقعی
 پیامک ★    : بازگشت به سرپرست مالی → مدیرعامل دستوردهنده
 دفتر بدهی  : ثبت کسری + تسویه بعدی + گزارش تجمیعی
 گام بعدی   : bash script-07.sh
============================================================
FINAL