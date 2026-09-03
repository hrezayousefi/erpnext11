#!/usr/bin/env bash
# =============================================================================
# setup_phase4.sh — Master Data + Workspace force-sync (کاملاً خودکار)
# ERPNext v15 / Frappe v15 | File-First | بدون Wizard | بدون console | idempotent
# =============================================================================
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 PYTHONIOENCODING=utf-8

SITE_NAME="transport-dev.local"
BENCH_DIR="${HOME}/frappe-bench"
APP="transport_ir"
PKG="${BENCH_DIR}/apps/${APP}/${APP}"
MOD="${PKG}/iran_transport"

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

[[ -d "$BENCH_DIR" ]] || err "Bench not found"
[[ -d "${BENCH_DIR}/apps/${APP}" ]] || err "transport_ir not found — run phase 3 first"
cd "$BENCH_DIR"
bench use "$SITE_NAME" 2>/dev/null || true

if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "bench already running"
else
  nohup bench start >>/tmp/bench-start-phase4.log 2>&1 &
  log "bench start pid=$!"; sleep 12
fi

# =============================================================================
# 1) اعتبارسنجی مشترک
# =============================================================================
step "1) validations module"
mkdir -p "${MOD}/validations"
write_utf8 "${MOD}/validations/__init__.py" << 'EOF'
# validations package
EOF
write_utf8 "${MOD}/validations/master_data.py" << 'EOF'
"""Shared master-data validations using ir_base utilities."""
import frappe
from frappe import _
from ir_base.utils.validators import (
    persian_to_english_digits, validate_iranian_national_id,
    validate_iran_mobile, validate_sheba, normalize_plate,
)

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
        dup = frappe.db.exists("Driver", {"custom_national_id": doc.custom_national_id, "name": ["!=", doc.name]})
        if dup:
            frappe.throw(_("کد ملی تکراری است. راننده موجود: {0}").format(dup))
    if doc.get("cell_number"):
        doc.cell_number = persian_to_english_digits(doc.cell_number).strip()
        validate_iran_mobile(doc.cell_number)
    if doc.get("custom_sheba"):
        doc.custom_sheba = persian_to_english_digits(doc.custom_sheba).strip().upper().replace(" ", "").replace("-", "")
        validate_sheba(doc.custom_sheba)

def validate_vehicle(doc, method=None):
    if doc.get("license_plate"):
        doc.license_plate = normalize_plate(doc.license_plate)
        dup = frappe.db.exists("Vehicle", {"license_plate": doc.license_plate, "name": ["!=", doc.name]})
        if dup:
            frappe.throw(_("پلاک تکراری است. خودرو موجود: {0}").format(dup))
EOF

# =============================================================================
# 2) چهار DocType جدید
# =============================================================================
step "2) master DocTypes"
DT="${MOD}/doctype"
for d in border carrier customs_broker border_representative; do
  mkdir -p "${DT}/${d}"; : > "${DT}/${d}/__init__.py"
done

write_utf8 "${DT}/border/border.json" << 'EOF'
{
 "actions": [], "allow_rename": 1, "autoname": "field:border_name", "title_field": "border_name",
 "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["border_name", "province", "border_type", "adjacent_country", "is_active", "notes"],
 "fields": [
  {"fieldname": "border_name", "fieldtype": "Data", "label": "نام مرز", "reqd": 1, "unique": 1, "in_list_view": 1},
  {"fieldname": "province", "fieldtype": "Data", "label": "استان", "in_list_view": 1},
  {"fieldname": "border_type", "fieldtype": "Select", "label": "نوع مرز", "options": "زمینی\nدریایی\nهوایی\nریلی", "default": "زمینی"},
  {"fieldname": "adjacent_country", "fieldtype": "Link", "label": "کشور مقابل", "options": "Country"},
  {"fieldname": "is_active", "fieldtype": "Check", "label": "فعال", "default": 1, "in_list_view": 1},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "توضیحات"}
 ],
 "issingle": 0, "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Transport", "name": "Border", "owner": "Administrator",
 "permissions": [
  {"role": "System Manager", "read": 1, "write": 1, "create": 1, "delete": 1, "report": 1, "export": 1},
  {"role": "Transport Supervisor", "read": 1, "write": 1, "create": 1, "report": 1},
  {"role": "Transport User - Purchase", "read": 1},
  {"role": "Transport User - Sales", "read": 1},
  {"role": "Customs Officer", "read": 1},
  {"role": "CEO", "read": 1, "report": 1}
 ],
 "sort_field": "modified", "sort_order": "DESC", "track_changes": 1
}
EOF
write_utf8 "${DT}/border/border.py" << 'EOF'
from frappe.model.document import Document

class Border(Document):
    pass
EOF
write_utf8 "${DT}/border/test_border.py" << 'EOF'
from frappe.tests.utils import FrappeTestCase

class TestBorder(FrappeTestCase):
    pass
EOF

write_utf8 "${DT}/carrier/carrier.json" << 'EOF'
{
 "actions": [], "autoname": "field:carrier_name", "title_field": "carrier_name",
 "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["carrier_name", "contact_person", "mobile_no", "phone_no", "sheba", "bank_name", "is_active", "notes"],
 "fields": [
  {"fieldname": "carrier_name", "fieldtype": "Data", "label": "نام باربری", "reqd": 1, "unique": 1, "in_list_view": 1},
  {"fieldname": "contact_person", "fieldtype": "Data", "label": "شخص تماس"},
  {"fieldname": "mobile_no", "fieldtype": "Data", "label": "موبایل", "in_list_view": 1},
  {"fieldname": "phone_no", "fieldtype": "Data", "label": "تلفن"},
  {"fieldname": "sheba", "fieldtype": "Data", "label": "شماره شبا"},
  {"fieldname": "bank_name", "fieldtype": "Data", "label": "نام بانک"},
  {"fieldname": "is_active", "fieldtype": "Check", "label": "فعال", "default": 1},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "توضیحات"}
 ],
 "issingle": 0, "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Transport", "name": "Carrier", "owner": "Administrator",
 "permissions": [
  {"role": "System Manager", "read": 1, "write": 1, "create": 1, "delete": 1, "report": 1, "export": 1},
  {"role": "Transport Supervisor", "read": 1, "write": 1, "create": 1, "report": 1},
  {"role": "Transport User - Purchase", "read": 1},
  {"role": "Transport User - Sales", "read": 1},
  {"role": "Financial Manager", "read": 1, "report": 1},
  {"role": "CEO", "read": 1, "report": 1}
 ],
 "sort_field": "modified", "sort_order": "DESC", "track_changes": 1
}
EOF
write_utf8 "${DT}/carrier/carrier.py" << 'EOF'
from frappe.model.document import Document
from transport_ir.iran_transport.validations.master_data import validate_master_mobile

class Carrier(Document):
    def validate(self):
        validate_master_mobile(self)
EOF
write_utf8 "${DT}/carrier/test_carrier.py" << 'EOF'
from frappe.tests.utils import FrappeTestCase

class TestCarrier(FrappeTestCase):
    pass
EOF

write_utf8 "${DT}/customs_broker/customs_broker.json" << 'EOF'
{
 "actions": [], "autoname": "field:broker_name", "title_field": "broker_name",
 "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["broker_name", "contact_person", "mobile_no", "phone_no", "is_active", "notes"],
 "fields": [
  {"fieldname": "broker_name", "fieldtype": "Data", "label": "نام ترخیص‌کار", "reqd": 1, "unique": 1, "in_list_view": 1},
  {"fieldname": "contact_person", "fieldtype": "Data", "label": "شخص تماس"},
  {"fieldname": "mobile_no", "fieldtype": "Data", "label": "موبایل", "in_list_view": 1},
  {"fieldname": "phone_no", "fieldtype": "Data", "label": "تلفن"},
  {"fieldname": "is_active", "fieldtype": "Check", "label": "فعال", "default": 1},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "توضیحات"}
 ],
 "issingle": 0, "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Transport", "name": "Customs Broker", "owner": "Administrator",
 "permissions": [
  {"role": "System Manager", "read": 1, "write": 1, "create": 1, "delete": 1, "report": 1, "export": 1},
  {"role": "Transport Supervisor", "read": 1, "write": 1, "create": 1, "report": 1},
  {"role": "Customs Officer", "read": 1, "write": 1, "create": 1, "report": 1},
  {"role": "CEO", "read": 1, "report": 1}
 ],
 "sort_field": "modified", "sort_order": "DESC", "track_changes": 1
}
EOF
write_utf8 "${DT}/customs_broker/customs_broker.py" << 'EOF'
from frappe.model.document import Document
from transport_ir.iran_transport.validations.master_data import validate_master_mobile

class CustomsBroker(Document):
    def validate(self):
        validate_master_mobile(self)
EOF
write_utf8 "${DT}/customs_broker/test_customs_broker.py" << 'EOF'
from frappe.tests.utils import FrappeTestCase

class TestCustomsBroker(FrappeTestCase):
    pass
EOF

write_utf8 "${DT}/border_representative/border_representative.json" << 'EOF'
{
 "actions": [], "autoname": "field:representative_name", "title_field": "representative_name",
 "creation": "2025-01-01 00:00:00.000000", "doctype": "DocType", "engine": "InnoDB",
 "field_order": ["representative_name", "border", "mobile_no", "phone_no", "is_active", "notes"],
 "fields": [
  {"fieldname": "representative_name", "fieldtype": "Data", "label": "نام نماینده مرز", "reqd": 1, "in_list_view": 1},
  {"fieldname": "border", "fieldtype": "Link", "label": "مرز", "options": "Border", "reqd": 1, "in_list_view": 1},
  {"fieldname": "mobile_no", "fieldtype": "Data", "label": "موبایل", "in_list_view": 1},
  {"fieldname": "phone_no", "fieldtype": "Data", "label": "تلفن"},
  {"fieldname": "is_active", "fieldtype": "Check", "label": "فعال", "default": 1},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "توضیحات"}
 ],
 "issingle": 0, "modified": "2025-01-01 00:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Transport", "name": "Border Representative", "owner": "Administrator",
 "permissions": [
  {"role": "System Manager", "read": 1, "write": 1, "create": 1, "delete": 1, "report": 1, "export": 1},
  {"role": "Transport Supervisor", "read": 1, "write": 1, "create": 1, "report": 1},
  {"role": "Customs Officer", "read": 1, "report": 1},
  {"role": "CEO", "read": 1, "report": 1}
 ],
 "sort_field": "modified", "sort_order": "DESC", "track_changes": 1
}
EOF
write_utf8 "${DT}/border_representative/border_representative.py" << 'EOF'
from frappe.model.document import Document
from transport_ir.iran_transport.validations.master_data import validate_master_mobile

class BorderRepresentative(Document):
    def validate(self):
        validate_master_mobile(self)
EOF
write_utf8 "${DT}/border_representative/test_border_representative.py" << 'EOF'
from frappe.tests.utils import FrappeTestCase

class TestBorderRepresentative(FrappeTestCase):
    pass
EOF

# =============================================================================
# 3) fixtures
# =============================================================================
step "3) fixtures"
mkdir -p "${PKG}/fixtures"
write_utf8 "${PKG}/fixtures/custom_field.json" << 'EOF'
[
 {"doctype": "Custom Field", "name": "Driver-custom_section_ir", "dt": "Driver", "fieldname": "custom_section_ir", "fieldtype": "Section Break", "label": "اطلاعات ایران", "insert_after": "cell_number", "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Driver-custom_national_id", "dt": "Driver", "fieldname": "custom_national_id", "fieldtype": "Data", "label": "کد ملی", "insert_after": "custom_section_ir", "unique": 1, "in_standard_filter": 1, "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Driver-custom_smart_card_no", "dt": "Driver", "fieldname": "custom_smart_card_no", "fieldtype": "Data", "label": "شماره کارت هوشمند", "insert_after": "custom_national_id", "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Driver-custom_sheba", "dt": "Driver", "fieldname": "custom_sheba", "fieldtype": "Data", "label": "شماره شبا", "insert_after": "custom_smart_card_no", "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Driver-custom_bank_name", "dt": "Driver", "fieldname": "custom_bank_name", "fieldtype": "Data", "label": "نام بانک", "insert_after": "custom_sheba", "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Vehicle-custom_vehicle_type", "dt": "Vehicle", "fieldname": "custom_vehicle_type", "fieldtype": "Select", "label": "نوع خودرو", "options": "کامیون\nتریلی\nخاور\nوانت\nسایر", "insert_after": "license_plate", "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Vehicle-custom_capacity_ton", "dt": "Vehicle", "fieldname": "custom_capacity_ton", "fieldtype": "Float", "label": "ظرفیت (تن)", "insert_after": "custom_vehicle_type", "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Vehicle-custom_insurance_expiry", "dt": "Vehicle", "fieldname": "custom_insurance_expiry", "fieldtype": "Date", "label": "انقضای بیمه", "insert_after": "custom_capacity_ton", "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Vehicle-custom_inspection_expiry", "dt": "Vehicle", "fieldname": "custom_inspection_expiry", "fieldtype": "Date", "label": "انقضای معاینه فنی", "insert_after": "custom_insurance_expiry", "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Vehicle-custom_is_active", "dt": "Vehicle", "fieldname": "custom_is_active", "fieldtype": "Check", "label": "فعال", "default": "1", "insert_after": "custom_inspection_expiry", "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Item-custom_thickness_mm", "dt": "Item", "fieldname": "custom_thickness_mm", "fieldtype": "Float", "label": "ضخامت (میلی‌متر)", "insert_after": "description", "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Item-custom_dimensions", "dt": "Item", "fieldname": "custom_dimensions", "fieldtype": "Data", "label": "ابعاد", "insert_after": "custom_thickness_mm", "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Item-custom_cargo_description", "dt": "Item", "fieldname": "custom_cargo_description", "fieldtype": "Small Text", "label": "شرح کالا", "insert_after": "custom_dimensions", "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Customer-custom_preferred_border", "dt": "Customer", "fieldname": "custom_preferred_border", "fieldtype": "Link", "label": "مرز ترجیحی", "options": "Border", "insert_after": "customer_name", "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Supplier-custom_is_factory", "dt": "Supplier", "fieldname": "custom_is_factory", "fieldtype": "Check", "label": "کارخانه است", "default": "0", "insert_after": "supplier_name", "module": "Iran Transport"},
 {"doctype": "Custom Field", "name": "Supplier-custom_loading_city", "dt": "Supplier", "fieldname": "custom_loading_city", "fieldtype": "Data", "label": "شهر بارگیری", "insert_after": "custom_is_factory", "module": "Iran Transport"}
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
python3 -m json.tool "${PKG}/fixtures/custom_field.json" >/dev/null && log "custom_field.json OK"
python3 -m json.tool "${PKG}/fixtures/border.json" >/dev/null && log "border.json OK"

# =============================================================================
# 4) hooks.py
# =============================================================================
step "4) hooks.py"
HOOKS="${PKG}/hooks.py"
if grep -q "PHASE4_HOOKS_START" "$HOOKS"; then
  warn "phase4 hooks already present"
else
cat >> "$HOOKS" << 'EOF'

# --- PHASE4_HOOKS_START ---
fixtures = [
    {"dt": "Custom Field", "filters": [["module", "=", "Iran Transport"]]},
    {"dt": "Border", "filters": [["is_active", "=", 1]]}
]

doc_events = {
    "Driver": {"validate": "transport_ir.iran_transport.validations.master_data.validate_driver"},
    "Vehicle": {"validate": "transport_ir.iran_transport.validations.master_data.validate_vehicle"}
}
# --- PHASE4_HOOKS_END ---
EOF
  log "hooks appended"
fi

# =============================================================================
# 5) Workspace JSON (تک‌منبع حقیقت — content + links)
# =============================================================================
step "5) workspace json"
WS_DIR="${MOD}/workspace/iran_transport"
mkdir -p "$WS_DIR"
write_utf8 "${WS_DIR}/__init__.py" << 'EOF'
# Workspace package
EOF
write_utf8 "${WS_DIR}/iran_transport.json" << 'EOF'
{
 "charts": [],
 "content": "[{\"id\":\"card_master\",\"type\":\"card\",\"data\":{\"card_name\":\"اطلاعات پایه\",\"col\":4}}]",
 "creation": "2025-01-01 00:00:00.000000", "doctype": "Workspace", "for_user": "", "hide_custom": 0,
 "icon": "truck", "is_default": 0, "is_hidden": 0, "is_standard": 1,
 "label": "حمل و نقل", "modified": "2026-03-20 12:00:00.000000", "modified_by": "Administrator",
 "module": "Iran Transport", "name": "Iran Transport", "number_cards": [], "owner": "Administrator",
 "parent_page": "", "public": 1, "quick_lists": [], "restrict_to_domain": "", "roles": [],
 "sequence_id": 20.0, "shortcuts": [], "title": "حمل و نقل",
 "links": [
  {"type": "Card Break", "label": "اطلاعات پایه", "link_count": 6, "hidden": 0, "onboard": 0, "is_query_report": 0},
  {"type": "Link", "label": "Border", "link_type": "DocType", "link_to": "Border", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""},
  {"type": "Link", "label": "Carrier", "link_type": "DocType", "link_to": "Carrier", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""},
  {"type": "Link", "label": "Customs Broker", "link_type": "DocType", "link_to": "Customs Broker", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""},
  {"type": "Link", "label": "Border Representative", "link_type": "DocType", "link_to": "Border Representative", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""},
  {"type": "Link", "label": "Driver", "link_type": "DocType", "link_to": "Driver", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""},
  {"type": "Link", "label": "Vehicle", "link_type": "DocType", "link_to": "Vehicle", "hidden": 0, "onboard": 0, "is_query_report": 0, "dependencies": ""}
 ]
}
EOF
python3 -m json.tool "${WS_DIR}/iran_transport.json" >/dev/null && log "workspace.json OK"

# =============================================================================
# 6) force-sync workspace (خواندن JSON و نوشتن به DB)
# =============================================================================
step "6) setup_workspace module"
write_utf8 "${MOD}/setup_workspace_phase4.py" << 'EOF'
"""Force-apply Iran Transport workspace from its JSON file (idempotent)."""
import json
import frappe

def setup_workspace_phase4():
    path = frappe.get_app_path(
        "transport_ir", "iran_transport", "workspace", "iran_transport", "iran_transport.json"
    )
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    name = data["name"]
    frappe.flags.in_patch = True

    if frappe.db.exists("Workspace", name):
        doc = frappe.get_doc("Workspace", name)
    else:
        doc = frappe.new_doc("Workspace")
        doc.name = name

    for k in ["label", "title", "module", "public", "icon", "content",
              "sequence_id", "parent_page", "for_user", "is_hidden", "hide_custom"]:
        if k in data:
            setattr(doc, k, data[k])

    for ct in ["links", "shortcuts", "charts", "number_cards", "quick_lists", "roles"]:
        doc.set(ct, [])
    for row in data.get("links", []):
        doc.append("links", row)

    doc.flags.ignore_permissions = True
    doc.flags.ignore_validate = True
    doc.flags.ignore_mandatory = True

    if doc.is_new():
        doc.insert(ignore_permissions=True)
    else:
        doc.save(ignore_permissions=True)

    frappe.db.commit()
    frappe.clear_cache()

    ws = frappe.get_doc("Workspace", name)
    n = len(ws.links or [])
    print(f"Workspace '{name}' links={n}")
    if n < 7:
        frappe.throw(f"Workspace links not applied (got {n})")
    return {"name": name, "links": n}
EOF

# =============================================================================
# 7) verify_phase4
# =============================================================================
step "7) verify module"
write_utf8 "${MOD}/verify_phase4.py" << 'EOF'
import json
import frappe

def verify_phase4():
    passed, failed = [], []
    def ok(name, cond):
        (passed if cond else failed).append(name)
        print(("PASS: " if cond else "FAIL: ") + name)

    for dt in ["Border", "Carrier", "Customs Broker", "Border Representative"]:
        ok(f"doctype {dt}", bool(frappe.db.exists("DocType", dt)))

    ok("border count == 6", frappe.db.count("Border") == 6)

    for dt, fn in [("Driver","custom_national_id"), ("Vehicle","custom_capacity_ton"),
                   ("Item","custom_thickness_mm"), ("Customer","custom_preferred_border"),
                   ("Supplier","custom_is_factory")]:
        ok(f"custom field {dt}.{fn}", bool(frappe.db.exists("Custom Field", {"dt": dt, "fieldname": fn})))

    try:
        from ir_base.utils.validators import validate_iranian_national_id
        validate_iranian_national_id("1234567890")
        ok("negative national id raises", False)
    except Exception:
        ok("negative national id raises", True)

    ws_name = "Iran Transport"
    ok("workspace exists", bool(frappe.db.exists("Workspace", ws_name)))
    if frappe.db.exists("Workspace", ws_name):
        ws = frappe.get_doc("Workspace", ws_name)
        ok("workspace has links", len(ws.links or []) >= 7)
        try:
            content = json.loads(ws.content or "[]")
            has_card = any(
                isinstance(b, dict) and b.get("type") == "card"
                and (b.get("data") or {}).get("card_name") == "اطلاعات پایه"
                for b in content
            )
        except Exception:
            has_card = False
        ok("workspace content has master card", has_card)
        link_tos = {r.link_to for r in ws.links if r.type == "Link"}
        ok("workspace links Border", "Border" in link_tos)
        ok("workspace links Carrier", "Carrier" in link_tos)

    print(f"\nPassed: {len(passed)}  Failed: {len(failed)}")
    if failed:
        for f in failed: print("  -", f)
    else:
        print("All phase-4 checks passed.")
    return {"passed": passed, "failed": failed}
EOF

# =============================================================================
# 8) migrate + force workspace + verify
# =============================================================================
step "8) migrate + force workspace + verify"
bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache
bench --site "$SITE_NAME" execute transport_ir.iran_transport.setup_workspace_phase4.setup_workspace_phase4
bench --site "$SITE_NAME" clear-cache
bench --site "$SITE_NAME" execute transport_ir.iran_transport.verify_phase4.verify_phase4

# =============================================================================
# 9) git commit
# =============================================================================
step "9) git commit"
cd "${BENCH_DIR}/apps/${APP}"
git add -A
git commit -m "phase 4: master data + custom fields + validations + workspace force-sync" || warn "nothing to commit"

step "DONE"
cat <<FINAL

${GREEN}فاز ۴ تمام شد (کاملاً خودکار).${NC}

انتظار: Passed: 15  Failed: 0

چک‌لیست دستی:
  [ ] /app/border -> 6 مرز
  [ ] Workspace حمل و نقل -> کارت «اطلاعات پایه» با 6 لینک
  [ ] فرم Driver -> بخش «اطلاعات ایران»
  [ ] Driver کد ملی 1234567890 -> خطا
  [ ] Driver موبایل 08123456789 -> خطا

FINAL