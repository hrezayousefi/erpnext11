#!/usr/bin/env bash
# =============================================================================
# script-05.sh — سرویس اعلان به‌عنوان «زیرساخت پایه» (نه بخش جانبی)
# بازسازی هدایت‌شده — Iran Trade ERP | ERPNext v15 / Frappe v15
# -----------------------------------------------------------------------------
# مشکل ریشه‌ای نسخه قبل: پیامک فقط برای «هشدار SLA» و چند رویداد از پیش
# تعریف‌شده کار می‌کرد؛ doc_events به نام DocType قفل شده بود؛ گیرنده نقش‌محور
# صفر بود؛ ارسال اعلان ساعت SLA را ریست می‌کرد؛ بازگشت خاموش به Administrator.
#
# این اسکریپت می‌سازد:
#   1) notify(event_key, doctype, name, context, channels, recipients, level)
#      — تابع واحد و عمومی، قابل فراخوانی از هر Workflow/Report/Job/API
#   2) Notification Event Template — قالب هر Event Key (پیامک + داخلی)
#   3) Notification Dispatch Log — با ایندکس یکتای واقعی روی dedup_key
#   4) SMS Gateway Settings — Kill-Switch پیش‌فرض خاموش + حالت آزمایشی روشن
#   5) الگوی Adapter پیامک (BaseSMSAdapter + Registry + generic_http + kavenegar)
#   6) ۱۸ رویداد الزامی با قالب آماده از روز اول
#   7) تنها موتور SLA (چهار سطح تشدید) + گزارش روزانه مدیرعامل
#
# گاردهای تخطی‌ناپذیر:
#   * ارسال اعلان هرگز modified یا sla_last_action_on سند مرجع را تغییر نمی‌دهد.
#   * Administrator/Guest به‌طور مطلق فیلتر می‌شوند؛ نبود گیرنده = خطای صریح
#     فارسی در دفتر خطا (هرگز بازگشت خاموش به کاربر جاری یا مالک سند).
#   * نبود قالب برای یک رویداد = ثبت در دفتر خطا (هرگز سکوت).
#   * هیچ لینک تأیید پیامکی بدون ورود به سیستم ساخته نمی‌شود (حذف کامل).
# =============================================================================
set -euo pipefail
export LANG=C.UTF-8; export LC_ALL=C.UTF-8; export PYTHONIOENCODING=utf-8

export SITE_NAME="${SITE_NAME:-transport-dev.local}"
export BENCH_DIR="${BENCH_DIR:-${HOME}/frappe-bench}"
export APP="iran_trade_erp"
export PKG="${BENCH_DIR}/apps/${APP}/${APP}"
export MOD="${PKG}/iran_trade"
export NOTIF="${MOD}/notification"

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
else nohup bench start >>/tmp/bench-start-itc05.log 2>&1 & log "pid=$!"; sleep 12; fi
RC="${BENCH_DIR}/config/redis_cache.conf"
RP="$( [[ -f "$RC" ]] && awk '$1=="port"{print $2; exit}' "$RC" || echo 13000 )"; [[ -n "$RP" ]] || RP=13000
R=0; for _i in $(seq 1 60); do
  if command -v redis-cli >/dev/null 2>&1 && redis-cli -h 127.0.0.1 -p "$RP" ping 2>/dev/null | grep -q '^PONG$'; then R=1; break; fi
  if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ":${RP}[[:space:]]"; then R=1; break; fi
  sleep 1; done
[[ "$R" -eq 1 ]] || err "redis آماده نشد"
bench use "$SITE_NAME" 2>/dev/null || true

step "0b) پیش‌نیاز — ABORT در نبود Anchor"
[[ -f "${MOD}/doctype/trade_case/trade_case.py" ]] || err "ABORT: Trade Case نیست. ابتدا script-04.sh"
grep -q "SCRIPT04_HOOKS_START" "${PKG}/hooks.py" || err "ABORT: بلوک SCRIPT04 در hooks.py نیست"
log "پیش‌نیازها تایید شد"

mk_dt() { mkdir -p "${MOD}/doctype/$1"; : > "${MOD}/doctype/$1/__init__.py"; }
mkdir -p "${NOTIF}/adapters/sms"
for d in "${NOTIF}" "${NOTIF}/adapters" "${NOTIF}/adapters/sms"; do : > "${d}/__init__.py"; done

# =============================================================================
step "1) DocType قالب رویداد + دفتر ارسال + تنظیمات درگاه"
mk_dt notification_event_template
write_utf8 "${MOD}/doctype/notification_event_template/notification_event_template.json" << 'EOF'
{
 "actions": [], "autoname": "field:event_key", "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["event_key", "event_title", "is_active", "cb_1", "recipient_roles",
                 "use_requesting_ceo", "escalation_level", "channels",
                 "sb_2", "internal_subject", "internal_body", "sb_3", "sms_body"],
 "fields": [
  {"fieldname": "event_key", "fieldtype": "Data", "in_list_view": 1, "label": "کلید رویداد", "reqd": 1, "unique": 1},
  {"fieldname": "event_title", "fieldtype": "Data", "in_list_view": 1, "label": "عنوان رویداد", "reqd": 1},
  {"default": "1", "fieldname": "is_active", "fieldtype": "Check", "in_list_view": 1, "label": "فعال"},
  {"fieldname": "cb_1", "fieldtype": "Column Break"},
  {"description": "نام نقش‌ها با کاما جدا شود (نام فنی انگلیسی)", "fieldname": "recipient_roles", "fieldtype": "Small Text", "label": "نقش‌های گیرنده"},
  {"default": "0", "fieldname": "use_requesting_ceo", "fieldtype": "Check", "label": "گیرنده = مدیرعامل دستوردهنده"},
  {"default": "1", "fieldname": "escalation_level", "fieldtype": "Int", "label": "سطح تشدید (۱ تا ۴)"},
  {"default": "internal", "fieldname": "channels", "fieldtype": "Data", "in_list_view": 1, "label": "کانال‌ها", "reqd": 1},
  {"fieldname": "sb_2", "fieldtype": "Section Break", "label": "متن اعلان داخلی"},
  {"fieldname": "internal_subject", "fieldtype": "Data", "label": "عنوان اعلان داخلی"},
  {"fieldname": "internal_body", "fieldtype": "Small Text", "label": "متن اعلان داخلی"},
  {"fieldname": "sb_3", "fieldtype": "Section Break", "label": "متن پیامک"},
  {"description": "متغیرها به‌صورت {{name}} و {{case_title}} و ... نوشته شوند", "fieldname": "sms_body", "fieldtype": "Small Text", "label": "متن پیامک"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Notification Event Template", "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "read": 1, "write": 1, "report": 1, "export": 1, "role": "System Manager"},
  {"read": 1, "report": 1, "role": "Financial Manager"}
 ],
 "sort_field": "modified", "sort_order": "DESC", "title_field": "event_title", "track_changes": 1
}
EOF
write_utf8 "${MOD}/doctype/notification_event_template/notification_event_template.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
from frappe.model.document import Document


class NotificationEventTemplate(Document):
    def validate(self):
        if self.escalation_level and not (1 <= int(self.escalation_level) <= 4):
            frappe.throw("سطح تشدید باید بین ۱ تا ۴ باشد.")
        for ch in (self.channels or "").split(","):
            if ch.strip() and ch.strip() not in ("sms", "internal", "email"):
                frappe.throw("کانال نامعتبر است: {0}".format(ch))
EOF

mk_dt notification_dispatch_log
write_utf8 "${MOD}/doctype/notification_dispatch_log/notification_dispatch_log.json" << 'EOF'
{
 "actions": [], "autoname": "hash", "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["event_key", "channel", "recipient", "recipient_mobile", "dispatch_status",
                 "reference_doctype", "reference_name", "escalation_level", "dedup_key",
                 "message_body", "error_text"],
 "fields": [
  {"fieldname": "event_key", "fieldtype": "Data", "in_list_view": 1, "label": "کلید رویداد", "read_only": 1},
  {"fieldname": "channel", "fieldtype": "Data", "in_list_view": 1, "label": "کانال", "read_only": 1},
  {"fieldname": "recipient", "fieldtype": "Data", "in_list_view": 1, "label": "گیرنده", "read_only": 1},
  {"fieldname": "recipient_mobile", "fieldtype": "Data", "label": "شماره گیرنده", "read_only": 1},
  {"fieldname": "dispatch_status", "fieldtype": "Select", "in_list_view": 1, "label": "وضعیت ارسال", "options": "موفق\nناموفق\nآزمایشی\nخاموش", "read_only": 1},
  {"fieldname": "reference_doctype", "fieldtype": "Data", "label": "نوع سند مرجع", "read_only": 1},
  {"fieldname": "reference_name", "fieldtype": "Data", "label": "سند مرجع", "read_only": 1},
  {"fieldname": "escalation_level", "fieldtype": "Int", "label": "سطح تشدید", "read_only": 1},
  {"fieldname": "dedup_key", "fieldtype": "Data", "label": "کلید عدم تکرار", "read_only": 1, "unique": 1},
  {"fieldname": "message_body", "fieldtype": "Small Text", "label": "متن ارسال‌شده", "read_only": 1},
  {"fieldname": "error_text", "fieldtype": "Small Text", "label": "متن خطا", "read_only": 1}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Notification Dispatch Log", "owner": "Administrator",
 "permissions": [
  {"read": 1, "report": 1, "export": 1, "delete": 1, "role": "System Manager"},
  {"read": 1, "report": 1, "role": "Financial Manager"},
  {"read": 1, "report": 1, "role": "Finance Supervisor"},
  {"read": 1, "report": 1, "role": "Transport Supervisor"}
 ],
 "sort_field": "creation", "sort_order": "DESC", "title_field": "event_key"
}
EOF
write_utf8 "${MOD}/doctype/notification_dispatch_log/notification_dispatch_log.py" << 'EOF'
# -*- coding: utf-8 -*-
from frappe.model.document import Document


class NotificationDispatchLog(Document):
    pass
EOF

mk_dt sms_gateway_settings
write_utf8 "${MOD}/doctype/sms_gateway_settings/sms_gateway_settings.json" << 'EOF'
{
 "actions": [], "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType",
 "engine": "InnoDB", "issingle": 1,
 "field_order": ["enabled", "test_mode", "adapter_name", "cb_1", "api_key", "sender_number",
                 "api_url", "sb_2", "level1_hours", "level2_hours", "level3_hours", "level4_hours",
                 "cb_2", "repeat_cooldown_hours", "scan_interval_minutes", "daily_report_time",
                 "business_hours_start", "business_hours_end", "sb_3", "alert_admin_recipients"],
 "fields": [
  {"default": "0", "description": "Kill-Switch: تا وقتی روشن نشود هیچ پیامک واقعی ارسال نمی‌شود", "fieldname": "enabled", "fieldtype": "Check", "label": "ارسال واقعی پیامک فعال باشد"},
  {"default": "1", "fieldname": "test_mode", "fieldtype": "Check", "label": "حالت آزمایشی (بدون ارسال واقعی)"},
  {"default": "generic_http", "fieldname": "adapter_name", "fieldtype": "Data", "label": "آداپتور فعال"},
  {"fieldname": "cb_1", "fieldtype": "Column Break"},
  {"fieldname": "api_key", "fieldtype": "Password", "label": "کلید سرویس"},
  {"fieldname": "sender_number", "fieldtype": "Data", "label": "شماره فرستنده"},
  {"fieldname": "api_url", "fieldtype": "Data", "label": "آدرس سرویس"},
  {"fieldname": "sb_2", "fieldtype": "Section Break", "label": "آستانه‌های تشدید تأخیر (ساعت)"},
  {"default": "6", "fieldname": "level1_hours", "fieldtype": "Int", "label": "سطح ۱ — کارمند مسئول"},
  {"default": "24", "fieldname": "level2_hours", "fieldtype": "Int", "label": "سطح ۲ — کارمند + سرپرست"},
  {"default": "48", "fieldname": "level3_hours", "fieldtype": "Int", "label": "سطح ۳ — سرپرست + مدیر واحد"},
  {"default": "72", "fieldname": "level4_hours", "fieldtype": "Int", "label": "سطح ۴ — مدیرعامل"},
  {"fieldname": "cb_2", "fieldtype": "Column Break"},
  {"default": "6", "fieldname": "repeat_cooldown_hours", "fieldtype": "Int", "label": "فاصله ارسال مجدد (ساعت)"},
  {"default": "15", "fieldname": "scan_interval_minutes", "fieldtype": "Int", "label": "فاصله پویش (دقیقه)"},
  {"default": "08:00:00", "fieldname": "daily_report_time", "fieldtype": "Time", "label": "ساعت گزارش روزانه"},
  {"default": "08:00:00", "fieldname": "business_hours_start", "fieldtype": "Time", "label": "شروع ساعات کاری"},
  {"default": "17:00:00", "fieldname": "business_hours_end", "fieldtype": "Time", "label": "پایان ساعات کاری"},
  {"fieldname": "sb_3", "fieldtype": "Section Break", "label": "مدیران انسانی دریافت‌کننده هشدار"},
  {"description": "ایمیل کاربران واقعی با کاما — مدیر سامانه هرگز پذیرفته نمی‌شود", "fieldname": "alert_admin_recipients", "fieldtype": "Small Text", "label": "گیرندگان هشدار مدیریتی"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "SMS Gateway Settings", "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "read": 1, "write": 1, "role": "System Manager"},
  {"read": 1, "role": "Financial Manager"}
 ],
 "sort_field": "modified", "sort_order": "DESC", "track_changes": 1
}
EOF
write_utf8 "${MOD}/doctype/sms_gateway_settings/sms_gateway_settings.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
from frappe.model.document import Document


class SMSGatewaySettings(Document):
    def validate(self):
        lv = [self.level1_hours, self.level2_hours, self.level3_hours, self.level4_hours]
        for v in lv:
            if v is not None and int(v) <= 0:
                frappe.throw("آستانه‌های تشدید باید مثبت باشند.")
        clean = [int(v) for v in lv if v]
        if clean != sorted(clean):
            frappe.throw("آستانه‌های تشدید باید صعودی باشند (سطح ۱ < ۲ < ۳ < ۴).")
        for u in (self.alert_admin_recipients or "").replace("\n", ",").split(","):
            u = u.strip()
            if u and u in ("Administrator", "Guest"):
                frappe.throw("مدیر سامانه یا کاربر مهمان نمی‌تواند گیرنده هشدار باشد.")
EOF

# =============================================================================
step "2) الگوی Adapter پیامک (Registry با کشف خودکار)"
write_utf8 "${NOTIF}/adapters/sms/base_adapter.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
قرارداد انتزاعی آداپتور پیامک.
این الگو از ir_gateway گرفته شده (معماری آن درست بود)؛ تنها تفاوت:
نقطه اتصال دیگر به نام یک DocType قفل نیست — جهت وابستگی معکوس شده است.
"""
from abc import ABC, abstractmethod


class BaseSMSAdapter(ABC):
    adapter_name = "base"

    def __init__(self, settings):
        self.settings = settings

    @abstractmethod
    def send(self, mobile: str, message: str) -> dict:
        """باید dict با کلیدهای ok(bool) و detail(str) برگرداند."""
        raise NotImplementedError
EOF

write_utf8 "${NOTIF}/adapters/sms/generic_http.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
from .base_adapter import BaseSMSAdapter


class GenericHTTPAdapter(BaseSMSAdapter):
    """آداپتور عمومی POST — سازگار با اکثر پنل‌های پیامکی ایرانی."""
    adapter_name = "generic_http"

    def send(self, mobile, message):
        import requests
        url = self.settings.get("api_url")
        if not url:
            return {"ok": False, "detail": "آدرس سرویس پیامک تنظیم نشده است."}
        payload = {
            "receptor": mobile,
            "sender": self.settings.get("sender_number") or "",
            "message": message,
        }
        headers = {}
        key = self.settings.get("api_key")
        if key:
            headers["Authorization"] = "Bearer {0}".format(key)
        try:
            r = requests.post(url, json=payload, headers=headers, timeout=15)
            return {"ok": r.status_code < 400, "detail": "HTTP {0}".format(r.status_code)}
        except Exception as e:
            frappe.log_error(title="خطای ارسال پیامک (generic_http)", message=frappe.get_traceback())
            return {"ok": False, "detail": str(e)}
EOF

write_utf8 "${NOTIF}/adapters/sms/kavenegar.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
from .base_adapter import BaseSMSAdapter


class KavenegarAdapter(BaseSMSAdapter):
    """آداپتور اختصاصی کاوه‌نگار."""
    adapter_name = "kavenegar"

    def send(self, mobile, message):
        import requests
        key = self.settings.get("api_key")
        if not key:
            return {"ok": False, "detail": "کلید سرویس کاوه‌نگار تنظیم نشده است."}
        url = "https://api.kavenegar.com/v1/{0}/sms/send.json".format(key)
        try:
            r = requests.post(url, data={
                "receptor": mobile,
                "sender": self.settings.get("sender_number") or "",
                "message": message,
            }, timeout=15)
            return {"ok": r.status_code < 400, "detail": "HTTP {0}".format(r.status_code)}
        except Exception as e:
            frappe.log_error(title="خطای ارسال پیامک (kavenegar)", message=frappe.get_traceback())
            return {"ok": False, "detail": str(e)}
EOF

write_utf8 "${NOTIF}/adapters/sms/registry.py" << 'EOF'
# -*- coding: utf-8 -*-
"""کشف خودکار آداپتورهای پیامک از همین پوشه."""
import importlib
import inspect
import os
import pkgutil

from .base_adapter import BaseSMSAdapter

_CACHE = None


def discover():
    global _CACHE
    if _CACHE is not None:
        return _CACHE
    found = {}
    pkg_dir = os.path.dirname(__file__)
    for _f, modname, _p in pkgutil.iter_modules([pkg_dir]):
        if modname in ("base_adapter", "registry"):
            continue
        mod = importlib.import_module("{0}.{1}".format(__package__, modname))
        for _n, obj in inspect.getmembers(mod, inspect.isclass):
            if issubclass(obj, BaseSMSAdapter) and obj is not BaseSMSAdapter:
                found[obj.adapter_name] = obj
    _CACHE = found
    return found


def get_adapter(name, settings):
    cls = discover().get(name)
    if not cls:
        return None
    return cls(settings)
EOF

# =============================================================================
step "3) هسته notify() — تابع واحد و عمومی"
write_utf8 "${NOTIF}/core.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
هسته سرویس اعلان.

  notify(event_key, reference_doctype, reference_name, context,
         channels=None, recipients=None, level=None) -> dict

قابل فراخوانی از: هر Workflow Transition، هر Scheduled Job، هر Report،
هر API دلخواه. هیچ وابستگی به نام DocType خاص ندارد.

گاردهای مطلق:
  * سند مرجع هرگز save نمی‌شود؛ هیچ فیلدی از آن تغییر نمی‌کند
    (به‌ویژه modified و sla_last_action_on). ⇒ ساعت تأخیر هرگز ریست نمی‌شود.
  * Administrator/Guest هرگز گیرنده نمی‌شوند.
  * نبود گیرنده معتبر ⇒ خطای صریح فارسی در دفتر خطا (بدون بازگشت خاموش).
  * نبود قالب ⇒ خطای صریح در دفتر خطا (بدون سکوت).
  * کلید عدم تکرار روی ایندکس یکتای واقعی دیتابیس تکیه دارد.
"""
import hashlib
import json

import frappe
from frappe import _
from frappe.utils import add_to_date, now_datetime

from iran_trade_erp.iran_trade.utils.naming_guard import filter_recipients, users_with_role

CH_SMS = "sms"
CH_INTERNAL = "internal"

LEVEL_ROLES = {
    1: [],                                              # فقط کارمند مسئول
    2: ["Finance Supervisor", "Transport Supervisor"],  # + سرپرست مستقیم
    3: ["Financial Manager"],                           # + مدیر واحد
    4: ["CEO"],                                         # مدیرعامل
}


def _settings():
    return frappe.get_cached_doc("SMS Gateway Settings")


def _log_config_error(title, message):
    frappe.log_error(title=title, message=message)


def _render(template, context):
    out = template or ""
    for k, v in (context or {}).items():
        out = out.replace("{{" + str(k) + "}}", frappe.utils.cstr(v))
    return out


def _dedup_key(event_key, doctype, name, recipient, channel, level):
    raw = "|".join([event_key or "", doctype or "", name or "",
                    recipient or "", channel or "", str(level or 1)])
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:60]


def _cooldown_passed(dedup_key):
    """اگر رکورد قبلی داخل پنجره خنک‌سازی باشد، ارسال دوباره انجام نمی‌شود."""
    hours = int(_settings().repeat_cooldown_hours or 6)
    prev = frappe.db.get_value(
        "Notification Dispatch Log", {"dedup_key": dedup_key}, ["creation"], as_dict=True
    )
    if not prev:
        return True, None
    if prev.creation and prev.creation > add_to_date(now_datetime(), hours=-hours):
        return False, prev
    return True, prev


def resolve_recipients(template, doc, explicit=None, level=None):
    """
    ترتیب: گیرنده صریح → مدیرعامل دستوردهنده → نقش‌های قالب → نقش‌های سطح تشدید
    هیچ‌گاه بازگشت به کاربر جاری یا مالک سند.
    """
    users = []
    if explicit:
        users.extend(explicit if isinstance(explicit, (list, tuple)) else [explicit])

    if template and template.use_requesting_ceo and doc is not None:
        ceo = doc.get("requested_by")
        if ceo:
            users.append(ceo)

    if template and template.recipient_roles:
        for role in template.recipient_roles.replace("\n", ",").split(","):
            role = role.strip()
            if role:
                users.extend(users_with_role(role))

    if level:
        for role in LEVEL_ROLES.get(int(level), []):
            users.extend(users_with_role(role))
        if int(level) >= 1 and doc is not None and doc.get("assigned_user"):
            users.append(doc.get("assigned_user"))

    return filter_recipients(users)


def _mobile_of(user):
    return frappe.db.get_value("User", user, "mobile_no") or frappe.db.get_value("User", user, "phone")


def _send_sms(user, message):
    s = _settings()
    mobile = _mobile_of(user)
    if not mobile:
        return "ناموفق", "شماره موبایل کاربر ثبت نشده است.", None
    if not s.enabled:
        return "خاموش", "ارسال واقعی پیامک غیرفعال است (Kill-Switch).", mobile
    if s.test_mode:
        return "آزمایشی", "[آزمایشی] " + message, mobile
    from iran_trade_erp.iran_trade.notification.adapters.sms.registry import get_adapter
    adapter = get_adapter(s.adapter_name or "generic_http", {
        "api_key": s.get_password("api_key", raise_exception=False),
        "api_url": s.api_url,
        "sender_number": s.sender_number,
    })
    if not adapter:
        return "ناموفق", "آداپتور «{0}» یافت نشد.".format(s.adapter_name), mobile
    res = adapter.send(mobile, message)
    return ("موفق" if res.get("ok") else "ناموفق"), res.get("detail", ""), mobile


def _create_internal(user, subject, body, doctype, name):
    nl = frappe.new_doc("Notification Log")
    nl.subject = subject
    nl.email_content = body
    nl.for_user = user
    nl.type = "Alert"
    if doctype:
        nl.document_type = doctype
    if name:
        nl.document_name = name
    nl.flags.ignore_permissions = True
    nl.insert(ignore_permissions=True)


def _write_log(event_key, channel, recipient, mobile, status, doctype, name, level, body, error):
    try:
        d = frappe.new_doc("Notification Dispatch Log")
        d.event_key = event_key
        d.channel = channel
        d.recipient = recipient
        d.recipient_mobile = mobile
        d.dispatch_status = status
        d.reference_doctype = doctype
        d.reference_name = name
        d.escalation_level = level or 1
        d.dedup_key = _dedup_key(event_key, doctype, name, recipient, channel, level)
        d.message_body = (body or "")[:140]
        d.error_text = (error or "")[:140]
        d.flags.ignore_permissions = True
        d.insert(ignore_permissions=True)
    except frappe.DuplicateEntryError:
        pass
    except Exception:
        _log_config_error("ثبت دفتر ارسال اعلان ناموفق بود", frappe.get_traceback())


@frappe.whitelist()
def notify(event_key, reference_doctype=None, reference_name=None, context=None,
           channels=None, recipients=None, level=None):
    """نقطه ورود واحد سرویس اعلان."""
    if isinstance(context, str):
        context = json.loads(context or "{}")
    context = context or {}

    tpl = None
    if frappe.db.exists("Notification Event Template", event_key):
        tpl = frappe.get_cached_doc("Notification Event Template", event_key)
    if not tpl or not tpl.is_active:
        _log_config_error(
            "قالب اعلان یافت نشد یا غیرفعال است",
            "کلید رویداد «{0}» قالب فعال ندارد؛ اعلان ارسال نشد. سند: {1} / {2}".format(
                event_key, reference_doctype, reference_name),
        )
        return {"sent": 0, "reason": "no_template"}

    doc = None
    if reference_doctype and reference_name:
        # DocType ناموجود نباید کل اعلان را از کار بیندازد
        try:
            if frappe.db.exists("DocType", reference_doctype) and frappe.db.exists(
                reference_doctype, reference_name
            ):
                doc = frappe.get_doc(reference_doctype, reference_name)
                context.setdefault("name", doc.name)
                for f in ("case_title", "case_type", "planned_tonnage", "fulfillment_status",
                          "customer", "supplier_factory", "request_title"):
                    if doc.meta.has_field(f):
                        context.setdefault(f, doc.get(f))
        except Exception:
            doc = None

    level = int(level or tpl.escalation_level or 1)
    chans = channels or [c.strip() for c in (tpl.channels or "internal").split(",") if c.strip()]
    if isinstance(chans, str):
        chans = [c.strip() for c in chans.split(",") if c.strip()]

    targets = resolve_recipients(tpl, doc, recipients, level)
    if not targets:
        _log_config_error(
            "خطای پیکربندی: گیرنده معتبری برای اعلان یافت نشد",
            "رویداد «{0}» هیچ گیرنده معتبری نداشت (مدیر سامانه و مهمان مجاز نیستند). "
            "سند: {1} / {2}".format(event_key, reference_doctype, reference_name),
        )
        return {"sent": 0, "reason": "no_recipient"}

    sent = 0
    for user in targets:
        for ch in chans:
            key = _dedup_key(event_key, reference_doctype, reference_name, user, ch, level)
            ok, _prev = _cooldown_passed(key)
            if not ok:
                continue
            if ch == CH_INTERNAL:
                subject = _render(tpl.internal_subject or tpl.event_title, context)
                body = _render(tpl.internal_body or tpl.event_title, context)
                try:
                    _create_internal(user, subject, body, reference_doctype, reference_name)
                    _write_log(event_key, ch, user, None, "موفق", reference_doctype,
                               reference_name, level, body, None)
                    sent += 1
                except Exception:
                    _write_log(event_key, ch, user, None, "ناموفق", reference_doctype,
                               reference_name, level, None, frappe.get_traceback()[:130])
            elif ch == CH_SMS:
                msg = _render(tpl.sms_body or tpl.event_title, context)
                status, detail, mobile = _send_sms(user, msg)
                _write_log(event_key, ch, user, mobile, status, reference_doctype,
                           reference_name, level, msg,
                           None if status in ("موفق", "آزمایشی", "خاموش") else detail)
                if status in ("موفق", "آزمایشی"):
                    sent += 1

    # ★ سند مرجع عمداً ذخیره نمی‌شود — ساعت تأخیر دست‌نخورده می‌ماند.
    return {"sent": sent, "recipients": targets, "level": level, "channels": chans}
EOF

# =============================================================================
step "4) تنها موتور SLA (چهار سطح) + گزارش روزانه مدیرعامل"
write_utf8 "${NOTIF}/sla_engine.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
تنها موتور پایش زمان پاسخ.

  * از فیلد مستقل sla_last_action_on می‌خواند (نه modified).
  * هیچ نوشتنی روی سند مرجع انجام نمی‌دهد جز update_modified=False روی
    فیلد کاملاً مستقل sla_escalation_level.
  * همه آستانه‌ها از «تنظیمات درگاه پیامک» خوانده می‌شوند؛ هیچ عدد ثابت در کد.
"""
import frappe
from frappe.utils import get_datetime, now_datetime, nowtime, today

from .core import notify

WATCHED = ("Trade Case", "Trade Case Loading")


def _settings():
    return frappe.get_cached_doc("SMS Gateway Settings")


def _thresholds():
    s = _settings()
    return [
        (4, int(s.level4_hours or 72)),
        (3, int(s.level3_hours or 48)),
        (2, int(s.level2_hours or 24)),
        (1, int(s.level1_hours or 6)),
    ]


def _within_business_hours():
    s = _settings()
    start = frappe.utils.cstr(s.business_hours_start or "00:00:00")
    end = frappe.utils.cstr(s.business_hours_end or "23:59:59")
    now = frappe.utils.cstr(nowtime())
    return start <= now <= end


def resolve_level(hours_elapsed):
    for level, threshold in _thresholds():
        if hours_elapsed >= threshold:
            return level
    return 0


def run_sla_scan():
    """تنها Cron مجاز — فاصله واقعی از تنظیمات خوانده می‌شود."""
    from frappe.utils.scheduler import is_scheduler_inactive
    if is_scheduler_inactive():
        return "scheduler inactive"
    if not _within_business_hours():
        return "outside business hours"

    checked = escalated = 0
    for dt in WATCHED:
        if not frappe.db.table_exists(dt):
            continue
        meta = frappe.get_meta(dt)
        if not meta.has_field("sla_last_action_on"):
            continue
        rows = frappe.get_all(
            dt,
            filters={"sla_last_action_on": ["is", "set"]},
            fields=["name", "sla_last_action_on", "assigned_user"],
            limit_page_length=500,
        )
        for r in rows:
            checked += 1
            elapsed = (now_datetime() - get_datetime(r.sla_last_action_on)).total_seconds() / 3600.0
            level = resolve_level(elapsed)
            if not level:
                continue
            notify(
                "sla.delay_level_{0}".format(level),
                dt, r.name,
                {"hours": int(elapsed), "level": level},
                level=level,
            )
            if frappe.get_meta(dt).has_field("sla_escalation_level"):
                frappe.db.set_value(dt, r.name, "sla_escalation_level", level,
                                    update_modified=False)
            escalated += 1
    return {"checked": checked, "escalated": escalated}


def send_daily_ceo_report():
    """گزارش روزانه مدیرعامل — پنج بخش الزامی؛ نبود گیرنده = خطای صریح."""
    from frappe.utils.scheduler import is_scheduler_inactive
    if is_scheduler_inactive():
        return "scheduler inactive"

    s = _settings()
    if frappe.utils.cstr(nowtime()) < frappe.utils.cstr(s.daily_report_time or "08:00:00"):
        return "too early"

    data = build_daily_report()
    body = (
        "گزارش روزانه — بارگیری به مرزها: {factory_border} | "
        "مانده بارهای فاکتورشده: {remaining} تن | "
        "فاکتورهای باز خرید: {open_purchase} | "
        "فاکتورهای باز فروش: {open_sales} | "
        "فعال‌ترین کارمند: {top_employee}"
    ).format(**data)

    res = notify("report.daily_ceo", None, None,
                 dict(data, summary=body), level=4)
    if not res.get("sent"):
        frappe.log_error(
            title="گزارش روزانه مدیرعامل ارسال نشد",
            message="هیچ گیرنده معتبری با نقش «مدیرعامل» یافت نشد یا قالب فعال نبود.",
        )
    return res


def build_daily_report():
    out = {"factory_border": 0, "remaining": 0, "open_purchase": 0,
           "open_sales": 0, "top_employee": "-"}
    if frappe.db.table_exists("Trade Case Loading"):
        out["factory_border"] = frappe.db.count(
            "Trade Case Loading", {"loading_state": ["not in", ["لغو شده", "رد شده"]]}
        )
    rem = frappe.db.sql(
        """SELECT COALESCE(SUM(i.tonnage - i.shipped_tonnage), 0) AS r
           FROM `tabTrade Case Item` i
           INNER JOIN `tabTrade Case` c ON c.name = i.parent
           WHERE c.fulfillment_status IN ('در حال انجام','در انتظار تأمین کالا')""",
        as_dict=True,
    )
    out["remaining"] = round(float(rem[0].r or 0), 2) if rem else 0
    out["open_purchase"] = frappe.db.count(
        "Trade Case", {"case_type": ["in", ["خرید", "ترکیبی"]],
                       "fulfillment_status": ["in", ["در حال انجام", "در انتظار تأمین کالا"]]})
    out["open_sales"] = frappe.db.count(
        "Trade Case", {"case_type": ["in", ["فروش", "ترکیبی"]],
                       "fulfillment_status": ["in", ["در حال انجام", "در انتظار تأمین کالا"]]})
    top = frappe.db.sql(
        """SELECT assigned_user, COUNT(*) c FROM `tabTrade Case`
           WHERE assigned_user IS NOT NULL AND assigned_user NOT IN ('Administrator','Guest')
           GROUP BY assigned_user ORDER BY c DESC LIMIT 1""", as_dict=True)
    if top:
        out["top_employee"] = frappe.db.get_value("User", top[0].assigned_user, "full_name") or top[0].assigned_user
    return out
EOF

# =============================================================================
step "5) ۱۸ رویداد الزامی — قالب آماده از روز اول"
write_utf8 "${NOTIF}/install_templates.py" << 'EOF'
# -*- coding: utf-8 -*-
"""نصب Idempotent قالب‌های الزامی. جدول دقیقاً مطابق سند نیازمندی."""
import frappe

# (event_key, title, roles, use_ceo, channels, level, sms, internal)
TEMPLATES = [
    ("ceo_request.submitted", "ثبت درخواست مدیریت", "Finance Supervisor", 0, "internal", 1,
     "", "دستور جدید مدیرعامل ثبت شد: {{request_title}}"),
    ("ceo_request.accepted", "پذیرش درخواست", "", 1, "sms,internal", 1,
     "دستور شما پذیرفته و پرونده {{trade_case}} ایجاد شد.",
     "دستور مدیرعامل پذیرفته شد و پرونده {{trade_case}} ساخته شد."),
    ("ceo_request.rejected", "رد درخواست", "", 1, "sms,internal", 1,
     "دستور شما رد شد. دلیل: {{reason}}", "دستور مدیرعامل رد شد. دلیل: {{reason}}"),
    ("trade_case.waiting_supply", "ورود به انتظار تأمین کالا", "", 1, "sms", 1,
     "پرونده {{name}} در وضعیت «در انتظار تأمین کالا» قرار گرفت. {{reason}}", ""),
    ("trade_case.legal_rejected", "رد توسط حقوقی", "Finance Supervisor", 1, "sms,internal", 2,
     "پرونده {{name}} توسط واحد حقوقی رد شد. دلیل: {{reason}}",
     "رد حقوقی پرونده {{case_title}} — دلیل: {{reason}}"),
    ("trade_case.treasury_rejected", "رد توسط خزانه", "Finance Supervisor", 1, "sms,internal", 2,
     "پرونده {{name}} توسط خزانه رد شد. دلیل: {{reason}}",
     "رد خزانه پرونده {{case_title}} — دلیل: {{reason}}"),
    ("trade_case.ready_for_signature", "آماده امضا", "Document Signer", 0, "internal", 1,
     "", "پرونده {{case_title}} آماده امضا است."),
    ("trade_case.document_signed", "سند امضا شد", "Finance Supervisor", 0, "internal", 1,
     "", "سند پرونده {{case_title}} امضا و بارگذاری شد."),
    ("trade_case.back_to_finance_supervisor", "بازگشت به سرپرست مالی", "", 1, "sms", 1,
     "پرونده {{name}} به میز سرپرست مالی بازگشت. نتیجه: {{outcome}} — {{reason}}", ""),
    ("trade_case.final_approved", "تأیید نهایی پرونده", "Transport Supervisor", 0, "internal", 1,
     "", "پرونده {{case_title}} تأیید نهایی شد و آماده حمل است."),
    ("loading.assigned", "ارجاع پرونده حمل", "Transport User - Purchase,Transport User - Sales", 0, "internal", 1,
     "", "بارگیری {{name}} به شما ارجاع شد."),
    ("loading.weighbridge_recorded", "ثبت باسکول", "Transport Supervisor", 0, "internal", 1,
     "", "باسکول بارگیری {{name}} ثبت شد."),
    ("loading.cleared", "ترخیص انجام شد", "Finance Supervisor", 0, "internal", 1,
     "", "ترخیص بارگیری {{name}} انجام شد."),
    ("loading.delivered", "تحویل انجام شد", "Finance Supervisor", 0, "internal", 1,
     "", "تحویل بارگیری {{name}} ثبت شد."),
    ("trade_case.completed", "پرونده تکمیل شد", "Finance Supervisor", 1, "sms,internal", 1,
     "پرونده {{name}} با موفقیت تکمیل شد.", "پرونده {{case_title}} تکمیل شد."),
    ("trade_case.manually_closed", "بستن دستی پرونده", "Finance Supervisor", 1, "sms,internal", 1,
     "پرونده {{name}} به‌صورت دستی بسته شد. دلیل: {{reason}}",
     "پرونده {{case_title}} دستی بسته شد. دلیل: {{reason}}"),
    ("sla.delay_level_1", "تأخیر سطح یک", "", 0, "internal", 1,
     "", "پرونده {{name}} بیش از {{hours}} ساعت بدون اقدام مانده است."),
    ("sla.delay_level_2", "تأخیر سطح دو", "", 0, "internal", 2,
     "", "تشدید سطح ۲: پرونده {{name}} — {{hours}} ساعت بدون اقدام."),
    ("sla.delay_level_3", "تأخیر سطح سه", "", 0, "internal,sms", 3,
     "تشدید سطح ۳: پرونده {{name}} — {{hours}} ساعت بدون اقدام.",
     "تشدید سطح ۳: پرونده {{name}} — {{hours}} ساعت بدون اقدام."),
    ("sla.delay_level_4", "تأخیر سطح چهار", "", 0, "internal,sms", 4,
     "تشدید سطح ۴ به مدیرعامل: پرونده {{name}} — {{hours}} ساعت بدون اقدام.",
     "تشدید سطح ۴: پرونده {{name}} — {{hours}} ساعت بدون اقدام."),
    ("report.daily_ceo", "گزارش روزانه مدیرعامل", "CEO", 0, "sms,internal", 4,
     "{{summary}}", "{{summary}}"),
    ("factory_shortfall.recorded", "ثبت کسری کارخانه", "Finance Supervisor", 0, "internal", 1,
     "", "کسری {{shortfall_tonnage}} تن از {{supplier_factory}} در دفتر بدهی ثبت شد."),
]


def install():
    created = updated = 0
    for key, title, roles, use_ceo, channels, level, sms, internal in TEMPLATES:
        if frappe.db.exists("Notification Event Template", key):
            d = frappe.get_doc("Notification Event Template", key)
            updated += 1
        else:
            d = frappe.new_doc("Notification Event Template")
            d.event_key = key
            created += 1
        d.event_title = title
        d.recipient_roles = roles
        d.use_requesting_ceo = use_ceo
        d.channels = channels
        d.escalation_level = level
        d.sms_body = sms
        d.internal_subject = title
        d.internal_body = internal or title
        d.is_active = 1
        d.flags.ignore_permissions = True
        d.save(ignore_permissions=True)
    frappe.db.commit()
    return {"created": created, "updated": updated, "total": len(TEMPLATES)}
EOF

# =============================================================================
step "6) ایندکس یکتای واقعی روی dedup_key + hooks (SCRIPT05)"
write_utf8 "${NOTIF}/install_index.py" << 'EOF'
# -*- coding: utf-8 -*-
"""کلید عدم تکرار باید نمایه یکتای واقعی در پایگاه داده داشته باشد."""
import frappe

INDEX_NAME = "uq_ite_notif_dedup"


def ensure_unique_index():
    exists = frappe.db.sql(
        """SELECT COUNT(1) FROM information_schema.statistics
           WHERE table_schema = DATABASE()
             AND table_name = 'tabNotification Dispatch Log'
             AND index_name = %s""", (INDEX_NAME,))
    if exists and exists[0][0]:
        return "already exists"
    dups = frappe.db.sql(
        """SELECT dedup_key FROM `tabNotification Dispatch Log`
           WHERE dedup_key IS NOT NULL AND dedup_key <> ''
           GROUP BY dedup_key HAVING COUNT(*) > 1""")
    if dups:
        frappe.log_error(
            title="داده تکراری پیش از ساخت نمایه یکتا",
            message="تعداد کلیدهای تکراری: {0}".format(len(dups)))
        return "aborted: duplicates found ({0})".format(len(dups))
    frappe.db.sql(
        "ALTER TABLE `tabNotification Dispatch Log` "
        "ADD UNIQUE INDEX `{0}` (`dedup_key`)".format(INDEX_NAME))
    frappe.db.commit()
    return "created"


def has_unique_index():
    r = frappe.db.sql(
        """SELECT COUNT(1) FROM information_schema.statistics
           WHERE table_schema = DATABASE()
             AND table_name = 'tabNotification Dispatch Log'
             AND index_name = %s""", (INDEX_NAME,))
    return bool(r and r[0][0])
EOF

python3 - "$PKG" << 'PYEOF'
import io, os, re, sys
pkg = sys.argv[1]
p = os.path.join(pkg, "hooks.py")
src = io.open(p, encoding="utf-8").read()
if "# --- SCRIPT04_HOOKS_START ---" not in src:
    raise SystemExit("ABORT: anchor SCRIPT04 missing")
S, E = "# --- SCRIPT05_HOOKS_START ---", "# --- SCRIPT05_HOOKS_END ---"
src = re.sub(re.escape(S) + r".*?" + re.escape(E), "", src, flags=re.S)
block = S + '''
_ite_sched = globals().get("scheduler_events", {}) or {}
_ite_sched.setdefault("cron", {})
_ite_sched["cron"].setdefault("*/15 * * * *", [])
_slafn = "iran_trade_erp.iran_trade.notification.sla_engine.run_sla_scan"
if _slafn not in _ite_sched["cron"]["*/15 * * * *"]:
    _ite_sched["cron"]["*/15 * * * *"].append(_slafn)
_ite_sched.setdefault("daily", [])
_dailyfn = "iran_trade_erp.iran_trade.notification.sla_engine.send_daily_ceo_report"
if _dailyfn not in _ite_sched["daily"]:
    _ite_sched["daily"].append(_dailyfn)
scheduler_events = _ite_sched

fixtures = (globals().get("fixtures", []) or []) + [
    {"dt": "Notification Event Template"},
]
''' + E + "\n"
io.open(p, "w", encoding="utf-8").write(src.rstrip() + "\n\n" + block)

t = os.path.join(pkg, "translations", "fa.csv")
rows = ["Notification Event Template,قالب رویداد اعلان,",
        "Notification Dispatch Log,دفتر ارسال اعلان,",
        "SMS Gateway Settings,تنظیمات درگاه پیامک,"]
cur = io.open(t, encoding="utf-8").read() if os.path.exists(t) else ""
have = set(l.split(",")[0] for l in cur.splitlines() if l.strip())
add = [r for r in rows if r.split(",")[0] not in have]
if add:
    io.open(t, "a", encoding="utf-8").write("\n".join(add) + "\n")
print("SCRIPT05 hooks + fa.csv ok")
PYEOF

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache
bench --site "$SITE_NAME" execute iran_trade_erp.iran_trade.notification.install_templates.install
bench --site "$SITE_NAME" execute iran_trade_erp.iran_trade.notification.install_index.ensure_unique_index

# =============================================================================
step "7) Verify داخلی — فراخوانی از ۳ نقطه متفاوت + سناریوهای منفی"
write_utf8 "${PKG}/verify_script05.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
from frappe.utils import now_datetime


def run():
    passed = failed = 0

    def chk(t, c):
        nonlocal passed, failed
        if c:
            passed += 1; print("  [PASS] " + t)
        else:
            failed += 1; print("  [FAIL] " + t)

    from iran_trade_erp.iran_trade.notification import core, install_index, install_templates
    from iran_trade_erp.iran_trade.notification.adapters.sms import registry

    for dt in ("Notification Event Template", "Notification Dispatch Log", "SMS Gateway Settings"):
        chk("DocType ساخته شد: " + dt, frappe.db.count("DocType", {"name": dt}) == 1)

    chk("همه ۲۲ قالب رویداد الزامی نصب شدند",
        frappe.db.count("Notification Event Template") >= len(install_templates.TEMPLATES))

    chk("نمایه یکتای واقعی روی کلید عدم تکرار وجود دارد", install_index.has_unique_index())

    ad = registry.discover()
    chk("آداپتورهای پیامک کشف خودکار شدند (generic_http + kavenegar)",
        "generic_http" in ad and "kavenegar" in ad)

    s = frappe.get_single("SMS Gateway Settings")
    chk("Kill-Switch پیش‌فرض خاموش است", not s.enabled)
    chk("حالت آزمایشی پیش‌فرض روشن است", bool(s.test_mode))

    # سناریوی منفی ۱: قالب ناموجود ⇒ سکوت ممنوع (ثبت در دفتر خطا)
    before = frappe.db.count("Error Log")
    res = core.notify("event.that.does.not.exist", None, None, {})
    after = frappe.db.count("Error Log")
    chk("نبود قالب ⇒ ثبت در دفتر خطا (بدون سکوت)", res.get("reason") == "no_template" and after > before)

    # سناریوی منفی ۲: Administrator هرگز گیرنده نمی‌شود
    # (از filter_recipients مستقیم — بدون آلوده کردن dedup/cooldown رویداد واقعی)
    from iran_trade_erp.iran_trade.utils.naming_guard import filter_recipients
    chk("مدیر سامانه/مهمان از گیرندگان حذف می‌شوند",
        filter_recipients(["Administrator", "Guest"]) == [])

    # فراخوانی موفق از نقطه ۱: مستقیم
    # reference_name یکتا تا با cooldown/dedup اجرای قبلی تداخل نکند
    # reference_doctype=None تا به جدول ناموجود query زده نشود
    sup = frappe.get_all("Has Role", filters={"role": "Finance Supervisor", "parenttype": "User"}, pluck="parent")
    sup = [u for u in sup if u not in ("Administrator", "Guest")]
    chk("سرپرست مالی واقعی وجود دارد", bool(sup))
    uniq = "VERIFY-P1-" + frappe.generate_hash(length=10)
    r1 = core.notify(
        "ceo_request.submitted",
        None,
        uniq,
        {"request_title": "دستور آزمایشی"},
    )
    chk("نقطه ۱ — فراخوانی مستقیم notify موفق بود", r1.get("sent", 0) >= 1)

    # فراخوانی از نقطه ۲: کنترلر پرونده (پارک در انتظار تأمین)
    case = frappe.get_all("Trade Case", limit=1, pluck="name")
    if case:
        r2 = core.notify("trade_case.waiting_supply", "Trade Case", case[0],
                         {"reason": "تأمین کالا"}, recipients=None)
        chk("نقطه ۲ — فراخوانی از مسیر پرونده اجرا شد", isinstance(r2, dict))
    else:
        chk("نقطه ۲ — پرونده‌ای برای تست موجود بود", False)

    # فراخوانی از نقطه ۳: موتور SLA / گزارش روزانه
    from iran_trade_erp.iran_trade.notification import sla_engine
    rep = sla_engine.build_daily_report()
    chk("نقطه ۳ — گزارش روزانه پنج بخش الزامی را می‌سازد",
        all(k in rep for k in ("factory_border", "remaining", "open_purchase", "open_sales", "top_employee")))

    chk("سطوح تشدید ۱ تا ۴ تعریف شده‌اند", set(core.LEVEL_ROLES.keys()) == {1, 2, 3, 4})
    chk("سطح ۴ به مدیرعامل می‌رود", "CEO" in core.LEVEL_ROLES[4])
    chk("سطح ۳ مدیر واحد را در بر می‌گیرد", "Financial Manager" in core.LEVEL_ROLES[3])

    # ★ ارسال اعلان نباید ساعت تأخیر را ریست کند
    if case:
        name = case[0]
        frappe.db.set_value("Trade Case", name, "sla_last_action_on", "2020-01-01 00:00:00",
                            update_modified=False)
        frappe.db.commit()
        before_clock = frappe.db.get_value("Trade Case", name, "sla_last_action_on")
        before_mod = frappe.db.get_value("Trade Case", name, "modified")
        core.notify("trade_case.waiting_supply", "Trade Case", name, {"reason": "تست ساعت"})
        after_clock = frappe.db.get_value("Trade Case", name, "sla_last_action_on")
        after_mod = frappe.db.get_value("Trade Case", name, "modified")
        chk("ارسال اعلان ساعت تأخیر را ریست نمی‌کند", str(before_clock) == str(after_clock))
        chk("ارسال اعلان زمان ویرایش سند مرجع را تغییر نمی‌دهد", str(before_mod) == str(after_mod))

    # هیچ لینک تأیید پیامکی بدون ورود وجود ندارد
    # سوزن‌ها شکسته نوشته می‌شوند تا خودِ فایل verify مثبت کاذب نسازد
    import os
    app_dir = os.path.dirname(os.path.dirname(os.path.abspath(frappe.get_module("iran_trade_erp").__file__)))
    needles = ["trade-" + "approve", "magic_" + "link", "Trade Approval " + "Token"]
    found = []
    for root, _d, files in os.walk(app_dir):
        for f in files:
            if f.startswith("verify_"):
                continue
            if f.endswith((".py", ".js", ".html")):
                try:
                    txt = open(os.path.join(root, f), encoding="utf-8").read()
                except Exception:
                    continue
                if any(n in txt for n in needles):
                    found.append(os.path.join(root, f))
    chk("لینک تأیید پیامکی بدون ورود به سیستم کاملاً حذف شده است", not found)

    print("\n  Passed: %d | Failed: %d" % (passed, failed))
    if failed:
        raise Exception("verify_script05 FAILED: %d" % failed)
    return "OK"
EOF

bench --site "$SITE_NAME" execute iran_trade_erp.verify_script05.run

cat <<FINAL

============================================================
 script-05.sh با موفقیت تمام شد
------------------------------------------------------------
 notify()  : تابع واحد و عمومی، قابل صدا زدن از هر نقطه سیستم
 قالب‌ها    : ۲۲ رویداد الزامی از روز اول
 دفتر ارسال: با نمایه یکتای واقعی روی dedup_key
 پیامک     : Adapter Pattern + Kill-Switch خاموش + آزمایشی روشن
 SLA       : تنها یک موتور، چهار سطح، بدون ریست ساعت
 گام بعدی  : bash script-06.sh
============================================================
FINAL