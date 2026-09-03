#!/usr/bin/env bash
# =============================================================================
# setup_realign_gate.sh — FINAL GATE (after phase 4, single script)
# ERPNext v15 / Frappe v15 / Bench 5.31
#
# ✅ REAL FIX 1: ویزارد — در Frappe v15، frappe.is_setup_complete() از جدول
#                Installed Application می‌خواند (نه System Settings).
#                پس پرچم‌های frappe و erpnext را به 1 می‌بریم.
# ✅ REAL FIX 2: Navbar — باگ شناخته‌شدهٔ Frappe v15 (نصب Docker) که Toolbar
#                خودکار ساخته نمی‌شود؛ با app_include_js + ensure_toolbar.js
#                برای همیشه درست می‌شود (همان workaround کنسول، ولی خودکار).
# ✅ Administrator مقدس.
# ✅ Transit قبل از Company.
#
# استفاده:
#   nano ~/frappe-bench/setup_realign_gate.sh
#   chmod +x ~/frappe-bench/setup_realign_gate.sh
#   ~/frappe-bench/setup_realign_gate.sh
# =============================================================================
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=utf-8

export SITE_NAME="transport-dev.local"
export BENCH_DIR="${HOME}/frappe-bench"
export BASE_APP="ir_base"
export APP="transport_ir"
export PKG="${BENCH_DIR}/apps/${APP}/${APP}"
export MOD="${PKG}/iran_transport"
export NOW_TS="$(date '+%Y-%m-%d %H:%M:%S').000000"
export HOOKS="${PKG}/hooks.py"

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

# ─── preflight ───
[[ -d "$BENCH_DIR" ]] || err "Bench not found: $BENCH_DIR"
[[ -d "$BENCH_DIR/sites/$SITE_NAME" ]] || err "site $SITE_NAME missing — run phases 1-3 first"
[[ -f "${MOD}/doctype/border/border.json" ]] || err "Phase 4 artifacts missing — run phase 4 first"
cd "$BENCH_DIR"

INSTALLED_APPS="$(bench --site "$SITE_NAME" list-apps 2>/dev/null || true)"
for required_app in "frappe" "erpnext" "$BASE_APP" "$APP"; do
  if ! echo "$INSTALLED_APPS" | grep -qE "^${required_app}([[:space:]]|$)"; then
    err "App '${required_app}' is NOT installed on site ${SITE_NAME}."
  fi
done
log "preflight: all 4 apps installed"

if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "bench already running — skip bench start"
else
  nohup bench start >>/tmp/bench-realign.log 2>&1 &
  echo $! >/tmp/bench-realign.pid
  log "bench start pid=$(cat /tmp/bench-realign.pid)"
  sleep 12
fi

# =============================================================================
# 0) secrets (خارج از Git)
# =============================================================================
step "0) secrets management (outside Git)"

if [[ ! -f "secrets.env" ]]; then
write_utf8 "secrets.env" << 'EOF'
COMPANY_NAME="شرکت بازرگانی ایران"
COMPANY_ABBR="IRBCO"
DEFAULT_CURRENCY="IRR"
FISCAL_YEAR_START="2026-03-21"
FISCAL_YEAR_END="2027-03-20"

CEO_EMAIL="ceo@irbco.local"
CEO_PASSWORD="ChangeMe_CEO_1405"
CEO_FULL_NAME="مدیرعامل"

FIN_MGR_EMAIL="fin.mgr@irbco.local"
FIN_MGR_PASSWORD="ChangeMe_FinMgr_1405"
FIN_MGR_FULL_NAME="مدیر مالی"

FIN_SUP_EMAIL="ehsan.nahalparvar@irbco.local"
FIN_SUP_PASSWORD="ChangeMe_FinSup_1405"
FIN_SUP_FULL_NAME="احسان نهال‌پرور"

FIN_USER_EMAIL="faezeh.heydari@irbco.local"
FIN_USER_PASSWORD="ChangeMe_FinUser_1405"
FIN_USER_FULL_NAME="فائزه حیدری"

LEGAL_EMAIL="pouya.soleimani@irbco.local"
LEGAL_PASSWORD="ChangeMe_Legal_1405"
LEGAL_FULL_NAME="پویا سلیمانی"

TREASURY_EMAIL="atieh.alaei@irbco.local"
TREASURY_PASSWORD="ChangeMe_Treasury_1405"
TREASURY_FULL_NAME="عطیه اعلایی"

RECEIV_EMAIL="zahra.mirzaei@irbco.local"
RECEIV_PASSWORD="ChangeMe_Receiv_1405"
RECEIV_FULL_NAME="زهرا میرزایی"

TRANS_SUP_EMAIL="najmeh.afrashtehpour@irbco.local"
TRANS_SUP_PASSWORD="ChangeMe_TransSup_1405"
TRANS_SUP_FULL_NAME="نجمه افراشته‌پور"

TRANS_PUR_EMAIL="amini@irbco.local"
TRANS_PUR_PASSWORD="ChangeMe_TransPur_1405"
TRANS_PUR_FULL_NAME="خانم امینی"

TRANS_SAL_EMAIL="mohaddeseh.enayati@irbco.local"
TRANS_SAL_PASSWORD="ChangeMe_TransSal_1405"
TRANS_SAL_FULL_NAME="محدثه عنایتی"

CUSTOMS_EMAIL="mohammadi@irbco.local"
CUSTOMS_PASSWORD="ChangeMe_Customs_1405"
CUSTOMS_FULL_NAME="آقای محمدی"

SIGNER_EMAIL="saeed.yousefi@irbco.local"
SIGNER_PASSWORD="ChangeMe_Signer_1405"
SIGNER_FULL_NAME="سعید یوسفی"
EOF
  warn "secrets.env created — EDIT PASSWORDS BEFORE PRODUCTION"
fi

if [[ ! -f "secrets.env.template" ]]; then
write_utf8 "secrets.env.template" << 'EOF'
COMPANY_NAME="شرکت بازرگانی ایران"
COMPANY_ABBR="IRBCO"
DEFAULT_CURRENCY="IRR"
FISCAL_YEAR_START="2026-03-21"
FISCAL_YEAR_END="2027-03-20"
CEO_EMAIL="ceo@irbco.local"
CEO_PASSWORD="CHANGE_ME"
CEO_FULL_NAME="مدیرعامل"
FIN_MGR_EMAIL="fin.mgr@irbco.local"
FIN_MGR_PASSWORD="CHANGE_ME"
FIN_MGR_FULL_NAME="مدیر مالی"
FIN_SUP_EMAIL="ehsan.nahalparvar@irbco.local"
FIN_SUP_PASSWORD="CHANGE_ME"
FIN_SUP_FULL_NAME="احسان نهال‌پرور"
FIN_USER_EMAIL="faezeh.heydari@irbco.local"
FIN_USER_PASSWORD="CHANGE_ME"
FIN_USER_FULL_NAME="فائزه حیدری"
LEGAL_EMAIL="pouya.soleimani@irbco.local"
LEGAL_PASSWORD="CHANGE_ME"
LEGAL_FULL_NAME="پویا سلیمانی"
TREASURY_EMAIL="atieh.alaei@irbco.local"
TREASURY_PASSWORD="CHANGE_ME"
TREASURY_FULL_NAME="عطیه اعلایی"
RECEIV_EMAIL="zahra.mirzaei@irbco.local"
RECEIV_PASSWORD="CHANGE_ME"
RECEIV_FULL_NAME="زهرا میرزایی"
TRANS_SUP_EMAIL="najmeh.afrashtehpour@irbco.local"
TRANS_SUP_PASSWORD="CHANGE_ME"
TRANS_SUP_FULL_NAME="نجمه افراشته‌پور"
TRANS_PUR_EMAIL="amini@irbco.local"
TRANS_PUR_PASSWORD="CHANGE_ME"
TRANS_PUR_FULL_NAME="خانم امینی"
TRANS_SAL_EMAIL="mohaddeseh.enayati@irbco.local"
TRANS_SAL_PASSWORD="CHANGE_ME"
TRANS_SAL_FULL_NAME="محدثه عنایتی"
CUSTOMS_EMAIL="mohammadi@irbco.local"
CUSTOMS_PASSWORD="CHANGE_ME"
CUSTOMS_FULL_NAME="آقای محمدی"
SIGNER_EMAIL="saeed.yousefi@irbco.local"
SIGNER_PASSWORD="CHANGE_ME"
SIGNER_FULL_NAME="سعید یوسفی"
EOF
  log "secrets.env.template created"
fi

touch .gitignore
for pat in "secrets.env" "*.pyc" "__pycache__/" "*.log" "archive/" "sites/*/private/" "sites/*/public/files/"; do
  if ! grep -qxF "$pat" .gitignore; then echo "$pat" >> .gitignore; fi
done
log ".gitignore updated (secrets.env EXCLUDED)"

# =============================================================================
# 1) docs housekeeping
# =============================================================================
step "1) docs housekeeping"

write_utf8 "apps/${APP}/DEVELOPMENT_RULES.md" << 'EOF'
# DEVELOPMENT_RULES — transport_ir

## هویت و ویزارد
- Administrator مقدس است.
- ویزارد با `Installed Application.is_setup_complete=1` برای frappe و erpnext کشته می‌شود
  (این همان gate واقعی `frappe.is_setup_complete()` در Frappe v15 است، نه System Settings).
- Company defaults با ۳ روش (API + SQL + Global Defaults) ست می‌شود.

## Navbar (نوار بالا)
- باگ شناخته‌شدهٔ Frappe v15: گاهی Toolbar خودکار ساخته نمی‌شود (نصب Docker).
- راه‌حل دائمی: `public/js/ensure_toolbar.js` + `app_include_js` در hooks.
- هرگز دستی در کنسول Toolbar نساز؛ این فایل خودش انجام می‌دهد.

## اصول طلایی
- File-First؛ Idempotent؛ No Console؛ No drop-site.
- English fieldnames، Persian labels.
- یکتایی داده در validate پایتون (نه unique DB).
- Workspace: name/label/title انگلیسی؛ فارسی از Translation.
- Transit قبل از Company.
- External Systems فقط از Adapter/Service.
EOF

write_utf8 "apps/${APP}/BACKLOG.md" << 'EOF'
# BACKLOG — transport_ir

## Out of core for now
- Interactive transport map (Phase 7+)
- UI history browser for duplicates (Phase 7)
- Chat / organizational messaging
- External BI / Power BI
- Generic form/report/dashboard builder
- Full archive/OCR/AI
- WhatsApp (permanently out)

## Golden rules
1. Deferred features must not block future design.
2. External communication only via adapter/service.
3. No field/relation locks that prevent future growth.
EOF
log "docs written"

# =============================================================================
# 2) حذف فایل‌های force-sync قدیمی
# =============================================================================
step "2) remove legacy force-sync files"

for f in \
  "${MOD}/setup_workspace_phase4.py" \
  "${MOD}/verify_phase4.py" \
  "${MOD}/verify_phase3.py" \
  "${MOD}/import_doctype.py" \
  ; do
  if [[ -f "$f" ]]; then
    rm -f "$f"
    log "removed: $f"
  fi
done

# =============================================================================
# 3) fixtures — Property Setter
# =============================================================================
step "3) property_setter.json"

mkdir -p "${PKG}/fixtures"

write_utf8 "${PKG}/fixtures/property_setter.json" << EOF
[
 {"doctype": "Property Setter", "name": "Vehicle-make-hidden", "doctype_or_field": "DocField", "doc_type": "Vehicle", "field_name": "make", "property": "hidden", "property_type": "Check", "value": "1", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Vehicle-make-reqd", "doctype_or_field": "DocField", "doc_type": "Vehicle", "field_name": "make", "property": "reqd", "property_type": "Check", "value": "0", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Vehicle-model-hidden", "doctype_or_field": "DocField", "doc_type": "Vehicle", "field_name": "model", "property": "hidden", "property_type": "Check", "value": "1", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Vehicle-model-reqd", "doctype_or_field": "DocField", "doc_type": "Vehicle", "field_name": "model", "property": "reqd", "property_type": "Check", "value": "0", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Vehicle-last_odometer-hidden", "doctype_or_field": "DocField", "doc_type": "Vehicle", "field_name": "last_odometer", "property": "hidden", "property_type": "Check", "value": "1", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Vehicle-last_odometer-reqd", "doctype_or_field": "DocField", "doc_type": "Vehicle", "field_name": "last_odometer", "property": "reqd", "property_type": "Check", "value": "0", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Vehicle-fuel_type-hidden", "doctype_or_field": "DocField", "doc_type": "Vehicle", "field_name": "fuel_type", "property": "hidden", "property_type": "Check", "value": "1", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Vehicle-fuel_type-reqd", "doctype_or_field": "DocField", "doc_type": "Vehicle", "field_name": "fuel_type", "property": "reqd", "property_type": "Check", "value": "0", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Vehicle-fuel_uom-hidden", "doctype_or_field": "DocField", "doc_type": "Vehicle", "field_name": "fuel_uom", "property": "hidden", "property_type": "Check", "value": "1", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Vehicle-fuel_uom-reqd", "doctype_or_field": "DocField", "doc_type": "Vehicle", "field_name": "fuel_uom", "property": "reqd", "property_type": "Check", "value": "0", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Vehicle-acquisition_date-hidden", "doctype_or_field": "DocField", "doc_type": "Vehicle", "field_name": "acquisition_date", "property": "hidden", "property_type": "Check", "value": "1", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Vehicle-uom-hidden", "doctype_or_field": "DocField", "doc_type": "Vehicle", "field_name": "uom", "property": "hidden", "property_type": "Check", "value": "1", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Vehicle-carbon_check_date-hidden", "doctype_or_field": "DocField", "doc_type": "Vehicle", "field_name": "carbon_check_date", "property": "hidden", "property_type": "Check", "value": "1", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Vehicle-license_plate-reqd", "doctype_or_field": "DocField", "doc_type": "Vehicle", "field_name": "license_plate", "property": "reqd", "property_type": "Check", "value": "1", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Vehicle-quick_entry", "doctype_or_field": "DocType", "doc_type": "Vehicle", "property": "quick_entry", "property_type": "Check", "value": "0", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Driver-quick_entry", "doctype_or_field": "DocType", "doc_type": "Driver", "property": "quick_entry", "property_type": "Check", "value": "0", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Driver-full_name-in_list_view", "doctype_or_field": "DocField", "doc_type": "Driver", "field_name": "full_name", "property": "in_list_view", "property_type": "Check", "value": "1", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Driver-cell_number-in_list_view", "doctype_or_field": "DocField", "doc_type": "Driver", "field_name": "cell_number", "property": "in_list_view", "property_type": "Check", "value": "1", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Property Setter", "name": "Driver-status-in_list_view", "doctype_or_field": "DocField", "doc_type": "Driver", "field_name": "status", "property": "in_list_view", "property_type": "Check", "value": "1", "module": "Iran Transport", "modified": "${NOW_TS}"}
]
EOF

# =============================================================================
# 4) fixtures — Custom Field
# =============================================================================
step "4) custom_field.json"

write_utf8 "${PKG}/fixtures/custom_field.json" << EOF
[
 {"doctype": "Custom Field", "name": "Driver-custom_section_ir", "dt": "Driver", "fieldname": "custom_section_ir", "fieldtype": "Section Break", "label": "اطلاعات ایران", "insert_after": "cell_number", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Driver-custom_national_id", "dt": "Driver", "fieldname": "custom_national_id", "fieldtype": "Data", "label": "کد ملی", "insert_after": "custom_section_ir", "in_standard_filter": 1, "in_list_view": 1, "unique": 0, "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Driver-custom_is_smart_driver", "dt": "Driver", "fieldname": "custom_is_smart_driver", "fieldtype": "Check", "label": "هوشمندی راننده", "insert_after": "custom_national_id", "in_list_view": 1, "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Driver-custom_smart_card_no", "dt": "Driver", "fieldname": "custom_smart_card_no", "fieldtype": "Data", "label": "شماره کارت هوشمند (هوشمندی)", "insert_after": "custom_is_smart_driver", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Driver-custom_license_number", "dt": "Driver", "fieldname": "custom_license_number", "fieldtype": "Data", "label": "شماره گواهینامه", "insert_after": "custom_smart_card_no", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Driver-custom_license_expiry", "dt": "Driver", "fieldname": "custom_license_expiry", "fieldtype": "Date", "label": "انقضای گواهینامه", "insert_after": "custom_license_number", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Driver-custom_sheba", "dt": "Driver", "fieldname": "custom_sheba", "fieldtype": "Data", "label": "شماره شبا", "insert_after": "custom_license_expiry", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Driver-custom_bank_name", "dt": "Driver", "fieldname": "custom_bank_name", "fieldtype": "Data", "label": "نام بانک", "insert_after": "custom_sheba", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Driver-custom_vehicle", "dt": "Driver", "fieldname": "custom_vehicle", "fieldtype": "Link", "label": "خودرو اختصاصی", "options": "Vehicle", "insert_after": "custom_bank_name", "in_list_view": 1, "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Driver-custom_plate_number", "dt": "Driver", "fieldname": "custom_plate_number", "fieldtype": "Data", "label": "پلاک", "insert_after": "custom_vehicle", "fetch_from": "custom_vehicle.license_plate", "read_only": 1, "in_list_view": 1, "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Vehicle-custom_vehicle_type", "dt": "Vehicle", "fieldname": "custom_vehicle_type", "fieldtype": "Select", "label": "نوع خودرو", "options": "کامیون\\nتریلی\\nخاور\\nوانت\\nسایر", "insert_after": "license_plate", "in_list_view": 1, "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Vehicle-custom_capacity_ton", "dt": "Vehicle", "fieldname": "custom_capacity_ton", "fieldtype": "Float", "label": "ظرفیت (تن)", "insert_after": "custom_vehicle_type", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Vehicle-custom_insurance_expiry", "dt": "Vehicle", "fieldname": "custom_insurance_expiry", "fieldtype": "Date", "label": "انقضای بیمه", "insert_after": "custom_capacity_ton", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Vehicle-custom_inspection_expiry", "dt": "Vehicle", "fieldname": "custom_inspection_expiry", "fieldtype": "Date", "label": "انقضای معاینه فنی", "insert_after": "custom_insurance_expiry", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Vehicle-custom_is_active", "dt": "Vehicle", "fieldname": "custom_is_active", "fieldtype": "Check", "label": "فعال", "default": "1", "insert_after": "custom_inspection_expiry", "in_list_view": 1, "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Vehicle-custom_docs", "dt": "Vehicle", "fieldname": "custom_docs", "fieldtype": "Attach", "label": "مدارک خودرو", "insert_after": "custom_is_active", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Item-custom_thickness_mm", "dt": "Item", "fieldname": "custom_thickness_mm", "fieldtype": "Float", "label": "ضخامت (میلی‌متر)", "insert_after": "description", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Item-custom_dimensions", "dt": "Item", "fieldname": "custom_dimensions", "fieldtype": "Data", "label": "ابعاد", "insert_after": "custom_thickness_mm", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Item-custom_cargo_description", "dt": "Item", "fieldname": "custom_cargo_description", "fieldtype": "Small Text", "label": "شرح کالا", "insert_after": "custom_dimensions", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Customer-custom_preferred_border", "dt": "Customer", "fieldname": "custom_preferred_border", "fieldtype": "Link", "label": "مرز ترجیحی", "options": "Border", "insert_after": "customer_name", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Supplier-custom_is_factory", "dt": "Supplier", "fieldname": "custom_is_factory", "fieldtype": "Check", "label": "کارخانه است", "default": "0", "insert_after": "supplier_name", "module": "Iran Transport", "modified": "${NOW_TS}"},
 {"doctype": "Custom Field", "name": "Supplier-custom_loading_city", "dt": "Supplier", "fieldname": "custom_loading_city", "fieldtype": "Data", "label": "شهر بارگیری", "insert_after": "custom_is_factory", "module": "Iran Transport", "modified": "${NOW_TS}"}
]
EOF

# =============================================================================
# 5) fixtures — translation + border
# =============================================================================
step "5) translation.json + border.json"

write_utf8 "${PKG}/fixtures/translation.json" << EOF
[
 {"doctype": "Translation", "name": "fa-workspace-iran-transport", "language": "fa", "source_text": "Iran Transport", "translated_text": "حمل و نقل", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-border", "language": "fa", "source_text": "Border", "translated_text": "مرز", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-carrier", "language": "fa", "source_text": "Carrier", "translated_text": "باربری", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-customs-broker", "language": "fa", "source_text": "Customs Broker", "translated_text": "ترخیص‌کار", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-border-representative", "language": "fa", "source_text": "Border Representative", "translated_text": "نماینده مرز", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-driver", "language": "fa", "source_text": "Driver", "translated_text": "راننده", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-vehicle", "language": "fa", "source_text": "Vehicle", "translated_text": "خودرو", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-role-ceo", "language": "fa", "source_text": "CEO", "translated_text": "مدیرعامل", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-role-fin-mgr", "language": "fa", "source_text": "Financial Manager", "translated_text": "مدیر مالی", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-role-fin-sup", "language": "fa", "source_text": "Finance Supervisor", "translated_text": "سرپرست مالی", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-role-fin-user", "language": "fa", "source_text": "Finance User", "translated_text": "کارشناس مالی", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-role-legal", "language": "fa", "source_text": "Legal Reviewer", "translated_text": "بررسی حقوقی", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-role-treasury", "language": "fa", "source_text": "Treasury User", "translated_text": "خزانه", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-role-receiv", "language": "fa", "source_text": "Receivables User", "translated_text": "وصول مطالبات", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-role-trans-sup", "language": "fa", "source_text": "Transport Supervisor", "translated_text": "سرپرست حمل", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-role-trans-pur", "language": "fa", "source_text": "Transport User - Purchase", "translated_text": "کارشناس حمل خرید", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-role-trans-sal", "language": "fa", "source_text": "Transport User - Sales", "translated_text": "کارشناس حمل فروش", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-role-customs", "language": "fa", "source_text": "Customs Officer", "translated_text": "کارشناس گمرک", "modified": "${NOW_TS}"},
 {"doctype": "Translation", "name": "fa-role-signer", "language": "fa", "source_text": "Document Signer", "translated_text": "امضاکننده سند", "modified": "${NOW_TS}"}
]
EOF

write_utf8 "${PKG}/fixtures/border.json" << EOF
[
 {"doctype": "Border", "name": "بازرگان", "border_name": "بازرگان", "province": "آذربایجان غربی", "border_type": "زمینی", "is_active": 1, "modified": "${NOW_TS}"},
 {"doctype": "Border", "name": "مهران", "border_name": "مهران", "province": "ایلام", "border_type": "زمینی", "is_active": 1, "modified": "${NOW_TS}"},
 {"doctype": "Border", "name": "شلمچه", "border_name": "شلمچه", "province": "خوزستان", "border_type": "زمینی", "is_active": 1, "modified": "${NOW_TS}"},
 {"doctype": "Border", "name": "دوغارون", "border_name": "دوغارون", "province": "خراسان رضوی", "border_type": "زمینی", "is_active": 1, "modified": "${NOW_TS}"},
 {"doctype": "Border", "name": "آستارا", "border_name": "آستارا", "province": "گیلان", "border_type": "زمینی", "is_active": 1, "modified": "${NOW_TS}"},
 {"doctype": "Border", "name": "پرویزخان", "border_name": "پرویزخان", "province": "کرمانشاه", "border_type": "زمینی", "is_active": 1, "modified": "${NOW_TS}"}
]
EOF

# =============================================================================
# 6) patch DocType JSONs + workspace JSON
# =============================================================================
step "6) patch DocTypes + workspace"

python3 << 'PYEOF'
import json, os
PKG = os.environ["PKG"]
MOD = os.environ["MOD"]
now = os.environ["NOW_TS"]

def patch_doctype(path, patches):
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    doc.update(patches)
    doc["modified"] = now
    finance_roles = [
        "Finance User", "Finance Supervisor", "Financial Manager",
        "Legal Reviewer", "Treasury User", "Receivables User"
    ]
    existing = {p["role"]: p for p in doc.get("permissions", [])}
    for role in finance_roles:
        if role in existing:
            existing[role]["read"] = 1
            existing[role]["report"] = 1
        else:
            doc.setdefault("permissions", []).append({"role": role, "read": 1, "report": 1})
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    print(f"  patched: {path}")

for dt, patches in [
    ("border", {"allow_rename": 1}),
    ("carrier", {"allow_rename": 1}),
    ("customs_broker", {"allow_rename": 1}),
    ("border_representative", {
        "allow_rename": 1,
        "autoname": "format:{representative_name}-{border}",
        "naming_rule": "Expression",
    }),
]:
    p = f"{MOD}/doctype/{dt}/{dt}.json"
    if os.path.exists(p):
        patch_doctype(p, patches)
    else:
        print(f"  SKIP missing: {p}")

ws = {
    "charts": [],
    "content": '[{"id":"card_master","type":"card","data":{"card_name":"اطلاعات پایه","col":4}}]',
    "creation": now,
    "doctype": "Workspace",
    "for_user": "",
    "hide_custom": 0,
    "icon": "truck",
    "is_default": 0,
    "is_hidden": 0,
    "is_standard": 1,
    "label": "Iran Transport",
    "modified": now,
    "modified_by": "Administrator",
    "module": "Iran Transport",
    "name": "Iran Transport",
    "number_cards": [],
    "owner": "Administrator",
    "parent_page": "",
    "public": 1,
    "quick_lists": [],
    "restrict_to_domain": "",
    "roles": [],
    "sequence_id": 20.0,
    "shortcuts": [],
    "title": "Iran Transport",
    "links": [
        {"type": "Card Break", "label": "اطلاعات پایه", "link_count": 6, "hidden": 0, "onboard": 0, "is_query_report": 0},
        {"type": "Link", "label": "Border", "link_type": "DocType", "link_to": "Border", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""},
        {"type": "Link", "label": "Carrier", "link_type": "DocType", "link_to": "Carrier", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""},
        {"type": "Link", "label": "Customs Broker", "link_type": "DocType", "link_to": "Customs Broker", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""},
        {"type": "Link", "label": "Border Representative", "link_type": "DocType", "link_to": "Border Representative", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""},
        {"type": "Link", "label": "Driver", "link_type": "DocType", "link_to": "Driver", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""},
        {"type": "Link", "label": "Vehicle", "link_type": "DocType", "link_to": "Vehicle", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""},
    ],
}
ws_path = f"{MOD}/workspace/iran_transport/iran_transport.json"
os.makedirs(os.path.dirname(ws_path), exist_ok=True)
with open(ws_path, "w", encoding="utf-8") as f:
    json.dump(ws, f, ensure_ascii=False, indent=1)
print("workspace JSON written")
PYEOF

# =============================================================================
# 7) hooks.py (با app_include_js برای Navbar)
# =============================================================================
step "7) hooks.py"

python3 << 'PYEOF'
import os, re
p = os.environ["HOOKS"]
with open(p, encoding="utf-8") as f:
    src = f.read()
src = re.sub(r"# --- REALIGN_GATE_HOOKS_START ---.*?# --- REALIGN_GATE_HOOKS_END ---\n?", "", src, flags=re.DOTALL)
src = re.sub(r"# --- PHASE4_HOOKS_START ---.*?# --- PHASE4_HOOKS_END ---\n?", "", src, flags=re.DOTALL)
with open(p, "w", encoding="utf-8") as f:
    f.write(src)
print("hooks cleaned")
PYEOF

cat >> "$HOOKS" << 'EOF'

# --- REALIGN_GATE_HOOKS_START ---
fixtures = [
    {"dt": "Property Setter", "filters": [["module", "=", "Iran Transport"]]},
    {"dt": "Custom Field",    "filters": [["module", "=", "Iran Transport"]]},
    {"dt": "Border",          "filters": [["is_active", "=", 1]]},
    {"dt": "Translation",     "filters": [["language", "=", "fa"]]},
]

doc_events = {
    "Driver":  {"validate": "transport_ir.iran_transport.validations.master_data.validate_driver"},
    "Vehicle": {"validate": "transport_ir.iran_transport.validations.master_data.validate_vehicle"},
    "Carrier": {"validate": "transport_ir.iran_transport.validations.master_data.validate_master_mobile"},
    "Customs Broker": {"validate": "transport_ir.iran_transport.validations.master_data.validate_master_mobile"},
    "Border Representative": {"validate": "transport_ir.iran_transport.validations.master_data.validate_master_mobile"},
}

# REAL FIX 2: navbar ensure (باگ Frappe v15 که Toolbar خودکار ساخته نمی‌شود)
app_include_js = ["/assets/transport_ir/js/ensure_toolbar.js"]
# --- REALIGN_GATE_HOOKS_END ---
EOF
log "hooks.py updated (fixtures + doc_events + app_include_js)"

# =============================================================================
# 8) python modules
# =============================================================================
step "8) python modules"

mkdir -p "${MOD}/validations"
: > "${MOD}/validations/__init__.py"

write_utf8 "${MOD}/validations/master_data.py" << 'EOF'
"""Master data validations."""
import frappe
from frappe import _
from ir_base.utils.validators import (
    persian_to_english_digits,
    validate_iranian_national_id,
    validate_iran_mobile,
    validate_sheba,
    normalize_plate,
)


def _get_existing_title(doctype, name):
    if not name:
        return ""
    try:
        doc = frappe.get_doc(doctype, name)
        for field in ("full_name", "carrier_name", "broker_name",
                      "representative_name", "license_plate", "border_name"):
            if doc.get(field):
                return doc.get(field)
    except Exception:
        pass
    return name


def validate_master_mobile(doc, method=None):
    if doc.get("mobile_no"):
        doc.mobile_no = persian_to_english_digits(doc.mobile_no).strip()
        validate_iran_mobile(doc.mobile_no)
    if doc.get("sheba"):
        doc.sheba = persian_to_english_digits(doc.sheba).strip().upper().replace(" ", "").replace("-", "")
        validate_sheba(doc.sheba)


def validate_driver(doc, method=None):
    if doc.get("custom_national_id"):
        doc.custom_national_id = persian_to_english_digits(doc.custom_national_id).strip()
        validate_iranian_national_id(doc.custom_national_id)
        dup = frappe.db.exists("Driver", {
            "custom_national_id": doc.custom_national_id,
            "name": ["!=", doc.name],
        })
        if dup:
            title = _get_existing_title("Driver", dup)
            frappe.throw(_("کد ملی تکراری است. راننده موجود: {0}").format(title or dup))
    if doc.get("cell_number"):
        doc.cell_number = persian_to_english_digits(doc.cell_number).strip()
        validate_iran_mobile(doc.cell_number)
    if doc.get("custom_sheba"):
        doc.custom_sheba = persian_to_english_digits(doc.custom_sheba).strip().upper().replace(" ", "").replace("-", "")
        validate_sheba(doc.custom_sheba)


def validate_vehicle(doc, method=None):
    if doc.get("license_plate"):
        doc.license_plate = normalize_plate(doc.license_plate)
        dup = frappe.db.exists("Vehicle", {
            "license_plate": doc.license_plate,
            "name": ["!=", doc.name],
        })
        if dup:
            title = _get_existing_title("Vehicle", dup)
            frappe.throw(_("پلاک تکراری است. خودرو موجود: {0}").format(title or dup))
EOF

# =============================================================================
# 8b) REAL FIX 2 — public/js/ensure_toolbar.js (Navbar دائمی)
# =============================================================================
step "8b) public/js/ensure_toolbar.js (navbar ensure)"

mkdir -p "${PKG}/public/js"

write_utf8 "${PKG}/public/js/ensure_toolbar.js" << 'EOF'
/* transport_ir — ensure the Desk top navbar exists.
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
			if (navbar_in_dom()) return;                       // navbar هست؛ کاری نکن
			if (!frappe.ui || !frappe.ui.toolbar || !frappe.ui.toolbar.Toolbar) return;
			if (frappe.ui.toolbar_obj) return;                 // قبلاً ساخته شده
			frappe.ui.toolbar_obj = new frappe.ui.toolbar.Toolbar();
			console.log("[transport_ir] top navbar ensured");
		} catch (e) {
			console.warn("[transport_ir] ensure_toolbar failed:", e);
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
log "ensure_toolbar.js written"

# =============================================================================
# 8c) setup_seeds.py — REAL FIX 1: close the TRUE wizard gate
# =============================================================================
write_utf8 "${MOD}/setup_seeds.py" << 'EOF'
"""Seed foundational data.

REAL FIX 1 for Frappe v15 Setup Wizard hijack:

In Frappe v15, `frappe.is_setup_complete()` reads from
`tabInstalled Application.is_setup_complete` for `frappe` and `erpnext` —
NOT from System Settings.setup_complete. If these flags stay 0,
ERPNext's `fin()` shortcut (used when Company already exists) calls
`login_as_first_user(args)` -> session becomes the first seeded user (amini)
instead of Administrator.

Fix: set Installed Application.is_setup_complete = 1 for frappe+erpnext
BEFORE anything else, AND again at the end.
"""
import os
import frappe
from frappe.utils import getdate


USER_ROLE_MAP = {
    "ceo":       ("CEO",                        "CEO_EMAIL",       "CEO_FULL_NAME",       "CEO_PASSWORD"),
    "fin_mgr":   ("Financial Manager",          "FIN_MGR_EMAIL",   "FIN_MGR_FULL_NAME",   "FIN_MGR_PASSWORD"),
    "fin_sup":   ("Finance Supervisor",         "FIN_SUP_EMAIL",   "FIN_SUP_FULL_NAME",   "FIN_SUP_PASSWORD"),
    "fin_user":  ("Finance User",               "FIN_USER_EMAIL",  "FIN_USER_FULL_NAME",  "FIN_USER_PASSWORD"),
    "legal":     ("Legal Reviewer",             "LEGAL_EMAIL",     "LEGAL_FULL_NAME",     "LEGAL_PASSWORD"),
    "treasury":  ("Treasury User",              "TREASURY_EMAIL",  "TREASURY_FULL_NAME",  "TREASURY_PASSWORD"),
    "receiv":    ("Receivables User",           "RECEIV_EMAIL",    "RECEIV_FULL_NAME",    "RECEIV_PASSWORD"),
    "trans_sup": ("Transport Supervisor",       "TRANS_SUP_EMAIL", "TRANS_SUP_FULL_NAME", "TRANS_SUP_PASSWORD"),
    "trans_pur": ("Transport User - Purchase",  "TRANS_PUR_EMAIL", "TRANS_PUR_FULL_NAME", "TRANS_PUR_PASSWORD"),
    "trans_sal": ("Transport User - Sales",     "TRANS_SAL_EMAIL", "TRANS_SAL_FULL_NAME", "TRANS_SAL_PASSWORD"),
    "customs":   ("Customs Officer",            "CUSTOMS_EMAIL",   "CUSTOMS_FULL_NAME",   "CUSTOMS_PASSWORD"),
    "signer":    ("Document Signer",            "SIGNER_EMAIL",    "SIGNER_FULL_NAME",    "SIGNER_PASSWORD"),
}

PROTECTED_USERS = {"Administrator", "Guest"}


def _env(name, default=""):
    return os.environ.get(name, default)


def _get_app_version(app_name):
    """Best-effort version lookup for Installed Application."""
    try:
        if app_name == "frappe":
            return frappe.__version__
        mod = frappe.get_module(app_name)
        return getattr(mod, "__version__", "UNVERSIONED") or "UNVERSIONED"
    except Exception:
        return "UNVERSIONED"


def close_installed_app_gate():
    """REAL FIX 1: flip is_setup_complete=1 for frappe+erpnext in
    tabInstalled Application. This is what frappe.is_setup_complete() reads."""
    for app_name in ("frappe", "erpnext"):
        if frappe.db.exists("Installed Application", {"app_name": app_name}):
            frappe.db.set_value(
                "Installed Application",
                {"app_name": app_name},
                {"is_setup_complete": 1, "has_setup_wizard": 1},
            )
        else:
            frappe.get_doc({
                "doctype": "Installed Application",
                "app_name": app_name,
                "app_version": _get_app_version(app_name),
                "has_setup_wizard": 1,
                "is_setup_complete": 1,
            }).insert(ignore_permissions=True, ignore_if_duplicate=True)
    frappe.db.commit()
    return "Installed Application gate closed (frappe+erpnext is_setup_complete=1)"


def kill_wizard_and_onboarding():
    """Close every layer of the setup wizard gate."""
    # Layer 1: the REAL gate (Installed Application)
    close_installed_app_gate()

    # Layer 2: legacy System Settings flag
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

    # Layer 3: module onboarding tables
    try:
        if frappe.db.exists("DocType", "Module Onboarding"):
            frappe.db.sql("update `tabModule Onboarding` set is_complete=1")
        if frappe.db.exists("DocType", "Onboarding Step"):
            frappe.db.sql("update `tabOnboarding Step` set is_complete=1, is_skipped=1")
    except Exception:
        pass

    frappe.db.commit()
    frappe.clear_cache()
    # Also invalidate the @request_cache cache of frappe.is_setup_complete
    try:
        if hasattr(frappe.is_setup_complete, "cache_clear"):
            frappe.is_setup_complete.cache_clear()
    except Exception:
        pass
    return "wizard killed (Installed Application + System Settings + onboarding)"


def ensure_warehouse_type(name_):
    if frappe.db.exists("Warehouse Type", name_):
        return f"warehouse_type {name_} exists"
    meta = frappe.get_meta("Warehouse Type")
    if meta.autoname and str(meta.autoname).startswith("field:"):
        fieldname = str(meta.autoname).split("field:")[1]
        try:
            frappe.get_doc({"doctype": "Warehouse Type", fieldname: name_}).insert(
                ignore_permissions=True, ignore_links=True)
            return f"warehouse_type {name_} created (field:{fieldname})"
        except Exception:
            if frappe.db.exists("Warehouse Type", name_):
                return f"warehouse_type {name_} exists"
    try:
        frappe.get_doc({"doctype": "Warehouse Type", "name": name_}).insert(
            ignore_permissions=True, ignore_links=True)
        return f"warehouse_type {name_} created (name)"
    except Exception:
        if frappe.db.exists("Warehouse Type", name_):
            return f"warehouse_type {name_} exists"
        if meta.has_field("warehouse_type"):
            frappe.get_doc({"doctype": "Warehouse Type", "warehouse_type": name_}).insert(
                ignore_permissions=True, ignore_links=True)
            return f"warehouse_type {name_} created (warehouse_type field)"
    return f"warehouse_type {name_} failed"


def drop_stale_unique_index():
    try:
        rows = frappe.db.sql(
            "show index from `tabDriver` where Column_name='custom_national_id' and Non_unique=0",
            as_dict=True,
        )
        if rows:
            idx = rows[0].get("Key_name")
            if idx and idx != "PRIMARY":
                frappe.db.sql(f"alter table `tabDriver` drop index `{idx}`")
                return f"dropped stale unique index {idx} on Driver.custom_national_id"
        return "no stale unique index on Driver.custom_national_id"
    except Exception as e:
        return f"index check warning: {e}"


def cleanup_wizard_residue(keep_company):
    removed = []
    for row in frappe.get_all("Company", fields=["name"]):
        if row.name == keep_company:
            continue
        has_tx = (
            frappe.db.count("GL Entry", {"company": row.name})
            or frappe.db.count("Sales Invoice", {"company": row.name})
            or frappe.db.count("Purchase Invoice", {"company": row.name})
            or frappe.db.count("Stock Entry", {"company": row.name})
        )
        if has_tx:
            removed.append(f"KEEP {row.name} (has transactions)")
            continue
        try:
            frappe.delete_doc("Company", row.name, force=1, ignore_permissions=True)
            removed.append(f"deleted wizard company {row.name}")
        except Exception as e:
            removed.append(f"could not delete {row.name}: {e}")
    frappe.db.commit()
    return "wizard residue: " + ("; ".join(removed) if removed else "none found")


def ensure_company(company_name, abbr, currency):
    if frappe.db.exists("Currency", currency):
        frappe.db.set_value("Currency", currency, "enabled", 1)
    ensure_warehouse_type("Transit")
    frappe.db.commit()
    if frappe.db.exists("Company", company_name):
        return f"company exists: {company_name}"
    doc = frappe.get_doc({
        "doctype": "Company",
        "company_name": company_name,
        "abbr": abbr,
        "default_currency": currency,
        "country": "Iran",
        "chart_of_accounts": "Standard",
    })
    doc.insert(ignore_permissions=True)
    return f"company created: {company_name}"


def set_company_defaults(company_name, currency):
    """Set company defaults via 3 methods to bypass Frappe v15 cache."""
    frappe.defaults.set_global_default("company", company_name)
    frappe.defaults.set_global_default("currency", currency)
    frappe.defaults.set_global_default("country", "Iran")
    frappe.defaults.set_global_default("fiscal_year", "1405")

    for key, val in [
        ("company", company_name),
        ("Company", company_name),
        ("currency", currency),
        ("country", "Iran"),
        ("fiscal_year", "1405"),
    ]:
        frappe.db.sql(
            "DELETE FROM `tabDefaultValue` WHERE defkey = %s AND parent = '__global'",
            key,
        )
        frappe.db.sql(
            """INSERT INTO `tabDefaultValue`
                (name, creation, modified, modified_by, owner,
                 defkey, defvalue, parent, parenttype, parentfield)
               VALUES (%s, NOW(), NOW(), 'Administrator', 'Administrator',
                       %s, %s, '__global', 'Control', 'system_defaults')""",
            (frappe.generate_hash(), key, val),
        )

    if frappe.db.exists("DocType", "Global Defaults"):
        try:
            gd = frappe.get_single("Global Defaults")
            if gd.meta.has_field("default_company"):
                gd.default_company = company_name
            if gd.meta.has_field("default_currency"):
                gd.default_currency = currency
            if gd.meta.has_field("country"):
                gd.country = "Iran"
            if gd.meta.has_field("current_fiscal_year") and frappe.db.exists("Fiscal Year", "1405"):
                gd.current_fiscal_year = "1405"
            gd.flags.ignore_permissions = True
            gd.save(ignore_permissions=True)
        except Exception as e:
            print(f"Global Defaults save warning: {e}")

    frappe.db.commit()
    frappe.clear_cache()
    resolved = (
        frappe.defaults.get_global_default("company")
        or frappe.db.get_default("company")
    )
    return f"company defaults set -> {resolved}"


def ensure_fiscal_year(company_name, start, end):
    s, e = getdate(start), getdate(end)
    for row in frappe.get_all("Fiscal Year", fields=["name"], filters={"disabled": 0}):
        if row.name == "1405":
            continue
        try:
            o = frappe.get_doc("Fiscal Year", row.name)
            if o.year_start_date and o.year_end_date and not o.companies:
                if not (e < getdate(o.year_start_date) or s > getdate(o.year_end_date)):
                    o.disabled = 1
                    o.save(ignore_permissions=True)
        except Exception:
            pass

    if not frappe.db.exists("Fiscal Year", "1405"):
        fy = frappe.get_doc({
            "doctype": "Fiscal Year",
            "year": "1405",
            "year_start_date": start,
            "year_end_date": end,
            "is_short_year": 0,
            "disabled": 0,
            "companies": [{"company": company_name}],
        })
        fy.insert(ignore_permissions=True)
    else:
        fy = frappe.get_doc("Fiscal Year", "1405")
        if fy.disabled:
            fy.disabled = 0
            fy.save(ignore_permissions=True)

    existing = frappe.db.sql(
        """SELECT company FROM `tabFiscal Year Company`
           WHERE parent = '1405' AND parenttype = 'Fiscal Year' AND company = %s""",
        company_name,
    )
    if not existing:
        frappe.db.sql(
            """INSERT INTO `tabFiscal Year Company`
                (name, creation, modified, modified_by, owner,
                 parent, parentfield, parenttype, company)
               VALUES (%s, NOW(), NOW(), 'Administrator', 'Administrator',
                       '1405', 'companies', 'Fiscal Year', %s)""",
            (frappe.generate_hash(), company_name),
        )
    frappe.db.commit()
    return "fiscal_year 1405 ensured + company linked via SQL"


def restore_administrator():
    if not frappe.db.exists("User", "Administrator"):
        frappe.throw("User Administrator missing")
    admin = frappe.get_doc("User", "Administrator")
    changed = False
    if not admin.enabled:
        admin.enabled = 1; changed = True
    if admin.user_type != "System User":
        admin.user_type = "System User"; changed = True
    if admin.module_profile:
        admin.module_profile = ""; changed = True
    if admin.block_modules:
        admin.set("block_modules", []); changed = True
    if not any(r.role == "System Manager" for r in admin.roles):
        admin.append("roles", {"role": "System Manager"}); changed = True
    if changed:
        admin.flags.ignore_permissions = True
        admin.save(ignore_permissions=True)
    for emp in frappe.get_all("Employee", filters={"user_id": "Administrator"}, fields=["name"]):
        frappe.db.set_value("Employee", emp.name, "user_id", "")
    frappe.db.commit()
    return "Administrator healthy"


def ensure_workspace_label():
    if not frappe.db.exists("Workspace", "Iran Transport"):
        return "workspace not in DB yet"
    ws = frappe.get_doc("Workspace", "Iran Transport")
    changed = False
    if ws.label != "Iran Transport":
        ws.label = "Iran Transport"; changed = True
    if ws.title != "Iran Transport":
        ws.title = "Iran Transport"; changed = True
    if changed:
        ws.save(ignore_permissions=True)
    return "workspace label ensured"


def ensure_users():
    results = []
    for key, (role, email_env, name_env, pwd_env) in USER_ROLE_MAP.items():
        email = _env(email_env)
        full_name = _env(name_env, key)
        pwd = _env(pwd_env, f"ChangeMe_{key}_1405")
        if not email:
            results.append(f"SKIP {key}")
            continue
        if email in PROTECTED_USERS or email.lower() == "administrator":
            results.append(f"REFUSED to touch protected: {email}")
            continue
        if not frappe.db.exists("User", email):
            frappe.get_doc({
                "doctype": "User",
                "email": email,
                "first_name": full_name,
                "user_type": "System User",
                "send_welcome_email": 0,
                "enabled": 1,
                "language": "fa",
                "time_zone": "Asia/Tehran",
                "new_password": pwd,
                "roles": [{"role": role}],
            }).insert(ignore_permissions=True)
            results.append(f"user created: {email} ({role})")
        else:
            u = frappe.get_doc("User", email)
            u.user_type = "System User"
            u.enabled = 1
            u.language = "fa"
            u.time_zone = "Asia/Tehran"
            u.add_roles(role)
            if pwd and not pwd.startswith("ChangeMe") and pwd != "CHANGE_ME":
                u.new_password = pwd
            u.save(ignore_permissions=True)
            results.append(f"user updated: {email} ({role})")
    return results


def seed_all():
    results = []

    # ── STEP 1: CLOSE THE REAL WIZARD GATE FIRST ──
    # This is the key fix. Without it, fin() -> login_as_first_user hijacks session.
    results.append(kill_wizard_and_onboarding())

    # ── STEP 2: Administrator health ──
    results.append(restore_administrator())

    # ── STEP 3: Transit BEFORE Company ──
    results.append(ensure_warehouse_type("Transit"))
    frappe.db.commit()

    company_name = _env("COMPANY_NAME", "شرکت بازرگانی ایران")
    abbr = _env("COMPANY_ABBR", "IRBCO")
    currency = _env("DEFAULT_CURRENCY", "IRR")

    # ── STEP 4: Company (no hijack risk because wizard gate already closed) ──
    results.append(ensure_company(company_name, abbr, currency))
    results.append(cleanup_wizard_residue(company_name))
    results.append(drop_stale_unique_index())

    # ── STEP 5: Users ──
    results.extend(ensure_users())

    # ── STEP 6: Fiscal Year ──
    try:
        results.append(ensure_fiscal_year(
            company_name,
            _env("FISCAL_YEAR_START", "2026-03-21"),
            _env("FISCAL_YEAR_END", "2027-03-20"),
        ))
    except Exception as e:
        results.append(f"FY warning: {e}")

    results.append(ensure_workspace_label())
    results.append(set_company_defaults(company_name, currency))
    results.append(restore_administrator())

    # ── STEP 7: CLOSE THE WIZARD GATE AGAIN (idempotent safety net) ──
    results.append(kill_wizard_and_onboarding())

    frappe.db.commit()
    frappe.clear_cache()
    return {"results": results}
EOF

# =============================================================================
# 8d) verify_realign.py — checks the REAL gate + navbar assets
# =============================================================================
write_utf8 "${MOD}/verify_realign.py" << 'EOF'
"""Verification with multi-path company resolution + real gate check + navbar."""
import os
import frappe


def resolve_company():
    names = []
    try:
        names.append(frappe.defaults.get_global_default("company"))
    except Exception:
        pass
    names.append(frappe.db.get_default("company"))
    if frappe.db.exists("DocType", "Global Defaults"):
        try:
            names.append(frappe.db.get_singles_value("Global Defaults", "default_company"))
        except Exception:
            pass
    try:
        names.append(frappe.db.get_value("Company", {"abbr": "IRBCO"}, "name"))
    except Exception:
        pass
    if frappe.db.exists("Company", "شرکت بازرگانی ایران"):
        names.append("شرکت بازرگانی ایران")
    for name in names:
        if name and frappe.db.exists("Company", name):
            return name
    return frappe.db.get_value("Company", {}, "name")


def verify_realign():
    passed, failed = [], []

    def ok(name, cond, detail=""):
        (passed if cond else failed).append(name)
        prefix = "✓" if cond else "✗"
        print(f"{prefix} {name}" + (f" — {detail}" if detail else ""))

    # ── THE REAL GATE CHECK ──
    try:
        setup_ok = bool(frappe.is_setup_complete())
    except Exception as e:
        setup_ok = False
        print(f"  ! is_setup_complete() raised: {e}")
    ok("frappe.is_setup_complete() == True (REAL gate)", setup_ok)

    ia_flags = frappe.get_all(
        "Installed Application",
        filters={"app_name": ["in", ["frappe", "erpnext"]]},
        fields=["app_name", "is_setup_complete"],
    )
    ok(
        "Installed Application.is_setup_complete == 1 for frappe+erpnext",
        bool(ia_flags) and all(f.is_setup_complete for f in ia_flags),
        str(ia_flags),
    )

    ok(
        "setup_complete == 1 (legacy flag)",
        str(frappe.db.get_single_value("System Settings", "setup_complete")) == "1",
    )

    # ── NAVBAR (REAL FIX 2) server-side checks ──
    js_path = os.path.join(frappe.get_app_path("transport_ir"), "public", "js", "ensure_toolbar.js")
    ok("ensure_toolbar.js exists in app", os.path.exists(js_path), js_path)
    hooked = frappe.get_hooks("app_include_js") or []
    ok(
        "ensure_toolbar.js hooked via app_include_js",
        any("ensure_toolbar" in str(h) for h in hooked),
        str([h for h in hooked if "ensure_toolbar" in str(h)]),
    )

    admin = frappe.get_doc("User", "Administrator")
    ok("admin has System Manager", any(r.role == "System Manager" for r in admin.roles))
    ok("admin no blocked modules", not admin.block_modules)
    ok("admin not linked to Employee",
       not frappe.db.exists("Employee", {"user_id": "Administrator"}))
    ok("operational users have NO System Manager",
       not frappe.get_all("Has Role", filters={
           "role": "System Manager",
           "parent": ["not in", ["Administrator"]],
           "parenttype": "User",
       }))

    company = resolve_company()
    ok("default company set", bool(company), str(company))
    companies = frappe.get_all("Company", fields=["name"])
    ok("exactly one company (no wizard residue)", len(companies) == 1,
       f"found={[c.name for c in companies]}")
    if company:
        ok("company has root accounts",
           frappe.db.count("Account", {"company": company, "is_group": 1}) > 0)

    ok("FY 1405 exists", bool(frappe.db.exists("Fiscal Year", "1405")))
    if frappe.db.exists("Fiscal Year", "1405"):
        fy = frappe.get_doc("Fiscal Year", "1405")
        ok("FY 1405 not disabled", not fy.disabled)
        fy_companies = [c.company for c in (fy.companies or [])]
        ok("FY 1405 linked to company",
           bool(company) and company in fy_companies,
           f"companies={fy_companies}")

    for ps, expected in [
        ("Vehicle-make-hidden", "1"),
        ("Vehicle-model-hidden", "1"),
        ("Vehicle-fuel_type-hidden", "1"),
        ("Vehicle-fuel_uom-hidden", "1"),
        ("Vehicle-license_plate-reqd", "1"),
        ("Vehicle-make-reqd", "0"),
        ("Vehicle-fuel_type-reqd", "0"),
        ("Vehicle-quick_entry", "0"),
        ("Driver-quick_entry", "0"),
    ]:
        val = frappe.db.get_value("Property Setter", ps, "value") \
            if frappe.db.exists("Property Setter", ps) else None
        ok(f"PS {ps}={expected}", str(val) == expected)

    for dt, fn in [
        ("Driver", "custom_national_id"),
        ("Driver", "custom_is_smart_driver"),
        ("Driver", "custom_license_number"),
        ("Driver", "custom_license_expiry"),
        ("Driver", "custom_vehicle"),
        ("Driver", "custom_plate_number"),
        ("Vehicle", "custom_vehicle_type"),
        ("Vehicle", "custom_capacity_ton"),
        ("Vehicle", "custom_docs"),
        ("Item", "custom_thickness_mm"),
        ("Customer", "custom_preferred_border"),
        ("Supplier", "custom_is_factory"),
    ]:
        ok(f"CF {dt}.{fn}",
           bool(frappe.db.exists("Custom Field", {"dt": dt, "fieldname": fn})))

    if frappe.db.exists("Custom Field", {"dt": "Driver", "fieldname": "custom_national_id"}):
        cf = frappe.get_doc("Custom Field", {"dt": "Driver", "fieldname": "custom_national_id"})
        ok("national_id NOT db-unique", not cf.unique)

    for dt in ["Border", "Carrier", "Customs Broker", "Border Representative"]:
        ok(f"{dt} allow_rename=1", bool(frappe.get_meta(dt).allow_rename))
    br_autoname = str(frappe.get_meta("Border Representative").autoname or "")
    ok("Border Rep autoname format", "format:" in br_autoname, br_autoname)

    finance = [
        "Finance User", "Finance Supervisor", "Financial Manager",
        "Legal Reviewer", "Treasury User", "Receivables User",
    ]
    for dt in ["Border", "Carrier", "Customs Broker", "Border Representative"]:
        perm_roles = {p.role for p in frappe.get_meta(dt).permissions if p.read}
        missing = [r for r in finance if r not in perm_roles]
        ok(f"{dt} finance read", not missing, f"missing: {missing}" if missing else "")

    ok("border count == 6", frappe.db.count("Border") == 6)
    ok("fa translation: Iran Transport → حمل و نقل",
       bool(frappe.db.exists("Translation", {
           "source_text": "Iran Transport",
           "language": "fa",
           "translated_text": "حمل و نقل",
       })))

    if frappe.db.exists("Workspace", "Iran Transport"):
        ws = frappe.get_doc("Workspace", "Iran Transport")
        ok("workspace label EN", ws.label == "Iran Transport")
        ok("workspace title EN", ws.title == "Iran Transport")
        ok("workspace public", ws.public == 1)
        ok("workspace links >= 7", len(ws.links or []) >= 7)
    else:
        ok("workspace exists", False)

    users = frappe.get_all("User", filters={"email": ["like", "%@irbco.local"]},
                           fields=["name", "user_type", "enabled"])
    ok("12 users exist", len(users) == 12)
    if users:
        ok("all users System User", all(u.user_type == "System User" for u in users))
        ok("all users enabled", all(u.enabled for u in users))
    expected_emails = [
        "ehsan.nahalparvar@irbco.local",
        "faezeh.heydari@irbco.local",
        "najmeh.afrashtehpour@irbco.local",
        "amini@irbco.local",
        "mohaddeseh.enayati@irbco.local",
        "mohammadi@irbco.local",
    ]
    actual_emails = {u.name for u in users}
    for em in expected_emails:
        ok(f"business user {em}", em in actual_emails)

    from ir_base.utils.validators import (
        validate_iranian_national_id, validate_iran_mobile, validate_sheba,
    )
    for fn, bad in [
        (validate_iranian_national_id, "1234567890"),
        (validate_iranian_national_id, "0000000000"),
        (validate_iran_mobile, "08123456789"),
        (validate_sheba, "IR000000000000000000000000"),
    ]:
        try:
            fn(bad)
            ok(f"validator rejects {bad}", False)
        except Exception:
            ok(f"validator rejects {bad}", True)

    import importlib
    for m in ["carrier", "customs_broker", "border_representative"]:
        try:
            importlib.import_module(f"transport_ir.iran_transport.doctype.{m}.{m}")
            ok(f"controller {m} imports", True)
        except Exception as e:
            ok(f"controller {m} imports", False, str(e))
    try:
        from transport_ir.iran_transport.validations.master_data import validate_master_mobile
        ok("validate_master_mobile importable", True)
    except Exception as e:
        ok("validate_master_mobile importable", False, str(e))

    print(f"\n{'='*60}")
    print(f"  Passed: {len(passed)}  |  Failed: {len(failed)}")
    print(f"{'='*60}")
    if failed:
        for f in failed:
            print(f"  ✗ {f}")
        print("\n❌ Foundation NOT ready — fix failures before phase 5")
        frappe.throw("Realign verification failed: " + " | ".join(failed))
    else:
        print("\n✓ ALL CHECKS PASSED — foundation ready for phase 5")
    return {"passed": len(passed), "failed": len(failed)}
EOF

# =============================================================================
# 9) migrate + kill wizard + seed_all + verify + assets check
# =============================================================================
step "9) migrate + kill wizard + seed_all + verify"

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache

# Belt-and-suspenders: close the gate from bash too, before any browser can reach it.
bench --site "$SITE_NAME" execute transport_ir.iran_transport.setup_seeds.kill_wizard_and_onboarding
log "wizard killed (Installed Application + System Settings)"

set -a; source "secrets.env"; set +a
log "secrets loaded"

bench --site "$SITE_NAME" execute transport_ir.iran_transport.setup_seeds.seed_all
bench --site "$SITE_NAME" clear-cache
bench --site "$SITE_NAME" execute transport_ir.iran_transport.verify_realign.verify_realign

# REAL FIX 2: اگر symlink assets برای فایل جدید نیست، یک‌بار build کن
if [[ ! -e "sites/assets/${APP}/js/ensure_toolbar.js" ]]; then
  warn "assets symlink missing for ensure_toolbar.js — running bench build --app ${APP} (one-time)"
  bench build --app "${APP}" || warn "bench build failed; run 'bench build --app ${APP}' manually"
else
  log "assets path OK: sites/assets/${APP}/js/ensure_toolbar.js"
fi

# =============================================================================
# 10) git commit + tag
# =============================================================================
step "10) git commit + tag"

for repo in "$BASE_APP" "$APP"; do
  cd "${BENCH_DIR}/apps/${repo}"
  git config user.email >/dev/null 2>&1 || git config user.email "dev@example.com"
  git config user.name  >/dev/null 2>&1 || git config user.name "IR Base Contributors"
  git add -A
  git commit -m "realign-gate: wizard REAL gate closed + navbar ensure_toolbar.js via app_include_js" || warn "nothing to commit in $repo"
  if git tag --list | grep -qxF "foundation-v1"; then git tag -d foundation-v1; fi
  git tag -a foundation-v1 -m "foundation complete — wizard gate closed + navbar ensured — ready for phase 5"
  log "tagged foundation-v1 on $repo"
done

cd "$BENCH_DIR"

step "DONE"
cat <<FINAL

${GREEN}═══════════════════════════════════════════════════════════════${NC}
${GREEN}  REALIGN-GATE COMPLETE — هر دو REAL FIX اعمال شد${NC}
${GREEN}═══════════════════════════════════════════════════════════════${NC}

✓ FIX 1: Installed Application.is_setup_complete = 1 (frappe + erpnext)
  → ویزارد دیگر hijack نمی‌کند (login_as_first_user هرگز اجرا نمی‌شود)
✓ FIX 2: ensure_toolbar.js + app_include_js
  → Navbar (جستجو/زنگ/آواتار) خودکار و دائمی برمی‌گردد؛ بدون کنسول
✓ Company defaults با ۳ روش (API + SQL + Global Defaults)
✓ FY 1405 با SQL به شرکت لینک شد
✓ Administrator مقدس
✓ ۱۲ کاربر عملیاتی ساخته شد

${YELLOW}─────────── چک‌لیست مرورگر ───────────${NC}

 ۱) Logout کامل + Incognito + Ctrl+Shift+R
 ۲) ورود با Administrator
 ۳) Navbar بالا دیده شود (جستجو + زنگ + آواتار) — بدون کنسول!
 ۴) گوشه بالا «Administrator» (نه خانم امینی)
 ۵) دسک بدون ویزارد
 ۶) کلیک «حمل و نقل» → /app/iran-transport
 ۷) /app/company → «شرکت بازرگانی ایران»
 ۸) /app/fiscal-year/1405 → شرکت لینک شده

${GREEN}─────────── گام بعدی ───────────${NC}

 اگر همه سبز: «دروازه سبز شد» → ir_jalali → فاز ۵

FINAL