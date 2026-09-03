#!/usr/bin/env bash
# =============================================================================
# script-03.sh — داده پایه صنعت + هویت ایرانی/خارجی + موتور چندارزی رویدادی
# بازسازی هدایت‌شده — Iran Trade ERP | ERPNext v15 / Frappe v15
# -----------------------------------------------------------------------------
# این اسکریپت:
#   1) چهار DocType داده پایه صنعت حمل: Border / Carrier / Customs Broker /
#      Border Representative  (+ داده اولیه ۶ مرز واقعی ایران)
#   2) مدل هویت ایرانی/خارجی روی Driver, Customer, Supplier, Contact
#      nationality (پیش‌فرض ایرانی) | national_id (فقط ایرانی) | passport_number
#   3) نوع پلاک روی Vehicle: ایرانی / بین‌المللی / گذر موقت
#      اعتبارسنجی قالب فقط برای «ایرانی»
#   4) موتور واحد چندارزی در «سطح رویداد» — دقیقاً طبق
#      mid-phases-v3/MULTI_CURRENCY_DESIGN.txt
#      resolve_rate: ارز یکسان → Currency Exchange → Treasury Settings
#      (فقط USD→IRR) → در غیر این صورت throw. بدون نرخ حدسی، بدون نرخ صفر.
#      rate_locked / rate_source / base_amount منجمد در لحظه رویداد.
#
# هیچ فایلی از script-01/02 تغییر نمی‌کند. اجرای مجدد بی‌خطر است.
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

[[ -d "$BENCH_DIR" ]] || err "Bench یافت نشد"
cd "$BENCH_DIR"

step "0) سرویس‌ها"
if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "bench در حال اجراست"
else
  nohup bench start >>/tmp/bench-start-itc03.log 2>&1 & log "bench start pid=$!"; sleep 12
fi
RC="${BENCH_DIR}/config/redis_cache.conf"
RP="$( [[ -f "$RC" ]] && awk '$1=="port"{print $2; exit}' "$RC" || echo 13000 )"; [[ -n "$RP" ]] || RP=13000
R=0; for _i in $(seq 1 60); do
  if command -v redis-cli >/dev/null 2>&1 && redis-cli -h 127.0.0.1 -p "$RP" ping 2>/dev/null | grep -q '^PONG$'; then R=1; break; fi
  if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ":${RP}[[:space:]]"; then R=1; break; fi
  sleep 1; done
[[ "$R" -eq 1 ]] || err "redis آماده نشد"
bench use "$SITE_NAME" 2>/dev/null || true

step "0b) پیش‌نیاز — ABORT در نبود Anchor"
[[ -d "${BENCH_DIR}/apps/${APP}" ]] || err "ABORT: اپ ${APP} نیست. ابتدا script-02.sh"
[[ -f "${MOD}/utils/naming_guard.py" ]] || err "ABORT: naming_guard.py نیست (script-02)"
bench --site "$SITE_NAME" list-apps 2>/dev/null | grep -qw "iran_common" || err "ABORT: iran_common نصب نیست"
log "پیش‌نیازها تایید شد"

# =============================================================================
step "1) DocTypeهای داده پایه صنعت حمل"
mk_dt() { mkdir -p "${MOD}/doctype/$1"; : > "${MOD}/doctype/$1/__init__.py"; }
mk_dt border; mk_dt carrier; mk_dt customs_broker; mk_dt border_representative

write_utf8 "${MOD}/doctype/border/border.json" << 'EOF'
{
 "actions": [], "allow_rename": 1, "autoname": "field:border_name",
 "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["border_name", "province", "border_type", "adjacent_country", "is_active", "notes"],
 "fields": [
  {"fieldname": "border_name", "fieldtype": "Data", "in_list_view": 1, "label": "نام مرز", "reqd": 1, "unique": 1},
  {"fieldname": "province", "fieldtype": "Data", "in_list_view": 1, "label": "استان"},
  {"fieldname": "border_type", "fieldtype": "Select", "in_list_view": 1, "label": "نوع مرز", "options": "زمینی\nدریایی\nهوایی\nریلی", "default": "زمینی"},
  {"fieldname": "adjacent_country", "fieldtype": "Link", "label": "کشور مقابل", "options": "Country"},
  {"default": "1", "fieldname": "is_active", "fieldtype": "Check", "label": "فعال"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "یادداشت"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Border", "owner": "Administrator",
  "permissions": [
   {"create": 1, "delete": 1, "read": 1, "write": 1, "report": 1, "export": 1, "role": "System Manager"},
   {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Transport Supervisor"},
   {"read": 1, "report": 1, "role": "Transport User - Purchase"},
   {"read": 1, "report": 1, "role": "Transport User - Sales"},
   {"read": 1, "report": 1, "role": "Customs Officer"},
   {"read": 1, "report": 1, "role": "Finance Supervisor"},
   {"read": 1, "report": 1, "role": "Finance User"},
   {"read": 1, "report": 1, "role": "Financial Manager"},
   {"read": 1, "report": 1, "role": "CEO"},
   {"read": 1, "report": 1, "role": "Legal Reviewer"},
   {"read": 1, "report": 1, "role": "Treasury User"},
   {"read": 1, "report": 1, "role": "Receivables User"}
  ],
  "sort_field": "modified", "sort_order": "DESC", "title_field": "border_name", "track_changes": 1
}
EOF
write_utf8 "${MOD}/doctype/border/border.py" << 'EOF'
# -*- coding: utf-8 -*-
from frappe.model.document import Document


class Border(Document):
    pass
EOF

for pair in "carrier:Carrier:carrier_name:نام باربری" \
            "customs_broker:Customs Broker:broker_name:نام ترخیص‌کار"; do
  d="${pair%%:*}"; rest="${pair#*:}"; dt="${rest%%:*}"; rest="${rest#*:}"
  fn="${rest%%:*}"; lbl="${rest#*:}"
  EXTRA=""
  if [[ "$d" == "carrier" ]]; then
    EXTRA='{"fieldname": "sheba", "fieldtype": "Data", "label": "شماره شبا"},
  {"fieldname": "bank_name", "fieldtype": "Data", "label": "نام بانک"},'
  fi
  write_utf8 "${MOD}/doctype/${d}/${d}.json" << EOF
{
 "actions": [], "allow_rename": 1, "autoname": "field:${fn}",
 "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["${fn}", "contact_person", "mobile_no", "phone_no", $( [[ "$d" == "carrier" ]] && echo '"sheba", "bank_name",' )"is_active", "notes"],
 "fields": [
  {"fieldname": "${fn}", "fieldtype": "Data", "in_list_view": 1, "label": "${lbl}", "reqd": 1, "unique": 1},
  {"fieldname": "contact_person", "fieldtype": "Data", "in_list_view": 1, "label": "شخص رابط"},
  {"fieldname": "mobile_no", "fieldtype": "Data", "in_list_view": 1, "label": "شماره موبایل"},
  {"fieldname": "phone_no", "fieldtype": "Data", "label": "تلفن"},
  ${EXTRA}
  {"default": "1", "fieldname": "is_active", "fieldtype": "Check", "label": "فعال"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "یادداشت"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "${dt}", "owner": "Administrator",
  "permissions": [
   {"create": 1, "delete": 1, "read": 1, "write": 1, "report": 1, "export": 1, "role": "System Manager"},
   {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Transport Supervisor"},
   {"read": 1, "report": 1, "role": "Transport User - Purchase"},
   {"read": 1, "report": 1, "role": "Transport User - Sales"},
   {"read": 1, "report": 1, "role": "Customs Officer"},
   {"read": 1, "report": 1, "role": "Finance Supervisor"},
   {"read": 1, "report": 1, "role": "Finance User"},
   {"read": 1, "report": 1, "role": "Financial Manager"},
   {"read": 1, "report": 1, "role": "CEO"},
   {"read": 1, "report": 1, "role": "Legal Reviewer"},
   {"read": 1, "report": 1, "role": "Treasury User"},
   {"read": 1, "report": 1, "role": "Receivables User"}
  ],
  "sort_field": "modified", "sort_order": "DESC", "title_field": "${fn}", "track_changes": 1
}
EOF
done

write_utf8 "${MOD}/doctype/carrier/carrier.py" << 'EOF'
# -*- coding: utf-8 -*-
from frappe.model.document import Document
from iran_trade_erp.iran_trade.validations.master_data import validate_master_party


class Carrier(Document):
    def validate(self):
        validate_master_party(self)
EOF
write_utf8 "${MOD}/doctype/customs_broker/customs_broker.py" << 'EOF'
# -*- coding: utf-8 -*-
from frappe.model.document import Document
from iran_trade_erp.iran_trade.validations.master_data import validate_master_party


class CustomsBroker(Document):
    def validate(self):
        validate_master_party(self)
EOF

write_utf8 "${MOD}/doctype/border_representative/border_representative.json" << 'EOF'
{
 "actions": [], "allow_rename": 1, "autoname": "format:{representative_name}-{border}",
 "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["representative_name", "border", "mobile_no", "phone_no", "is_active", "notes"],
 "fields": [
  {"fieldname": "representative_name", "fieldtype": "Data", "in_list_view": 1, "label": "نام نماینده", "reqd": 1},
  {"fieldname": "border", "fieldtype": "Link", "in_list_view": 1, "label": "مرز", "options": "Border", "reqd": 1},
  {"fieldname": "mobile_no", "fieldtype": "Data", "in_list_view": 1, "label": "شماره موبایل"},
  {"fieldname": "phone_no", "fieldtype": "Data", "label": "تلفن"},
  {"default": "1", "fieldname": "is_active", "fieldtype": "Check", "label": "فعال"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "یادداشت"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Border Representative", "owner": "Administrator",
  "permissions": [
   {"create": 1, "delete": 1, "read": 1, "write": 1, "report": 1, "export": 1, "role": "System Manager"},
   {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Transport Supervisor"},
   {"read": 1, "report": 1, "role": "Customs Officer"},
   {"read": 1, "report": 1, "role": "Finance Supervisor"},
   {"read": 1, "report": 1, "role": "Finance User"},
   {"read": 1, "report": 1, "role": "Financial Manager"},
   {"read": 1, "report": 1, "role": "Treasury User"},
   {"read": 1, "report": 1, "role": "Receivables User"},
   {"read": 1, "report": 1, "role": "CEO"}
  ],
  "sort_field": "modified", "sort_order": "DESC", "title_field": "representative_name", "track_changes": 1
}
EOF
write_utf8 "${MOD}/doctype/border_representative/border_representative.py" << 'EOF'
# -*- coding: utf-8 -*-
from frappe.model.document import Document
from iran_trade_erp.iran_trade.validations.master_data import validate_master_party


class BorderRepresentative(Document):
    def validate(self):
        validate_master_party(self)
EOF

# =============================================================================
step "2) اعتبارسنجی داده پایه + هویت ایرانی/خارجی + پلاک"
mkdir -p "${MOD}/validations"; : > "${MOD}/validations/__init__.py"
write_utf8 "${MOD}/validations/master_data.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
اعتبارسنجی داده پایه و هویت.

قاعده هویت (طبق طراحی V3 که این بخش را درست حل کرده بود):
  nationality پیش‌فرض «ایرانی».
  کد ملی فقط برای ایرانی اعتبارسنجی می‌شود (رقم کنترلی واقعی).
  برای غیرایرانی شماره گذرنامه کافی است و کد ملی الزامی نیست.
پلاک:
  فقط نوع «ایرانی» با الگوی ایرانی سنجیده می‌شود.
  «بین‌المللی» و «گذر موقت» آزادند (مجوز گذر موقت فیلد جدا دارد).
"""
import frappe
from frappe import _
from iran_common.utils import guarded as G

NATIONALITY_IRANIAN = "ایرانی"


def validate_master_party(doc):
    """موبایل و شبا داده پایه — با احترام به کلید خاموش‌کردن سنجه."""
    if doc.get("mobile_no"):
        doc.mobile_no = G.check_mobile(doc.mobile_no, doc.doctype, doc.name)
    if doc.get("sheba"):
        doc.sheba = G.check_sheba(doc.sheba, doc.doctype, doc.name)


def validate_identity(doc, method=None):
    """
    هویت ایرانی/خارجی روی Driver / Customer / Supplier / Contact.
    فیلدها با پیشوند ite_ ساخته می‌شوند تا با فیلدهای استاندارد تداخل نکنند.
    """
    nat = doc.get("ite_nationality") or NATIONALITY_IRANIAN
    nid = doc.get("ite_national_id")
    passport = doc.get("ite_passport_number")

    if nat == NATIONALITY_IRANIAN:
        if nid:
            doc.ite_national_id = G.check_national_id(nid, nat, doc.doctype, doc.name)
    else:
        if not passport:
            frappe.throw(_("برای شخص غیرایرانی، درج «شماره گذرنامه» الزامی است."))
        # کد ملی برای غیرایرانی هرگز اجباری نیست و اعتبارسنجی نمی‌شود.

    if doc.get("mobile_no"):
        doc.mobile_no = G.check_mobile(doc.mobile_no, doc.doctype, doc.name)
    elif doc.get("cell_number"):
        doc.cell_number = G.check_mobile(doc.cell_number, doc.doctype, doc.name)


def validate_plate(doc, method=None):
    """نوع پلاک: ایرانی / بین‌المللی / گذر موقت."""
    ptype = doc.get("ite_plate_type") or "ایرانی"
    plate = doc.get("license_plate") or doc.get("ite_plate_number")
    if plate:
        normalized = G.check_plate(plate, ptype, doc.doctype, doc.name)
        if doc.get("license_plate"):
            doc.license_plate = normalized
        else:
            doc.ite_plate_number = normalized
    if ptype == "گذر موقت" and not doc.get("ite_transit_permit_no"):
        frappe.throw(_("برای پلاک «گذر موقت»، شماره مجوز گذر موقت الزامی است."))
EOF

write_utf8 "${PKG}/fixtures/custom_field.json" << 'EOF'
[
 {"doctype":"Custom Field","name":"Driver-ite_identity_sb","dt":"Driver","fieldname":"ite_identity_sb","fieldtype":"Section Break","label":"هویت","insert_after":"status","module":"Iran Trade"},
 {"doctype":"Custom Field","name":"Driver-ite_nationality","dt":"Driver","fieldname":"ite_nationality","fieldtype":"Select","label":"ملیت","options":"ایرانی\nغیرایرانی","default":"ایرانی","insert_after":"ite_identity_sb","module":"Iran Trade"},
 {"doctype":"Custom Field","name":"Driver-ite_national_id","dt":"Driver","fieldname":"ite_national_id","fieldtype":"Data","label":"کد ملی","depends_on":"eval:doc.ite_nationality=='ایرانی'","insert_after":"ite_nationality","module":"Iran Trade"},
 {"doctype":"Custom Field","name":"Driver-ite_passport_number","dt":"Driver","fieldname":"ite_passport_number","fieldtype":"Data","label":"شماره گذرنامه","depends_on":"eval:doc.ite_nationality!='ایرانی'","insert_after":"ite_national_id","module":"Iran Trade"},

 {"doctype":"Custom Field","name":"Customer-ite_nationality","dt":"Customer","fieldname":"ite_nationality","fieldtype":"Select","label":"ملیت","options":"ایرانی\nغیرایرانی","default":"ایرانی","insert_after":"customer_type","module":"Iran Trade"},
 {"doctype":"Custom Field","name":"Customer-ite_national_id","dt":"Customer","fieldname":"ite_national_id","fieldtype":"Data","label":"کد ملی / شناسه ملی","depends_on":"eval:doc.ite_nationality=='ایرانی'","insert_after":"ite_nationality","module":"Iran Trade"},
 {"doctype":"Custom Field","name":"Customer-ite_passport_number","dt":"Customer","fieldname":"ite_passport_number","fieldtype":"Data","label":"شماره گذرنامه","depends_on":"eval:doc.ite_nationality!='ایرانی'","insert_after":"ite_national_id","module":"Iran Trade"},

 {"doctype":"Custom Field","name":"Supplier-ite_nationality","dt":"Supplier","fieldname":"ite_nationality","fieldtype":"Select","label":"ملیت","options":"ایرانی\nغیرایرانی","default":"ایرانی","insert_after":"supplier_type","module":"Iran Trade"},
 {"doctype":"Custom Field","name":"Supplier-ite_national_id","dt":"Supplier","fieldname":"ite_national_id","fieldtype":"Data","label":"شناسه ملی","depends_on":"eval:doc.ite_nationality=='ایرانی'","insert_after":"ite_nationality","module":"Iran Trade"},
 {"doctype":"Custom Field","name":"Supplier-ite_passport_number","dt":"Supplier","fieldname":"ite_passport_number","fieldtype":"Data","label":"شماره گذرنامه","depends_on":"eval:doc.ite_nationality!='ایرانی'","insert_after":"ite_national_id","module":"Iran Trade"},
 {"doctype":"Custom Field","name":"Supplier-custom_is_factory","dt":"Supplier","fieldname":"custom_is_factory","fieldtype":"Check","label":"کارخانه است","insert_after":"ite_passport_number","module":"Iran Trade"},

 {"doctype":"Custom Field","name":"Contact-ite_nationality","dt":"Contact","fieldname":"ite_nationality","fieldtype":"Select","label":"ملیت","options":"ایرانی\nغیرایرانی","default":"ایرانی","insert_after":"designation","module":"Iran Trade"},
 {"doctype":"Custom Field","name":"Contact-ite_national_id","dt":"Contact","fieldname":"ite_national_id","fieldtype":"Data","label":"کد ملی","depends_on":"eval:doc.ite_nationality=='ایرانی'","insert_after":"ite_nationality","module":"Iran Trade"},
 {"doctype":"Custom Field","name":"Contact-ite_passport_number","dt":"Contact","fieldname":"ite_passport_number","fieldtype":"Data","label":"شماره گذرنامه","depends_on":"eval:doc.ite_nationality!='ایرانی'","insert_after":"ite_national_id","module":"Iran Trade"},

 {"doctype":"Custom Field","name":"Vehicle-ite_plate_type","dt":"Vehicle","fieldname":"ite_plate_type","fieldtype":"Select","label":"نوع پلاک","options":"ایرانی\nبین‌المللی\nگذر موقت","default":"ایرانی","insert_after":"license_plate","module":"Iran Trade"},
 {"doctype":"Custom Field","name":"Vehicle-ite_transit_permit_no","dt":"Vehicle","fieldname":"ite_transit_permit_no","fieldtype":"Data","label":"شماره مجوز گذر موقت","depends_on":"eval:doc.ite_plate_type=='گذر موقت'","insert_after":"ite_plate_type","module":"Iran Trade"},
 {"doctype":"Custom Field","name":"Vehicle-ite_transit_permit_expiry","dt":"Vehicle","fieldname":"ite_transit_permit_expiry","fieldtype":"Date","label":"انقضای مجوز گذر موقت","depends_on":"eval:doc.ite_plate_type=='گذر موقت'","insert_after":"ite_transit_permit_no","module":"Iran Trade"},

 {"doctype":"Custom Field","name":"Item-custom_thickness","dt":"Item","fieldname":"custom_thickness","fieldtype":"Data","label":"ضخامت","insert_after":"stock_uom","module":"Iran Trade"},
 {"doctype":"Custom Field","name":"Item-custom_dimensions","dt":"Item","fieldname":"custom_dimensions","fieldtype":"Data","label":"ابعاد","insert_after":"custom_thickness","module":"Iran Trade"}
]
EOF

write_utf8 "${PKG}/fixtures/border.json" << 'EOF'
[
 {"doctype": "Border", "name": "بازرگان", "border_name": "بازرگان", "province": "آذربایجان غربی", "border_type": "زمینی", "is_active": 1},
 {"doctype": "Border", "name": "مهران", "border_name": "مهران", "province": "ایلام", "border_type": "زمینی", "is_active": 1},
 {"doctype": "Border", "name": "شلمچه", "border_name": "شلمچه", "province": "خوزستان", "border_type": "زمینی", "is_active": 1},
 {"doctype": "Border", "name": "دوغارون", "border_name": "دوغارون", "province": "خراسان رضوی", "border_type": "زمینی", "is_active": 1},
 {"doctype": "Border", "name": "آستارا", "border_name": "آستارا", "province": "گیلان", "border_type": "زمینی", "is_active": 1},
 {"doctype": "Border", "name": "پرویزخان", "border_name": "پرویزخان", "province": "کرمانشاه", "border_type": "زمینی", "is_active": 1}
]
EOF

# =============================================================================
step "3) موتور واحد چندارزی سطح رویداد (MULTI_CURRENCY_DESIGN.txt)"
mkdir -p "${MOD}/doctype/treasury_settings"; : > "${MOD}/doctype/treasury_settings/__init__.py"
write_utf8 "${MOD}/doctype/treasury_settings/treasury_settings.json" << 'EOF'
{
 "actions": [], "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType",
 "engine": "InnoDB", "issingle": 1,
 "field_order": ["company_currency", "default_usd_to_irr_rate", "approved_payment_ceiling", "notes"],
 "fields": [
  {"default": "IRR", "fieldname": "company_currency", "fieldtype": "Link", "label": "ارز شرکت", "options": "Currency", "reqd": 1},
  {"fieldname": "default_usd_to_irr_rate", "fieldtype": "Float", "label": "نرخ جایگزین دلار به ریال (فقط Fallback)", "precision": "9"},
  {"fieldname": "approved_payment_ceiling", "fieldtype": "Currency", "label": "سقف پرداخت تأییدشده خزانه"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "یادداشت"}
 ],
 "links": [], "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Trade", "name": "Treasury Settings", "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "read": 1, "write": 1, "role": "System Manager"},
  {"read": 1, "write": 1, "role": "Financial Manager"},
  {"read": 1, "write": 1, "role": "Treasury User"},
  {"read": 1, "role": "Finance Supervisor"}
 ],
 "sort_field": "modified", "sort_order": "DESC", "track_changes": 1
}
EOF
write_utf8 "${MOD}/doctype/treasury_settings/treasury_settings.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
from frappe.model.document import Document


class TreasurySettings(Document):
    def validate(self):
        if self.default_usd_to_irr_rate is not None and float(self.default_usd_to_irr_rate or 0) < 0:
            frappe.throw("نرخ جایگزین نمی‌تواند منفی باشد.")
EOF

write_utf8 "${MOD}/utils/fx.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
موتور واحد چندارزی — «سطح رویداد»، نه سطح پرونده.

پیاده‌سازی مستقیم mid-phases-v3/MULTI_CURRENCY_DESIGN.txt:

  بلوک FX هر رویداد مالی:
    transaction_currency, company_currency, conversion_rate (precision 9),
    transaction_amount, base_amount, posting_date, rate_source, rate_locked

  ترتیب واکشی نرخ (resolve_rate):
    1) ارز مبدأ == ارز مقصد            → 1.0 ، منبع «ارز یکسان»
    2) Currency Exchange با date <= posting_date (جدیدترین)
    3) Treasury Settings.default_usd_to_irr_rate (فقط USD→IRR)
    4) در غیر این صورت throw — هیچ نرخ حدسی و هیچ نرخ صفر پذیرفته نیست.

  تغییرناپذیری:
    rate_locked=1 ⇒ تغییر نرخ با خطا رد می‌شود.
    Submit ⇒ rate_locked=1 خودکار.
    سند تاریخی هرگز نرخ روز را دوباره نمی‌خواند.
    هیچ GL Entry دستی ساخته نمی‌شود؛ سود/زیان تسعیر بر عهده ERPNext است.
"""
import frappe
from frappe import _
from frappe.utils import flt, getdate, nowdate

SRC_SAME = "ارز یکسان"
SRC_EXCHANGE = "نرخ رسمی ارز"
SRC_TREASURY = "تنظیمات خزانه (جایگزین)"
SRC_MANUAL = "دستی"


def company_currency():
    cur = frappe.db.get_single_value("Treasury Settings", "company_currency")
    return cur or "IRR"


def resolve_rate(from_currency, to_currency=None, posting_date=None):
    """برمی‌گرداند: (rate: float, source: str)"""
    to_currency = to_currency or company_currency()
    posting_date = getdate(posting_date or nowdate())

    if not from_currency:
        frappe.throw(_("ارز رویداد مشخص نشده است."))

    if from_currency == to_currency:
        return 1.0, SRC_SAME

    row = frappe.db.sql(
        """SELECT exchange_rate FROM `tabCurrency Exchange`
           WHERE from_currency=%s AND to_currency=%s AND date <= %s
           ORDER BY date DESC LIMIT 1""",
        (from_currency, to_currency, posting_date),
        as_dict=True,
    )
    if row and flt(row[0].exchange_rate) > 0:
        return flt(row[0].exchange_rate), SRC_EXCHANGE

    if from_currency == "USD" and to_currency == "IRR":
        fb = flt(frappe.db.get_single_value("Treasury Settings", "default_usd_to_irr_rate"))
        if fb > 0:
            return fb, SRC_TREASURY

    frappe.throw(
        _("نرخ تبدیل «{0}» به «{1}» در تاریخ {2} یافت نشد. لطفاً نرخ رسمی ارز را ثبت کنید.")
        .format(from_currency, to_currency, posting_date)
    )


def apply_fx(row, amount_field="amount", base_field="base_amount",
             currency_field="transaction_currency", rate_field="conversion_rate",
             source_field="rate_source", locked_field="rate_locked",
             posting_date=None, parent_locked=False):
    """
    بلوک FX یک رویداد را حل و منجمد می‌کند.
    هرگز نرخ سند قفل‌شده را بازنویسی نمی‌کند.
    """
    cur = row.get(currency_field) or company_currency()
    row.set(currency_field, cur)
    if hasattr(row, "company_currency"):
        row.set("company_currency", company_currency())

    locked = bool(row.get(locked_field)) or bool(parent_locked)
    existing_rate = flt(row.get(rate_field))

    if locked:
        if existing_rate <= 0:
            frappe.throw(_("نرخ تبدیل قفل‌شده نمی‌تواند صفر باشد."))
    else:
        if existing_rate > 0 and (row.get(source_field) == SRC_MANUAL):
            pass  # نرخ دستی کاربر محترم شمرده می‌شود
        else:
            rate, src = resolve_rate(cur, company_currency(), posting_date)
            row.set(rate_field, rate)
            row.set(source_field, src)
            existing_rate = rate

    row.set(base_field, flt(flt(row.get(amount_field)) * flt(row.get(rate_field)), 2))
    return row.get(base_field)


def guard_rate_change(doc, locked_field="rate_locked", rate_field="conversion_rate"):
    """اگر نرخ قفل است، هرگونه تغییر نرخ رد می‌شود."""
    if doc.is_new():
        return
    if not doc.get(locked_field):
        return
    before = frappe.db.get_value(doc.doctype, doc.name, rate_field)
    if before is not None and flt(before) != flt(doc.get(rate_field)):
        frappe.throw(
            _("نرخ تبدیل این سند قفل شده است و قابل تغییر نیست. برای اصلاح، سند را ابطال و اصلاحیه ثبت کنید.")
        )


def lock_rates(doc, rows_field=None, locked_field="rate_locked"):
    """در لحظه Submit، نرخ همه رویدادها منجمد می‌شود."""
    doc.set(locked_field, 1)
    if rows_field:
        for r in doc.get(rows_field) or []:
            r.set(locked_field, 1)


@frappe.whitelist()
def get_rate_preview(from_currency, posting_date=None):
    """پیش‌نمایش نرخ برای کلاینت — کلاینت هرگز خودش محاسبه نمی‌کند."""
    if not frappe.has_permission("Treasury Settings", "read"):
        frappe.throw(_("دسترسی لازم را ندارید."))
    rate, src = resolve_rate(from_currency, company_currency(), posting_date)
    return {"rate": rate, "source": src, "company_currency": company_currency()}
EOF

# =============================================================================
step "4) ثبت hooks (بلوک نشانه‌دار SCRIPT03) — ادغام، نه بازنویسی"
python3 - "$PKG" << 'PYEOF'
import io, os, re, sys
pkg = sys.argv[1]
p = os.path.join(pkg, "hooks.py")
src = io.open(p, encoding="utf-8").read()
S, E = "# --- SCRIPT03_HOOKS_START ---", "# --- SCRIPT03_HOOKS_END ---"
if "# --- SCRIPT02_HOOKS_START ---" not in src:
    raise SystemExit("ABORT: anchor SCRIPT02_HOOKS_START not found in hooks.py")
src = re.sub(re.escape(S) + r".*?" + re.escape(E), "", src, flags=re.S)
block = S + '''
_ite_events = globals().get("doc_events", {}) or {}
for _dt in ("Driver", "Customer", "Supplier", "Contact"):
    _ite_events.setdefault(_dt, {})
    _h = _ite_events[_dt].get("validate")
    _fn = "iran_trade_erp.iran_trade.validations.master_data.validate_identity"
    if _h is None:
        _ite_events[_dt]["validate"] = _fn
    elif isinstance(_h, list):
        if _fn not in _h:
            _h.append(_fn)
    elif _h != _fn:
        _ite_events[_dt]["validate"] = [_h, _fn]

_ite_events.setdefault("Vehicle", {})
_vfn = "iran_trade_erp.iran_trade.validations.master_data.validate_plate"
_vh = _ite_events["Vehicle"].get("validate")
if _vh is None:
    _ite_events["Vehicle"]["validate"] = _vfn
elif isinstance(_vh, list):
    if _vfn not in _vh:
        _vh.append(_vfn)
elif _vh != _vfn:
    _ite_events["Vehicle"]["validate"] = [_vh, _vfn]

doc_events = _ite_events

fixtures = (globals().get("fixtures", []) or []) + [
    {"dt": "Custom Field", "filters": [["module", "=", "Iran Trade"]]},
    {"dt": "Border"},
]
''' + E + "\n"
src = src.rstrip() + "\n\n" + block
io.open(p, "w", encoding="utf-8").write(src)
print("hooks.py SCRIPT03 block written")
PYEOF

# ترجمه‌های این فاز — الحاقی و Idempotent
python3 - "$PKG" << 'PYEOF'
import io, os, sys
pkg = sys.argv[1]
p = os.path.join(pkg, "translations", "fa.csv")
rows = [
    "Border,مرز,", "Carrier,باربری,", "Customs Broker,ترخیص‌کار,",
    "Border Representative,نماینده مرز,", "Treasury Settings,تنظیمات خزانه,",
]
cur = io.open(p, encoding="utf-8").read() if os.path.exists(p) else ""
have = set(l.split(",")[0] for l in cur.splitlines() if l.strip())
add = [r for r in rows if r.split(",")[0] not in have]
if add:
    io.open(p, "a", encoding="utf-8").write("\n".join(add) + "\n")
print("fa.csv rows added:", len(add))
PYEOF

step "5) migrate + اعمال fixtureها"
bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache

# =============================================================================
step "6) Verify داخلی — اجرای واقعی با داده عددی"
write_utf8 "${PKG}/verify_script03.py" << 'EOF'
# -*- coding: utf-8 -*-
import frappe
from frappe.utils import flt


def run():
    passed = failed = 0

    def chk(t, c):
        nonlocal passed, failed
        if c:
            passed += 1; print("  [PASS] " + t)
        else:
            failed += 1; print("  [FAIL] " + t)

    for dt in ("Border", "Carrier", "Customs Broker", "Border Representative", "Treasury Settings"):
        chk("DocType ساخته شد: " + dt, frappe.db.count("DocType", {"name": dt}) == 1)

    chk("۶ مرز واقعی ایران بارگذاری شد", frappe.db.count("Border") >= 6)

    for dt, fn in (("Driver", "ite_nationality"), ("Customer", "ite_nationality"),
                   ("Supplier", "ite_nationality"), ("Contact", "ite_nationality"),
                   ("Vehicle", "ite_plate_type"), ("Supplier", "custom_is_factory")):
        chk("فیلد سفارشی {0}.{1}".format(dt, fn),
            frappe.db.exists("Custom Field", {"dt": dt, "fieldname": fn}) is not None)

    # برچسب فارسی برای هر فیلد جدید
    missing = frappe.get_all("Custom Field",
                             filters={"module": "Iran Trade", "label": ["in", ["", None]]},
                             pluck="name")
    chk("همه فیلدهای جدید برچسب فارسی دارند", not missing)

    # --- موتور ارز: سناریوهای S1..S6 ---
    from iran_trade_erp.iran_trade.utils import fx

    ts = frappe.get_single("Treasury Settings")
    ts.company_currency = "IRR"
    ts.default_usd_to_irr_rate = 600000
    ts.flags.ignore_permissions = True
    ts.save(ignore_permissions=True)
    frappe.db.commit()
    frappe.clear_cache()

    r, s = fx.resolve_rate("IRR", "IRR", "2026-01-01")
    chk("S1 ریالی: نرخ ۱ و منبع «ارز یکسان»", r == 1.0 and s == fx.SRC_SAME)

    r, s = fx.resolve_rate("USD", "IRR", "2026-01-01")
    chk("S2 دلاری: Fallback خزانه استفاده شد", flt(r) == 600000.0 and s == fx.SRC_TREASURY)

    # نرخ رسمی باید بر Fallback مقدم باشد
    if not frappe.db.exists("Currency Exchange", {"from_currency": "USD", "to_currency": "IRR", "date": "2025-12-01"}):
        ce = frappe.new_doc("Currency Exchange")
        ce.from_currency = "USD"; ce.to_currency = "IRR"
        ce.date = "2025-12-01"; ce.exchange_rate = 550000
        ce.flags.ignore_permissions = True
        ce.insert(ignore_permissions=True)
        frappe.db.commit()
    r, s = fx.resolve_rate("USD", "IRR", "2026-01-01")
    chk("S2b نرخ رسمی ارز بر Fallback مقدم است", flt(r) == 550000.0 and s == fx.SRC_EXCHANGE)

    # سناریوی منفی: ارز بدون نرخ باید throw کند (هرگز صفر/حدس)
    blocked = False
    try:
        fx.resolve_rate("EUR", "IRR", "2026-01-01")
    except Exception:
        blocked = True
    chk("S-neg ارز بدون نرخ ⇒ خطای صریح (بدون نرخ حدسی)", blocked)

    # S3 ترکیبی: دو ردیف با دو ارز در یک سند
    class Row(dict):
        def get(self, k, d=None): return dict.get(self, k, d)
        def set(self, k, v): self[k] = v

    r1 = Row(transaction_currency="IRR", amount=1000000)
    r2 = Row(transaction_currency="USD", amount=100)
    b1 = fx.apply_fx(r1, posting_date="2026-01-01")
    b2 = fx.apply_fx(r2, posting_date="2026-01-01")
    chk("S3 ترکیبی: پایه ریالی درست", flt(b1) == 1000000.0)
    chk("S3 ترکیبی: پایه دلاری درست", flt(b2) == 55000000.0)
    chk("S3 جمع پایه صحیح", flt(b1 + b2) == 56000000.0)

    # S5 تاریخی: نرخ جدید امروز، سند دیروز نباید عوض شود
    r3 = Row(transaction_currency="USD", amount=10, conversion_rate=500000,
             rate_locked=1, rate_source=fx.SRC_EXCHANGE)
    b3 = fx.apply_fx(r3, posting_date="2026-01-01")
    chk("S5 سند قفل‌شده نرخ روز را نمی‌خواند", flt(b3) == 5000000.0)

    print("\n  Passed: %d | Failed: %d" % (passed, failed))
    if failed:
        raise Exception("verify_script03 FAILED: %d" % failed)
    return "OK"
EOF

bench --site "$SITE_NAME" execute iran_trade_erp.verify_script03.run

cat <<FINAL

============================================================
 script-03.sh با موفقیت تمام شد
------------------------------------------------------------
 داده پایه : Border / Carrier / Customs Broker / Border Rep.
 هویت      : ایرانی/غیرایرانی روی Driver/Customer/Supplier/Contact
 پلاک      : ایرانی / بین‌المللی / گذر موقت (سنجه فقط برای ایرانی)
 ارز       : موتور واحد سطح رویداد + Treasury Settings (فقط Fallback)
 گام بعدی  : bash script-04.sh
============================================================
FINAL
