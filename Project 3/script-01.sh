#!/usr/bin/env bash
# =============================================================================
# script-01.sh — اپ پایه «iran_common»
# بازسازی هدایت‌شده (Guided Reconstruction) — Iran Trade ERP
# ERPNext v15 / Frappe v15 | File-First | Idempotent | No bench console
# -----------------------------------------------------------------------------
# این اسکریپت اپ عمومی iran_common را می‌سازد و شامل موارد زیر است:
#   1) سنجه‌های اعتبارسنجی ایرانی  — کپی خط‌به‌خط از ir_base/utils/validators.py
#   2) تقویم شمسی کامل — کپی خط‌به‌خط از ir_jalali
#   3) «تنظیمات پایه ایران» + Validation Bypass Log + سابقه تغییر کلیدها
#   4) نقش Settings Manager + ورک‌اسپیس تنظیمات
#   5) بستن دروازهٔ ویزارد Frappe v15 (Installed Application.is_setup_complete)
#   6) ensure_toolbar.js — بازیابی Navbar بالای Desk (باگ Frappe v15)
#   7) fa.csv پایه
#   hooks.py فقط بلوک نشانه‌دار را عوض می‌کند؛ app_include_* ادغام امن می‌شود.
# =============================================================================
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=utf-8

export SITE_NAME="${SITE_NAME:-transport-dev.local}"
export BENCH_DIR="${BENCH_DIR:-${HOME}/frappe-bench}"
export APP="iran_common"
export PKG="${BENCH_DIR}/apps/${APP}/${APP}"

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
step "0) سرویس‌های bench و redis"
if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "bench از قبل در حال اجراست"
else
  nohup bench start >>/tmp/bench-start-itc01.log 2>&1 &
  log "bench start pid=$!"; sleep 12
fi

REDIS_CACHE_CONF="${BENCH_DIR}/config/redis_cache.conf"
if [[ -f "$REDIS_CACHE_CONF" ]]; then
  REDIS_CACHE_PORT="$(awk '$1 == "port" {print $2; exit}' "$REDIS_CACHE_CONF")"
else
  REDIS_CACHE_PORT="13000"
fi
[[ -n "${REDIS_CACHE_PORT:-}" ]] || REDIS_CACHE_PORT="13000"
log "انتظار برای redis_cache روی پورت ${REDIS_CACHE_PORT}"
REDIS_READY=0
for _i in $(seq 1 60); do
  if command -v redis-cli >/dev/null 2>&1; then
    if redis-cli -h 127.0.0.1 -p "$REDIS_CACHE_PORT" ping 2>/dev/null | grep -q '^PONG$'; then
      REDIS_READY=1; break
    fi
  fi
  if command -v ss >/dev/null 2>&1; then
    if ss -lnt 2>/dev/null | grep -q ":${REDIS_CACHE_PORT}[[:space:]]"; then
      REDIS_READY=1; break
    fi
  fi
  sleep 1
done
[[ "$REDIS_READY" -eq 1 ]] || err "redis_cache آماده نشد. /tmp/bench-start-itc01.log را ببینید"
log "redis_cache آماده است"

# =============================================================================
step "0b) اطمینان از وجود سایت (بدون drop-site)"
if [[ ! -d "${BENCH_DIR}/sites/${SITE_NAME}" ]]; then
  err "سایت ${SITE_NAME} وجود ندارد. ابتدا سایت را بسازید (این اسکریپت هرگز سایت حذف/ایجاد نمی‌کند)."
fi
bench use "$SITE_NAME" 2>/dev/null || true
log "سایت: ${SITE_NAME}"

# =============================================================================
step "1) ساخت اپ iran_common"
if [[ -d "${BENCH_DIR}/apps/${APP}" ]]; then
  warn "اپ ${APP} موجود است — فقط فایل‌ها بازنویسی می‌شوند (Force-Replace)"
else
  timeout 120 bash -c 'printf "%s\n" "Iran Common" "Iranian common infrastructure: validators, Jalali calendar, FA helpers" "Iran Trade ERP" "dev@local" "mit" "n" | bench new-app iran_common' \
    || err "bench new-app iran_common failed (timeout/interactive?)"
  log "اپ ${APP} ساخته شد"
fi
mkdir -p "${PKG}/utils" "${PKG}/public/js" "${PKG}/public/css" \
         "${PKG}/iran_common/doctype" "${PKG}/translations" "${PKG}/fixtures"

write_utf8 "${PKG}/modules.txt" << 'MODEOF'
Iran Common
MODEOF

write_utf8 "${PKG}/utils/__init__.py" << 'INITEOF'
INITEOF

# =============================================================================
step "2) کپی خط‌به‌خط سنجه‌های اعتبارسنجی ایرانی (ir_base/utils/validators.py)"
# --- BEGIN VERBATIM COPY: ir_base/utils/validators.py --
write_utf8 "${PKG}/utils/validators.py" << 'IRV_VERBATIM_EOF'
"""
Pure validation and normalization utilities for Iranian data formats.
No DocType dependencies. All validate_* functions raise frappe.throw on failure.
"""

from __future__ import annotations
import re
import frappe
from frappe import _

_PERSIAN_DIGITS = "۰۱۲۳۴۵۶۷۸۹"
_ARABIC_DIGITS = "٠١٢٣٤٥٦٧٨٩"
_ENGLISH_DIGITS = "0123456789"

_DIGIT_TRANSLATION = str.maketrans(
	_PERSIAN_DIGITS + _ARABIC_DIGITS,
	_ENGLISH_DIGITS + _ENGLISH_DIGITS,
)


def persian_to_english_digits(value: str) -> str:
	if value is None:
		return ""
	return str(value).translate(_DIGIT_TRANSLATION)


def validate_iranian_national_id(value: str) -> None:
	if value is None:
		frappe.throw(_("National ID is required"))

	code = persian_to_english_digits(str(value)).strip()

	if not code.isdigit() or len(code) != 10:
		frappe.throw(_("National ID must be exactly 10 digits"))

	if len(set(code)) == 1:
		frappe.throw(_("Invalid National ID"))

	digits = [int(d) for d in code]
	check_digit = digits[9]
	weighted_sum = sum(digits[i] * (10 - i) for i in range(9))
	remainder = weighted_sum % 11

	expected = remainder if remainder < 2 else 11 - remainder

	if check_digit != expected:
		frappe.throw(_("Invalid National ID checksum"))


def validate_iran_mobile(value: str) -> None:
	if value is None:
		frappe.throw(_("Mobile number is required"))

	mobile = persian_to_english_digits(str(value)).strip().replace(" ", "").replace("-", "")

	if not mobile.isdigit() or len(mobile) != 11 or not mobile.startswith("09"):
		frappe.throw(_("Mobile number must be 11 digits starting with 09"))


def validate_sheba(value: str) -> None:
	if value is None:
		frappe.throw(_("SHEBA is required"))

	sheba = (
		persian_to_english_digits(str(value))
		.strip()
		.upper()
		.replace(" ", "")
		.replace("-", "")
	)

	if not sheba.startswith("IR") or len(sheba) != 26 or not sheba[2:].isdigit():
		frappe.throw(_("SHEBA must be IR followed by exactly 24 digits"))

	rearranged = sheba[4:] + sheba[:4]

	numeric_parts = []
	for ch in rearranged:
		if ch.isdigit():
			numeric_parts.append(ch)
		else:
			numeric_parts.append(str(ord(ch) - 55))

	numeric_str = "".join(numeric_parts)

	remainder = 0
	for i in range(0, len(numeric_str), 7):
		block = str(remainder) + numeric_str[i : i + 7]
		remainder = int(block) % 97

	if remainder != 1:
		frappe.throw(_("Invalid SHEBA checksum"))


def normalize_plate(value: str) -> str:
	if value is None:
		return ""

	text = persian_to_english_digits(str(value)).strip().upper()
	text = re.sub(r"[\s\-_./\\]+", " ", text)
	return text.strip()


def verify_validators() -> dict:
	results = {"passed": [], "failed": []}

	def _expect_pass(name, fn, *args):
		try:
			fn(*args)
			results["passed"].append(name)
			print(f"PASS: {name}")
		except Exception as e:
			results["failed"].append(f"{name} -> {e}")
			print(f"FAIL: {name} -> {e}")

	def _expect_fail(name, fn, *args):
		try:
			fn(*args)
			results["failed"].append(f"{name} -> should have raised")
			print(f"FAIL: {name} -> should have raised")
		except Exception:
			results["passed"].append(name)
			print(f"PASS: {name} (correctly raised)")

	assert persian_to_english_digits("۰۹۱۲۳۴۵۶۷۸۹") == "09123456789"
	assert persian_to_english_digits("٠٩١٢") == "0912"
	results["passed"].append("persian_to_english_digits basic")
	print("PASS: persian_to_english_digits basic")

	_expect_pass("national_id valid", validate_iranian_national_id, "0013542419")
	_expect_pass("national_id persian", validate_iranian_national_id, "۰۰۱۳۵۴۲۴۱۹")
	_expect_fail("national_id short", validate_iranian_national_id, "123")
	_expect_fail("national_id zeros", validate_iranian_national_id, "0000000000")
	_expect_fail("national_id bad check", validate_iranian_national_id, "0013542418")

	_expect_pass("mobile valid", validate_iran_mobile, "09123456789")
	_expect_pass("mobile persian", validate_iran_mobile, "۰۹۱۲۳۴۵۶۷۸۹")
	_expect_fail("mobile not 09", validate_iran_mobile, "08123456789")
	_expect_fail("mobile short", validate_iran_mobile, "0912345678")

	_expect_pass("sheba valid", validate_sheba, "IR930150000001351800087201")
	_expect_pass("sheba spaces", validate_sheba, "IR93 0150-0000 0135 1800 0872 01")
	_expect_fail("sheba wrong prefix", validate_sheba, "US930150000001351800087201")
	_expect_fail("sheba short", validate_sheba, "IR93015000000135180008720")
	_expect_fail("sheba bad check", validate_sheba, "IR000000000000000000000000")

	normalized = normalize_plate("  ۱۲ ب  ۳۴۵  ۶۷  ")
	assert "12" in normalized and "345" in normalized
	results["passed"].append("normalize_plate basic")
	print(f"PASS: normalize_plate basic -> '{normalized}'")

	print(f"\n=== SUMMARY ===")
	print(f"Passed: {len(results['passed'])}")
	print(f"Failed: {len(results['failed'])}")
	if results["failed"]:
		for f in results["failed"]:
			print(f"  - {f}")
	else:
		print("All checks passed.")

	return results
IRV_VERBATIM_EOF
# --- END VERBATIM COPY -------------------------------------------------------
log "validators.py کپی شد (بدون تغییر منطق)"

# =============================================================================
step "3) لایه «کلید خاموش‌کردن سنجه‌ها» + لاگ محترمانه"
write_utf8 "${PKG}/utils/guarded.py" << 'GUARDEOF'
# -*- coding: utf-8 -*-
"""
لایه نازک روی validators.py

هدف: توابع خالص validators.py دست‌نخورده باقی می‌مانند (کپی خط‌به‌خط).
این ماژول فقط سه چیز اضافه می‌کند:
  1) امکان «خاموش کردن» یک سنجه خاص از «تنظیمات پایه ایران» (Kill-Switch)
  2) اجرای سنجه فقط برای ملیت ایرانی (کد ملی) و فقط برای پلاک ایرانی
  3) ثبت محترمانه هر عبور/خاموشی در «ثبت عبور از اعتبارسنجی» — هرگز سکوت
"""
import frappe
from frappe import _

from iran_common.utils.validators import (  # noqa: F401
    persian_to_english_digits,
    validate_iranian_national_id,
    validate_iran_mobile,
    validate_sheba,
    normalize_plate,
)

SWITCH_FIELDS = {
    "national_id": "enable_national_id_check",
    "mobile": "enable_mobile_check",
    "sheba": "enable_sheba_check",
    "plate": "enable_plate_check",
}


def _settings():
    try:
        return frappe.get_cached_doc("Iran Common Settings")
    except Exception:
        return None


def is_enabled(kind: str) -> bool:
    """آیا این سنجه روشن است؟ پیش‌فرض: روشن."""
    field = SWITCH_FIELDS.get(kind)
    if not field:
        return True
    s = _settings()
    if not s:
        return True
    return bool(s.get(field, 1))


def log_bypass(kind, value, reference_doctype=None, reference_name=None, reason=""):
    """ثبت محترمانه عبور از اعتبارسنجی — هرگز بی‌صدا رد نمی‌شود."""
    try:
        doc = frappe.get_doc({
            "doctype": "Validation Bypass Log",
            "check_kind": kind,
            "raw_value": frappe.utils.cstr(value)[:140],
            "reference_doctype": reference_doctype,
            "reference_name": reference_name,
            "bypass_reason": reason or _("سنجه توسط تنظیمات پایه ایران خاموش است"),
            "acted_by": frappe.session.user,
        })
        doc.flags.ignore_permissions = True
        doc.insert(ignore_permissions=True)
    except Exception:
        frappe.log_error(
            title="ثبت عبور از اعتبارسنجی ناموفق بود",
            message=frappe.get_traceback(),
        )


def check_national_id(value, nationality="ایرانی", reference_doctype=None, reference_name=None):
    """کد ملی فقط برای ایرانی‌ها اعتبارسنجی می‌شود."""
    if not value:
        return None
    if (nationality or "ایرانی") != "ایرانی":
        return persian_to_english_digits(value)
    if not is_enabled("national_id"):
        log_bypass("کد ملی", value, reference_doctype, reference_name)
        return persian_to_english_digits(value)
    validate_iranian_national_id(value)
    return persian_to_english_digits(value)


def check_mobile(value, reference_doctype=None, reference_name=None):
    if not value:
        return None
    if not is_enabled("mobile"):
        log_bypass("موبایل", value, reference_doctype, reference_name)
        return persian_to_english_digits(value)
    validate_iran_mobile(value)
    return persian_to_english_digits(value)


def check_sheba(value, reference_doctype=None, reference_name=None):
    if not value:
        return None
    if not is_enabled("sheba"):
        log_bypass("شبا", value, reference_doctype, reference_name)
        return persian_to_english_digits(value)
    validate_sheba(value)
    return persian_to_english_digits(value).upper().replace(" ", "")


def check_plate(value, plate_type="ایرانی", reference_doctype=None, reference_name=None):
    """قالب پلاک فقط برای نوع «ایرانی» بررسی می‌شود."""
    if not value:
        return None
    if (plate_type or "ایرانی") != "ایرانی":
        return persian_to_english_digits(value).strip()
    if not is_enabled("plate"):
        log_bypass("پلاک", value, reference_doctype, reference_name)
        return persian_to_english_digits(value).strip()
    return normalize_plate(value)


def mask_sheba(value):
    """شبا ماسک‌شده برای گزارش‌ها: IR93****0872"""
    v = frappe.utils.cstr(value or "").strip()
    if len(v) < 8:
        return v
    return v[:4] + "****" + v[-4:]
GUARDEOF

# =============================================================================
step "4) DocType «تنظیمات پایه ایران» + «ثبت عبور از اعتبارسنجی»"
write_utf8 "${PKG}/iran_common/__init__.py" << 'EOF'
EOF
write_utf8 "${PKG}/iran_common/doctype/__init__.py" << 'EOF'
EOF

mkdir -p "${PKG}/iran_common/doctype/iran_common_settings"
write_utf8 "${PKG}/iran_common/doctype/iran_common_settings/__init__.py" << 'EOF'
EOF
write_utf8 "${PKG}/iran_common/doctype/iran_common_settings/iran_common_settings.json" << 'EOF'
{
 "actions": [],
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "field_order": [
  "sb_switches", "enable_national_id_check", "enable_mobile_check",
  "cb_switches", "enable_sheba_check", "enable_plate_check",
  "sb_calendar", "default_country", "default_calendar_hint", "notes"
 ],
 "fields": [
  {"fieldname": "sb_switches", "fieldtype": "Section Break", "label": "کلید فعال/غیرفعال سنجه‌های ایرانی"},
  {"default": "1", "fieldname": "enable_national_id_check", "fieldtype": "Check", "label": "اعتبارسنجی کد ملی فعال باشد"},
  {"default": "1", "fieldname": "enable_mobile_check", "fieldtype": "Check", "label": "اعتبارسنجی شماره موبایل فعال باشد"},
  {"fieldname": "cb_switches", "fieldtype": "Column Break"},
  {"default": "1", "fieldname": "enable_sheba_check", "fieldtype": "Check", "label": "اعتبارسنجی شماره شبا فعال باشد"},
  {"default": "1", "fieldname": "enable_plate_check", "fieldtype": "Check", "label": "اعتبارسنجی قالب پلاک ایرانی فعال باشد"},
  {"fieldname": "sb_calendar", "fieldtype": "Section Break", "label": "تنظیمات عمومی"},
  {"default": "Iran", "fieldname": "default_country", "fieldtype": "Data", "label": "کشور پیش‌فرض", "read_only": 1},
  {"default": "Jalali (display) / Gregorian (storage)", "fieldname": "default_calendar_hint", "fieldtype": "Data", "label": "قاعده تقویم", "read_only": 1},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "یادداشت"}
 ],
 "issingle": 1,
 "links": [],
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Iran Common",
 "name": "Iran Common Settings",
 "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "email": 1, "print": 1, "read": 1, "role": "System Manager", "share": 1, "write": 1},
  {"create": 0, "delete": 0, "email": 1, "print": 1, "read": 1, "role": "Settings Manager", "share": 0, "write": 1}
 ],
 "sort_field": "modified",
 "sort_order": "DESC",
 "track_changes": 1
}
EOF
write_utf8 "${PKG}/iran_common/doctype/iran_common_settings/iran_common_settings.py" << 'EOF'
# -*- coding: utf-8 -*-
"""Iran Common Settings — Single.

سابقهٔ تغییر کلیدها در «ثبت عبور از اعتبارسنجی» ذخیره می‌شود
(چه کسی / کدام سنجه / روشن→خاموش یا برعکس). Error Log جای audit نیست.
"""
import frappe
from frappe import _
from frappe.model.document import Document

_SWITCH_LABELS = (
    ("enable_national_id_check", "کد ملی"),
    ("enable_mobile_check", "موبایل"),
    ("enable_sheba_check", "شبا"),
    ("enable_plate_check", "پلاک"),
)


class IranCommonSettings(Document):
    def on_update(self):
        before = self.get_doc_before_save()
        for field, label in _SWITCH_LABELS:
            new_val = 1 if self.get(field) else 0
            if before is None:
                old_val = 1
            else:
                old_val = 1 if before.get(field) else 0
            if old_val == new_val:
                continue
            if new_val == 0:
                action = _("خاموش شد")
                raw = "1→0"
            else:
                action = _("روشن شد")
                raw = "0→1"
            self._audit_switch_change(label, raw, action)

    def _audit_switch_change(self, label, raw, action):
        try:
            reason = _(
                "تغییر تنظیمات پایه ایران: سنجه «{0}» {1} توسط {2}"
            ).format(label, action, frappe.session.user)
            doc = frappe.get_doc({
                "doctype": "Validation Bypass Log",
                "check_kind": _("تنظیمات / {0}").format(label),
                "raw_value": raw,
                "reference_doctype": "Iran Common Settings",
                "reference_name": "Iran Common Settings",
                "bypass_reason": reason,
                "acted_by": frappe.session.user,
            })
            doc.flags.ignore_permissions = True
            doc.insert(ignore_permissions=True)
        except Exception:
            frappe.log_error(
                title="ثبت سابقه تغییر تنظیمات پایه ایران ناموفق بود",
                message=frappe.get_traceback(),
            )
EOF

mkdir -p "${PKG}/iran_common/doctype/validation_bypass_log"
write_utf8 "${PKG}/iran_common/doctype/validation_bypass_log/__init__.py" << 'EOF'
EOF
write_utf8 "${PKG}/iran_common/doctype/validation_bypass_log/validation_bypass_log.json" << 'EOF'
{
 "actions": [],
 "autoname": "hash",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "field_order": ["check_kind", "raw_value", "reference_doctype", "reference_name", "acted_by", "bypass_reason"],
 "fields": [
  {"fieldname": "check_kind", "fieldtype": "Data", "in_list_view": 1, "label": "نوع سنجه", "read_only": 1},
  {"fieldname": "raw_value", "fieldtype": "Data", "in_list_view": 1, "label": "مقدار ورودی", "read_only": 1},
  {"fieldname": "reference_doctype", "fieldtype": "Data", "label": "نوع سند مرجع", "read_only": 1},
  {"fieldname": "reference_name", "fieldtype": "Data", "in_list_view": 1, "label": "سند مرجع", "read_only": 1},
  {"fieldname": "acted_by", "fieldtype": "Link", "in_list_view": 1, "label": "کاربر", "options": "User", "read_only": 1},
  {"fieldname": "bypass_reason", "fieldtype": "Small Text", "label": "دلیل عبور", "read_only": 1}
 ],
 "links": [],
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Iran Common",
 "name": "Validation Bypass Log",
 "owner": "Administrator",
 "permissions": [
  {"read": 1, "report": 1, "role": "System Manager", "export": 1},
  {"read": 1, "report": 1, "role": "Financial Manager", "export": 1},
  {"read": 1, "report": 1, "role": "Settings Manager", "export": 1}
 ],
 "sort_field": "creation",
 "sort_order": "DESC",
 "title_field": "check_kind"
}
EOF
write_utf8 "${PKG}/iran_common/doctype/validation_bypass_log/validation_bypass_log.py" << 'EOF'
# -*- coding: utf-8 -*-
from frappe.model.document import Document


class ValidationBypassLog(Document):
    pass
EOF

# =============================================================================
step "4b) Workspace تنظیمات (Settings Manager + System Manager)"
mkdir -p "${PKG}/iran_common/workspace/iran_common"
write_utf8 "${PKG}/iran_common/workspace/iran_common/__init__.py" << 'EOF'
EOF
write_utf8 "${PKG}/iran_common/workspace/iran_common/iran_common.json" << 'EOF'
{
 "charts": [],
 "content": "[{\"id\":\"card_settings\",\"type\":\"card\",\"data\":{\"card_name\":\"Settings\",\"col\":4}}]",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "Workspace",
 "for_user": "",
 "hide_custom": 0,
 "icon": "setting",
 "is_default": 0,
 "is_hidden": 0,
 "is_standard": 1,
 "label": "Iran Common",
 "links": [
  {
   "type": "Card Break",
   "label": "Settings",
   "link_count": 2,
   "hidden": 0,
   "onboard": 0,
   "is_query_report": 0
  },
  {
   "type": "Link",
   "label": "Iran Common Settings",
   "link_type": "DocType",
   "link_to": "Iran Common Settings",
   "hidden": 0,
   "onboard": 0,
   "is_query_report": 0,
   "dependencies": ""
  },
  {
   "type": "Link",
   "label": "Validation Bypass Log",
   "link_type": "DocType",
   "link_to": "Validation Bypass Log",
   "hidden": 0,
   "onboard": 0,
   "is_query_report": 0,
   "dependencies": ""
  }
 ],
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Iran Common",
 "name": "Iran Common",
 "number_cards": [],
 "owner": "Administrator",
 "parent_page": "",
 "public": 1,
 "quick_lists": [],
 "restrict_to_domain": "",
 "roles": [
  {"role": "Settings Manager"},
  {"role": "System Manager"}
 ],
 "sequence_id": 90.0,
 "shortcuts": [
  {
   "type": "DocType",
   "label": "Iran Common Settings",
   "link_to": "Iran Common Settings",
   "doc_view": "",
   "color": "Blue",
   "format": "",
   "stats_filter": ""
  }
 ],
 "title": "Iran Common"
}
EOF

# =============================================================================
step "5) کپی خط‌به‌خط تقویم شمسی (ir_jalali)"
# --- BEGIN VERBATIM COPY: ir_jalali/utils/jalali.py --------------------------
write_utf8 "${PKG}/utils/jalali.py" << 'IRJ_PY_EOF'
"""Jalaali<->Gregorian (reference algorithm). UI Shamsi, DB ALWAYS Gregorian."""
from __future__ import division
import datetime

BREAKS = [-61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181, 1210,
          1635, 2060, 2097, 2192, 2262, 2324, 2394, 2456, 3178]
MONTHS_FA = ["فروردین", "اردیبهشت", "خرداد", "تیر", "مرداد", "شهریور",
             "مهر", "آبان", "آذر", "دی", "بهمن", "اسفند"]
_FA = "۰۱۲۳۴۵۶۷۸۹"

def div(a, b): return int(a / b)
def mod(a, b): return a - div(a, b) * b

def jal_cal(jy):
    gy = jy + 621
    leap_j = -14
    jp = BREAKS[0]
    jump = None
    if jy < jp or jy >= BREAKS[-1]:
        raise Exception("Invalid Jalaali year %s" % jy)
    for i in range(1, len(BREAKS)):
        jm = BREAKS[i]
        jump = jm - jp
        if jy < jm: break
        leap_j = leap_j + div(jump, 33) * 8 + div(mod(jump, 33), 4)
        jp = jm
    n = jy - jp
    leap_j = leap_j + div(n, 33) * 8 + div(mod(n, 33) + 3, 4)
    if mod(jump, 33) == 4 and jump - n == 4: leap_j += 1
    leap_g = div(gy, 4) - div((div(gy, 100) + 1) * 3, 4) - 150
    march = 20 + leap_j - leap_g
    if jump - n < 6: n = n - jump + div(jump + 4, 33) * 33
    leap = mod(mod(n + 1, 33) - 1, 4)
    if leap == -1: leap = 4
    return {"leap": leap, "gy": gy, "march": march}

def g2d(gy, gm, gd):
    d = div((gy + div(gm - 8, 6) + 100100) * 1461, 4) + div(153 * mod(gm + 9, 12) + 2, 5) + gd - 34840408
    d = d - div(div(gy + 100100 + div(gm - 8, 6), 100) * 3, 4) + 752
    return d

def d2g(jdn):
    j = 4 * jdn + 139361631 + div(div(4 * jdn + 183187720, 146097) * 3, 4) * 4 - 3908
    i = div(mod(j, 1461), 4) * 5 + 308
    gd = div(mod(i, 153), 5) + 1
    gm = mod(div(i, 153), 12) + 1
    gy = div(j, 1461) - 100100 + div(8 - gm, 6)
    return {"gy": gy, "gm": gm, "gd": gd}

def j2d(jy, jm, jd):
    r = jal_cal(jy)
    return g2d(r["gy"], 3, r["march"]) + (jm - 1) * 31 - div(jm, 7) * (jm - 7) + jd - 1

def d2j(jdn):
    gy = d2g(jdn)["gy"]
    jy = gy - 621
    r = jal_cal(jy)
    jdn1f = g2d(gy, 3, r["march"])
    k = jdn - jdn1f
    if k >= 0:
        if k <= 185: return {"jy": jy, "jm": div(k, 31) + 1, "jd": mod(k, 31) + 1}
        k -= 186
    else:
        jy -= 1; k += 179
        if r["leap"] == 1: k += 1
    return {"jy": jy, "jm": 7 + div(k, 30), "jd": mod(k, 30) + 1}

def to_jalaali(gy, gm, gd): return d2j(g2d(gy, gm, gd))
def to_gregorian(jy, jm, jd): return d2g(j2d(jy, jm, jd))

def _as_date(value):
    if value is None: return None
    if isinstance(value, datetime.datetime): return value.date(), value
    if isinstance(value, datetime.date): return value, None
    s = str(value).strip()
    if not s: return None
    base = s.split(" ")[0].split("T")[0]
    try: y, m, d = [int(x) for x in base.split("-")]
    except Exception: return None
    return datetime.date(y, m, d), None

def _fa(s): return "".join(_FA[int(c)] if c.isdigit() else c for c in s)

def format_jalali(value, sep="/"):
    p = _as_date(value)
    if not p or not p[0]: return ""
    j = to_jalaali(p[0].year, p[0].month, p[0].day)
    return "%04d%s%02d%s%02d" % (j["jy"], sep, j["jm"], sep, j["jd"])

def format_jalali_fa(value):
    p = _as_date(value)
    if not p or not p[0]: return ""
    j = to_jalaali(p[0].year, p[0].month, p[0].day)
    return _fa("%d %s %d" % (j["jd"], MONTHS_FA[j["jm"] - 1], j["jy"]))

def jalali(value, sep="/"):
    return format_jalali(value, sep)

def jalali_fa(value):
    return format_jalali_fa(value)

def test_jalali():
    cases = [
        ((2025, 3, 20), (1403, 12, 30)),
        ((2025, 3, 21), (1404, 1, 1)),
        ((2026, 3, 21), (1405, 1, 1)),
        ((2026, 8, 13), (1405, 5, 22)),
    ]
    failed = []
    for g, jx in cases:
        r = to_jalaali(*g)
        if (r["jy"], r["jm"], r["jd"]) != jx:
            failed.append("g2j %s -> %s != %s" % (g, (r["jy"], r["jm"], r["jd"]), jx))
        b = to_gregorian(*jx)
        if (b["gy"], b["gm"], b["gd"]) != g:
            failed.append("j2g %s -> %s != %s" % (jx, (b["gy"], b["gm"], b["gd"]), g))
    if format_jalali(datetime.date(2026, 8, 13)) != "1405/05/22": failed.append("format_jalali wrong")
    if format_jalali_fa(datetime.date(2026, 8, 13)) != "۲۲ مرداد ۱۴۰۵": failed.append("format_jalali_fa wrong")
    if failed: raise Exception("JALALI TEST FAILED: " + "; ".join(failed))
    return {"passed": True, "cases": len(cases)}
IRJ_PY_EOF
# --- END VERBATIM COPY -------------------------------------------------------
log "jalali.py کپی شد"

# --- BEGIN VERBATIM COPY: ir_jalali/public/js/jalali_core.js -----------------
write_utf8 "${PKG}/public/js/jalali_core.js" << 'IRJ_CORE_EOF'
/* ir_jalali — Jalaali<->Gregorian (reference algorithm, ported 1:1) */
window.jalali = (function () {
	"use strict";
	var BREAKS = [-61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181, 1210, 1635, 2060, 2097, 2192, 2262, 2324, 2394, 2456, 3178];
	var MONTHS_FA = ["فروردین", "اردیبهشت", "خرداد", "تیر", "مرداد", "شهریور", "مهر", "آبان", "آذر", "دی", "بهمن", "اسفند"];
	var WEEK_FA = ["ش", "ی", "د", "س", "چ", "پ", "ج"];
	var FA = "۰۱۲۳۴۵۶۷۸۹";
	function div(a, b) { return Math.trunc(a / b); }
	function mod(a, b) { return a - div(a, b) * b; }
	function jalCal(jy) {
		var gy = jy + 621, leapJ = -14, jp = BREAKS[0], jm, jump, i, n, leapG, march, leap;
		if (jy < jp || jy >= BREAKS[BREAKS.length - 1]) throw new Error("Invalid Jalaali year " + jy);
		for (i = 1; i < BREAKS.length; i += 1) {
			jm = BREAKS[i]; jump = jm - jp; if (jy < jm) break;
			leapJ = leapJ + div(jump, 33) * 8 + div(mod(jump, 33), 4); jp = jm;
		}
		n = jy - jp; leapJ = leapJ + div(n, 33) * 8 + div(mod(n, 33) + 3, 4);
		if (mod(jump, 33) === 4 && jump - n === 4) leapJ += 1;
		leapG = div(gy, 4) - div((div(gy, 100) + 1) * 3, 4) - 150; march = 20 + leapJ - leapG;
		if (jump - n < 6) n = n - jump + div(jump + 4, 33) * 33;
		leap = mod(mod(n + 1, 33) - 1, 4); if (leap === -1) leap = 4;
		return { leap: leap, gy: gy, march: march };
	}
	function g2d(gy, gm, gd) {
		var d = div((gy + div(gm - 8, 6) + 100100) * 1461, 4) + div(153 * mod(gm + 9, 12) + 2, 5) + gd - 34840408;
		return d - div(div(gy + 100100 + div(gm - 8, 6), 100) * 3, 4) + 752;
	}
	function d2g(jdn) {
		var j = 4 * jdn + 139361631 + div(div(4 * jdn + 183187720, 146097) * 3, 4) * 4 - 3908;
		var i = div(mod(j, 1461), 4) * 5 + 308;
		return { gy: div(j, 1461) - 100100 + div(8 - (mod(div(i, 153), 12) + 1), 6), gm: mod(div(i, 153), 12) + 1, gd: div(mod(i, 153), 5) + 1 };
	}
	function j2d(jy, jm, jd) { var r = jalCal(jy); return g2d(r.gy, 3, r.march) + (jm - 1) * 31 - div(jm, 7) * (jm - 7) + jd - 1; }
	function d2j(jdn) {
		var gy = d2g(jdn).gy, jy = gy - 621, r = jalCal(jy), jdn1f = g2d(gy, 3, r.march), k = jdn - jdn1f;
		if (k >= 0) { if (k <= 185) return { jy: jy, jm: div(k, 31) + 1, jd: mod(k, 31) + 1 }; k -= 186; }
		else { jy -= 1; k += 179; if (r.leap === 1) k += 1; }
		return { jy: jy, jm: 7 + div(k, 30), jd: mod(k, 30) + 1 };
	}
	function isLeapJalaaliYear(jy) { return jalCal(jy).leap === 0; }
	function gregorianToJalaali(gy, gm, gd) { return d2j(g2d(gy, gm, gd)); }
	function jalaaliToGregorian(jy, jm, jd) { return d2g(j2d(jy, jm, jd)); }
	function pad(n) { return (n < 10 ? "0" : "") + n; }
	function faDigits(s) { return String(s).replace(/\d/g, function (d) { return FA[+d]; }); }
	function toLatin(s) { return String(s).replace(/[۰-۹]/g, function (c) { return FA.indexOf(c); }).replace(/[٠-٩]/g, function (c) { return "٠١٢٣٤٥٦٧٨٩".indexOf(c); }); }
	function fromISO(v) {
		if (!v) return null; var m = String(v).match(/^(\d{4})-(\d{1,2})-(\d{1,2})([ T](\d{1,2}:\d{1,2}(:\d{1,2})?))?/);
		if (!m) return null; return { gy: +m[1], gm: +m[2], gd: +m[3], time: m[4] ? m[4].trim() : "" };
	}
	function tryParseJalali(v) {
		if (!v) return null; var m = toLatin(String(v).trim()).match(/^(\d{4})\s*[\/\-.]\s*(\d{1,2})\s*[\/\-.]\s*(\d{1,2})/);
		if (!m) return null; var jy = +m[1]; if (jy < 1300 || jy > 1500) return null; return { jy: jy, jm: +m[2], jd: +m[3] };
	}
	function formatJalali(j, sep, fa) { var s = j.jy + (sep || "/") + pad(j.jm) + (sep || "/") + pad(j.jd); return fa ? faDigits(s) : s; }
	return {
		gregorianToJalaali: gregorianToJalaali, jalaaliToGregorian: jalaaliToGregorian, isLeapJalaaliYear: isLeapJalaaliYear,
		fromISO: fromISO, tryParseJalali: tryParseJalali, formatJalali: formatJalali, faDigits: faDigits, toLatin: toLatin, pad: pad,
		MONTHS_FA: MONTHS_FA, WEEK_FA: WEEK_FA
	};
})();
IRJ_CORE_EOF
# --- END VERBATIM COPY -------------------------------------------------------

# --- BEGIN VERBATIM COPY: ir_jalali/public/js/jalali_picker.js ---------------
write_utf8 "${PKG}/public/js/jalali_picker.js" << 'IRJ_PICK_EOF'
window.jalaliPicker = (function () {
	"use strict";
	var $el = null, state = { jy: 1405, jm: 1 }, onPick = null;
	function monthLen(jy, jm) { if (jm <= 6) return 31; if (jm <= 11) return 30; return window.jalali.isLeapJalaaliYear(jy) ? 30 : 29; }
	function firstWeekday(jy, jm) { var g = window.jalali.jalaaliToGregorian(jy, jm, 1); var d = new Date(Date.UTC(g.gy, g.gm - 1, g.gd)); return (d.getUTCDay() + 1) % 7; }
	function build() {
		var J = window.jalali;
		var html = '<div class="jp-head"><button type="button" class="jp-next" title="ماه بعد">›</button><span class="jp-title">' + J.MONTHS_FA[state.jm - 1] + ' ' + J.faDigits(state.jy) + '</span><button type="button" class="jp-prev" title="ماه قبل">‹</button><button type="button" class="jp-today">امروز</button></div><table class="jp-grid"><tr>';
		J.WEEK_FA.forEach(function (w) { html += "<th>" + w + "</th>"; }); html += "</tr><tr>";
		var fw = firstWeekday(state.jy, state.jm), len = monthLen(state.jy, state.jm), i;
		for (i = 0; i < fw; i++) html += "<td></td>";
		for (i = 1; i <= len; i++) { if ((fw + i - 1) % 7 === 0 && i > 1) html += "</tr><tr>"; html += '<td><button type="button" class="jp-day" data-d="' + i + '">' + J.faDigits(i) + "</button></td>"; }
		html += "</tr></table>"; $el.find(".jp-body").html(html);
	}
	function close() { if ($el) $el.hide(); }
	function open($input, cb) {
		onPick = cb; var J = window.jalali; var cur = J.tryParseJalali($input.val() || "");
		if (cur) state = { jy: cur.jy, jm: cur.jm };
		else { var n = new Date(); var j = J.gregorianToJalaali(n.getFullYear(), n.getMonth() + 1, n.getDate()); state = { jy: j.jy, jm: j.jm }; }
		if (!$el) {
			$el = $('<div class="jalali-popup" dir="rtl"><div class="jp-body"></div></div>').appendTo("body");
			$el.on("click", ".jp-prev", function () { state.jm -= 1; if (state.jm < 1) { state.jm = 12; state.jy -= 1; } build(); });
			$el.on("click", ".jp-next", function () { state.jm += 1; if (state.jm > 12) { state.jm = 1; state.jy += 1; } build(); });
			$el.on("click", ".jp-today", function () { var n = new Date(); var j = J.gregorianToJalaali(n.getFullYear(), n.getMonth() + 1, n.getDate()); state = { jy: j.jy, jm: j.jm }; build(); });
			$el.on("click", ".jp-day", function () { var j = { jy: state.jy, jm: state.jm, jd: +$(this).data("d") }; close(); if (onPick) onPick(j); });
			$(document).on("mousedown.jalaliPopup", function (e) { if ($el && $el.is(":visible") && !$el.is(e.target) && $el.has(e.target).length === 0 && !$(e.target).closest(".date-input").length) close(); });
		}
		var off = $input.offset(); $el.css({ top: off.top + $input.outerHeight() + 2, left: Math.max(8, off.left - 220) }).show(); build();
	}
	return { open: open, close: close };
})();
IRJ_PICK_EOF
# --- END VERBATIM COPY -------------------------------------------------------

# --- BEGIN VERBATIM COPY: ir_jalali/public/js/controls_patch.js --------------
write_utf8 "${PKG}/public/js/controls_patch.js" << 'IRJ_CTRL_EOF'
(function () {
	"use strict";
	function pad(n) { return (n < 10 ? "0" : "") + n; }
	function patchAll() {
		if (!window.frappe || !frappe.ui || !frappe.ui.form || !frappe.ui.form.ControlDate) return false;
		var J = window.jalali; var D = frappe.ui.form.ControlDate; if (D.__jalali) return true; D.__jalali = true;
		D.prototype.set_formatted_input = function (value) {
			this.value = value; if (!this.$input) return; var g = value ? J.fromISO(value) : null;
			if (g) { var j = J.gregorianToJalaali(g.gy, g.gm, g.gd); var txt = J.formatJalali(j, "/", true); if (g.time) txt += " " + J.faDigits(g.time); this.$input.val(txt); } else { this.$input.val(""); }
		};
		var origParse = D.prototype.parse;
		D.prototype.parse = function (value) {
			if (value) { var s = String(value); var tm = s.match(/[ T](\d{1,2}:\d{1,2}(:\d{1,2})?)\s*$/); var time = tm ? tm[1] : ""; var j = J.tryParseJalali(s);
				if (j) { var g = J.jalaaliToGregorian(j.jy, j.jm, j.jd); value = g.gy + "-" + pad(g.gm) + "-" + pad(g.gd) + (time ? " " + time : ""); } }
			return origParse ? origParse.call(this, value) : value;
		};
		var origMake = D.prototype.make_input;
		D.prototype.make_input = function () {
			if (origMake) origMake.call(this); var ctrl = this; if (!ctrl.$input || ctrl.$input.data("jalaliBound")) return;
			ctrl.$input.data("jalaliBound", 1).attr("autocomplete", "off");
			ctrl.$input.on("mousedown.jalali", function (e) {
				e.preventDefault(); e.stopImmediatePropagation();
				window.jalaliPicker.open(ctrl.$input, function (j) { var g0 = ctrl.value ? J.fromISO(ctrl.value) : null; var time = g0 && g0.time ? " " + g0.time : ""; ctrl.$input.val(J.formatJalali(j, "/", true) + time); ctrl.$input.trigger("change"); });
			});
		};
		return true;
	}
	$(function () { setTimeout(patchAll, 300); });
	$(document).on("app_ready startup", function () { patchAll(); });
})();
IRJ_CTRL_EOF
# --- END VERBATIM COPY -------------------------------------------------------

# --- BEGIN VERBATIM COPY: ir_jalali/public/css/jalali_picker.css -------------
write_utf8 "${PKG}/public/css/jalali_picker.css" << 'IRJ_CSS_EOF'
.jalali-popup{position:absolute;z-index:10000;background:#fff;border:1px solid #d1d8dd;border-radius:8px;box-shadow:0 4px 16px rgba(0,0,0,.15);padding:8px;width:252px;display:none;direction:rtl;font-size:12px}
.jalali-popup .jp-head{display:flex;align-items:center;gap:6px;margin-bottom:6px}
.jalali-popup .jp-title{flex:1;text-align:center;font-weight:600}
.jalali-popup button{border:none;background:#f1f4f6;border-radius:6px;padding:4px 8px;cursor:pointer}
.jalali-popup button:hover{background:#e2e6e9}
.jalali-popup table.jp-grid{width:100%;border-collapse:collapse}
.jalali-popup .jp-grid th{color:#6c7680;font-weight:500;padding:2px}
.jalali-popup .jp-grid td{text-align:center;padding:1px}
.jalali-popup .jp-day{width:28px;height:26px}
IRJ_CSS_EOF
# --- END VERBATIM COPY -------------------------------------------------------
log "تقویم شمسی (py + 3 فایل js + css) کپی شد"

# =============================================================================
step "5b) REAL FIX 2 — public/js/ensure_toolbar.js (Navbar دائمی)"
# --- BEGIN VERBATIM COPY: setup_realign_gate.sh ensure_toolbar.js ------------
# تنها تغییر مجاز: پیشوند لاگ transport_ir → iran_common (مسیر assets هم iran_common)
write_utf8 "${PKG}/public/js/ensure_toolbar.js" << 'EOF'
/* iran_common — ensure the Desk top navbar exists.
 *
 * Background: on some Frappe v15 installs (notably docker-based), the desk
 * boots without instantiating frappe.ui.toolbar.Toolbar, so the top navbar
 * (search / notifications / help / avatar) is missing. The known workaround
 * (frappe_docker#1804) is:
 *     frappe.ui.toolbar_obj = new frappe.ui.toolbar.Toolbar();
 * This file applies that workaround automatically, once, only if needed.
 */
(function () {
	"use strict";

	function navbar_in_dom() {
		return !!(
			document.querySelector("nav.navbar") ||
			document.querySelector(".navbar") ||
			document.querySelector("header.navbar") ||
			document.querySelector("#navbar")
		);
	}

	function ensure_toolbar() {
		try {
			if (!window.frappe || !frappe.boot || !frappe.session) return;
			if (frappe.session.user === "Guest") return;
			if (navbar_in_dom()) return;
			if (!frappe.ui || !frappe.ui.toolbar || !frappe.ui.toolbar.Toolbar) return;
			if (frappe.ui.toolbar_obj) return;
			frappe.ui.toolbar_obj = new frappe.ui.toolbar.Toolbar();
			console.log("[iran_common] top navbar ensured");
		} catch (e) {
			console.warn("[iran_common] ensure_toolbar failed:", e);
		}
	}

	$(function () {
		setTimeout(ensure_toolbar, 500);
	});
	$(document).on("app_ready startup", function () {
		setTimeout(ensure_toolbar, 500);
	});
})();
EOF
# --- END VERBATIM COPY -------------------------------------------------------
log "ensure_toolbar.js written"

# =============================================================================
step "6) کپی خط‌به‌خط کمک‌تابع‌های جینجا"
# --- BEGIN VERBATIM COPY: jinja_helpers.py ----------------------------------
write_utf8 "${PKG}/utils/jinja_helpers.py" << 'IRJ_JINJA_EOF'
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
IRJ_JINJA_EOF
# --- END VERBATIM COPY -------------------------------------------------------
sed -i 's/from ir_jalali\.utils\.jalali import/from iran_common.utils.jalali import/g' "${PKG}/utils/jinja_helpers.py"
sed -i 's/import ir_jalali\.utils\.jalali/import iran_common.utils.jalali/g' "${PKG}/utils/jinja_helpers.py"
grep -q "iran_common.utils.jalali" "${PKG}/utils/jinja_helpers.py" \
  && log "jinja_helpers.py کپی و مسیر تقویم به منبع واحد وصل شد" \
  || warn "jinja_helpers.py مرجع تقویم نداشت (بدون تغییر)"

# =============================================================================
step "7) hooks.py — فقط بلوک نشانه‌دار؛ ادغام امن app_include_*"
python3 - "$PKG" << 'PYEOF'
import io, os, re, sys
pkg = sys.argv[1]
hooks = os.path.join(pkg, "hooks.py")
src = ""
if os.path.exists(hooks):
    src = io.open(hooks, encoding="utf-8").read()

START = "# --- IRAN_COMMON_HOOKS_START ---"
END = "# --- IRAN_COMMON_HOOKS_END ---"
# فقط بلوک خودمان پاک می‌شود؛ بقیهٔ hooks (scaffold / دستی) دست‌نخورده می‌ماند
src = re.sub(re.escape(START) + r".*?" + re.escape(END) + r"\n?", "", src, flags=re.S)

block = f'''{START}
app_name = "iran_common"
app_title = "Iran Common"
app_publisher = "Iran Trade ERP"
app_description = "زیرساخت عمومی ایران: اعتبارسنجی، تقویم شمسی، کمک‌تابع‌های فارسی"
app_email = "dev@local"
app_license = "MIT"

required_apps = ["frappe"]

before_install = "iran_common.setup_foundation.ensure_settings_manager_role"
before_migrate = "iran_common.setup_foundation.ensure_settings_manager_role"
after_migrate = "iran_common.setup_foundation.after_migrate"

# ادغام امن: مقادیر قبلی app_include_js/css (خارج از این بلوک یا scaffold) حفظ می‌شوند
_ic_js = globals().get("app_include_js", [])
if isinstance(_ic_js, str):
    app_include_js = [_ic_js] if _ic_js else []
elif isinstance(_ic_js, (list, tuple)):
    app_include_js = list(_ic_js)
else:
    app_include_js = []
for _f in [
    "/assets/iran_common/js/jalali_core.js",
    "/assets/iran_common/js/jalali_picker.js",
    "/assets/iran_common/js/controls_patch.js",
    "/assets/iran_common/js/ensure_toolbar.js",
]:
    if _f not in app_include_js:
        app_include_js.append(_f)

_ic_css = globals().get("app_include_css", [])
if isinstance(_ic_css, str):
    app_include_css = [_ic_css] if _ic_css else []
elif isinstance(_ic_css, (list, tuple)):
    app_include_css = list(_ic_css)
else:
    app_include_css = []
for _f in ["/assets/iran_common/css/jalali_picker.css"]:
    if _f not in app_include_css:
        app_include_css.append(_f)

# jinja: فقط کلیدهای iran_common را می‌نشانیم؛ اگر jinja از قبل dict بود methods را merge کن
_ic_jinja = globals().get("jinja", None)
_ic_methods = [
    "iran_common.utils.jalali.jalali",
    "iran_common.utils.jalali.jalali_fa",
    "iran_common.utils.jinja_helpers.fa_digits",
    "iran_common.utils.jinja_helpers.fa_money",
    "iran_common.utils.jinja_helpers.fa_date",
    "iran_common.utils.jinja_helpers.normalize_persian",
]
if isinstance(_ic_jinja, dict):
    jinja = dict(_ic_jinja)
    _prev = jinja.get("methods") or []
    if isinstance(_prev, str):
        _prev = [_prev]
    elif not isinstance(_prev, (list, tuple)):
        _prev = []
    else:
        _prev = list(_prev)
    for _m in _ic_methods:
        if _m not in _prev:
            _prev.append(_m)
    jinja["methods"] = _prev
else:
    jinja = {{"methods": _ic_methods}}
{END}
'''
src = (src.rstrip() + "\n\n" + block + "\n") if src.strip() else (block + "\n")
io.open(hooks, "w", encoding="utf-8").write(src)
# syntax check
import ast
ast.parse(src)
print("hooks.py updated (marker-safe merge):", hooks)
PYEOF
log "hooks.py نوشته شد (ادغام امن)"

# =============================================================================
step "8) ترجمه فارسی پایه (fa.csv)"
write_utf8 "${PKG}/translations/fa.csv" << 'FAEOF'
Iran Common,عمومی ایران,
Iran Common Settings,تنظیمات پایه ایران,
Validation Bypass Log,ثبت عبور از اعتبارسنجی,
Settings Manager,تنظیمات,
Settings,تنظیمات,
FAEOF

# =============================================================================
step "8b) setup_foundation — نقش + ویزارد + ترجمه"
write_utf8 "${PKG}/setup_foundation.py" << 'EOF'
# -*- coding: utf-8 -*-
"""Foundation seed for iran_common.

- Settings Manager role (before_install / before_migrate)
- Translations
- Iran Common Settings defaults
- Wizard gate close (Frappe v15 REAL gate: Installed Application.is_setup_complete)

Does NOT touch validators/jalali logic. Safe for re-run.
"""
from __future__ import annotations

import frappe


def ensure_settings_manager_role():
    """Idempotent. Safe to call before DocType sync."""
    if frappe.db.exists("Role", "Settings Manager"):
        return
    try:
        doc = frappe.get_doc({
            "doctype": "Role",
            "role_name": "Settings Manager",
            "desk_access": 1,
            "is_custom": 1,
        })
        doc.insert(ignore_permissions=True)
        frappe.db.commit()
    except Exception:
        frappe.db.rollback()


def _get_app_version(app_name):
    try:
        if app_name == "frappe":
            return getattr(frappe, "__version__", "UNVERSIONED") or "UNVERSIONED"
        mod = frappe.get_module(app_name)
        return getattr(mod, "__version__", "UNVERSIONED") or "UNVERSIONED"
    except Exception:
        return "UNVERSIONED"


def close_installed_app_gate():
    """REAL FIX 1: flip is_setup_complete=1 for frappe+erpnext."""
    for app_name in ("frappe", "erpnext"):
        if not frappe.db.exists("DocType", "Installed Application"):
            break
        if frappe.db.exists("Installed Application", {"app_name": app_name}):
            frappe.db.set_value(
                "Installed Application",
                {"app_name": app_name},
                "is_setup_complete",
                1,
            )
            try:
                meta = frappe.get_meta("Installed Application")
                if meta.has_field("has_setup_wizard"):
                    frappe.db.set_value(
                        "Installed Application",
                        {"app_name": app_name},
                        "has_setup_wizard",
                        1,
                    )
            except Exception:
                pass
        else:
            try:
                row = {
                    "doctype": "Installed Application",
                    "app_name": app_name,
                    "app_version": _get_app_version(app_name),
                    "is_setup_complete": 1,
                }
                meta = frappe.get_meta("Installed Application")
                if meta.has_field("has_setup_wizard"):
                    row["has_setup_wizard"] = 1
                frappe.get_doc(row).insert(ignore_permissions=True, ignore_if_duplicate=True)
            except Exception:
                pass
    frappe.db.commit()
    return "Installed Application gate closed (frappe+erpnext is_setup_complete=1)"


def kill_wizard_and_onboarding():
    """Close every layer of the setup wizard gate (same method as realign-gate)."""
    msg = close_installed_app_gate()

    try:
        frappe.db.set_single_value("System Settings", "setup_complete", 1)
        meta = frappe.get_meta("System Settings")
        if meta.has_field("enable_onboarding"):
            frappe.db.set_single_value("System Settings", "enable_onboarding", 0)
        if meta.has_field("is_first_startup"):
            frappe.db.set_single_value("System Settings", "is_first_startup", 0)
        ss = frappe.get_single("System Settings")
        if not ss.language:
            frappe.db.set_single_value("System Settings", "language", "fa")
        if not ss.time_zone:
            frappe.db.set_single_value("System Settings", "time_zone", "Asia/Tehran")
    except Exception:
        pass

    try:
        if frappe.db.exists("DocType", "Module Onboarding"):
            frappe.db.sql("update `tabModule Onboarding` set is_complete=1")
        if frappe.db.exists("DocType", "Onboarding Step"):
            frappe.db.sql(
                "update `tabOnboarding Step` set is_complete=1, is_skipped=1"
            )
    except Exception:
        pass

    frappe.db.commit()
    frappe.clear_cache()
    try:
        if hasattr(frappe.is_setup_complete, "cache_clear"):
            frappe.is_setup_complete.cache_clear()
    except Exception:
        pass
    return msg + " + System Settings + onboarding"


def _ensure_translation(source, translated, language="fa"):
    name = frappe.db.get_value(
        "Translation",
        {"language": language, "source_text": source},
        "name",
    )
    if name:
        doc = frappe.get_doc("Translation", name)
        if doc.translated_text != translated:
            doc.translated_text = translated
            doc.save(ignore_permissions=True)
            return f"translation updated: {source}"
        return f"translation exists: {source}"
    frappe.get_doc({
        "doctype": "Translation",
        "language": language,
        "source_text": source,
        "translated_text": translated,
    }).insert(ignore_permissions=True)
    return f"translation created: {source}"


def _ensure_settings_defaults():
    if not frappe.db.exists("DocType", "Iran Common Settings"):
        return "Iran Common Settings DocType missing"
    s = frappe.get_single("Iran Common Settings")
    changed = False
    for field in (
        "enable_national_id_check",
        "enable_mobile_check",
        "enable_sheba_check",
        "enable_plate_check",
    ):
        if s.meta.has_field(field) and s.get(field) is None:
            s.set(field, 1)
            changed = True
    if s.meta.has_field("default_country") and not s.get("default_country"):
        s.default_country = "Iran"
        changed = True
    if changed:
        s.flags.ignore_permissions = True
        s.flags.ignore_version = True
        s.save(ignore_permissions=True)
        return "Iran Common Settings defaults applied"
    return "Iran Common Settings OK"


def after_migrate():
    ensure_settings_manager_role()
    kill_wizard_and_onboarding()
    for src, dst in (
        ("Settings Manager", "تنظیمات"),
        ("Iran Common", "عمومی ایران"),
        ("Iran Common Settings", "تنظیمات پایه ایران"),
        ("Validation Bypass Log", "ثبت عبور از اعتبارسنجی"),
        ("Settings", "تنظیمات"),
    ):
        _ensure_translation(src, dst)
    _ensure_settings_defaults()
    frappe.db.commit()
    frappe.clear_cache()


def run():
    results = []
    ensure_settings_manager_role()
    results.append("role Settings Manager ensured")
    results.append(kill_wizard_and_onboarding())
    for src, dst in (
        ("Settings Manager", "تنظیمات"),
        ("Iran Common", "عمومی ایران"),
        ("Iran Common Settings", "تنظیمات پایه ایران"),
        ("Validation Bypass Log", "ثبت عبور از اعتبارسنجی"),
        ("Settings", "تنظیمات"),
    ):
        results.append(_ensure_translation(src, dst))
    results.append(_ensure_settings_defaults())
    frappe.db.commit()
    frappe.clear_cache()
    return {"results": results}
EOF

# =============================================================================
step "9) نصب اپ روی سایت + migrate + build"
if bench --site "$SITE_NAME" list-apps 2>/dev/null | grep -qw "$APP"; then
  warn "اپ ${APP} از قبل روی سایت نصب است"
else
  bench --site "$SITE_NAME" install-app "$APP"
  log "اپ ${APP} نصب شد"
fi
bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache
bench build --app "$APP" || warn "bench build رد شد — در صورت نبود assets دستی: bench build --app ${APP}"

bench --site "$SITE_NAME" execute iran_common.setup_foundation.run
bench --site "$SITE_NAME" clear-cache
log "wizard gate closed + foundation seeded"

# assets symlink برای ensure_toolbar
if [[ ! -e "sites/assets/${APP}/js/ensure_toolbar.js" ]]; then
  warn "assets symlink missing for ensure_toolbar.js — bench build --app ${APP}"
  bench build --app "${APP}" || warn "bench build failed"
else
  log "assets path OK: sites/assets/${APP}/js/ensure_toolbar.js"
fi

# =============================================================================
step "10) Verify"
write_utf8 "${PKG}/verify_script01.py" << 'VEOF'
# -*- coding: utf-8 -*-
"""Verify واقعی script-01 — همه چک‌ها روی سایت زنده اجرا می‌شوند."""
import os
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

    from iran_common.utils import validators as V
    from iran_common.utils import guarded as G
    from iran_common.utils import jalali as J

    ok = True
    try:
        V.validate_iranian_national_id("0084575948")
    except Exception:
        ok = False
    chk("C1 کد ملی معتبر پذیرفته شد", ok)

    bad = False
    try:
        V.validate_iranian_national_id("1234567890")
    except Exception:
        bad = True
    chk("C2 کد ملی نامعتبر رد شد", bad)

    ok = True
    try:
        V.validate_iran_mobile("09121234567")
    except Exception:
        ok = False
    chk("C3 موبایل ۰۹ معتبر پذیرفته شد", ok)

    bad = False
    try:
        V.validate_iran_mobile("08121234567")
    except Exception:
        bad = True
    chk("C4 موبایل نامعتبر رد شد", bad)

    chk("C5 تبدیل ارقام فارسی", V.persian_to_english_digits("۰۹۱۲") == "0912")

    j = J.to_jalaali(2024, 3, 20)
    g = J.to_gregorian(j["jy"], j["jm"], j["jd"])
    chk(
        "C6 تبدیل رفت‌وبرگشت تاریخ دقیق است",
        (g.get("gy"), g.get("gm"), g.get("gd")) == (2024, 3, 20),
    )
    try:
        J.test_jalali()
        chk("C6b test_jalali (4 vectors) PASS", True)
    except Exception as e:
        chk("C6b test_jalali (4 vectors) PASS", False)
        print("       detail:", e)

    chk("C7 «تنظیمات پایه ایران» ساخته شد", frappe.db.count("DocType", {"name": "Iran Common Settings"}) == 1)
    chk("C8 «ثبت عبور از اعتبارسنجی» ساخته شد", frappe.db.count("DocType", {"name": "Validation Bypass Log"}) == 1)

    s = frappe.get_single("Iran Common Settings")
    s.enable_national_id_check = 1
    s.flags.ignore_permissions = True
    s.save(ignore_permissions=True)
    frappe.db.commit()

    before_all = frappe.db.count("Validation Bypass Log")
    s = frappe.get_single("Iran Common Settings")
    s.enable_national_id_check = 0
    s.flags.ignore_permissions = True
    s.save(ignore_permissions=True)
    frappe.db.commit()
    frappe.clear_cache()
    after_settings = frappe.db.count("Validation Bypass Log")
    chk("C9b سابقه تغییر تنظیمات (خاموش کردن کلید) ثبت شد", after_settings >= before_all + 1)

    row = frappe.get_all(
        "Validation Bypass Log",
        filters={"reference_doctype": "Iran Common Settings"},
        fields=["name", "acted_by", "check_kind", "raw_value", "bypass_reason"],
        order_by="creation desc",
        limit=1,
    )
    chk("C9c audit دارای acted_by است", bool(row and row[0].get("acted_by")))
    chk("C9d raw_value تغییر کلید 1→0", bool(row and "1→0" in str(row[0].get("raw_value") or "")))

    before = frappe.db.count("Validation Bypass Log")
    G.check_national_id("1234567890", "ایرانی", "Iran Common Settings", "test")
    after = frappe.db.count("Validation Bypass Log")
    chk("C9 خاموش‌بودن سنجه، لاگ عبور داده ثبت می‌کند", after >= before + 1)

    s = frappe.get_single("Iran Common Settings")
    s.enable_national_id_check = 1
    s.flags.ignore_permissions = True
    s.save(ignore_permissions=True)
    frappe.db.commit()

    ok = True
    try:
        G.check_national_id("ABC-999", "غیرایرانی")
    except Exception:
        ok = False
    chk("C10 هویت غیرایرانی نیازی به کد ملی معتبر ندارد", ok)

    ok = True
    try:
        G.check_plate("TR 34 ABC 12", "بین‌المللی")
    except Exception:
        ok = False
    chk("C11 پلاک بین‌المللی آزاد است", ok)

    chk("C12 ماسک شبا درست است", G.mask_sheba("IR930120000000000012345678").startswith("IR93****"))

    chk("C13 نقش Settings Manager وجود دارد", bool(frappe.db.exists("Role", "Settings Manager")))
    chk(
        "C14 ترجمه Settings Manager → تنظیمات",
        bool(frappe.db.exists("Translation", {
            "language": "fa",
            "source_text": "Settings Manager",
            "translated_text": "تنظیمات",
        })),
    )

    chk("C15 Workspace Iran Common وجود دارد", bool(frappe.db.exists("Workspace", "Iran Common")))
    if frappe.db.exists("Workspace", "Iran Common"):
        ws = frappe.get_doc("Workspace", "Iran Common")
        roles = {r.role for r in (ws.roles or [])}
        chk("C16 Workspace roles شامل Settings Manager", "Settings Manager" in roles)
        chk("C17 Workspace icon=setting", (ws.icon or "") == "setting")
        chk("C18 Workspace public", int(ws.public or 0) == 1)
    else:
        chk("C16 Workspace roles شامل Settings Manager", False)
        chk("C17 Workspace icon=setting", False)
        chk("C18 Workspace public", False)

    meta = frappe.get_meta("Iran Common Settings")
    sm_write = any(
        p.role == "Settings Manager" and int(p.read or 0) == 1 and int(p.write or 0) == 1
        for p in (meta.permissions or [])
    )
    chk("C19 Settings Manager write روی Iran Common Settings", sm_write)

    try:
        setup_ok = bool(frappe.is_setup_complete())
    except Exception as e:
        setup_ok = False
        print("       is_setup_complete error:", e)
    chk("C20 frappe.is_setup_complete() == True", setup_ok)

    ia = []
    if frappe.db.exists("DocType", "Installed Application"):
        ia = frappe.get_all(
            "Installed Application",
            filters={"app_name": ["in", ["frappe", "erpnext"]]},
            fields=["app_name", "is_setup_complete"],
        )
    chk(
        "C21 Installed Application is_setup_complete برای frappe/erpnext",
        bool(ia) and all(int(r.is_setup_complete or 0) == 1 for r in ia),
    )

    legacy = str(frappe.db.get_single_value("System Settings", "setup_complete") or "")
    chk("C22 System Settings.setup_complete == 1", legacy in ("1", "True", "true"))

    # Navbar ensure (REAL FIX 2)
    js_path = frappe.get_app_path("iran_common", "public", "js", "ensure_toolbar.js")
    chk("C23 ensure_toolbar.js exists", os.path.exists(js_path))
    hooked = [str(h) for h in (frappe.get_hooks("app_include_js") or [])]
    chk(
        "C24 ensure_toolbar.js hooked via app_include_js",
        any("ensure_toolbar" in h for h in hooked),
    )
    # jalali assets هنوز hook هستند (رگرسیون نگیریم)
    chk("C25 jalali_core.js still hooked", any("jalali_core" in h for h in hooked))

    print("\n  Passed: %d | Failed: %d" % (passed, failed))
    if failed:
        raise Exception("verify_script01 FAILED: %d" % failed)
    return "OK"
VEOF

bench --site "$SITE_NAME" execute iran_common.verify_script01.run

cd ~/frappe-bench
bench --site transport-dev.local execute frappe.db.set_default --args '["time_zone", "Asia/Tehran"]'
bench --site transport-dev.local execute frappe.db.set_default --args '["date_format", "yyyy-mm-dd"]'
bench --site transport-dev.local execute frappe.db.set_default --args '["first_day_of_the_week", "Saturday"]'
bench --site transport-dev.local execute frappe.db.set_default --args '["language", "fa"]'
bench --site transport-dev.local execute frappe.db.set_default --args '["country", "Iran"]'
bench --site transport-dev.local execute frappe.db.set_default --args '["currency", "IRR"]'
bench --site transport-dev.local clear-cache
cd -

# =============================================================================
cat <<FINAL

============================================================
 script-01.sh با موفقیت تمام شد
------------------------------------------------------------
 اپ            : iran_common
 Navbar        : ensure_toolbar.js + app_include_js (ادغام امن)
 Wizard        : Installed Application.is_setup_complete
 Settings audit: Validation Bypass Log (1→0 / 0→1 + acted_by)
 API           : validators / guarded / jalali — دست‌نخورده برای script-02+

 مرورگر: Logout → Incognito → Ctrl+Shift+R
 Console: [iran_common] top navbar ensured
 Navbar : جستجو + زنگ + آواتار باید برگردد
============================================================
FINAL