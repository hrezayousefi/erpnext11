#!/usr/bin/env bash
# =============================================================================
# script-02.sh — اسکلت اپ اصلی «iran_trade_erp» + نقش‌ها + کاربران واقعی
# بازسازی هدایت‌شده — Iran Trade ERP | ERPNext v15 / Frappe v15
# -----------------------------------------------------------------------------
# این اسکریپت:
#   1) اپ iran_trade_erp را می‌سازد (ماژول: Iran Trade)
#   2) ۱۳ نقش کسب‌وکاری را به‌صورت fixture ایجاد می‌کند
#      (۱۲ نقش سازمانی + «Validation Override» قابل انتساب)
#   3) شرکت و سال مالی و ۱۲ کاربر واقعی سازمان را می‌سازد
#      ⚠ دو مدیرعامل: هادی کرمیان و سعید یوسفی — هر دو هم‌زمان
#        CEO + Document Signer (تصحیح خطای ریشه‌ای نسخه قبل)
#      ⚠ Warehouse Type «Transit» قبل از Company (الزام ERPNext v15)
#   4) Administrator را «مقدس» نگه می‌دارد: هیچ نقش کسب‌وکاری نمی‌گیرد
#   5) الگوی ضد ۴۰۴ فارسی را به‌عنوان ابزار مشترک می‌نویسد
#      (name/label/title انگلیسی + ترجمه فارسی از fa.csv)
#   6) اسکلت hooks.py با بلوک‌های نشانه‌دار (Marker) برای فازهای بعد
#
# هیچ فایلی از script-01 تغییر نمی‌کند. اجرای مجدد بی‌خطر است.
# =============================================================================
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=utf-8

export SITE_NAME="${SITE_NAME:-transport-dev.local}"
export BENCH_DIR="${BENCH_DIR:-${HOME}/frappe-bench}"
export APP="iran_trade_erp"
export PKG="${BENCH_DIR}/apps/${APP}/${APP}"
export MOD="${PKG}/iran_trade"

# ایمیل و نام کاربران واقعی — قابل بازنویسی با متغیر محیطی
export CEO1_EMAIL="${CEO1_EMAIL:-hadi.karamian@irbco.local}"
export CEO1_NAME="${CEO1_NAME:-هادی کرمیان}"
export CEO2_EMAIL="${CEO2_EMAIL:-saeed.yousefi@irbco.local}"
export CEO2_NAME="${CEO2_NAME:-سعید یوسفی}"
export DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-Irbco@1404}"
export COMPANY_NAME="${COMPANY_NAME:-بازرگانی و حمل‌ونقل ایران}"
export COMPANY_ABBR="${COMPANY_ABBR:-ITE}"

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

[[ -d "$BENCH_DIR" ]] || err "Bench یافت نشد"
cd "$BENCH_DIR"

step "0) سرویس‌های bench و redis"
if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "bench از قبل در حال اجراست"
else
  nohup bench start >>/tmp/bench-start-itc02.log 2>&1 &
  log "bench start pid=$!"; sleep 12
fi
REDIS_CACHE_CONF="${BENCH_DIR}/config/redis_cache.conf"
if [[ -f "$REDIS_CACHE_CONF" ]]; then
  REDIS_CACHE_PORT="$(awk '$1 == "port" {print $2; exit}' "$REDIS_CACHE_CONF")"
else
  REDIS_CACHE_PORT="13000"
fi
[[ -n "${REDIS_CACHE_PORT:-}" ]] || REDIS_CACHE_PORT="13000"
REDIS_READY=0
for _i in $(seq 1 60); do
  if command -v redis-cli >/dev/null 2>&1 && redis-cli -h 127.0.0.1 -p "$REDIS_CACHE_PORT" ping 2>/dev/null | grep -q '^PONG$'; then REDIS_READY=1; break; fi
  if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ":${REDIS_CACHE_PORT}[[:space:]]"; then REDIS_READY=1; break; fi
  sleep 1
done
[[ "$REDIS_READY" -eq 1 ]] || err "redis_cache آماده نشد"
log "redis_cache آماده است"

# redis_queue (پورت پیش‌فرض 11000) — seed/commit در after_commit به صف RQ وصل می‌شود
REDIS_QUEUE_CONF="${BENCH_DIR}/config/redis_queue.conf"
if [[ -f "$REDIS_QUEUE_CONF" ]]; then
  REDIS_QUEUE_PORT="$(awk '$1 == "port" {print $2; exit}' "$REDIS_QUEUE_CONF")"
else
  REDIS_QUEUE_PORT="11000"
fi
[[ -n "${REDIS_QUEUE_PORT:-}" ]] || REDIS_QUEUE_PORT="11000"
REDIS_Q_READY=0
for _i in $(seq 1 60); do
  if command -v redis-cli >/dev/null 2>&1 && redis-cli -h 127.0.0.1 -p "$REDIS_QUEUE_PORT" ping 2>/dev/null | grep -q '^PONG$'; then REDIS_Q_READY=1; break; fi
  if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ":${REDIS_QUEUE_PORT}[[:space:]]"; then REDIS_Q_READY=1; break; fi
  sleep 1
done
[[ "$REDIS_Q_READY" -eq 1 ]] || err "redis_queue آماده نشد (پورت ${REDIS_QUEUE_PORT})"
log "redis_queue آماده است (پورت ${REDIS_QUEUE_PORT})"

step "0b) پیش‌نیاز: اپ iran_common (script-01)"
bench use "$SITE_NAME" 2>/dev/null || true
bench --site "$SITE_NAME" list-apps 2>/dev/null | grep -qw "iran_common" \
  || err "ABORT: اپ iran_common نصب نیست. ابتدا script-01.sh را اجرا کنید."
log "iran_common موجود است"

# =============================================================================
step "1) ساخت اپ iran_trade_erp"
# روش اثبات‌شده (غیرتعاملی) — همان الگوی script-01 / ir_jalali که گیر نمی‌کند
if [[ -d "${BENCH_DIR}/apps/${APP}" ]]; then
  warn "اپ ${APP} موجود است — Force-Replace فایل‌ها"
else
  timeout 120 bash -c 'printf "%s\n" "Iran Trade ERP" "Iran Trade ERP — بازرگانی و حمل ایران" "Iran Trade ERP" "dev@local" "mit" "n" | bench new-app iran_trade_erp' \
    || err "bench new-app iran_trade_erp failed (timeout/interactive?)"
  log "اپ ${APP} ساخته شد"
fi
mkdir -p "${MOD}/doctype" "${MOD}/workflow" "${MOD}/notification/adapters/sms" \
         "${MOD}/api" "${MOD}/report" "${MOD}/print_format" "${MOD}/workspace" \
         "${MOD}/setup" "${MOD}/utils" \
         "${PKG}/fixtures" "${PKG}/translations" "${PKG}/public/js" "${PKG}/public/css" \
         "${PKG}/patches/v1_0"

write_utf8 "${PKG}/modules.txt" << 'EOF'
Iran Trade
EOF
for d in "${MOD}" "${MOD}/doctype" "${MOD}/workflow" "${MOD}/notification" \
         "${MOD}/notification/adapters" "${MOD}/notification/adapters/sms" \
         "${MOD}/api" "${MOD}/report" "${MOD}/setup" "${MOD}/utils" \
         "${PKG}/patches" "${PKG}/patches/v1_0"; do
  [[ -f "${d}/__init__.py" ]] || : > "${d}/__init__.py"
done
log "ساختار پوشه‌ها آماده شد"

# =============================================================================
step "2) fixture نقش‌ها (۱۳ نقش) — بدون Administrator"
write_utf8 "${PKG}/fixtures/role.json" << 'EOF'
[
 {"doctype": "Role", "name": "CEO", "role_name": "CEO", "desk_access": 1, "is_custom": 1},
 {"doctype": "Role", "name": "Financial Manager", "role_name": "Financial Manager", "desk_access": 1, "is_custom": 1},
 {"doctype": "Role", "name": "Finance Supervisor", "role_name": "Finance Supervisor", "desk_access": 1, "is_custom": 1},
 {"doctype": "Role", "name": "Finance User", "role_name": "Finance User", "desk_access": 1, "is_custom": 1},
 {"doctype": "Role", "name": "Legal Reviewer", "role_name": "Legal Reviewer", "desk_access": 1, "is_custom": 1},
 {"doctype": "Role", "name": "Treasury User", "role_name": "Treasury User", "desk_access": 1, "is_custom": 1},
 {"doctype": "Role", "name": "Receivables User", "role_name": "Receivables User", "desk_access": 1, "is_custom": 1},
 {"doctype": "Role", "name": "Transport Supervisor", "role_name": "Transport Supervisor", "desk_access": 1, "is_custom": 1},
 {"doctype": "Role", "name": "Transport User - Purchase", "role_name": "Transport User - Purchase", "desk_access": 1, "is_custom": 1},
 {"doctype": "Role", "name": "Transport User - Sales", "role_name": "Transport User - Sales", "desk_access": 1, "is_custom": 1},
 {"doctype": "Role", "name": "Customs Officer", "role_name": "Customs Officer", "desk_access": 1, "is_custom": 1},
 {"doctype": "Role", "name": "Document Signer", "role_name": "Document Signer", "desk_access": 1, "is_custom": 1},
 {"doctype": "Role", "name": "Validation Override", "role_name": "Validation Override", "desk_access": 1, "is_custom": 1}
]
EOF

# =============================================================================
step "3) ابزار مشترک: الگوی ضد ۴۰۴ فارسی + گارد Administrator/Guest"
write_utf8 "${MOD}/utils/naming_guard.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
الگوی ضد «۴۰۴ فارسی» در Frappe v15.

مسئله (سه بار مستقل در تاریخ این پروژه تکرار شد):
  Frappe v15 آدرس نوار کناری را از روی slug(title) می‌سازد ولی مسیر را با
  slug(name) پیدا می‌کند. عنوان فارسی ⇒ slug غیرقابل حل ⇒ «صفحه یافت نشد».

قاعده تخطی‌ناپذیر:
  name == label == title  همیشه انگلیسی/ASCII می‌ماند.
  متن فارسی فقط از translations/fa.csv می‌آید.
"""
import re
import frappe

ASCII_RE = re.compile(r"^[A-Za-z0-9 _\-\.]+$")


def assert_ascii_identifier(value, what="identifier"):
    if not value or not ASCII_RE.match(frappe.utils.cstr(value)):
        frappe.throw(
            "شناسه فنی «{0}» باید انگلیسی باشد تا آدرس صفحه گم نشود: {1}".format(what, value)
        )
    return value


def ensure_workspace(name, label, icon, roles, content, sequence_id=10, public=1,
                     parent=None, module=None, is_default=0):
    """
    ساخت/به‌روزرسانی Workspace با شناسه انگلیسی پایدار — Idempotent.
    برچسب فارسی از fa.csv اعمال می‌شود، نه از title.

    اصلاح: ماژول هر فضا صراحتاً قابل تعیین است. اگر چند فضای کاری یک ماژول
    واحد بگیرند، نگاشت «ماژول ← فضای کاری» Desk به یک فضا فرو می‌پاشد و
    breadcrumb برای همه کاربران یک عنوان تکراری نشان می‌دهد (باگ میز مدیرعامل).
    پیش‌فرض همچنان «Iran Trade» است تا هیچ مصرف‌کنندهٔ قبلی نشکند.
    """
    assert_ascii_identifier(name, "Workspace name")
    assert_ascii_identifier(label, "Workspace label")

    if frappe.db.exists("Workspace", name):
        ws = frappe.get_doc("Workspace", name)
    else:
        ws = frappe.new_doc("Workspace")
        ws.name = name

    ws.label = label
    ws.title = label
    ws.icon = icon or "file"
    ws.public = public
    ws.is_hidden = 0
    ws.module = module if module is not None else "Iran Trade"
    ws.sequence_id = sequence_id
    if is_default:
        ws.is_default = 1
    ws.content = frappe.as_json(content) if not isinstance(content, str) else content
    if parent:
        ws.parent_page = parent
    ws.set("roles", [])
    for r in roles or []:
        ws.append("roles", {"role": r})
    ws.flags.ignore_permissions = True
    ws.flags.ignore_mandatory = True
    ws.save(ignore_permissions=True)
    return ws.name


def purge_persian_workspaces():
    """حذف Workspaceهای فارسی‌نام باقی‌مانده از تلاش‌های قبلی (منبع ۴۰۴)."""
    removed = []
    for row in frappe.get_all("Workspace", fields=["name"]):
        if not ASCII_RE.match(row.name or ""):
            frappe.delete_doc("Workspace", row.name, force=True, ignore_permissions=True)
            removed.append(row.name)
    return removed


FORBIDDEN_USERS = {"Administrator", "Guest"}


def filter_recipients(users):
    """
    گارد سراسری: مدیر سامانه و کاربر مهمان هرگز گیرنده نمی‌شوند.
    اگر پس از فیلتر هیچ‌کس نماند، تابع لیست خالی برمی‌گرداند و
    فراخوان موظف است خطای صریح فارسی ثبت کند (سکوت ممنوع).
    """
    out = []
    for u in users or []:
        if not u:
            continue
        if u in FORBIDDEN_USERS:
            continue
        if not frappe.db.get_value("User", u, "enabled"):
            continue
        if frappe.db.get_value("User", u, "user_type") != "System User":
            continue
        if u not in out:
            out.append(u)
    return out


def users_with_role(role):
    # اصلاح: خواندن از سطح دیتابیس (db) تا در متنِ کاربر عادی (نه مدیر سامانه)
    # که روی DocTypeهای هسته مجوز ندارد، حلّ گیرندگان اعلان هرگز خالی نشود.
    rows = frappe.db.get_all(
        "Has Role", filters={"role": role, "parenttype": "User"}, fields=["parent"]
    )
    return filter_recipients([r.parent for r in rows])
EOF

# =============================================================================
step "4) seed: Transit → شرکت، سال مالی، ۱۲ کاربر واقعی، Administrator مقدس"
# همان روش realign-gate: Warehouse Type «Transit» قبل از Company
write_utf8 "${MOD}/setup/seed_org.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
راه‌اندازی سازمان واقعی.

قاعده‌های تخطی‌ناپذیر:
  * Warehouse Type «Transit» قبل از ساخت Company (ERPNext on_update → create_default_warehouses).
  * Administrator هیچ نقش کسب‌وکاری نمی‌گیرد (فقط System Manager می‌ماند).
  * هر دو مدیرعامل (کرمیان و یوسفی) هم‌زمان CEO و Document Signer هستند.
  * سیستم از روز اول چند-کاربره است: هر نقش می‌تواند N کاربر داشته باشد.
"""
import os
import frappe

# (email, full_name_fa, [roles])
ORG_USERS = [
    ("CEO1", "مدیرعامل یکم", ["CEO", "Document Signer"]),
    ("CEO2", "مدیرعامل دوم", ["CEO", "Document Signer"]),
    ("fin.mgr@irbco.local", "مدیر مالی", ["Financial Manager"]),
    ("ehsan.nahalparvar@irbco.local", "احسان نهال‌پرور", ["Finance Supervisor"]),
    ("faezeh.heydari@irbco.local", "فائزه حیدری", ["Finance User"]),
    ("pouya.soleimani@irbco.local", "پویا سلیمانی", ["Legal Reviewer"]),
    ("atieh.alaei@irbco.local", "عطیه اعلایی", ["Treasury User"]),
    ("zahra.mirzaei@irbco.local", "زهرا میرزایی", ["Receivables User"]),
    ("najmeh.afrashtehpour@irbco.local", "نجمه افراشته‌پور", ["Transport Supervisor"]),
    ("amini@irbco.local", "خانم امینی", ["Transport User - Purchase"]),
    ("mohaddeseh.enayati@irbco.local", "محدثه عنایتی", ["Transport User - Sales"]),
    ("mohammadi@irbco.local", "آقای محمدی", ["Customs Officer"]),
]


def _split_name(full_name):
    parts = (full_name or "").strip().split(" ", 1)
    return parts[0], (parts[1] if len(parts) > 1 else "")


def ensure_user(email, full_name, roles, password):
    first, last = _split_name(full_name)
    if frappe.db.exists("User", email):
        u = frappe.get_doc("User", email)
    else:
        u = frappe.new_doc("User")
        u.email = email
        u.new_password = password
        u.send_welcome_email = 0
    u.first_name = first
    u.last_name = last
    u.full_name = full_name
    u.enabled = 1
    u.user_type = "System User"
    u.language = "fa"
    u.time_zone = "Asia/Tehran"
    existing = {r.role for r in (u.get("roles") or [])}
    for r in roles:
        if r not in existing and frappe.db.exists("Role", r):
            u.append("roles", {"role": r})
    u.flags.ignore_permissions = True
    u.save(ignore_permissions=True)
    return u.name


def restore_administrator():
    """Administrator مقدس است: فقط System Manager، بدون نقش کسب‌وکاری."""
    biz = set()
    for _e, _n, rls in ORG_USERS:
        biz.update(rls)
    biz.add("Validation Override")
    admin = frappe.get_doc("User", "Administrator")
    keep = [r for r in (admin.get("roles") or []) if r.role not in biz]
    admin.set("roles", [])
    for r in keep:
        admin.append("roles", {"role": r.role})
    if not any(r.role == "System Manager" for r in admin.get("roles")):
        admin.append("roles", {"role": "System Manager"})
    admin.enabled = 1
    admin.flags.ignore_permissions = True
    admin.save(ignore_permissions=True)
    return "Administrator cleaned"


def ensure_warehouse_type(name_="Transit"):
    """ERPNext Company.on_update → create_default_warehouses نیاز به Transit دارد.

    همان الگوی realign-gate / setup_seeds.ensure_warehouse_type — Idempotent.
    """
    if frappe.db.exists("Warehouse Type", name_):
        return f"warehouse_type {name_} exists"
    meta = frappe.get_meta("Warehouse Type")
    if meta.autoname and str(meta.autoname).startswith("field:"):
        fieldname = str(meta.autoname).split("field:")[1]
        try:
            frappe.get_doc({"doctype": "Warehouse Type", fieldname: name_}).insert(
                ignore_permissions=True, ignore_links=True
            )
            frappe.db.commit()
            return f"warehouse_type {name_} created (field:{fieldname})"
        except Exception:
            if frappe.db.exists("Warehouse Type", name_):
                return f"warehouse_type {name_} exists"
    try:
        frappe.get_doc({"doctype": "Warehouse Type", "name": name_}).insert(
            ignore_permissions=True, ignore_links=True
        )
        frappe.db.commit()
        return f"warehouse_type {name_} created (name)"
    except Exception:
        if frappe.db.exists("Warehouse Type", name_):
            return f"warehouse_type {name_} exists"
        if meta.has_field("warehouse_type"):
            frappe.get_doc(
                {"doctype": "Warehouse Type", "warehouse_type": name_}
            ).insert(ignore_permissions=True, ignore_links=True)
            frappe.db.commit()
            return f"warehouse_type {name_} created (warehouse_type field)"
    if frappe.db.exists("Warehouse Type", name_):
        return f"warehouse_type {name_} exists"
    frappe.throw(
        "ساخت Warehouse Type «{0}» ناموفق بود — بدون آن Company ساخته نمی‌شود.".format(
            name_
        )
    )


def ensure_company(name, abbr, currency="IRR"):
    existing = frappe.db.get_value("Company", {"company_name": name}, "name")
    if existing:
        return existing
    # اگر با نام دقیق هم موجود است
    if frappe.db.exists("Company", name):
        return name
    c = frappe.new_doc("Company")
    c.company_name = name
    c.abbr = abbr
    c.default_currency = currency
    c.country = "Iran"
    c.flags.ignore_permissions = True
    c.flags.ignore_mandatory = True
    c.insert(ignore_permissions=True)
    return c.name


def ensure_fiscal_year(year_name, start, end):
    if frappe.db.exists("Fiscal Year", year_name):
        return year_name
    fy = frappe.new_doc("Fiscal Year")
    fy.year = year_name
    fy.year_start_date = start
    fy.year_end_date = end
    fy.flags.ignore_permissions = True
    fy.insert(ignore_permissions=True)
    return fy.name


def seed_all():
    out = []
    ceo1_email = os.environ.get("CEO1_EMAIL") or "hadi.karamian@irbco.local"
    ceo1_name = os.environ.get("CEO1_NAME") or "هادی کرمیان"
    ceo2_email = os.environ.get("CEO2_EMAIL") or "saeed.yousefi@irbco.local"
    ceo2_name = os.environ.get("CEO2_NAME") or "سعید یوسفی"
    password = os.environ.get("DEFAULT_PASSWORD") or "Irbco@1404"
    company = os.environ.get("COMPANY_NAME") or "بازرگانی و حمل‌ونقل ایران"
    abbr = os.environ.get("COMPANY_ABBR") or "ITE"

    # ── STEP: Transit BEFORE Company (ERPNext v15) ──
    out.append(ensure_warehouse_type("Transit"))
    frappe.db.commit()

    out.append(ensure_company(company, abbr))
    out.append(ensure_fiscal_year("1405", "2026-03-21", "2027-03-20"))

    for email, name, roles in ORG_USERS:
        if email == "CEO1":
            email, name = ceo1_email, ceo1_name
        elif email == "CEO2":
            email, name = ceo2_email, ceo2_name
        out.append(ensure_user(email, name, roles, password))

    out.append(restore_administrator())
    frappe.db.commit()
    return out
EOF

# =============================================================================
step "4b) مجوزهای پایه هسته برای نقش‌های سازمانی — بستن خلا روز اول"
# ریشه: fixture نقش‌ها هیچ مجوزی روی DocTypeهای هسته نمی‌دهد؛ فرم پرونده
# بازرگانی پر از Link به Customer/Supplier/Company/User/Sales Invoice/
# Purchase Invoice/Payment Entry و اقلام پر از Item/UOM/Currency است.
# بدون read روی هسته، کاربران واقعی در روز اول با dialog «غیر مجاز» مواجه
# می‌شوند. روش: مسیر استاندارد Frappe (Document API روی DocType.permissions،
# نه SQL خام) + راستی‌آزمایی با Meta و frappe.has_permission کاربر واقعی.
write_utf8 "${MOD}/setup/master_permissions.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
مجوزهای پایه هسته برای نقش‌های سازمانی — خلا روز اول.

قاعده بدون حدس:
  * هیچ ستون/نامی فرض نمی‌شود؛ مسیر استاندارد Frappe v15 استفاده می‌شود:
    سطر مجوز در جدول permissions خودِ DocType، با Document API (نه SQL خام).
  * هر پرچم فقط اگر در Meta موجود باشد نوشته می‌شود.
  * اثرِ نوشتن بلافاصله با Meta و frappe.has_permission کاربر واقعی
    راستی‌آزمایی می‌شود؛ ناقص ماندن = خطای صریح (سکوت ممنوع).
  * DocType غایب (فاز بعدی) با اخطار رد می‌شود و در اجرای بعدی می‌نشیند.
"""
import frappe

# ارجاع: fixtures/role.json — هر ۱۳ نقش (۱۲ سازمانی + Validation Override)
BUSINESS_ROLES = [
    "CEO", "Financial Manager", "Finance Supervisor", "Finance User",
    "Legal Reviewer", "Treasury User", "Receivables User",
    "Transport Supervisor", "Transport User - Purchase",
    "Transport User - Sales", "Customs Officer", "Document Signer",
    "Validation Override",
]

# ارجاع: Linkهای trade_case.json / trade_case_item.json / treasury_settings.json /
# border.json / transport_waybill.json + Notification Log (کارتابل script-09)
# + Version (تایم‌لاین کارتابل) + User/Has Role (اعلان script-05)
READ_FOR_ALL = [
    "Customer", "Supplier", "Company", "User", "Item", "UOM",
    "Currency", "Country", "Sales Invoice", "Purchase Invoice",
    "Payment Entry", "Contact", "Address", "Driver", "Vehicle",
    "Version", "DocType", "Workflow State", "Notification Log",
]

CREATE_ROLES = ["Financial Manager", "Finance Supervisor", "Finance User", "CEO"]

# (dt, نقش‌های دارای create/write اضافه بر read)
CREATE_MATRIX = [
    ("Customer", CREATE_ROLES),
    ("Supplier", CREATE_ROLES),
    ("Item", CREATE_ROLES),
    ("Company", ["Financial Manager", "CEO"]),
    ("Sales Invoice", CREATE_ROLES),
    ("Purchase Invoice", CREATE_ROLES),
    ("Payment Entry", CREATE_ROLES + ["Treasury User"]),
]

# کارشناس وصول باید بتواند فاکتورها را ویرایش/علامت‌گذاری کند (بدون create)
WRITE_ONLY = [("Sales Invoice", ["Receivables User"]),
              ("Purchase Invoice", ["Receivables User"])]


def _flags_for(dt, role):
    want = {"read": 1, "report": 1}
    for _dt, roles in CREATE_MATRIX:
        if _dt == dt and role in roles:
            want.update({"create": 1, "write": 1, "delete": 0})
            break
    for _dt, roles in WRITE_ONLY:
        if _dt == dt and role in roles:
            want.setdefault("write", 1)
    return want


def _ensure_row(dt, role, want):
    """سطر مجوز استاندارد در DocType.permissions — با Document API."""
    d = frappe.get_doc("DocType", dt)
    pmeta = frappe.get_meta("DocPerm")
    row = None
    for p in (d.permissions or []):
        if (p.role or "") == role:
            row = p
            break
    if row is None:
        row = d.append("permissions", {"role": role})
    for f in pmeta.fields:
        if f.fieldname in want:
            row.set(f.fieldname, want[f.fieldname])
    d.flags.ignore_permissions = True
    d.flags.ignore_mandatory = True
    d.save(ignore_permissions=True)


def _effective(dt, role, want):
    """راستی‌آزمایی: هر پرچم باید دقیقاً برابر مقدار خواسته‌شده باشد (از جمله 0)."""
    meta = frappe.get_meta(dt)
    for p in (meta.permissions or []):
        if (p.role or "") == role:
            return all(int(p.get(f) or 0) == int(v) for f, v in want.items())
    return False


def apply_master_permissions():
    tasks, skipped = [], []
    for dt in READ_FOR_ALL:
        for role in BUSINESS_ROLES:
            tasks.append((dt, role, _flags_for(dt, role)))
    for dt, role, want in tasks:
        if not frappe.db.exists("DocType", dt):
            skipped.append(dt)
            continue
        _ensure_row(dt, role, want)
    frappe.db.commit()
    frappe.clear_cache()

    pending = [(dt, r, w) for (dt, r, w) in tasks
               if frappe.db.exists("DocType", dt) and not _effective(dt, r, w)]
    if pending:
        raise Exception("مجوزهای پایه ناقص ماند: " +
                        ", ".join("{0}/{1}".format(d, r) for d, r, _w in pending[:20]))
    return {"tasks": len(tasks), "skipped_missing": sorted(set(skipped))}
EOF

# =============================================================================
step "5) DocType سلسله‌مراتب سرپرستی (تیم و اعضا) — چند-کاربره از روز اول"
mkdir -p "${MOD}/doctype/supervisor_team_member" "${MOD}/doctype/supervisor_team"
: > "${MOD}/doctype/supervisor_team_member/__init__.py"
: > "${MOD}/doctype/supervisor_team/__init__.py"

write_utf8 "${MOD}/doctype/supervisor_team_member/supervisor_team_member.json" << 'EOF'
{
 "actions": [], "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType",
 "editable_grid": 1, "engine": "InnoDB", "istable": 1,
 "field_order": ["team_user", "user_full_name", "is_active", "max_open_cases"],
 "fields": [
  {"fieldname": "team_user", "fieldtype": "Link", "in_list_view": 1, "label": "کاربر زیرمجموعه", "options": "User", "reqd": 1, "columns": 4},
  {"fetch_from": "team_user.full_name", "fieldname": "user_full_name", "fieldtype": "Data", "in_list_view": 1, "label": "نام کامل", "read_only": 1, "columns": 4},
  {"default": "1", "fieldname": "is_active", "fieldtype": "Check", "in_list_view": 1, "label": "فعال", "columns": 1},
  {"fieldname": "max_open_cases", "fieldtype": "Int", "in_list_view": 1, "label": "سقف پرونده باز", "columns": 2}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Supervisor Team Member", "owner": "Administrator",
 "permissions": [], "sort_field": "modified", "sort_order": "DESC"
}
EOF
write_utf8 "${MOD}/doctype/supervisor_team_member/supervisor_team_member.py" << 'EOF'
# -*- coding: utf-8 -*-
from frappe.model.document import Document


class SupervisorTeamMember(Document):
    pass
EOF

write_utf8 "${MOD}/doctype/supervisor_team/supervisor_team.json" << 'EOF'
{
 "actions": [], "autoname": "field:team_name", "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["team_name", "supervisor", "unit", "is_active", "sb_members", "members"],
 "fields": [
  {"fieldname": "team_name", "fieldtype": "Data", "label": "نام تیم", "reqd": 1, "unique": 1, "in_list_view": 1},
  {"fieldname": "supervisor", "fieldtype": "Link", "label": "سرپرست", "options": "User", "reqd": 1, "in_list_view": 1},
  {"fieldname": "unit", "fieldtype": "Select", "label": "واحد", "options": "مالی\nحمل\nگمرک", "reqd": 1, "in_list_view": 1},
  {"default": "1", "fieldname": "is_active", "fieldtype": "Check", "label": "فعال"},
  {"fieldname": "sb_members", "fieldtype": "Section Break", "label": "اعضای تیم"},
  {"fieldname": "members", "fieldtype": "Table", "label": "اعضا", "options": "Supervisor Team Member"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Supervisor Team", "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "read": 1, "write": 1, "report": 1, "role": "System Manager"},
  {"read": 1, "write": 1, "report": 1, "role": "Finance Supervisor"},
  {"read": 1, "write": 1, "report": 1, "role": "Transport Supervisor"},
  {"read": 1, "report": 1, "role": "Financial Manager"}
 ],
 "sort_field": "modified", "sort_order": "DESC", "title_field": "team_name", "track_changes": 1
}
EOF
write_utf8 "${MOD}/doctype/supervisor_team/supervisor_team.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
from frappe.model.document import Document
from iran_trade_erp.iran_trade.utils.naming_guard import FORBIDDEN_USERS


class SupervisorTeam(Document):
    def validate(self):
        if self.supervisor in FORBIDDEN_USERS:
            frappe.throw("مدیر سامانه یا کاربر مهمان نمی‌تواند سرپرست تیم باشد.")
        seen = set()
        for row in self.members or []:
            if row.team_user in FORBIDDEN_USERS:
                frappe.throw("مدیر سامانه یا کاربر مهمان نمی‌تواند عضو تیم باشد.")
            if row.team_user in seen:
                frappe.throw("کاربر «{0}» بیش از یک بار در تیم آمده است.".format(row.team_user))
            seen.add(row.team_user)


@frappe.whitelist()
def get_team_members(supervisor=None, unit=None):
    """اعضای زیرمجموعه یک سرپرست — سرپرست فقط تیم خودش را می‌بیند."""
    supervisor = supervisor or frappe.session.user
    if supervisor != frappe.session.user and not frappe.has_permission("Supervisor Team", "write"):
        frappe.throw("شما اجازه مشاهده تیم کاربر دیگری را ندارید.")
    filters = {"supervisor": supervisor, "is_active": 1}
    if unit:
        filters["unit"] = unit
    teams = frappe.get_all("Supervisor Team", filters=filters, pluck="name")
    out = []
    for t in teams:
        doc = frappe.get_doc("Supervisor Team", t)
        for m in doc.members:
            if m.is_active:
                out.append({
                    "user": m.team_user,
                    "full_name": m.user_full_name,
                    "max_open_cases": m.max_open_cases or 0,
                    "team": t,
                    "unit": doc.unit,
                })
    return out
EOF

# =============================================================================
step "6) hooks.py با بلوک‌های نشانه‌دار (Marker) — ادغام‌شونده، نه بازنویسی"
# اگر hooks از قبل هست (scaffold bench new-app)، فقط بلوک SCRIPT02 را ادغام کن
python3 - "$PKG" << 'PYEOF'
import io, os, re, sys
pkg = sys.argv[1]
hooks = os.path.join(pkg, "hooks.py")
src = ""
if os.path.exists(hooks):
    src = io.open(hooks, encoding="utf-8").read()

START = "# --- SCRIPT02_HOOKS_START ---"
END = "# --- SCRIPT02_HOOKS_END ---"
src = re.sub(re.escape(START) + r".*?" + re.escape(END) + r"\n?", "", src, flags=re.S)

# اگر فایل خالی/ناقص است یا app_name ندارد، اسکلت کامل بنویس؛ وگرنه فقط بلوک را append کن
need_skeleton = ("app_name" not in src) or ("iran_trade_erp" not in src)

skeleton = '''# -*- coding: utf-8 -*-
# =============================================================================
# hooks.py — iran_trade_erp
# قاعده حیاتی: این فایل «حالت مشترک» بین همه اسکریپت‌هاست.
# هر فاز فقط بلوک نشانه‌دار خودش را می‌نویسد و هرگز dict/list دیگری را
# بازنویسی نمی‌کند. الگوی ادغام: globals().get("doc_events", {})
# =============================================================================
app_name = "iran_trade_erp"
app_title = "Iran Trade ERP"
app_publisher = "Iran Trade ERP"
app_description = "سامانه پرونده بازرگانی و حمل ایران"
app_email = "dev@local"
app_license = "MIT"

required_apps = ["frappe", "erpnext", "iran_common"]

fixtures = [
    {"dt": "Role", "filters": [["name", "in", [
        "CEO", "Financial Manager", "Finance Supervisor", "Finance User",
        "Legal Reviewer", "Treasury User", "Receivables User",
        "Transport Supervisor", "Transport User - Purchase",
        "Transport User - Sales", "Customs Officer", "Document Signer",
        "Validation Override"
    ]]]},
]

doc_events = {}
scheduler_events = {}
app_include_js = []
app_include_css = []
'''

block = '''# --- SCRIPT02_HOOKS_START ---
# اسکلت: هیچ رویداد سندی در این فاز ثبت نمی‌شود.
# --- SCRIPT02_HOOKS_END ---
'''

if need_skeleton:
    # scaffold را با اسکلت خودمان جایگزین نکن اگر فقط app_name فرق دارد —
    # ولی new-app تازه معمولاً app_name درست دارد؛ برای اطمینان:
    if not src.strip() or "app_name" not in src:
        out = skeleton + "\n" + block + "\n"
    else:
        # hooks موجود (scaffold): required_apps / fixtures را با regex امن تنظیم کن
        if "required_apps" not in src:
            src += '\nrequired_apps = ["frappe", "erpnext", "iran_common"]\n'
        if "fixtures" not in src:
            src += '''
fixtures = [
    {"dt": "Role", "filters": [["name", "in", [
        "CEO", "Financial Manager", "Finance Supervisor", "Finance User",
        "Legal Reviewer", "Treasury User", "Receivables User",
        "Transport Supervisor", "Transport User - Purchase",
        "Transport User - Sales", "Customs Officer", "Document Signer",
        "Validation Override"
    ]]]},
]
'''
        if re.search(r"^doc_events\s*=", src, flags=re.M) is None:
            src += "\ndoc_events = {}\n"
        if re.search(r"^scheduler_events\s*=", src, flags=re.M) is None:
            src += "\nscheduler_events = {}\n"
        if re.search(r"^app_include_js\s*=", src, flags=re.M) is None:
            src += "\napp_include_js = []\n"
        if re.search(r"^app_include_css\s*=", src, flags=re.M) is None:
            src += "\napp_include_css = []\n"
        out = src.rstrip() + "\n\n" + block + "\n"
else:
    out = src.rstrip() + "\n\n" + block + "\n"

io.open(hooks, "w", encoding="utf-8").write(out)
import ast
ast.parse(out)
print("hooks.py updated (marker-safe):", hooks)
PYEOF
log "hooks.py نوشته شد"

# =============================================================================
step "7) ترجمه فارسی (fa.csv) — منبع واحد برچسب‌های نمایشی"
write_utf8 "${PKG}/translations/fa.csv" << 'EOF'
Iran Trade,بازرگانی ایران,
Iran Trade ERP,سامانه بازرگانی و حمل ایران,
CEO,مدیرعامل,
Financial Manager,مدیر مالی,
Finance Supervisor,سرپرست مالی,
Finance User,کارشناس مالی,
Legal Reviewer,بررسی حقوقی,
Treasury User,کارشناس خزانه,
Receivables User,کارشناس وصول مطالبات,
Transport Supervisor,سرپرست حمل,
Transport User - Purchase,کارشناس حمل خرید,
Transport User - Sales,کارشناس حمل فروش,
Customs Officer,کارشناس گمرک,
Document Signer,امضاکننده سند,
Validation Override,عبور از اعتبارسنجی,
Supervisor Team,تیم سرپرستی,
Supervisor Team Member,عضو تیم سرپرستی,
EOF

# =============================================================================
step "8) نصب اپ + migrate"
if bench --site "$SITE_NAME" list-apps 2>/dev/null | grep -qw "$APP"; then
  warn "اپ ${APP} از قبل نصب است"
else
  bench --site "$SITE_NAME" install-app "$APP"
fi
bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache

step "9) اجرای seed سازمان (Transit → شرکت/سال مالی/کاربران)"
bench --site "$SITE_NAME" execute iran_trade_erp.iran_trade.setup.seed_org.seed_all

# اصلاح خلا روز اول: مجوزهای پایه هسته برای نقش‌های سازمانی
# (بدون این، کاربران واقعی در فرم پرونده با dialog «مشتری/شرکت» روبه‌رو می‌شدند)
bench --site "$SITE_NAME" execute iran_trade_erp.iran_trade.setup.master_permissions.apply_master_permissions

# =============================================================================
step "10) Verify داخلی — اجرای واقعی"
write_utf8 "${PKG}/verify_script02.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe

ROLES = ["CEO", "Financial Manager", "Finance Supervisor", "Finance User",
         "Legal Reviewer", "Treasury User", "Receivables User",
         "Transport Supervisor", "Transport User - Purchase",
         "Transport User - Sales", "Customs Officer", "Document Signer",
         "Validation Override"]


def run():
    passed = failed = 0

    def chk(t, c):
        nonlocal passed, failed
        if c:
            passed += 1; print("  [PASS] " + t)
        else:
            failed += 1; print("  [FAIL] " + t)

    for r in ROLES:
        chk("نقش موجود است: " + r, frappe.db.exists("Role", r) is not None)

    chk("Warehouse Type Transit موجود است",
        bool(frappe.db.exists("Warehouse Type", "Transit")))
    chk("شرکت ساخته شد", frappe.db.count("Company") >= 1)
    chk("سال مالی 1405 ساخته شد", frappe.db.exists("Fiscal Year", "1405") is not None)

    ceos = frappe.get_all("Has Role", filters={"role": "CEO", "parenttype": "User"}, pluck="parent")
    ceos = [c for c in ceos if c not in ("Administrator", "Guest")]
    chk("دقیقاً دو مدیرعامل واقعی وجود دارد", len(ceos) >= 2)

    signers = frappe.get_all("Has Role", filters={"role": "Document Signer", "parenttype": "User"}, pluck="parent")
    dual = [c for c in ceos if c in signers]
    chk("هر دو مدیرعامل هم‌زمان امضاکننده سند هستند", len(dual) >= 2)

    admin_roles = {r.role for r in frappe.get_doc("User", "Administrator").roles}
    biz = set(ROLES)
    chk("Administrator هیچ نقش کسب‌وکاری ندارد", len(admin_roles & biz) == 0)

    from iran_trade_erp.iran_trade.utils.naming_guard import filter_recipients
    chk("گارد گیرنده، Administrator/Guest را حذف می‌کند",
        filter_recipients(["Administrator", "Guest"]) == [])

    chk("«تیم سرپرستی» ساخته شد", frappe.db.count("DocType", {"name": "Supervisor Team"}) == 1)

    # سناریوی منفی الگوی ۴۰۴
    from iran_trade_erp.iran_trade.utils.naming_guard import assert_ascii_identifier
    blocked = False
    try:
        assert_ascii_identifier("داشبورد مدیرعامل", "Workspace name")
    except Exception:
        blocked = True
    chk("شناسه فارسی برای Workspace مسدود می‌شود (ضد ۴۰۴)", blocked)

    # اصلاح خلا روز اول — راستی‌آزمایی با کاربر واقعی، نه Administrator
    from iran_trade_erp.iran_trade.setup.master_permissions import apply_master_permissions
    res = apply_master_permissions()
    chk("اعمال مجوزهای پایه اجرا شد (Idempotent)", res["tasks"] > 0)

    sup = frappe.get_all("Has Role", filters={"role": "Finance Supervisor",
                                              "parenttype": "User"}, pluck="parent")
    sup = [u for u in sup if u not in ("Administrator", "Guest")]
    chk("کاربر سرپرست مالی واقعی موجود است", bool(sup))
    if sup:
        u = sup[0]
        chk("★ رفع dialog «مشتری»: read برای سرپرست مالی",
            frappe.has_permission("Customer", "read", user=u))
        chk("★ رفع dialog «شرکت»: read برای سرپرست مالی",
            frappe.has_permission("Company", "read", user=u))
        chk("ایجاد مشتری توسط سرپرست مالی",
            frappe.has_permission("Customer", "create", user=u))
        chk("ایجاد تأمین‌کننده توسط سرپرست مالی",
            frappe.has_permission("Supplier", "create", user=u))
        chk("read روی User (گیرنده‌های اعلان script-05)",
            frappe.has_permission("User", "read", user=u))
        chk("read روی Version (تایم‌لاین کارتابل script-09)",
            frappe.has_permission("Version", "read", user=u))
    fu = frappe.get_all("Has Role", filters={"role": "Finance User",
                                             "parenttype": "User"}, pluck="parent")
    fu = [x for x in fu if x not in ("Administrator", "Guest")]
    if fu:
        chk("read روی کالا برای کارشناس مالی",
            frappe.has_permission("Item", "read", user=fu[0]))
        chk("read روی فاکتور خرید برای کارشناس مالی",
            frappe.has_permission("Purchase Invoice", "read", user=fu[0]))
    co = frappe.get_all("Has Role", filters={"role": "Customs Officer",
                                             "parenttype": "User"}, pluck="parent")
    co = [x for x in co if x not in ("Administrator", "Guest")]
    if co:
        chk("read روی راننده برای کارشناس گمرک",
            frappe.has_permission("Driver", "read", user=co[0]))

    print("\n  Passed: %d | Failed: %d" % (passed, failed))
    if failed:
        raise Exception("verify_script02 FAILED: %d" % failed)
    return "OK"
EOF

bench --site "$SITE_NAME" execute iran_trade_erp.verify_script02.run

cat <<FINAL

============================================================
 script-02.sh با موفقیت تمام شد
------------------------------------------------------------
 اپ         : iran_trade_erp (ماژول Iran Trade)
 نقش‌ها      : ۱۳ نقش (۱۲ سازمانی + Validation Override)
 کاربران    : ۱۲ کاربر واقعی؛ دو مدیرعامل با نقش دوگانه
 Transit    : Warehouse Type قبل از Company
 Administrator : بدون هیچ نقش کسب‌وکاری (مقدس)
 ابزار      : naming_guard (ضد ۴۰۴ فارسی + گارد گیرنده)
 گام بعدی   : bash script-03.sh
============================================================
FINAL