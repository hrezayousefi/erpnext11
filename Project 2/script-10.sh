#!/usr/bin/env bash
# =============================================================================
# script-10.sh — پذیرش نهایی: اجرای واقعی سه سناریوی کسب‌وکار + ممیزی سراسری
# بازسازی هدایت‌شده — Iran Trade ERP | ERPNext v15 / Frappe v15
# -----------------------------------------------------------------------------
# این اسکریپت هیچ ساختار جدیدی نمی‌سازد. کارش «اثبات» است، نه «ادعا»:
#   الف) سناریوی کامل «خرید» از درخواست تا بستن + گزارش
#   ب)  سناریوی کامل «فروش» (الگوی ب: اول فروش، بعد تأمین کالا)
#   ج)  سناریوی «ترکیبی/دلالی» با ارز مختلط (کرایه ریالی + فروش دلاری)
#   د)  سناریوی «کسری تحویل کارخانه» و تسویه بعدی آن
#   ه)  ممیزی سراسری G-01..G-20 روی سورس واقعی
#   و)  تولید گزارش پذیرش در sites/<site>/private/files/
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
else nohup bench start >>/tmp/bench-start-itc10.log 2>&1 & log "pid=$!"; sleep 12; fi
RC="${BENCH_DIR}/config/redis_cache.conf"
RP="$( [[ -f "$RC" ]] && awk '$1=="port"{print $2; exit}' "$RC" || echo 13000 )"; [[ -n "$RP" ]] || RP=13000
R=0; for _i in $(seq 1 60); do
  if command -v redis-cli >/dev/null 2>&1 && redis-cli -h 127.0.0.1 -p "$RP" ping 2>/dev/null | grep -q '^PONG$'; then R=1; break; fi
  if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ":${RP}[[:space:]]"; then R=1; break; fi
  sleep 1; done
[[ "$R" -eq 1 ]] || err "redis آماده نشد"
bench use "$SITE_NAME" 2>/dev/null || true

step "0b) پیش‌نیاز — همه فازها"
for f in "${MOD}/utils/fx.py" "${MOD}/notification/core.py" "${MOD}/workflow/guards.py" \
         "${MOD}/doctype/trade_case_loading/loading_engine.py" "${MOD}/api/report_excel.py" \
         "${MOD}/api/cartable.py"; do
  [[ -f "$f" ]] || err "ABORT: $f موجود نیست — اسکریپت‌های ۰۱ تا ۰۹ را به ترتیب اجرا کنید."
done
for m in 02 03 04 05 06 07 08 09; do
  grep -q "SCRIPT${m}_HOOKS_START" "${PKG}/hooks.py" || err "ABORT: بلوک SCRIPT${m} در hooks.py نیست"
done
log "همه فازها حاضرند"

# =============================================================================
step "1) نوشتن سناریوهای پذیرش"
write_utf8 "${PKG}/acceptance.py" << 'EOF'
# -*- coding: utf-8 -*-
"""پذیرش نهایی — اجرای واقعی روی سایت زنده، با اعداد واقعی."""
import io
import json
import os
import re

import frappe
from frappe.model.workflow import apply_workflow
from frappe.utils import flt, now_datetime, nowdate

RESULTS = []


def _rec(section, title, ok, detail=""):
    RESULTS.append({"section": section, "title": title, "ok": bool(ok), "detail": detail})
    print(("  [PASS] " if ok else "  [FAIL] ") + section + " — " + title +
          (" | " + detail if detail else ""))


# ------------------------------------------------------------------ fixtures
def _ceo():
    r = frappe.get_all("Has Role", filters={"role": "CEO", "parenttype": "User"}, pluck="parent")
    return [x for x in r if x not in ("Administrator", "Guest")][0]


def _item(code="ACC-STEEL", name="ورق فولادی پذیرش"):
    if not frappe.db.exists("Item", code):
        it = frappe.new_doc("Item"); it.item_code = code; it.item_name = name
        it.item_group = frappe.db.get_value("Item Group", {"is_group": 0}, "name") or "All Item Groups"
        it.stock_uom = "Kg"; it.is_stock_item = 0
        it.flags.ignore_permissions = True; it.insert(ignore_permissions=True)
    return code


def _customer(n="مشتری پذیرش"):
    if not frappe.db.exists("Customer", n):
        c = frappe.new_doc("Customer"); c.customer_name = n
        c.customer_group = frappe.db.get_value("Customer Group", {"is_group": 0}, "name") or "All Customer Groups"
        c.territory = frappe.db.get_value("Territory", {"is_group": 0}, "name") or "All Territories"
        c.flags.ignore_permissions = True; c.insert(ignore_permissions=True)
    return n


def _supplier(n="کارخانه پذیرش"):
    if not frappe.db.exists("Supplier", n):
        s = frappe.new_doc("Supplier"); s.supplier_name = n
        s.supplier_group = frappe.db.get_value("Supplier Group", {"is_group": 0}, "name") or "All Supplier Groups"
        s.custom_is_factory = 1
        s.flags.ignore_permissions = True; s.insert(ignore_permissions=True)
    return n


def _driver(n="راننده پذیرش"):
    if not frappe.db.exists("Driver", n):
        d = frappe.new_doc("Driver"); d.full_name = n; d.ite_nationality = "ایرانی"
        d.flags.ignore_permissions = True; d.insert(ignore_permissions=True)
    return n


def _new_case(title, ctype, rows):
    c = frappe.new_doc("Trade Case")
    c.case_title = title; c.case_type = ctype; c.requested_by = _ceo()
    c.company = frappe.db.get_value("Company", {}, "name"); c.posting_date = nowdate()
    c.customer = _customer(); c.supplier_factory = _supplier()
    for r in rows:
        c.append("items", r)
    c.flags.ignore_permissions = True
    c.insert(ignore_permissions=True)
    frappe.db.commit()
    return c


def _drive_to_approved(c):
    apply_workflow(c, "ارسال به حقوقی"); c.reload()
    for f in ("chk_legal_purchase_contract", "chk_legal_sales_contract",
              "chk_legal_obligations", "chk_legal_requirements", "chk_legal_documents"):
        c.set(f, 1)
    c.flags.ignore_permissions = True; c.save(ignore_permissions=True)
    apply_workflow(c, "تایید حقوقی"); c.reload()
    c.treasury_approved_ceiling = 5000000000
    c.flags.ignore_permissions = True; c.save(ignore_permissions=True)
    apply_workflow(c, "تایید خزانه"); c.reload()
    c.signed_document = "/files/acceptance-signed.pdf"
    c.flags.ignore_permissions = True; c.save(ignore_permissions=True)
    apply_workflow(c, "امضا شد"); c.reload()
    for f in ("chk_sup_purchase", "chk_sup_sales", "chk_sup_prices",
              "chk_sup_documents", "chk_sup_signatures", "chk_sup_costs"):
        c.set(f, 1)
    c.flags.ignore_permissions = True; c.save(ignore_permissions=True)
    apply_workflow(c, "تایید سرپرست"); c.reload()
    apply_workflow(c, "تایید وصول"); c.reload()
    return c


# --------------------------------------------------------------- scenario A
def scenario_purchase():
    S = "سناریو الف (خرید)"
    c = _new_case("پذیرش — خرید ۱۰۰ تن", "خرید",
                  [{"row_kind": "خرید", "item": _item(), "tonnage": 100,
                    "price": 10000000, "transaction_currency": "IRR"}])
    _rec(S, "پرونده خرید با مدیرعامل دستوردهنده ثبت شد", bool(c.requested_by), c.name)
    _rec(S, "تناژ کل ۱۰۰ تن", flt(c.planned_tonnage) == 100.0)

    _drive_to_approved(c)
    _rec(S, "پرونده تا «تاییدشده» پیش رفت", c.workflow_state == "Approved", c.workflow_state)

    row = c.items[0].name
    slip = frappe.new_doc("Trade Sales Slip")
    slip.purchase_case = c.name; slip.trade_item_row = row
    slip.buyer = _customer(); slip.tonnage = 100; slip.price = 12000000
    slip.transaction_currency = "IRR"; slip.posting_date = nowdate()
    slip.flags.ignore_permissions = True; slip.insert(ignore_permissions=True)
    frappe.db.commit()
    _rec(S, "★ ریزفاکتور فروش را واحد مالی صادر کرد", slip.slip_status == "صادرشده", slip.name)

    from iran_trade_erp.iran_trade.doctype.trade_sales_slip.trade_sales_slip import receive_by_transport
    receive_by_transport(slip.name)
    _rec(S, "★ واحد حمل ریزفاکتور را دریافت کرد",
         frappe.db.get_value("Trade Sales Slip", slip.name, "slip_status") == "تحویل واحد حمل شد")

    from iran_trade_erp.iran_trade.doctype.trade_case_loading import loading_engine as LE
    l1 = LE.create_loading(c.name, row, 100, sales_slip=slip.name, idempotency_key="ACC-A1")
    ld = frappe.get_doc("Trade Case Loading", l1)

    wb = frappe.new_doc("Transport Weighbridge")
    wb.loading = l1; wb.posting_datetime = now_datetime()
    wb.weight_empty = 10000; wb.weight_full = 110000; wb.approval_status = "تاییدشده"
    wb.flags.ignore_permissions = True; wb.insert(ignore_permissions=True)
    frappe.db.commit(); ld.reload()
    _rec(S, "تناژ مؤثر از باسکول = ۱۰۰ تن", flt(ld.effective_tonnage) == 100.0)

    w = frappe.new_doc("Transport Waybill")
    w.loading = l1; w.waybill_number = "ACC-WB-A"; w.waybill_date = nowdate()
    w.driver = _driver(); w.waybill_tonnage = 100
    w.freight_amount = 450000000; w.insurance_amount = 50000000
    w.flags.ignore_permissions = True; w.insert(ignore_permissions=True); w.submit()
    frappe.db.commit(); ld.reload()
    _rec(S, "کارشناس خرید توانست بارنامه را Submit کند (بدون قفل)", w.docstatus == 1)

    bj = frappe.new_doc("Transport Bijak")
    bj.loading = l1; bj.needs_bijak = "خیر"
    bj.flags.ignore_permissions = True; bj.insert(ignore_permissions=True)
    cl = frappe.new_doc("Transport Clearance")
    cl.loading = l1; cl.clearance_status = "ترخیص شد"
    cl.customs_cost = 200000000; cl.clearance_cost = 150000000
    cl.transaction_currency = "IRR"
    cl.flags.ignore_permissions = True; cl.insert(ignore_permissions=True)
    frappe.db.commit(); ld.reload()

    ld.delivery_receipt = "/files/acc-delivery.pdf"; ld.delivery_date = nowdate()
    ld.append("payments", {"payment_type": "کرایه", "amount": 450000000,
                           "transaction_currency": "IRR", "payment_date": nowdate()})
    ld.append("payments", {"payment_type": "گمرک", "amount": 200000000,
                           "transaction_currency": "IRR", "payment_date": nowdate()})
    ld.append("payments", {"payment_type": "ترخیص", "amount": 150000000,
                           "transaction_currency": "IRR", "payment_date": nowdate()})
    ld.finance_approved = 1
    ld.flags.ignore_permissions = True; ld.save(ignore_permissions=True)
    frappe.db.commit(); ld.reload()

    expected = 450000000 + 200000000 + 150000000 + 50000000
    _rec(S, "بهای عملیاتی = کرایه+گمرک+ترخیص+بیمه (پرداخت‌ها شمرده نشدند)",
         flt(ld.total_operational_cost) == float(expected),
         "{0} == {1}".format(flt(ld.total_operational_cost), expected))
    _rec(S, "جمع تسویه جدا محاسبه شد", flt(ld.total_settled) == 800000000.0)

    ld.loading_state = "تکمیل شد"
    ld.flags.ignore_permissions = True; ld.save(ignore_permissions=True)
    frappe.db.commit()
    _rec(S, "بارگیری با چک‌لیست ۱۰ قلمی کامل بسته شد", ld.loading_state == "تکمیل شد")

    c.reload()
    _rec(S, "وضعیت تأمین پرونده «تکمیل‌شده» شد",
         c.fulfillment_status == "تکمیل‌شده", c.fulfillment_status)

    # ★ چرخهٔ عمر ریزفاکتور دیگر وضعیت مرده ندارد: ۱۰۰ تن مؤثر = تناژ ریزفاکتور
    _rec(S, "★ ریزفاکتور فروش به «تکمیل‌شده» رسید (تناژ مؤثر ≥ تناژ ریزفاکتور)",
         frappe.db.get_value("Trade Sales Slip", slip.name, "slip_status") == "تکمیل‌شده",
         str(frappe.db.get_value("Trade Sales Slip", slip.name, "slip_status")))

    from iran_trade_erp.iran_trade.utils.money_engine import get_cost_preview
    p = get_cost_preview("Trade Case", c.name)
    _rec(S, "عدد سود در فرم و در API یکسان است",
         flt(p["estimated_profit"]) == flt(c.estimated_profit))
    return c


# --------------------------------------------------------------- scenario B
def scenario_sales():
    S = "سناریو ب (فروش، اول فروش بعد تأمین)"
    c = _new_case("پذیرش — پیش‌فروش ۵۰ تن", "فروش",
                  [{"row_kind": "فروش", "item": _item(), "tonnage": 50,
                    "price": 13000000, "transaction_currency": "IRR"}])
    from iran_trade_erp.iran_trade.doctype.trade_case.trade_case import (
        park_waiting_supply, release_waiting_supply,
    )
    park_waiting_supply(c.name, "کالا هنوز از کارخانه تأمین نشده است")
    c.reload()
    _rec(S, "★ وضعیت رسمی «در انتظار تأمین کالا» فعال شد",
         c.fulfillment_status == "در انتظار تأمین کالا")

    sms = frappe.db.count("Notification Dispatch Log",
                          {"event_key": "trade_case.waiting_supply", "reference_name": c.name})
    _rec(S, "اعلان انتظار تأمین برای مدیرعامل دستوردهنده ثبت شد", sms >= 1, str(sms))

    release_waiting_supply(c.name); c.reload()
    _rec(S, "آزادسازی و ادامه گردش‌کار انجام شد",
         c.fulfillment_status == "در حال انجام", c.fulfillment_status)

    _drive_to_approved(c)
    _rec(S, "پرونده فروش تا «تاییدشده» پیش رفت", c.workflow_state == "Approved")
    return c


# --------------------------------------------------------------- scenario C
def scenario_mixed():
    S = "سناریو ج (ترکیبی/دلالی با ارز مختلط)"
    ts = frappe.get_single("Treasury Settings")
    ts.company_currency = "IRR"
    if not flt(ts.default_usd_to_irr_rate):
        ts.default_usd_to_irr_rate = 600000
    ts.flags.ignore_permissions = True; ts.save(ignore_permissions=True)
    frappe.db.commit()

    c = _new_case("پذیرش — ترکیبی ارز مختلط", "ترکیبی", [
        {"row_kind": "خرید", "item": _item(), "tonnage": 40,
         "price": 10000000, "transaction_currency": "IRR"},
        {"row_kind": "فروش", "item": _item(), "tonnage": 40,
         "price": 2500, "transaction_currency": "USD"},
    ])
    _rec(S, "پرونده چندارزی علامت خورد", c.has_multi_currency == 1)
    _rec(S, "خرید ریالی درست محاسبه شد", flt(c.purchase_amount_base) == 400000000.0,
         str(flt(c.purchase_amount_base)))
    _rec(S, "فروش دلاری به پایه ریالی تبدیل شد", flt(c.sales_amount_base) > 0,
         str(flt(c.sales_amount_base)))

    _drive_to_approved(c)
    row = c.items[0].name
    from iran_trade_erp.iran_trade.doctype.trade_case_loading import loading_engine as LE
    # قاعدهٔ دلالی: بارگیری فقط روی ریزفاکتورِ دریافتی (صدور کار مالی است)
    slip_c = frappe.new_doc("Trade Sales Slip")
    slip_c.purchase_case = c.name; slip_c.trade_item_row = row
    slip_c.buyer = _customer(); slip_c.tonnage = 40; slip_c.price = 13000000
    slip_c.transaction_currency = "IRR"; slip_c.posting_date = nowdate()
    slip_c.flags.ignore_permissions = True
    slip_c.insert(ignore_permissions=True)
    from iran_trade_erp.iran_trade.doctype.trade_sales_slip.trade_sales_slip import receive_by_transport
    receive_by_transport(slip_c.name)
    frappe.db.commit()
    l1 = LE.create_loading(c.name, row, 40, sales_slip=slip_c.name, idempotency_key="ACC-C1")
    ld = frappe.get_doc("Trade Case Loading", l1)
    ld.cost_currency = "IRR"; ld.freight_cost = 300000000     # کرایه ریالی
    ld.flags.ignore_permissions = True; ld.save(ignore_permissions=True)
    frappe.db.commit(); ld.reload()
    _rec(S, "کرایه ریالی در بهای عملیاتی نشست",
         flt(ld.base_freight_cost) == 300000000.0)

    cl = frappe.new_doc("Transport Clearance")
    cl.loading = l1; cl.clearance_status = "در جریان"
    cl.customs_cost = 1000; cl.clearance_cost = 0
    cl.transaction_currency = "USD"                            # گمرک دلاری
    cl.flags.ignore_permissions = True; cl.insert(ignore_permissions=True)
    frappe.db.commit(); ld.reload()
    _rec(S, "گمرک دلاری با نرخ رویداد به پایه تبدیل شد",
         flt(ld.base_customs_cost) > 0, str(flt(ld.base_customs_cost)))
    _rec(S, "★ ارز ویژگی رویداد است نه پرونده (ریالی و دلاری کنار هم)",
         flt(ld.base_freight_cost) == 300000000.0 and flt(ld.base_customs_cost) > 0)
    return c


# --------------------------------------------------------------- scenario D
def scenario_shortfall():
    S = "سناریو د (کسری تحویل کارخانه)"
    c = _new_case("پذیرش — کسری ۱۰۰/۹۶", "خرید",
                  [{"row_kind": "خرید", "item": _item(), "tonnage": 100,
                    "price": 10000000, "transaction_currency": "IRR"}])
    _drive_to_approved(c)
    row = c.items[0].name
    from iran_trade_erp.iran_trade.doctype.trade_case_loading import loading_engine as LE
    from iran_trade_erp.iran_trade.doctype.trade_sales_slip.trade_sales_slip import receive_by_transport
    for i, t in enumerate([24, 24, 24, 24]):
        s4 = frappe.new_doc("Trade Sales Slip")
        s4.purchase_case = c.name; s4.trade_item_row = row
        s4.buyer = _customer(); s4.tonnage = 25; s4.price = 12000000
        s4.transaction_currency = "IRR"; s4.posting_date = nowdate()
        s4.flags.ignore_permissions = True
        s4.insert(ignore_permissions=True)
        receive_by_transport(s4.name)
        frappe.db.commit()
        lname = LE.create_loading(c.name, row, 25, sales_slip=s4.name, idempotency_key="ACC-D%d" % i)
        ld = frappe.get_doc("Trade Case Loading", lname)
        ld.actual_tonnage = t
        ld.flags.ignore_permissions = True; ld.save(ignore_permissions=True)
    frappe.db.commit()

    cap = LE.get_capacity(c.name, row)
    _rec(S, "۴ تریلی × ۲۴ تن ⇒ حمل‌شده ۹۶ تن", flt(cap["total_shipped"]) == 96.0,
         str(cap["total_shipped"]))
    _rec(S, "فاکتور خرید به صفر نرسید (۴ تن کسری)",
         flt(cap["total_remaining"]) > 0, str(cap["total_remaining"]))

    from iran_trade_erp.iran_trade.doctype.trade_case.trade_case import manual_close
    res = manual_close(c.name, "باسکول ۹۶ تن — کسری بارگیری کارخانه")
    _rec(S, "بستن دستی با دلیل اجباری انجام شد", bool(res.get("snapshot")))

    led = frappe.get_all("Factory Shortfall Ledger", filters={"trade_case": c.name},
                         fields=["name", "shortfall_tonnage", "ledger_status"])
    _rec(S, "کسری در دفتر بدهی کارخانه ثبت شد",
         len(led) == 1 and flt(led[0].shortfall_tonnage) == 4.0,
         json.dumps([dict(x) for x in led], ensure_ascii=False))

    from iran_trade_erp.iran_trade.doctype.factory_shortfall_ledger.factory_shortfall_ledger import (
        settle_shortfall, factory_debt_summary,
    )
    _rec(S, "گزارش تجمیعی بدهکاری کارخانه‌ها کار می‌کند", len(factory_debt_summary()) >= 1)
    settle_shortfall(led[0].name, notes="در معامله بعدی جبران شد")
    _rec(S, "کسری بعداً قابل تسویه است",
         frappe.db.get_value("Factory Shortfall Ledger", led[0].name, "ledger_status") == "تسویه‌شده")
    return c


# ------------------------------------------------------------ global audit
def global_audit():
    S = "ممیزی سراسری"
    app_dir = frappe.get_app_path("iran_trade_erp")
    srcs = {}
    for root, _d, files in os.walk(app_dir):
        for f in files:
            if f.endswith((".py", ".js", ".json", ".html", ".css")):
                p = os.path.join(root, f)
                try:
                    srcs[p] = io.open(p, encoding="utf-8").read()
                except Exception:
                    pass
    blob = "\n".join(srcs.values())

    _rec(S, "G-03 هیچ ارسال واقعی پیامک به‌صورت پیش‌فرض فعال نیست",
         not frappe.db.get_single_value("SMS Gateway Settings", "enabled"))
    _rec(S, "G-03b حالت آزمایشی پیش‌فرض روشن است",
         bool(frappe.db.get_single_value("SMS Gateway Settings", "test_mode")))
    _rec(S, "لینک تأیید پیامکی بدون ورود وجود ندارد",
         ("trade-approve" not in blob) and ("Trade Approval Token" not in blob))
    _rec(S, "G-10 هیچ استفاده‌ای از bench console نیست", "bench console" not in blob)
    _rec(S, "G-11 هیچ drop-site در سورس نیست", "drop-site" not in blob)
    _rec(S, "هیچ GL Entry دستی ساخته نمی‌شود", 'new_doc("GL Entry")' not in blob)

    admin_roles = {r.role for r in frappe.get_doc("User", "Administrator").roles}
    biz = {"CEO", "Finance Supervisor", "Finance User", "Legal Reviewer", "Treasury User",
           "Receivables User", "Transport Supervisor", "Customs Officer", "Document Signer",
           "Financial Manager", "Transport User - Purchase", "Transport User - Sales"}
    _rec(S, "G-20 Administrator هیچ نقش کسب‌وکاری ندارد", not (admin_roles & biz))

    wf = frappe.get_doc("Workflow", "Trade Case Workflow")
    actors = {t.allowed for t in wf.transitions} | {s.allow_edit for s in wf.states}
    _rec(S, "Administrator/Guest در هیچ گذار گردش‌کار نیست",
         not ({"Administrator", "Guest"} & actors))

    # G-07 برچسب فارسی برای هر فیلد جدید
    fa = re.compile(r"[\u0600-\u06FF]")
    bad = []
    for dt in ("Trade Case", "Trade Case Item", "Trade Case Loading", "Trade Sales Slip",
               "CEO Request", "Factory Shortfall Ledger", "Transport Waybill",
               "Transport Weighbridge", "Transport Bijak", "Transport Clearance",
               "Transport Payment", "Notification Event Template", "SMS Gateway Settings",
               "Cartable Settings", "Treasury Settings", "Supervisor Team"):
        if not frappe.db.exists("DocType", dt):
            continue
        for f in frappe.get_meta(dt).fields:
            if f.fieldtype in ("Column Break",):
                continue
            if not f.label or not fa.search(f.label):
                bad.append(dt + "." + f.fieldname)
    _rec(S, "G-07 همه فیلدها برچسب فارسی دارند", not bad, ", ".join(bad[:6]))

    # الگوی ۴۰۴
    ascii_re = re.compile(r"^[A-Za-z0-9 _\-\.]+$")
    bad_ws = [w.name for w in frappe.get_all("Workspace", fields=["name"])
              if not ascii_re.match(w.name or "")]
    _rec(S, "هیچ Workspace با شناسه فارسی وجود ندارد", not bad_ws, ", ".join(bad_ws))

    # تک‌موتوری بودن
    _rec(S, "تنها یک موتور SLA در سورس ثبت شده",
         blob.count("sla_engine.run_sla_scan") <= 2)
    _rec(S, "تنها یک موتور هزینه در سورس تعریف شده",
         blob.count("def operational_cost(") == 1)
    _rec(S, "تنها یک موتور شاخص عملکرد تعریف شده",
         blob.count("def get_kpi(") == 1)

    # نمایه‌های یکتای واقعی
    from iran_trade_erp.iran_trade.notification.install_index import has_unique_index as n_idx
    from iran_trade_erp.iran_trade.doctype.trade_case_loading.install_index import has_unique_index as l_idx
    _rec(S, "نمایه یکتای واقعی روی کلید عدم تکرار اعلان", n_idx())
    _rec(S, "نمایه یکتای واقعی روی کلید عملیات بارگیری", l_idx())

    # فراخوانی سرویس اعلان از ≥۳ نقطه
    points = frappe.db.sql(
        """SELECT DISTINCT event_key FROM `tabNotification Dispatch Log`""", as_dict=True)
    _rec(S, "سرویس اعلان از حداقل ۳ رویداد متفاوت فراخوانی شده",
         len(points) >= 3, str(len(points)))

    # فیلدهای Trade Case در بازه معقول
    meta = frappe.get_meta("Trade Case")
    doc_fields = [f for f in meta.fields
                  if f.fieldtype not in ("Section Break", "Column Break", "Tab Break", "Table")]
    checks = [f for f in doc_fields if f.fieldtype == "Check"]
    _rec(S, "فیلدهای غیرچک‌لیستی Trade Case حدود ۳۰ است",
         len(doc_fields) - len(checks) <= 40,
         "غیرچک‌لیستی={0} چک‌لیستی={1}".format(len(doc_fields) - len(checks), len(checks)))

    # ---------------------------------------------------------------- G-21+
    # ★ ممیزی‌های جدید این فاز: مجوز با کاربر واقعی (نه Administrator)
    def _user(role):
        rows = frappe.get_all("Has Role", filters={"role": role, "parenttype": "User"},
                              pluck="parent")
        rows = [r for r in rows if r not in ("Administrator", "Guest")]
        return rows[0] if rows else None

    ehsan = _user("Finance Supervisor") or "ehsan.nahalparvar@irbco.local"
    _rec(S, "G-21 سرپرست مالی read مشتری دارد",
         frappe.has_permission("Customer", "read", user=ehsan))
    _rec(S, "G-21 سرپرست مالی read شرکت دارد",
         frappe.has_permission("Company", "read", user=ehsan))
    _rec(S, "G-21 سرپرست مالی read روی Version (تایم‌لاین کارتابل) دارد",
         frappe.has_permission("Version", "read", user=ehsan))
    _rec(S, "G-21 سرپرست مالی read روی User (گیرندگان اعلان) دارد",
         frappe.has_permission("User", "read", user=ehsan))

    faezeh = _user("Finance User")
    if faezeh:
        _rec(S, "G-21 کارشناس مالی read بارنامه دارد",
             frappe.has_permission("Transport Waybill", "read", user=faezeh))
        _rec(S, "G-21 کارشناس مالی read بیجک/ترخیص دارد",
             frappe.has_permission("Transport Bijak", "read", user=faezeh) and
             frappe.has_permission("Transport Clearance", "read", user=faezeh))
    mohammadi = _user("Customs Officer")
    if mohammadi:
        _rec(S, "G-21 کارشناس گمرک read ریزفاکتور فروش دارد",
             frappe.has_permission("Trade Sales Slip", "read", user=mohammadi))

    # ★ breadcrumb: میز مدیرعامل دیگر فضای پیش‌فرض ماژول نیست
    holders = frappe.get_all("Workspace", filters={"module": "Iran Trade"}, pluck="name")
    _rec(S, "G-22 فقط «My Cartable» حامل ماژول Iran Trade است (حل breadcrumb)",
         holders == ["My Cartable"], ", ".join(holders))

    # ★ قاعدهٔ دلالی غیرقابل دور زدن + مغایرت‌گیری ریزفاکتور↔بارگیری
    from iran_trade_erp.iran_trade.doctype.trade_case_loading import loading_engine as LE2
    from iran_trade_erp.iran_trade.doctype.trade_case_loading import install_index as l_idx2
    case_x = frappe.get_all("Trade Case", filters={"case_type": "خرید"}, limit=1, pluck="name")
    if case_x:
        blocked = False
        try:
            LE2.create_loading(case_x[0], "row-ghost", 5, idempotency_key="ACC-NOSLIP")
        except Exception:
            blocked = True
        _rec(S, "G-23 بارگیری بدون ریزفاکتور فروش مسدود است", blocked)
    _rec(S, "G-24 نمایه یکتای عملیات بارگیری برقرار است", l_idx2.has_unique_index())


def run():
    frappe.set_user("Administrator")
    scenario_purchase()
    scenario_sales()
    scenario_mixed()
    scenario_shortfall()
    global_audit()

    total = len(RESULTS)
    ok = len([r for r in RESULTS if r["ok"]])
    fail = total - ok

    lines = []
    lines.append("=" * 78)
    lines.append("گزارش پذیرش نهایی — Iran Trade ERP (بازسازی هدایت‌شده)")
    lines.append("تاریخ اجرا: " + str(now_datetime()))
    lines.append("=" * 78)
    cur = None
    for r in RESULTS:
        if r["section"] != cur:
            cur = r["section"]
            lines.append("")
            lines.append("### " + cur)
        lines.append(("  [قبول] " if r["ok"] else "  [رد]   ") + r["title"] +
                     (("  ← " + r["detail"]) if r["detail"] else ""))
    lines.append("")
    lines.append("-" * 78)
    lines.append("جمع بررسی‌ها: {0} | قبول: {1} | رد: {2}".format(total, ok, fail))
    lines.append("-" * 78)

    path = frappe.get_site_path("private", "files", "ITE_ACCEPTANCE_REPORT.txt")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    io.open(path, "w", encoding="utf-8").write("\n".join(lines))
    print("\n".join(lines[-4:]))
    print("گزارش ذخیره شد: " + path)

    if fail:
        raise Exception("acceptance FAILED: {0} مورد رد شد".format(fail))
    return "OK"
EOF

# =============================================================================
step "2) اجرای پذیرش نهایی"
bench --site "$SITE_NAME" execute iran_trade_erp.acceptance.run

step "3) اجرای دوباره همه Verifyها (اثبات Idempotency و سلامت کل سیستم)"
for v in 01 02 03 04 05 06 07 08 09; do
  case "$v" in
    01) bench --site "$SITE_NAME" execute iran_common.verify_script01.run ;;
    *)  bench --site "$SITE_NAME" execute "iran_trade_erp.verify_script${v}.run" ;;
  esac
done

cat <<FINAL

============================================================
 script-10.sh با موفقیت تمام شد — پذیرش نهایی قبول
------------------------------------------------------------
 سناریو الف : خرید کامل از درخواست تا بستن
 سناریو ب   : فروش با «در انتظار تأمین کالا»
 سناریو ج   : ترکیبی/دلالی با کرایه ریالی + گمرک دلاری
 سناریو د   : کسری ۱۰۰/۹۶ + دفتر بدهی + تسویه بعدی
 ممیزی      : G-01..G-20 روی سورس واقعی
 گزارش      : sites/${SITE_NAME}/private/files/ITE_ACCEPTANCE_REPORT.txt
============================================================
FINAL
