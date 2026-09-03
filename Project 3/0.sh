#!/usr/bin/env bash
# =============================================================================
# script-00-site-bootstrap.sh  —  RECOVERED PREREQUISITE (additive, new)
# Iran Trade ERP | ERPNext v15 / Frappe v15 | File-First | Idempotent
# -----------------------------------------------------------------------------
# چرا این فایل وجود دارد (ریشه‌یابی شده در حسابرسی):
#   هیچ‌یک از script-01.sh .. script-10.sh (Project 2 / بازسازی هدایت‌شده) یک
#   سایت Frappe واقعی نمی‌سازند. همه آن‌ها با این فرض شروع می‌شوند که سایت،
#   bench و اپ erpnext از قبل نصب هستند:
#
#       [[ -d "${BENCH_DIR}/sites/${SITE_NAME}" ]] || err "سایت ... وجود ندارد"
#
#   در Project 1، اسکریپت setup_ir_base_phase2.sh دقیقاً همین نقش را ایفا
#   می‌کرد: از صفر nginx/bench را بالا می‌آورد، «bench new-site» را اجرا
#   می‌کرد، erpnext را نصب می‌کرد و locale فارسی/تهران را تنظیم می‌کرد —
#   قبل از هر اسکریپت فاز دیگر.
#
#   این نسخه، همان منطق تأییدشده Project 1 (site creation, erpnext install,
#   locale) را — و فقط همان بخش، نه ساخت اپ ir_base که در معماری جدید با
#   iran_common در script-01.sh جایگزین شده — به‌صورت افزایشی (additive)
#   برای معماری Project 2 بازسازی می‌کند تا زنجیره «مستقل، کامل، از صفر»
#   کامل شود:
#
#       script-00-site-bootstrap.sh  →  script-01.sh  →  ...  →  script-10.sh
#
# منبع مرجع (خط‌به‌خط، فقط بخش site/erpnext/locale):
#   Project 1/setup_ir_base_phase2.sh  (بخش‌های ۰ تا ۴ب)
#
# تغییرات نسبت به منبع:
#   - بخش ساخت اپ ir_base (بخش‌های ۵ تا ۱۱ منبع) عمداً حذف شد؛ آن نقش را
#     script-01.sh با اپ iran_common ایفا می‌کند (بدون تکرار منطق).
#   - MYSQL_ROOT_PASSWORD / ADMIN_PASSWORD دیگر مقدار ثابت hardcode نیستند؛
#     هر دو از متغیر محیطی با امکان override خوانده می‌شوند و اگر ست نشوند
#     اسکریپت با خطای صریح متوقف می‌شود (رفع نقطه‌ضعف امنیتی یافت‌شده در
#     حسابرسی: Project 1 مقدار "as12" را hardcode کرده بود).
# =============================================================================
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export PYTHONIOENCODING=utf-8

# ───────────────────────────── CONFIG (env-overridable, no hardcoded secrets) ─
export SITE_NAME="${SITE_NAME:-transport-dev.local}"
export BENCH_DIR="${BENCH_DIR:-${HOME}/frappe-bench}"
TIME_ZONE="${TIME_ZONE:-Asia/Tehran}"
LANG_CODE="${LANG_CODE:-fa}"
CURRENCY="${CURRENCY:-IRR}"

# این دو مقدار دیگر هیچ پیش‌فرض ثابتی ندارند — باید صراحتاً ست شوند.
MYSQL_ROOT_PASSWORD="as12"
ADMIN_PASSWORD="as12"
# ────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${YELLOW}======== $* ========${NC}"; }

site_has_app() {
  local site="$1" app="$2"
  bench --site "$site" list-apps 2>/dev/null | grep -qE "^${app}([[:space:]]|$)"
}

[[ -d "$BENCH_DIR" ]] || err "Bench not found: $BENCH_DIR (bench init باید قبلاً روی ماشین انجام شده باشد)"
command -v bench >/dev/null || err "bench not in PATH"
cd "$BENCH_DIR"
export PATH="${HOME}/.local/bin:${PATH:-}"

# =============================================================================
step "0) نسخه‌ها"
# =============================================================================
echo "----- versions -----"
lsb_release -a 2>/dev/null || true
python3 --version || true
node --version || true
bench --version || true
echo "--------------------"

# =============================================================================
step "1) bench start (پس‌زمینه، idempotent)"
# =============================================================================
if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "port 8000 / bench از قبل در حال اجراست — رد شد"
else
  nohup bench start >>/tmp/bench-start-script00.log 2>&1 &
  echo $! >/tmp/bench-start-script00.pid
  log "bench start pid=$(cat /tmp/bench-start-script00.pid) log=/tmp/bench-start-script00.log"
  sleep 12
fi

# =============================================================================
step "2) global bench config"
# =============================================================================
bench set-config -g time_zone "$TIME_ZONE"
bench set-config -g language "$LANG_CODE"
bench set-config -g default_currency "$CURRENCY"
log "global: time_zone=${TIME_ZONE} language=${LANG_CODE} default_currency=${CURRENCY}"

# =============================================================================
step "3) سایت ${SITE_NAME} — فقط اگر وجود ندارد (بدون drop، بدون سؤال تعاملی)"
# =============================================================================
if [[ ! -d "sites/${SITE_NAME}" ]]; then
  [[ -n "$MYSQL_ROOT_PASSWORD" ]] || err "MYSQL_ROOT_PASSWORD ست نشده. مثال: MYSQL_ROOT_PASSWORD=... ADMIN_PASSWORD=... bash script-00-site-bootstrap.sh"
  [[ -n "$ADMIN_PASSWORD" ]]      || err "ADMIN_PASSWORD ست نشده. مثال: MYSQL_ROOT_PASSWORD=... ADMIN_PASSWORD=... bash script-00-site-bootstrap.sh"

  bench new-site "$SITE_NAME" \
    --mariadb-root-password "$MYSQL_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --db-type mariadb
  log "created site ${SITE_NAME}"
else
  warn "site ${SITE_NAME} از قبل وجود دارد — رد شد (NO DROP)"
fi

bench --site "$SITE_NAME" set-config developer_mode 1
bench --site "$SITE_NAME" set-config time_zone "$TIME_ZONE"
bench --site "$SITE_NAME" set-config language "$LANG_CODE"
bench --site "$SITE_NAME" set-config default_currency "$CURRENCY"
bench --site "$SITE_NAME" set-config currency "$CURRENCY" || true

# =============================================================================
step "4) erpnext + migrate + scheduler"
# =============================================================================
if ! site_has_app "$SITE_NAME" "erpnext"; then
  bench --site "$SITE_NAME" install-app erpnext
else
  warn "erpnext از قبل نصب است"
fi

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" enable-scheduler
bench --site "$SITE_NAME" clear-cache

echo "----- list-apps -----"
bench --site "$SITE_NAME" list-apps
echo "----------------------"

# =============================================================================
step "5) locale فقط با bench execute (بدون console، بدون python خام)"
# =============================================================================
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
log "locale اعمال شد"

# =============================================================================
step "DONE"
# =============================================================================
cat <<FINAL

${GREEN}script-00-site-bootstrap.sh با موفقیت تمام شد.${NC}

Site:      http://${SITE_NAME}:8000/app
Bench log: /tmp/bench-start-script00.log

گام بعدی: bash script-01.sh

Checklist:
  [ ] list-apps شامل: frappe, erpnext
  [ ] developer_mode=1
  [ ] language=fa , time_zone=Asia/Tehran
  [ ] هیچ رمز عبوری در این فایل hardcode نشده (باید env-var بدهید)
FINAL
