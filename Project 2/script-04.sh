#!/usr/bin/env bash
# =============================================================================
# script-04.sh — هسته دامنه: پرونده بازرگانی، اقلام، میز مدیرعامل، موتور واحد مالی
# بازسازی هدایت‌شده — Iran Trade ERP | ERPNext v15 / Frappe v15
# -----------------------------------------------------------------------------
# این اسکریپت هسته کسب‌وکار را از صفر و مینیمال می‌سازد:
#   1) Trade Case  — پرونده بازرگانی، ~۳۲ فیلد سطح سند، چهار تب شماره‌دار
#      * requested_by = مدیرعامل دستوردهنده (فیلد دائمی، الزامی)
#      * case_type = خرید / فروش / ترکیبی (دلالی)  ← شرکت دلال است نه انباردار
#      * fulfillment_status شامل «در انتظار تأمین کالا» (وضعیت رسمی)
#      * source_doctype/source_document/source_detail_row (Dynamic Link)
#      * linked_purchase_case / linked_sales_case (دوطرفه، با اعتبارسنجی نوع)
#      * sales_invoice / purchase_invoice / payment_entry = Link واقعی ERPNext
#   2) Trade Case Item — چندکالایی با بلوک FX هر ردیف + shipped/remaining
#   3) CEO Request — میز مدیرعامل (مسیر دیجیتال مکمل مسیر تلفنی/حضوری)
#   4) موتور واحد هزینه و سود (به‌جای سه فرمول متناقض)
#      total_operational_cost = کرایه+گمرک+ترخیص+بیمه+سایر+اولیه
#      total_settled          = جمع پرداخت‌ها (تسویه است، نه هزینه)
#      settlement_balance     = هزینه − تسویه
#      estimated_profit       = فروش − خرید − هزینه عملیاتی
#      پرداخت‌ها هرگز دوباره به‌عنوان هزینه شمرده نمی‌شوند.
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
else nohup bench start >>/tmp/bench-start-itc04.log 2>&1 & log "pid=$!"; sleep 12; fi
RC="${BENCH_DIR}/config/redis_cache.conf"
RP="$( [[ -f "$RC" ]] && awk '$1=="port"{print $2; exit}' "$RC" || echo 13000 )"; [[ -n "$RP" ]] || RP=13000
R=0; for _i in $(seq 1 60); do
  if command -v redis-cli >/dev/null 2>&1 && redis-cli -h 127.0.0.1 -p "$RP" ping 2>/dev/null | grep -q '^PONG$'; then R=1; break; fi
  if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ":${RP}[[:space:]]"; then R=1; break; fi
  sleep 1; done
[[ "$R" -eq 1 ]] || err "redis آماده نشد"
bench use "$SITE_NAME" 2>/dev/null || true

step "0b) پیش‌نیاز — ABORT در نبود Anchor"
[[ -f "${MOD}/utils/fx.py" ]] || err "ABORT: fx.py نیست. ابتدا script-03.sh"
[[ -f "${MOD}/utils/naming_guard.py" ]] || err "ABORT: naming_guard.py نیست. script-02"
grep -q "SCRIPT03_HOOKS_START" "${PKG}/hooks.py" || err "ABORT: بلوک SCRIPT03 در hooks.py نیست"
log "پیش‌نیازها تایید شد"

mk_dt() { mkdir -p "${MOD}/doctype/$1"; : > "${MOD}/doctype/$1/__init__.py"; }

# =============================================================================
step "1) Trade Case Item — ردیف کالا با بلوک FX رویدادی"
mk_dt trade_case_item
write_utf8 "${MOD}/doctype/trade_case_item/trade_case_item.json" << 'EOF'
{
 "actions": [], "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType",
 "editable_grid": 1, "engine": "InnoDB", "istable": 1,
 "field_order": [
  "row_kind", "item", "item_name", "thickness", "dimensions",
  "qty", "uom", "weight", "tonnage",
  "cb_price", "price", "transaction_currency", "conversion_rate", "rate_source", "rate_locked",
  "amount", "base_amount",
  "cb_progress", "shipped_tonnage", "remaining_tonnage"
 ],
 "fields": [
  {"default": "خرید", "fieldname": "row_kind", "fieldtype": "Select", "in_list_view": 1, "label": "نوع ردیف", "options": "خرید\nفروش", "reqd": 1, "columns": 1},
  {"fieldname": "item", "fieldtype": "Link", "in_list_view": 1, "label": "کالا", "options": "Item", "reqd": 1, "columns": 2},
  {"fetch_from": "item.item_name", "fieldname": "item_name", "fieldtype": "Data", "label": "نام کالا", "read_only": 1},
  {"fieldname": "thickness", "fieldtype": "Data", "label": "ضخامت"},
  {"fieldname": "dimensions", "fieldtype": "Data", "label": "ابعاد"},
  {"default": "0", "fieldname": "qty", "fieldtype": "Float", "in_list_view": 1, "label": "تعداد", "columns": 1},
  {"fieldname": "uom", "fieldtype": "Link", "label": "واحد", "options": "UOM"},
  {"default": "0", "fieldname": "weight", "fieldtype": "Float", "label": "وزن (کیلوگرم)"},
  {"default": "0", "fieldname": "tonnage", "fieldtype": "Float", "in_list_view": 1, "label": "تناژ", "reqd": 1, "columns": 1},
  {"fieldname": "cb_price", "fieldtype": "Column Break"},
  {"default": "0", "fieldname": "price", "fieldtype": "Float", "in_list_view": 1, "label": "قیمت واحد", "columns": 1},
  {"default": "IRR", "fieldname": "transaction_currency", "fieldtype": "Link", "in_list_view": 1, "label": "ارز رویداد", "options": "Currency", "reqd": 1, "columns": 1},
  {"fieldname": "conversion_rate", "fieldtype": "Float", "label": "نرخ تبدیل", "precision": "9"},
  {"fieldname": "rate_source", "fieldtype": "Data", "label": "منبع نرخ", "read_only": 1},
  {"default": "0", "fieldname": "rate_locked", "fieldtype": "Check", "label": "نرخ قفل شده", "read_only": 1},
  {"fieldname": "amount", "fieldtype": "Float", "in_list_view": 1, "label": "مبلغ رویداد", "read_only": 1, "columns": 1},
  {"fieldname": "base_amount", "fieldtype": "Float", "label": "مبلغ پایه (ریال)", "read_only": 1},
  {"fieldname": "cb_progress", "fieldtype": "Column Break"},
  {"default": "0", "fieldname": "shipped_tonnage", "fieldtype": "Float", "label": "تناژ حمل‌شده", "read_only": 1},
  {"default": "0", "fieldname": "remaining_tonnage", "fieldtype": "Float", "in_list_view": 1, "label": "تناژ باقی‌مانده", "read_only": 1, "columns": 1}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Trade Case Item", "owner": "Administrator",
 "permissions": [], "sort_field": "modified", "sort_order": "DESC"
}
EOF
write_utf8 "${MOD}/doctype/trade_case_item/trade_case_item.py" << 'EOF'
# -*- coding: utf-8 -*-
from frappe.model.document import Document


class TradeCaseItem(Document):
    pass
EOF

# =============================================================================
step "2) موتور واحد هزینه و سود — تنها منبع حقیقت هر عدد مالی"
write_utf8 "${MOD}/utils/money_engine.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
موتور واحد هزینه و سود.

مسئله ریشه‌ای نسخه قبل: سه فرمول متناقض (کنترلر فاز۶، Client Script، گزارش فاز۸)
و «دوباره‌شماری پرداخت‌ها به‌عنوان هزینه».

قاعده واحد و تخطی‌ناپذیر:
  total_operational_cost = freight + customs + clearance + insurance + other + initial
  total_settled          = Σ base_amount ردیف‌های پرداخت      (تسویه، نه هزینه)
  settlement_balance     = total_operational_cost − total_settled
  estimated_profit       = sales_base − purchase_base − total_operational_cost

کلاینت اجازه محاسبه مستقل ندارد؛ فقط get_cost_preview را صدا می‌زند.
"""
import frappe
from frappe import _
from frappe.utils import flt

COST_FIELDS = (
    ("freight_cost", "base_freight_cost"),
    ("customs_cost", "base_customs_cost"),
    ("clearance_cost", "base_clearance_cost"),
    ("insurance_cost", "base_insurance_cost"),
    ("other_cost", "base_other_cost"),
    ("initial_costs", "base_initial_costs"),
)


def operational_cost(doc):
    """جمع هزینه‌های عملیاتی بر مبنای «مبلغ پایه» هر رویداد."""
    total = 0.0
    for src, base in COST_FIELDS:
        total += flt(doc.get(base) if doc.get(base) is not None else doc.get(src))
    return flt(total, 2)


def settled_total(doc, payments_field="payments"):
    """جمع تسویه — هرگز به هزینه اضافه نمی‌شود."""
    total = 0.0
    for row in doc.get(payments_field) or []:
        total += flt(row.get("base_amount") if row.get("base_amount") else row.get("amount"))
    return flt(total, 2)


def item_totals(doc, items_field="items"):
    """جمع تناژ و مبالغ پایه به تفکیک خرید/فروش."""
    out = {"tonnage": 0.0, "purchase_base": 0.0, "sales_base": 0.0,
           "purchase_tonnage": 0.0, "sales_tonnage": 0.0, "currencies": set()}
    for r in doc.get(items_field) or []:
        out["tonnage"] += flt(r.tonnage)
        out["currencies"].add(r.transaction_currency or "IRR")
        if (r.row_kind or "خرید") == "خرید":
            out["purchase_base"] += flt(r.base_amount)
            out["purchase_tonnage"] += flt(r.tonnage)
        else:
            out["sales_base"] += flt(r.base_amount)
            out["sales_tonnage"] += flt(r.tonnage)
    return out


def estimated_profit(sales_base, purchase_base, op_cost):
    return flt(flt(sales_base) - flt(purchase_base) - flt(op_cost), 2)


@frappe.whitelist()
def get_cost_preview(doctype, name):
    """
    تنها نقطه‌ای که کلاینت اعداد مالی را می‌گیرد.
    خروجی دقیقاً همان چیزی است که سرور ذخیره کرده؛ بدون محاسبه دوم.
    """
    if not frappe.has_permission(doctype, "read", doc=name):
        frappe.throw(_("دسترسی لازم را ندارید."))
    doc = frappe.get_doc(doctype, name)
    op = operational_cost(doc)
    st = settled_total(doc) if doc.meta.has_field("payments") else 0.0
    return {
        "total_operational_cost": op,
        "total_settled": st,
        "settlement_balance": flt(op - st, 2),
        "estimated_profit": flt(doc.get("estimated_profit")),
        "sales_amount_base": flt(doc.get("sales_amount_base")),
        "purchase_amount_base": flt(doc.get("purchase_amount_base")),
    }
EOF

# =============================================================================
step "3) Trade Case — پرونده بازرگانی (چهار تب، ~۳۲ فیلد سطح سند)"
mk_dt trade_case
write_utf8 "${MOD}/doctype/trade_case/trade_case.json" << 'EOF'
{
 "actions": [], "allow_import": 1, "autoname": "naming_series:",
 "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType", "engine": "InnoDB",
 "field_order": [
  "tab_request",
  "sb_1_request", "naming_series", "case_title", "case_type", "requested_by", "requested_by_name",
  "cb_request_2", "company", "posting_date", "workflow_state", "fulfillment_status",
  "sb_2_parties", "customer", "supplier_factory", "cb_parties", "assigned_user", "sla_last_action_on",

  "tab_items",
  "sb_3_items", "items",
  "sb_4_summary", "planned_tonnage", "purchase_amount_base", "cb_summary",
  "sales_amount_base", "estimated_profit", "has_multi_currency",
  "sb_5_route", "destination", "border", "cb_route", "transport_type", "delivery_type",

  "tab_review",
  "sb_6_legal", "chk_legal_purchase_contract", "chk_legal_sales_contract", "chk_legal_obligations",
  "cb_legal", "chk_legal_requirements", "chk_legal_documents", "legal_notes",
  "sb_7_treasury", "treasury_approved_ceiling", "treasury_notes",
  "sb_8_docs", "document_type", "signed_document", "cb_docs", "proforma_purchase", "proforma_sales",
  "sb_9_supervisor", "chk_sup_purchase", "chk_sup_sales", "chk_sup_prices",
  "cb_sup", "chk_sup_documents", "chk_sup_signatures", "chk_sup_costs", "receivables_notes",

  "tab_close",
  "sb_10_links", "source_doctype", "source_document", "source_detail_row",
  "cb_links", "linked_purchase_case", "linked_sales_case",
  "sb_11_accounting", "sales_invoice", "purchase_invoice", "cb_acc", "payment_entry",
  "sb_12_close", "manual_close_reason", "closed_remaining_snapshot",
  "cb_close", "closed_by_user", "closed_on",
  "sb_13_exception", "rejection_reason", "hold_reason", "cb_exc", "hold_previous_state", "cancel_reason"
 ],
 "fields": [
  {"fieldname": "tab_request", "fieldtype": "Tab Break", "label": "۱ - درخواست و طرفین"},
  {"fieldname": "sb_1_request", "fieldtype": "Section Break", "label": "۱-۱ اطلاعات درخواست"},
  {"default": "TC-.YYYY.-.#####", "fieldname": "naming_series", "fieldtype": "Select", "hidden": 1, "label": "سری شماره‌گذاری", "options": "TC-.YYYY.-.#####"},
  {"fieldname": "case_title", "fieldtype": "Data", "in_list_view": 1, "label": "عنوان پرونده", "reqd": 1},
  {"fieldname": "case_type", "fieldtype": "Select", "in_list_view": 1, "in_standard_filter": 1, "label": "نوع پرونده", "options": "خرید\nفروش\nترکیبی", "reqd": 1},
  {"description": "مدیرعاملی که دستور اولیه را داده است (تلفنی/حضوری یا از میز مدیرعامل)", "fieldname": "requested_by", "fieldtype": "Link", "label": "مدیرعامل دستوردهنده", "options": "User", "reqd": 1},
  {"fetch_from": "requested_by.full_name", "fieldname": "requested_by_name", "fieldtype": "Data", "label": "نام مدیرعامل", "read_only": 1},
  {"fieldname": "cb_request_2", "fieldtype": "Column Break"},
  {"fieldname": "company", "fieldtype": "Link", "label": "شرکت", "options": "Company", "reqd": 1},
  {"fieldname": "posting_date", "fieldtype": "Date", "label": "تاریخ ثبت", "reqd": 1},
  {"fieldname": "workflow_state", "fieldtype": "Link", "hidden": 1, "label": "وضعیت گردش‌کار", "options": "Workflow State", "read_only": 1},
  {"default": "در انتظار شروع", "fieldname": "fulfillment_status", "fieldtype": "Select", "in_list_view": 1, "in_standard_filter": 1, "label": "وضعیت تأمین", "options": "در انتظار شروع\nدر انتظار تأمین کالا\nدر حال انجام\nتکمیل‌شده\nبسته‌شده دستی", "reqd": 1},

  {"fieldname": "sb_2_parties", "fieldtype": "Section Break", "label": "۱-۲ طرفین و مسئول"},
  {"fieldname": "customer", "fieldtype": "Link", "label": "مشتری", "options": "Customer"},
  {"fieldname": "supplier_factory", "fieldtype": "Link", "label": "کارخانه / تأمین‌کننده", "options": "Supplier"},
  {"fieldname": "cb_parties", "fieldtype": "Column Break"},
  {"fieldname": "assigned_user", "fieldtype": "Link", "label": "مسئول فعلی", "options": "User"},
  {"description": "فقط با اقدام واقعی کاربر جلو می‌رود؛ ارسال اعلان هرگز آن را تغییر نمی‌دهد", "fieldname": "sla_last_action_on", "fieldtype": "Datetime", "label": "آخرین اقدام واقعی", "read_only": 1},

  {"fieldname": "tab_items", "fieldtype": "Tab Break", "label": "۲ - اقلام و مالی"},
  {"fieldname": "sb_3_items", "fieldtype": "Section Break", "label": "۲-۱ اقلام کالا (چندکالایی)"},
  {"fieldname": "items", "fieldtype": "Table", "label": "اقلام", "options": "Trade Case Item", "reqd": 1},
  {"fieldname": "sb_4_summary", "fieldtype": "Section Break", "label": "۲-۲ خلاصه مالی (محاسبه خودکار)"},
  {"fieldname": "planned_tonnage", "fieldtype": "Float", "in_list_view": 1, "label": "تناژ کل برنامه", "read_only": 1},
  {"fieldname": "purchase_amount_base", "fieldtype": "Currency", "label": "مبلغ خرید (پایه ریالی)", "read_only": 1},
  {"fieldname": "cb_summary", "fieldtype": "Column Break"},
  {"fieldname": "sales_amount_base", "fieldtype": "Currency", "label": "مبلغ فروش (پایه ریالی)", "read_only": 1},
  {"fieldname": "estimated_profit", "fieldtype": "Currency", "label": "سود برآوردی", "read_only": 1},
  {"default": "0", "fieldname": "has_multi_currency", "fieldtype": "Check", "label": "پرونده چندارزی است", "read_only": 1},

  {"fieldname": "sb_5_route", "fieldtype": "Section Break", "label": "۲-۳ مسیر و تحویل"},
  {"fieldname": "destination", "fieldtype": "Data", "label": "مقصد"},
  {"fieldname": "border", "fieldtype": "Link", "label": "مرز", "options": "Border"},
  {"fieldname": "cb_route", "fieldtype": "Column Break"},
  {"fieldname": "transport_type", "fieldtype": "Select", "label": "نوع حمل", "options": "\nجاده‌ای\nریلی\nدریایی\nترکیبی"},
  {"fieldname": "delivery_type", "fieldtype": "Select", "label": "نوع تحویل", "options": "\nدرب کارخانه\nتحویل مرز\nتحویل مقصد"},

  {"fieldname": "tab_review", "fieldtype": "Tab Break", "label": "۳ - بررسی‌ها، اسناد و امضا"},
  {"fieldname": "sb_6_legal", "fieldtype": "Section Break", "label": "۳-۱ چک‌لیست حقوقی"},
  {"default": "0", "fieldname": "chk_legal_purchase_contract", "fieldtype": "Check", "label": "بررسی قرارداد خرید"},
  {"default": "0", "fieldname": "chk_legal_sales_contract", "fieldtype": "Check", "label": "بررسی قرارداد فروش"},
  {"default": "0", "fieldname": "chk_legal_obligations", "fieldtype": "Check", "label": "بررسی تعهدات طرفین"},
  {"fieldname": "cb_legal", "fieldtype": "Column Break"},
  {"default": "0", "fieldname": "chk_legal_requirements", "fieldtype": "Check", "label": "بررسی الزامات قانونی"},
  {"default": "0", "fieldname": "chk_legal_documents", "fieldtype": "Check", "label": "کنترل اسناد"},
  {"fieldname": "legal_notes", "fieldtype": "Small Text", "label": "یادداشت حقوقی"},

  {"fieldname": "sb_7_treasury", "fieldtype": "Section Break", "label": "۳-۲ خزانه"},
  {"fieldname": "treasury_approved_ceiling", "fieldtype": "Currency", "label": "سقف پرداخت تأییدشده"},
  {"fieldname": "treasury_notes", "fieldtype": "Small Text", "label": "یادداشت خزانه"},

  {"fieldname": "sb_8_docs", "fieldtype": "Section Break", "label": "۳-۳ اسناد و امضا"},
  {"fieldname": "document_type", "fieldtype": "Select", "label": "نوع سند پیوست", "options": "\nقرارداد خرید\nقرارداد فروش\nپیش‌فاکتور\nسند امضاشده\nسایر"},
  {"description": "برگه چاپی سپیدار پس از امضای دستی مدیرعامل، اینجا بارگذاری می‌شود", "fieldname": "signed_document", "fieldtype": "Attach", "label": "سند امضاشده"},
  {"fieldname": "cb_docs", "fieldtype": "Column Break"},
  {"fieldname": "proforma_purchase", "fieldtype": "Attach", "label": "پیش‌فاکتور خرید"},
  {"fieldname": "proforma_sales", "fieldtype": "Attach", "label": "پیش‌فاکتور فروش"},

  {"fieldname": "sb_9_supervisor", "fieldtype": "Section Break", "label": "۳-۴ چک‌لیست نهایی سرپرست مالی"},
  {"default": "0", "fieldname": "chk_sup_purchase", "fieldtype": "Check", "label": "کنترل خرید"},
  {"default": "0", "fieldname": "chk_sup_sales", "fieldtype": "Check", "label": "کنترل فروش"},
  {"default": "0", "fieldname": "chk_sup_prices", "fieldtype": "Check", "label": "کنترل قیمت‌ها"},
  {"fieldname": "cb_sup", "fieldtype": "Column Break"},
  {"default": "0", "fieldname": "chk_sup_documents", "fieldtype": "Check", "label": "کنترل اسناد"},
  {"default": "0", "fieldname": "chk_sup_signatures", "fieldtype": "Check", "label": "کنترل امضاها"},
  {"default": "0", "fieldname": "chk_sup_costs", "fieldtype": "Check", "label": "کنترل هزینه‌ها"},
  {"fieldname": "receivables_notes", "fieldtype": "Small Text", "label": "یادداشت وصول مطالبات"},

  {"fieldname": "tab_close", "fieldtype": "Tab Break", "label": "۴ - اتصال‌ها و بستن"},
  {"fieldname": "sb_10_links", "fieldtype": "Section Break", "label": "۴-۱ اتصال به سند اصلی"},
  {"fieldname": "source_doctype", "fieldtype": "Link", "label": "نوع سند اصلی", "options": "DocType"},
  {"fieldname": "source_document", "fieldtype": "Dynamic Link", "label": "سند اصلی", "options": "source_doctype"},
  {"fieldname": "source_detail_row", "fieldtype": "Data", "label": "شناسه ردیف سند اصلی"},
  {"fieldname": "cb_links", "fieldtype": "Column Break"},
  {"fieldname": "linked_purchase_case", "fieldtype": "Link", "label": "پرونده خرید مرتبط", "options": "Trade Case"},
  {"fieldname": "linked_sales_case", "fieldtype": "Link", "label": "پرونده فروش مرتبط", "options": "Trade Case"},

  {"fieldname": "sb_11_accounting", "fieldtype": "Section Break", "label": "۴-۲ اتصال حسابداری واقعی"},
  {"fieldname": "sales_invoice", "fieldtype": "Link", "label": "فاکتور فروش", "options": "Sales Invoice"},
  {"fieldname": "purchase_invoice", "fieldtype": "Link", "label": "فاکتور خرید", "options": "Purchase Invoice"},
  {"fieldname": "cb_acc", "fieldtype": "Column Break"},
  {"fieldname": "payment_entry", "fieldtype": "Link", "label": "سند پرداخت", "options": "Payment Entry"},

  {"fieldname": "sb_12_close", "fieldtype": "Section Break", "label": "۴-۳ بستن پرونده"},
  {"fieldname": "manual_close_reason", "fieldtype": "Small Text", "label": "دلیل بستن دستی"},
  {"fieldname": "closed_remaining_snapshot", "fieldtype": "Small Text", "label": "تصویر باقی‌مانده در لحظه بستن", "read_only": 1},
  {"fieldname": "cb_close", "fieldtype": "Column Break"},
  {"fieldname": "closed_by_user", "fieldtype": "Link", "label": "بسته‌شده توسط", "options": "User", "read_only": 1},
  {"fieldname": "closed_on", "fieldtype": "Datetime", "label": "تاریخ بستن", "read_only": 1},

  {"fieldname": "sb_13_exception", "fieldtype": "Section Break", "label": "۴-۴ مسیرهای استثنا"},
  {"fieldname": "rejection_reason", "fieldtype": "Small Text", "label": "دلیل رد"},
  {"fieldname": "hold_reason", "fieldtype": "Small Text", "label": "دلیل تعلیق"},
  {"fieldname": "cb_exc", "fieldtype": "Column Break"},
  {"fieldname": "hold_previous_state", "fieldtype": "Data", "label": "وضعیت پیش از تعلیق", "read_only": 1},
  {"fieldname": "cancel_reason", "fieldtype": "Small Text", "label": "علت لغو"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Trade Case", "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "email": 1, "export": 1, "print": 1, "read": 1, "report": 1, "share": 1, "write": 1, "role": "System Manager"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "print": 1, "role": "Finance User"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "print": 1, "export": 1, "role": "Finance Supervisor"},
  {"read": 1, "write": 1, "report": 1, "role": "Legal Reviewer"},
  {"read": 1, "write": 1, "report": 1, "role": "Treasury User"},
  {"read": 1, "write": 1, "report": 1, "role": "Receivables User"},
  {"read": 1, "write": 1, "report": 1, "role": "Document Signer"},
  {"read": 1, "write": 1, "report": 1, "export": 1, "role": "Financial Manager"},
  {"read": 1, "write": 1, "report": 1, "role": "Transport Supervisor"},
  {"read": 1, "report": 1, "role": "Transport User - Purchase"},
  {"read": 1, "report": 1, "role": "Transport User - Sales"},
  {"read": 1, "report": 1, "export": 1, "print": 1, "role": "CEO"}
 ],
 "search_fields": "case_title,case_type,customer,supplier_factory",
 "sort_field": "modified", "sort_order": "DESC", "title_field": "case_title", "track_changes": 1
}
EOF

write_utf8 "${MOD}/doctype/trade_case/trade_case.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
کنترلر پرونده بازرگانی.

اصول:
  * تنها یک موتور محاسبه مالی (money_engine) — هیچ فرمول موازی.
  * تنها یک موتور ارز (fx) — نرخ هر رویداد، نه نرخ پرونده.
  * ساعت SLA فقط با اقدام واقعی کاربر جلو می‌رود.
  * ارز، ویژگی رویداد است: یک پرونده می‌تواند ردیف ریالی و ردیف دلاری داشته باشد.
"""
import json

import frappe
from frappe import _
from frappe.model.document import Document
from frappe.utils import flt, now_datetime, nowdate

from iran_trade_erp.iran_trade.utils import fx
from iran_trade_erp.iran_trade.utils import money_engine as ME

FULFILL_WAITING_SUPPLY = "در انتظار تأمین کالا"
FULFILL_IN_PROGRESS = "در حال انجام"
FULFILL_COMPLETED = "تکمیل‌شده"
FULFILL_MANUAL_CLOSED = "بسته‌شده دستی"


class TradeCase(Document):
    # ------------------------------------------------------------------ hooks
    def before_insert(self):
        if not self.company:
            self.company = frappe.defaults.get_user_default("Company") or frappe.db.get_value("Company", {}, "name")
        if not self.posting_date:
            self.posting_date = nowdate()
        if not self.sla_last_action_on:
            self.sla_last_action_on = now_datetime()

    def validate(self):
        self._validate_requested_by()
        self._apply_item_fx()
        self._roll_up_totals()
        self._validate_linked_cases()
        self._sync_fulfillment_status()

    def on_update(self):
        self._touch_sla_clock()

    # ------------------------------------------------------------- validation
    def _validate_requested_by(self):
        """مدیرعامل دستوردهنده باید واقعاً نقش مدیرعامل داشته باشد."""
        if not self.requested_by:
            frappe.throw(_("درج «مدیرعامل دستوردهنده» الزامی است."))
        if self.requested_by in ("Administrator", "Guest"):
            frappe.throw(_("مدیر سامانه یا کاربر مهمان نمی‌تواند دستوردهنده باشد."))
        has_ceo = frappe.db.exists("Has Role", {"parent": self.requested_by, "role": "CEO", "parenttype": "User"})
        if not has_ceo:
            frappe.throw(_("کاربر انتخاب‌شده نقش «مدیرعامل» ندارد."))

    def _apply_item_fx(self):
        """هر ردیف کالا، نرخ و مبلغ پایه خودش را دارد (چندارزی سطح رویداد)."""
        for row in self.items or []:
            row.amount = flt(flt(row.qty or row.tonnage or 0) * flt(row.price), 2) \
                if flt(row.qty) else flt(flt(row.tonnage) * flt(row.price), 2)
            fx.apply_fx(row, posting_date=self.posting_date)

    def _roll_up_totals(self):
        t = ME.item_totals(self)
        self.planned_tonnage = flt(t["tonnage"], 3)
        self.purchase_amount_base = flt(t["purchase_base"], 2)
        self.sales_amount_base = flt(t["sales_base"], 2)
        self.has_multi_currency = 1 if len(t["currencies"]) > 1 else 0

        op_cost = flt(self._loading_cost_total(), 2)
        self.estimated_profit = ME.estimated_profit(
            self.sales_amount_base, self.purchase_amount_base, op_cost
        )

    def _loading_cost_total(self):
        """هزینه عملیاتی کل پرونده = جمع هزینه عملیاتی همه بارگیری‌ها."""
        if not self.name or self.is_new():
            return 0.0
        if not frappe.db.table_exists("Trade Case Loading"):
            return 0.0
        row = frappe.db.sql(
            """SELECT COALESCE(SUM(total_operational_cost), 0) AS c
               FROM `tabTrade Case Loading`
               WHERE trade_case=%s AND loading_state NOT IN ('لغو شده','رد شده')""",
            (self.name,), as_dict=True,
        )
        return flt(row[0].c) if row else 0.0

    def _validate_linked_cases(self):
        """اتصال دوطرفه با اعتبارسنجی نوع — جلوگیری از حلقه و خطای منطقی."""
        if self.linked_purchase_case:
            if self.linked_purchase_case == self.name:
                frappe.throw(_("پرونده نمی‌تواند به خودش متصل شود."))
            t = frappe.db.get_value("Trade Case", self.linked_purchase_case, "case_type")
            if t not in ("خرید", "ترکیبی"):
                frappe.throw(_("«پرونده خرید مرتبط» باید از نوع خرید یا ترکیبی باشد."))
        if self.linked_sales_case:
            if self.linked_sales_case == self.name:
                frappe.throw(_("پرونده نمی‌تواند به خودش متصل شود."))
            t = frappe.db.get_value("Trade Case", self.linked_sales_case, "case_type")
            if t not in ("فروش", "ترکیبی"):
                frappe.throw(_("«پرونده فروش مرتبط» باید از نوع فروش یا ترکیبی باشد."))
        if self.linked_purchase_case and self.linked_purchase_case == self.linked_sales_case:
            frappe.throw(_("پرونده خرید و فروش مرتبط نمی‌توانند یکی باشند."))

    def _sync_fulfillment_status(self):
        if self.fulfillment_status in (FULFILL_WAITING_SUPPLY, FULFILL_MANUAL_CLOSED):
            return
        shipped = sum(flt(r.shipped_tonnage) for r in self.items or [])
        if self.planned_tonnage and shipped >= flt(self.planned_tonnage) - 0.001:
            self.fulfillment_status = FULFILL_COMPLETED
        elif shipped > 0:
            self.fulfillment_status = FULFILL_IN_PROGRESS

    # -------------------------------------------------------------- SLA clock
    def _touch_sla_clock(self):
        """
        ساعت SLA فقط با «اقدام واقعی کاربر» جلو می‌رود.
        ارسال اعلان، ثبت تاریخچه و کار موتورها این فیلد را هرگز تغییر نمی‌دهند.
        """
        if self.flags.get("ignore_sla_touch"):
            return
        if frappe.session.user in ("Administrator", "Guest"):
            return
        if not self.has_value_changed("workflow_state"):
            return
        frappe.db.set_value(
            self.doctype, self.name, "sla_last_action_on", now_datetime(),
            update_modified=False,
        )


# ------------------------------------------------------------------- API ----
@frappe.whitelist()
def park_waiting_supply(name, reason=None):
    """پارک پرونده در وضعیت رسمی «در انتظار تأمین کالا» — فقط سرپرست مالی."""
    _guard_role(["Finance Supervisor", "System Manager"])
    doc = frappe.get_doc("Trade Case", name)
    doc.fulfillment_status = FULFILL_WAITING_SUPPLY
    if reason:
        doc.hold_reason = reason
    doc.save(ignore_permissions=False)
    frappe.db.commit()
    _safe_notify("trade_case.waiting_supply", doc, {"reason": reason or ""})
    return {"status": FULFILL_WAITING_SUPPLY}


@frappe.whitelist()
def release_waiting_supply(name):
    """آزادسازی از «در انتظار تأمین کالا» و ادامه گردش‌کار."""
    _guard_role(["Finance Supervisor", "System Manager"])
    doc = frappe.get_doc("Trade Case", name)
    if doc.fulfillment_status != FULFILL_WAITING_SUPPLY:
        frappe.throw(_("این پرونده در وضعیت «در انتظار تأمین کالا» نیست."))
    doc.fulfillment_status = FULFILL_IN_PROGRESS
    doc.save()
    frappe.db.commit()
    return {"status": doc.fulfillment_status}


@frappe.whitelist()
def manual_close(name, reason):
    """
    بستن دستی با دلیل اجباری + ثبت تصویر باقی‌مانده
    + ثبت خودکار کسری در «دفتر بدهی کارخانه» (script-07).
    """
    _guard_role(["Finance Supervisor", "Transport Supervisor", "System Manager"])
    if not (reason or "").strip():
        frappe.throw(_("ثبت «دلیل بستن دستی» الزامی است."))
    doc = frappe.get_doc("Trade Case", name)
    snapshot = []
    for r in doc.items or []:
        rem = flt(r.tonnage) - flt(r.shipped_tonnage)
        if rem > 0.001:
            snapshot.append({
                "row": r.name, "item": r.item, "row_kind": r.row_kind,
                "planned": flt(r.tonnage), "shipped": flt(r.shipped_tonnage),
                "remaining": flt(rem, 3),
            })
    doc.closed_remaining_snapshot = json.dumps(snapshot, ensure_ascii=False)
    doc.manual_close_reason = reason
    doc.closed_by_user = frappe.session.user
    doc.closed_on = now_datetime()
    doc.fulfillment_status = FULFILL_MANUAL_CLOSED
    doc.save()

    if frappe.db.table_exists("Factory Shortfall Ledger"):
        from iran_trade_erp.iran_trade.doctype.factory_shortfall_ledger.factory_shortfall_ledger import (
            record_shortfall_from_case,
        )
        record_shortfall_from_case(doc, snapshot)

    frappe.db.commit()
    _safe_notify("trade_case.manually_closed", doc, {"reason": reason})
    return {"snapshot": snapshot}


def _guard_role(roles):
    user_roles = set(frappe.get_roles())
    if not user_roles.intersection(set(roles)):
        frappe.throw(_("شما اجازه انجام این عملیات را ندارید."))


def _safe_notify(event_key, doc, context):
    """اگر سرویس اعلان هنوز نصب نشده، سکوت ممنوع است — در دفتر خطا ثبت می‌شود."""
    try:
        from iran_trade_erp.iran_trade.notification.core import notify
        notify(event_key, doc.doctype, doc.name, context)
    except ImportError:
        frappe.log_error(
            title="سرویس اعلان در دسترس نیست",
            message="رویداد {0} برای سند {1} ارسال نشد.".format(event_key, doc.name),
        )
EOF

write_utf8 "${MOD}/doctype/trade_case/trade_case_list.js" << 'EOF'
frappe.listview_settings["Trade Case"] = {
	add_fields: ["fulfillment_status", "case_type", "planned_tonnage"],
	get_indicator: function (doc) {
		const map = {
			"در انتظار شروع": ["در انتظار شروع", "gray"],
			"در انتظار تأمین کالا": ["در انتظار تأمین کالا", "orange"],
			"در حال انجام": ["در حال انجام", "blue"],
			"تکمیل‌شده": ["تکمیل‌شده", "green"],
			"بسته‌شده دستی": ["بسته‌شده دستی", "purple"],
		};
		const v = map[doc.fulfillment_status] || ["نامشخص", "gray"];
		return [__(v[0]), v[1], "fulfillment_status,=," + doc.fulfillment_status];
	},
};
EOF

# =============================================================================
step "4) CEO Request — میز مدیرعامل (مسیر دیجیتال مکمل)"
mk_dt ceo_request_item; mk_dt ceo_request
write_utf8 "${MOD}/doctype/ceo_request_item/ceo_request_item.json" << 'EOF'
{
 "actions": [], "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType",
 "editable_grid": 1, "engine": "InnoDB", "istable": 1,
 "field_order": ["row_kind", "item", "qty", "uom", "tonnage", "price", "transaction_currency", "description"],
 "fields": [
  {"default": "خرید", "fieldname": "row_kind", "fieldtype": "Select", "in_list_view": 1, "label": "نوع", "options": "خرید\nفروش", "columns": 1},
  {"fieldname": "item", "fieldtype": "Link", "in_list_view": 1, "label": "کالا", "options": "Item", "reqd": 1, "columns": 2},
  {"default": "0", "fieldname": "qty", "fieldtype": "Float", "in_list_view": 1, "label": "تعداد", "columns": 1},
  {"fieldname": "uom", "fieldtype": "Link", "label": "واحد", "options": "UOM"},
  {"default": "0", "fieldname": "tonnage", "fieldtype": "Float", "in_list_view": 1, "label": "تناژ", "columns": 1},
  {"default": "0", "fieldname": "price", "fieldtype": "Float", "in_list_view": 1, "label": "قیمت واحد", "columns": 2},
  {"default": "IRR", "fieldname": "transaction_currency", "fieldtype": "Link", "in_list_view": 1, "label": "ارز", "options": "Currency", "columns": 1},
  {"fieldname": "description", "fieldtype": "Small Text", "label": "توضیح"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "CEO Request Item", "owner": "Administrator",
 "permissions": [], "sort_field": "modified", "sort_order": "DESC"
}
EOF
write_utf8 "${MOD}/doctype/ceo_request_item/ceo_request_item.py" << 'EOF'
# -*- coding: utf-8 -*-
from frappe.model.document import Document


class CEORequestItem(Document):
    pass
EOF

write_utf8 "${MOD}/doctype/ceo_request/ceo_request.json" << 'EOF'
{
 "actions": [], "autoname": "naming_series:", "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType", "engine": "InnoDB",
 "field_order": [
  "sb_1", "naming_series", "request_title", "request_type", "cb_1", "requested_by",
  "posting_date", "request_status",
  "sb_2", "customer", "supplier_factory", "cb_2", "destination", "attachment",
  "sb_3", "items",
  "sb_4", "instructions", "cb_4", "assigned_supervisor", "trade_case", "handled_on"
 ],
 "fields": [
  {"fieldname": "sb_1", "fieldtype": "Section Break", "label": "۱ - دستور مدیرعامل"},
  {"default": "CEOR-.YYYY.-.####", "fieldname": "naming_series", "fieldtype": "Select", "hidden": 1, "label": "سری", "options": "CEOR-.YYYY.-.####"},
  {"fieldname": "request_title", "fieldtype": "Data", "in_list_view": 1, "label": "عنوان دستور", "reqd": 1},
  {"fieldname": "request_type", "fieldtype": "Select", "in_list_view": 1, "label": "نوع دستور", "options": "خرید\nفروش\nترکیبی", "reqd": 1},
  {"fieldname": "cb_1", "fieldtype": "Column Break"},
  {"fieldname": "requested_by", "fieldtype": "Link", "in_list_view": 1, "label": "مدیرعامل دستوردهنده", "options": "User", "reqd": 1},
  {"fieldname": "posting_date", "fieldtype": "Date", "label": "تاریخ دستور", "reqd": 1},
  {"default": "ثبت‌شده", "fieldname": "request_status", "fieldtype": "Select", "in_list_view": 1, "in_standard_filter": 1, "label": "وضعیت", "options": "ثبت‌شده\nارجاع‌شده به سرپرست مالی\nتبدیل به پرونده شد\nرد شد", "read_only": 1},
  {"fieldname": "sb_2", "fieldtype": "Section Break", "label": "۲ - طرفین"},
  {"fieldname": "customer", "fieldtype": "Link", "label": "مشتری", "options": "Customer"},
  {"fieldname": "supplier_factory", "fieldtype": "Link", "label": "کارخانه / تأمین‌کننده", "options": "Supplier"},
  {"fieldname": "cb_2", "fieldtype": "Column Break"},
  {"fieldname": "destination", "fieldtype": "Data", "label": "مقصد"},
  {"fieldname": "attachment", "fieldtype": "Attach", "label": "پیوست"},
  {"fieldname": "sb_3", "fieldtype": "Section Break", "label": "۳ - اقلام درخواستی"},
  {"fieldname": "items", "fieldtype": "Table", "label": "اقلام", "options": "CEO Request Item"},
  {"fieldname": "sb_4", "fieldtype": "Section Break", "label": "۴ - ارجاع"},
  {"fieldname": "instructions", "fieldtype": "Small Text", "label": "توضیح دستور"},
  {"fieldname": "cb_4", "fieldtype": "Column Break"},
  {"fieldname": "assigned_supervisor", "fieldtype": "Link", "label": "سرپرست مالی مقصد", "options": "User", "read_only": 1},
  {"fieldname": "trade_case", "fieldtype": "Link", "label": "پرونده ساخته‌شده", "options": "Trade Case", "read_only": 1},
  {"fieldname": "handled_on", "fieldtype": "Datetime", "label": "زمان رسیدگی", "read_only": 1}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "CEO Request", "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "read": 1, "write": 1, "report": 1, "export": 1, "print": 1, "role": "System Manager"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "print": 1, "role": "CEO"},
  {"read": 1, "write": 1, "report": 1, "role": "Finance Supervisor"},
  {"read": 1, "write": 1, "report": 1, "role": "Finance User"},
  {"read": 1, "report": 1, "role": "Financial Manager"}
 ],
 "sort_field": "modified", "sort_order": "DESC", "title_field": "request_title", "track_changes": 1
}
EOF

write_utf8 "${MOD}/doctype/ceo_request/ceo_request.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
میز مدیرعامل.

مسیر فیزیکی (تلفنی/حضوری) پیش‌فرض امروز است و سیستم آن را ثبت نمی‌کند.
این DocType «مسیر دیجیتال مکمل» است، نه جایگزین. هر دو مسیر به یک
Trade Case واحد می‌رسند.
"""
import frappe
from frappe import _
from frappe.model.document import Document
from frappe.utils import now_datetime, nowdate

from iran_trade_erp.iran_trade.utils.naming_guard import users_with_role


class CEORequest(Document):
    def before_insert(self):
        if not self.posting_date:
            self.posting_date = nowdate()
        if not self.requested_by:
            self.requested_by = frappe.session.user

    def validate(self):
        if self.requested_by in ("Administrator", "Guest"):
            frappe.throw(_("مدیر سامانه یا کاربر مهمان نمی‌تواند دستور ثبت کند."))
        if not frappe.db.exists("Has Role", {"parent": self.requested_by, "role": "CEO", "parenttype": "User"}):
            frappe.throw(_("ثبت دستور فقط توسط کاربر دارای نقش «مدیرعامل» ممکن است."))

    def after_insert(self):
        """ارجاع خودکار به کارتابل سرپرست مالی + اعلان داخلی."""
        supervisors = users_with_role("Finance Supervisor")
        if not supervisors:
            frappe.log_error(
                title="خطای پیکربندی: سرپرست مالی یافت نشد",
                message="درخواست {0} قابل ارجاع نبود؛ هیچ کاربر فعالی با نقش «سرپرست مالی» وجود ندارد.".format(self.name),
            )
            return
        self.db_set("assigned_supervisor", supervisors[0], update_modified=False)
        self.db_set("request_status", "ارجاع‌شده به سرپرست مالی", update_modified=False)
        _notify("ceo_request.submitted", self, {"ceo": self.requested_by})


@frappe.whitelist()
def convert_to_trade_case(name, assigned_user=None):
    """
    تبدیل دستور مدیرعامل به پرونده بازرگانی.
    تمام اقلام و اطلاعات مالی/طرفین/پیوست منتقل می‌شوند (نه فقط نوع پرونده).
    """
    roles = set(frappe.get_roles())
    if not roles.intersection({"Finance Supervisor", "Finance User", "System Manager"}):
        frappe.throw(_("فقط سرپرست/کارشناس مالی می‌تواند دستور را به پرونده تبدیل کند."))

    req = frappe.get_doc("CEO Request", name)
    if req.trade_case:
        return req.trade_case

    case = frappe.new_doc("Trade Case")
    case.case_title = req.request_title
    case.case_type = req.request_type
    case.requested_by = req.requested_by          # ★ فیلد دائمی مدیرعامل دستوردهنده
    case.posting_date = req.posting_date or nowdate()
    case.customer = req.customer
    case.supplier_factory = req.supplier_factory
    case.destination = req.destination
    case.assigned_user = assigned_user or frappe.session.user
    case.source_doctype = "CEO Request"
    case.source_document = req.name
    if req.attachment:
        case.proforma_purchase = req.attachment

    for r in req.items or []:
        case.append("items", {
            "row_kind": r.row_kind, "item": r.item, "qty": r.qty, "uom": r.uom,
            "tonnage": r.tonnage, "price": r.price,
            "transaction_currency": r.transaction_currency or "IRR",
        })
    if not case.items:
        frappe.throw(_("دستور مدیرعامل هیچ قلم کالایی ندارد؛ ابتدا اقلام را ثبت کنید."))

    case.insert()
    req.db_set("trade_case", case.name, update_modified=False)
    req.db_set("request_status", "تبدیل به پرونده شد", update_modified=False)
    req.db_set("handled_on", now_datetime(), update_modified=False)
    frappe.db.commit()
    _notify("ceo_request.accepted", req, {"trade_case": case.name})
    return case.name


@frappe.whitelist()
def reject_request(name, reason):
    if not (reason or "").strip():
        frappe.throw(_("ثبت دلیل رد الزامی است."))
    roles = set(frappe.get_roles())
    if not roles.intersection({"Finance Supervisor", "System Manager"}):
        frappe.throw(_("فقط سرپرست مالی می‌تواند دستور را رد کند."))
    req = frappe.get_doc("CEO Request", name)
    req.db_set("request_status", "رد شد", update_modified=False)
    req.db_set("instructions", (req.instructions or "") + "\nدلیل رد: " + reason, update_modified=False)
    frappe.db.commit()
    _notify("ceo_request.rejected", req, {"reason": reason})
    return True


def _notify(event_key, doc, context):
    try:
        from iran_trade_erp.iran_trade.notification.core import notify
        notify(event_key, doc.doctype, doc.name, context)
    except ImportError:
        frappe.log_error(
            title="سرویس اعلان در دسترس نیست",
            message="رویداد {0} برای سند {1} ارسال نشد.".format(event_key, doc.name),
        )
EOF

# =============================================================================
step "5) ترجمه‌ها + hooks (بلوک SCRIPT04)"
python3 - "$PKG" << 'PYEOF'
import io, os, re, sys
pkg = sys.argv[1]
p = os.path.join(pkg, "hooks.py")
src = io.open(p, encoding="utf-8").read()
if "# --- SCRIPT03_HOOKS_START ---" not in src:
    raise SystemExit("ABORT: anchor SCRIPT03 missing")
S, E = "# --- SCRIPT04_HOOKS_START ---", "# --- SCRIPT04_HOOKS_END ---"
src = re.sub(re.escape(S) + r".*?" + re.escape(E), "", src, flags=re.S)
block = S + '''
# هسته دامنه؛ کنترلرها منطق را خودشان دارند و اینجا رویداد موازی ثبت نمی‌شود
# تا «اجرای دو باره منطق» (باگ لایه‌لایه شدن پچ‌ها) هرگز تکرار نشود.
''' + E + "\n"
io.open(p, "w", encoding="utf-8").write(src.rstrip() + "\n\n" + block)

t = os.path.join(pkg, "translations", "fa.csv")
rows = ["Trade Case,پرونده بازرگانی,", "Trade Case Item,قلم پرونده بازرگانی,",
        "CEO Request,دستور مدیرعامل,", "CEO Request Item,قلم دستور مدیرعامل,"]
cur = io.open(t, encoding="utf-8").read() if os.path.exists(t) else ""
have = set(l.split(",")[0] for l in cur.splitlines() if l.strip())
add = [r for r in rows if r.split(",")[0] not in have]
if add:
    io.open(t, "a", encoding="utf-8").write("\n".join(add) + "\n")
print("SCRIPT04 hooks + fa.csv ok")
PYEOF

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache

# =============================================================================
step "6) Verify داخلی — سناریوی عددی واقعی (خرید/فروش/ترکیبی)"
write_utf8 "${PKG}/verify_script04.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
from frappe.utils import flt, nowdate


def _ceo():
    rows = frappe.get_all("Has Role", filters={"role": "CEO", "parenttype": "User"}, pluck="parent")
    rows = [r for r in rows if r not in ("Administrator", "Guest")]
    return rows[0]


def _ensure_uom(name="Nos"):
    """UOM قبل از Item — همان الگوی Transit قبل از Company."""
    if frappe.db.exists("UOM", name):
        return name
    # ترجیح به واحدهای رایج ERPNext اگر موجود باشند
    for candidate in (name, "Nos", "Unit", "Kg", "Kilogram", "Ton", "Tonne"):
        if frappe.db.exists("UOM", candidate):
            return candidate
    doc = frappe.get_doc({
        "doctype": "UOM",
        "uom_name": name,
        "enabled": 1,
    })
    doc.flags.ignore_permissions = True
    doc.insert(ignore_permissions=True)
    frappe.db.commit()
    return name


def _ensure_item_group():
    """Item Group ریشه/برگ — بدون فرض «All Item Groups»."""
    # برگ غیرگروهی
    leaf = frappe.db.get_value("Item Group", {"is_group": 0}, "name")
    if leaf:
        return leaf
    # هر گروه موجود
    any_g = frappe.db.get_value("Item Group", {}, "name")
    if any_g:
        return any_g
    # ساخت حداقلی
    root_name = "All Item Groups"
    if not frappe.db.exists("Item Group", root_name):
        root = frappe.get_doc({
            "doctype": "Item Group",
            "item_group_name": root_name,
            "is_group": 1,
        })
        root.flags.ignore_permissions = True
        root.flags.ignore_mandatory = True
        try:
            root.insert(ignore_permissions=True)
        except Exception:
            pass
        frappe.db.commit()
    child_name = "Products"
    if not frappe.db.exists("Item Group", child_name):
        child = frappe.get_doc({
            "doctype": "Item Group",
            "item_group_name": child_name,
            "is_group": 0,
            "parent_item_group": root_name if frappe.db.exists("Item Group", root_name) else None,
        })
        child.flags.ignore_permissions = True
        child.flags.ignore_mandatory = True
        child.insert(ignore_permissions=True)
        frappe.db.commit()
        return child_name
    return frappe.db.get_value("Item Group", {}, "name")


def _item():
    name = "TEST-STEEL-COIL"
    if frappe.db.exists("Item", name):
        return name
    uom = _ensure_uom("Nos")
    group = _ensure_item_group()
    it = frappe.new_doc("Item")
    it.item_code = name
    it.item_name = "ورق فولادی آزمایشی"
    it.item_group = group
    it.stock_uom = uom
    it.is_stock_item = 0
    it.flags.ignore_permissions = True
    it.flags.ignore_mandatory = True
    it.insert(ignore_permissions=True)
    frappe.db.commit()
    return name


def run():
    passed = failed = 0

    def chk(t, c):
        nonlocal passed, failed
        if c:
            passed += 1; print("  [PASS] " + t)
        else:
            failed += 1; print("  [FAIL] " + t)

    for dt in ("Trade Case", "Trade Case Item", "CEO Request", "CEO Request Item"):
        chk("DocType ساخته شد: " + dt, frappe.db.count("DocType", {"name": dt}) == 1)

    meta = frappe.get_meta("Trade Case")
    doc_fields = [f for f in meta.fields
                  if f.fieldtype not in ("Section Break", "Column Break", "Tab Break", "Table")]
    chk("تعداد فیلد سطح سند در بازه معقول (<=۶۰ با احتساب چک‌لیست‌ها): %d" % len(doc_fields),
        len(doc_fields) <= 60)

    no_label = [f.fieldname for f in meta.fields
                if f.fieldtype not in ("Column Break",) and not f.label]
    chk("همه فیلدهای Trade Case برچسب فارسی دارند", not no_label)

    chk("فیلد دائمی «مدیرعامل دستوردهنده» وجود دارد", meta.has_field("requested_by"))
    opts = meta.get_field("fulfillment_status").options or ""
    chk("وضعیت رسمی «در انتظار تأمین کالا» تعریف شده", "در انتظار تأمین کالا" in opts)
    chk("نوع پرونده «ترکیبی» (دلالی) وجود دارد", "ترکیبی" in (meta.get_field("case_type").options or ""))
    chk("اتصال حسابداری واقعی Link است",
        meta.get_field("sales_invoice").fieldtype == "Link" and
        meta.get_field("purchase_invoice").fieldtype == "Link")
    chk("Dynamic Link سند اصلی وجود دارد",
        meta.get_field("source_document").fieldtype == "Dynamic Link")

    # --- سناریوی واقعی: پرونده ترکیبی با ارز مختلط ---
    ceo = _ceo()
    item = _item()
    company = frappe.db.get_value("Company", {}, "name")

    ts = frappe.get_single("Treasury Settings")
    ts.company_currency = "IRR"
    if not flt(ts.default_usd_to_irr_rate):
        ts.default_usd_to_irr_rate = 600000
    ts.flags.ignore_permissions = True
    ts.save(ignore_permissions=True)
    frappe.db.commit()

    case = frappe.new_doc("Trade Case")
    case.case_title = "پرونده آزمایشی ترکیبی"
    case.case_type = "ترکیبی"
    case.requested_by = ceo
    case.company = company
    case.posting_date = nowdate()
    case.fulfillment_status = "در انتظار شروع"
    case.append("items", {"row_kind": "خرید", "item": item, "tonnage": 100,
                          "price": 10000000, "transaction_currency": "IRR"})
    case.append("items", {"row_kind": "فروش", "item": item, "tonnage": 100,
                          "price": 2500, "transaction_currency": "USD"})
    case.flags.ignore_permissions = True
    case.insert(ignore_permissions=True)
    frappe.db.commit()

    chk("تناژ کل از اقلام محاسبه شد (۲۰۰)", flt(case.planned_tonnage) == 200.0)
    chk("پرونده به‌درستی «چندارزی» علامت خورد", case.has_multi_currency == 1)
    chk("مبلغ خرید پایه درست است", flt(case.purchase_amount_base) == 1000000000.0)
    chk("مبلغ فروش پایه (دلاری) به ریال تبدیل شد", flt(case.sales_amount_base) > 0)
    chk("سود = فروش − خرید − هزینه عملیاتی",
        flt(case.estimated_profit) == flt(case.sales_amount_base) - flt(case.purchase_amount_base))

    # عدد یکسان در فرم و در API پیش‌نمایش
    from iran_trade_erp.iran_trade.utils.money_engine import get_cost_preview
    prev = get_cost_preview("Trade Case", case.name)
    chk("عدد سود در فرم و در API دقیقاً یکسان است",
        flt(prev["estimated_profit"]) == flt(case.estimated_profit))

    # سناریوی منفی: دستوردهنده بدون نقش مدیرعامل
    blocked = False
    try:
        bad = frappe.new_doc("Trade Case")
        bad.case_title = "خطا"; bad.case_type = "خرید"
        bad.requested_by = "Administrator"; bad.company = company
        bad.posting_date = nowdate()
        bad.append("items", {"row_kind": "خرید", "item": item, "tonnage": 1, "price": 1})
        bad.flags.ignore_permissions = True
        bad.insert(ignore_permissions=True)
    except Exception:
        blocked = True
    chk("مدیر سامانه نمی‌تواند دستوردهنده باشد (سناریوی منفی)", blocked)

    # پارک در «در انتظار تأمین کالا»
    case.fulfillment_status = "در انتظار تأمین کالا"
    case.flags.ignore_permissions = True
    case.save(ignore_permissions=True)
    frappe.db.commit()
    chk("پارک در «در انتظار تأمین کالا» پایدار است",
        frappe.db.get_value("Trade Case", case.name, "fulfillment_status") == "در انتظار تأمین کالا")

    # بستن دستی + Snapshot
    from iran_trade_erp.iran_trade.doctype.trade_case.trade_case import manual_close
    res = manual_close(case.name, "کسری تحویل کارخانه — باسکول کمتر از فاکتور")
    chk("بستن دستی، تصویر باقی‌مانده را نگه می‌دارد", len(res["snapshot"]) == 2)
    chk("دلیل بستن دستی ذخیره شد",
        bool(frappe.db.get_value("Trade Case", case.name, "manual_close_reason")))

    blocked = False
    try:
        manual_close(case.name, "   ")
    except Exception:
        blocked = True
    chk("بستن دستی بدون دلیل مسدود است (سناریوی منفی)", blocked)

    print("\n  Passed: %d | Failed: %d" % (passed, failed))
    if failed:
        raise Exception("verify_script04 FAILED: %d" % failed)
    return "OK"
EOF

bench --site "$SITE_NAME" execute iran_trade_erp.verify_script04.run

cat <<FINAL

============================================================
 script-04.sh با موفقیت تمام شد
------------------------------------------------------------
 Trade Case      : ۴ تب شماره‌دار، مدیرعامل دستوردهنده، ترکیبی/دلالی
 Trade Case Item : چندکالایی + بلوک FX هر ردیف + shipped/remaining
 CEO Request     : میز مدیرعامل + تبدیل کامل به پرونده
 موتور مالی      : یک فرمول، یک عدد، در فرم و API یکسان
 گام بعدی        : bash script-05.sh
============================================================
FINAL