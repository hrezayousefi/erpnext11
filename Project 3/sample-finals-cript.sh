#!/usr/bin/env bash
# =============================================================================
# sample-finals-cript.sh — نمونهٔ «فاز پایانی»: سیم‌کشی رویدادهای واقعی
#                          گردش‌کار خرید/فروش/حمل به ابزار iran_notify
# ERPNext v15 / Frappe v15 | File-First | Idempotent | No bench console
# -----------------------------------------------------------------------------
# ★★★ این یک اسکریپتِ «آماده اجرا روی محیط واقعی» نیست. ★★★
# این یک TEMPLATE/نمونه است که باید بعد از اینکه DocTypeهای واقعیِ ورک‌فلوی
# خرید/فروش/حمل (میز مدیرعامل → پرونده → نهال‌پرور → کارمند → تأییدها →
# حمل → بستن) در فازهای ۳ به بعد ساخته شدند، دقیق‌سازی شود.
#
# این اسکریپت هیچ زیرساخت جدیدی نمی‌سازد. فقط دو کار می‌کند:
#   1) رویدادهای واقعی کسب‌وکاری را به‌عنوان رکوردهای «Notification Event»
#      در اپ iran_notify (که در script-02.sh ساخته شد) می‌کارد.
#   2) در اپ ورک‌فلوی واقعی (نه در iran_notify) چند تابع کوچک «صدازننده»
#      اضافه می‌کند که در نقاط درست گردش‌کار notify() را فرا می‌خوانند.
#
# پیش از اجرا حتماً بخش «نقشهٔ جای‌گزین‌ها» را با نام‌های واقعی پروژهٔ خودتان
# جایگزین کنید. هر جا با CUSTOMIZE-ME علامت‌گذاری شده باید تغییر کند.
# =============================================================================
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=utf-8

# =============================================================================
# نقشهٔ جای‌گزین‌ها (CUSTOMIZE-ME) — همهٔ این‌ها فرضی/نمونه‌اند
# =============================================================================
export SITE_NAME="${SITE_NAME:-transport-dev.local}"
export BENCH_DIR="${BENCH_DIR:-${HOME}/frappe-bench}"

# CUSTOMIZE-ME: نام اپی که ورک‌فلوی واقعی خرید/فروش/حمل در آن پیاده شده است.
# این اپ در این نمونه فرض شده از قبل توسط فازهای ۳ به بعد ساخته شده.
export WORKFLOW_APP="${WORKFLOW_APP:-iran_trade_workflow}"

# CUSTOMIZE-ME: نام DocType واقعی «پرونده» (Case) در اپ ورک‌فلو.
export CASE_DOCTYPE="${CASE_DOCTYPE:-Trade Case}"

# CUSTOMIZE-ME: نام فیلد روی CASE_DOCTYPE که «مدیرعامل دستوردهنده» را نگه می‌دارد.
export CEO_FIELD="${CEO_FIELD:-requested_by}"

# CUSTOMIZE-ME: نام فیلد روی CASE_DOCTYPE که «کارمند مسئول پرونده» را نگه می‌دارد.
export ASSIGNEE_FIELD="${ASSIGNEE_FIELD:-assigned_user}"

# CUSTOMIZE-ME: نام DocType واقعی «فاکتور خرید» برای رویداد بستن دستی.
export PURCHASE_INVOICE_DOCTYPE="${PURCHASE_INVOICE_DOCTYPE:-Purchase Invoice}"

WORKFLOW_PKG="${BENCH_DIR}/apps/${WORKFLOW_APP}/${WORKFLOW_APP}"

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

[[ -d "$BENCH_DIR" ]] || err "Bench یافت نشد: $BENCH_DIR"
cd "$BENCH_DIR"

# =============================================================================
step "0) پیش‌نیاز: iran_notify باید از قبل روی این سایت نصب باشد"
if ! bench --site "$SITE_NAME" list-apps 2>/dev/null | grep -qw "iran_notify"; then
  err "اپ iran_notify روی سایت ${SITE_NAME} نصب نیست. ابتدا script-02.sh را اجرا کنید."
fi
log "iran_notify نصب است — از notify() آن استفاده می‌کنیم، چیزی دوباره نمی‌سازیم"

if [[ ! -d "${WORKFLOW_PKG}" ]]; then
  warn "اپ ورک‌فلوی «${WORKFLOW_APP}» یافت نشد."
  warn "CUSTOMIZE-ME: متغیر WORKFLOW_APP را با نام واقعی اپ گردش‌کار خودتان تنظیم کنید"
  warn "و این اسکریپت را دوباره اجرا کنید. تا آن زمان فقط بخش «کاشت رویدادها» را می‌سازیم."
fi

# =============================================================================
step "1) کاشت رویدادهای واقعی گردش‌کار در iran_notify (Idempotent)"
# -----------------------------------------------------------------------------
# این کاتالوگ دقیقاً از روی ورک‌فلوی توصیف‌شدهٔ کسب‌وکار نوشته شده:
#   میز مدیرعامل -> نهال‌پرور (سرپرست مالی) -> کارمند -> تأییدها ->
#   ★ پیامک نتیجه به همان مدیرعامل، درست پیش از بازگشت به نهال‌پرور ->
#   چاپ سپیدار -> امضا -> حمل -> بستن (با احتساب کسری باسکول)
#
# ستون‌ها هرکدام یک رکورد «Notification Event» در iran_notify می‌سازند.
# send_sms=1 فقط برای مواردی گذاشته شده که واقعاً باید بیرون از سیستم دیده
# شوند (طبق تحلیل ۵ نمونه + تصمیم صریح کارفرما دربارهٔ کنترل هزینه).
write_utf8 "/tmp/iran_notify_seed_workflow_events.py" << PYEOF
# -*- coding: utf-8 -*-
"""بذر رویدادهای واقعی کسب‌وکار روی اپ iran_notify.
اجرا: bench --site \$SITE execute /tmp/iran_notify_seed_workflow_events.run
(یا محتوای EVENTS را در اپ ورک‌فلوی خودتان به‌عنوان ماژول seed نگه دارید)
"""
import frappe

CEO_FIELD = "${CEO_FIELD}"
ASSIGNEE_FIELD = "${ASSIGNEE_FIELD}"

# (event_key, event_title, category, is_critical, send_sms,
#  dynamic_user_field, dynamic_mobile_field, recipient_roles,
#  internal_subject, internal_body, sms_body)
EVENTS = [
    # ── میز مدیرعامل ────────────────────────────────────────────────
    ("ceo_order.submitted", "ثبت دستور خرید/فروش مدیرعامل", "گردش‌کار", 0, 0,
     None, None, ["Finance Supervisor"],
     "دستور جدید مدیرعامل", "دستور جدید ثبت شد: {{name}}", None),

    ("ceo_order.assigned_to_clerk", "ارجاع پرونده به کارمند مالی", "گردش‌کار", 0, 0,
     ASSIGNEE_FIELD, None, [],
     "پرونده به شما ارجاع شد", "پرونده {{name}} به شما ارجاع شد. لطفاً به نام مدیرعامل دستوردهنده آغاز کنید.", None),

    # ── پرونده ──────────────────────────────────────────────────────
    ("case.opened_for_ceo", "تشکیل پرونده به نام مدیرعامل دستوردهنده", "گردش‌کار", 0, 0,
     CEO_FIELD, None, [],
     "پرونده شما تشکیل شد", "پرونده {{name}} به نام شما تشکیل شد.", None),

    ("case.parked_waiting_supply", "ورود به «در انتظار تأمین کالا»", "گردش‌کار", 1, 1,
     CEO_FIELD, None, ["Finance Supervisor"],
     "در انتظار تأمین کالا", "پرونده {{name}} در وضعیت «در انتظار تأمین کالا» قرار گرفت.",
     "پرونده {{name}} در انتظار تأمین کالا قرار گرفت."),

    ("case.legal_rejected", "رد واحد حقوقی", "گردش‌کار", 1, 1,
     ASSIGNEE_FIELD, None, ["Finance Supervisor"],
     "رد حقوقی", "واحد حقوقی پرونده {{name}} را رد کرد. دلیل: {{reason}}",
     "حقوقی پرونده {{name}} را رد کرد. دلیل: {{reason}}"),

    ("case.treasury_rejected", "رد خزانه", "گردش‌کار", 1, 1,
     ASSIGNEE_FIELD, None, ["Finance Supervisor"],
     "رد خزانه", "خزانه پرونده {{name}} را رد کرد. دلیل: {{reason}}",
     "خزانه پرونده {{name}} را رد کرد. دلیل: {{reason}}"),

    # ── ★ نقطهٔ حساس گردش‌کار: دقیقاً پیش از بازگشت به نهال‌پرور ──────
    ("case.result_to_ceo", "★ نتیجه به مدیرعامل دستوردهنده (پیش از بازگشت به نهال‌پرور)",
     "گردش‌کار", 1, 1,
     CEO_FIELD, None, [],
     "نتیجهٔ دستور شما", "پرونده {{name}} — نتیجه: {{outcome}}\n{{reason}}",
     "پرونده {{name}}: {{outcome}} {{reason}}"),

    ("case.returned_to_finance_supervisor", "بازگشت پرونده به نهال‌پرور (سرپرست مالی)",
     "گردش‌کار", 0, 0,
     None, None, ["Finance Supervisor"],
     "بازگشت پرونده", "پرونده {{name}} به میز شما بازگشت. نتیجه: {{outcome}}", None),

    ("case.sepidar_form_printed", "چاپ فرم سپیدار (بیرون از ERPNext)", "گردش‌کار", 0, 0,
     None, None, ["Finance Supervisor"],
     "فرم سپیدار چاپ شد", "فرم سپیدار پرونده {{name}} چاپ شد؛ در انتظار امضای مدیرعامل.", None),

    ("case.signed_by_ceo", "امضای مدیرعامل روی فرم", "گردش‌کار", 0, 0,
     None, None, ["Finance Supervisor", "Transport Supervisor"],
     "امضا انجام شد", "فرم پرونده {{name}} امضا شد. آمادهٔ شروع عملیات حمل.", None),

    # ── عملیات حمل ─────────────────────────────────────────────────
    ("shipment.driver_assigned", "تخصیص راننده به بار", "حمل و ترخیص", 0, 1,
     None, "driver_mobile", ["Transport Supervisor"],
     "تخصیص راننده", "راننده {{driver_name}} با پلاک {{plate_number}} برای {{name}} ثبت شد.",
     "بار {{name}} به شما تخصیص یافت. مقصد: {{destination}}"),

    ("shipment.weighbridge_recorded", "ثبت باسکول (معمولاً با تناژ فاکتور اختلاف دارد)",
     "حمل و ترخیص", 0, 0,
     None, None, ["Finance Supervisor"],
     "ثبت باسکول", "باسکول {{name}} ثبت شد. وزن واقعی: {{actual_tonnage}} تن (برنامه: {{planned_tonnage}} تن).", None),

    # ── بستن پرونده و طلب کارخانه (باسکول هرگز دقیق نمی‌زند) ────────
    ("case.closed_manually", "بستن دستی فاکتور خرید با دلیل (کسری باسکول)",
     "مالی", 1, 1,
     None, None, ["Finance Supervisor", "Financial Manager"],
     "بستن دستی فاکتور", "فاکتور {{name}} به‌صورت دستی بسته شد.\nدلیل: {{reason}}\nکسری: {{shortfall_tonnage}} تن",
     "فاکتور {{name}} دستی بسته شد. دلیل: {{reason}}"),

    ("factory_debt.recorded", "ثبت طلب از کارخانه/منبع (کسری تناژ)", "مالی", 0, 0,
     None, None, ["Finance Supervisor"],
     "طلب از کارخانه", "{{shortfall_tonnage}} تن طلب از {{supplier_factory}} ثبت شد (فاکتور {{name}}).", None),

    ("factory_debt.settled", "تسویهٔ طلب کارخانه", "مالی", 0, 0,
     None, None, ["Finance Supervisor"],
     "تسویهٔ طلب", "طلب از {{supplier_factory}} تسویه شد.", None),
]


def run():
    created, updated, skipped = 0, 0, 0
    for (key, title, category, is_critical, send_sms, dyn_user, dyn_mobile,
         roles, subj, body, sms_body) in EVENTS:

        payload = {
            "event_title": title,
            "category": category,
            "is_active": 1,
            "is_critical": is_critical,
            "send_sms": send_sms,
            "dynamic_user_field": dyn_user,
            "dynamic_mobile_field": dyn_mobile,
            "internal_subject": subj,
            "internal_body": body,
            "sms_body": sms_body,
        }

        if frappe.db.exists("Notification Event", key):
            existing = frappe.get_doc("Notification Event", key)
            if not (existing.is_seed and existing.allow_seed_overwrite):
                skipped += 1
                continue
            for field, value in payload.items():
                if value is not None:
                    existing.set(field, value)
            existing.flags.ignore_permissions = True
            existing.save(ignore_permissions=True)
            updated += 1
            continue

        doc = frappe.get_doc({"doctype": "Notification Event", "event_key": key, **payload})
        for role in roles:
            doc.append("recipient_roles", {"role": role})
        doc.is_seed = 1
        doc.allow_seed_overwrite = 1
        doc.flags.ignore_permissions = True
        doc.insert(ignore_permissions=True)
        created += 1

    frappe.db.commit()
    print("رویدادهای گردش‌کار: {0} ساخته شد، {1} به‌روزرسانی شد، {2} (سفارشی‌شده) دست‌نخورده ماند".format(
        created, updated, skipped))
    return {"created": created, "updated": updated, "skipped": skipped}
PYEOF

bench --site "$SITE_NAME" execute "/tmp/iran_notify_seed_workflow_events.run" 2>/dev/null || {
  warn "اجرای مستقیم فایل موقت با bench execute ممکن نبود (به دلیل مسیر خارج از اپ)."
  warn "CUSTOMIZE-ME: محتوای EVENTS بالا را به فایلی داخل اپ ${WORKFLOW_APP} (مثلاً"
  warn "  apps/${WORKFLOW_APP}/${WORKFLOW_APP}/notify_seed.py) منتقل کنید و از آنجا اجرا کنید:"
  warn "  bench --site ${SITE_NAME} execute ${WORKFLOW_APP}.notify_seed.run"
}

# =============================================================================
step "2) توابع «صدازننده» در اپ ورک‌فلوی واقعی (فقط اگر اپ موجود باشد)"
# -----------------------------------------------------------------------------
# این توابع کوچک، تنها پلی هستند بین رویداد واقعی سند و notify(). هیچ منطق
# کسب‌وکاری اینجا نیست — همهٔ منطق (گیرنده، قالب، کانال) در «Notification
# Event» (که در مرحلهٔ ۱ کاشته شد) تعریف شده است.
if [[ -d "${WORKFLOW_PKG}" ]]; then
  write_utf8 "${WORKFLOW_PKG}/notify_bindings.py" << PYEOF
# -*- coding: utf-8 -*-
"""پل بین رویدادهای واقعی «${CASE_DOCTYPE}» و ابزار عمومی iran_notify.

CUSTOMIZE-ME: نام تابع‌ها را با نام واقعی مراحل گردش‌کار خودتان (متد
تغییر وضعیت / رویداد فرم / اکشن Server Script) وصل کنید. این‌ها فقط
نمونه‌اند و باید در نقطهٔ دقیق کد گردش‌کار شما فراخوانی شوند؛ به‌خودی‌خود
با ذخیرهٔ سند اجرا نمی‌شوند مگر آن‌ها را در hooks.py یا متد controller
سند خودتان صدا بزنید.
"""
from iran_notify import notify


def on_case_opened_for_ceo(doc, method=None):
    notify("case.opened_for_ceo", doc.doctype, doc.name)


def on_case_parked_waiting_supply(doc, method=None, reason=""):
    notify("case.parked_waiting_supply", doc.doctype, doc.name, {"reason": reason})


def on_legal_rejected(doc, method=None, reason=""):
    notify("case.legal_rejected", doc.doctype, doc.name, {"reason": reason})


def on_treasury_rejected(doc, method=None, reason=""):
    notify("case.treasury_rejected", doc.doctype, doc.name, {"reason": reason})


def on_result_to_ceo(doc, method=None, outcome="", reason=""):
    """★ باید دقیقاً یک قدم پیش از فراخوانی on_returned_to_finance_supervisor
    صدا زده شود — طبق نقطهٔ حساس گردش‌کار."""
    notify("case.result_to_ceo", doc.doctype, doc.name, {"outcome": outcome, "reason": reason})


def on_returned_to_finance_supervisor(doc, method=None, outcome=""):
    notify("case.returned_to_finance_supervisor", doc.doctype, doc.name, {"outcome": outcome})


def on_sepidar_form_printed(doc, method=None):
    notify("case.sepidar_form_printed", doc.doctype, doc.name)


def on_signed_by_ceo(doc, method=None):
    notify("case.signed_by_ceo", doc.doctype, doc.name)


def on_purchase_invoice_closed_manually(doc, method=None, reason="", shortfall_tonnage=0):
    notify(
        "case.closed_manually", doc.doctype, doc.name,
        {"reason": reason, "shortfall_tonnage": shortfall_tonnage},
    )
PYEOF

  step "2b) hooks.py اپ ورک‌فلو — فقط بلوک نشانه‌دار؛ ادغام امن"
  python3 - "$WORKFLOW_PKG" "$CASE_DOCTYPE" << PYEOF2
import io, os, re, sys, ast
pkg = sys.argv[1]
case_doctype = sys.argv[2]
hooks = os.path.join(pkg, "hooks.py")
src = ""
if os.path.exists(hooks):
    src = io.open(hooks, encoding="utf-8").read()

START = "# --- IRAN_NOTIFY_WORKFLOW_SAMPLE_HOOKS_START ---"
END = "# --- IRAN_NOTIFY_WORKFLOW_SAMPLE_HOOKS_END ---"
src = re.sub(re.escape(START) + r".*?" + re.escape(END) + r"\n?", "", src, flags=re.S)

module = os.path.basename(pkg)
block = f'''{START}
# CUSTOMIZE-ME: این doc_events فقط نمونه است. رویداد "{case_doctype}" را با
# نام DocType واقعی و متد controller خودتان (validate/on_update/on_submit)
# جایگزین کنید. این پرونده فقط زمانی مفید است که واقعاً بخواهید بر اساس
# on_update عمومی تشخیص دهید، نه یک متد اختصاصی در کنترلر سند.
_in_doc_events = dict(globals().get("doc_events") or {{}})
_case_events = dict(_in_doc_events.get("{case_doctype}") or {{}})
_case_events.setdefault("on_update", "{module}.notify_bindings.on_case_opened_for_ceo")
_in_doc_events["{case_doctype}"] = _case_events
doc_events = _in_doc_events
{END}
'''
src = (src.rstrip() + "\n\n" + block + "\n") if src.strip() else (block + "\n")
io.open(hooks, "w", encoding="utf-8").write(src)
ast.parse(src)
print("hooks.py (workflow sample) updated:", hooks)
PYEOF2
  log "نمونهٔ hooks.py برای ${WORKFLOW_APP} نوشته شد — حتماً بازبینی و دقیق‌سازی کنید"
else
  warn "چون اپ ${WORKFLOW_APP} یافت نشد، مرحلهٔ ۲ (notify_bindings.py + hooks.py) رد شد."
  warn "بعد از ساخت اپ ورک‌فلوی واقعی، این اسکریپت را دوباره با WORKFLOW_APP درست اجرا کنید."
fi

# =============================================================================
step "3) راستی‌آزمایی حداقلی (فقط بخش کاشت رویداد؛ نه سیم‌کشی، چون آن نمونه است)"
write_utf8 "/tmp/iran_notify_verify_workflow_seed.py" << 'PYEOF'
# -*- coding: utf-8 -*-
import frappe


def run():
    passed, failed = 0, 0

    def chk(title, cond):
        nonlocal passed, failed
        if cond:
            passed += 1
            print("  [PASS] " + title)
        else:
            failed += 1
            print("  [FAIL] " + title)

    sample_keys = [
        "ceo_order.submitted", "case.opened_for_ceo", "case.parked_waiting_supply",
        "case.legal_rejected", "case.treasury_rejected", "case.result_to_ceo",
        "case.returned_to_finance_supervisor", "case.sepidar_form_printed",
        "case.signed_by_ceo", "shipment.driver_assigned", "shipment.weighbridge_recorded",
        "case.closed_manually", "factory_debt.recorded", "factory_debt.settled",
    ]
    for key in sample_keys:
        chk("رویداد {0} بذر شده".format(key), bool(frappe.db.exists("Notification Event", key)))

    ceo_result = frappe.db.exists("Notification Event", "case.result_to_ceo")
    if ceo_result:
        doc = frappe.get_doc("Notification Event", "case.result_to_ceo")
        chk("★ case.result_to_ceo پیامکی است (send_sms=1)", bool(doc.send_sms))
        chk("★ case.result_to_ceo حیاتی است (is_critical=1)", bool(doc.is_critical))
        chk("★ case.result_to_ceo گیرنده‌اش فیلد پویای مدیرعامل است",
            bool((doc.dynamic_user_field or "").strip()))

    print("\n  Passed: %d | Failed: %d" % (passed, failed))
    if failed:
        raise Exception("verify_workflow_seed FAILED: %d" % failed)
    return "OK"
PYEOF
bench --site "$SITE_NAME" execute "/tmp/iran_notify_verify_workflow_seed.run" 2>/dev/null || \
  warn "اجرای مستقیم فایل verify موقت ممکن نبود؛ محتوای آن را داخل اپ خودتان کپی کنید."

# =============================================================================
cat <<FINAL

============================================================
 sample-finals-cript.sh اجرا شد (به‌عنوان نمونه/TEMPLATE)
------------------------------------------------------------
 این اسکریپت زیرساخت جدید نساخت — فقط نشان داد چگونه پس از تکمیل
 ورک‌فلوی واقعی خرید/فروش/حمل، از iran_notify.notify() که در فاز ۲
 ساخته شد استفاده کنید.

 قبل از اجرای واقعی روی سایت تولید، حتماً:
   1) WORKFLOW_APP / CASE_DOCTYPE / CEO_FIELD / ASSIGNEE_FIELD را با
      نام‌های واقعی جایگزین کنید.
   2) هر CUSTOMIZE-ME را بخوانید و دقیق‌سازی کنید.
   3) notify_bindings.py را از نقطهٔ درست کد گردش‌کار خودتان (نه صرفاً
      doc_events عمومی) صدا بزنید، مخصوصاً ★ on_result_to_ceo که باید
      دقیقاً یک قدم پیش از on_returned_to_finance_supervisor اجرا شود.

 برای جزئیات کامل به readme-sample-finals-cript.txt مراجعه کنید.
============================================================
FINAL
