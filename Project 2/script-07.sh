#!/usr/bin/env bash
# =============================================================================
# script-07.sh — ریزفاکتور فروش (صادره توسط مالی) + موتور اتمیک چندبارگیری
#                + اسناد اقماری حمل + چک‌لیست ۱۰ قلمی بستن
# بازسازی هدایت‌شده — Iran Trade ERP | ERPNext v15 / Frappe v15
# -----------------------------------------------------------------------------
# ★ شکاف مهمی که کاربر تصریح کرد و در هیچ دیاگرام قبلی نبود:
#   پس از رسیدن پرونده به مرحله حمل، «خانم حیدری» (کارشناس مالی) ریزفاکتورهای
#   فروش را برای فاکتور خرید صادر می‌کند و واحد حمل آن‌ها را «دریافت» می‌کند.
#   صدور فاکتور هرگز کار واحد حمل نیست. این اسکریپت این شکاف را می‌بندد:
#     Trade Sales Slip  ← فقط Finance User / Finance Supervisor می‌سازد
#     Trade Case Loading ← واحد حمل فقط ریزفاکتور صادرشده را دریافت می‌کند
#
# همچنین می‌سازد:
#   Trade Case Loading  — هر بارگیری/محموله، با موتور اتمیک:
#     SELECT ... FOR UPDATE روی پرونده و ردیف کالا | کلید یکتای عملیات
#     (Idempotency Key با ایندکس یکتای واقعی) | تفکیک کامل
#     reserved_tonnage (ظرفیت رزروشده) از shipped_tonnage (واقعاً حمل‌شده)
#     effective_tonnage: باسکول تاییدشده > actual دستی > هرگز planned
#   Transport Waybill (Submittable) / Weighbridge / Bijak / Clearance
#   Transport Payment (Child, چندارزی) — پرداخت «تسویه» است نه «هزینه»
#   چک‌لیست بستن ۱۰ قلمی با فیلد واقعی (نه فرض‌شده)
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
else nohup bench start >>/tmp/bench-start-itc07.log 2>&1 & log "pid=$!"; sleep 12; fi
RC="${BENCH_DIR}/config/redis_cache.conf"
RP="$( [[ -f "$RC" ]] && awk '$1=="port"{print $2; exit}' "$RC" || echo 13000 )"; [[ -n "$RP" ]] || RP=13000
R=0; for _i in $(seq 1 60); do
  if command -v redis-cli >/dev/null 2>&1 && redis-cli -h 127.0.0.1 -p "$RP" ping 2>/dev/null | grep -q '^PONG$'; then R=1; break; fi
  if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ":${RP}[[:space:]]"; then R=1; break; fi
  sleep 1; done
[[ "$R" -eq 1 ]] || err "redis آماده نشد"
bench use "$SITE_NAME" 2>/dev/null || true

step "0b) پیش‌نیاز — ABORT در نبود Anchor"
[[ -f "${MOD}/workflow/guards.py" ]] || err "ABORT: گاردهای گردش‌کار نیست. ابتدا script-06.sh"
grep -q "SCRIPT06_HOOKS_START" "${PKG}/hooks.py" || err "ABORT: بلوک SCRIPT06 در hooks.py نیست"
log "پیش‌نیازها تایید شد"

mk_dt() { mkdir -p "${MOD}/doctype/$1"; : > "${MOD}/doctype/$1/__init__.py"; }

# =============================================================================
step "1) ریزفاکتور فروش — صدور فقط توسط واحد مالی"
mk_dt trade_sales_slip
write_utf8 "${MOD}/doctype/trade_sales_slip/trade_sales_slip.json" << 'EOF'
{
 "actions": [], "autoname": "naming_series:", "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["naming_series", "purchase_case", "trade_item_row", "item", "cb_1",
                 "buyer", "buyer_nationality", "buyer_passport", "posting_date", "slip_status",
                 "sb_2", "tonnage", "price", "transaction_currency", "cb_2",
                 "conversion_rate", "rate_source", "rate_locked", "amount", "base_amount",
                 "sb_3", "issued_by", "issued_on", "cb_3", "received_by_transport",
                 "received_on", "sales_invoice", "notes"],
 "fields": [
  {"default": "TSS-.YYYY.-.#####", "fieldname": "naming_series", "fieldtype": "Select", "hidden": 1, "label": "سری", "options": "TSS-.YYYY.-.#####"},
  {"description": "فاکتور خرید بزرگ چندکالایی که این ریزفاکتور از آن بریده می‌شود", "fieldname": "purchase_case", "fieldtype": "Link", "in_list_view": 1, "label": "پرونده خرید مبدأ", "options": "Trade Case", "reqd": 1},
  {"fieldname": "trade_item_row", "fieldtype": "Data", "label": "شناسه ردیف کالای مبدأ", "reqd": 1},
  {"fieldname": "item", "fieldtype": "Link", "in_list_view": 1, "label": "کالا", "options": "Item", "reqd": 1},
  {"fieldname": "cb_1", "fieldtype": "Column Break"},
  {"fieldname": "buyer", "fieldtype": "Link", "in_list_view": 1, "label": "خریدار", "options": "Customer", "reqd": 1},
  {"fetch_from": "buyer.ite_nationality", "fieldname": "buyer_nationality", "fieldtype": "Data", "label": "ملیت خریدار", "read_only": 1},
  {"fetch_from": "buyer.ite_passport_number", "fieldname": "buyer_passport", "fieldtype": "Data", "label": "گذرنامه خریدار", "read_only": 1},
  {"fieldname": "posting_date", "fieldtype": "Date", "label": "تاریخ صدور", "reqd": 1},
  {"default": "صادرشده", "fieldname": "slip_status", "fieldtype": "Select", "in_list_view": 1, "in_standard_filter": 1, "label": "وضعیت", "options": "صادرشده\nتحویل واحد حمل شد\nدر حال بارگیری\nتکمیل‌شده\nلغو شده", "reqd": 1},
  {"fieldname": "sb_2", "fieldtype": "Section Break", "label": "مبلغ و ارز (رویدادی)"},
  {"fieldname": "tonnage", "fieldtype": "Float", "in_list_view": 1, "label": "تناژ ریزفاکتور", "reqd": 1},
  {"fieldname": "price", "fieldtype": "Float", "label": "قیمت واحد فروش", "reqd": 1},
  {"default": "IRR", "fieldname": "transaction_currency", "fieldtype": "Link", "label": "ارز رویداد", "options": "Currency", "reqd": 1},
  {"fieldname": "cb_2", "fieldtype": "Column Break"},
  {"fieldname": "conversion_rate", "fieldtype": "Float", "label": "نرخ تبدیل", "precision": "9", "read_only": 1},
  {"fieldname": "rate_source", "fieldtype": "Data", "label": "منبع نرخ", "read_only": 1},
  {"default": "0", "fieldname": "rate_locked", "fieldtype": "Check", "label": "نرخ قفل شده", "read_only": 1},
  {"fieldname": "amount", "fieldtype": "Float", "label": "مبلغ رویداد", "read_only": 1},
  {"fieldname": "base_amount", "fieldtype": "Currency", "label": "مبلغ پایه (ریال)", "read_only": 1},
  {"fieldname": "sb_3", "fieldtype": "Section Break", "label": "صدور و تحویل به حمل"},
  {"fieldname": "issued_by", "fieldtype": "Link", "label": "صادرکننده (کارشناس مالی)", "options": "User", "read_only": 1},
  {"fieldname": "issued_on", "fieldtype": "Datetime", "label": "زمان صدور", "read_only": 1},
  {"fieldname": "cb_3", "fieldtype": "Column Break"},
  {"fieldname": "received_by_transport", "fieldtype": "Link", "label": "دریافت‌کننده در واحد حمل", "options": "User", "read_only": 1},
  {"fieldname": "received_on", "fieldtype": "Datetime", "label": "زمان دریافت توسط حمل", "read_only": 1},
  {"fieldname": "sales_invoice", "fieldtype": "Link", "label": "فاکتور فروش رسمی", "options": "Sales Invoice"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "توضیح"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Trade Sales Slip", "owner": "Administrator",
  "permissions": [
   {"create": 1, "delete": 1, "read": 1, "write": 1, "report": 1, "export": 1, "print": 1, "role": "System Manager"},
   {"create": 1, "read": 1, "write": 1, "report": 1, "print": 1, "role": "Finance User"},
   {"create": 1, "read": 1, "write": 1, "report": 1, "print": 1, "export": 1, "role": "Finance Supervisor"},
   {"read": 1, "write": 1, "report": 1, "role": "Transport Supervisor"},
   {"read": 1, "write": 1, "report": 1, "role": "Transport User - Purchase"},
   {"read": 1, "write": 1, "report": 1, "role": "Transport User - Sales"},
   {"read": 1, "report": 1, "role": "Financial Manager"},
   {"read": 1, "report": 1, "role": "CEO"},
   {"read": 1, "report": 1, "role": "Customs Officer"},
   {"read": 1, "report": 1, "role": "Treasury User"},
   {"read": 1, "report": 1, "role": "Receivables User"},
   {"read": 1, "report": 1, "role": "Legal Reviewer"}
  ],
  "sort_field": "modified", "sort_order": "DESC", "track_changes": 1
}
EOF
write_utf8 "${MOD}/doctype/trade_sales_slip/trade_sales_slip.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
ریزفاکتور فروش.

قاعده سازمانی صریح کارفرما:
  صدور ریزفاکتورهای فروش «کار واحد مالی» است (فائزه حیدری)، نه واحد حمل.
  واحد حمل فقط ریزفاکتور صادرشده را دریافت می‌کند و بر اساس آن بارگیری می‌سازد.
"""
import frappe
from frappe import _
from frappe.model.document import Document
from frappe.utils import flt, now_datetime, nowdate

from iran_trade_erp.iran_trade.utils import fx

ISSUER_ROLES = {"Finance User", "Finance Supervisor", "System Manager"}
TRANSPORT_ROLES = {"Transport Supervisor", "Transport User - Purchase",
                   "Transport User - Sales", "System Manager"}


class TradeSalesSlip(Document):
    def before_insert(self):
        roles = set(frappe.get_roles())
        if not roles.intersection(ISSUER_ROLES):
            frappe.throw(_(
                "صدور ریزفاکتور فروش فقط بر عهده واحد مالی است. "
                "واحد حمل اجازه صدور فاکتور ندارد."
            ))
        if not self.posting_date:
            self.posting_date = nowdate()
        self.issued_by = frappe.session.user
        self.issued_on = now_datetime()

    def validate(self):
        self._validate_source_row()
        self.amount = flt(flt(self.tonnage) * flt(self.price), 2)
        fx.apply_fx(self, posting_date=self.posting_date)

    def on_update(self):
        self._refresh_case_progress()

    def _validate_source_row(self):
        case = frappe.get_doc("Trade Case", self.purchase_case)
        # اصلاح: فیلتر زودهنگام نوع پرونده — برش فقط از پرونده خرید/ترکیبی مجاز است
        if case.case_type not in ("خرید", "ترکیبی"):
            frappe.throw(_(
                "ریزفاکتور فروش فقط از پروندهٔ «خرید» یا «ترکیبی» بریده می‌شود؛ "
                "پروندهٔ انتخابی از نوع «{0}» است."
            ).format(case.case_type))
        row = None
        for r in case.items or []:
            if r.name == self.trade_item_row:
                row = r
                break
        if not row:
            frappe.throw(_("ردیف کالای مبدأ در پرونده خرید یافت نشد."))
        if row.row_kind != "خرید":
            frappe.throw(_("ریزفاکتور فروش فقط از ردیف «خرید» بریده می‌شود."))
        self.item = row.item

        other = frappe.db.sql(
            """SELECT COALESCE(SUM(tonnage), 0) AS t FROM `tabTrade Sales Slip`
               WHERE trade_item_row=%s AND slip_status <> 'لغو شده' AND name <> %s""",
            (self.trade_item_row, self.name or ""), as_dict=True,
        )
        used = flt(other[0].t) if other else 0.0
        if used + flt(self.tonnage) > flt(row.tonnage) + 0.001:
            frappe.throw(_(
                "مجموع ریزفاکتورهای این ردیف ({0} تن) از تناژ ردیف کالا ({1} تن) بیشتر می‌شود."
            ).format(flt(used + flt(self.tonnage), 3), flt(row.tonnage, 3)))

    def _refresh_case_progress(self):
        if frappe.db.get_value("Trade Case", self.purchase_case, "fulfillment_status") == "در انتظار شروع":
            frappe.db.set_value("Trade Case", self.purchase_case, "fulfillment_status",
                                "در حال انجام", update_modified=False)


@frappe.whitelist()
def receive_by_transport(name):
    """واحد حمل ریزفاکتور صادرشده را «دریافت» می‌کند (نه اینکه بسازد)."""
    roles = set(frappe.get_roles())
    if not roles.intersection(TRANSPORT_ROLES):
        frappe.throw(_("فقط واحد حمل می‌تواند ریزفاکتور را دریافت کند."))
    d = frappe.get_doc("Trade Sales Slip", name)
    if d.slip_status != "صادرشده":
        frappe.throw(_("این ریزفاکتور قبلاً تحویل واحد حمل شده است."))
    d.slip_status = "تحویل واحد حمل شد"
    d.received_by_transport = frappe.session.user
    d.received_on = now_datetime()
    d.save()
    frappe.db.commit()
    return {"ok": True}


@frappe.whitelist()
def open_slips_for_transport(purchase_case=None):
    """فهرست ریزفاکتورهای آماده بارگیری برای واحد حمل."""
    if not frappe.has_permission("Trade Sales Slip", "read"):
        frappe.throw(_("دسترسی لازم را ندارید."))
    filters = {"slip_status": ["in", ["تحویل واحد حمل شد", "در حال بارگیری"]]}
    if purchase_case:
        filters["purchase_case"] = purchase_case
    return frappe.get_all(
        "Trade Sales Slip", filters=filters,
        fields=["name", "purchase_case", "item", "buyer", "tonnage", "price",
                "transaction_currency", "base_amount", "slip_status"],
        order_by="posting_date asc",
    )
EOF

# =============================================================================
step "2) پرداخت حمل (Child، چندارزی) و اسناد اقماری"
mk_dt transport_payment
write_utf8 "${MOD}/doctype/transport_payment/transport_payment.json" << 'EOF'
{
 "actions": [], "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType",
 "editable_grid": 1, "engine": "InnoDB", "istable": 1,
 "field_order": ["payment_type", "amount", "transaction_currency", "conversion_rate",
                 "base_amount", "payment_date", "sheba", "bank_name", "reference_no",
                 "paid_by", "notes"],
 "fields": [
  {"fieldname": "payment_type", "fieldtype": "Select", "in_list_view": 1, "label": "نوع پرداخت", "options": "پیش کرایه\nکرایه\nگمرک\nترخیص\nبیمه\nسایر", "reqd": 1, "columns": 2},
  {"default": "0", "fieldname": "amount", "fieldtype": "Float", "in_list_view": 1, "label": "مبلغ", "reqd": 1, "columns": 2},
  {"default": "IRR", "fieldname": "transaction_currency", "fieldtype": "Link", "in_list_view": 1, "label": "ارز", "options": "Currency", "reqd": 1, "columns": 1},
  {"fieldname": "conversion_rate", "fieldtype": "Float", "label": "نرخ تبدیل", "precision": "9", "read_only": 1},
  {"fieldname": "base_amount", "fieldtype": "Currency", "in_list_view": 1, "label": "مبلغ پایه", "read_only": 1, "columns": 2},
  {"fieldname": "payment_date", "fieldtype": "Date", "label": "تاریخ پرداخت"},
  {"fieldname": "sheba", "fieldtype": "Data", "label": "شماره شبا"},
  {"fieldname": "bank_name", "fieldtype": "Data", "label": "بانک"},
  {"fieldname": "reference_no", "fieldtype": "Data", "label": "شماره پیگیری"},
  {"fieldname": "paid_by", "fieldtype": "Link", "label": "پرداخت‌کننده", "options": "User"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "توضیح"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Transport Payment", "owner": "Administrator",
 "permissions": [], "sort_field": "modified", "sort_order": "DESC"
}
EOF
write_utf8 "${MOD}/doctype/transport_payment/transport_payment.py" << 'EOF'
# -*- coding: utf-8 -*-
from frappe.model.document import Document


class TransportPayment(Document):
    pass
EOF

# ---- Waybill / Weighbridge / Bijak / Clearance ------------------------------
mk_dt transport_waybill
write_utf8 "${MOD}/doctype/transport_waybill/transport_waybill.json" << 'EOF'
{
 "actions": [], "autoname": "naming_series:", "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType", "engine": "InnoDB", "is_submittable": 1,
 "field_order": ["naming_series", "loading", "waybill_number", "waybill_date", "cb_1",
                 "driver", "vehicle", "carrier", "sb_2", "origin", "destination", "border",
                 "cb_2", "item_name", "waybill_tonnage", "freight_amount", "insurance_amount",
                 "sb_3", "attachment", "notes", "amended_from"],
 "fields": [
  {"default": "WB-.YYYY.-.#####", "fieldname": "naming_series", "fieldtype": "Select", "hidden": 1, "label": "سری", "options": "WB-.YYYY.-.#####"},
  {"fieldname": "loading", "fieldtype": "Link", "in_list_view": 1, "label": "بارگیری", "options": "Trade Case Loading", "reqd": 1},
  {"bold": 1, "fieldname": "waybill_number", "fieldtype": "Data", "in_list_view": 1, "label": "شماره بارنامه", "reqd": 1},
  {"fieldname": "waybill_date", "fieldtype": "Date", "in_list_view": 1, "label": "تاریخ بارنامه", "reqd": 1},
  {"fieldname": "cb_1", "fieldtype": "Column Break"},
  {"fieldname": "driver", "fieldtype": "Link", "label": "راننده", "options": "Driver", "reqd": 1},
  {"fieldname": "vehicle", "fieldtype": "Link", "label": "خودرو", "options": "Vehicle"},
  {"fieldname": "carrier", "fieldtype": "Link", "label": "باربری", "options": "Carrier"},
  {"fieldname": "sb_2", "fieldtype": "Section Break", "label": "مسیر و بار"},
  {"fieldname": "origin", "fieldtype": "Data", "label": "مبدأ"},
  {"fieldname": "destination", "fieldtype": "Data", "label": "مقصد"},
  {"fieldname": "border", "fieldtype": "Link", "label": "مرز", "options": "Border"},
  {"fieldname": "cb_2", "fieldtype": "Column Break"},
  {"fieldname": "item_name", "fieldtype": "Data", "label": "شرح کالا"},
  {"description": "تناژ اعلامی بارنامه — هرگز جایگزین تناژ مؤثر بارگیری نمی‌شود", "fieldname": "waybill_tonnage", "fieldtype": "Float", "label": "تناژ بارنامه", "reqd": 1},
  {"default": "0", "fieldname": "freight_amount", "fieldtype": "Float", "label": "کرایه"},
  {"default": "0", "fieldname": "insurance_amount", "fieldtype": "Float", "label": "بیمه"},
  {"fieldname": "sb_3", "fieldtype": "Section Break", "label": "پیوست"},
  {"fieldname": "attachment", "fieldtype": "Attach", "label": "تصویر بارنامه"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "توضیح"},
  {"fieldname": "amended_from", "fieldtype": "Link", "hidden": 1, "label": "اصلاحیه از", "no_copy": 1, "options": "Transport Waybill", "print_hide": 1, "read_only": 1}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Transport Waybill", "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "read": 1, "write": 1, "submit": 1, "cancel": 1, "amend": 1, "report": 1, "export": 1, "print": 1, "role": "System Manager"},
  {"create": 1, "read": 1, "write": 1, "submit": 1, "cancel": 1, "amend": 1, "report": 1, "print": 1, "role": "Transport Supervisor"},
  {"create": 1, "read": 1, "write": 1, "submit": 1, "amend": 1, "report": 1, "print": 1, "role": "Transport User - Purchase"},
   {"create": 1, "read": 1, "write": 1, "submit": 1, "amend": 1, "report": 1, "print": 1, "role": "Transport User - Sales"},
   {"read": 1, "report": 1, "role": "Customs Officer"},
   {"read": 1, "report": 1, "role": "Finance Supervisor"},
   {"read": 1, "report": 1, "role": "Finance User"},
   {"read": 1, "report": 1, "role": "Financial Manager"},
   {"read": 1, "report": 1, "role": "Treasury User"},
   {"read": 1, "report": 1, "role": "Receivables User"},
   {"read": 1, "report": 1, "role": "CEO"}
  ],
  "sort_field": "modified", "sort_order": "DESC", "track_changes": 1
}
EOF
write_utf8 "${MOD}/doctype/transport_waybill/transport_waybill.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
from frappe import _
from frappe.model.document import Document
from frappe.utils import flt


class TransportWaybill(Document):
    def validate(self):
        if flt(self.waybill_tonnage) <= 0:
            frappe.throw(_("تناژ بارنامه باید بزرگ‌تر از صفر باشد."))
        for f, label in (("freight_amount", "کرایه"), ("insurance_amount", "بیمه")):
            if flt(self.get(f)) < 0:
                frappe.throw(_("{0} نمی‌تواند منفی باشد.").format(label))
        dup = frappe.db.exists("Transport Waybill", {
            "waybill_number": self.waybill_number,
            "docstatus": ["<", 2],
            "name": ["!=", self.name or ""],
        })
        if dup:
            frappe.throw(_("شماره بارنامه «{0}» قبلاً ثبت شده است.").format(self.waybill_number))

    def on_submit(self):
        """
        بارنامه فقط کرایه/بیمه و مشخصات راننده را منتقل می‌کند.
        ★ بارنامه هرگز تناژ مؤثر بارگیری را بازنویسی نمی‌کند
          (رفع BUG_F_WBT_FIELD_MISMATCH).
        """
        ld = frappe.get_doc("Trade Case Loading", self.loading)
        ld.waybill = self.name
        ld.waybill_number = self.waybill_number
        ld.waybill_tonnage = self.waybill_tonnage
        ld.driver = self.driver or ld.driver
        ld.vehicle = self.vehicle or ld.vehicle
        ld.carrier = self.carrier or ld.carrier
        ld.freight_cost = flt(self.freight_amount)
        ld.insurance_cost = flt(self.insurance_amount)
        ld.chk_waybill = 1
        ld.chk_driver = 1 if ld.driver else 0
        ld.save(ignore_permissions=True)
EOF

mk_dt transport_weighbridge
write_utf8 "${MOD}/doctype/transport_weighbridge/transport_weighbridge.json" << 'EOF'
{
 "actions": [], "autoname": "naming_series:", "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["naming_series", "loading", "posting_datetime", "plate_number", "cb_1",
                 "operator", "approval_status", "approved_by",
                 "sb_2", "weight_empty", "weight_full", "cb_2", "net_weight", "net_tonnage",
                 "sb_3", "attachment", "notes"],
 "fields": [
  {"default": "WGH-.YYYY.-.#####", "fieldname": "naming_series", "fieldtype": "Select", "hidden": 1, "label": "سری", "options": "WGH-.YYYY.-.#####"},
  {"fieldname": "loading", "fieldtype": "Link", "in_list_view": 1, "label": "بارگیری", "options": "Trade Case Loading", "reqd": 1},
  {"fieldname": "posting_datetime", "fieldtype": "Datetime", "label": "زمان توزین", "reqd": 1},
  {"fieldname": "plate_number", "fieldtype": "Data", "label": "پلاک"},
  {"fieldname": "cb_1", "fieldtype": "Column Break"},
  {"fieldname": "operator", "fieldtype": "Data", "label": "متصدی باسکول"},
  {"default": "ثبت‌شده", "fieldname": "approval_status", "fieldtype": "Select", "in_list_view": 1, "label": "وضعیت تایید", "options": "ثبت‌شده\nتاییدشده\nردشده", "reqd": 1},
  {"fieldname": "approved_by", "fieldtype": "Link", "label": "تاییدکننده", "options": "User", "read_only": 1},
  {"fieldname": "sb_2", "fieldtype": "Section Break", "label": "اوزان"},
  {"fieldname": "weight_empty", "fieldtype": "Float", "label": "وزن خالی (کیلوگرم)", "reqd": 1},
  {"fieldname": "weight_full", "fieldtype": "Float", "in_list_view": 1, "label": "وزن پر (کیلوگرم)", "reqd": 1},
  {"fieldname": "cb_2", "fieldtype": "Column Break"},
  {"fieldname": "net_weight", "fieldtype": "Float", "label": "وزن خالص (کیلوگرم)", "read_only": 1},
  {"fieldname": "net_tonnage", "fieldtype": "Float", "in_list_view": 1, "label": "تناژ خالص", "read_only": 1},
  {"fieldname": "sb_3", "fieldtype": "Section Break", "label": "پیوست"},
  {"fieldname": "attachment", "fieldtype": "Attach", "label": "قبض باسکول"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "توضیح"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Transport Weighbridge", "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "read": 1, "write": 1, "report": 1, "export": 1, "print": 1, "role": "System Manager"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "print": 1, "role": "Transport Supervisor"},
   {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Customs Officer"},
   {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Transport User - Purchase"},
   {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Transport User - Sales"},
   {"read": 1, "report": 1, "role": "Finance Supervisor"},
   {"read": 1, "report": 1, "role": "Finance User"},
   {"read": 1, "report": 1, "role": "Financial Manager"},
   {"read": 1, "report": 1, "role": "Treasury User"},
   {"read": 1, "report": 1, "role": "Receivables User"},
   {"read": 1, "report": 1, "role": "CEO"}
  ],
  "sort_field": "modified", "sort_order": "DESC", "track_changes": 1
}
EOF
write_utf8 "${MOD}/doctype/transport_weighbridge/transport_weighbridge.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
from frappe import _
from frappe.model.document import Document
from frappe.utils import flt


class TransportWeighbridge(Document):
    def validate(self):
        if flt(self.weight_full) <= flt(self.weight_empty):
            frappe.throw(_("وزن پر باید بیشتر از وزن خالی باشد."))
        self.net_weight = flt(flt(self.weight_full) - flt(self.weight_empty), 2)
        self.net_tonnage = flt(self.net_weight / 1000.0, 3)
        if self.approval_status == "تاییدشده" and not self.approved_by:
            self.approved_by = frappe.session.user

    def on_update(self):
        """فقط باسکول «تاییدشده» منبع تناژ مؤثر است."""
        if self.approval_status != "تاییدشده":
            return
        ld = frappe.get_doc("Trade Case Loading", self.loading)
        ld.weighbridge = self.name
        ld.weight_empty = self.weight_empty
        ld.weight_full = self.weight_full
        ld.weighbridge_tonnage = self.net_tonnage
        ld.chk_weighbridge = 1
        ld.save(ignore_permissions=True)
        try:
            from iran_trade_erp.iran_trade.notification.core import notify
            notify("loading.weighbridge_recorded", "Trade Case Loading", ld.name, {})
        except Exception:
            frappe.log_error(title="اعلان باسکول ارسال نشد", message=frappe.get_traceback())
EOF

for spec in "transport_bijak:Transport Bijak:BJK:بیجک" "transport_clearance:Transport Clearance:CLR:ترخیص"; do
  d="${spec%%:*}"; rest="${spec#*:}"; dt="${rest%%:*}"; rest="${rest#*:}"; pre="${rest%%:*}"; lbl="${rest#*:}"
  mk_dt "$d"
done

write_utf8 "${MOD}/doctype/transport_bijak/transport_bijak.json" << 'EOF'
{
 "actions": [], "autoname": "naming_series:", "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["naming_series", "loading", "needs_bijak", "cb_1", "bijak_number",
                 "declaration_number", "bijak_status", "sb_2", "bijak_attachment",
                 "declaration_attachment", "notes"],
 "fields": [
  {"default": "BJK-.YYYY.-.#####", "fieldname": "naming_series", "fieldtype": "Select", "hidden": 1, "label": "سری", "options": "BJK-.YYYY.-.#####"},
  {"fieldname": "loading", "fieldtype": "Link", "in_list_view": 1, "label": "بارگیری", "options": "Trade Case Loading", "reqd": 1},
  {"default": "بله", "fieldname": "needs_bijak", "fieldtype": "Select", "in_list_view": 1, "label": "نیاز به بیجک", "options": "بله\nخیر", "reqd": 1},
  {"fieldname": "cb_1", "fieldtype": "Column Break"},
  {"fieldname": "bijak_number", "fieldtype": "Data", "label": "شماره بیجک"},
  {"fieldname": "declaration_number", "fieldtype": "Data", "label": "شماره اظهارنامه"},
  {"default": "ثبت‌شده", "fieldname": "bijak_status", "fieldtype": "Select", "in_list_view": 1, "label": "وضعیت", "options": "ثبت‌شده\nتاییدشده\nبدون نیاز"},
  {"fieldname": "sb_2", "fieldtype": "Section Break", "label": "پیوست‌ها"},
  {"fieldname": "bijak_attachment", "fieldtype": "Attach", "label": "تصویر بیجک"},
  {"fieldname": "declaration_attachment", "fieldtype": "Attach", "label": "تصویر اظهارنامه"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "توضیح"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Transport Bijak", "owner": "Administrator",
  "permissions": [
   {"create": 1, "delete": 1, "read": 1, "write": 1, "report": 1, "export": 1, "role": "System Manager"},
   {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Customs Officer"},
   {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Transport Supervisor"},
   {"read": 1, "report": 1, "role": "Transport User - Purchase"},
   {"read": 1, "report": 1, "role": "Transport User - Sales"},
   {"read": 1, "report": 1, "role": "Finance Supervisor"},
   {"read": 1, "report": 1, "role": "Finance User"},
   {"read": 1, "report": 1, "role": "Financial Manager"},
   {"read": 1, "report": 1, "role": "Treasury User"},
   {"read": 1, "report": 1, "role": "Receivables User"},
   {"read": 1, "report": 1, "role": "CEO"}
  ],
  "sort_field": "modified", "sort_order": "DESC", "track_changes": 1
}
EOF
write_utf8 "${MOD}/doctype/transport_bijak/transport_bijak.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
from frappe import _
from frappe.model.document import Document


class TransportBijak(Document):
    def validate(self):
        if self.needs_bijak == "خیر":
            self.bijak_status = "بدون نیاز"
            return
        if not self.bijak_attachment or not self.declaration_attachment:
            frappe.throw(_("برای بیجک، پیوست بیجک و پیوست اظهارنامه هر دو الزامی است."))

    def on_update(self):
        ld = frappe.get_doc("Trade Case Loading", self.loading)
        ld.bijak = self.name
        ld.chk_bijak = 1 if self.bijak_status in ("تاییدشده", "بدون نیاز") else 0
        ld.save(ignore_permissions=True)
EOF

write_utf8 "${MOD}/doctype/transport_clearance/transport_clearance.json" << 'EOF'
{
 "actions": [], "autoname": "naming_series:", "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["naming_series", "loading", "clearance_status", "cb_1", "customs_broker",
                 "border_representative", "sb_2", "customs_cost", "clearance_cost",
                 "transaction_currency", "cb_2", "conversion_rate", "base_customs_cost",
                 "base_clearance_cost", "sb_3", "attachment", "notes"],
 "fields": [
  {"default": "CLR-.YYYY.-.#####", "fieldname": "naming_series", "fieldtype": "Select", "hidden": 1, "label": "سری", "options": "CLR-.YYYY.-.#####"},
  {"fieldname": "loading", "fieldtype": "Link", "in_list_view": 1, "label": "بارگیری", "options": "Trade Case Loading", "reqd": 1},
  {"default": "در جریان", "fieldname": "clearance_status", "fieldtype": "Select", "in_list_view": 1, "label": "وضعیت ترخیص", "options": "در جریان\nترخیص شد\nمتوقف", "reqd": 1},
  {"fieldname": "cb_1", "fieldtype": "Column Break"},
  {"fieldname": "customs_broker", "fieldtype": "Link", "label": "ترخیص‌کار", "options": "Customs Broker"},
  {"fieldname": "border_representative", "fieldtype": "Link", "label": "نماینده مرز", "options": "Border Representative"},
  {"fieldname": "sb_2", "fieldtype": "Section Break", "label": "هزینه‌ها (چندارزی رویدادی)"},
  {"default": "0", "fieldname": "customs_cost", "fieldtype": "Float", "label": "هزینه گمرک"},
  {"default": "0", "fieldname": "clearance_cost", "fieldtype": "Float", "label": "هزینه ترخیص"},
  {"default": "IRR", "fieldname": "transaction_currency", "fieldtype": "Link", "label": "ارز", "options": "Currency", "reqd": 1},
  {"fieldname": "cb_2", "fieldtype": "Column Break"},
  {"fieldname": "conversion_rate", "fieldtype": "Float", "label": "نرخ تبدیل", "precision": "9", "read_only": 1},
  {"fieldname": "base_customs_cost", "fieldtype": "Currency", "label": "گمرک (پایه)", "read_only": 1},
  {"fieldname": "base_clearance_cost", "fieldtype": "Currency", "label": "ترخیص (پایه)", "read_only": 1},
  {"fieldname": "sb_3", "fieldtype": "Section Break", "label": "پیوست"},
  {"fieldname": "attachment", "fieldtype": "Attach", "label": "سند ترخیص"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "توضیح"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Transport Clearance", "owner": "Administrator",
  "permissions": [
   {"create": 1, "delete": 1, "read": 1, "write": 1, "report": 1, "export": 1, "role": "System Manager"},
   {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Customs Officer"},
   {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Transport Supervisor"},
   {"read": 1, "report": 1, "role": "Transport User - Purchase"},
   {"read": 1, "report": 1, "role": "Transport User - Sales"},
   {"read": 1, "report": 1, "role": "Finance Supervisor"},
   {"read": 1, "report": 1, "role": "Finance User"},
   {"read": 1, "report": 1, "role": "Financial Manager"},
   {"read": 1, "report": 1, "role": "Treasury User"},
   {"read": 1, "report": 1, "role": "Receivables User"},
   {"read": 1, "report": 1, "role": "CEO"}
  ],
  "sort_field": "modified", "sort_order": "DESC", "track_changes": 1
}
EOF
write_utf8 "${MOD}/doctype/transport_clearance/transport_clearance.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
from frappe.model.document import Document
from frappe.utils import flt

from iran_trade_erp.iran_trade.utils import fx


class TransportClearance(Document):
    def validate(self):
        rate, source = fx.resolve_rate(self.transaction_currency or "IRR")
        self.conversion_rate = rate
        self.base_customs_cost = flt(flt(self.customs_cost) * rate, 2)
        self.base_clearance_cost = flt(flt(self.clearance_cost) * rate, 2)

    def on_update(self):
        ld = frappe.get_doc("Trade Case Loading", self.loading)
        ld.clearance = self.name
        ld.customs_broker = self.customs_broker
        ld.border_representative = self.border_representative
        ld.customs_cost = flt(self.customs_cost)
        ld.clearance_cost = flt(self.clearance_cost)
        ld.base_customs_cost = flt(self.base_customs_cost)
        ld.base_clearance_cost = flt(self.base_clearance_cost)
        ld.chk_clearance = 1 if self.clearance_status == "ترخیص شد" else 0
        ld.save(ignore_permissions=True)
        if self.clearance_status == "ترخیص شد":
            try:
                from iran_trade_erp.iran_trade.notification.core import notify
                notify("loading.cleared", "Trade Case Loading", ld.name, {})
            except Exception:
                frappe.log_error(title="اعلان ترخیص ارسال نشد", message=frappe.get_traceback())
EOF

log "اسناد اقماری حمل نوشته شدند"
echo "PART-1 OF SCRIPT-07 DONE"

# =============================================================================
step "3) Trade Case Loading — هر بارگیری/محموله + چک‌لیست ۱۰ قلمی"
mk_dt trade_case_loading
write_utf8 "${MOD}/doctype/trade_case_loading/trade_case_loading.json" << 'EOF'
{
 "actions": [], "autoname": "naming_series:", "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType", "engine": "InnoDB",
 "field_order": [
  "tab_main",
  "sb_1", "naming_series", "trade_case", "trade_item_row", "trade_item", "cb_1",
  "sales_slip", "buyer", "loading_state", "assigned_user", "sla_last_action_on",
  "sb_2", "planned_tonnage", "actual_tonnage", "weighbridge_tonnage", "cb_2",
  "waybill_tonnage", "effective_tonnage", "idempotency_key", "sla_escalation_level",
  "sb_3", "driver", "vehicle", "carrier", "cb_3", "customs_broker", "border_representative",
  "sb_4", "waybill", "waybill_number", "weighbridge", "cb_4", "bijak", "clearance",
  "weight_empty", "weight_full", "delivery_receipt", "delivery_date",

  "tab_money",
  "sb_5", "cost_currency", "cost_conversion_rate", "cb_5", "freight_cost", "customs_cost",
  "clearance_cost", "insurance_cost", "other_cost", "initial_costs",
  "sb_6", "base_freight_cost", "base_customs_cost", "base_clearance_cost", "cb_6",
  "base_insurance_cost", "base_other_cost", "base_initial_costs",
  "sb_7", "total_operational_cost", "total_settled", "cb_7", "settlement_balance",
  "sb_8", "payments",

  "tab_close",
  "sb_9", "chk_purchase", "chk_sales", "chk_driver", "chk_waybill", "chk_weighbridge",
  "cb_9", "chk_bijak", "chk_clearance", "chk_delivery", "chk_payments", "finance_approved",
  "sb_10", "manual_close_reason", "closure_remaining_snapshot", "cb_10", "closed_by_user", "closed_on"
 ],
 "fields": [
  {"fieldname": "tab_main", "fieldtype": "Tab Break", "label": "۱ - بارگیری و اسناد"},
  {"fieldname": "sb_1", "fieldtype": "Section Break", "label": "۱-۱ اطلاعات پایه"},
  {"default": "LD-.YYYY.-.#####", "fieldname": "naming_series", "fieldtype": "Select", "hidden": 1, "label": "سری", "options": "LD-.YYYY.-.#####"},
  {"fieldname": "trade_case", "fieldtype": "Link", "in_list_view": 1, "in_standard_filter": 1, "label": "پرونده بازرگانی", "options": "Trade Case", "reqd": 1},
  {"fieldname": "trade_item_row", "fieldtype": "Data", "label": "شناسه ردیف کالا", "reqd": 1},
  {"fieldname": "trade_item", "fieldtype": "Link", "in_list_view": 1, "label": "کالا", "options": "Item"},
  {"fieldname": "cb_1", "fieldtype": "Column Break"},
  {"description": "ریزفاکتور فروشی که واحد مالی صادر کرده و واحد حمل آن را دریافت کرده است", "fieldname": "sales_slip", "fieldtype": "Link", "label": "ریزفاکتور فروش", "options": "Trade Sales Slip"},
  {"fieldname": "buyer", "fieldtype": "Link", "label": "خریدار این بارگیری", "options": "Customer"},
  {"default": "ایجاد شده", "fieldname": "loading_state", "fieldtype": "Select", "in_list_view": 1, "in_standard_filter": 1, "label": "وضعیت بارگیری", "options": "ایجاد شده\nراننده تعیین شد\nبارنامه صادر شد\nباسکول ثبت شد\nبیجک ثبت شد\nترخیص شد\nتحویل شد\nپرداخت ثبت شد\nتکمیل شد\nبسته دستی\nلغو شده\nرد شده", "reqd": 1},
  {"fieldname": "assigned_user", "fieldtype": "Link", "label": "کارشناس مسئول", "options": "User"},
  {"fieldname": "sla_last_action_on", "fieldtype": "Datetime", "label": "آخرین اقدام واقعی", "read_only": 1},

  {"fieldname": "sb_2", "fieldtype": "Section Break", "label": "۱-۲ تناژ (رزرو در برابر واقعی)"},
  {"description": "ظرفیت رزروشده — هرگز «حمل‌شده» محسوب نمی‌شود", "fieldname": "planned_tonnage", "fieldtype": "Float", "in_list_view": 1, "label": "تناژ برنامه (رزرو)", "reqd": 1},
  {"fieldname": "actual_tonnage", "fieldtype": "Float", "label": "تناژ واقعی دستی"},
  {"fieldname": "weighbridge_tonnage", "fieldtype": "Float", "label": "تناژ باسکول تاییدشده", "read_only": 1},
  {"fieldname": "cb_2", "fieldtype": "Column Break"},
  {"fieldname": "waybill_tonnage", "fieldtype": "Float", "label": "تناژ بارنامه", "read_only": 1},
  {"description": "اولویت: باسکول تاییدشده > تناژ واقعی دستی > هرگز از تناژ برنامه", "fieldname": "effective_tonnage", "fieldtype": "Float", "in_list_view": 1, "label": "تناژ مؤثر", "read_only": 1},
  {"fieldname": "idempotency_key", "fieldtype": "Data", "label": "کلید یکتای عملیات", "read_only": 1},
  {"fieldname": "sla_escalation_level", "fieldtype": "Int", "label": "سطح تشدید", "read_only": 1},

  {"fieldname": "sb_3", "fieldtype": "Section Break", "label": "۱-۳ راننده و باربری"},
  {"fieldname": "driver", "fieldtype": "Link", "label": "راننده", "options": "Driver"},
  {"fieldname": "vehicle", "fieldtype": "Link", "label": "خودرو", "options": "Vehicle"},
  {"fieldname": "carrier", "fieldtype": "Link", "label": "باربری", "options": "Carrier"},
  {"fieldname": "cb_3", "fieldtype": "Column Break"},
  {"fieldname": "customs_broker", "fieldtype": "Link", "label": "ترخیص‌کار", "options": "Customs Broker"},
  {"fieldname": "border_representative", "fieldtype": "Link", "label": "نماینده مرز", "options": "Border Representative"},

  {"fieldname": "sb_4", "fieldtype": "Section Break", "label": "۱-۴ اسناد اقماری"},
  {"fieldname": "waybill", "fieldtype": "Link", "label": "بارنامه", "options": "Transport Waybill", "read_only": 1},
  {"fieldname": "waybill_number", "fieldtype": "Data", "label": "شماره بارنامه", "read_only": 1},
  {"fieldname": "weighbridge", "fieldtype": "Link", "label": "باسکول", "options": "Transport Weighbridge", "read_only": 1},
  {"fieldname": "cb_4", "fieldtype": "Column Break"},
  {"fieldname": "bijak", "fieldtype": "Link", "label": "بیجک", "options": "Transport Bijak", "read_only": 1},
  {"fieldname": "clearance", "fieldtype": "Link", "label": "ترخیص", "options": "Transport Clearance", "read_only": 1},
  {"fieldname": "weight_empty", "fieldtype": "Float", "label": "وزن خالی", "read_only": 1},
  {"fieldname": "weight_full", "fieldtype": "Float", "label": "وزن پر", "read_only": 1},
  {"fieldname": "delivery_receipt", "fieldtype": "Attach", "label": "رسید تخلیه"},
  {"fieldname": "delivery_date", "fieldtype": "Date", "label": "تاریخ تحویل"},

  {"fieldname": "tab_money", "fieldtype": "Tab Break", "label": "۲ - هزینه و تسویه"},
  {"fieldname": "sb_5", "fieldtype": "Section Break", "label": "۲-۱ هزینه‌های عملیاتی"},
  {"default": "IRR", "fieldname": "cost_currency", "fieldtype": "Link", "label": "ارز هزینه‌ها", "options": "Currency", "reqd": 1},
  {"fieldname": "cost_conversion_rate", "fieldtype": "Float", "label": "نرخ تبدیل هزینه", "precision": "9", "read_only": 1},
  {"fieldname": "cb_5", "fieldtype": "Column Break"},
  {"default": "0", "fieldname": "freight_cost", "fieldtype": "Float", "label": "کرایه"},
  {"default": "0", "fieldname": "customs_cost", "fieldtype": "Float", "label": "گمرک"},
  {"default": "0", "fieldname": "clearance_cost", "fieldtype": "Float", "label": "ترخیص"},
  {"default": "0", "fieldname": "insurance_cost", "fieldtype": "Float", "label": "بیمه"},
  {"default": "0", "fieldname": "other_cost", "fieldtype": "Float", "label": "سایر"},
  {"default": "0", "fieldname": "initial_costs", "fieldtype": "Float", "label": "هزینه اولیه"},

  {"fieldname": "sb_6", "fieldtype": "Section Break", "label": "۲-۲ معادل پایه ریالی"},
  {"fieldname": "base_freight_cost", "fieldtype": "Currency", "label": "کرایه (پایه)", "read_only": 1},
  {"fieldname": "base_customs_cost", "fieldtype": "Currency", "label": "گمرک (پایه)", "read_only": 1},
  {"fieldname": "base_clearance_cost", "fieldtype": "Currency", "label": "ترخیص (پایه)", "read_only": 1},
  {"fieldname": "cb_6", "fieldtype": "Column Break"},
  {"fieldname": "base_insurance_cost", "fieldtype": "Currency", "label": "بیمه (پایه)", "read_only": 1},
  {"fieldname": "base_other_cost", "fieldtype": "Currency", "label": "سایر (پایه)", "read_only": 1},
  {"fieldname": "base_initial_costs", "fieldtype": "Currency", "label": "هزینه اولیه (پایه)", "read_only": 1},

  {"fieldname": "sb_7", "fieldtype": "Section Break", "label": "۲-۳ جمع‌بندی (تک منبع حقیقت)"},
  {"fieldname": "total_operational_cost", "fieldtype": "Currency", "in_list_view": 1, "label": "بهای تمام‌شده عملیاتی", "read_only": 1},
  {"fieldname": "total_settled", "fieldtype": "Currency", "label": "جمع تسویه‌شده", "read_only": 1},
  {"fieldname": "cb_7", "fieldtype": "Column Break"},
  {"fieldname": "settlement_balance", "fieldtype": "Currency", "label": "مانده تسویه", "read_only": 1},
  {"fieldname": "sb_8", "fieldtype": "Section Break", "label": "۲-۴ پرداخت‌ها (تسویه، نه هزینه)"},
  {"fieldname": "payments", "fieldtype": "Table", "label": "پرداخت‌ها", "options": "Transport Payment"},

  {"fieldname": "tab_close", "fieldtype": "Tab Break", "label": "۳ - چک‌لیست و بستن"},
  {"fieldname": "sb_9", "fieldtype": "Section Break", "label": "۳-۱ چک‌لیست ۱۰ قلمی بستن"},
  {"default": "0", "fieldname": "chk_purchase", "fieldtype": "Check", "label": "۱ خرید"},
  {"default": "0", "fieldname": "chk_sales", "fieldtype": "Check", "label": "۲ فروش"},
  {"default": "0", "fieldname": "chk_driver", "fieldtype": "Check", "label": "۳ راننده"},
  {"default": "0", "fieldname": "chk_waybill", "fieldtype": "Check", "label": "۴ بارنامه"},
  {"default": "0", "fieldname": "chk_weighbridge", "fieldtype": "Check", "label": "۵ باسکول"},
  {"fieldname": "cb_9", "fieldtype": "Column Break"},
  {"default": "0", "fieldname": "chk_bijak", "fieldtype": "Check", "label": "۶ بیجک"},
  {"default": "0", "fieldname": "chk_clearance", "fieldtype": "Check", "label": "۷ ترخیص"},
  {"default": "0", "fieldname": "chk_delivery", "fieldtype": "Check", "label": "۸ رسید تخلیه"},
  {"default": "0", "fieldname": "chk_payments", "fieldtype": "Check", "label": "۹ پرداخت‌ها"},
  {"default": "0", "fieldname": "finance_approved", "fieldtype": "Check", "label": "۱۰ تایید مالی", "permlevel": 1},
  {"fieldname": "sb_10", "fieldtype": "Section Break", "label": "۳-۲ بستن دستی"},
  {"fieldname": "manual_close_reason", "fieldtype": "Small Text", "label": "دلیل بستن دستی"},
  {"fieldname": "closure_remaining_snapshot", "fieldtype": "Small Text", "label": "تصویر باقی‌مانده", "read_only": 1},
  {"fieldname": "cb_10", "fieldtype": "Column Break"},
  {"fieldname": "closed_by_user", "fieldtype": "Link", "label": "بسته‌شده توسط", "options": "User", "read_only": 1},
  {"fieldname": "closed_on", "fieldtype": "Datetime", "label": "زمان بستن", "read_only": 1}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Trade Case Loading", "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "read": 1, "write": 1, "report": 1, "export": 1, "print": 1, "share": 1, "role": "System Manager"},
  {"create": 1, "delete": 1, "read": 1, "write": 1, "report": 1, "export": 1, "print": 1, "role": "Transport Supervisor"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "print": 1, "role": "Transport User - Purchase"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "print": 1, "role": "Transport User - Sales"},
  {"read": 1, "write": 1, "report": 1, "role": "Customs Officer"},
  {"read": 1, "write": 1, "report": 1, "export": 1, "role": "Finance Supervisor"},
  {"read": 1, "report": 1, "role": "Finance User"},
  {"read": 1, "report": 1, "export": 1, "role": "Financial Manager"},
  {"read": 1, "report": 1, "role": "CEO"},
  {"permlevel": 1, "read": 1, "write": 1, "role": "Finance Supervisor"},
  {"permlevel": 1, "read": 1, "write": 1, "role": "Financial Manager"},
  {"permlevel": 1, "read": 1, "write": 1, "role": "System Manager"}
 ],
 "sort_field": "modified", "sort_order": "DESC", "track_changes": 1
}
EOF

write_utf8 "${MOD}/doctype/trade_case_loading/trade_case_loading.py" << 'EOF'
# -*- coding: utf-8 -*-
"""کنترلر بارگیری — یک موتور هزینه، یک موتور تناژ."""
import frappe
from frappe import _
from frappe.model.document import Document
from frappe.utils import flt, now_datetime

from iran_trade_erp.iran_trade.utils import fx
from iran_trade_erp.iran_trade.utils import money_engine as ME

CLOSED_STATES = ("تکمیل شد", "بسته دستی", "لغو شده", "رد شده")
CHECKLIST = ["chk_purchase", "chk_sales", "chk_driver", "chk_waybill", "chk_weighbridge",
             "chk_bijak", "chk_clearance", "chk_delivery", "chk_payments", "finance_approved"]


class TradeCaseLoading(Document):
    def before_insert(self):
        if not self.sla_last_action_on:
            self.sla_last_action_on = now_datetime()

    def validate(self):
        self._apply_cost_fx()
        self._compute_effective_tonnage()
        self._apply_money_model()
        self._auto_checklist()
        self._guard_close()

    def on_update(self):
        from iran_trade_erp.iran_trade.doctype.trade_case_loading.loading_engine import (
            recompute_case_progress,
        )
        recompute_case_progress(self.trade_case)

    # ------------------------------------------------------------------ money
    def _apply_cost_fx(self):
        rate, _src = fx.resolve_rate(self.cost_currency or "IRR")
        self.cost_conversion_rate = rate
        for src, base in ME.COST_FIELDS:
            self.set(base, flt(flt(self.get(src)) * rate, 2))
        for row in self.payments or []:
            row.amount = flt(row.amount)
            fx.apply_fx(row)

    def _apply_money_model(self):
        self.total_operational_cost = ME.operational_cost(self)
        self.total_settled = ME.settled_total(self)
        self.settlement_balance = flt(self.total_operational_cost - self.total_settled, 2)

    # --------------------------------------------------------------- tonnage
    def _compute_effective_tonnage(self):
        """اولویت صریح: باسکول تاییدشده > actual دستی > هرگز از planned."""
        if flt(self.weighbridge_tonnage) > 0:
            self.effective_tonnage = flt(self.weighbridge_tonnage, 3)
        elif flt(self.actual_tonnage) > 0:
            self.effective_tonnage = flt(self.actual_tonnage, 3)
        else:
            self.effective_tonnage = 0.0

    # ------------------------------------------------------------- checklist
    def _auto_checklist(self):
        self.chk_purchase = 1 if self.trade_case else 0
        self.chk_sales = 1 if self.sales_slip else 0
        self.chk_driver = 1 if self.driver else 0
        self.chk_waybill = 1 if self.waybill else 0
        self.chk_weighbridge = 1 if flt(self.weighbridge_tonnage) > 0 else 0
        self.chk_delivery = 1 if self.delivery_receipt else 0
        self.chk_payments = 1 if (self.payments and flt(self.total_settled) > 0) else 0

    def _guard_close(self):
        if self.loading_state != "تکمیل شد":
            return
        missing = [f for f in CHECKLIST if not self.get(f)]
        if missing:
            labels = {f: (self.meta.get_field(f).label or f) for f in missing}
            frappe.throw(_("بستن بارگیری ممکن نیست؛ موارد زیر تکمیل نشده‌اند: ")
                         + "، ".join(labels.values()))
        if flt(self.effective_tonnage) <= 0:
            frappe.throw(_("تناژ مؤثر باید بزرگ‌تر از صفر باشد (باسکول یا تناژ واقعی)."))
EOF

echo "PART-2 OF SCRIPT-07 DONE"

# =============================================================================
step "4) موتور اتمیک چندبارگیری (قفل تراکنشی + کلید یکتای عملیات)"
write_utf8 "${MOD}/doctype/trade_case_loading/loading_engine.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
موتور اتمیک چندبارگیری.

  reserved_tonnage = Σ planned_tonnage بارگیری‌های فعال   (رزرو ظرفیت)
  shipped_tonnage  = Σ effective_tonnage واقعی            (باسکول/actual)
  planned هرگز «حمل‌شده» محسوب نمی‌شود.
  باقی‌مانده = planned_total − max(reserved, shipped) و هرگز منفی نمی‌شود.

تراکنش ساخت:
  1) کنترل وضعیت پرونده (بسته/تکمیل ⇒ رد)
  2) کلید یکتای عملیات (اگر قبلاً ساخته شده، همان رکورد برمی‌گردد)
  3) SELECT ... FOR UPDATE روی پرونده و ردیف کالا
  4) کنترل اضافه‌بار ردیف و کل داخل همان تراکنش
  5) insert + commit؛ در هر خطا rollback کامل
"""
import hashlib

import frappe
from frappe import _
from frappe.utils import flt, now_datetime

ACTIVE_EXCLUDE = ("لغو شده", "رد شده")
BLOCKED_CASE_STATES = ("تکمیل‌شده", "بسته‌شده دستی")


def make_idempotency_key(trade_case, trade_item_row, tonnage, buyer, extra=""):
    raw = "|".join([trade_case or "", trade_item_row or "", str(flt(tonnage)),
                    buyer or "", extra or ""])
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:60]


def get_capacity(trade_case, trade_item_row=None, locked=False):
    """ظرفیت واقعی از پایگاه‌داده — در حالت locked با SELECT ... FOR UPDATE."""
    suffix = " FOR UPDATE" if locked else ""
    case_row = frappe.db.sql(
        "SELECT name, fulfillment_status FROM `tabTrade Case` WHERE name=%s" + suffix,
        (trade_case,), as_dict=True,
    )
    if not case_row:
        frappe.throw(_("پرونده بازرگانی یافت نشد."))

    items = frappe.db.sql(
        "SELECT name, item, tonnage, shipped_tonnage, row_kind "
        "FROM `tabTrade Case Item` WHERE parent=%s" + suffix,
        (trade_case,), as_dict=True,
    )
    loadings = frappe.db.sql(
        "SELECT name, trade_item_row, planned_tonnage, effective_tonnage, "
        "loading_state, sales_slip "
        "FROM `tabTrade Case Loading` WHERE trade_case=%s" + suffix,
        (trade_case,), as_dict=True,
    )
    active = [l for l in loadings if l.loading_state not in ACTIVE_EXCLUDE]

    per_row = {}
    for it in items:
        reserved = sum(flt(l.planned_tonnage) for l in active if l.trade_item_row == it.name)
        shipped = sum(flt(l.effective_tonnage) for l in active if l.trade_item_row == it.name)
        used = max(reserved, shipped)
        per_row[it.name] = {
            "item": it.item, "row_kind": it.row_kind,
            "planned": flt(it.tonnage), "reserved": flt(reserved, 3),
            "shipped": flt(shipped, 3),
            "remaining": max(0.0, flt(flt(it.tonnage) - used, 3)),
        }

    total_planned = sum(flt(i.tonnage) for i in items)
    total_reserved = sum(flt(l.planned_tonnage) for l in active)
    total_shipped = sum(flt(l.effective_tonnage) for l in active)
    # اصلاح مغایرت‌گیری ریزفاکتور↔بارگیری: تناژ رزروشدهٔ هر ریزفاکتور جدا شمرده می‌شود
    slip_reserved = {}
    for l in active:
        if l.sales_slip:
            slip_reserved[l.sales_slip] = flt(slip_reserved.get(l.sales_slip, 0.0)) + flt(l.planned_tonnage)
    out = {
        "case_status": case_row[0].fulfillment_status,
        "total_planned": flt(total_planned, 3),
        "total_reserved": flt(total_reserved, 3),
        "total_shipped": flt(total_shipped, 3),
        "total_remaining": max(0.0, flt(total_planned - max(total_reserved, total_shipped), 3)),
        "rows": per_row,
        "loading_count": len(active),
        "slip_reserved": slip_reserved,
    }
    if trade_item_row:
        out["row"] = per_row.get(trade_item_row)
    return out


@frappe.whitelist()
def create_loading(trade_case, trade_item_row, planned_tonnage, sales_slip=None,
                   buyer=None, idempotency_key=None, assigned_user=None):
    """ساخت اتمیک بارگیری."""
    roles = set(frappe.get_roles())
    if not roles.intersection({"Transport Supervisor", "Transport User - Purchase",
                               "Transport User - Sales", "System Manager"}):
        frappe.throw(_("فقط واحد حمل می‌تواند بارگیری ایجاد کند."))

    planned_tonnage = flt(planned_tonnage)
    if planned_tonnage <= 0:
        frappe.throw(_("تناژ بارگیری باید بزرگ‌تر از صفر باشد."))

    # اصلاح قاعدهٔ دلالی (غیرقابل دور زدن): هر بارگیری باید به یک ریزفاکتور
    # فروشِ «دریافت‌شده توسط حمل» متصل باشد — صدور فاکتور کار مالی است،
    # حمل فقط بر اساس ریزفاکتورِ دریافت‌شده بارگیری می‌سازد.
    if not sales_slip:
        frappe.throw(_(
            "ایجاد بارگیری بدون «ریزفاکتور فروش» مجاز نیست. "
            "ابتدا واحد مالی ریزفاکتور را صادر و واحد حمل آن را دریافت کند."
        ))

    key = idempotency_key or make_idempotency_key(trade_case, trade_item_row,
                                                  planned_tonnage, buyer)
    existing = frappe.db.get_value("Trade Case Loading", {"idempotency_key": key}, "name")
    if existing:
        return existing

    try:
        cap = get_capacity(trade_case, trade_item_row, locked=True)
        if cap["case_status"] in BLOCKED_CASE_STATES:
            frappe.throw(_("پرونده «{0}» است و بارگیری جدید نمی‌پذیرد.").format(cap["case_status"]))
        row = cap.get("row")
        if not row:
            frappe.throw(_("ردیف کالای انتخاب‌شده در این پرونده وجود ندارد."))
        if planned_tonnage > row["remaining"] + 0.001:
            frappe.throw(_("اضافه‌بار ردیف کالا: باقی‌مانده این ردیف {0} تن است.")
                         .format(row["remaining"]))
        if planned_tonnage > cap["total_remaining"] + 0.001:
            frappe.throw(_("اضافه‌بار کل پرونده: باقی‌مانده کل {0} تن است.")
                         .format(cap["total_remaining"]))

        slip = frappe.get_doc("Trade Sales Slip", sales_slip)
        if slip.purchase_case != trade_case:
            frappe.throw(_(
                "ریزفاکتور فروش «{0}» متعلق به پروندهٔ «{1}» است، نه پروندهٔ انتخاب‌شده."
            ).format(sales_slip, slip.purchase_case))
        st = slip.slip_status
        if st == "صادرشده":
            frappe.throw(_("ریزفاکتور فروش هنوز توسط واحد حمل «دریافت» نشده است."))
        if st in (None, "لغو شده"):
            frappe.throw(_("ریزفاکتور فروش معتبر نیست."))
        # اصلاح مغایرت‌گیری ریزفاکتور↔بارگیری: جمع بارگیری‌های همین ریزفاکتور
        # هرگز نباید از تناژ خود ریزفاکتور بیشتر شود (مستقل از ماندهٔ ردیف پرونده).
        slip_used = flt(cap.get("slip_reserved", {}).get(sales_slip, 0.0))
        if slip_used + planned_tonnage > flt(slip.tonnage) + 0.001:
            frappe.throw(_(
                "مجموع بارگیری‌های ریزفاکتور ({0} تن) با این بارگیری از تناژ خود "
                "ریزفاکتور ({1} تن) بیشتر می‌شود."
            ).format(flt(slip_used + planned_tonnage, 3), flt(slip.tonnage, 3)))

        d = frappe.new_doc("Trade Case Loading")
        d.trade_case = trade_case
        d.trade_item_row = trade_item_row
        d.trade_item = row["item"]
        d.planned_tonnage = planned_tonnage
        d.sales_slip = sales_slip
        d.buyer = buyer or (frappe.db.get_value("Trade Sales Slip", sales_slip, "buyer") if sales_slip else None)
        d.idempotency_key = key
        d.assigned_user = assigned_user or _pick_least_loaded_user(trade_case)
        d.loading_state = "ایجاد شده"
        d.insert()
        frappe.db.commit()
    except Exception:
        frappe.db.rollback()
        raise

    recompute_case_progress(trade_case)
    _notify_assignment(d)
    return d.name


def _pick_least_loaded_user(trade_case):
    """
    توزیع بار واقعی — نه «قدیمی‌ترین کاربر».
    نقش بر اساس نوع پرونده انتخاب می‌شود (خرید→کارتابل خرید، فروش→کارتابل فروش).
    """
    from iran_trade_erp.iran_trade.utils.naming_guard import users_with_role
    case_type = frappe.db.get_value("Trade Case", trade_case, "case_type")
    role = "Transport User - Purchase" if case_type == "خرید" else "Transport User - Sales"
    users = users_with_role(role) or users_with_role("Transport Supervisor")
    if not users:
        frappe.log_error(
            title="خطای پیکربندی: کارشناس حمل یافت نشد",
            message="هیچ کاربر فعالی با نقش «{0}» وجود ندارد.".format(role),
        )
        return None
    counts = []
    for u in users:
        c = frappe.db.count("Trade Case Loading",
                            {"assigned_user": u,
                             "loading_state": ["not in", list(ACTIVE_EXCLUDE) + ["تکمیل شد"]]})
        counts.append((c, u))
    counts.sort()
    return counts[0][1]


def _notify_assignment(doc):
    try:
        from iran_trade_erp.iran_trade.notification.core import notify
        notify("loading.assigned", doc.doctype, doc.name, {},
               recipients=[doc.assigned_user] if doc.assigned_user else None)
    except Exception:
        frappe.log_error(title="اعلان ارجاع بارگیری ارسال نشد", message=frappe.get_traceback())


def recompute_case_progress(trade_case):
    """به‌روزرسانی پیشرفت ردیف‌ها و پرونده — بدون تغییر ساعت SLA."""
    if not trade_case or not frappe.db.exists("Trade Case", trade_case):
        return
    cap = get_capacity(trade_case)
    for row_name, info in cap["rows"].items():
        frappe.db.set_value("Trade Case Item", row_name, {
            "shipped_tonnage": info["shipped"],
            "remaining_tonnage": info["remaining"],
        }, update_modified=False)

    status = frappe.db.get_value("Trade Case", trade_case, "fulfillment_status")
    if status not in BLOCKED_CASE_STATES and status != "در انتظار تأمین کالا":
        new_status = "تکمیل‌شده" if cap["total_remaining"] <= 0.001 and cap["total_shipped"] > 0 \
            else ("در حال انجام" if cap["total_shipped"] > 0 or cap["total_reserved"] > 0 else status)
        if new_status != status:
            frappe.db.set_value("Trade Case", trade_case, "fulfillment_status",
                                new_status, update_modified=False)

    # اصلاح وضعیت‌های مرده ریزفاکتور: چرخهٔ صادرشده → تحویل حمل → در حال بارگیری
    # → تکمیل‌شده حالا واقعاً جلو می‌رود (بر اساس تناژ مؤثر، نه تناژ برنامه).
    slip_names = {s for s in (cap.get("slip_reserved") or {})}
    slip_names |= {r.sales_slip for r in frappe.db.sql(
        "SELECT DISTINCT sales_slip FROM `tabTrade Case Loading` "
        "WHERE trade_case=%s AND sales_slip IS NOT NULL AND sales_slip<>''",
        (trade_case,), as_dict=True)}
    for slip_name in slip_names:
        _sync_slip_status(slip_name)

    frappe.publish_realtime("ite_case_progress", cap, doctype="Trade Case", docname=trade_case)


def _sync_slip_status(sales_slip):
    """وضعیت ریزفاکتور فقط از داده واقعی بارگیری‌ها محاسبه می‌شود — هرگز دستی."""
    if not sales_slip or not frappe.db.exists("Trade Sales Slip", sales_slip):
        return
    agg = frappe.db.sql(
        """SELECT COALESCE(SUM(planned_tonnage),0) AS p,
                  COALESCE(SUM(effective_tonnage),0) AS e
           FROM `tabTrade Case Loading`
           WHERE sales_slip=%s AND loading_state NOT IN ('لغو شده','رد شده')""",
        (sales_slip,), as_dict=True)[0]
    slip_tonnage = flt(frappe.db.get_value("Trade Sales Slip", sales_slip, "tonnage"))
    if agg.e and flt(agg.e) >= slip_tonnage - 0.001:
        new_status = "تکمیل‌شده"
    elif agg.p:
        new_status = "در حال بارگیری"
    else:
        new_status = "تحویل واحد حمل شد"
    if frappe.db.get_value("Trade Sales Slip", sales_slip, "slip_status") != new_status:
        frappe.db.set_value("Trade Sales Slip", sales_slip, "slip_status",
                            new_status, update_modified=False)


@frappe.whitelist()
def get_case_rows(trade_case):
    """ردیف‌های کالای یک پرونده — برای انتخاب انسانی ردیف در فرم (نه تایپ هش)."""
    if not frappe.has_permission("Trade Case", "read", doc=trade_case):
        frappe.throw(_("دسترسی لازم را ندارید."))
    rows = frappe.get_all("Trade Case Item",
                          filters={"parenttype": "Trade Case", "parent": trade_case},
                          fields=["name", "item", "item_name", "row_kind", "tonnage",
                                  "shipped_tonnage", "remaining_tonnage"],
                          order_by="idx asc")
    return rows


@frappe.whitelist()
def manual_close_loading(name, reason):
    """بستن دستی بارگیری — فقط سرپرست حمل، با دلیل اجباری و حفظ Snapshot."""
    import json
    roles = set(frappe.get_roles())
    if not roles.intersection({"Transport Supervisor", "System Manager"}):
        frappe.throw(_("فقط سرپرست حمل می‌تواند بارگیری را دستی ببندد."))
    if not (reason or "").strip():
        frappe.throw(_("ثبت «دلیل بستن دستی» الزامی است."))
    d = frappe.get_doc("Trade Case Loading", name)
    cap = get_capacity(d.trade_case, d.trade_item_row)
    d.closure_remaining_snapshot = json.dumps(cap.get("row") or {}, ensure_ascii=False)
    d.manual_close_reason = reason
    d.closed_by_user = frappe.session.user
    d.closed_on = now_datetime()
    d.loading_state = "بسته دستی"
    d.save()
    frappe.db.commit()
    recompute_case_progress(d.trade_case)
    return {"ok": True, "snapshot": d.closure_remaining_snapshot}


def on_loading_change(doc, method=None):
    """لغو/رد/حذف بارگیری ⇒ آزادسازی ظرفیت رزروشده."""
    recompute_case_progress(doc.trade_case)


@frappe.whitelist()
def get_case_capacity(trade_case):
    if not frappe.has_permission("Trade Case", "read", doc=trade_case):
        frappe.throw(_("دسترسی لازم را ندارید."))
    return get_capacity(trade_case)
EOF

write_utf8 "${MOD}/doctype/trade_case_loading/install_index.py" << 'EOF'
# -*- coding: utf-8 -*-
"""ایندکس یکتای واقعی روی کلید عملیات — جلوگیری قطعی از ثبت دوباره."""
import frappe

INDEX_NAME = "uq_ite_loading_idem_key"


def ensure_unique_index():
    r = frappe.db.sql(
        """SELECT COUNT(1) FROM information_schema.statistics
           WHERE table_schema=DATABASE() AND table_name='tabTrade Case Loading'
             AND index_name=%s""", (INDEX_NAME,))
    if r and r[0][0]:
        return "already exists"
    dups = frappe.db.sql(
        """SELECT idempotency_key FROM `tabTrade Case Loading`
           WHERE idempotency_key IS NOT NULL AND idempotency_key <> ''
           GROUP BY idempotency_key HAVING COUNT(*)>1""")
    if dups:
        frappe.log_error(title="کلید عملیات تکراری پیش از ساخت نمایه",
                         message="تعداد: {0}".format(len(dups)))
        return "aborted: duplicates"
    frappe.db.sql("ALTER TABLE `tabTrade Case Loading` "
                  "ADD UNIQUE INDEX `{0}` (`idempotency_key`)".format(INDEX_NAME))
    frappe.db.commit()
    return "created"


def has_unique_index():
    r = frappe.db.sql(
        """SELECT COUNT(1) FROM information_schema.statistics
           WHERE table_schema=DATABASE() AND table_name='tabTrade Case Loading'
             AND index_name=%s""", (INDEX_NAME,))
    return bool(r and r[0][0])
EOF

# =============================================================================
step "5) hooks (SCRIPT07) + ترجمه‌ها"
python3 - "$PKG" << 'PYEOF'
import io, os, re, sys
pkg = sys.argv[1]
p = os.path.join(pkg, "hooks.py")
src = io.open(p, encoding="utf-8").read()
if "# --- SCRIPT06_HOOKS_START ---" not in src:
    raise SystemExit("ABORT: anchor SCRIPT06 missing")
S, E = "# --- SCRIPT07_HOOKS_START ---", "# --- SCRIPT07_HOOKS_END ---"
src = re.sub(re.escape(S) + r".*?" + re.escape(E), "", src, flags=re.S)
block = S + '''
_ite_ev2 = globals().get("doc_events", {}) or {}
_ite_ev2.setdefault("Trade Case Loading", {})
for _evt in ("on_trash", "on_cancel"):
    _fn = "iran_trade_erp.iran_trade.doctype.trade_case_loading.loading_engine.on_loading_change"
    _cur = _ite_ev2["Trade Case Loading"].get(_evt)
    if _cur is None:
        _ite_ev2["Trade Case Loading"][_evt] = _fn
    elif isinstance(_cur, list):
        if _fn not in _cur:
            _cur.append(_fn)
    elif _cur != _fn:
        _ite_ev2["Trade Case Loading"][_evt] = [_cur, _fn]
doc_events = _ite_ev2
''' + E + "\n"
io.open(p, "w", encoding="utf-8").write(src.rstrip() + "\n\n" + block)

t = os.path.join(pkg, "translations", "fa.csv")
rows = ["Trade Sales Slip,ریزفاکتور فروش,", "Trade Case Loading,بارگیری پرونده,",
        "Transport Waybill,بارنامه,", "Transport Weighbridge,باسکول,",
        "Transport Bijak,بیجک,", "Transport Clearance,ترخیص,",
        "Transport Payment,پرداخت حمل,"]
cur = io.open(t, encoding="utf-8").read() if os.path.exists(t) else ""
have = set(l.split(",")[0] for l in cur.splitlines() if l.strip())
add = [r for r in rows if r.split(",")[0] not in have]
if add:
    io.open(t, "a", encoding="utf-8").write("\n".join(add) + "\n")
print("SCRIPT07 hooks + fa.csv ok")
PYEOF

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" execute iran_trade_erp.iran_trade.doctype.trade_case_loading.install_index.ensure_unique_index
bench --site "$SITE_NAME" clear-cache

# =============================================================================
step "6) Verify داخلی — سناریوی واقعی ۱۰۰ تن = ۳۰+۲۵+۲۰+۲۵"
write_utf8 "${PKG}/verify_script07.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
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


def _ensure_customer_group():
    """Customer Group برگ — بدون فرض «All Customer Groups»."""
    leaf = frappe.db.get_value("Customer Group", {"is_group": 0}, "name")
    if leaf:
        return leaf
    any_g = frappe.db.get_value("Customer Group", {}, "name")
    if any_g:
        return any_g
    root_name = "All Customer Groups"
    if not frappe.db.exists("Customer Group", root_name):
        root = frappe.get_doc({
            "doctype": "Customer Group",
            "customer_group_name": root_name,
            "is_group": 1,
        })
        root.flags.ignore_permissions = True
        root.flags.ignore_mandatory = True
        try:
            root.insert(ignore_permissions=True)
        except Exception:
            pass
        frappe.db.commit()
    child_name = "Commercial"
    if not frappe.db.exists("Customer Group", child_name):
        child = frappe.get_doc({
            "doctype": "Customer Group",
            "customer_group_name": child_name,
            "is_group": 0,
            "parent_customer_group": root_name if frappe.db.exists("Customer Group", root_name) else None,
        })
        child.flags.ignore_permissions = True
        child.flags.ignore_mandatory = True
        child.insert(ignore_permissions=True)
        frappe.db.commit()
        return child_name
    return frappe.db.get_value("Customer Group", {}, "name")


def _ensure_territory():
    """Territory برگ — بدون فرض «All Territories»."""
    leaf = frappe.db.get_value("Territory", {"is_group": 0}, "name")
    if leaf:
        return leaf
    any_t = frappe.db.get_value("Territory", {}, "name")
    if any_t:
        return any_t
    root_name = "All Territories"
    if not frappe.db.exists("Territory", root_name):
        root = frappe.get_doc({
            "doctype": "Territory",
            "territory_name": root_name,
            "is_group": 1,
        })
        root.flags.ignore_permissions = True
        root.flags.ignore_mandatory = True
        try:
            root.insert(ignore_permissions=True)
        except Exception:
            pass
        frappe.db.commit()
    child_name = "Iran"
    if not frappe.db.exists("Territory", child_name):
        child = frappe.get_doc({
            "doctype": "Territory",
            "territory_name": child_name,
            "is_group": 0,
            "parent_territory": root_name if frappe.db.exists("Territory", root_name) else None,
        })
        child.flags.ignore_permissions = True
        child.flags.ignore_mandatory = True
        child.insert(ignore_permissions=True)
        frappe.db.commit()
        return child_name
    return frappe.db.get_value("Territory", {}, "name")


def _customer():
    n = "مشتری آزمایشی"
    if frappe.db.exists("Customer", n):
        return n
    group = _ensure_customer_group()
    territory = _ensure_territory()
    c = frappe.new_doc("Customer")
    c.customer_name = n
    c.customer_group = group
    c.territory = territory
    c.flags.ignore_permissions = True
    c.flags.ignore_mandatory = True
    c.insert(ignore_permissions=True)
    frappe.db.commit()
    return n


def _driver():
    """Driver را با name واقعی پس از insert برمی‌گرداند (نه لزوماً full_name)."""
    label = "راننده آزمایشی"
    existing = frappe.db.get_value("Driver", {"full_name": label}, "name")
    if existing:
        return existing
    if frappe.db.exists("Driver", label):
        return label
    d = frappe.new_doc("Driver")
    d.full_name = label
    if d.meta.has_field("ite_nationality"):
        d.ite_nationality = "ایرانی"
    d.flags.ignore_permissions = True
    d.flags.ignore_mandatory = True
    d.insert(ignore_permissions=True)
    frappe.db.commit()
    return d.name


def run():
    passed = failed = 0

    def chk(t, c):
        nonlocal passed, failed
        if c:
            passed += 1; print("  [PASS] " + t)
        else:
            failed += 1; print("  [FAIL] " + t)

    frappe.set_user("Administrator")
    from iran_trade_erp.iran_trade.doctype.trade_case_loading import loading_engine as LE
    from iran_trade_erp.iran_trade.doctype.trade_case_loading import install_index

    for dt in ("Trade Sales Slip", "Trade Case Loading", "Transport Waybill",
               "Transport Weighbridge", "Transport Bijak", "Transport Clearance",
               "Transport Payment"):
        chk("DocType ساخته شد: " + dt, frappe.db.count("DocType", {"name": dt}) == 1)

    chk("نمایه یکتای واقعی روی کلید عملیات وجود دارد", install_index.has_unique_index())

    meta = frappe.get_meta("Trade Case Loading")
    for f in ("chk_purchase", "chk_sales", "chk_driver", "chk_waybill", "chk_weighbridge",
              "chk_bijak", "chk_clearance", "chk_delivery", "chk_payments", "finance_approved"):
        chk("فیلد واقعی چک‌لیست وجود دارد: " + f, meta.has_field(f))
    chk("finance_approved دارای permlevel=1 است",
        meta.get_field("finance_approved").permlevel == 1)

    # --- پرونده ۱۰۰ تنی ---
    case = frappe.new_doc("Trade Case")
    case.case_title = "پرونده بارگیری آزمایشی"; case.case_type = "خرید"
    case.requested_by = _ceo(); case.company = frappe.db.get_value("Company", {}, "name")
    case.posting_date = nowdate()
    case.append("items", {"row_kind": "خرید", "item": _item(), "tonnage": 100,
                          "price": 10000000, "transaction_currency": "IRR"})
    case.flags.ignore_permissions = True
    case.insert(ignore_permissions=True)
    frappe.db.commit()
    row = case.items[0].name

    # ریزفاکتور فروش — فقط مالی می‌سازد
    slip = frappe.new_doc("Trade Sales Slip")
    slip.purchase_case = case.name; slip.trade_item_row = row
    slip.buyer = _customer(); slip.tonnage = 30; slip.price = 12000000
    slip.transaction_currency = "IRR"; slip.posting_date = nowdate()
    slip.flags.ignore_permissions = True
    slip.insert(ignore_permissions=True)
    frappe.db.commit()
    chk("★ ریزفاکتور فروش توسط واحد مالی صادر شد", slip.slip_status == "صادرشده")
    chk("مبلغ پایه ریزفاکتور محاسبه شد", flt(slip.base_amount) == 360000000.0)

    blocked = False
    try:
        LE.create_loading(case.name, row, 30, sales_slip=slip.name)
    except Exception as e:
        blocked = "دریافت" in str(e)
    chk("★ بارگیری پیش از «دریافت» ریزفاکتور توسط حمل مسدود است", blocked)

    from iran_trade_erp.iran_trade.doctype.trade_sales_slip.trade_sales_slip import receive_by_transport
    receive_by_transport(slip.name)
    chk("★ واحد حمل ریزفاکتور را دریافت کرد (نه اینکه بسازد)",
        frappe.db.get_value("Trade Sales Slip", slip.name, "slip_status") == "تحویل واحد حمل شد")

    # سناریوی ۳۰+۲۵+۲۰+۲۵ — هر بارگیری با ریزفاکتورِ دریافتی خودش (قاعدهٔ دلالی)
    def _new_received_slip(tonnage):
        s2 = frappe.new_doc("Trade Sales Slip")
        s2.purchase_case = case.name; s2.trade_item_row = row
        s2.buyer = _customer(); s2.tonnage = tonnage; s2.price = 12000000
        s2.transaction_currency = "IRR"; s2.posting_date = nowdate()
        s2.flags.ignore_permissions = True
        s2.insert(ignore_permissions=True)
        receive_by_transport(s2.name)
        return s2.name

    # سناریوی منفی جدید: بارگیری بدون ریزفاکتور مسدود است (قاعده قابل دور زدن نیست)
    blocked = False
    try:
        LE.create_loading(case.name, row, 30, idempotency_key="T-NOSLIP")
    except Exception:
        blocked = True
    chk("★ بارگیری بدون ریزفاکتور فروش مسدود است (سناریوی منفی)", blocked)

    slip_b = _new_received_slip(25)
    slip_c = _new_received_slip(20)
    slip_d = _new_received_slip(25)
    l1 = LE.create_loading(case.name, row, 30, sales_slip=slip.name, idempotency_key="T-A")
    l2 = LE.create_loading(case.name, row, 25, sales_slip=slip_b, idempotency_key="T-B")
    l3 = LE.create_loading(case.name, row, 20, sales_slip=slip_c, idempotency_key="T-C")
    chk("سه بارگیری ساخته شد", len({l1, l2, l3}) == 3)

    chk("★ وضعیت ریزفاکتور ۳۰ تنی پس از بارگیری «در حال بارگیری» شد",
        frappe.db.get_value("Trade Sales Slip", slip.name, "slip_status") == "در حال بارگیری")

    # سناریوی منفی جدید: مغایرت ریزفاکتور↔بارگیری (۲۶ تن روی ریزفاکتور ۲۵ تنی)
    blocked = False
    try:
        LE.create_loading(case.name, row, 26, sales_slip=slip_b, idempotency_key="T-OVERSLIP")
    except Exception:
        blocked = True
    chk("★ جمع بارگیری‌ها نمی‌تواند از تناژ خود ریزفاکتور بیشتر شود (سناریوی منفی)", blocked)

    same = LE.create_loading(case.name, row, 30, sales_slip=slip.name, idempotency_key="T-A")
    chk("کلید یکتای عملیات از ثبت دوباره جلوگیری می‌کند", same == l1)

    cap = LE.get_capacity(case.name, row)
    chk("رزرو = ۷۵ تن", flt(cap["total_reserved"]) == 75.0)
    chk("حمل‌شده هنوز صفر است (planned هرگز حمل‌شده نیست)", flt(cap["total_shipped"]) == 0.0)
    chk("باقی‌مانده = ۲۵ تن", flt(cap["total_remaining"]) == 25.0)

    blocked = False
    try:
        LE.create_loading(case.name, row, 30, sales_slip=slip_d, idempotency_key="T-OVER")
    except Exception:
        blocked = True
    chk("اضافه‌بار ردیف کالا مسدود است (سناریوی منفی)", blocked)

    l4 = LE.create_loading(case.name, row, 25, sales_slip=slip_d, idempotency_key="T-D")
    cap = LE.get_capacity(case.name, row)
    chk("پس از بار چهارم، باقی‌مانده صفر است", flt(cap["total_remaining"]) == 0.0)

    # باسکول ⇒ تناژ مؤثر
    wb = frappe.new_doc("Transport Weighbridge")
    wb.loading = l1; wb.posting_datetime = frappe.utils.now_datetime()
    wb.weight_empty = 12000; wb.weight_full = 41000
    wb.approval_status = "تاییدشده"
    wb.flags.ignore_permissions = True
    wb.insert(ignore_permissions=True)
    frappe.db.commit()
    ld1 = frappe.get_doc("Trade Case Loading", l1)
    chk("تناژ مؤثر از باسکول تاییدشده گرفته شد (۲۹ تن)", flt(ld1.effective_tonnage) == 29.0)
    # چرخهٔ عمر ریزفاکتور: ۲۹ تن مؤثر هنوز کمتر از ۳۰ تن ریزفاکتور است
    chk("★ ریزفاکتور پیش از تکمیل تناژ، «تکمیل‌شده» نمی‌شود",
        frappe.db.get_value("Trade Sales Slip", slip.name, "slip_status") == "در حال بارگیری")

    # بارنامه نباید تناژ مؤثر را بازنویسی کند
    drv = _driver()
    wbill = frappe.new_doc("Transport Waybill")
    wbill.loading = l1; wbill.waybill_number = "WB-TEST-001"
    wbill.waybill_date = nowdate(); wbill.driver = drv
    wbill.waybill_tonnage = 30; wbill.freight_amount = 450000000
    wbill.insurance_amount = 50000000
    wbill.flags.ignore_permissions = True
    wbill.insert(ignore_permissions=True); wbill.submit()
    frappe.db.commit()
    ld1.reload()
    chk("★ بارنامه تناژ مؤثر را بازنویسی نکرد", flt(ld1.effective_tonnage) == 29.0)
    chk("تناژ بارنامه در فیلد جدا ذخیره شد", flt(ld1.waybill_tonnage) == 30.0)

    dup = False
    try:
        w2 = frappe.new_doc("Transport Waybill")
        w2.loading = l2; w2.waybill_number = "WB-TEST-001"
        w2.waybill_date = nowdate(); w2.driver = drv; w2.waybill_tonnage = 25
        w2.flags.ignore_permissions = True; w2.insert(ignore_permissions=True)
    except Exception:
        dup = True
    chk("شماره بارنامه تکراری مسدود است", dup)

    # --- مدل مالی: پرداخت هرگز هزینه نیست ---
    ld1.reload()
    ld1.other_cost = 100000000
    ld1.append("payments", {"payment_type": "کرایه", "amount": 450000000,
                            "transaction_currency": "IRR", "payment_date": nowdate()})
    ld1.flags.ignore_permissions = True
    ld1.save(ignore_permissions=True)
    frappe.db.commit()
    ld1.reload()
    expected_cost = 450000000 + 50000000 + 100000000
    chk("بهای تمام‌شده عملیاتی = کرایه+بیمه+سایر (پرداخت شمرده نشد)",
        flt(ld1.total_operational_cost) == float(expected_cost))
    chk("جمع تسویه جدا محاسبه شد", flt(ld1.total_settled) == 450000000.0)
    chk("مانده تسویه درست است",
        flt(ld1.settlement_balance) == float(expected_cost) - 450000000.0)

    # گارد بستن با چک‌لیست ناقص
    blocked = False
    try:
        ld1.loading_state = "تکمیل شد"
        ld1.flags.ignore_permissions = True
        ld1.save(ignore_permissions=True)
    except Exception:
        blocked = True
    chk("بستن بارگیری با چک‌لیست ناقص مسدود است (سناریوی منفی)", blocked)

    # لغو ⇒ آزادسازی ظرفیت
    ld4 = frappe.get_doc("Trade Case Loading", l4)
    ld4.loading_state = "لغو شده"
    ld4.flags.ignore_permissions = True
    ld4.save(ignore_permissions=True)
    frappe.db.commit()
    cap = LE.get_capacity(case.name, row)
    chk("لغو بارگیری ظرفیت را آزاد کرد", flt(cap["total_remaining"]) == 25.0)
    chk("باقی‌مانده هرگز منفی نمی‌شود", cap["total_remaining"] >= 0)

    print("\n  Passed: %d | Failed: %d" % (passed, failed))
    if failed:
        raise Exception("verify_script07 FAILED: %d" % failed)
    return "OK"
EOF

bench --site "$SITE_NAME" execute iran_trade_erp.verify_script07.run

cat <<FINAL

============================================================
 script-07.sh با موفقیت تمام شد
------------------------------------------------------------
 ★ ریزفاکتور فروش : صدور فقط توسط مالی | دریافت توسط حمل
 بارگیری          : موتور اتمیک + FOR UPDATE + کلید یکتای واقعی
 تناژ             : رزرو ≠ حمل‌شده | باسکول > actual > هرگز planned
 مالی             : پرداخت «تسویه» است نه «هزینه» — یک فرمول
 چک‌لیست          : ۱۰ فیلد واقعی + permlevel روی تایید مالی
 گام بعدی         : bash script-08.sh
============================================================
FINAL