#!/usr/bin/env bash
# =============================================================================
# setup_ir_base_phase2.sh
# فاز ۱ + فاز ۲ — از صفر عملیاتی تا پایان فاز ۲
# ERPNext v15 / Frappe v15 / Bench 5.31
#
# قوانین:
#   File-First | بدون drop-site | بدون سؤال تعاملی
#   بدون install.py | بدون after_install فعال
#   بدون bench console | بدون env/bin/python خام
#   bench execute فقط برای تست و locale
#   Force-Replace فقط فایل‌های تعریف‌شده
#   bench start در پس‌زمینه
#
# استفاده:
#   nano ~/setup_ir_base_phase2.sh
#   chmod +x ~/setup_ir_base_phase2.sh
#   ~/setup_ir_base_phase2.sh
# =============================================================================

set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export PYTHONIOENCODING=utf-8

# ───────────────────────────── CONFIG ────────────────────────────────────────
MYSQL_ROOT_PASSWORD="as12"
ADMIN_PASSWORD="as12"

SITE_NAME="transport-dev.local"
BACKUP_SITE="erp.local"
APP_NAME="ir_base"
BENCH_DIR="${HOME}/frappe-bench"

TIME_ZONE="Asia/Tehran"
LANG_CODE="fa"
CURRENCY="IRR"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; exit 1; }
step() { echo -e "\n${YELLOW}======== $* ========${NC}"; }

write_utf8() {
  local target="$1"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-8 -t UTF-8 "$tmp" >/dev/null 2>&1 || err "UTF-8 invalid: $target"
  fi
  mkdir -p "$(dirname "$target")"
  mv -f "$tmp" "$target"
  log "write: $target"
}

site_has_app() {
  local site="$1" app="$2"
  bench --site "$site" list-apps 2>/dev/null | grep -qE "^${app}([[:space:]]|$)"
}

[[ -d "$BENCH_DIR" ]] || err "Bench not found: $BENCH_DIR"
command -v bench >/dev/null || err "bench not in PATH"

cd "$BENCH_DIR"
export PATH="${HOME}/.local/bin:${PATH:-}"

# =============================================================================
# 0) نسخه‌ها + بکاپ erp.local + بایگانی back.py
# =============================================================================
step "0) versions + backup ${BACKUP_SITE}"

echo "----- versions -----"
lsb_release -a 2>/dev/null || true
python3 --version || true
node --version || true
bench --version || true
bench version || true
echo "--------------------"

if [[ -d "sites/${BACKUP_SITE}" ]]; then
  bench --site "$BACKUP_SITE" backup --with-files || warn "backup ${BACKUP_SITE} failed — continue"
  log "backup attempted for ${BACKUP_SITE}"
else
  warn "site ${BACKUP_SITE} not found — skip backup"
fi

mkdir -p "${BENCH_DIR}/archive"
if [[ -f "${BENCH_DIR}/back.py" ]]; then
  mv -f "${BENCH_DIR}/back.py" "${BENCH_DIR}/archive/back.py.old"
  log "archived back.py"
fi
if [[ -f "${HOME}/back.py" ]]; then
  mv -f "${HOME}/back.py" "${BENCH_DIR}/archive/back.py.home.old"
  log "archived ~/back.py"
fi

# =============================================================================
# 1) bench start در پس‌زمینه
# =============================================================================
step "1) bench start (background)"

if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "port 8000 / bench already running — skip bench start"
else
  nohup bench start >>/tmp/bench-start-phase2.log 2>&1 &
  echo $! >/tmp/bench-start-phase2.pid
  log "bench start pid=$(cat /tmp/bench-start-phase2.pid) log=/tmp/bench-start-phase2.log"
  sleep 12
fi

# =============================================================================
# 2) تنظیمات گلوبال Bench  (عین یادداشت شما)
# =============================================================================
step "2) global bench config"

bench set-config -g time_zone "$TIME_ZONE"
bench set-config -g language "$LANG_CODE"
bench set-config -g default_currency "$CURRENCY"
log "global: time_zone=${TIME_ZONE} language=${LANG_CODE} default_currency=${CURRENCY}"

# =============================================================================
# 3) سایت جدید فقط اگر وجود ندارد — بدون drop
# =============================================================================
step "3) site ${SITE_NAME} (no drop)"

if [[ ! -d "sites/${SITE_NAME}" ]]; then
  [[ "$MYSQL_ROOT_PASSWORD" != "YOUR_MYSQL_ROOT_PASSWORD_HERE" && -n "$MYSQL_ROOT_PASSWORD" ]] \
    || err "سایت وجود ندارد. MYSQL_ROOT_PASSWORD را بالای اسکریپت مقداردهی کنید."

  bench new-site "$SITE_NAME" \
    --mariadb-root-password "$MYSQL_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --db-type mariadb
  log "created site ${SITE_NAME}"
else
  warn "site ${SITE_NAME} already exists — skip new-site (NO DROP)"
fi

bench --site "$SITE_NAME" set-config developer_mode 1
bench --site "$SITE_NAME" set-config time_zone "$TIME_ZONE"
bench --site "$SITE_NAME" set-config language "$LANG_CODE"
bench --site "$SITE_NAME" set-config default_currency "$CURRENCY"
bench --site "$SITE_NAME" set-config currency "$CURRENCY" || true

# =============================================================================
# 4) ERPNext + migrate + scheduler
# =============================================================================
step "4) erpnext + migrate + scheduler"

if ! site_has_app "$SITE_NAME" "erpnext"; then
  bench --site "$SITE_NAME" install-app erpnext
else
  warn "erpnext already installed"
fi

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" enable-scheduler
bench --site "$SITE_NAME" clear-cache

echo "----- list-apps after erpnext -----"
bench --site "$SITE_NAME" list-apps
echo "-----------------------------------"

# =============================================================================
# 4b) locale فقط با bench execute  (نه console، نه python خام)
# =============================================================================
step "4b) locale via bench execute"

bench --site "$SITE_NAME" execute frappe.db.set_value \
  --args '["Language", "fa", "enabled", 1]' || warn "enable Language fa failed"

bench --site "$SITE_NAME" execute frappe.db.set_single_value \
  --args '["System Settings", "language", "fa"]' || warn "System Settings language failed"

bench --site "$SITE_NAME" execute frappe.db.set_single_value \
  --args '["System Settings", "time_zone", "Asia/Tehran"]' || warn "System Settings time_zone failed"

bench --site "$SITE_NAME" execute frappe.db.set_value \
  --args '["User", "Administrator", "language", "fa"]' || warn "Administrator language failed"

bench --site "$SITE_NAME" execute frappe.db.set_value \
  --args '["User", "Administrator", "time_zone", "Asia/Tehran"]' || warn "Administrator time_zone failed"

bench --site "$SITE_NAME" clear-cache
log "locale applied via bench execute"

# =============================================================================
# 5) scaffold اپ — اگر نیست، غیرتعاملی بساز؛ اگر هست، دست نزن
# =============================================================================
step "5) app scaffold ${APP_NAME}"

APP_ROOT="${BENCH_DIR}/apps/${APP_NAME}"

if [[ ! -d "$APP_ROOT" ]]; then
  # ترتیب سؤالات واقعی Frappe v15:
  # Title → Description → Publisher → Email → License → GitHub Workflow
  if ! timeout 90 bash -c 'printf "%s\n" \
      "IR Base" \
      "Iran base utilities and settings for ERPNext v15" \
      "IR Base Contributors" \
      "dev@example.com" \
      "mit" \
      "n" | bench new-app ir_base'; then
    err "bench new-app غیرتعاملی شکست خورد. پوشه apps/ir_base ساخته نشد."
  fi
  log "bench new-app done (non-interactive)"
else
  warn "apps/${APP_NAME} exists — skip new-app, Force Replace files only"
fi

PKG="${APP_ROOT}/${APP_NAME}"
HOOKS="${PKG}/hooks.py"
[[ -f "$HOOKS" ]] || err "missing $HOOKS"

# پاکسازی انحراف‌های قبلی (اگر از تلاش‌های قبل مانده باشند)
rm -f "${PKG}/install.py" \
      "${PKG}/import_doctype.py" \
      "${APP_ROOT}/import_doctype.py" \
      "${PKG}/utils/import_doctype.py" || true

# =============================================================================
# 6) hooks.py — فقط required_apps و خاموش کردن after_install
# =============================================================================
step "6) hooks.py (surgical)"

sed -i -E 's/^([[:space:]]*after_install[[:space:]]*=)/# \1/' "$HOOKS" || true

if grep -qE '^[[:space:]]*required_apps[[:space:]]*=' "$HOOKS"; then
  sed -i -E 's|^[[:space:]]*required_apps[[:space:]]*=.*|required_apps = ["erpnext"]|' "$HOOKS"
elif grep -qE '^app_version[[:space:]]*=' "$HOOKS"; then
  sed -i -E '/^app_version[[:space:]]*=/a required_apps = ["erpnext"]' "$HOOKS"
elif grep -qE '^app_license[[:space:]]*=' "$HOOKS"; then
  sed -i -E '/^app_license[[:space:]]*=/a required_apps = ["erpnext"]' "$HOOKS"
else
  printf '\nrequired_apps = ["erpnext"]\n' >> "$HOOKS"
fi

if grep -qE '^app_color[[:space:]]*=' "$HOOKS"; then
  sed -i -E 's|^app_color[[:space:]]*=.*|app_color = "#3498db"|' "$HOOKS"
fi

echo "----- hooks check -----"
grep -nE 'required_apps|app_color|^[[:space:]]*after_install|^#[[:space:]]*after_install' "$HOOKS" || true
echo "-----------------------"

printf '%s\n' "IR Base" > "${PKG}/modules.txt"
log "modules.txt -> IR Base"

# =============================================================================
# 7) utils — Force Replace عین فایل تأییدشده
# =============================================================================
step "7) utils (Force Replace)"

mkdir -p "${PKG}/utils"

write_utf8 "${PKG}/utils/__init__.py" << 'EOF'
# IR Base utilities package
EOF

write_utf8 "${PKG}/utils/validators.py" << 'EOF'
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
EOF

# =============================================================================
# 8) DocType سه لایه — Force Replace عین فایل تأییدشده
# مسیر: apps/ir_base/ir_base/ir_base/doctype/iran_base_settings/
# =============================================================================
step "8) DocType Iran Base Settings (Force Replace)"

DT_BASE="${PKG}/${APP_NAME}/doctype"
DT_DIR="${DT_BASE}/iran_base_settings"
mkdir -p "$DT_DIR"
touch "${PKG}/${APP_NAME}/__init__.py"

write_utf8 "${DT_BASE}/__init__.py" << 'EOF'
# DocTypes package
EOF

write_utf8 "${DT_DIR}/__init__.py" << 'EOF'
# Iran Base Settings DocType package
EOF

write_utf8 "${DT_DIR}/iran_base_settings.py" << 'EOF'
# Copyright (c) 2025, IR Base Contributors and contributors
# For license information, please see license.txt

import frappe
from frappe.model.document import Document


class IranBaseSettings(Document):
	"""
	Single DocType for Iran Base module settings.
	Kept intentionally minimal. Business logic stays in controllers/services/hooks.
	"""
	pass
EOF

write_utf8 "${DT_DIR}/test_iran_base_settings.py" << 'EOF'
# Copyright (c) 2025, IR Base Contributors and Contributors
# See license.txt

# import frappe
from frappe.tests.utils import FrappeTestCase


class TestIranBaseSettings(FrappeTestCase):
	pass
EOF

write_utf8 "${DT_DIR}/iran_base_settings.json" << 'EOF'
{
 "actions": [],
 "allow_rename": 0,
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "field_order": [
  "defaults_section",
  "default_country",
  "default_calendar_hint",
  "notes"
 ],
 "fields": [
  {
   "fieldname": "defaults_section",
   "fieldtype": "Section Break",
   "label": "تنظیمات پیش‌فرض"
  },
  {
   "default": "Iran",
   "fieldname": "default_country",
   "fieldtype": "Data",
   "label": "کشور پیش‌فرض",
   "read_only": 1
  },
  {
   "default": "Persian (Jalali) recommended",
   "fieldname": "default_calendar_hint",
   "fieldtype": "Data",
   "label": "راهنمای تقویم پیش‌فرض",
   "read_only": 1
  },
  {
   "fieldname": "notes",
   "fieldtype": "Small Text",
   "label": "یادداشت"
  }
 ],
 "issingle": 1,
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "IR Base",
 "name": "Iran Base Settings",
 "owner": "Administrator",
 "permissions": [
  {
   "create": 1,
   "delete": 1,
   "email": 1,
   "print": 1,
   "read": 1,
   "role": "System Manager",
   "share": 1,
   "write": 1
  }
 ],
 "sort_field": "modified",
 "sort_order": "DESC",
 "track_changes": 1
}
EOF

python3 -m json.tool "${DT_DIR}/iran_base_settings.json" >/dev/null && log "JSON OK" || err "JSON invalid"

# =============================================================================
# 9) install-app (اگر لازم) + migrate + clear-cache
# =============================================================================
step "9) install-app + migrate + clear-cache"

cd "$BENCH_DIR"

if ! site_has_app "$SITE_NAME" "$APP_NAME"; then
  bench --site "$SITE_NAME" install-app "$APP_NAME"
else
  warn "${APP_NAME} already on site — migrate only (Force Replace files already on disk)"
fi

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache
log "migrate + clear-cache done"

# =============================================================================
# 10) تست‌ها — bench execute، نه console
# =============================================================================
step "10) verification"

echo "--- list-apps ---"
bench --site "$SITE_NAME" list-apps

echo "--- DocType exists ---"
bench --site "$SITE_NAME" execute frappe.db.exists --args '["DocType", "Iran Base Settings"]' || true

echo "--- verify_validators ---"
bench --site "$SITE_NAME" execute ir_base.utils.validators.verify_validators

echo "--- locale ---"
bench --site "$SITE_NAME" execute frappe.db.get_single_value --args '["System Settings", "language"]' || true
bench --site "$SITE_NAME" execute frappe.db.get_single_value --args '["System Settings", "time_zone"]' || true

# =============================================================================
# 11) git — پیام کامیت عین یادداشت شما
# =============================================================================
step "11) git add + commit"

cd "$APP_ROOT"
if [[ ! -d .git ]]; then
  git init
fi
git config user.email >/dev/null 2>&1 || git config user.email "dev@example.com"
git config user.name  >/dev/null 2>&1 || git config user.name "IR Base Contributors"
git add .
git status
git commit -m "phase 2: done" || warn "nothing to commit (clean tree)"
git status
log "git done"

# =============================================================================
step "DONE"
cat <<FINAL

${GREEN}فاز ۲ تمام شد.${NC}

Site:      http://${SITE_NAME}:8000/app
Settings:  http://${SITE_NAME}:8000/app/iran-base-settings
Bench log: /tmp/bench-start-phase2.log

ساختار مورد انتظار:
apps/ir_base/ir_base/
  hooks.py                 (required_apps = ["erpnext"])
  utils/__init__.py
  utils/validators.py
  ir_base/doctype/__init__.py
  ir_base/doctype/iran_base_settings/
    __init__.py
    iran_base_settings.json
    iran_base_settings.py
    test_iran_base_settings.py

اگر UI هنوز EN است: Logout / Login + Ctrl+Shift+R
ندیدن DocType در Awesome Bar در این فاز خطا نیست.
URL مستقیم معیار است.

Checklist:
  [ ] list-apps: frappe, erpnext, ir_base
  [ ] DocType Iran Base Settings
  [ ] verify_validators: 16 PASS / 0 FAIL
  [ ] git: phase 2: done
  [ ] no install.py / no active after_install

FINAL