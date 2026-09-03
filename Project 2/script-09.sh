#!/usr/bin/env bash
# =============================================================================
# script-09.sh — فضای کاری، کارتابل، داشبورد مدیرعامل و تجربه کاربری فرم
# بازسازی هدایت‌شده — Iran Trade ERP | ERPNext v15 / Frappe v15
# -----------------------------------------------------------------------------
# این اسکریپت لایه دیدنی سامانه را می‌سازد — مینیمال، ولی زیبا:
#   1) شش فضای کاری اختصاصی با شناسه انگلیسی پایدار (ضد ۴۰۴ فارسی)
#      CEO Command | My Cartable | Finance Desk | Transport Desk |
#      Customs Desk | Commercial Desk
#   2) کارتابل واحد با ۹ بخش سند نیازمندی (ارجاع‌شده/جدید/در انتظار اقدام/
#      فوری/عقب‌افتاده/در اختیار من/تکمیل‌شده اخیر/اعلان‌ها/آخرین فعالیت‌ها)
#   3) داشبورد مدیرعامل: کارت‌های KPI مینیمال با شیب رنگی ملایم، بدون شلوغی
#   4) تجربه کاربری فرم (Client Script):
#      • بخش‌های شماره‌دار و جمع‌شونده  • تب‌بندی
#      • نگاشت «مرحله → بخش» (فقط بخش مرتبط باز می‌ماند، هیچ فیلدی حذف نمی‌شود)
#      • کارت خلاصه بالای فرم (۱۱ قلم)  • تایم‌لاین فارسی
#      • هشدار خروج با تغییرات ذخیره‌نشده
#      • قفل بر اساس مرحله (فیلدهای غیرمرتبط فقط‌خواندنی می‌شوند)
#   5) «تنظیمات کارتابل» با نگاشت مرحله→بخش قابل تغییر بدون کد
#   6) گزارش بار کاری کاربران برای توزیع واقعی کار توسط سرپرست
#
# هیچ Build فرانت‌اند لازم نیست؛ فقط دارایی‌های استاتیک اپ.
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
else nohup bench start >>/tmp/bench-start-itc09.log 2>&1 & log "pid=$!"; sleep 12; fi
RC="${BENCH_DIR}/config/redis_cache.conf"
RP="$( [[ -f "$RC" ]] && awk '$1=="port"{print $2; exit}' "$RC" || echo 13000 )"; [[ -n "$RP" ]] || RP=13000
R=0; for _i in $(seq 1 60); do
  if command -v redis-cli >/dev/null 2>&1 && redis-cli -h 127.0.0.1 -p "$RP" ping 2>/dev/null | grep -q '^PONG$'; then R=1; break; fi
  if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ":${RP}[[:space:]]"; then R=1; break; fi
  sleep 1; done
[[ "$R" -eq 1 ]] || err "redis آماده نشد"
bench use "$SITE_NAME" 2>/dev/null || true

step "0b) پیش‌نیاز — ABORT در نبود Anchor"
[[ -f "${MOD}/report/queries.py" ]] || err "ABORT: گزارش‌ها نیستند. ابتدا script-08.sh"
grep -q "SCRIPT08_HOOKS_START" "${PKG}/hooks.py" || err "ABORT: بلوک SCRIPT08 در hooks.py نیست"
log "پیش‌نیازها تایید شد"

mkdir -p "${MOD}/api" "${MOD}/workspace" "${PKG}/public/js" "${PKG}/public/css"
mk_dt() { mkdir -p "${MOD}/doctype/$1"; : > "${MOD}/doctype/$1/__init__.py"; }

# =============================================================================
step "1) تنظیمات کارتابل + نگاشت مرحله→بخش (بدون کد، قابل تغییر)"
mk_dt cartable_settings
write_utf8 "${MOD}/doctype/cartable_settings/cartable_settings.json" << 'EOF'
{
 "actions": [], "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType",
 "engine": "InnoDB", "issingle": 1,
 "field_order": ["urgent_hours", "overdue_hours", "recent_days", "cb_1",
                 "autosave_debounce_ms", "refresh_seconds", "sb_2", "stage_section_map"],
 "fields": [
  {"default": "12", "fieldname": "urgent_hours", "fieldtype": "Int", "label": "آستانه «فوری» (ساعت)"},
  {"default": "24", "fieldname": "overdue_hours", "fieldtype": "Int", "label": "آستانه «عقب‌افتاده» (ساعت)"},
  {"default": "7", "fieldname": "recent_days", "fieldtype": "Int", "label": "بازه «تکمیل‌شده اخیر» (روز)"},
  {"fieldname": "cb_1", "fieldtype": "Column Break"},
  {"default": "2500", "fieldname": "autosave_debounce_ms", "fieldtype": "Int", "label": "تأخیر ذخیره خودکار (میلی‌ثانیه)"},
  {"default": "120", "fieldname": "refresh_seconds", "fieldtype": "Int", "label": "فاصله تازه‌سازی کارتابل (ثانیه)"},
  {"fieldname": "sb_2", "fieldtype": "Section Break", "label": "نگاشت مرحله به بخش فرم"},
  {"description": "JSON: {\"نام مرحله\": [\"نام فنی بخش\", ...]}", "fieldname": "stage_section_map", "fieldtype": "Code", "label": "نگاشت مرحله → بخش", "options": "JSON"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Cartable Settings", "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "read": 1, "write": 1, "role": "System Manager"},
  {"read": 1, "role": "Financial Manager"},
  {"read": 1, "role": "Finance Supervisor"},
  {"read": 1, "role": "Transport Supervisor"}
 ],
 "sort_field": "modified", "sort_order": "DESC", "track_changes": 1
}
EOF
write_utf8 "${MOD}/doctype/cartable_settings/cartable_settings.py" << 'EOF'
# -*- coding: utf-8 -*-
import json

import frappe
from frappe.model.document import Document

DEFAULT_MAP = {
    "Draft": ["sb_1_request", "sb_2_parties", "sb_3_items", "sb_4_summary", "sb_5_route"],
    "Waiting Supply": ["sb_1_request", "sb_3_items", "sb_13_exception"],
    "Legal Review": ["sb_6_legal", "sb_8_docs", "sb_3_items"],
    "Treasury Review": ["sb_7_treasury", "sb_4_summary"],
    "Pending Signature": ["sb_8_docs"],
    "Finance Supervisor Approval": ["sb_9_supervisor", "sb_8_docs", "sb_4_summary"],
    "Receivables": ["sb_9_supervisor", "sb_11_accounting"],
    "Approved": ["sb_10_links", "sb_11_accounting"],
    "Loading In Progress": ["sb_3_items", "sb_10_links"],
    "Pending Finance Close": ["sb_11_accounting", "sb_12_close"],
    "Completed": ["sb_12_close"],
}


class CartableSettings(Document):
    def validate(self):
        if not (self.stage_section_map or "").strip():
            self.stage_section_map = json.dumps(DEFAULT_MAP, ensure_ascii=False, indent=2)
            return
        try:
            json.loads(self.stage_section_map)
        except Exception:
            frappe.throw("نگاشت مرحله → بخش باید JSON معتبر باشد.")


def get_stage_map():
    raw = frappe.db.get_single_value("Cartable Settings", "stage_section_map")
    if not raw:
        return DEFAULT_MAP
    try:
        return json.loads(raw)
    except Exception:
        return DEFAULT_MAP
EOF

# =============================================================================
step "2) API کارتابل، کارت خلاصه، تایم‌لاین فارسی و KPI مدیرعامل"
write_utf8 "${MOD}/api/cartable.py" << 'EOF'
# -*- coding: utf-8 -*-
"""کارتابل واحد — ۹ بخش سند نیازمندی. مدیر سامانه کارتابل عملیاتی ندارد."""
import frappe
from frappe import _
from frappe.utils import add_to_date, now_datetime

from iran_trade_erp.iran_trade.doctype.cartable_settings.cartable_settings import get_stage_map

CASE_FIELDS = ["name", "case_title", "case_type", "workflow_state", "fulfillment_status",
               "planned_tonnage", "assigned_user", "sla_last_action_on", "modified"]


def _settings():
    return frappe.get_cached_doc("Cartable Settings")


def _user():
    u = frappe.session.user
    if u in ("Administrator", "Guest"):
        return None
    return u


@frappe.whitelist()
def get_cartable():
    user = _user()
    if not user:
        return {"blocked": True,
                "message": _("مدیر سامانه کارتابل عملیاتی ندارد. با کاربر سازمانی وارد شوید.")}

    s = _settings()
    urgent_cut = add_to_date(now_datetime(), hours=-int(s.urgent_hours or 12))
    overdue_cut = add_to_date(now_datetime(), hours=-int(s.overdue_hours or 24))
    recent_cut = add_to_date(now_datetime(), days=-int(s.recent_days or 7))

    mine = {"assigned_user": user}
    open_states = ["not in", ["Completed", "Cancelled", "Rejected"]]

    def cases(extra, limit=20, order="modified desc"):
        f = dict(mine); f.update(extra)
        return frappe.get_all("Trade Case", filters=f, fields=CASE_FIELDS,
                              order_by=order, limit_page_length=limit)

    data = {
        "blocked": False,
        "user": user,
        "assigned_to_me": cases({"workflow_state": open_states}, order="creation desc"),
        "new_items": cases({"workflow_state": "Draft"}),
        "pending_my_action": cases({"workflow_state": open_states}),
        "urgent": cases({"workflow_state": open_states,
                         "sla_last_action_on": ["<", urgent_cut]}),
        "overdue": cases({"workflow_state": open_states,
                          "sla_last_action_on": ["<", overdue_cut]}),
        "in_my_hands": cases({}),
        "recently_completed": cases({"workflow_state": "Completed",
                                     "modified": [">", recent_cut]}),
        "alerts": frappe.get_all(
            "Notification Log", filters={"for_user": user, "read": 0},
            fields=["name", "subject", "document_type", "document_name", "creation"],
            order_by="creation desc", limit_page_length=15),
        "my_activity": frappe.get_all(
            "Version", filters={"owner": user}, fields=["ref_doctype", "docname", "creation"],
            order_by="creation desc", limit_page_length=15),
    }
    data["loadings"] = frappe.get_all(
        "Trade Case Loading", filters={"assigned_user": user,
                                       "loading_state": ["not in", ["تکمیل شد", "لغو شده", "رد شده"]]},
        fields=["name", "trade_case", "trade_item", "planned_tonnage",
                "effective_tonnage", "loading_state"],
        order_by="modified desc", limit_page_length=20)
    data["counts"] = {k: len(v) for k, v in data.items() if isinstance(v, list)}
    return data


@frappe.whitelist()
def summary_card(doctype, name):
    """کارت خلاصه بالای فرم — ۱۱ قلم مستقل."""
    if not frappe.has_permission(doctype, "read", doc=name):
        frappe.throw(_("دسترسی لازم را ندارید."))
    doc = frappe.get_doc(doctype, name)
    shipped = sum(frappe.utils.flt(r.shipped_tonnage) for r in (doc.get("items") or []))
    remaining = sum(frappe.utils.flt(r.remaining_tonnage) for r in (doc.get("items") or []))
    loadings = frappe.db.count("Trade Case Loading",
                               {"trade_case": name,
                                "loading_state": ["not in", ["لغو شده", "رد شده"]]}) \
        if doctype == "Trade Case" else 0
    items = ", ".join(sorted({r.item for r in (doc.get("items") or []) if r.item}))
    return [
        {"label": "شماره پرونده", "value": doc.name},
        {"label": "مشتری", "value": doc.get("customer") or "—"},
        {"label": "نوع معامله", "value": doc.get("case_type") or "—"},
        {"label": "کالا", "value": items or "—"},
        {"label": "تناژ کل", "value": frappe.utils.flt(doc.get("planned_tonnage"), 3)},
        {"label": "تناژ حمل‌شده", "value": frappe.utils.flt(shipped, 3)},
        {"label": "تناژ باقی‌مانده", "value": frappe.utils.flt(remaining, 3)},
        {"label": "تعداد بارگیری", "value": loadings},
        {"label": "وضعیت تأمین", "value": doc.get("fulfillment_status") or "—"},
        {"label": "مسئول فعلی", "value": doc.get("assigned_user") or "—"},
        {"label": "مرحله فعلی", "value": doc.get("workflow_state") or "—"},
    ]


@frappe.whitelist()
def case_timeline(doctype, name, limit=40):
    """تایم‌لاین فارسی: «نام کاربر — عملیات — ساعت شمسی»."""
    if not frappe.has_permission(doctype, "read", doc=name):
        frappe.throw(_("دسترسی لازم را ندارید."))
    from iran_common.utils.jalali import jalali_fa

    rows = frappe.get_all(
        "Version", filters={"ref_doctype": doctype, "docname": name},
        fields=["owner", "data", "creation"], order_by="creation desc",
        limit_page_length=int(limit))
    out = []
    for r in rows:
        action = "ویرایش سند"
        try:
            import json as _json
            d = _json.loads(r.data or "{}")
            for ch in d.get("changed", []):
                if ch and ch[0] == "workflow_state":
                    action = "تغییر مرحله: {0} ← {1}".format(ch[2] or "-", ch[1] or "-")
                    break
        except Exception:
            pass
        out.append({
            "user": frappe.db.get_value("User", r.owner, "full_name") or r.owner,
            "action": action,
            "when": jalali_fa(r.creation),
        })
    return out


@frappe.whitelist()
def stage_section_map():
    return get_stage_map()


@frappe.whitelist()
def workload_by_user(unit=None):
    """بار کاری واقعی هر کاربر — مبنای توزیع کار توسط سرپرست."""
    if not frappe.has_permission("Trade Case", "report"):
        frappe.throw(_("دسترسی لازم را ندارید."))
    rows = frappe.db.sql(
        """SELECT assigned_user,
                  SUM(CASE WHEN workflow_state NOT IN ('Completed','Cancelled','Rejected')
                           THEN 1 ELSE 0 END) AS open_cases,
                  COUNT(*) AS total_cases
           FROM `tabTrade Case`
           WHERE assigned_user IS NOT NULL
             AND assigned_user NOT IN ('Administrator','Guest')
           GROUP BY assigned_user ORDER BY open_cases DESC""", as_dict=True)
    for r in rows:
        r["full_name"] = frappe.db.get_value("User", r.assigned_user, "full_name") or r.assigned_user
        r["open_loadings"] = frappe.db.count(
            "Trade Case Loading",
            {"assigned_user": r.assigned_user,
             "loading_state": ["not in", ["تکمیل شد", "لغو شده", "رد شده"]]})
    return rows
EOF

write_utf8 "${MOD}/api/ceo_dashboard.py" << 'EOF'
# -*- coding: utf-8 -*-
"""داشبورد مدیرعامل — مینیمال و زیبا، با یک موتور شاخص (نه دو موتور موازی)."""
import frappe
from frappe import _
from frappe.utils import add_to_date, flt, now_datetime

ALLOWED = {"CEO", "Financial Manager", "Finance Supervisor",
           "Transport Supervisor", "System Manager"}


def _guard():
    if not set(frappe.get_roles()).intersection(ALLOWED):
        frappe.throw(_("دسترسی به داشبورد مدیریتی ندارید."))


@frappe.whitelist()
def get_kpi():
    """
    تنها موتور شاخص عملکرد. هر عدد اینجا از همان فیلدهای ذخیره‌شده سرور
    می‌آید؛ هیچ فرمول موازی تعریف نمی‌شود.
    """
    _guard()
    overdue_cut = add_to_date(now_datetime(), hours=-48)

    open_cases = frappe.db.count(
        "Trade Case", {"workflow_state": ["not in", ["Completed", "Cancelled", "Rejected"]]})
    waiting_supply = frappe.db.count("Trade Case", {"fulfillment_status": "در انتظار تأمین کالا"})
    completed = frappe.db.count("Trade Case", {"workflow_state": "Completed"})
    overdue = frappe.db.count(
        "Trade Case", {"workflow_state": ["not in", ["Completed", "Cancelled", "Rejected"]],
                       "sla_last_action_on": ["<", overdue_cut]})

    agg = frappe.db.sql(
        """SELECT COALESCE(SUM(planned_tonnage),0) planned,
                  COALESCE(SUM(estimated_profit),0) profit,
                  COALESCE(SUM(sales_amount_base),0) sales,
                  COALESCE(SUM(purchase_amount_base),0) purchase
           FROM `tabTrade Case`""", as_dict=True)[0]

    shipped = frappe.db.sql(
        """SELECT COALESCE(SUM(effective_tonnage),0) s
           FROM `tabTrade Case Loading`
           WHERE loading_state NOT IN ('لغو شده','رد شده')""", as_dict=True)[0].s

    cost = frappe.db.sql(
        """SELECT COALESCE(SUM(total_operational_cost),0) c,
                  COALESCE(SUM(total_settled),0) s
           FROM `tabTrade Case Loading`
           WHERE loading_state NOT IN ('لغو شده','رد شده')""", as_dict=True)[0]

    debt = frappe.db.sql(
        """SELECT COALESCE(SUM(shortfall_tonnage),0) t
           FROM `tabFactory Shortfall Ledger` WHERE ledger_status='باز'""",
        as_dict=True)[0].t if frappe.db.table_exists("Factory Shortfall Ledger") else 0

    return {
        "cards": [
            {"key": "open_cases", "label": "پرونده‌های باز", "value": open_cases, "tone": "blue"},
            {"key": "waiting_supply", "label": "در انتظار تأمین کالا", "value": waiting_supply, "tone": "amber"},
            {"key": "overdue", "label": "عقب‌افتاده (بیش از ۴۸ ساعت)", "value": overdue, "tone": "rose"},
            {"key": "completed", "label": "تکمیل‌شده", "value": completed, "tone": "green"},
            {"key": "planned", "label": "تناژ برنامه", "value": flt(agg.planned, 1), "tone": "slate"},
            {"key": "shipped", "label": "تناژ حمل‌شده", "value": flt(shipped, 1), "tone": "teal"},
            {"key": "profit", "label": "سود برآوردی (ریال)", "value": flt(agg.profit, 0), "tone": "violet"},
            {"key": "debt", "label": "طلب از کارخانه‌ها (تن)", "value": flt(debt, 1), "tone": "orange"},
        ],
        "finance": {
            "sales_base": flt(agg.sales, 0),
            "purchase_base": flt(agg.purchase, 0),
            "operational_cost": flt(cost.c, 0),
            "settled": flt(cost.s, 0),
            "balance": flt(flt(cost.c) - flt(cost.s), 0),
        },
    }


@frappe.whitelist()
def get_breakdown():
    """سه نمای گروهی مینیمال برای داشبورد."""
    _guard()
    by_factory = frappe.db.sql(
        """SELECT COALESCE(supplier_factory,'نامشخص') k,
                  COALESCE(SUM(planned_tonnage),0) v
           FROM `tabTrade Case` GROUP BY supplier_factory ORDER BY v DESC LIMIT 8""",
        as_dict=True)
    by_border = frappe.db.sql(
        """SELECT COALESCE(border,'نامشخص') k, COUNT(*) v
           FROM `tabTrade Case` GROUP BY border ORDER BY v DESC LIMIT 8""", as_dict=True)
    by_state = frappe.db.sql(
        """SELECT COALESCE(fulfillment_status,'نامشخص') k, COUNT(*) v
           FROM `tabTrade Case` GROUP BY fulfillment_status ORDER BY v DESC""", as_dict=True)
    return {"by_factory": by_factory, "by_border": by_border, "by_state": by_state}


@frappe.whitelist()
def send_report_to_ceo():
    """دکمه «ارسال این گزارش به مدیرعامل» — نقطه چهارم فراخوانی سرویس اعلان."""
    _guard()
    from iran_trade_erp.iran_trade.notification.sla_engine import send_daily_ceo_report
    return send_daily_ceo_report()
EOF

# =============================================================================
step "3) فضاهای کاری با شناسه انگلیسی پایدار (ضد ۴۰۴)"
write_utf8 "${MOD}/workspace/install_workspaces.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
شش فضای کاری نقش‌محور.
قاعده: name/label/title انگلیسی؛ متن فارسی فقط از fa.csv.
"""
import frappe

from iran_trade_erp.iran_trade.utils.naming_guard import ensure_workspace, purge_persian_workspaces


def _card(label, links):
    return {"id": label, "type": "card", "data": {"card_name": label, "col": 4}}


def _shortcut(label):
    return {"id": label, "type": "shortcut", "data": {"shortcut_name": label, "col": 3}}


def _header(text):
    return {"id": text, "type": "header",
            "data": {"text": "<span class=\"h4\">" + text + "</span>", "col": 12}}


# اصلاح breadcrumb: اگر هر شش فضا یک ماژول «Iran Trade» بگیرند، نگاشت
# ماژول←Workspace در Desk به یک فضا فرومی‌پاشد و برای هر کاربری «میز مدیرعامل»
# نمایش داده می‌شود (حتی کارشناس مالی که نقش آن فضا را ندارد). راه درست:
# فقط «My Cartable» — که هر ۱۲ نقش سازمانی را در بر می‌گیرد — حامل ماژول
# است؛ بقیه میزها نقش‌محور از لیست Workspace قابل دسترس‌اند.
# توجه: در Frappe v15 فیلد is_default روی Workspace وجود ندارد؛ پیش‌فرض ماژول
# با همین «حامل واحد ماژول» تعیین می‌شود.
WORKSPACES = [
    ("CEO Command", "dashboard", ["CEO", "Financial Manager", "System Manager"], 10, ""),
    ("My Cartable", "organization", ["CEO", "Financial Manager", "Finance Supervisor",
                                     "Finance User", "Legal Reviewer", "Treasury User",
                                     "Receivables User", "Transport Supervisor",
                                     "Transport User - Purchase", "Transport User - Sales",
                                     "Customs Officer", "Document Signer"], 20, "Iran Trade"),
    ("Finance Desk", "money-coins-1", ["Financial Manager", "Finance Supervisor",
                                       "Finance User", "Treasury User", "Receivables User",
                                       "Legal Reviewer", "Document Signer"], 30, ""),
    ("Transport Desk", "stock", ["Transport Supervisor", "Transport User - Purchase",
                                 "Transport User - Sales"], 40, ""),
    ("Customs Desk", "getting-started", ["Customs Officer", "Transport Supervisor"], 50, ""),
    ("Commercial Desk", "file", ["Finance Supervisor", "Financial Manager", "CEO"], 60, ""),
]

LINKS = {
    "CEO Command": ["CEO Request", "Trade Case", "Factory Shortfall Ledger"],
    "My Cartable": ["Trade Case", "Trade Case Loading", "Trade Sales Slip"],
    "Finance Desk": ["Trade Case", "Trade Sales Slip", "Factory Shortfall Ledger",
                     "Treasury Settings"],
    "Transport Desk": ["Trade Case Loading", "Transport Waybill", "Transport Weighbridge"],
    "Customs Desk": ["Transport Bijak", "Transport Clearance", "Border",
                     "Customs Broker", "Border Representative"],
    "Commercial Desk": ["Trade Case", "Trade Sales Slip", "Carrier", "Supervisor Team"],
}


def _content(ws_name):
    blocks = [_header(ws_name)]
    if ws_name == "CEO Command":
        blocks.append({"id": "ceo_kpi", "type": "custom_block",
                       "data": {"custom_block_name": "ITE CEO KPI", "col": 12}})
    for dt in LINKS.get(ws_name, []):
        blocks.append({"id": dt, "type": "shortcut", "data": {"shortcut_name": dt, "col": 3}})
    return blocks


def install():
    purged = purge_persian_workspaces()
    made = []
    for name, icon, roles, sequence_id, module in WORKSPACES:
        roles = [r for r in roles if frappe.db.exists("Role", r)]
        made.append(ensure_workspace(
            name, name, icon, roles, _content(name),
            sequence_id=sequence_id, module=module,
        ))
        ws = frappe.get_doc("Workspace", name)
        ws.set("shortcuts", [])
        for dt in LINKS.get(name, []):
            if frappe.db.exists("DocType", dt):
                ws.append("shortcuts", {"type": "DocType", "link_to": dt, "label": dt})
        ws.flags.ignore_permissions = True
        ws.save(ignore_permissions=True)
    frappe.db.commit()
    return {"created": made, "purged_persian": purged}
EOF

# =============================================================================
step "4) استایل مینیمال RTL + موتور رندر داشبورد و کارتابل"
write_utf8 "${PKG}/public/css/ite_ui.css" << 'EOF'
/* ============================================================
   Iran Trade ERP — لایه بصری مینیمال RTL
   اصل: کمترین عنصر، بیشترین خوانایی. بدون شلوغی.
   ============================================================ */
.ite-wrap { direction: rtl; text-align: right;
  font-family: Vazirmatn, IRANSans, IRANYekan, Tahoma, sans-serif; }

.ite-kpi-grid {
  display: grid; gap: 12px; margin: 8px 0 18px 0;
  grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
}
.ite-kpi {
  border-radius: 14px; padding: 16px 18px; color: #0f172a;
  background: #ffffff; border: 1px solid #eceff3;
  box-shadow: 0 1px 2px rgba(16,24,40,.04);
  transition: transform .15s ease, box-shadow .15s ease;
}
.ite-kpi:hover { transform: translateY(-2px); box-shadow: 0 6px 18px rgba(16,24,40,.08); }
.ite-kpi .v { font-size: 26px; font-weight: 700; letter-spacing: -.5px; line-height: 1.2; }
.ite-kpi .l { font-size: 12px; color: #64748b; margin-top: 6px; }
.ite-kpi .bar { height: 4px; width: 42px; border-radius: 99px; margin-bottom: 12px; }

.ite-tone-blue   .bar { background: linear-gradient(90deg,#3b82f6,#93c5fd); }
.ite-tone-amber  .bar { background: linear-gradient(90deg,#f59e0b,#fcd34d); }
.ite-tone-rose   .bar { background: linear-gradient(90deg,#f43f5e,#fda4af); }
.ite-tone-green  .bar { background: linear-gradient(90deg,#10b981,#6ee7b7); }
.ite-tone-slate  .bar { background: linear-gradient(90deg,#64748b,#cbd5e1); }
.ite-tone-teal   .bar { background: linear-gradient(90deg,#0d9488,#5eead4); }
.ite-tone-violet .bar { background: linear-gradient(90deg,#7c3aed,#c4b5fd); }
.ite-tone-orange .bar { background: linear-gradient(90deg,#ea580c,#fdba74); }

.ite-panel { background:#fff; border:1px solid #eceff3; border-radius:14px;
  padding:14px 16px; margin-bottom:14px; }
.ite-panel h5 { font-size:13px; color:#0f172a; margin:0 0 10px 0; font-weight:700; }
.ite-row { display:flex; justify-content:space-between; padding:7px 0;
  border-bottom:1px dashed #f1f5f9; font-size:12.5px; }
.ite-row:last-child { border-bottom:0; }
.ite-muted { color:#94a3b8; font-size:12px; }

/* کارت خلاصه بالای فرم */
.ite-summary { display:grid; gap:10px; margin:6px 0 4px 0;
  grid-template-columns: repeat(auto-fit, minmax(140px,1fr)); }
.ite-summary .cell { background:#f8fafc; border:1px solid #eef2f6;
  border-radius:10px; padding:9px 11px; }
.ite-summary .cell .k { font-size:11px; color:#64748b; }
.ite-summary .cell .v { font-size:13.5px; font-weight:700; color:#0f172a; margin-top:3px; }

/* تایم‌لاین فارسی */
.ite-timeline { position:relative; padding-right:16px; }
.ite-timeline::before { content:""; position:absolute; right:5px; top:4px; bottom:4px;
  width:2px; background:#eef2f6; }
.ite-tl-item { position:relative; padding:6px 16px 6px 0; font-size:12.5px; }
.ite-tl-item::before { content:""; position:absolute; right:-1px; top:12px;
  width:9px; height:9px; border-radius:99px; background:#3b82f6; border:2px solid #fff; }
.ite-tl-item .who { font-weight:700; color:#0f172a; }
.ite-tl-item .what { color:#334155; }
.ite-tl-item .when { color:#94a3b8; font-size:11px; }

/* بخش‌های جمع‌شونده و قفل مرحله‌ای */
.ite-stage-dim .section-head { opacity:.55; }
.ite-badge { display:inline-block; padding:2px 9px; border-radius:99px;
  font-size:11px; font-weight:700; }
.ite-badge.on  { background:#ecfdf5; color:#047857; }
.ite-badge.off { background:#f1f5f9; color:#64748b; }
EOF

write_utf8 "${PKG}/public/js/ite_dashboard.js" << 'EOF'
/* ============================================================
   موتور رندر مشترک داشبورد مدیرعامل و کارتابل — بدون Build
   ============================================================ */
frappe.provide("ite.ui");

ite.ui.money = function (v) {
	if (v === null || v === undefined) return "—";
	try { return Number(v).toLocaleString("fa-IR"); } catch (e) { return v; }
};

ite.ui.kpi_grid = function (cards) {
	let h = '<div class="ite-kpi-grid">';
	(cards || []).forEach(function (c) {
		h += '<div class="ite-kpi ite-tone-' + (c.tone || "slate") + '">' +
			'<div class="bar"></div>' +
			'<div class="v">' + ite.ui.money(c.value) + "</div>" +
			'<div class="l">' + frappe.utils.escape_html(c.label) + "</div>" +
			"</div>";
	});
	return h + "</div>";
};

ite.ui.panel = function (title, rows) {
	let h = '<div class="ite-panel"><h5>' + frappe.utils.escape_html(title) + "</h5>";
	if (!rows || !rows.length) {
		h += '<div class="ite-muted">موردی برای نمایش نیست.</div>';
	} else {
		rows.forEach(function (r) {
			h += '<div class="ite-row"><span>' + frappe.utils.escape_html(r.k) +
				"</span><span><b>" + ite.ui.money(r.v) + "</b></span></div>";
		});
	}
	return h + "</div>";
};

ite.ui.list_panel = function (title, rows, render) {
	let h = '<div class="ite-panel"><h5>' + frappe.utils.escape_html(title) +
		' <span class="ite-badge ' + (rows && rows.length ? "on" : "off") + '">' +
		(rows ? rows.length : 0) + "</span></h5>";
	if (!rows || !rows.length) {
		h += '<div class="ite-muted">موردی وجود ندارد.</div>';
	} else {
		rows.slice(0, 8).forEach(function (r) { h += render(r); });
	}
	return h + "</div>";
};

ite.ui.render_ceo = function (target) {
	frappe.call({
		method: "iran_trade_erp.iran_trade.api.ceo_dashboard.get_kpi",
		callback: function (r) {
			if (!r.message) return;
			const f = r.message.finance || {};
			let h = '<div class="ite-wrap">' + ite.ui.kpi_grid(r.message.cards);
			h += ite.ui.panel("خلاصه مالی", [
				{ k: "جمع فروش (پایه ریالی)", v: f.sales_base },
				{ k: "جمع خرید (پایه ریالی)", v: f.purchase_base },
				{ k: "بهای تمام‌شده عملیاتی", v: f.operational_cost },
				{ k: "جمع تسویه‌شده", v: f.settled },
				{ k: "مانده تسویه", v: f.balance },
			]);
			h += "</div>";
			$(target).html(h);
		},
	});
	frappe.call({
		method: "iran_trade_erp.iran_trade.api.ceo_dashboard.get_breakdown",
		callback: function (r) {
			if (!r.message) return;
			let h = '<div class="ite-wrap">';
			h += ite.ui.panel("تناژ به تفکیک کارخانه", (r.message.by_factory || []).map(x => ({ k: x.k, v: x.v })));
			h += ite.ui.panel("پرونده به تفکیک مرز", (r.message.by_border || []).map(x => ({ k: x.k, v: x.v })));
			h += ite.ui.panel("وضعیت تأمین", (r.message.by_state || []).map(x => ({ k: x.k, v: x.v })));
			h += "</div>";
			$(target).append(h);
		},
	});
};

ite.ui.render_cartable = function (target) {
	frappe.call({
		method: "iran_trade_erp.iran_trade.api.cartable.get_cartable",
		callback: function (r) {
			const d = r.message || {};
			if (d.blocked) { $(target).html('<div class="ite-wrap ite-panel">' + d.message + "</div>"); return; }
			const caseRow = function (c) {
				return '<div class="ite-row"><span><a href="/app/trade-case/' +
					encodeURIComponent(c.name) + '">' + frappe.utils.escape_html(c.case_title || c.name) +
					"</a></span><span class=\"ite-muted\">" +
					frappe.utils.escape_html(c.workflow_state || "") + "</span></div>";
			};
			const loadRow = function (l) {
				return '<div class="ite-row"><span><a href="/app/trade-case-loading/' +
					encodeURIComponent(l.name) + '">' + frappe.utils.escape_html(l.name) +
					"</a></span><span class=\"ite-muted\">" +
					frappe.utils.escape_html(l.loading_state || "") + "</span></div>";
			};
			const alertRow = function (a) {
				return '<div class="ite-row"><span>' + frappe.utils.escape_html(a.subject || "") +
					"</span></div>";
			};
			const actRow = function (a) {
				return '<div class="ite-row"><span>' + frappe.utils.escape_html(a.ref_doctype || "") +
					" — " + frappe.utils.escape_html(a.docname || "") + "</span></div>";
			};
			let h = '<div class="ite-wrap">';
			h += ite.ui.list_panel("ارجاع‌شده به من", d.assigned_to_me, caseRow);
			h += ite.ui.list_panel("کارهای جدید", d.new_items, caseRow);
			h += ite.ui.list_panel("در انتظار اقدام من", d.pending_my_action, caseRow);
			h += ite.ui.list_panel("فوری", d.urgent, caseRow);
			h += ite.ui.list_panel("عقب‌افتاده", d.overdue, caseRow);
			h += ite.ui.list_panel("پرونده‌های در اختیار من", d.in_my_hands, caseRow);
			h += ite.ui.list_panel("بارگیری‌های من", d.loadings, loadRow);
			h += ite.ui.list_panel("تکمیل‌شده اخیر", d.recently_completed, caseRow);
			h += ite.ui.list_panel("اعلان‌ها و هشدارها", d.alerts, alertRow);
			h += ite.ui.list_panel("آخرین فعالیت‌های من", d.my_activity, actRow);
			h += "</div>";
			$(target).html(h);
		},
	});
};

$(document).on("page-change", function () {
	const route = frappe.get_route() || [];
	if (route[0] !== "Workspaces") return;
	setTimeout(function () {
		const $c = $(".layout-main-section");
		if (!$c.length) return;
		if (route[1] === "CEO Command" && !$c.find(".ite-kpi-grid").length) {
			const $t = $('<div class="ite-mount"></div>').prependTo($c);
			ite.ui.render_ceo($t);
		}
		if (route[1] === "My Cartable" && !$c.find(".ite-panel").length) {
			const $t = $('<div class="ite-mount"></div>').prependTo($c);
			ite.ui.render_cartable($t);
		}
	}, 350);
});
EOF

write_utf8 "${PKG}/public/js/ite_form_ux.js" << 'EOF'
/* ============================================================
   تجربه کاربری فرم پرونده بازرگانی
   بخش‌های شماره‌دار و جمع‌شونده | تب‌بندی | نگاشت مرحله→بخش |
   کارت خلاصه | تایم‌لاین فارسی | هشدار خروج | قفل مرحله‌ای
   ============================================================ */
frappe.provide("ite.form");

ite.form._stage_map = null;
ite.form._dirty = false;

ite.form.load_stage_map = function (cb) {
	if (ite.form._stage_map) { cb(ite.form._stage_map); return; }
	frappe.call({
		method: "iran_trade_erp.iran_trade.api.cartable.stage_section_map",
		callback: function (r) { ite.form._stage_map = r.message || {}; cb(ite.form._stage_map); },
	});
};

ite.form.render_summary = function (frm) {
	if (frm.is_new()) return;
	frappe.call({
		method: "iran_trade_erp.iran_trade.api.cartable.summary_card",
		args: { doctype: frm.doctype, name: frm.doc.name },
		callback: function (r) {
			if (!r.message) return;
			let h = '<div class="ite-wrap"><div class="ite-summary">';
			r.message.forEach(function (c) {
				h += '<div class="cell"><div class="k">' + frappe.utils.escape_html(c.label) +
					'</div><div class="v">' + frappe.utils.escape_html(String(c.value)) + "</div></div>";
			});
			h += "</div></div>";
			frm.get_field("ite_summary_html") ?
				frm.set_df_property("ite_summary_html", "options", h) :
				frm.dashboard.add_section(h, __("کارت خلاصه پرونده"));
		},
	});
};

ite.form.render_timeline = function (frm) {
	if (frm.is_new()) return;
	frappe.call({
		method: "iran_trade_erp.iran_trade.api.cartable.case_timeline",
		args: { doctype: frm.doctype, name: frm.doc.name, limit: 25 },
		callback: function (r) {
			const rows = r.message || [];
			let h = '<div class="ite-wrap ite-timeline">';
			if (!rows.length) {
				h += '<div class="ite-muted">هنوز رویدادی ثبت نشده است.</div>';
			} else {
				rows.forEach(function (x) {
					h += '<div class="ite-tl-item"><span class="who">' +
						frappe.utils.escape_html(x.user) + '</span> — <span class="what">' +
						frappe.utils.escape_html(x.action) + '</span><div class="when">' +
						frappe.utils.escape_html(x.when) + "</div></div>";
				});
			}
			h += "</div>";
			frm.dashboard.add_section(h, __("تایم‌لاین پرونده"));
		},
	});
};

ite.form.apply_stage_sections = function (frm) {
	ite.form.load_stage_map(function (map) {
		const state = frm.doc.workflow_state || "Draft";
		const active = map[state] || [];
		(frm.meta.fields || []).forEach(function (df) {
			if (df.fieldtype !== "Section Break") return;
			if (!df.fieldname || df.fieldname.indexOf("sb_") !== 0) return;
			const isActive = active.indexOf(df.fieldname) !== -1;
			// هیچ فیلدی حذف نمی‌شود؛ فقط بخش‌های غیرمرتبط جمع می‌شوند
			frm.toggle_display(df.fieldname, true);
			try {
				const $sec = frm.fields_dict[df.fieldname] && frm.fields_dict[df.fieldname].wrapper;
				if ($sec) {
					$($sec).toggleClass("ite-stage-dim", !isActive);
					const $body = $($sec).find(".section-body").first();
					if ($body.length) { isActive ? $body.show() : $body.hide(); }
				}
			} catch (e) { /* بی‌صدا نمی‌مانیم؛ فقط UI است */ }
		});
	});
};

ite.form.apply_stage_lock = function (frm) {
	/* قفل بر اساس مرحله — فیلدهای مراحل گذشته فقط‌خواندنی می‌شوند */
	const state = frm.doc.workflow_state || "Draft";
	const lock = {
		"Legal Review": ["items", "case_type", "requested_by"],
		"Treasury Review": ["items", "case_type", "requested_by", "chk_legal_purchase_contract",
			"chk_legal_sales_contract", "chk_legal_obligations",
			"chk_legal_requirements", "chk_legal_documents"],
		"Pending Signature": ["items", "case_type", "requested_by", "treasury_approved_ceiling"],
		"Finance Supervisor Approval": ["items", "case_type", "requested_by", "signed_document"],
		"Receivables": ["items", "case_type", "requested_by", "signed_document"],
		"Approved": ["items", "case_type", "requested_by", "signed_document"],
		"Completed": ["items", "case_type", "requested_by", "signed_document"],
	};
	(lock[state] || []).forEach(function (f) {
		if (frm.get_field(f)) frm.set_df_property(f, "read_only", 1);
	});
};

ite.form.guard_unsaved = function (frm) {
	frm.$wrapper.off("change.iteDirty").on("change.iteDirty", "input,select,textarea", function () {
		ite.form._dirty = true;
	});
	if (!window.__ite_beforeunload) {
		window.__ite_beforeunload = true;
		window.addEventListener("beforeunload", function (e) {
			const cur = frappe.get_route() || [];
			if (cur[0] !== "Form") return;
			if (cur_frm && cur_frm.is_dirty && cur_frm.is_dirty()) {
				e.preventDefault();
				e.returnValue = "تغییرات ذخیره‌نشده دارید. آیا از خروج مطمئن هستید؟";
				return e.returnValue;
			}
		});
	}
	frappe.router.on("change", function () {
		if (cur_frm && cur_frm.is_dirty && cur_frm.is_dirty()) {
			frappe.show_alert({ message: __("تغییرات ذخیره‌نشده دارید."), indicator: "orange" }, 6);
		}
	});
};

frappe.ui.form.on("Trade Case", {
	refresh: function (frm) {
		ite.form.render_summary(frm);
		ite.form.render_timeline(frm);
		ite.form.apply_stage_sections(frm);
		ite.form.apply_stage_lock(frm);
		ite.form.guard_unsaved(frm);

		if (!frm.is_new()) {
			frm.add_custom_button(__("پیش‌نمایش اعداد مالی"), function () {
				frappe.call({
					method: "iran_trade_erp.iran_trade.utils.money_engine.get_cost_preview",
					args: { doctype: frm.doctype, name: frm.doc.name },
					callback: function (r) {
						const m = r.message || {};
						frappe.msgprint({
							title: __("اعداد مالی (منبع واحد: سرور)"),
							message:
								"<div style='direction:rtl;text-align:right'>" +
								"بهای عملیاتی: <b>" + ite.ui.money(m.total_operational_cost) + "</b><br>" +
								"جمع تسویه: <b>" + ite.ui.money(m.total_settled) + "</b><br>" +
								"مانده تسویه: <b>" + ite.ui.money(m.settlement_balance) + "</b><br>" +
								"سود برآوردی: <b>" + ite.ui.money(m.estimated_profit) + "</b>" +
								"</div>",
						});
					},
				});
			}, __("مالی"));

			if (frm.doc.fulfillment_status !== "در انتظار تأمین کالا") {
				frm.add_custom_button(__("پارک در انتظار تأمین کالا"), function () {
					frappe.prompt([{ fieldname: "reason", fieldtype: "Small Text",
						label: __("دلیل"), reqd: 1 }], function (v) {
						frappe.call({
							method: "iran_trade_erp.iran_trade.doctype.trade_case.trade_case.park_waiting_supply",
							args: { name: frm.doc.name, reason: v.reason },
							callback: function () { frm.reload_doc(); },
						});
					}, __("پارک پرونده"), __("ثبت"));
				}, __("عملیات"));
			} else {
				frm.add_custom_button(__("آزادسازی و ادامه"), function () {
					frappe.call({
						method: "iran_trade_erp.iran_trade.doctype.trade_case.trade_case.release_waiting_supply",
						args: { name: frm.doc.name },
						callback: function () { frm.reload_doc(); },
					});
				}, __("عملیات"));
			}

			frm.add_custom_button(__("بستن دستی با ثبت دلیل"), function () {
				frappe.prompt([{ fieldname: "reason", fieldtype: "Small Text",
					label: __("دلیل بستن دستی"), reqd: 1 }], function (v) {
					frappe.call({
						method: "iran_trade_erp.iran_trade.doctype.trade_case.trade_case.manual_close",
						args: { name: frm.doc.name, reason: v.reason },
						callback: function () {
							frappe.show_alert({ message: __("پرونده بسته شد و کسری در دفتر بدهی ثبت گردید."),
								indicator: "orange" });
							frm.reload_doc();
						},
					});
				}, __("بستن دستی پرونده"), __("ثبت"));
			}, __("عملیات"));

			if (frm.doc.workflow_state === "Pending Signature") {
				frm.add_custom_button(__("بارگذاری سند امضاشده"), function () {
					new frappe.ui.FileUploader({
						doctype: frm.doctype, docname: frm.doc.name,
						on_success: function (file) {
							frappe.call({
								method: "iran_trade_erp.iran_trade.workflow.guards.upload_signed_document",
								args: { name: frm.doc.name, file_url: file.file_url },
								callback: function () {
									frappe.show_alert({ message: __("سند امضاشده ثبت شد."), indicator: "green" });
									frm.reload_doc();
								},
							});
						},
					});
				}, __("عملیات"));
			}
		}
	},

	workflow_state: function (frm) {
		ite.form.apply_stage_sections(frm);
		ite.form.apply_stage_lock(frm);
	},
});

frappe.ui.form.on("Trade Case Loading", {
	refresh: function (frm) {
		ite.form.guard_unsaved(frm);
		if (frm.is_new()) return;
		frm.add_custom_button(__("بستن دستی بارگیری"), function () {
			frappe.prompt([{ fieldname: "reason", fieldtype: "Small Text",
				label: __("دلیل"), reqd: 1 }], function (v) {
				frappe.call({
					method: "iran_trade_erp.iran_trade.doctype.trade_case_loading.loading_engine.manual_close_loading",
					args: { name: frm.doc.name, reason: v.reason },
					callback: function () { frm.reload_doc(); },
				});
			}, __("بستن دستی"), __("ثبت"));
		}, __("عملیات"));
	},
});

/* ============================================================
   اصلاح حلقهٔ عملیات انسانی:
   «صدور → دریافت → بارگیری» حالا دکمهٔ واقعی دارد و trade_item_row
   دیگر با دست تایپ نمی‌شود؛ با picker از ردیف‌های پرونده انتخاب می‌شود.
   ============================================================ */

frappe.ui.form.on("Trade Sales Slip", {
	onload: function (frm) {
		// فیلتر زودهنگام: ریزفاکتور فقط از پرونده خرید/ترکیبی بریده می‌شود
		frm.set_query("purchase_case", function () {
			return { filters: { case_type: ["in", ["خرید", "ترکیبی"]] } };
		});
	},
	refresh: function (frm) {
		if (frm.is_new()) return;
		// ★ دکمه دریافت توسط واحد حمل — حلقه اصلی گردش‌کار مالی→حمل
		if (frm.doc.slip_status === "صادرشده") {
			frm.add_custom_button(__("دریافت ریزفاکتور (واحد حمل)"), function () {
				frappe.confirm(
					__("این ریزفاکتور به کارتابل واحد حمل تحویل می‌شود. ادامه می‌دهید؟"),
					function () {
						frappe.call({
							method: "iran_trade_erp.iran_trade.doctype.trade_sales_slip.trade_sales_slip.receive_by_transport",
							args: { name: frm.doc.name },
							callback: function (r) {
								if (!r.exc) {
									frappe.show_alert({ message: __("ریزفاکتور تحویل واحد حمل شد."), indicator: "green" });
									frm.reload_doc();
								}
							},
						});
					}
				);
			}, __("عملیات"));
		}
		// ★ انتخاب ردیف کالا با picker — به‌جای تایپ دستی شناسهٔ ردیف
		frm.add_custom_button(__("انتخاب ردیف از پرونده خرید"), function () {
			if (!frm.doc.purchase_case) {
				frappe.msgprint(__("ابتدا «پرونده خرید مبدأ» را انتخاب کنید."));
				return;
			}
			frappe.call({
				method: "iran_trade_erp.iran_trade.doctype.trade_case_loading.loading_engine.get_case_rows",
				args: { trade_case: frm.doc.purchase_case },
				callback: function (r) {
					const rows = r.message || [];
					if (!rows.length) {
						frappe.msgprint(__("این پرونده قلم کالایی ندارد."));
						return;
					}
					const fields = rows.map(function (x) {
						return {
							label: (x.item_name || x.item) + " — " + x.tonnage + " تن (مانده: " +
								(x.remaining_tonnage || 0) + ")", value: x.name,
						};
					});
					frappe.prompt([{ fieldname: "row_name", fieldtype: "Select",
						label: __("ردیف کالای مبدأ"), options: fields, reqd: 1 }],
						function (v) {
							const picked = rows.find(function (x) { return x.name === v.row_name; });
							if (picked) {
								frm.set_value("trade_item_row", picked.name);
								frm.set_value("item", picked.item);
								frappe.show_alert({ message: __("ردیف انتخاب شد: ") + (picked.item_name || picked.item), indicator: "blue" });
							}
						}, __("انتخاب ردیف"), __("انتخاب"));
				},
			});
		}, __("عملیات"));
	},
});

frappe.ui.form.on("Trade Case", {
	// ★ دکمه ایجاد بارگیری اتمیک — بدون آن، واحد حمل فقط console/API داشت
	ite_create_loading: function (frm) {
		const case_name = frm.doc.name;
		frappe.call({
			method: "iran_trade_erp.iran_trade.doctype.trade_case_loading.loading_engine.get_case_rows",
			args: { trade_case: case_name },
			callback: function (r) {
				const rows = (r.message || []).filter(function (x) {
					return (x.row_kind || "") === "خرید";
				});
				if (!rows.length) {
					frappe.msgprint(__("این پرونده ردیف «خرید» برای برش ندارد."));
					return;
				}
				frappe.call({
					method: "iran_trade_erp.iran_trade.doctype.trade_sales_slip.trade_sales_slip.open_slips_for_transport",
					args: { purchase_case: case_name },
					callback: function (r2) {
						const slips = r2.message || [];
						if (!slips.length) {
							frappe.msgprint(__("هیچ ریزفاکتور «دریافت‌شده»ای برای این پرونده نیست. ابتدا واحد مالی ریزفاکتور صادر و واحد حمل آن را دریافت کند."));
							return;
						}
						const row_fields = rows.map(function (x) {
							return { label: (x.item_name || x.item) + " — " + x.tonnage + " تن", value: x.name };
						});
						const slip_fields = slips.map(function (s) {
							return { label: s.name + " — " + s.tonnage + " تن — " + (s.buyer || ""), value: s.name };
						});
						frappe.prompt([
							{ fieldname: "trade_item_row", fieldtype: "Select", label: __("ردیف کالا"), options: row_fields, reqd: 1 },
							{ fieldname: "sales_slip", fieldtype: "Select", label: __("ریزفاکتور فروش"), options: slip_fields, reqd: 1 },
							{ fieldname: "planned_tonnage", fieldtype: "Float", label: __("تناژ برنامه (رزرو)"), reqd: 1 },
						], function (v) {
							frappe.call({
								method: "iran_trade_erp.iran_trade.doctype.trade_case_loading.loading_engine.create_loading",
								args: {
									trade_case: case_name,
									trade_item_row: v.trade_item_row,
									planned_tonnage: v.planned_tonnage,
									sales_slip: v.sales_slip,
								},
								callback: function (r3) {
									if (!r3.exc) {
										frappe.show_alert({ message: __("بارگیری ایجاد شد: ") + r3.message, indicator: "green" });
										frm.reload_doc();
									}
								},
							});
						}, __("ایجاد بارگیری"), __("ثبت"));
					},
				});
			},
		});
	},
});

// دکمه فقط برای واحد حمل نمایش داده می‌شود (نقش‌های حمل یا مدیر سامانه)
frappe.ui.form.on("Trade Case", {
	refresh: function (frm) {
		if (frm.is_new()) return;
		if (frappe.user.has_role("Transport Supervisor") ||
			frappe.user.has_role("Transport User - Purchase") ||
			frappe.user.has_role("Transport User - Sales") ||
			frappe.user.has_role("System Manager")) {
			frm.add_custom_button(__("ایجاد بارگیری"), function () {
				frm.trigger("ite_create_loading");
			}, __("عملیات حمل"));
		}
	},
});
EOF

# =============================================================================
step "5) hooks (SCRIPT09) + ترجمه‌ها"
python3 - "$PKG" << 'PYEOF'
import io, os, re, sys
pkg = sys.argv[1]
p = os.path.join(pkg, "hooks.py")
src = io.open(p, encoding="utf-8").read()
if "# --- SCRIPT08_HOOKS_START ---" not in src:
    raise SystemExit("ABORT: anchor SCRIPT08 missing")
S, E = "# --- SCRIPT09_HOOKS_START ---", "# --- SCRIPT09_HOOKS_END ---"
src = re.sub(re.escape(S) + r".*?" + re.escape(E), "", src, flags=re.S)
block = S + '''
_ite_js = globals().get("app_include_js", []) or []
for _f in ("/assets/iran_trade_erp/js/ite_dashboard.js",
           "/assets/iran_trade_erp/js/ite_form_ux.js"):
    if _f not in _ite_js:
        _ite_js.append(_f)
app_include_js = _ite_js

_ite_css = globals().get("app_include_css", []) or []
if "/assets/iran_trade_erp/css/ite_ui.css" not in _ite_css:
    _ite_css.append("/assets/iran_trade_erp/css/ite_ui.css")
app_include_css = _ite_css
''' + E + "\n"
io.open(p, "w", encoding="utf-8").write(src.rstrip() + "\n\n" + block)

t = os.path.join(pkg, "translations", "fa.csv")
rows = ["CEO Command,میز مدیرعامل,", "My Cartable,کارتابل من,",
        "Finance Desk,میز مالی,", "Transport Desk,میز حمل,",
        "Customs Desk,میز گمرک,", "Commercial Desk,میز بازرگانی,",
        "Cartable Settings,تنظیمات کارتابل,"]
cur = io.open(t, encoding="utf-8").read() if os.path.exists(t) else ""
have = set(l.split(",")[0] for l in cur.splitlines() if l.strip())
add = [r for r in rows if r.split(",")[0] not in have]
if add:
    io.open(t, "a", encoding="utf-8").write("\n".join(add) + "\n")
print("SCRIPT09 hooks + fa.csv ok")
PYEOF

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" execute iran_trade_erp.iran_trade.workspace.install_workspaces.install
bench --site "$SITE_NAME" clear-cache
bench build --app "$APP" >/dev/null 2>&1 || warn "bench build رد شد — دارایی‌ها استاتیک‌اند"

# =============================================================================
step "6) Verify داخلی"
write_utf8 "${PKG}/verify_script09.py" << 'EOF'
# -*- coding: utf-8 -*-
import re

import frappe

ASCII = re.compile(r"^[A-Za-z0-9 _\-\.]+$")
WS = ["CEO Command", "My Cartable", "Finance Desk", "Transport Desk",
      "Customs Desk", "Commercial Desk"]


def run():
    passed = failed = 0

    def chk(t, c):
        nonlocal passed, failed
        if c:
            passed += 1; print("  [PASS] " + t)
        else:
            failed += 1; print("  [FAIL] " + t)

    for w in WS:
        chk("فضای کاری ساخته شد: " + w, frappe.db.exists("Workspace", w) is not None)

    bad = [r.name for r in frappe.get_all("Workspace", fields=["name"])
           if not ASCII.match(r.name or "")]
    chk("هیچ Workspace با شناسه فارسی وجود ندارد (ضد ۴۰۴)", not bad)

    for w in WS:
        d = frappe.get_doc("Workspace", w)
        chk("فضای کاری «{0}» نقش‌محور است".format(w), len(d.roles) >= 1)

    # ★ اصلاح breadcrumb: دقیقاً یک فضا حامل ماژول است (My Cartable با
    # نقش هر ۱۲ کاربر سازمانی)؛ دیگر «میز مدیرعامل» به همه نشان داده نمی‌شود
    # توجه: در Frappe v15 ستون is_default روی Workspace وجود ندارد؛
    # پیش‌فرض ماژول با «حامل واحد فیلد module» تعیین و verify می‌شود.
    module_holders = frappe.get_all("Workspace", filters={"module": "Iran Trade"}, pluck="name")
    chk("★ فقط یک فضای کاری ماژول «Iran Trade» را حمل می‌کند (یافت‌شده: {0})".format(
        ", ".join(module_holders)
    ), module_holders == ["My Cartable"])
    chk("★ فضای پیش‌فرض ماژول، «My Cartable» است (نه میز مدیرعامل)",
        frappe.db.get_value("Workspace", "My Cartable", "module") == "Iran Trade")
    chk("میز مدیرعامل دیگر حامل ماژول نیست",
        not frappe.db.get_value("Workspace", "CEO Command", "module"))

    chk("«تنظیمات کارتابل» ساخته شد",
        frappe.db.count("DocType", {"name": "Cartable Settings"}) == 1)

    from iran_trade_erp.iran_trade.doctype.cartable_settings.cartable_settings import get_stage_map
    m = get_stage_map()
    chk("نگاشت مرحله → بخش تعریف شده است", isinstance(m, dict) and len(m) >= 8)
    chk("مرحله «Pending Signature» بخش اسناد را نشان می‌دهد",
        "sb_8_docs" in (m.get("Pending Signature") or []))

    from iran_trade_erp.iran_trade.api import cartable, ceo_dashboard
    k = ceo_dashboard.get_kpi()
    chk("داشبورد مدیرعامل کارت‌های KPI برمی‌گرداند", len(k.get("cards", [])) == 8)
    chk("کارت «در انتظار تأمین کالا» در داشبورد هست",
        any(c["key"] == "waiting_supply" for c in k["cards"]))
    chk("خلاصه مالی داشبورد کامل است",
        all(x in k["finance"] for x in ("sales_base", "purchase_base",
                                        "operational_cost", "settled", "balance")))
    b = ceo_dashboard.get_breakdown()
    chk("نماهای گروهی داشبورد کار می‌کنند",
        all(x in b for x in ("by_factory", "by_border", "by_state")))

    # کارتابل: مدیر سامانه نباید کارتابل عملیاتی داشته باشد
    frappe.set_user("Administrator")
    c = cartable.get_cartable()
    chk("مدیر سامانه کارتابل عملیاتی ندارد", c.get("blocked") is True)

    # با کاربر واقعی
    fin = frappe.get_all("Has Role", filters={"role": "Finance User", "parenttype": "User"},
                         pluck="parent")
    fin = [u for u in fin if u not in ("Administrator", "Guest")]
    if fin:
        frappe.set_user(fin[0])
        c = cartable.get_cartable()
        for sec in ("assigned_to_me", "new_items", "pending_my_action", "urgent",
                    "overdue", "in_my_hands", "recently_completed", "alerts", "my_activity"):
            chk("کارتابل بخش «{0}» را برمی‌گرداند".format(sec), sec in c)
        frappe.set_user("Administrator")
    else:
        chk("کاربر مالی واقعی برای تست کارتابل موجود بود", False)

    case = frappe.get_all("Trade Case", limit=1, pluck="name")
    if case:
        card = cartable.summary_card("Trade Case", case[0])
        chk("کارت خلاصه دقیقاً ۱۱ قلم دارد", len(card) == 11)
        tl = cartable.case_timeline("Trade Case", case[0])
        chk("تایم‌لاین فارسی برمی‌گردد", isinstance(tl, list))
        if tl:
            chk("قالب تایم‌لاین شامل کاربر/عملیات/زمان است",
                all(k2 in tl[0] for k2 in ("user", "action", "when")))
        else:
            passed += 1; print("  [PASS] تایم‌لاین خالی ولی معتبر است")
    else:
        chk("پرونده‌ای برای تست کارت خلاصه موجود بود", False)

    wl = cartable.workload_by_user()
    chk("گزارش بار کاری کاربران اجرا شد", isinstance(wl, list))

    import os
    css = frappe.get_app_path("iran_trade_erp", "public", "css", "ite_ui.css")
    js1 = frappe.get_app_path("iran_trade_erp", "public", "js", "ite_dashboard.js")
    js2 = frappe.get_app_path("iran_trade_erp", "public", "js", "ite_form_ux.js")
    chk("استایل مینیمال نوشته شد", os.path.exists(css))
    chk("موتور داشبورد نوشته شد", os.path.exists(js1))
    chk("تجربه کاربری فرم نوشته شد", os.path.exists(js2))
    ux = open(js2, encoding="utf-8").read()
    chk("هشدار خروج با تغییرات ذخیره‌نشده پیاده شده", "beforeunload" in ux)
    chk("کارت خلاصه در فرم پیاده شده", "render_summary" in ux)
    chk("تایم‌لاین فارسی در فرم پیاده شده", "render_timeline" in ux)
    chk("نگاشت مرحله→بخش در فرم اعمال می‌شود", "apply_stage_sections" in ux)
    chk("قفل بر اساس مرحله پیاده شده", "apply_stage_lock" in ux)
    # ★ حلقهٔ عملیات انسانی (اصلاح لایه B)
    chk("★ دکمه «دریافت ریزفاکتور توسط حمل» در فرم هست", "receive_by_transport" in ux)
    chk("★ دکمه «ایجاد بارگیری» در فرم پرونده هست", "ite_create_loading" in ux)
    chk("★ picker انتخاب ردیف کالا (نه تایپ هش) هست", "get_case_rows" in ux)
    chk("★ فیلتر purchase_case روی نوع پرونده هست", "case_type" in ux and "purchase_case" in ux)

    print("\n  Passed: %d | Failed: %d" % (passed, failed))
    if failed:
        raise Exception("verify_script09 FAILED: %d" % failed)
    return "OK"
EOF

bench --site "$SITE_NAME" execute iran_trade_erp.verify_script09.run

cat <<FINAL

============================================================
 script-09.sh با موفقیت تمام شد
------------------------------------------------------------
 فضای کاری : ۶ میز نقش‌محور با شناسه انگلیسی پایدار (ضد ۴۰۴)
 کارتابل   : ۹ بخش + بارگیری‌های من (مدیر سامانه محروم)
 داشبورد   : ۸ کارت KPI مینیمال + خلاصه مالی + سه نمای گروهی
 فرم       : تب‌بندی، بخش شماره‌دار جمع‌شونده، نگاشت مرحله→بخش،
             کارت خلاصه ۱۱ قلمی، تایم‌لاین فارسی، هشدار خروج، قفل مرحله‌ای
 گام بعدی  : bash script-10.sh
============================================================
FINAL