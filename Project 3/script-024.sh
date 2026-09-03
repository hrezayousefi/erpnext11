#!/usr/bin/env bash
# =============================================================================
# script-02.sh — اپ پایهٔ مستقل «iran_notify»
# زیرساخت عمومی هشدار/اعلان — Iran Trade ERP
# ERPNext v15 / Frappe v15 | File-First | Idempotent | No bench console
# -----------------------------------------------------------------------------
# این اسکریپت نتیجهٔ مرور خط‌به‌خطِ ۵ نمونهٔ ساخته‌شده توسط AIهای مختلف است
# (script-02.sh, script-02-iran-notify2.sh, script-02-notification-hub.sh,
#  script-02-notification-hub2.sh, script-02-iran-alerts.sh) که در پوشهٔ
#  ./erpnext مطالعه شدند. از هرکدام بهترین ایده نگه داشته شده و مواردی که
#  به‌صراحت غیرمفید تشخیص داده شدند حذف شدند.
#
# ★ تصمیم معماری کلیدی (طبق خواستهٔ کارفرما):
#   هر «رویداد اعلان» فقط یک تصمیم انسانی واقعی دارد:
#     اعلان داخلی  = رایگان و همیشه روشن (اصلاً کلید خاموش/روشن ندارد)
#     پیامک        = پولی → یک تیک ساده: «ارسال پیامک برای این رویداد» (send_sms)
#   بنابراین DocType «رویداد اعلان» یک چک‌باکس send_sms دارد، نه سه/چهار چک‌باکس
#   به‌هم‌ریخته مثل نمونه‌های اولیه.
#
# ★ چیزی که عمداً حذف شد (طبق تحلیل، این‌ها زیرساخت واقعی نیستند):
#     sms_daily_cap / sms_monthly_cap / sms_unit_cost /
#     cost_alert_threshold_percent / گزارش «Alert Cost By Event» /
#     رویداد alert.cost_threshold
#   دلیل: کنترل هزینهٔ واقعیِ پیامک وظیفهٔ خودِ پنل/درگاه پیامکی است؛ آن پنل هم
#   دقیق‌تر می‌شمارد و هم مطمئن‌تر قطع می‌کند. اضافه‌کردن یک شمارندهٔ دوم داخل
#   ERPNext فقط توهم کنترل می‌دهد و نگهداری آن هزینهٔ مهندسی بی‌فایده دارد.
#
# این اپ به هیچ DocType کسب‌وکاری (Trade Case، حمل، فاکتور و ...) قفل نیست.
# فقط یک ابزار عمومی است که در فازهای بعدی (ساخت ورک‌فلوی واقعی خرید/فروش/حمل)
# با یک خط فراخوانی می‌شود:
#
#     from iran_notify import notify
#     notify("case.legal_rejected", "Trade Case", doc.name,
#            {"reason": "مدارک ناقص است"})
#
# تضمین‌های تخطی‌ناپذیر notify():
#   1) هرگز استثنا به بیرون پرتاب نمی‌کند (ذخیرهٔ سند کاربر هرگز به‌خاطر
#      اعلان نمی‌شکند)
#   2) هرگز سند مرجع را save/reload نمی‌کند (ساعت SLA/مهلت دست‌نخورده می‌ماند)
#   3) Administrator و Guest مطلقاً هرگز گیرندهٔ اعلان نمی‌شوند
#   4) نبود رویداد/گیرنده/قالب = ثبت در دفتر خطا با پیام فارسی روشن،
#      هرگز سکوت
#   5) پیامک واقعی تا وقتی «Kill-Switch» (sms_master_enabled) روشن نشود
#      ارسال نمی‌شود؛ پیش‌فرض کارخانه: خاموش + حالت آزمایشی روشن
#   6) تکرار در یک بازهٔ کول‌داون با نمایهٔ یکتای واقعی دیتابیس کنترل می‌شود
#      (نه یک بررسی نرم در پایتون که در شرایط هم‌زمانی شکست می‌خورد)
#   7) ادغام hooks.py همیشه با بلوک نشانه‌دار و امن است — هرگز فایل کاربر را
#      کامل بازنویسی نمی‌کند
# =============================================================================
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=utf-8

export SITE_NAME="${SITE_NAME:-transport-dev.local}"
export BENCH_DIR="${BENCH_DIR:-${HOME}/frappe-bench}"
export APP="iran_notify"
export PKG="${BENCH_DIR}/apps/${APP}/${APP}"
export MOD="${PKG}/iran_notify"
export DT="${MOD}/doctype"

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

validate_py() {
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$1" \
    || err "Python syntax error: $1"
}

mk_dt() {
  mkdir -p "${DT}/$1"
  : > "${DT}/$1/__init__.py"
}

[[ -d "$BENCH_DIR" ]] || err "Bench یافت نشد: $BENCH_DIR"
cd "$BENCH_DIR"

# =============================================================================
step "0) سرویس‌های bench و redis"
if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "bench از قبل در حال اجراست"
else
  nohup bench start >>/tmp/bench-start-iran-notify.log 2>&1 &
  log "bench start pid=$! (در حال استارت آپ اولیه...)"; sleep 5
fi

# تابع کمکی برای بررسی بالا آمدن پورت‌های Redis
wait_for_redis() {
  local port=$1
  local name=$2
  local ready=0
  for _i in $(seq 1 60); do
    if command -v redis-cli >/dev/null 2>&1 && redis-cli -h 127.0.0.1 -p "$port" ping 2>/dev/null | grep -q '^PONG$'; then
      ready=1; break
    fi
    if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ":${port}[[:space:]]"; then
      ready=1; break
    fi
    sleep 1
  done
  
  if [[ "$ready" -eq 1 ]]; then
    log "$name (پورت $port) آماده است"
  else
    err "$name (پورت $port) آماده نشد. لاگ: /tmp/bench-start-iran-notify.log"
  fi
}

# استخراج پورت‌ها از فایل‌های تنظیمات Bench
REDIS_CACHE_PORT="13000"
REDIS_QUEUE_PORT="11000"

if [[ -f "${BENCH_DIR}/config/redis_cache.conf" ]]; then
  REDIS_CACHE_PORT="$(awk '$1 == "port" {print $2; exit}' "${BENCH_DIR}/config/redis_cache.conf")"
fi
if [[ -f "${BENCH_DIR}/config/redis_queue.conf" ]]; then
  REDIS_QUEUE_PORT="$(awk '$1 == "port" {print $2; exit}' "${BENCH_DIR}/config/redis_queue.conf")"
fi

# انتظار برای هر دو سرویس (ترتیب مهم نیست اما هر دو حیاتی‌اند)
wait_for_redis "$REDIS_CACHE_PORT" "Redis Cache"
wait_for_redis "$REDIS_QUEUE_PORT" "Redis Queue"

log "همهٔ سرویس‌های Redis (Cache و Queue) آماده هستند"


# =============================================================================
step "1) ساخت اسکلت اپ مستقل ${APP}"
if [[ -d "${BENCH_DIR}/apps/${APP}" ]]; then
  warn "اپ ${APP} موجود است — فقط فایل‌ها بازنویسی می‌شوند (Force-Replace)"
else
  timeout 120 bash -c 'printf "%s\n" "Iran Notify" "Iranian notification/alert infrastructure: internal + SMS, reusable across all future workflow apps" "Iran Trade ERP" "dev@local" "mit" "n" | bench new-app iran_notify' \
    || err "bench new-app iran_notify failed (timeout/interactive?)"
  log "اپ ${APP} ساخته شد"
fi

mkdir -p "${PKG}/notification" "${PKG}/channels" "${PKG}/sms/adapters" \
         "${PKG}/public/js" "${PKG}/public/css" "${PKG}/translations" \
         "${MOD}/doctype" "${MOD}/workspace/iran_notify" \
         "${MOD}/workspace/my_notification_preferences"

write_utf8 "${PKG}/modules.txt" << 'EOF'
Iran Notify
EOF

write_utf8 "${PKG}/notification/__init__.py" << 'EOF'
# -*- coding: utf-8 -*-
EOF
write_utf8 "${PKG}/channels/__init__.py" << 'EOF'
# -*- coding: utf-8 -*-
EOF
write_utf8 "${PKG}/sms/__init__.py" << 'EOF'
# -*- coding: utf-8 -*-
EOF
write_utf8 "${PKG}/sms/adapters/__init__.py" << 'EOF'
# -*- coding: utf-8 -*-
EOF
write_utf8 "${MOD}/__init__.py" << 'EOF'
EOF
write_utf8 "${MOD}/doctype/__init__.py" << 'EOF'
EOF
write_utf8 "${MOD}/workspace/__init__.py" << 'EOF'
EOF
write_utf8 "${MOD}/workspace/iran_notify/__init__.py" << 'EOF'
EOF
write_utf8 "${MOD}/workspace/my_notification_preferences/__init__.py" << 'EOF'
EOF

# =============================================================================
step "2) DocType — تنظیمات مرکز اعلان (Single)"
mk_dt notify_settings
write_utf8 "${DT}/notify_settings/notify_settings.json" << 'EOF'
{
 "actions": [],
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "field_order": [
  "sb_master", "master_enabled", "sms_master_enabled", "cb_master", "test_mode", "test_mobile",
  "sb_defaults", "default_sms_gateway", "default_cooldown_minutes", "enable_user_preferences",
  "sb_quiet", "quiet_hours_enabled", "quiet_hours_start", "cb_quiet", "quiet_hours_end",
  "sb_digest", "health_digest_enabled", "health_digest_roles",
  "notes"
 ],
 "fields": [
  {"fieldname": "sb_master", "fieldtype": "Section Break", "label": "کلیدهای اصلی (Kill-Switch)"},
  {"default": "1", "fieldname": "master_enabled", "fieldtype": "Check", "label": "سیستم اعلان فعال باشد", "description": "توقف اضطراری کل سیستم اعلان (داخلی + پیامک)."},
  {"default": "0", "fieldname": "sms_master_enabled", "fieldtype": "Check", "label": "ارسال واقعی پیامک فعال باشد", "description": "تا این کلید روشن نشود، هیچ پیامک واقعی — حتی اگر رویدادها send_sms داشته باشند — ارسال نمی‌شود."},
  {"fieldname": "cb_master", "fieldtype": "Column Break"},
  {"default": "1", "fieldname": "test_mode", "fieldtype": "Check", "label": "حالت آزمایشی", "description": "در حالت آزمایشی، پیامک به‌جای مخابره واقعی فقط در دفتر ارسال ثبت می‌شود."},
  {"depends_on": "eval:doc.test_mode", "fieldname": "test_mobile", "fieldtype": "Data", "label": "شمارهٔ موبایل تست (اختیاری)"},

  {"fieldname": "sb_defaults", "fieldtype": "Section Break", "label": "پیش‌فرض‌ها"},
  {"fieldname": "default_sms_gateway", "fieldtype": "Link", "label": "درگاه پیامک پیش‌فرض", "options": "SMS Gateway Profile"},
  {"default": "10", "fieldname": "default_cooldown_minutes", "fieldtype": "Int", "label": "کول‌داون پیش‌فرض (دقیقه)", "description": "اگر رویداد کول‌داون اختصاصی نداشته باشد از این مقدار استفاده می‌شود."},
  {"default": "1", "fieldname": "enable_user_preferences", "fieldtype": "Check", "label": "کاربران بتوانند رویدادهای غیرحیاتی را برای خودشان بی‌صدا کنند"},

  {"fieldname": "sb_quiet", "fieldtype": "Section Break", "label": "ساعات سکوت"},
  {"default": "1", "fieldname": "quiet_hours_enabled", "fieldtype": "Check", "label": "ساعات سکوت فعال باشد"},
  {"default": "22:00:00", "depends_on": "eval:doc.quiet_hours_enabled", "fieldname": "quiet_hours_start", "fieldtype": "Time", "label": "شروع سکوت"},
  {"fieldname": "cb_quiet", "fieldtype": "Column Break"},
  {"default": "07:00:00", "depends_on": "eval:doc.quiet_hours_enabled", "fieldname": "quiet_hours_end", "fieldtype": "Time", "label": "پایان سکوت"},

  {"fieldname": "sb_digest", "fieldtype": "Section Break", "label": "گزارش سلامت روزانه"},
  {"default": "1", "fieldname": "health_digest_enabled", "fieldtype": "Check", "label": "گزارش روزانهٔ سلامت اعلان فعال باشد"},
  {"fieldname": "health_digest_roles", "fieldtype": "Table MultiSelect", "label": "نقش‌های دریافت‌کنندهٔ گزارش سلامت", "options": "Notification Recipient Role"},

  {"fieldname": "notes", "fieldtype": "Small Text", "label": "یادداشت"}
 ],
 "issingle": 1,
 "links": [],
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Iran Notify",
 "name": "Notify Settings",
 "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "email": 1, "print": 1, "read": 1, "role": "System Manager", "share": 1, "write": 1},
  {"read": 1, "role": "Notification Manager", "write": 1}
 ],
 "sort_field": "modified",
 "sort_order": "DESC",
 "track_changes": 1
}
EOF
write_utf8 "${DT}/notify_settings/notify_settings.py" << 'PYEOF'
# -*- coding: utf-8 -*-
import frappe
from frappe import _
from frappe.model.document import Document


class NotifySettings(Document):
    def validate(self):
        if self.sms_master_enabled and self.test_mode and not (self.test_mobile or "").strip():
            frappe.msgprint(
                _("پیامک واقعی روشن است و حالت آزمایشی هم فعال است؛ بدون «شمارهٔ موبایل تست» "
                  "پیامک‌ها فقط در دفتر ارسال ثبت می‌شوند و به هیچ شماره‌ای مخابره نمی‌شوند."),
                indicator="orange",
                alert=True,
            )
PYEOF

# =============================================================================
step "3) DocType — درگاه پیامک (Plugin Architecture برای آداپتورها)"
mk_dt sms_gateway_profile
write_utf8 "${DT}/sms_gateway_profile/sms_gateway_profile.json" << 'EOF'
{
 "actions": [],
 "autoname": "field:profile_name",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "field_order": [
  "sb_id", "profile_name", "adapter_key", "cb_id", "is_default", "is_enabled",
  "sb_cfg", "config_json", "required_fields_hint"
 ],
 "fields": [
  {"fieldname": "sb_id", "fieldtype": "Section Break", "label": "شناسه"},
  {"fieldname": "profile_name", "fieldtype": "Data", "in_list_view": 1, "label": "نام درگاه", "reqd": 1, "unique": 1},
  {"description": "باید دقیقاً یکی از کلیدهای ثبت‌شده در Registry آداپتورهای پیامک باشد.", "fieldname": "adapter_key", "fieldtype": "Data", "in_list_view": 1, "label": "کلید آداپتور", "reqd": 1},
  {"fieldname": "cb_id", "fieldtype": "Column Break"},
  {"default": "0", "fieldname": "is_default", "fieldtype": "Check", "in_list_view": 1, "label": "درگاه پیش‌فرض"},
  {"default": "1", "fieldname": "is_enabled", "fieldtype": "Check", "in_list_view": 1, "label": "فعال"},
  {"fieldname": "sb_cfg", "fieldtype": "Section Break", "label": "پیکربندی آداپتور"},
  {"description": "فیلدهای لازم به آداپتور بستگی دارد (پایین را ببینید). نمونه: {\"api_key\": \"...\", \"sender_id\": \"...\"}", "fieldname": "config_json", "fieldtype": "Code", "label": "پیکربندی (JSON)", "options": "JSON"},
  {"fieldname": "required_fields_hint", "fieldtype": "HTML", "label": "فیلدهای لازم این آداپتور"}
 ],
 "links": [],
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Iran Notify",
 "name": "SMS Gateway Profile",
 "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "email": 1, "print": 1, "read": 1, "role": "System Manager", "share": 1, "write": 1},
  {"create": 1, "read": 1, "role": "Notification Manager", "write": 1}
 ],
 "sort_field": "modified",
 "sort_order": "DESC",
 "title_field": "profile_name",
 "track_changes": 1
}
EOF
write_utf8 "${DT}/sms_gateway_profile/sms_gateway_profile.py" << 'PYEOF'
# -*- coding: utf-8 -*-
import json

import frappe
from frappe import _
from frappe.model.document import Document


class SMSGatewayProfile(Document):
    def validate(self):
        from iran_notify.sms.registry import get_adapter

        adapter_cls = get_adapter((self.adapter_key or "").strip())
        if not adapter_cls:
            frappe.throw(_("کلید آداپتور «{0}» در Registry ثبت نشده است.").format(self.adapter_key))

        try:
            cfg = json.loads(self.config_json or "{}")
            if not isinstance(cfg, dict):
                raise ValueError
        except Exception:
            frappe.throw(_("پیکربندی باید یک JSON معتبر (شیء) باشد."))
            return

        missing = []
        for field in adapter_cls.required_fields():
            if field.get("required") and not (cfg.get(field["name"]) or "").strip() if isinstance(cfg.get(field["name"]), str) else not cfg.get(field["name"]):
                if field.get("required"):
                    missing.append(field.get("label") or field["name"])
        if missing:
            frappe.throw(_("فیلدهای الزامی آداپتور خالی است: {0}").format("، ".join(missing)))

    def before_save(self):
        if self.is_default:
            frappe.db.set_value(
                "SMS Gateway Profile",
                {"name": ["!=", self.name or ""], "is_default": 1},
                "is_default",
                0,
            )
PYEOF

write_utf8 "${PKG}/public/js/sms_gateway_profile.js" << 'JS'
frappe.ui.form.on("SMS Gateway Profile", {
	refresh: function (frm) {
		render_hint(frm);
	},
	adapter_key: function (frm) {
		render_hint(frm);
	},
});

function render_hint(frm) {
	if (!frm.doc.adapter_key) {
		frm.set_df_property("required_fields_hint", "options", "");
		return;
	}
	frappe.call({
		method: "iran_notify.api.get_adapter_required_fields",
		args: { adapter_key: frm.doc.adapter_key },
		callback: function (r) {
			if (!r.message) return;
			if (r.message.error) {
				frm.set_df_property(
					"required_fields_hint",
					"options",
					`<div class="text-danger small">${frappe.utils.escape_html(r.message.error)}</div>`
				);
				return;
			}
			var rows = (r.message.fields || [])
				.map(function (f) {
					return (
						"<li><b>" +
						frappe.utils.escape_html(f.name) +
						"</b> — " +
						frappe.utils.escape_html(f.label || "") +
						(f.required ? ' <span class="text-danger">*</span>' : "") +
						"</li>"
					);
				})
				.join("");
			frm.set_df_property(
				"required_fields_hint",
				"options",
				'<div class="text-muted small">کلیدهای مورد انتظار در «پیکربندی (JSON)»:</div><ul>' + rows + "</ul>"
			);
		},
	});
}
JS

# =============================================================================
step "4) DocTypeهای فرزند — نقش/کاربرِ گیرنده"
mk_dt notification_recipient_role
write_utf8 "${DT}/notification_recipient_role/notification_recipient_role.json" << 'EOF'
{
 "actions": [], "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType",
 "editable_grid": 1, "engine": "InnoDB", "istable": 1,
 "field_order": ["role"],
 "fields": [{"fieldname": "role", "fieldtype": "Link", "in_list_view": 1, "label": "نقش", "options": "Role", "reqd": 1}],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Notify", "name": "Notification Recipient Role", "owner": "Administrator",
 "permissions": [], "sort_field": "modified", "sort_order": "DESC"
}
EOF
write_utf8 "${DT}/notification_recipient_role/notification_recipient_role.py" << 'PYEOF'
# -*- coding: utf-8 -*-
from frappe.model.document import Document


class NotificationRecipientRole(Document):
    pass
PYEOF

mk_dt notification_recipient_user
write_utf8 "${DT}/notification_recipient_user/notification_recipient_user.json" << 'EOF'
{
 "actions": [], "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType",
 "editable_grid": 1, "engine": "InnoDB", "istable": 1,
 "field_order": ["user"],
 "fields": [{"fieldname": "user", "fieldtype": "Link", "in_list_view": 1, "label": "کاربر", "options": "User", "reqd": 1}],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Notify", "name": "Notification Recipient User", "owner": "Administrator",
 "permissions": [], "sort_field": "modified", "sort_order": "DESC"
}
EOF
write_utf8 "${DT}/notification_recipient_user/notification_recipient_user.py" << 'PYEOF'
# -*- coding: utf-8 -*-
from frappe.model.document import Document


class NotificationRecipientUser(Document):
    pass
PYEOF

# =============================================================================
step "5) DocType — رویداد اعلان (قلب تنظیمات UI؛ فقط یک تصمیم واقعی: پیامک)"
mk_dt notification_event
write_utf8 "${DT}/notification_event/notification_event.json" << 'EOF'
{
 "actions": [],
 "allow_rename": 1,
 "autoname": "field:event_key",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "field_order": [
  "sb_id", "event_key", "event_title", "category", "cb_id", "is_active", "is_critical", "cooldown_minutes",
  "sb_channels", "channel_help", "send_sms", "send_email", "cb_channels", "respect_quiet_hours", "allow_user_optout",
  "sb_recipients", "recipient_roles", "recipient_users",
  "cb_recipients", "dynamic_user_field", "dynamic_mobile_field",
  "sb_internal", "internal_subject", "internal_body",
  "sb_sms", "sms_body", "sms_hint",
  "sb_email", "email_subject", "email_body",
  "sb_meta", "is_seed", "allow_seed_overwrite", "cb_meta", "variables_hint", "notes"
 ],
 "fields": [
  {"fieldname": "sb_id", "fieldtype": "Section Break", "label": "شناسهٔ رویداد"},
  {"description": "همین کلید در کد صدا زده می‌شود: notify(\"case.legal_rejected\", ...). فقط حروف کوچک انگلیسی، عدد، نقطه و زیرخط.", "fieldname": "event_key", "fieldtype": "Data", "in_list_view": 1, "in_standard_filter": 1, "label": "کلید رویداد", "reqd": 1, "unique": 1},
  {"fieldname": "event_title", "fieldtype": "Data", "in_list_view": 1, "label": "عنوان رویداد", "reqd": 1},
  {"default": "گردش‌کار", "fieldname": "category", "fieldtype": "Select", "in_standard_filter": 1, "label": "دسته", "options": "گردش‌کار\nمالی\nحمل و ترخیص\nسیستمی\nگزارش", "reqd": 1},
  {"fieldname": "cb_id", "fieldtype": "Column Break"},
  {"default": "1", "fieldname": "is_active", "fieldtype": "Check", "in_list_view": 1, "label": "فعال"},
  {"default": "0", "description": "رویداد حیاتی از ساعات سکوت و بی‌صداکردن کاربر عبور می‌کند (کول‌داون همچنان رعایت می‌شود).", "fieldname": "is_critical", "fieldtype": "Check", "label": "حیاتی"},
  {"description": "صفر یعنی از کول‌داون پیش‌فرض «تنظیمات مرکز اعلان» استفاده شود.", "fieldname": "cooldown_minutes", "fieldtype": "Int", "label": "کول‌داون اختصاصی (دقیقه)"},

  {"fieldname": "sb_channels", "fieldtype": "Section Break", "label": "کانال‌ها — فقط یک تصمیم واقعی"},
  {"fieldname": "channel_help", "fieldtype": "HTML", "options": "<div class='text-muted small'>اعلان داخلی همیشه و رایگان ارسال می‌شود (نیازی به تیک ندارد). فقط دربارهٔ «پیامک» که پولی است تصمیم بگیرید.</div>"},
  {"default": "0", "fieldname": "send_sms", "fieldtype": "Check", "in_list_view": 1, "label": "پیامک هم ارسال شود؟ (پولی)"},
  {"default": "0", "fieldname": "send_email", "fieldtype": "Check", "label": "ایمیل هم ارسال شود؟ (اختیاری)"},
  {"fieldname": "cb_channels", "fieldtype": "Column Break"},
  {"default": "1", "fieldname": "respect_quiet_hours", "fieldtype": "Check", "label": "رعایت ساعات سکوت (فقط پیامک)"},
  {"default": "1", "fieldname": "allow_user_optout", "fieldtype": "Check", "label": "کاربر بتواند این رویداد را برای خودش بی‌صدا کند"},

  {"fieldname": "sb_recipients", "fieldtype": "Section Break", "label": "گیرندگان"},
  {"fieldname": "recipient_roles", "fieldtype": "Table MultiSelect", "label": "نقش‌های گیرنده", "options": "Notification Recipient Role"},
  {"fieldname": "recipient_users", "fieldtype": "Table MultiSelect", "label": "کاربران ثابت گیرنده", "options": "Notification Recipient User"},
  {"fieldname": "cb_recipients", "fieldtype": "Column Break"},
  {"description": "نام فیلدی از سند مرجع که مقدارش «نام کاربری» یک User است — مثل requested_by (مدیرعامل دستوردهنده) یا assigned_user (کارمند مسئول پرونده).", "fieldname": "dynamic_user_field", "fieldtype": "Data", "label": "فیلد کاربر پویا روی سند"},
  {"description": "نام فیلدی از سند مرجع که شمارهٔ موبایل خام دارد — برای گیرندهٔ بدون حساب کاربری (مثل راننده).", "fieldname": "dynamic_mobile_field", "fieldtype": "Data", "label": "فیلد موبایل پویا روی سند"},

  {"fieldname": "sb_internal", "fieldtype": "Section Break", "label": "متن اعلان داخلی"},
  {"fieldname": "internal_subject", "fieldtype": "Data", "label": "عنوان"},
  {"fieldname": "internal_body", "fieldtype": "Small Text", "label": "متن"},

  {"depends_on": "eval:doc.send_sms", "fieldname": "sb_sms", "fieldtype": "Section Break", "label": "متن پیامک"},
  {"description": "متغیرها به شکل {{name}} یا {{reason}} — همهٔ فیلدهای سند مرجع خودکار در دسترس‌اند.", "fieldname": "sms_body", "fieldtype": "Small Text", "label": "متن پیامک"},
  {"fieldname": "sms_hint", "fieldtype": "HTML", "options": "<div class='text-muted small'>هر ۷۰ نویسهٔ فارسی ≈ یک قطعهٔ پیامک. کوتاه‌تر یعنی ارزان‌تر.</div>"},

  {"collapsible": 1, "depends_on": "eval:doc.send_email", "fieldname": "sb_email", "fieldtype": "Section Break", "label": "متن ایمیل"},
  {"fieldname": "email_subject", "fieldtype": "Data", "label": "موضوع ایمیل"},
  {"fieldname": "email_body", "fieldtype": "Text Editor", "label": "متن ایمیل"},

  {"collapsible": 1, "fieldname": "sb_meta", "fieldtype": "Section Break", "label": "اطلاعات فنی"},
  {"default": "0", "fieldname": "is_seed", "fieldtype": "Check", "label": "ساخته‌شده توسط نصب‌کننده", "read_only": 1},
  {"default": "1", "description": "اگر خاموش شود، اجرای دوبارهٔ نصب‌کننده متن/تنظیمات شما را بازنویسی نمی‌کند.", "fieldname": "allow_seed_overwrite", "fieldtype": "Check", "label": "اجازهٔ بازنویسی توسط نصب‌کننده"},
  {"fieldname": "cb_meta", "fieldtype": "Column Break"},
  {"fieldname": "variables_hint", "fieldtype": "Small Text", "label": "متغیرهای متداول", "read_only": 1},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "یادداشت"}
 ],
 "links": [],
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Iran Notify",
 "name": "Notification Event",
 "naming_rule": "By fieldname",
 "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "email": 1, "export": 1, "print": 1, "read": 1, "report": 1, "role": "System Manager", "share": 1, "write": 1},
  {"create": 1, "email": 1, "export": 1, "print": 1, "read": 1, "report": 1, "role": "Notification Manager", "write": 1}
 ],
 "sort_field": "modified",
 "sort_order": "DESC",
 "title_field": "event_title",
 "track_changes": 1
}
EOF
write_utf8 "${DT}/notification_event/notification_event.py" << 'PYEOF'
# -*- coding: utf-8 -*-
import re

import frappe
from frappe import _
from frappe.model.document import Document

_KEY_RE = re.compile(r"^[a-z0-9_]+(\.[a-z0-9_]+)*$")
_BLOCKED_USERS = {"Administrator", "Guest"}

VARIABLES_HINT = (
    "{{name}} شناسهٔ سند | {{doctype}} نوع سند | {{reason}} دلیل | "
    "{{today}} امروز | {{doc_url}} لینک سند | و هر فیلد دیگر سند مرجع با نام خودش"
)


class NotificationEvent(Document):
    def validate(self):
        self.event_key = (self.event_key or "").strip()
        if not _KEY_RE.match(self.event_key or ""):
            frappe.throw(_("کلید رویداد فقط می‌تواند شامل حروف کوچک انگلیسی، عدد، زیرخط و نقطه باشد. مثال: case.legal_rejected"))

        if self.cooldown_minutes is not None and int(self.cooldown_minutes) < 0:
            frappe.throw(_("کول‌داون نمی‌تواند منفی باشد."))

        if self.send_sms and not (self.sms_body or "").strip():
            frappe.throw(_("«ارسال پیامک» فعال است ولی «متن پیامک» خالی است."))

        if self.send_email and not (self.email_body or "").strip():
            frappe.throw(_("«ارسال ایمیل» فعال است ولی «متن ایمیل» خالی است."))

        if not (self.internal_body or "").strip():
            self.internal_body = self.event_title

        if not self._has_any_recipient_source():
            frappe.throw(
                _(
                    "هیچ منبع گیرنده‌ای مشخص نشده است. حداقل یکی از موارد زیر را تعیین کنید: "
                    "نقش گیرنده، کاربر ثابت، فیلد کاربر پویا یا فیلد موبایل پویا."
                )
            )

        for row in (self.recipient_users or []):
            if row.user in _BLOCKED_USERS:
                frappe.throw(_("مدیر سامانه (Administrator) یا کاربر مهمان (Guest) نمی‌تواند گیرندهٔ اعلان باشد."))

        self.variables_hint = VARIABLES_HINT

    def _has_any_recipient_source(self):
        return bool(
            (self.recipient_roles or [])
            or (self.recipient_users or [])
            or (self.dynamic_user_field or "").strip()
            or (self.dynamic_mobile_field or "").strip()
        )

    def on_update(self):
        frappe.cache().delete_value("iran_notify_event::" + self.name)
PYEOF

write_utf8 "${PKG}/public/js/notification_event.js" << 'JS'
frappe.listview_settings["Notification Event"] = {
	add_fields: ["is_active", "send_sms", "is_critical"],
	get_indicator: function (doc) {
		if (!doc.is_active) return [__("غیرفعال"), "gray", "is_active,=,0"];
		if (doc.send_sms) return [__("داخلی + پیامک"), "orange", "send_sms,=,1"];
		return [__("فقط داخلی (رایگان)"), "green", "send_sms,=,0"];
	},
};

frappe.ui.form.on("Notification Event", {
	refresh: function (frm) {
		if (!frm.doc.__islocal) {
			frm.add_custom_button(__("ارسال آزمایشی برای من"), function () {
				frappe.call({
					method: "iran_notify.api.send_test_to_me",
					args: { event_key: frm.doc.event_key },
					callback: function (r) {
						if (r.message) frappe.msgprint(JSON.stringify(r.message, null, 2));
					},
				});
			});
		}
	},
	sms_body: function (frm) {
		var len = (frm.doc.sms_body || "").length;
		var parts = Math.max(1, Math.ceil(len / 70));
		frm.set_intro(
			len ? __("طول متن: {0} نویسه ≈ {1} قطعهٔ پیامک", [len, parts]) : "",
			"blue"
		);
	},
});
JS

# =============================================================================
step "6) DocType — دفتر ارسال اعلان (با نمایهٔ یکتای واقعی برای دِدوپ)"
mk_dt notification_dispatch_log
write_utf8 "${DT}/notification_dispatch_log/notification_dispatch_log.json" << 'EOF'
{
 "actions": [],
 "autoname": "hash",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "field_order": [
  "event_key", "event_title", "channel", "dispatch_status", "cb1",
  "recipient_user", "recipient_address", "reference_doctype", "reference_name",
  "sb2", "message_subject", "message_body", "sms_parts", "decision_reason",
  "sb3", "dedup_key", "provider_message_id", "error_detail"
 ],
 "fields": [
  {"fieldname": "event_key", "fieldtype": "Data", "in_list_view": 1, "in_standard_filter": 1, "label": "کلید رویداد", "read_only": 1},
  {"fieldname": "event_title", "fieldtype": "Data", "label": "عنوان رویداد", "read_only": 1},
  {"fieldname": "channel", "fieldtype": "Select", "in_list_view": 1, "in_standard_filter": 1, "label": "کانال", "options": "Internal\nSMS\nEmail", "read_only": 1},
  {"fieldname": "dispatch_status", "fieldtype": "Select", "in_list_view": 1, "in_standard_filter": 1, "label": "وضعیت", "options": "Queued\nSent\nFailed\nBlocked - Master Off\nBlocked - SMS Off\nBlocked - Muted\nBlocked - Quiet Hours\nBlocked - No Address\nSkipped - Duplicate", "read_only": 1},
  {"fieldname": "cb1", "fieldtype": "Column Break"},
  {"fieldname": "recipient_user", "fieldtype": "Link", "in_list_view": 1, "label": "کاربر گیرنده", "options": "User", "read_only": 1},
  {"fieldname": "recipient_address", "fieldtype": "Data", "label": "نشانی گیرنده", "read_only": 1},
  {"fieldname": "reference_doctype", "fieldtype": "Data", "in_standard_filter": 1, "label": "نوع سند مرجع", "read_only": 1},
  {"fieldname": "reference_name", "fieldtype": "Data", "in_list_view": 1, "label": "سند مرجع", "read_only": 1},
  {"fieldname": "sb2", "fieldtype": "Section Break"},
  {"fieldname": "message_subject", "fieldtype": "Data", "label": "عنوان پیام", "read_only": 1},
  {"fieldname": "message_body", "fieldtype": "Small Text", "label": "متن پیام", "read_only": 1},
  {"default": "0", "fieldname": "sms_parts", "fieldtype": "Int", "label": "تعداد قطعهٔ پیامک", "read_only": 1},
  {"fieldname": "decision_reason", "fieldtype": "Small Text", "label": "دلیل تصمیم", "read_only": 1},
  {"fieldname": "sb3", "fieldtype": "Section Break", "collapsible": 1, "label": "اطلاعات فنی"},
  {"fieldname": "dedup_key", "fieldtype": "Data", "label": "کلید یکتای دِدوپ", "read_only": 1, "unique": 1},
  {"fieldname": "provider_message_id", "fieldtype": "Data", "label": "شناسهٔ پیام درگاه", "read_only": 1},
  {"fieldname": "error_detail", "fieldtype": "Small Text", "label": "جزئیات خطا", "read_only": 1}
 ],
 "links": [],
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Iran Notify",
 "name": "Notification Dispatch Log",
 "owner": "Administrator",
 "permissions": [
  {"read": 1, "report": 1, "export": 1, "role": "System Manager"},
  {"read": 1, "report": 1, "export": 1, "role": "Notification Manager"}
 ],
 "sort_field": "creation",
 "sort_order": "DESC"
}
EOF
write_utf8 "${DT}/notification_dispatch_log/notification_dispatch_log.py" << 'PYEOF'
# -*- coding: utf-8 -*-
from frappe.model.document import Document


class NotificationDispatchLog(Document):
    pass
PYEOF
write_utf8 "${DT}/notification_dispatch_log/notification_dispatch_log_list.js" << 'JS'
frappe.listview_settings["Notification Dispatch Log"] = {
	get_indicator: function (doc) {
		var map = {
			Sent: "green",
			Queued: "blue",
			Failed: "red",
			"Skipped - Duplicate": "gray",
		};
		var color = map[doc.dispatch_status] || "orange";
		return [__(doc.dispatch_status), color, "dispatch_status,=," + doc.dispatch_status];
	},
};
JS

# =============================================================================
step "7) DocType — ترجیح اعلان کاربر (انصراف خودخواسته)"
mk_dt notification_user_preference
write_utf8 "${DT}/notification_user_preference/notification_user_preference.json" << 'EOF'
{
 "actions": [],
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "field_order": ["user", "event_key", "cb", "mute_internal", "mute_sms", "custom_mobile"],
 "fields": [
  {"fieldname": "user", "fieldtype": "Link", "in_list_view": 1, "label": "کاربر", "options": "User", "reqd": 1},
  {"fieldname": "event_key", "fieldtype": "Data", "in_list_view": 1, "label": "کلید رویداد", "reqd": 1},
  {"fieldname": "cb", "fieldtype": "Column Break"},
  {"default": "0", "fieldname": "mute_internal", "fieldtype": "Check", "label": "اعلان داخلی این رویداد بی‌صدا شود"},
  {"default": "0", "fieldname": "mute_sms", "fieldtype": "Check", "label": "پیامک این رویداد بی‌صدا شود"},
  {"fieldname": "custom_mobile", "fieldtype": "Data", "label": "شمارهٔ موبایل جایگزین برای این رویداد"}
 ],
 "links": [],
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Iran Notify",
 "name": "Notification User Preference",
 "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "read": 1, "role": "System Manager", "write": 1},
  {"create": 1, "delete": 1, "read": 1, "role": "Notification Manager", "write": 1},
  {"create": 1, "delete": 1, "if_owner": 1, "read": 1, "role": "All", "write": 1}
 ],
 "sort_field": "modified",
 "sort_order": "DESC"
}
EOF
write_utf8 "${DT}/notification_user_preference/notification_user_preference.py" << 'PYEOF'
# -*- coding: utf-8 -*-
import frappe
from frappe import _
from frappe.model.document import Document


class NotificationUserPreference(Document):
    def validate(self):
        current_user = frappe.session.user
        roles = set(frappe.get_roles(current_user))
        is_manager = bool(roles & {"System Manager", "Notification Manager"}) or current_user == "Administrator"

        if not is_manager:
            # کاربر عادی فقط برای خودش — و مالک سند نیز باید خودش باشد
            self.user = current_user
            if self.user != current_user:
                frappe.throw(_("هر کاربر فقط می‌تواند ترجیحات اعلان حساب کاربری خودش را تغییر دهد."))

        if not self.user:
            frappe.throw(_("کاربر الزامی است."))

        if self.user in {"Guest"}:
            frappe.throw(_("برای کاربر مهمان نمی‌توان ترجیح اعلان ثبت کرد."))

        dup = frappe.db.exists(
            "Notification User Preference",
            {
                "user": self.user,
                "event_key": self.event_key,
                "name": ["!=", self.name or ""],
            },
        )
        if dup:
            frappe.throw(_("برای این کاربر و این رویداد قبلاً یک ترجیح ثبت شده است."))

    def before_insert(self):
        current_user = frappe.session.user
        roles = set(frappe.get_roles(current_user))
        is_manager = bool(roles & {"System Manager", "Notification Manager"}) or current_user == "Administrator"
        if not is_manager:
            self.user = current_user
            # if_owner روی owner کار می‌کند؛ owner را با user هم‌تراز نگه می‌داریم
            self.owner = current_user
PYEOF

write_utf8 "${PKG}/public/js/notification_user_preference.js" << 'JS'
frappe.ui.form.on("Notification User Preference", {
	onload: function (frm) {
		var is_manager =
			frappe.user.has_role("System Manager") || frappe.user.has_role("Notification Manager");
		if (!is_manager) {
			if (frm.is_new() || !frm.doc.user) {
				frm.set_value("user", frappe.session.user);
			}
			frm.set_df_property("user", "read_only", 1);
		}
	},
	refresh: function (frm) {
		var is_manager =
			frappe.user.has_role("System Manager") || frappe.user.has_role("Notification Manager");
		if (!is_manager) {
			frm.set_df_property("user", "read_only", 1);
		}
	},
});
JS

write_utf8 "${PKG}/public/js/notification_user_preference_list.js" << 'JS'
frappe.listview_settings["Notification User Preference"] = {
	onload: function (listview) {
		var is_manager =
			frappe.user.has_role("System Manager") || frappe.user.has_role("Notification Manager");
		if (!is_manager) {
			listview.filter_area.clear();
			listview.filter_area.add([
				[listview.doctype, "user", "=", frappe.session.user],
			]);
		}
	},
};
JS

write_utf8 "${PKG}/public/js/notification_log_list.js" << 'JS'
frappe.listview_settings["Notification Log"] = frappe.listview_settings["Notification Log"] || {};

(function () {
	var prev_onload = frappe.listview_settings["Notification Log"].onload;
	frappe.listview_settings["Notification Log"].onload = function (listview) {
		if (prev_onload) prev_onload(listview);
		if (frappe.session.user === "Guest") return;

		listview.page.add_inner_button(__("پاک‌سازی اعلان‌های خوانده‌شدهٔ من"), function () {
			frappe.confirm(
				__("آیا از حذف اعلان‌های خوانده‌شدهٔ خودتان از دیتابیس مطمئن هستید؟ (اعلان‌های بسیار تازه حذف نمی‌شوند)"),
				function () {
					frappe.call({
						method: "iran_notify.api.purge_my_notifications",
						args: { only_read: 1, older_than_minutes: 5 },
						freeze: true,
						callback: function (r) {
							var deleted = (r.message && r.message.deleted) || 0;
							frappe.show_alert({
								message: __("تعداد {0} اعلان خوانده‌شده پاک شد", [deleted]),
								indicator: "green",
							});
							listview.refresh();
						},
					});
				}
			);
		});
	};
})();
JS

# =============================================================================
step "8) هستهٔ پایتون — تنظیمات/رندر/گیرنده/سیاست/دِدوپ/ساعات سکوت"
write_utf8 "${PKG}/utils.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""ابزارهای عمومی و بی‌طرف iran_notify. هرگز چیزی را بی‌صدا رد نمی‌کند."""
import frappe


def log_config_error(title, message):
    try:
        frappe.log_error(title="[iran_notify] " + title, message=message)
    except Exception:
        pass


def sms_part_count(text):
    text = text or ""
    if not text:
        return 0
    is_ascii = all(ord(ch) < 128 for ch in text)
    unit = 160 if is_ascii else 70
    return max(1, -(-len(text) // unit))  # ceil division بدون import اضافه
PYEOF

write_utf8 "${PKG}/notification/settings.py" << 'PYEOF'
# -*- coding: utf-8 -*-
import frappe


def hub():
    return frappe.get_cached_doc("Notify Settings")
PYEOF

write_utf8 "${PKG}/notification/renderer.py" << 'PYEOF'
# -*- coding: utf-8 -*-
import re

import frappe

_VAR_RE = re.compile(r"\{\{\s*([a-zA-Z0-9_]+)\s*\}\}")


def build_context(ref_doc, extra=None):
    ctx = {}
    if ref_doc is not None:
        try:
            for key, value in ref_doc.as_dict().items():
                if isinstance(value, (list, dict)):
                    continue
                ctx[key] = value
        except Exception:
            pass
        ctx.setdefault("name", getattr(ref_doc, "name", ""))
        ctx.setdefault("doctype", getattr(ref_doc, "doctype", ""))
        try:
            ctx["doc_url"] = frappe.utils.get_url_to_form(ref_doc.doctype, ref_doc.name)
        except Exception:
            ctx["doc_url"] = ""

    ctx.setdefault("today", frappe.utils.formatdate(frappe.utils.today()))
    if extra:
        ctx.update(extra)
    return ctx


def render(template, ctx):
    if not template:
        return ""

    def _sub(match):
        key = match.group(1)
        value = ctx.get(key)
        return "" if value is None else frappe.utils.cstr(value)

    return _VAR_RE.sub(_sub, template)
PYEOF

write_utf8 "${PKG}/notification/recipients.py" << 'PYEOF'
# -*- coding: utf-8 -*-
import frappe

_BLOCKED_USERS = {"Administrator", "Guest"}


def _user_row(user, source, mobile=None):
    if not user or user in _BLOCKED_USERS:
        return None
    info = frappe.db.get_value("User", user, ["mobile_no", "email", "enabled"], as_dict=True)
    if not info or not info.enabled:
        return None
    return {
        "user": user,
        "mobile": mobile or info.mobile_no,
        "email": info.email,
        "name": frappe.utils.get_fullname(user),
        "source": source,
    }


def resolve(event, ref_doc, context=None):
    """رویداد + سند مرجع → فهرست گیرندگان یکتا. هرگز Administrator/Guest برنمی‌گرداند.

    context اختیاری است تا فیلدهای پویا (مثل triggered_by) وقتی سند مرجع
    در کار نیست هم از context خوانده شوند.
    """
    targets = {}
    notes = []
    context = context or {}

    for row in (event.get("recipient_roles") or []):
        role = row.get("role") if isinstance(row, dict) else row.role
        if not role:
            continue
        users = frappe.get_all(
            "Has Role",
            filters={"role": role, "parenttype": "User"},
            pluck="parent",
        )
        for u in users:
            r = _user_row(u, "role:" + role)
            if r:
                targets[r["user"]] = r
        if not users:
            notes.append("نقش «{0}» هیچ کاربری ندارد".format(role))

    for row in (event.get("recipient_users") or []):
        user = row.get("user") if isinstance(row, dict) else row.user
        r = _user_row(user, "fixed_user")
        if r:
            targets[r["user"]] = r

    dyn_user_field = event.get("dynamic_user_field")
    if dyn_user_field:
        value = None
        if ref_doc is not None:
            value = getattr(ref_doc, dyn_user_field, None)
        if not value:
            value = context.get(dyn_user_field)
        if value:
            r = _user_row(value, "dynamic_field:" + dyn_user_field)
            if r:
                targets[r["user"]] = r
            else:
                notes.append("فیلد «{0}» کاربر معتبر/فعال نداشت".format(dyn_user_field))
        else:
            notes.append("فیلد «{0}» روی سند/context خالی بود".format(dyn_user_field))

    dyn_mobile_field = event.get("dynamic_mobile_field")
    if dyn_mobile_field:
        mobile = None
        if ref_doc is not None:
            mobile = getattr(ref_doc, dyn_mobile_field, None)
        if not mobile:
            mobile = context.get(dyn_mobile_field)
        if mobile:
            key = "mobile:" + mobile
            targets[key] = {
                "user": None,
                "mobile": mobile,
                "email": None,
                "name": mobile,
                "source": "dynamic_mobile:" + dyn_mobile_field,
            }

    return list(targets.values()), notes
PYEOF

write_utf8 "${PKG}/notification/policy.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""تصمیم اینکه کدام کانال‌ها برای یک رویداد فعال‌اند.

اعلان داخلی همیشه فعال است (رایگان)؛ پیامک/ایمیل فقط با تیک آگاهانهٔ
«رویداد اعلان» + کلید سراسری. این دقیقاً تصمیم انسانیِ ساده‌ای است که
کارفرما خواسته: هر رویداد یک checkbox واقعی دارد، نه چهار تا.

SMS همیشه وقتی send_sms روشن است وارد channels می‌شود تا core بتواند
Blocked - SMS Off را در دفتر ارسال ثبت کند؛ ارسال واقعی همچنان فقط با
Kill-Switch یا حالت آزمایشی انجام می‌شود.
"""
from .settings import hub


def decide(event):
    channels = ["Internal"]  # رایگان و همیشه روشن — هیچ کلیدی آن را خاموش نمی‌کند
    reasons = []

    settings = hub()
    if event.get("send_sms"):
        channels.append("SMS")
        if not settings.sms_master_enabled and not settings.test_mode:
            reasons.append("پیامک این رویداد روشن است ولی Kill-Switch پیامک در تنظیمات خاموش است")
        elif not settings.sms_master_enabled and settings.test_mode:
            reasons.append("Kill-Switch پیامک خاموش است؛ فقط حالت آزمایشی فعال است")

    if event.get("send_email"):
        channels.append("Email")

    return channels, reasons
PYEOF

write_utf8 "${PKG}/notification/dedup.py" << 'PYEOF'
# -*- coding: utf-8 -*-
import hashlib
import time


def make_key(event_key, doctype, name, address, channel, cooldown_minutes):
    """کلید یکتا برای یک بازهٔ کول‌داون. تکرار در همان بازه به همان کلید می‌رسد
    و با نمایهٔ یکتای دیتابیس (unique=1 روی dedup_key) مسدود می‌شود."""
    cooldown_minutes = max(1, int(cooldown_minutes or 1))
    bucket = int(time.time() // (cooldown_minutes * 60))
    raw = "|".join([
        str(event_key), str(doctype or ""), str(name or ""),
        str(address or ""), str(channel or ""), str(bucket),
    ])
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()
PYEOF

write_utf8 "${PKG}/notification/quiet_hours.py" << 'PYEOF'
# -*- coding: utf-8 -*-
import datetime

import frappe


def is_quiet_now(settings):
    if not settings.quiet_hours_enabled:
        return False
    try:
        now = frappe.utils.now_datetime().time()
        start = frappe.utils.get_time(settings.quiet_hours_start or "22:00:00")
        end = frappe.utils.get_time(settings.quiet_hours_end or "07:00:00")
    except Exception:
        return False

    if start == end:
        return False
    if start < end:
        return start <= now < end
    return now >= start or now < end  # بازهٔ شبانه که از نیمه‌شب رد می‌شود
PYEOF

# =============================================================================
step "9) لایهٔ آداپتور پیامک (Plugin Architecture با Registry)"
write_utf8 "${PKG}/sms/base_adapter.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""کلاس پایهٔ هر آداپتور پیامک. هر آداپتور جدید فقط باید این را ارث‌بری کند
و در registry.py ثبت شود؛ هیچ‌جای دیگر کد لازم نیست تغییر کند."""


class BaseSMSAdapter:
    key = "base"
    label = "پایه"

    def __init__(self, config):
        self.config = config or {}

    @classmethod
    def required_fields(cls):
        """فهرست فیلدهای لازم برای config_json. هر آیتم: {name, label, required}."""
        return []

    def send(self, mobile, text):
        """باید dict برگرداند: {"ok": bool, "provider_message_id": str|None, "error": str|None}"""
        raise NotImplementedError
PYEOF

write_utf8 "${PKG}/sms/registry.py" << 'PYEOF'
# -*- coding: utf-8 -*-
_REGISTRY = {}


def register(adapter_cls):
    _REGISTRY[adapter_cls.key] = adapter_cls
    return adapter_cls


def get_adapter(key):
    return _REGISTRY.get(key)


def list_adapters():
    return [{"key": k, "label": v.label} for k, v in _REGISTRY.items()]


def _bootstrap():
    from iran_notify.sms.adapters import console_debug, generic_http, kavenegar  # noqa: F401


_bootstrap()
PYEOF

write_utf8 "${PKG}/sms/adapters/console_debug.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""آداپتور توسعه/تست — هیچ درخواست شبکه‌ای نمی‌زند. پیش‌فرض امن برای سایت‌های تازه."""
import frappe

from iran_notify.sms.base_adapter import BaseSMSAdapter
from iran_notify.sms.registry import register


@register
class ConsoleDebugAdapter(BaseSMSAdapter):
    key = "console_debug"
    label = "کنسول توسعه (بدون ارسال واقعی)"

    @classmethod
    def required_fields(cls):
        return []

    def send(self, mobile, text):
        frappe.logger("iran_notify").info("[console_debug SMS] to=%s text=%s", mobile, text)
        return {"ok": True, "provider_message_id": "debug-local", "error": None}
PYEOF

write_utf8 "${PKG}/sms/adapters/generic_http.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""آداپتور عمومی برای هر درگاه REST که با GET/POST ساده کار می‌کند.
اگر درگاه شما آداپتور اختصاصی ندارد، از همین با config_json مناسب استفاده کنید."""
import requests

from iran_notify.sms.base_adapter import BaseSMSAdapter
from iran_notify.sms.registry import register


@register
class GenericHTTPAdapter(BaseSMSAdapter):
    key = "generic_http"
    label = "درگاه عمومی HTTP"

    @classmethod
    def required_fields(cls):
        return [
            {"name": "url", "label": "آدرس سرویس", "required": True},
            {"name": "method", "label": "GET یا POST (پیش‌فرض POST)", "required": False},
            {"name": "mobile_param", "label": "نام پارامتر شماره موبایل", "required": True},
            {"name": "text_param", "label": "نام پارامتر متن پیام", "required": True},
            {"name": "extra_params", "label": "پارامترهای ثابت اضافه (شیء JSON)", "required": False},
            {"name": "headers", "label": "هدرهای HTTP (شیء JSON)", "required": False},
            {"name": "timeout", "label": "Timeout به ثانیه (پیش‌فرض ۱۰)", "required": False},
        ]

    def send(self, mobile, text):
        url = self.config.get("url")
        if not url:
            return {"ok": False, "provider_message_id": None, "error": "آدرس سرویس تنظیم نشده است."}

        method = (self.config.get("method") or "POST").upper()
        payload = dict(self.config.get("extra_params") or {})
        payload[self.config.get("mobile_param") or "mobile"] = mobile
        payload[self.config.get("text_param") or "text"] = text
        headers = self.config.get("headers") or {}
        timeout = float(self.config.get("timeout") or 10)

        try:
            if method == "GET":
                resp = requests.get(url, params=payload, headers=headers, timeout=timeout)
            else:
                resp = requests.post(url, json=payload, headers=headers, timeout=timeout)
            resp.raise_for_status()
            return {"ok": True, "provider_message_id": None, "error": None}
        except Exception as exc:
            return {"ok": False, "provider_message_id": None, "error": str(exc)}
PYEOF

write_utf8 "${PKG}/sms/adapters/kavenegar.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""نمونه آداپتور اختصاصی برای یک درگاه محبوب ایرانی (Kavenegar-style REST API).
پیش از استفادهٔ واقعی، آدرس/پارامترها را با مستندات به‌روز درگاه خودتان تطبیق دهید."""
import requests

from iran_notify.sms.base_adapter import BaseSMSAdapter
from iran_notify.sms.registry import register


@register
class KavenegarAdapter(BaseSMSAdapter):
    key = "kavenegar"
    label = "Kavenegar (نمونه)"

    @classmethod
    def required_fields(cls):
        return [
            {"name": "api_key", "label": "کلید API", "required": True},
            {"name": "sender_id", "label": "شمارهٔ فرستنده", "required": False},
        ]

    def send(self, mobile, text):
        api_key = self.config.get("api_key")
        if not api_key:
            return {"ok": False, "provider_message_id": None, "error": "کلید API تنظیم نشده است."}

        url = "https://api.kavenegar.com/v1/{0}/sms/send.json".format(api_key)
        payload = {"receptor": mobile, "message": text}
        if self.config.get("sender_id"):
            payload["sender"] = self.config["sender_id"]

        try:
            resp = requests.post(url, data=payload, timeout=10)
            data = resp.json() if resp.content else {}
            ok = resp.status_code < 400
            mid = None
            try:
                mid = str(data["entries"][0]["messageid"])
            except Exception:
                mid = None
            return {"ok": ok, "provider_message_id": mid, "error": None if ok else str(data)}
        except Exception as exc:
            return {"ok": False, "provider_message_id": None, "error": str(exc)}
PYEOF

# =============================================================================
step "10) کانال‌های تحویل (Internal با Notification Log خود Frappe / SMS / Email)"
write_utf8 "${PKG}/channels/internal_channel.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""اعلان داخلی — رایگان. از DocType داخلی «Notification Log» خود Frappe
استفاده می‌شود تا زنگولهٔ استاندارد Desk کار کند؛ چرخ دوباره ساخته نمی‌شود."""
import frappe


def deliver(log):
    if not log.recipient_user:
        return False, "اعلان داخلی بدون کاربر ممکن نیست.", None
    try:
        note = frappe.new_doc("Notification Log")
        note.subject = log.message_subject or log.event_title or log.event_key
        note.email_content = log.message_body or note.subject
        note.for_user = log.recipient_user
        note.type = "Alert"
        if log.reference_doctype and frappe.db.exists("DocType", log.reference_doctype):
            note.document_type = log.reference_doctype
            note.document_name = log.reference_name
        note.flags.ignore_permissions = True
        note.insert(ignore_permissions=True)
        return True, "اعلان داخلی ثبت شد.", note.name
    except Exception:
        frappe.log_error(title="[iran_notify] ثبت اعلان داخلی ناموفق بود", message=frappe.get_traceback())
        return False, "ثبت اعلان داخلی ناموفق بود.", None
PYEOF

write_utf8 "${PKG}/channels/sms_channel.py" << 'PYEOF'
# -*- coding: utf-8 -*-
import frappe

from iran_notify.notification.settings import hub
from iran_notify.sms.registry import get_adapter


def deliver(log):
    if not log.recipient_address:
        return False, "شمارهٔ موبایل موجود نیست.", None

    settings = hub()
    mobile = log.recipient_address
    if settings.test_mode:
        # در حالت آزمایشی هیچ درخواست شبکه‌ای زده نمی‌شود؛ فقط ثبت می‌شود.
        target = settings.test_mobile or mobile
        frappe.logger("iran_notify").info(
            "[TEST MODE] SMS شبیه‌سازی شد به %s (اصل: %s): %s", target, mobile, log.message_body
        )
        return True, "حالت آزمایشی: پیامک واقعی ارسال نشد.", "test-mode"

    profile_name = settings.default_sms_gateway
    if not profile_name:
        return False, "درگاه پیامک پیش‌فرض تنظیم نشده است.", None

    profile = frappe.get_cached_doc("SMS Gateway Profile", profile_name)
    if not profile.is_enabled:
        return False, "درگاه پیامک پیش‌فرض غیرفعال است.", None

    adapter_cls = get_adapter(profile.adapter_key)
    if not adapter_cls:
        return False, "آداپتور «{0}» یافت نشد.".format(profile.adapter_key), None

    import json

    config = json.loads(profile.config_json or "{}")
    adapter = adapter_cls(config)
    try:
        result = adapter.send(mobile, log.message_body or "") or {}
    except Exception as exc:
        frappe.log_error(title="[iran_notify] خطای آداپتور پیامک", message=frappe.get_traceback())
        return False, str(exc), None

    if result.get("ok"):
        return True, "ارسال شد.", result.get("provider_message_id")
    return False, result.get("error") or "ارسال ناموفق بود.", None
PYEOF

write_utf8 "${PKG}/channels/email_channel.py" << 'PYEOF'
# -*- coding: utf-8 -*-
import frappe


def deliver(log):
    if not log.recipient_address:
        return False, "ایمیل گیرنده موجود نیست.", None
    try:
        frappe.sendmail(
            recipients=[log.recipient_address],
            subject=log.message_subject or log.event_title or log.event_key,
            message=log.message_body or "",
            now=True,
        )
        return True, "ایمیل صف شد.", None
    except Exception:
        frappe.log_error(title="[iran_notify] ارسال ایمیل ناموفق بود", message=frappe.get_traceback())
        return False, "ارسال ایمیل ناموفق بود.", None
PYEOF

write_utf8 "${PKG}/channels/dispatcher.py" << 'PYEOF'
# -*- coding: utf-8 -*-
import frappe

from . import email_channel, internal_channel, sms_channel

_HANDLERS = {"Internal": internal_channel, "SMS": sms_channel, "Email": email_channel}


def deliver_log(log_name):
    log = frappe.get_doc("Notification Dispatch Log", log_name)
    handler = _HANDLERS.get(log.channel)
    if not handler:
        frappe.db.set_value(log.doctype, log.name, {
            "dispatch_status": "Failed",
            "error_detail": "کانال ناشناخته: {0}".format(log.channel),
        })
        return {"ok": False}

    try:
        ok, detail, provider_id = handler.deliver(log)
    except Exception:
        frappe.log_error(title="[iran_notify] خطای پیش‌بینی‌نشده در تحویل", message=frappe.get_traceback())
        ok, detail, provider_id = False, "خطای داخلی هنگام تحویل.", None

    frappe.db.set_value(log.doctype, log.name, {
        "dispatch_status": "Sent" if ok else "Failed",
        "provider_message_id": provider_id,
        "error_detail": "" if ok else detail,
    })
    return {"ok": ok, "detail": detail}
PYEOF

# =============================================================================
step "11) ★ تابع واحد notify() — نقطهٔ ورود همهٔ فازهای بعدی"
write_utf8 "${PKG}/notification/core.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""تابع واحد و عمومی اعلان — قلب اپ iran_notify.

    from iran_notify import notify
    notify("case.legal_rejected", "Trade Case", doc.name, {"reason": "مدارک ناقص است"})

تضمین‌ها (نباید هرگز نقض شوند):
  * هرگز استثنا پرتاب نمی‌کند.
  * هرگز سند مرجع را ذخیره/بازخوانی نمی‌کند.
  * Administrator/Guest هرگز گیرنده نمی‌شوند.
  * نبود رویداد/گیرنده = ثبت روشن در دفتر خطا، هرگز سکوت.
  * تکرار در یک بازهٔ کول‌داون با نمایهٔ یکتای دیتابیس (dedup_key) کنترل می‌شود.
"""
import json

import frappe

from ..utils import log_config_error, sms_part_count
from . import dedup, policy, quiet_hours
from . import recipients as recipients_mod
from . import renderer
from .settings import hub

_BLOCKED_USERS = {"Administrator", "Guest"}


def _get_event(event_key):
    if not event_key or not frappe.db.exists("Notification Event", event_key):
        return None
    doc = frappe.get_cached_doc("Notification Event", event_key)
    data = doc.as_dict()
    data["recipient_roles"] = [{"role": r.role} for r in (doc.recipient_roles or [])]
    data["recipient_users"] = [{"user": u.user} for u in (doc.recipient_users or [])]
    return data


def _load_doc(doctype, name, doc=None):
    if doc is not None:
        return doc
    if not doctype or not name:
        return None
    try:
        if not frappe.db.exists("DocType", doctype) or not frappe.db.exists(doctype, name):
            return None
        return frappe.get_doc(doctype, name)
    except Exception:
        return None


def _preference(user, event_key):
    if not user:
        return None
    try:
        return frappe.db.get_value(
            "Notification User Preference",
            {"user": user, "event_key": event_key},
            ["mute_internal", "mute_sms", "custom_mobile"],
            as_dict=True,
        )
    except Exception:
        return None


def _reserve(values):
    try:
        log = frappe.new_doc("Notification Dispatch Log")
        log.update(values)
        log.flags.ignore_permissions = True
        log.insert(ignore_permissions=True)
        return log
    except (frappe.exceptions.DuplicateEntryError, frappe.UniqueValidationError):
        return None
    except Exception as exc:
        if "Duplicate entry" in frappe.utils.cstr(exc) or "1062" in frappe.utils.cstr(exc):
            return None
        log_config_error("درج دفتر ارسال اعلان ناموفق بود", frappe.get_traceback())
        return None


def _write_blocked(values, status, reason):
    payload = dict(values)
    payload["dispatch_status"] = status
    payload["decision_reason"] = frappe.utils.cstr(reason)[:250]
    _reserve(payload)


def notify(event_key, doctype=None, name=None, context=None, doc=None):
    """رابط عمومی و ایمن. هرگز استثنا پرتاب نمی‌کند."""
    try:
        return _notify(event_key, doctype, name, context, doc)
    except Exception:
        log_config_error("اجرای notify() با خطا مواجه شد: {0}".format(event_key), frappe.get_traceback())
        return {"sent": 0, "reason": "exception", "event": event_key}


def _notify(event_key, doctype, name, context, doc):
    if isinstance(context, str):
        try:
            context = json.loads(context or "{}")
        except Exception:
            context = {}

    event = _get_event(event_key)
    if not event:
        log_config_error(
            "رویداد اعلان تعریف نشده است: {0}".format(event_key),
            "کلید رویداد «{0}» در «رویداد اعلان» وجود ندارد. سند مرجع: {1} / {2}\n"
            "برای رفع: یک «رویداد اعلان» با همین کلید بسازید.".format(event_key, doctype, name),
        )
        return {"sent": 0, "reason": "no_event", "event": event_key}

    if not frappe.utils.cint(event.get("is_active")):
        return {"sent": 0, "reason": "event_inactive", "event": event_key}

    settings = hub()
    ref_doc = _load_doc(doctype, name, doc)
    if ref_doc is not None and not doctype:
        doctype, name = ref_doc.doctype, ref_doc.name

    ctx = renderer.build_context(ref_doc, context)
    ctx.setdefault("event_title", event.get("event_title"))

    channels, reasons = policy.decide(event)
    targets, notes = recipients_mod.resolve(event, ref_doc, ctx)
    if not targets:
        log_config_error(
            "گیرنده‌ای برای اعلان یافت نشد: {0}".format(event_key),
            "رویداد «{0}» هیچ گیرندهٔ معتبری نداشت (Administrator/Guest هرگز گیرنده نمی‌شوند).\n"
            "سند مرجع: {1} / {2}\nجزئیات: {3}".format(event_key, doctype, name, " ؛ ".join(notes) or "-"),
        )
        return {"sent": 0, "reason": "no_recipient", "event": event_key, "notes": notes}

    cooldown = frappe.utils.cint(event.get("cooldown_minutes")) or frappe.utils.cint(settings.default_cooldown_minutes) or 1
    critical = bool(frappe.utils.cint(event.get("is_critical")))
    master_on = bool(frappe.utils.cint(settings.master_enabled))
    quiet_now = quiet_hours.is_quiet_now(settings)
    prefs_enabled = bool(frappe.utils.cint(settings.enable_user_preferences))
    event_allows_optout = bool(frappe.utils.cint(event.get("allow_user_optout")))

    subject = renderer.render(event.get("internal_subject") or event.get("event_title"), ctx)
    internal_text = renderer.render(event.get("internal_body") or event.get("event_title"), ctx)
    sms_text = renderer.render(event.get("sms_body"), ctx)
    email_subject = renderer.render(event.get("email_subject") or event.get("event_title"), ctx)
    email_text = renderer.render(event.get("email_body"), ctx)

    base_reason = " ؛ ".join(reasons) if reasons else ""
    stats = {"sent": 0, "queued": 0, "skipped_duplicate": 0, "blocked": 0}
    queued = []

    for target in targets:
        for channel in channels:
            address, body, subj = None, "", subject
            pref = None
            if prefs_enabled:
                pref = _preference(target.get("user"), event_key)

            if channel == "Internal":
                if not target.get("user"):
                    continue  # گیرندهٔ بدون حساب کاربری فقط پیامک می‌گیرد
                address, body = target.get("user"), internal_text
            elif channel == "SMS":
                address = (pref and pref.get("custom_mobile")) or target.get("mobile")
                body, subj = sms_text, ""
            elif channel == "Email":
                address, body, subj = target.get("email"), email_text, email_subject

            values = {
                "event_key": event_key,
                "event_title": event.get("event_title"),
                "channel": channel,
                "recipient_user": target.get("user"),
                "recipient_address": address,
                "reference_doctype": doctype,
                "reference_name": name,
                "message_subject": (subj or "")[:140],
                "message_body": (body or "")[:1000],
                "sms_parts": sms_part_count(body) if channel == "SMS" else 0,
                "dedup_key": dedup.make_key(event_key, doctype, name, address or target.get("user"), channel, cooldown),
                "decision_reason": base_reason,
            }

            if not address:
                _write_blocked(values, "Blocked - No Address", "نشانی گیرنده برای این کانال موجود نیست.")
                stats["blocked"] += 1
                continue
            if not master_on:
                _write_blocked(values, "Blocked - Master Off", "کل سیستم اعلان خاموش است.")
                stats["blocked"] += 1
                continue
            if channel == "SMS" and not frappe.utils.cint(settings.sms_master_enabled) and not frappe.utils.cint(settings.test_mode):
                _write_blocked(values, "Blocked - SMS Off", (base_reason + " | " if base_reason else "") + "Kill-Switch پیامک خاموش است.")
                stats["blocked"] += 1
                continue

            if not critical and prefs_enabled and event_allows_optout and pref:
                if channel == "Internal" and pref.get("mute_internal"):
                    _write_blocked(values, "Blocked - Muted", "کاربر اعلان داخلی این رویداد را بی‌صدا کرده است.")
                    stats["blocked"] += 1
                    continue
                if channel == "SMS" and pref.get("mute_sms"):
                    _write_blocked(values, "Blocked - Muted", "کاربر پیامک این رویداد را بی‌صدا کرده است.")
                    stats["blocked"] += 1
                    continue

            if channel == "SMS" and event.get("respect_quiet_hours") and quiet_now and not critical:
                _write_blocked(values, "Blocked - Quiet Hours", "درخواست در ساعات سکوت است.")
                stats["blocked"] += 1
                continue

            values["dispatch_status"] = "Queued"
            log = _reserve(values)
            if log is None:
                stats["skipped_duplicate"] += 1
                continue
            queued.append(log.name)

    from ..channels.dispatcher import deliver_log

    for log_name in queued:
        result = deliver_log(log_name)
        stats["sent" if result.get("ok") else "blocked"] += 1
        stats["queued"] += 1

    # ★ عمداً هیچ‌چیزی روی سند مرجع نوشته نمی‌شود (نه modified، نه هیچ فیلد دیگر).
    return {
        "sent": stats["sent"],
        "queued": stats["queued"],
        "skipped_duplicate": stats["skipped_duplicate"],
        "blocked": stats["blocked"],
        "event": event_key,
        "channels": channels,
        "notes": reasons + notes,
    }


def notify_async(event_key, **kwargs):
    """نسخهٔ کاملاً غیرهمزمان برای مسیرهای حساس به زمان (مثل ذخیرهٔ سند سنگین)."""
    try:
        frappe.enqueue(
            "iran_notify.notification.core.notify",
            queue="short",
            timeout=300,
            enqueue_after_commit=True,
            event_key=event_key,
            **kwargs
        )
        return {"queued": True, "event": event_key}
    except Exception:
        return notify(event_key, **kwargs)
PYEOF

write_utf8 "${PKG}/notification/__init__.py" << 'PYEOF'
# -*- coding: utf-8 -*-
from iran_notify.notification.core import notify, notify_async  # noqa: F401
PYEOF

write_utf8 "${PKG}/__init__.py" << 'PYEOF'
# -*- coding: utf-8 -*-
__version__ = "1.0.0"

from iran_notify.notification.core import notify, notify_async  # noqa: F401
PYEOF

# =============================================================================
step "12) گزارش سلامت روزانه (عمومی — نه مخصوص هیچ ورک‌فلوی کسب‌وکاری)"
write_utf8 "${PKG}/notification/digest.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""خلاصهٔ روزانهٔ سلامت اعلان — چند مورد Blocked/Failed داشتیم؟
این یک قابلیت عمومیِ زیرساختی است (نه رویداد کسب‌وکاری) و با notify() خودش
اطلاع‌رسانی می‌کند (dogfooding)."""
import frappe

from .core import notify
from .settings import hub


def send_daily_health_digest():
    settings = hub()
    if not settings.health_digest_enabled:
        return

    since = frappe.utils.add_days(frappe.utils.now_datetime(), -1)
    bad_statuses = ["Failed", "Blocked - No Address", "Blocked - Master Off", "Blocked - SMS Off"]
    count = frappe.db.count(
        "Notification Dispatch Log",
        {"creation": [">=", since], "dispatch_status": ["in", bad_statuses]},
    )
    if not count:
        return

    if not frappe.db.exists("Notification Event", "system.digest_daily_failures"):
        return

    notify(
        "system.digest_daily_failures",
        context={"failed_count": count, "since": frappe.utils.format_datetime(since)},
    )
PYEOF

# =============================================================================
step "13) API عمومی (whitelisted) برای فراخوانی بدون import مستقیم پایتون"
write_utf8 "${PKG}/api.py" << 'PYEOF'
# -*- coding: utf-8 -*-
import json

import frappe
from frappe import _

from iran_notify.notification.core import notify
from iran_notify.sms.registry import get_adapter, list_adapters


@frappe.whitelist()
def trigger(event_key, reference_doctype=None, reference_name=None, context=None):
    """امکان فراخوانی از Server Script / Client Script / اپ‌های دیگر بدون import مستقیم."""
    if isinstance(context, str):
        try:
            context = json.loads(context or "{}")
        except Exception:
            context = {}
    return notify(event_key, reference_doctype, reference_name, context)


@frappe.whitelist()
def get_adapter_required_fields(adapter_key):
    adapter_cls = get_adapter((adapter_key or "").strip())
    if not adapter_cls:
        return {"error": _("آداپتور «{0}» یافت نشد.").format(adapter_key)}
    return {"fields": adapter_cls.required_fields()}


@frappe.whitelist()
def get_registered_adapters():
    return list_adapters()


@frappe.whitelist()
def send_test_to_me(event_key):
    """دکمهٔ «ارسال آزمایشی برای من» در فرم رویداد اعلان — فقط برای کاربر جاری."""
    user = frappe.session.user
    if user in {"Guest", "Administrator"}:
        frappe.throw(_("این عملیات برای کاربر جاری مجاز نیست. با یک کاربر عادی/مدیر غیر Administrator وارد شوید."))

    if not frappe.db.exists("Notification Event", event_key):
        frappe.throw(_("رویداد یافت نشد."))

    return notify(event_key, context={"triggered_by": user})


@frappe.whitelist()
def purge_my_notifications(only_read=1, older_than_minutes=5):
    """پاک‌سازی امن اعلان‌های خوانده‌شدهٔ خود کاربر از Notification Log."""
    user = frappe.session.user
    if user in {"Guest"}:
        frappe.throw(_("این عملیات برای کاربر مهمان مجاز نیست."))

    only_read = frappe.utils.cint(only_read)
    older_than_minutes = max(0, frappe.utils.cint(older_than_minutes))

    filters = {"for_user": user}
    if only_read:
        filters["read"] = 1
    if older_than_minutes:
        cutoff = frappe.utils.add_to_date(frappe.utils.now_datetime(), minutes=-older_than_minutes)
        filters["creation"] = ["<", cutoff]

    deleted = frappe.db.count("Notification Log", filters) or 0
    if deleted:
        frappe.db.delete("Notification Log", filters)
        frappe.db.commit()

    return {
        "status": "success",
        "deleted": deleted,
        "cleared_for": user,
        "only_read": bool(only_read),
        "older_than_minutes": older_than_minutes,
    }
PYEOF

# =============================================================================
step "14) ایندکس یکتای واقعی روی dedup_key (دِدوپ در سطح دیتابیس)"
write_utf8 "${PKG}/install_index.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""نمایهٔ یکتای واقعی روی dedup_key — Idempotent؛ اگر از قبل باشد کاری نمی‌کند."""
import frappe


def ensure_unique_dedup_index():
    table = "tabNotification Dispatch Log"
    index_name = "iran_notify_dedup_key_uniq"

    if not frappe.db.table_exists("Notification Dispatch Log"):
        return "table missing"

    # 1) آیا ایندکس نام‌دار ما از قبل هست؟
    try:
        exists = frappe.db.sql(
            "SHOW INDEX FROM `{0}` WHERE Key_name = %s".format(table),
            (index_name,),
        )
    except Exception:
        exists = frappe.db.sql(
            """
            SELECT 1 FROM information_schema.statistics
            WHERE table_schema = DATABASE() AND table_name = %s AND index_name = %s
            LIMIT 1
            """,
            (table, index_name),
        )
    if exists:
        return "index already exists"

    # 2) ساخت ایندکس یکتا (DDL با auto_commit تا در تراکنش گیر نکند)
    try:
        ddl = "ALTER TABLE `{0}` ADD UNIQUE INDEX `{1}` (`dedup_key`)".format(table, index_name)
        try:
            frappe.db.sql(ddl, auto_commit=True)
        except TypeError:
            # نسخه‌هایی که auto_commit نمی‌گیرند
            if hasattr(frappe.db, "sql_ddl"):
                frappe.db.sql_ddl(ddl)
            else:
                frappe.db.commit()
                frappe.db.sql(ddl)
                frappe.db.commit()
        frappe.db.commit()
        return "index created"
    except Exception as exc:
        # اگر Frappe از روی unique=1 فیلد، ایندکس دیگری ساخته و
        # تکرار مقدار مانع ساخت شده، باز هم یکتایی ستون را بررسی می‌کنیم
        try:
            any_unique = frappe.db.sql(
                "SHOW INDEX FROM `{0}` WHERE Column_name = 'dedup_key' AND Non_unique = 0".format(table)
            )
            if any_unique:
                return "unique already enforced by other index"
        except Exception:
            pass
        frappe.log_error(title="[iran_notify] ساخت ایندکس یکتا ناموفق بود", message=str(exc))
        return "index creation failed: {0}".format(exc)
PYEOF

# =============================================================================
step "15) hooks.py — فقط بلوک نشانه‌دار؛ ادغام امن"
python3 - "$PKG" << 'PYEOF'
import io, os, re, sys, ast
pkg = sys.argv[1]
hooks = os.path.join(pkg, "hooks.py")
src = ""
if os.path.exists(hooks):
    src = io.open(hooks, encoding="utf-8").read()

START = "# --- IRAN_NOTIFY_HOOKS_START ---"
END = "# --- IRAN_NOTIFY_HOOKS_END ---"
src = re.sub(re.escape(START) + r".*?" + re.escape(END) + r"\n?", "", src, flags=re.S)

block = f'''{START}
app_name = "iran_notify"
app_title = "Iran Notify"
app_publisher = "Iran Trade ERP"
app_description = "زیرساخت عمومی هشدار/اعلان: داخلی رایگان + پیامک پولی، قابل فراخوانی از هر اپ آینده"
app_email = "dev@local"
app_license = "MIT"

required_apps = ["frappe"]

before_install = "iran_notify.setup_foundation.ensure_notification_manager_role"
before_migrate = "iran_notify.setup_foundation.ensure_notification_manager_role"
after_migrate = "iran_notify.setup_foundation.after_migrate"

_in_doctype_js = dict(globals().get("doctype_js") or {{}})
_in_doctype_js["SMS Gateway Profile"] = "public/js/sms_gateway_profile.js"
_in_doctype_js["Notification User Preference"] = "public/js/notification_user_preference.js"
doctype_js = _in_doctype_js

_in_dt_lv = dict(globals().get("doctype_list_js") or {{}})
_in_dt_lv["Notification Event"] = "public/js/notification_event.js"
_in_dt_lv["Notification Dispatch Log"] = "iran_notify/iran_notify/doctype/notification_dispatch_log/notification_dispatch_log_list.js"
_in_dt_lv["Notification User Preference"] = "public/js/notification_user_preference_list.js"
_in_dt_lv["Notification Log"] = "public/js/notification_log_list.js"
doctype_list_js = _in_dt_lv

_in_sched = globals().get("scheduler_events", {{}}) or {{}}
_in_sched.setdefault("cron", {{}})
_in_sched["cron"].setdefault("0 7 * * *", [])
_digest_fn = "iran_notify.notification.digest.send_daily_health_digest"
if _digest_fn not in _in_sched["cron"]["0 7 * * *"]:
    _in_sched["cron"]["0 7 * * *"].append(_digest_fn)
scheduler_events = _in_sched
{END}
'''
src = (src.rstrip() + "\n\n" + block + "\n") if src.strip() else (block + "\n")
io.open(hooks, "w", encoding="utf-8").write(src)
ast.parse(src)
print("hooks.py updated (marker-safe merge):", hooks)
PYEOF
log "hooks.py نوشته شد"

# =============================================================================
step "16) Workspace + ترجمهٔ فارسی"
write_utf8 "${MOD}/workspace/iran_notify/iran_notify.json" << 'EOF'
{
 "charts": [],
 "content": "[{\"id\":\"hdr\",\"type\":\"header\",\"data\":{\"text\":\"<span class=\\\"h4\\\">مرکز اعلان ایران</span>\",\"col\":12}},{\"id\":\"card_set\",\"type\":\"card\",\"data\":{\"card_name\":\"Settings\",\"col\":4}},{\"id\":\"card_events\",\"type\":\"card\",\"data\":{\"card_name\":\"Events\",\"col\":4}},{\"id\":\"card_logs\",\"type\":\"card\",\"data\":{\"card_name\":\"Logs\",\"col\":4}}]",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "Workspace",
 "for_user": "",
 "hide_custom": 0,
 "icon": "notification",
 "is_default": 0,
 "is_hidden": 0,
 "is_standard": 1,
 "label": "Iran Notify",
 "links": [
  {"type": "Card Break", "label": "Settings", "link_count": 2, "hidden": 0, "onboard": 0, "is_query_report": 0},
  {"type": "Link", "label": "Notify Settings", "link_type": "DocType", "link_to": "Notify Settings", "hidden": 0, "onboard": 1, "is_query_report": 0, "dependencies": ""},
  {"type": "Link", "label": "SMS Gateway Profile", "link_type": "DocType", "link_to": "SMS Gateway Profile", "hidden": 0, "onboard": 1, "is_query_report": 0, "dependencies": ""},
  {"type": "Card Break", "label": "Events", "link_count": 2, "hidden": 0, "onboard": 0, "is_query_report": 0},
  {"type": "Link", "label": "Notification Event", "link_type": "DocType", "link_to": "Notification Event", "hidden": 0, "onboard": 1, "is_query_report": 0, "dependencies": ""},
  {"type": "Link", "label": "Notification User Preference", "link_type": "DocType", "link_to": "Notification User Preference", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""},
  {"type": "Card Break", "label": "Logs", "link_count": 1, "hidden": 0, "onboard": 0, "is_query_report": 0},
  {"type": "Link", "label": "Notification Dispatch Log", "link_type": "DocType", "link_to": "Notification Dispatch Log", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""}
 ],
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Iran Notify",
 "name": "Iran Notify",
 "number_cards": [],
 "owner": "Administrator",
 "parent_page": "",
 "public": 1,
 "quick_lists": [],
 "restrict_to_domain": "",
 "roles": [
  {"role": "Notification Manager"},
  {"role": "System Manager"}
 ],
 "sequence_id": 91.0,
 "shortcuts": [
  {"type": "DocType", "label": "Notification Event", "link_to": "Notification Event", "doc_view": "", "color": "Blue", "format": "", "stats_filter": ""},
  {"type": "DocType", "label": "Notification Dispatch Log", "link_to": "Notification Dispatch Log", "doc_view": "", "color": "Orange", "format": "", "stats_filter": ""}
 ],
 "title": "Iran Notify"
}
EOF

write_utf8 "${MOD}/workspace/my_notification_preferences/my_notification_preferences.json" << 'EOF'
{
 "charts": [],
 "content": "[{\"id\":\"hdr\",\"type\":\"header\",\"data\":{\"text\":\"<span class=\\\"h4\\\">تنظیمات اعلان‌های من</span>\",\"col\":12}},{\"id\":\"card_prefs\",\"type\":\"card\",\"data\":{\"card_name\":\"My Preferences\",\"col\":6}},{\"id\":\"card_logs\",\"type\":\"card\",\"data\":{\"card_name\":\"My Logs\",\"col\":6}}]",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "Workspace",
 "for_user": "",
 "hide_custom": 0,
 "icon": "bell",
 "is_default": 0,
 "is_hidden": 0,
 "is_standard": 1,
 "label": "My Notification Preferences",
 "links": [
  {"type": "Card Break", "label": "My Preferences", "link_count": 1, "hidden": 0, "onboard": 0, "is_query_report": 0},
  {"type": "Link", "label": "Notification User Preference", "link_type": "DocType", "link_to": "Notification User Preference", "hidden": 0, "onboard": 1, "is_query_report": 0, "dependencies": ""},
  {"type": "Card Break", "label": "My Logs", "link_count": 1, "hidden": 0, "onboard": 0, "is_query_report": 0},
  {"type": "Link", "label": "Notification Log", "link_type": "DocType", "link_to": "Notification Log", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""}
 ],
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Iran Notify",
 "name": "My Notification Preferences",
 "number_cards": [],
 "owner": "Administrator",
 "parent_page": "",
 "public": 1,
 "quick_lists": [],
 "restrict_to_domain": "",
 "roles": [
  {"role": "Desk User"}
 ],
 "sequence_id": 92.0,
 "shortcuts": [
  {"type": "DocType", "label": "Notification User Preference", "link_to": "Notification User Preference", "doc_view": "", "color": "Blue", "format": "", "stats_filter": ""},
  {"type": "DocType", "label": "Notification Log", "link_to": "Notification Log", "doc_view": "", "color": "Orange", "format": "", "stats_filter": ""}
 ],
 "title": "My Notification Preferences"
}
EOF

write_utf8 "${PKG}/translations/fa.csv" << 'EOF'
Iran Notify,اعلان ایران,
My Notification Preferences,تنظیمات اعلان‌های من,
Notify Settings,تنظیمات مرکز اعلان,
SMS Gateway Profile,درگاه پیامک,
Notification Event,رویداد اعلان,
Notification Dispatch Log,دفتر ارسال اعلان,
Notification User Preference,ترجیح اعلان کاربر,
Notification Recipient Role,نقش گیرندهٔ اعلان,
Notification Recipient User,کاربر گیرندهٔ اعلان,
Notification Manager,مدیر اعلان,
Settings,تنظیمات,
Events,رویدادها,
Logs,دفاتر,
My Preferences,ترجیحات من,
My Logs,اعلان‌های من,
EOF

write_utf8 "${PKG}/public/js/notify_settings.js" << 'JS'
frappe.ui.form.on("Notify Settings", {
	refresh: function (frm) {
		if (!frm.doc.sms_master_enabled) {
			frm.set_intro(
				__("Kill-Switch پیامک خاموش است: هیچ پیامک واقعی از هیچ رویدادی ارسال نمی‌شود."),
				"blue"
			);
		} else if (frm.doc.test_mode) {
			frm.set_intro(__("حالت آزمایشی فعال است: پیامک‌ها فقط ثبت می‌شوند، مخابره نمی‌شوند."), "orange");
		} else {
			frm.set_intro(__("توجه: پیامک واقعی روشن است و حالت آزمایشی خاموش است."), "red");
		}
	},
});
JS

write_utf8 "${PKG}/public/css/iran_notify.css" << 'EOF'
/* iran_notify — سبک و بدون وابستگی؛ فقط جزئیات کوچک UI */
.form-intro:has(+ .form-layout) { direction: rtl; }
EOF

# =============================================================================
step "17) setup_foundation — نقش، پیش‌فرض‌های امن، بذر رویدادهای عمومی سیستمی"
write_utf8 "${PKG}/setup_foundation.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""بذر پایهٔ iran_notify — فقط زیرساخت عمومی، صفر رویداد کسب‌وکاری.

رویدادهای کسب‌وکاری واقعی (مثل «رد واحد حقوقی» یا «ارجاع به کارمند») در
فاز پایانی — پس از پیاده‌سازی کامل ورک‌فلوی خرید/فروش/حمل — با اسکریپت
نمونهٔ sample-finals-cript.sh کاشته می‌شوند، نه اینجا.
"""
import frappe


def ensure_notification_manager_role():
    if frappe.db.exists("Role", "Notification Manager"):
        return
    try:
        frappe.get_doc({
            "doctype": "Role",
            "role_name": "Notification Manager",
            "desk_access": 1,
            "is_custom": 1,
        }).insert(ignore_permissions=True)
        frappe.db.commit()
    except Exception:
        frappe.db.rollback()


def _ensure_defaults():
    if not frappe.db.exists("DocType", "Notify Settings"):
        return
    s = frappe.get_single("Notify Settings")
    changed = False
    defaults = {
        "master_enabled": 1,
        "sms_master_enabled": 0,   # Kill-Switch — عمداً خاموش تا مدیر آگاهانه روشن کند
        "test_mode": 1,
        "default_cooldown_minutes": 10,
        "enable_user_preferences": 1,
        "quiet_hours_enabled": 1,
        "health_digest_enabled": 1,
    }
    for field, value in defaults.items():
        if s.meta.has_field(field) and s.get(field) is None:
            s.set(field, value)
            changed = True
    if changed:
        s.flags.ignore_permissions = True
        s.save(ignore_permissions=True)


def _ensure_system_events():
    """دو رویداد کاملاً عمومی — نه یک کلمه دربارهٔ گردش‌کار کسب‌وکاری.

    system.notify_test فقط از dynamic_user_field=triggered_by استفاده می‌کند
    (بدون نقش) تا تست فقط به خودِ اجراکننده برود.
    system.digest_daily_failures برای نقش Notification Manager می‌ماند.

    فقط وقتی is_seed و allow_seed_overwrite=1 باشد بازنویسی می‌شود.
    """
    if not frappe.db.exists("DocType", "Notification Event"):
        return

    generic_events = [
        {
            "event_key": "system.notify_test",
            "event_title": "پیام آزمایشی مرکز اعلان",
            "category": "سیستمی",
            "send_sms": 0,
            "internal_subject": "تست مرکز اعلان",
            "internal_body": "این یک اعلان آزمایشی از مرکز اعلان است.",
            "dynamic_user_field": "triggered_by",
        },
        {
            "event_key": "system.digest_daily_failures",
            "event_title": "گزارش روزانهٔ اعلان‌های ناموفق",
            "category": "سیستمی",
            "send_sms": 0,
            "internal_subject": "گزارش سلامت اعلان",
            "internal_body": "در ۲۴ ساعت گذشته {{failed_count}} اعلان ارسال نشد. برای جزئیات «دفتر ارسال اعلان» را ببینید.",
        },
    ]

    for spec in generic_events:
        key = spec["event_key"]
        if frappe.db.exists("Notification Event", key):
            existing = frappe.get_doc("Notification Event", key)
            if existing.is_seed and existing.allow_seed_overwrite:
                for field, value in spec.items():
                    existing.set(field, value)
                existing.is_seed = 1
                if key == "system.notify_test":
                    existing.recipient_roles = []
                elif key == "system.digest_daily_failures":
                    if not existing.recipient_roles:
                        existing.append("recipient_roles", {"role": "Notification Manager"})
                existing.flags.ignore_permissions = True
                existing.save(ignore_permissions=True)
            continue

        doc = frappe.get_doc({"doctype": "Notification Event", **spec})
        doc.is_seed = 1
        doc.allow_seed_overwrite = 1
        doc.is_active = 1
        if key == "system.digest_daily_failures":
            doc.append("recipient_roles", {"role": "Notification Manager"})
        doc.flags.ignore_permissions = True
        doc.insert(ignore_permissions=True)


def _ensure_translations():
    rows = [
        ("Notification Manager", "مدیر اعلان"),
        ("Iran Notify", "اعلان ایران"),
        ("My Notification Preferences", "تنظیمات اعلان‌های من"),
    ]
    for source, translated in rows:
        if frappe.db.exists("Translation", {"language": "fa", "source_text": source}):
            continue
        frappe.get_doc({
            "doctype": "Translation",
            "language": "fa",
            "source_text": source,
            "translated_text": translated,
        }).insert(ignore_permissions=True)


def after_migrate():
    ensure_notification_manager_role()
    _ensure_defaults()
    _ensure_system_events()
    _ensure_translations()

    from iran_notify.install_index import ensure_unique_dedup_index

    ensure_unique_dedup_index()

    frappe.db.commit()
    frappe.clear_cache()


def run():
    after_migrate()
    return {"result": "iran_notify foundation seeded"}
PYEOF

# =============================================================================
step "18) verify_script02.py — تضمین رفتاری قواعد آهنین"
write_utf8 "${PKG}/verify_script02.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""راستی‌آزمایی رفتاری iran_notify روی سایت زندهٔ واقعی (نه mock)."""
import frappe


def _ensure_user(email, first_name, last_name, roles=None):
    """ساخت/فعال‌سازی کاربر fixture. created=True فقط اگر خودمان ساخته باشیم."""
    created = False
    if not frappe.db.exists("User", email):
        user = frappe.get_doc({
            "doctype": "User",
            "email": email,
            "first_name": first_name,
            "last_name": last_name,
            "send_welcome_email": 0,
            "user_type": "System User",
            "new_password": frappe.generate_hash(length=12),
        })
        user.flags.ignore_permissions = True
        user.insert(ignore_permissions=True)
        created = True
    else:
        user = frappe.get_doc("User", email)
        if not user.enabled:
            user.enabled = 1
            user.flags.ignore_permissions = True
            user.save(ignore_permissions=True)

    for role in (roles or []):
        user.add_roles(role)
    frappe.db.commit()
    return email, created


def _cleanup_user(email, created):
    if not created or not email:
        return
    try:
        # پاک‌سازی artifactهای وابسته قبل از حذف User
        if frappe.db.exists("DocType", "Notification Dispatch Log"):
            frappe.db.delete("Notification Dispatch Log", {"recipient_user": email})
        if frappe.db.exists("DocType", "Notification Log"):
            frappe.db.delete("Notification Log", {"for_user": email})
        if frappe.db.exists("DocType", "Notification User Preference"):
            frappe.db.delete("Notification User Preference", {"user": email})
        frappe.db.commit()
        if frappe.db.exists("User", email):
            frappe.delete_doc("User", email, force=1, ignore_permissions=True)
            frappe.db.commit()
    except Exception:
        frappe.db.rollback()


def run():
    passed, failed = 0, 0
    fixtures = []  # [(email, created), ...]

    def chk(title, cond):
        nonlocal passed, failed
        if cond:
            passed += 1
            print("  [PASS] " + title)
        else:
            failed += 1
            print("  [FAIL] " + title)

    from iran_notify.install_index import ensure_unique_dedup_index
    from iran_notify.notification import dedup, quiet_hours, recipients
    from iran_notify.notification.core import notify
    from iran_notify.notification.settings import hub

    # اطمینان از ایندکس قبل از آزمون‌ها (idempotent)
    ensure_unique_dedup_index()

    try:
        # گیرندهٔ C13: نقش مدیر اعلان دارد تا digest/رویدادها را پوشش دهد
        verify_user, created_v = _ensure_user(
            "notify.verifier@example.com", "Notify", "Verifier",
            roles=["Notification Manager"],
        )
        fixtures.append((verify_user, created_v))

        # کاربر عادی بدون نقش مدیریتی — فقط برای C22 (حفرهٔ if_owner)
        plain_user, created_p = _ensure_user(
            "notify.plain@example.com", "Notify", "Plain",
            roles=[],
        )
        fixtures.append((plain_user, created_p))

        chk("C1 نقش Notification Manager وجود دارد", bool(frappe.db.exists("Role", "Notification Manager")))
        chk("C2 Workspace Iran Notify وجود دارد", bool(frappe.db.exists("Workspace", "Iran Notify")))

        s = hub()
        chk("C3 پیامک واقعی پیش‌فرض خاموش است (Kill-Switch)", not bool(s.sms_master_enabled))
        chk("C4 حالت آزمایشی پیش‌فرض روشن است", bool(s.test_mode))
        chk("C5 سیستم اعلان پیش‌فرض روشن است", bool(s.master_enabled))

        chk("C6 رویداد سیستمی system.notify_test بذر شده", bool(frappe.db.exists("Notification Event", "system.notify_test")))
        chk("C7 رویداد سیستمی system.digest_daily_failures بذر شده", bool(frappe.db.exists("Notification Event", "system.digest_daily_failures")))

        # C8: رویداد بدون هیچ منبع گیرنده باید رد شود
        rejected = False
        try:
            frappe.get_doc({
                "doctype": "Notification Event",
                "event_key": "test.no_recipient_should_fail",
                "event_title": "تست بدون گیرنده",
                "category": "سیستمی",
            }).insert(ignore_permissions=True)
        except Exception:
            rejected = True
        chk("C8 رویداد بدون منبع گیرنده رد می‌شود", rejected)

        # C9: send_sms=1 بدون sms_body باید رد شود
        rejected = False
        try:
            d = frappe.get_doc({
                "doctype": "Notification Event",
                "event_key": "test.sms_without_body_should_fail",
                "event_title": "تست پیامک بدون متن",
                "category": "سیستمی",
                "send_sms": 1,
            })
            d.append("recipient_roles", {"role": "Notification Manager"})
            d.insert(ignore_permissions=True)
        except Exception:
            rejected = True
        chk("C9 رویداد پیامکی بدون متن پیامک رد می‌شود", rejected)

        # C10: Administrator/Guest هرگز گیرنده نمی‌شوند
        fake_event = {"recipient_roles": [], "recipient_users": [{"user": "Administrator"}],
                      "dynamic_user_field": None, "dynamic_mobile_field": None}
        targets, _notes = recipients.resolve(fake_event, None)
        chk("C10 Administrator هرگز در نتیجهٔ resolve نیست", all(t.get("user") != "Administrator" for t in targets))

        # C11: notify() با رویداد ناموجود هرگز استثنا نمی‌دهد
        ok = True
        try:
            result = notify("this.event.does.not.exist", context={})
        except Exception:
            ok = False
        chk("C11 notify() با رویداد ناموجود استثنا نمی‌دهد", ok)
        chk("C11b نتیجه reason=no_event است", isinstance(result, dict) and result.get("reason") == "no_event")

        # C12: dedup.make_key پایدار و به بازهٔ کول‌داون وابسته است
        k1 = dedup.make_key("evt", "DocType", "NAME", "addr", "SMS", 10)
        k2 = dedup.make_key("evt", "DocType", "NAME", "addr", "SMS", 10)
        chk("C12 dedup.make_key در یک بازه پایدار است", k1 == k2)

        # C13: reference_name یکتا در هر اجرا → idempotent روی اجرای مجدد اسکریپت
        run_token = frappe.generate_hash(length=10)
        ref_name = "VERIFY-" + run_token
        r1 = notify(
            "system.notify_test",
            doctype="ToDo",
            name=ref_name,
            context={"triggered_by": verify_user},
        )
        chk(
            "C13 فراخوانی notify() حداقل یک ردیف موفق/صف‌شده ثبت می‌کند",
            isinstance(r1, dict) and (r1.get("sent", 0) + r1.get("queued", 0)) >= 1,
        )

        # C13b: رویداد تست نباید نقش Notification Manager داشته باشد (اسپم مدیران)
        test_ev = frappe.get_doc("Notification Event", "system.notify_test")
        chk(
            "C13b system.notify_test فاقد recipient_roles است",
            not (test_ev.recipient_roles or []),
        )

        # C14: تکرار همان identity باید skipped_duplicate >= 1 و ردیف جدید نسازد
        before_names = set(frappe.get_all(
            "Notification Dispatch Log",
            filters={"event_key": "system.notify_test", "reference_name": ref_name},
            pluck="name",
        ))
        r2 = notify(
            "system.notify_test",
            doctype="ToDo",
            name=ref_name,
            context={"triggered_by": verify_user},
        )
        after_names = set(frappe.get_all(
            "Notification Dispatch Log",
            filters={"event_key": "system.notify_test", "reference_name": ref_name},
            pluck="name",
        ))
        chk(
            "C14 دِدوپ فراخوانی دوم همان identity را کاملاً بلاک می‌کند",
            len(after_names - before_names) == 0 and isinstance(r2, dict) and r2.get("skipped_duplicate", 0) >= 1,
        )

        # C15: ساعات سکوت هرگز استثنا نمی‌دهد، فقط bool برمی‌گرداند
        ok = True
        try:
            _q = quiet_hours.is_quiet_now(s)
            ok = isinstance(_q, bool)
        except Exception:
            ok = False
        chk("C15 quiet_hours.is_quiet_now() ایمن است و bool برمی‌گرداند", ok)

        # C16: ایندکس یکتای dedup_key واقعاً روی دیتابیس ساخته شده
        idx = frappe.db.sql(
            """
            SELECT 1 FROM information_schema.statistics
            WHERE table_schema = DATABASE() AND table_name = 'tabNotification Dispatch Log'
              AND index_name = 'iran_notify_dedup_key_uniq'
            LIMIT 1
            """
        )
        if not idx:
            # فال‌بک: هر ایندکس یکتا روی ستون dedup_key (مثلاً از unique=1 فیلد)
            idx = frappe.db.sql(
                """
                SELECT 1 FROM information_schema.statistics
                WHERE table_schema = DATABASE() AND table_name = 'tabNotification Dispatch Log'
                  AND column_name = 'dedup_key' AND non_unique = 0
                LIMIT 1
                """
            )
        chk("C16 نمایهٔ یکتای دیتابیس روی dedup_key وجود دارد", bool(idx))

        # C17: hooks.py شامل بلوک ماست
        hooked_sched = frappe.get_hooks("scheduler_events") or {}
        cron = (hooked_sched.get("cron") or {})
        chk(
            "C17 گزارش سلامت روزانه در scheduler_events ثبت شده",
            any("send_daily_health_digest" in fn for fns in cron.values() for fn in fns),
        )

        # C18: آداپتورهای پیامک ثبت شده‌اند (Plugin Registry)
        from iran_notify.sms.registry import list_adapters
        keys = {a["key"] for a in list_adapters()}
        chk("C18 آداپتورهای پایه ثبت شده‌اند", {"console_debug", "generic_http", "kavenegar"}.issubset(keys))

        # C19: هیچ فیلد سقف هزینه‌ای در DocType تنظیمات وجود ندارد (طبق تصمیم صریح کارفرما)
        settings_meta = frappe.get_meta("Notify Settings")
        banned_fields = {"sms_daily_cap", "sms_monthly_cap", "sms_unit_cost", "cost_alert_threshold_percent"}
        present = {f.fieldname for f in settings_meta.fields} & banned_fields
        chk("C19 فیلدهای سقف/هزینهٔ پیامک عمداً در تنظیمات وجود ندارند", not present)

        # C20: نبود گزارش/رویداد هزینه‌ای متروک
        chk("C20 رویداد alert.cost_threshold وجود ندارد (عمداً حذف شد)", not frappe.db.exists("Notification Event", "alert.cost_threshold"))

        # C21: Workspace تنظیمات شخصی کاربران عادی
        chk(
            "C21 Workspace My Notification Preferences وجود دارد",
            bool(frappe.db.exists("Workspace", "My Notification Preferences")),
        )

        # C22: کاربر عادی (بدون نقش مدیر) نمی‌تواند preference برای user دیگر بسازد
        blocked_cross = False
        original_user = frappe.session.user
        try:
            frappe.set_user(plain_user)
            try:
                doc = frappe.get_doc({
                    "doctype": "Notification User Preference",
                    "user": "Administrator",
                    "event_key": "system.notify_test",
                    "mute_internal": 1,
                })
                doc.insert(ignore_permissions=False)
                # اگر insert موفق شد ولی user اجباراً به plain_user تغییر کرد، باز هم امن است
                if doc.user == "Administrator":
                    blocked_cross = False
                else:
                    blocked_cross = True  # validate user را override کرده
                    frappe.delete_doc("Notification User Preference", doc.name, force=1, ignore_permissions=True)
            except Exception:
                blocked_cross = True
        finally:
            frappe.set_user(original_user)
            leftover = frappe.db.get_all(
                "Notification User Preference",
                filters={"event_key": "system.notify_test", "user": ["in", ["Administrator", plain_user]]},
                pluck="name",
            )
            for name in leftover:
                try:
                    frappe.delete_doc("Notification User Preference", name, force=1, ignore_permissions=True)
                except Exception:
                    pass
            frappe.db.commit()
        chk("C22 کاربر عادی نمی‌تواند preference برای user دیگر بسازد", blocked_cross)

        print("\n  Passed: %d | Failed: %d" % (passed, failed))
        if failed:
            raise Exception("verify_script02 FAILED: %d" % failed)
        return "OK"
    finally:
        for email, created in fixtures:
            _cleanup_user(email, created)
PYEOF

# =============================================================================
step "19) بررسی نحوی همهٔ فایل‌های پایتون پیش از migrate"
while IFS= read -r -d '' pyfile; do
  validate_py "$pyfile"
done < <(find "${BENCH_DIR}/apps/${APP}" -name '*.py' -print0)
log "همهٔ فایل‌های پایتون از نظر نحوی معتبرند"

# =============================================================================
step "20) نصب اپ روی سایت + migrate + build + seed + verify"
if bench --site "$SITE_NAME" list-apps 2>/dev/null | grep -qw "$APP"; then
  warn "اپ ${APP} از قبل روی سایت نصب است"
else
  bench --site "$SITE_NAME" install-app "$APP"
  log "اپ ${APP} نصب شد"
fi

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache
bench build --app "$APP" || warn "bench build رد شد — بعداً دستی: bench build --app ${APP}"

bench --site "$SITE_NAME" execute iran_notify.setup_foundation.run
bench --site "$SITE_NAME" execute iran_notify.verify_script02.run
bench --site "$SITE_NAME" clear-cache

# =============================================================================
cat <<FINAL

============================================================
 script-02.sh با موفقیت تمام شد
------------------------------------------------------------
 اپ            : iran_notify (مستقل، بدون وابستگی به هیچ ورک‌فلوی کسب‌وکاری)
 API عمومی     : from iran_notify import notify
                 notify("event.key", "DocType", "NAME", {"var": "value"})
 Kill-Switch   : sms_master_enabled پیش‌فرض خاموش + test_mode روشن
 UX رویداد     : فقط یک تیک واقعی به کاربر داده می‌شود → send_sms
                 (اعلان داخلی رایگان و همیشه روشن است، نیازی به تیک ندارد)
 حذف عمدی      : سقف/هزینهٔ پیامک در ERPNext (وظیفهٔ پنل پیامکی است)
 گام بعد       : sample-finals-cript.sh — پس از تکمیل ورک‌فلوی واقعی خرید/
                 فروش/حمل، دقیقاً همین notify() برای رویدادهای واقعی سیم‌کشی می‌شود.
============================================================
FINAL