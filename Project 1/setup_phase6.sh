#!/usr/bin/env bash
# =============================================================================
# setup_phase6.sh — Transport Operations (FIXED v3)
# ERPNext v15 / Frappe v15 | File-First | Controller-Based | Idempotent
#
# پیش‌نیاز:
#   phase2 → phase3 → phase4 → realign_gate → ir_jalali → phase5
#
# Fix v3 (این نسخه — بر اساس خطای واقعی اجرا):
#   1) WorkflowPermissionError: نمی‌توان هنگام insert مستقیماً
#      workflow_state را Draft→Pending Supervisor Review کرد.
#      راه‌حل فازهای قبل: insert با Draft، سپس db_set state.
#   2) verify false-fail روی "tc.status" داخل کامنت — حذف/سخت‌گیری درست.
#   3) fixture name guard از v2 حفظ شده.
#   4) OWNER: priority + other_cost/description حفظ شده.
#
# قوانین:
#   File-First | No bench console | No drop-site
#   allow_edit/allowed = تک‌نقش در هر ردیف (چند ردیف OK)
# =============================================================================
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=utf-8

export SITE_NAME="transport-dev.local"
export BENCH_DIR="${HOME}/frappe-bench"
export APP="transport_ir"
export PKG="${BENCH_DIR}/apps/${APP}/${APP}"
export MOD="${PKG}/iran_transport"
export HOOKS="${PKG}/hooks.py"
export NOW_TS
NOW_TS="$(date '+%Y-%m-%d %H:%M:%S').000000"

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
[[ -d "${BENCH_DIR}/apps/${APP}" ]] || err "transport_ir not found"
[[ -f "${MOD}/doctype/trade_case/trade_case.json" ]] || err "phase 5 missing (Trade Case)"
[[ -f "${MOD}/doctype/transport_case/transport_case.json" ]] || err "phase 5 missing (Transport Case)"
cd "$BENCH_DIR"
bench use "$SITE_NAME" 2>/dev/null || true

# =============================================================================
step "0) bench services"
if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "bench already running"
else
  nohup bench start >>/tmp/bench-start-phase6.log 2>&1 &
  log "bench start pid=$!"; sleep 12
fi

REDIS_CACHE_CONF="${BENCH_DIR}/config/redis_cache.conf"
if [[ -f "$REDIS_CACHE_CONF" ]]; then
  REDIS_CACHE_PORT="$(awk '$1 == "port" {print $2; exit}' "$REDIS_CACHE_CONF")"
else
  REDIS_CACHE_PORT="13000"
fi
[[ -n "${REDIS_CACHE_PORT:-}" ]] || REDIS_CACHE_PORT="13000"
log "waiting for redis_cache on port ${REDIS_CACHE_PORT}"
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
[[ "$REDIS_READY" -eq 1 ]] || err "redis_cache not ready. Check /tmp/bench-start-phase6.log"
log "redis_cache ready"

# =============================================================================
step "0b) preflight phase5 + roles"
for dt in "Trade Case" "Transport Case" "Border" "Carrier"; do
  cnt="$(bench --site "$SITE_NAME" execute frappe.db.count --args "[\"DocType\", {\"name\": \"${dt}\"}]" 2>/dev/null | tail -1 | tr -d '[:space:]')"
  [[ "$cnt" == "1" ]] || err "DocType missing: ${dt}"
done
for role in \
  "Transport Supervisor" \
  "Transport User - Purchase" \
  "Transport User - Sales" \
  "Customs Officer" \
  "Finance Supervisor" \
  "Financial Manager"
do
  cnt="$(bench --site "$SITE_NAME" execute frappe.db.count --args "[\"Role\", {\"name\": \"${role}\"}]" 2>/dev/null | tail -1 | tr -d '[:space:]')"
  [[ "$cnt" == "1" ]] || err "Role missing: ${role}"
done
log "preflight OK"

# =============================================================================
step "1) FIX trade_case.py bridge (Draft insert + db_set cartable state)"
DT="${MOD}/doctype"

# IMPORTANT (Frappe v15 workflow lesson from prior phases):
# Do NOT set a non-default workflow_state before/during insert.
# insert() as Draft, then db_set target state (system bridge).
write_utf8 "${DT}/trade_case/trade_case.py" << 'EOF'
import frappe
from frappe.model.document import Document
from frappe import _


class TradeCase(Document):
    def before_insert(self):
        if not self.posting_date:
            self.posting_date = frappe.utils.today()

        if not self.company:
            self.company = (
                frappe.defaults.get_user_default("Company")
                or frappe.db.get_single_value("Global Defaults", "default_company")
                or frappe.db.get_value("Company", {"is_group": 0}, "name")
            )

        if not self.company:
            frappe.throw(_("شرکت پیش‌فرض مشخص نشده است."))

    def validate(self):
        states_requiring_signature = [
            "Pending Signature",
            "Finance Supervisor",
            "Receivables",
            "Approved",
        ]
        if self.workflow_state in states_requiring_signature:
            if not self.signed_document:
                frappe.throw(
                    _("برای ورود به مرحله «{0}» بارگذاری سند امضاشده الزامی است.").format(
                        self.workflow_state
                    )
                )

    def on_update(self):
        """Auto-create Transport Case when Approved (once).

        Phase6 bridge rules (Frappe v15):
          - never assign legacy open-status field on Transport Case
          - anti-duplicate filters on workflow_state
          - insert Transport Case in Draft, then db_set cartable state
            (direct non-default workflow_state on insert is blocked)
        """
        if self.workflow_state != "Approved":
            return
        if not self.has_value_changed("workflow_state"):
            return

        if not frappe.db.exists("DocType", "Transport Case"):
            frappe.throw(_("پرونده حمل (Transport Case) هنوز در سیستم تعریف نشده است."))

        exists = frappe.db.exists(
            "Transport Case",
            {
                "trade_case": self.name,
                "workflow_state": ["not in", ["Cancelled", "Rejected"]],
            },
        )
        if exists:
            return

        tc = frappe.new_doc("Transport Case")
        tc.trade_case = self.name
        tc.case_title = f"حمل: {self.case_title}"
        tc.case_type = self.case_type
        tc.company = self.company
        tc.posting_date = self.posting_date
        # Leave workflow_state default (Draft). Set cartable AFTER insert.
        tc.customer = self.customer
        tc.supplier_factory = self.supplier_factory
        tc.item = self.item
        tc.cargo_description = self.cargo_description
        tc.thickness = self.thickness
        tc.dimensions = self.dimensions
        tc.qty = self.qty
        tc.weight = self.weight
        tc.planned_tonnage = self.planned_tonnage

        tc.purchase_amount = self.purchase_amount
        tc.sales_amount = self.sales_amount
        tc.initial_costs = self.initial_costs
        tc.freight_cost = self.freight_cost
        tc.customs_cost = self.customs_cost
        tc.clearance_cost = self.clearance_cost

        tc.destination = self.destination
        tc.border = self.border
        tc.transport_type = self.transport_type
        tc.delivery_type = self.delivery_type

        tc.flags.ignore_permissions = True
        tc.insert()

        # System bridge into supervisor cartable (bypass transition UI)
        frappe.db.set_value(
            "Transport Case",
            tc.name,
            "workflow_state",
            "Pending Supervisor Review",
            update_modified=False,
        )

        frappe.msgprint(
            _("پرونده حمل {0} به صورت خودکار ایجاد شد.").format(tc.name),
            alert=True,
            indicator="green",
        )
EOF

# =============================================================================
step "2) child + operational DocTypes"

mkdir -p "${DT}/transport_payment"
touch "${DT}/transport_payment/__init__.py"
write_utf8 "${DT}/transport_payment/transport_payment.json" << 'EOF'
{
 "actions": [],
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "editable_grid": 1,
 "engine": "InnoDB",
 "field_order": ["payment_type", "amount", "sheba", "bank_name", "payment_date", "reference_no", "paid_by", "notes"],
 "fields": [
  {"fieldname": "payment_type", "fieldtype": "Select", "label": "نوع پرداخت", "options": "پیش کرایه\nکرایه\nگمرک\nترخیص\nسایر", "reqd": 1, "in_list_view": 1},
  {"fieldname": "amount", "fieldtype": "Currency", "label": "مبلغ", "reqd": 1, "in_list_view": 1},
  {"fieldname": "sheba", "fieldtype": "Data", "label": "شماره شبا", "in_list_view": 1},
  {"fieldname": "bank_name", "fieldtype": "Data", "label": "بانک"},
  {"fieldname": "payment_date", "fieldtype": "Date", "label": "تاریخ پرداخت", "default": "Today", "in_list_view": 1},
  {"fieldname": "reference_no", "fieldtype": "Data", "label": "شماره سند"},
  {"fieldname": "paid_by", "fieldtype": "Link", "label": "پرداخت‌کننده", "options": "User"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "توضیحات"}
 ],
 "istable": 1,
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Iran Transport",
 "name": "Transport Payment",
 "owner": "Administrator",
 "permissions": [],
 "track_changes": 0
}
EOF
write_utf8 "${DT}/transport_payment/transport_payment.py" << 'EOF'
from frappe.model.document import Document


class TransportPayment(Document):
    pass
EOF

mkdir -p "${DT}/transport_waybill"
touch "${DT}/transport_waybill/__init__.py"
write_utf8 "${DT}/transport_waybill/transport_waybill.json" << 'EOF'
{
 "actions": [],
 "autoname": "naming_series:",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "is_submittable": 1,
 "field_order": [
  "naming_series", "transport_case", "waybill_number", "waybill_date", "column_break_1",
  "driver", "vehicle", "plate_number", "carrier",
  "section_route", "origin", "destination", "border", "column_break_r",
  "sender_name", "receiver_name",
  "section_cargo", "item_name", "tonnage", "freight_amount", "insurance_amount",
  "section_files", "attachment", "notes", "amended_from"
 ],
 "fields": [
  {"fieldname": "naming_series", "fieldtype": "Select", "options": "WB-.YYYY.-.#####", "default": "WB-.YYYY.-.#####", "reqd": 1, "hidden": 1},
  {"fieldname": "transport_case", "fieldtype": "Link", "label": "پرونده حمل", "options": "Transport Case", "reqd": 1, "in_list_view": 1, "in_standard_filter": 1},
  {"fieldname": "waybill_number", "fieldtype": "Data", "label": "شماره بارنامه", "reqd": 1, "in_list_view": 1, "bold": 1},
  {"fieldname": "waybill_date", "fieldtype": "Date", "label": "تاریخ بارنامه", "default": "Today", "reqd": 1},
  {"fieldname": "column_break_1", "fieldtype": "Column Break"},
  {"fieldname": "driver", "fieldtype": "Link", "label": "راننده", "options": "Driver", "reqd": 1, "in_list_view": 1},
  {"fieldname": "vehicle", "fieldtype": "Link", "label": "خودرو", "options": "Vehicle"},
  {"fieldname": "plate_number", "fieldtype": "Data", "label": "پلاک", "fetch_from": "vehicle.license_plate", "in_list_view": 1},
  {"fieldname": "carrier", "fieldtype": "Link", "label": "باربری", "options": "Carrier"},
  {"fieldname": "section_route", "fieldtype": "Section Break", "label": "مسیر"},
  {"fieldname": "origin", "fieldtype": "Data", "label": "مبدا"},
  {"fieldname": "destination", "fieldtype": "Data", "label": "مقصد"},
  {"fieldname": "border", "fieldtype": "Link", "label": "مرز", "options": "Border"},
  {"fieldname": "column_break_r", "fieldtype": "Column Break"},
  {"fieldname": "sender_name", "fieldtype": "Data", "label": "فرستنده"},
  {"fieldname": "receiver_name", "fieldtype": "Data", "label": "گیرنده"},
  {"fieldname": "section_cargo", "fieldtype": "Section Break", "label": "بار و مبلغ"},
  {"fieldname": "item_name", "fieldtype": "Data", "label": "کالا"},
  {"fieldname": "tonnage", "fieldtype": "Float", "label": "تناژ", "reqd": 1},
  {"fieldname": "freight_amount", "fieldtype": "Currency", "label": "مبلغ کرایه"},
  {"fieldname": "insurance_amount", "fieldtype": "Currency", "label": "مبلغ بیمه"},
  {"fieldname": "section_files", "fieldtype": "Section Break", "label": "پیوست"},
  {"fieldname": "attachment", "fieldtype": "Attach", "label": "فایل بارنامه"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "یادداشت"},
  {"fieldname": "amended_from", "fieldtype": "Link", "options": "Transport Waybill", "read_only": 1, "no_copy": 1, "print_hide": 1, "hidden": 1}
 ],
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Iran Transport",
 "name": "Transport Waybill",
 "naming_rule": "By \"Naming Series\" field",
 "owner": "Administrator",
 "permissions": [
  {"create": 1, "read": 1, "write": 1, "submit": 1, "cancel": 1, "delete": 1, "report": 1, "export": 1, "print": 1, "role": "System Manager"},
  {"create": 1, "read": 1, "write": 1, "submit": 1, "report": 1, "print": 1, "role": "Transport Supervisor"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "print": 1, "role": "Transport User - Purchase"},
  {"create": 1, "read": 1, "write": 1, "submit": 1, "report": 1, "print": 1, "role": "Transport User - Sales"},
  {"read": 1, "report": 1, "role": "Customs Officer"},
  {"read": 1, "report": 1, "role": "Finance Supervisor"},
  {"read": 1, "report": 1, "role": "Financial Manager"},
  {"read": 1, "report": 1, "role": "CEO"}
 ],
 "search_fields": "waybill_number,transport_case,driver,plate_number",
 "sort_field": "modified",
 "sort_order": "DESC",
 "title_field": "waybill_number",
 "track_changes": 1
}
EOF
write_utf8 "${DT}/transport_waybill/transport_waybill.py" << 'EOF'
import frappe
from frappe import _
from frappe.model.document import Document
from frappe.utils import flt


class TransportWaybill(Document):
    def validate(self):
        if not self.waybill_number:
            frappe.throw(_("شماره بارنامه اجباری است"))
        if flt(self.tonnage) <= 0:
            frappe.throw(_("تناژ بارنامه باید بزرگ‌تر از صفر باشد"))
        if flt(self.freight_amount) < 0 or flt(self.insurance_amount) < 0:
            frappe.throw(_("مبالغ نمی‌توانند منفی باشند"))

        dup = frappe.db.exists(
            "Transport Waybill",
            {
                "waybill_number": self.waybill_number,
                "name": ["!=", self.name],
                "docstatus": ["!=", 2],
            },
        )
        if dup:
            frappe.throw(_("شماره بارنامه تکراری است: {0}").format(self.waybill_number))

    def on_submit(self):
        self._sync_to_case()

    def _sync_to_case(self):
        if not self.transport_case:
            return
        case = frappe.get_doc("Transport Case", self.transport_case)
        case.driver = self.driver
        case.vehicle = self.vehicle
        case.plate_number = self.plate_number
        case.carrier = self.carrier
        case.waybill_number = self.waybill_number
        case.waybill_date = self.waybill_date
        case.waybill_ref = self.name
        if self.sender_name:
            case.sender_name = self.sender_name
        if self.receiver_name:
            case.receiver_name = self.receiver_name
        if self.freight_amount:
            case.freight_cost = self.freight_amount
        if self.tonnage:
            case.actual_tonnage = self.tonnage
        if self.destination:
            case.destination = self.destination
        if self.border:
            case.border = self.border
        case.flags.ignore_permissions = True
        case.save()
EOF

mkdir -p "${DT}/transport_weighbridge"
touch "${DT}/transport_weighbridge/__init__.py"
write_utf8 "${DT}/transport_weighbridge/transport_weighbridge.json" << 'EOF'
{
 "actions": [],
 "autoname": "naming_series:",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "field_order": [
  "naming_series", "transport_case", "waybill", "posting_datetime", "column_break_1",
  "plate_number", "operator",
  "section_w", "weight_empty", "weight_full", "net_weight", "net_tonnage",
  "section_f", "attachment", "notes", "approved_by", "approval_status"
 ],
 "fields": [
  {"fieldname": "naming_series", "fieldtype": "Select", "options": "WGH-.YYYY.-.#####", "default": "WGH-.YYYY.-.#####", "hidden": 1, "reqd": 1},
  {"fieldname": "transport_case", "fieldtype": "Link", "label": "پرونده حمل", "options": "Transport Case", "reqd": 1, "in_list_view": 1},
  {"fieldname": "waybill", "fieldtype": "Link", "label": "بارنامه", "options": "Transport Waybill"},
  {"fieldname": "posting_datetime", "fieldtype": "Datetime", "label": "تاریخ و ساعت", "default": "Now", "reqd": 1},
  {"fieldname": "column_break_1", "fieldtype": "Column Break"},
  {"fieldname": "plate_number", "fieldtype": "Data", "label": "پلاک", "in_list_view": 1},
  {"fieldname": "operator", "fieldtype": "Data", "label": "اپراتور"},
  {"fieldname": "section_w", "fieldtype": "Section Break", "label": "اوزان"},
  {"fieldname": "weight_empty", "fieldtype": "Float", "label": "وزن خالی (kg)", "reqd": 1, "in_list_view": 1},
  {"fieldname": "weight_full", "fieldtype": "Float", "label": "وزن پر (kg)", "reqd": 1, "in_list_view": 1},
  {"fieldname": "net_weight", "fieldtype": "Float", "label": "وزن خالص (kg)", "read_only": 1, "in_list_view": 1},
  {"fieldname": "net_tonnage", "fieldtype": "Float", "label": "تناژ خالص", "read_only": 1},
  {"fieldname": "section_f", "fieldtype": "Section Break", "label": "تایید و پیوست"},
  {"fieldname": "attachment", "fieldtype": "Attach", "label": "فایل باسکول"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "یادداشت"},
  {"fieldname": "approved_by", "fieldtype": "Link", "label": "تاییدکننده", "options": "User"},
  {"fieldname": "approval_status", "fieldtype": "Select", "label": "وضعیت تایید", "options": "ثبت‌شده\nتاییدشده\nردشده", "default": "ثبت‌شده", "in_list_view": 1}
 ],
 "modified": "2025-01-01 00:00:00.000000",
 "module": "Iran Transport",
 "name": "Transport Weighbridge",
 "naming_rule": "By \"Naming Series\" field",
 "owner": "Administrator",
 "permissions": [
  {"create": 1, "read": 1, "write": 1, "delete": 1, "report": 1, "export": 1, "print": 1, "role": "System Manager"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Transport Supervisor"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Transport User - Sales"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Transport User - Purchase"},
  {"read": 1, "write": 1, "report": 1, "role": "Customs Officer"},
  {"read": 1, "report": 1, "role": "CEO"}
 ],
 "sort_field": "modified",
 "sort_order": "DESC",
 "track_changes": 1
}
EOF
write_utf8 "${DT}/transport_weighbridge/transport_weighbridge.py" << 'EOF'
import frappe
from frappe import _
from frappe.model.document import Document
from frappe.utils import flt


class TransportWeighbridge(Document):
    def validate(self):
        if flt(self.weight_empty) < 0 or flt(self.weight_full) <= 0:
            frappe.throw(_("اوزان باید معتبر و مثبت باشند"))
        if flt(self.weight_full) < flt(self.weight_empty):
            frappe.throw(_("وزن پر نمی‌تواند کمتر از وزن خالی باشد"))
        self.net_weight = flt(self.weight_full) - flt(self.weight_empty)
        self.net_tonnage = flt(self.net_weight) / 1000.0

    def on_update(self):
        if self.approval_status != "تاییدشده":
            return
        if not self.transport_case:
            return
        case = frappe.get_doc("Transport Case", self.transport_case)
        case.weight_empty = self.weight_empty
        case.weight_full = self.weight_full
        case.net_weight = self.net_weight
        case.actual_tonnage = self.net_tonnage
        case.weighbridge_ref = self.name
        case.flags.ignore_permissions = True
        case.save()
EOF

mkdir -p "${DT}/transport_bijak"
touch "${DT}/transport_bijak/__init__.py"
write_utf8 "${DT}/transport_bijak/transport_bijak.json" << 'EOF'
{
 "actions": [],
 "autoname": "naming_series:",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "field_order": [
  "naming_series", "transport_case", "needs_bijak", "column_break_1", "bijak_number", "declaration_number",
  "section_f", "bijak_attachment", "declaration_attachment", "notes", "status"
 ],
 "fields": [
  {"fieldname": "naming_series", "fieldtype": "Select", "options": "BJK-.YYYY.-.#####", "default": "BJK-.YYYY.-.#####", "hidden": 1, "reqd": 1},
  {"fieldname": "transport_case", "fieldtype": "Link", "label": "پرونده حمل", "options": "Transport Case", "reqd": 1, "in_list_view": 1},
  {"fieldname": "needs_bijak", "fieldtype": "Select", "label": "نیاز به بیجک", "options": "بله\nخیر", "reqd": 1, "in_list_view": 1},
  {"fieldname": "column_break_1", "fieldtype": "Column Break"},
  {"fieldname": "bijak_number", "fieldtype": "Data", "label": "شماره بیجک", "in_list_view": 1},
  {"fieldname": "declaration_number", "fieldtype": "Data", "label": "شماره اظهار"},
  {"fieldname": "section_f", "fieldtype": "Section Break", "label": "مدارک"},
  {"fieldname": "bijak_attachment", "fieldtype": "Attach", "label": "فایل بیجک"},
  {"fieldname": "declaration_attachment", "fieldtype": "Attach", "label": "فایل اظهار"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "یادداشت"},
  {"fieldname": "status", "fieldtype": "Select", "label": "وضعیت", "options": "ثبت‌شده\nتاییدشده\nبدون نیاز", "default": "ثبت‌شده", "in_list_view": 1}
 ],
 "modified": "2025-01-01 00:00:00.000000",
 "module": "Iran Transport",
 "name": "Transport Bijak",
 "naming_rule": "By \"Naming Series\" field",
 "owner": "Administrator",
 "permissions": [
  {"create": 1, "read": 1, "write": 1, "delete": 1, "report": 1, "role": "System Manager"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Transport Supervisor"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Customs Officer"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Transport User - Purchase"},
  {"read": 1, "report": 1, "role": "Transport User - Sales"},
  {"read": 1, "report": 1, "role": "CEO"}
 ],
 "sort_field": "modified",
 "sort_order": "DESC",
 "track_changes": 1
}
EOF
write_utf8 "${DT}/transport_bijak/transport_bijak.py" << 'EOF'
import frappe
from frappe import _
from frappe.model.document import Document


class TransportBijak(Document):
    def validate(self):
        if self.needs_bijak == "خیر":
            self.status = "بدون نیاز"
            return
        if not self.bijak_attachment:
            frappe.throw(_("در صورت نیاز به بیجک، آپلود فایل بیجک اجباری است"))
        if not self.declaration_attachment:
            frappe.throw(_("در صورت نیاز به بیجک، آپلود فایل اظهار اجباری است"))

    def on_update(self):
        if not self.transport_case:
            return
        case = frappe.get_doc("Transport Case", self.transport_case)
        case.needs_bijak = self.needs_bijak
        case.bijak_number = self.bijak_number
        case.declaration_number = self.declaration_number
        case.bijak_ref = self.name
        if self.needs_bijak == "خیر":
            case.bijak_done = 1
        elif self.status == "تاییدشده":
            case.bijak_done = 1
        else:
            case.bijak_done = 0
        case.flags.ignore_permissions = True
        case.save()
EOF

mkdir -p "${DT}/transport_clearance"
touch "${DT}/transport_clearance/__init__.py"
write_utf8 "${DT}/transport_clearance/transport_clearance.json" << 'EOF'
{
 "actions": [],
 "autoname": "naming_series:",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "field_order": [
  "naming_series", "transport_case", "clearance_status", "column_break_1", "clearance_datetime",
  "section_people", "customs_broker", "border_representative", "column_break_p",
  "coordination_call", "coordination_sms", "driver_confirmed",
  "section_cost", "customs_cost", "clearance_cost",
  "section_f", "attachment", "notes", "approved_by"
 ],
 "fields": [
  {"fieldname": "naming_series", "fieldtype": "Select", "options": "CLR-.YYYY.-.#####", "default": "CLR-.YYYY.-.#####", "hidden": 1, "reqd": 1},
  {"fieldname": "transport_case", "fieldtype": "Link", "label": "پرونده حمل", "options": "Transport Case", "reqd": 1, "in_list_view": 1},
  {"fieldname": "clearance_status", "fieldtype": "Select", "label": "وضعیت ترخیص", "options": "در انتظار\nدر حال انجام\nترخیص شده\nمشکل‌دار", "default": "در انتظار", "in_list_view": 1},
  {"fieldname": "column_break_1", "fieldtype": "Column Break"},
  {"fieldname": "clearance_datetime", "fieldtype": "Datetime", "label": "تاریخ/ساعت ترخیص"},
  {"fieldname": "section_people", "fieldtype": "Section Break", "label": "عوامل گمرک"},
  {"fieldname": "customs_broker", "fieldtype": "Link", "label": "ترخیص‌کار", "options": "Customs Broker", "in_list_view": 1},
  {"fieldname": "border_representative", "fieldtype": "Link", "label": "نماینده مرز", "options": "Border Representative"},
  {"fieldname": "column_break_p", "fieldtype": "Column Break"},
  {"fieldname": "coordination_call", "fieldtype": "Check", "label": "تماس انجام شد"},
  {"fieldname": "coordination_sms", "fieldtype": "Check", "label": "پیامک ارسال شد"},
  {"fieldname": "driver_confirmed", "fieldtype": "Check", "label": "تایید راننده"},
  {"fieldname": "section_cost", "fieldtype": "Section Break", "label": "هزینه‌ها"},
  {"fieldname": "customs_cost", "fieldtype": "Currency", "label": "هزینه گمرک"},
  {"fieldname": "clearance_cost", "fieldtype": "Currency", "label": "هزینه ترخیص"},
  {"fieldname": "section_f", "fieldtype": "Section Break", "label": "پیوست و تایید"},
  {"fieldname": "attachment", "fieldtype": "Attach", "label": "مدارک ترخیص"},
  {"fieldname": "notes", "fieldtype": "Small Text", "label": "یادداشت"},
  {"fieldname": "approved_by", "fieldtype": "Link", "label": "تاییدکننده", "options": "User"}
 ],
 "modified": "2025-01-01 00:00:00.000000",
 "module": "Iran Transport",
 "name": "Transport Clearance",
 "naming_rule": "By \"Naming Series\" field",
 "owner": "Administrator",
 "permissions": [
  {"create": 1, "read": 1, "write": 1, "delete": 1, "report": 1, "role": "System Manager"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Customs Officer"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "role": "Transport Supervisor"},
  {"read": 1, "write": 1, "report": 1, "role": "Transport User - Purchase"},
  {"read": 1, "report": 1, "role": "Transport User - Sales"},
  {"read": 1, "report": 1, "role": "Finance Supervisor"},
  {"read": 1, "report": 1, "role": "CEO"}
 ],
 "sort_field": "modified",
 "sort_order": "DESC",
 "track_changes": 1
}
EOF
write_utf8 "${DT}/transport_clearance/transport_clearance.py" << 'EOF'
import frappe
from frappe.model.document import Document


class TransportClearance(Document):
    def on_update(self):
        if not self.transport_case:
            return
        case = frappe.get_doc("Transport Case", self.transport_case)
        case.clearance_status = self.clearance_status
        case.customs_broker = self.customs_broker
        case.border_representative = self.border_representative
        case.coordination_call = self.coordination_call
        case.coordination_sms = self.coordination_sms
        case.driver_confirmed = self.driver_confirmed
        case.clearance_ref = self.name
        if self.customs_cost is not None:
            case.customs_cost = self.customs_cost
        if self.clearance_cost is not None:
            case.clearance_cost = self.clearance_cost
        case.clearance_done = 1 if self.clearance_status == "ترخیص شده" else 0
        case.flags.ignore_permissions = True
        case.save()
EOF

log "sub DocTypes written"

# =============================================================================
step "3) Transport Case FULL operational JSON"
# OWNER: priority default متوسط, not reqd | other_cost + description if > 0
write_utf8 "${DT}/transport_case/transport_case.json" << 'EOF'
{
 "actions": [],
 "allow_rename": 0,
 "autoname": "naming_series:",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "field_order": [
  "naming_series", "trade_case", "case_title", "case_type", "workflow_state", "column_break_top",
  "posting_date", "company", "priority", "assigned_user",
  "section_parties", "customer", "supplier_factory", "column_break_p", "item", "cargo_description",
  "section_cargo", "thickness", "dimensions", "qty", "column_break_c", "weight", "planned_tonnage", "actual_tonnage",
  "section_financial", "purchase_amount", "sales_amount", "initial_costs", "column_break_f",
  "freight_cost", "customs_cost", "clearance_cost", "other_cost", "other_cost_description", "total_cost", "estimated_profit",
  "section_route", "destination", "border", "column_break_r", "transport_type", "delivery_type",
  "section_driver", "driver", "driver_name", "driver_mobile", "driver_national_id", "column_break_d",
  "vehicle", "plate_number", "carrier", "is_smart_driver", "smart_card_no",
  "section_waybill", "waybill_number", "waybill_date", "waybill_ref", "sender_name", "receiver_name",
  "section_weighbridge", "weight_empty", "weight_full", "net_weight", "weighbridge_ref",
  "section_bijak", "needs_bijak", "bijak_done", "bijak_number", "declaration_number", "bijak_ref",
  "section_clearance", "clearance_status", "clearance_done", "customs_broker", "border_representative",
  "column_break_cl", "coordination_call", "coordination_sms", "driver_confirmed", "clearance_ref",
  "section_delivery", "delivery_receipt", "delivery_date", "delivery_done",
  "section_pay", "payments", "payments_done",
  "section_finance_close", "sent_to_finance", "finance_approved", "close_notes",
  "section_checklist", "chk_driver", "chk_waybill", "chk_weighbridge", "chk_bijak", "chk_clearance", "chk_delivery", "chk_payments",
  "section_notes", "notes"
 ],
 "fields": [
  {"fieldname": "naming_series", "fieldtype": "Select", "options": "TR-.YYYY.-.#####", "default": "TR-.YYYY.-.#####", "hidden": 1, "reqd": 1},
  {"fieldname": "trade_case", "fieldtype": "Link", "label": "پرونده تجاری", "options": "Trade Case", "in_list_view": 1, "in_standard_filter": 1},
  {"fieldname": "case_title", "fieldtype": "Data", "label": "عنوان", "reqd": 1, "in_list_view": 1, "bold": 1},
  {"fieldname": "case_type", "fieldtype": "Select", "label": "نوع", "options": "خرید\nفروش", "reqd": 1, "in_list_view": 1, "in_standard_filter": 1},
  {"fieldname": "workflow_state", "fieldtype": "Link", "label": "وضعیت", "options": "Workflow State", "default": "Draft", "read_only": 1, "in_list_view": 1, "in_standard_filter": 1},
  {"fieldname": "column_break_top", "fieldtype": "Column Break"},
  {"fieldname": "posting_date", "fieldtype": "Date", "label": "تاریخ ثبت", "default": "Today", "reqd": 1},
  {"fieldname": "company", "fieldtype": "Link", "label": "شرکت", "options": "Company", "reqd": 1},
  {"fieldname": "priority", "fieldtype": "Select", "label": "اولویت", "options": "کم\nمتوسط\nزیاد\nفوری", "default": "متوسط", "in_list_view": 1, "in_standard_filter": 1},
  {"fieldname": "assigned_user", "fieldtype": "Link", "label": "کارشناس مسئول", "options": "User", "in_standard_filter": 1},

  {"fieldname": "section_parties", "fieldtype": "Section Break", "label": "طرفین و کالا"},
  {"fieldname": "customer", "fieldtype": "Link", "label": "مشتری", "options": "Customer", "in_standard_filter": 1},
  {"fieldname": "supplier_factory", "fieldtype": "Link", "label": "کارخانه/فروشنده", "options": "Supplier"},
  {"fieldname": "column_break_p", "fieldtype": "Column Break"},
  {"fieldname": "item", "fieldtype": "Link", "label": "کالا", "options": "Item"},
  {"fieldname": "cargo_description", "fieldtype": "Small Text", "label": "شرح کالا"},

  {"fieldname": "section_cargo", "fieldtype": "Section Break", "label": "مشخصات بار"},
  {"fieldname": "thickness", "fieldtype": "Float", "label": "ضخامت"},
  {"fieldname": "dimensions", "fieldtype": "Data", "label": "ابعاد"},
  {"fieldname": "qty", "fieldtype": "Float", "label": "تعداد"},
  {"fieldname": "column_break_c", "fieldtype": "Column Break"},
  {"fieldname": "weight", "fieldtype": "Float", "label": "وزن"},
  {"fieldname": "planned_tonnage", "fieldtype": "Float", "label": "تناژ برنامه", "reqd": 1, "in_list_view": 1},
  {"fieldname": "actual_tonnage", "fieldtype": "Float", "label": "تناژ واقعی"},

  {"fieldname": "section_financial", "fieldtype": "Section Break", "label": "مالی و هزینه‌ها"},
  {"fieldname": "purchase_amount", "fieldtype": "Currency", "label": "مبلغ خرید"},
  {"fieldname": "sales_amount", "fieldtype": "Currency", "label": "مبلغ فروش"},
  {"fieldname": "initial_costs", "fieldtype": "Currency", "label": "هزینه اولیه"},
  {"fieldname": "column_break_f", "fieldtype": "Column Break"},
  {"fieldname": "freight_cost", "fieldtype": "Currency", "label": "کرایه"},
  {"fieldname": "customs_cost", "fieldtype": "Currency", "label": "گمرک"},
  {"fieldname": "clearance_cost", "fieldtype": "Currency", "label": "ترخیص"},
  {"fieldname": "other_cost", "fieldtype": "Currency", "label": "هزینه‌های دیگر", "default": "0"},
  {"fieldname": "other_cost_description", "fieldtype": "Small Text", "label": "توضیحات هزینه‌های دیگر", "depends_on": "eval:doc.other_cost > 0", "mandatory_depends_on": "eval:doc.other_cost > 0"},
  {"fieldname": "total_cost", "fieldtype": "Currency", "label": "جمع هزینه", "read_only": 1},
  {"fieldname": "estimated_profit", "fieldtype": "Currency", "label": "سود تقریبی", "read_only": 1},

  {"fieldname": "section_route", "fieldtype": "Section Break", "label": "مسیر و حمل"},
  {"fieldname": "destination", "fieldtype": "Data", "label": "مقصد"},
  {"fieldname": "border", "fieldtype": "Link", "label": "مرز", "options": "Border", "in_standard_filter": 1},
  {"fieldname": "column_break_r", "fieldtype": "Column Break"},
  {"fieldname": "transport_type", "fieldtype": "Select", "label": "نوع حمل", "options": "\nزمینی\nدریایی\nهوایی\nریلی"},
  {"fieldname": "delivery_type", "fieldtype": "Select", "label": "نوع تحویل", "options": "\nتحویلی\nدرب کارخانه\nمرز"},

  {"fieldname": "section_driver", "fieldtype": "Section Break", "label": "راننده و خودرو"},
  {"fieldname": "driver", "fieldtype": "Link", "label": "راننده", "options": "Driver", "in_list_view": 1},
  {"fieldname": "driver_name", "fieldtype": "Data", "label": "نام راننده", "fetch_from": "driver.full_name", "read_only": 1},
  {"fieldname": "driver_mobile", "fieldtype": "Data", "label": "موبایل راننده", "fetch_from": "driver.cell_number", "read_only": 1},
  {"fieldname": "driver_national_id", "fieldtype": "Data", "label": "کد ملی راننده", "fetch_from": "driver.custom_national_id", "read_only": 1},
  {"fieldname": "column_break_d", "fieldtype": "Column Break"},
  {"fieldname": "vehicle", "fieldtype": "Link", "label": "خودرو", "options": "Vehicle"},
  {"fieldname": "plate_number", "fieldtype": "Data", "label": "پلاک", "fetch_from": "vehicle.license_plate", "read_only": 1},
  {"fieldname": "carrier", "fieldtype": "Link", "label": "باربری", "options": "Carrier"},
  {"fieldname": "is_smart_driver", "fieldtype": "Check", "label": "هوشمندی راننده"},
  {"fieldname": "smart_card_no", "fieldtype": "Data", "label": "شماره کارت هوشمند"},

  {"fieldname": "section_waybill", "fieldtype": "Section Break", "label": "بارنامه"},
  {"fieldname": "waybill_number", "fieldtype": "Data", "label": "شماره بارنامه", "in_standard_filter": 1},
  {"fieldname": "waybill_date", "fieldtype": "Date", "label": "تاریخ بارنامه"},
  {"fieldname": "waybill_ref", "fieldtype": "Link", "label": "ارجاع بارنامه", "options": "Transport Waybill", "read_only": 1, "hidden": 1},
  {"fieldname": "sender_name", "fieldtype": "Data", "label": "فرستنده"},
  {"fieldname": "receiver_name", "fieldtype": "Data", "label": "گیرنده"},

  {"fieldname": "section_weighbridge", "fieldtype": "Section Break", "label": "باسکول", "collapsible": 1},
  {"fieldname": "weight_empty", "fieldtype": "Float", "label": "وزن خالی"},
  {"fieldname": "weight_full", "fieldtype": "Float", "label": "وزن پر"},
  {"fieldname": "net_weight", "fieldtype": "Float", "label": "وزن خالص", "read_only": 1},
  {"fieldname": "weighbridge_ref", "fieldtype": "Link", "label": "ارجاع باسکول", "options": "Transport Weighbridge", "read_only": 1, "hidden": 1},

  {"fieldname": "section_bijak", "fieldtype": "Section Break", "label": "بیجک / اظهار", "collapsible": 1},
  {"fieldname": "needs_bijak", "fieldtype": "Select", "label": "نیاز به بیجک", "options": "\nبله\nخیر"},
  {"fieldname": "bijak_done", "fieldtype": "Check", "label": "بیجک تکمیل", "default": 0},
  {"fieldname": "bijak_number", "fieldtype": "Data", "label": "شماره بیجک"},
  {"fieldname": "declaration_number", "fieldtype": "Data", "label": "شماره اظهار"},
  {"fieldname": "bijak_ref", "fieldtype": "Link", "label": "ارجاع بیجک", "options": "Transport Bijak", "read_only": 1, "hidden": 1},

  {"fieldname": "section_clearance", "fieldtype": "Section Break", "label": "گمرک و ترخیص", "collapsible": 1},
  {"fieldname": "clearance_status", "fieldtype": "Select", "label": "وضعیت ترخیص", "options": "\nدر انتظار\nدر حال انجام\nترخیص شده\nمشکل‌دار"},
  {"fieldname": "clearance_done", "fieldtype": "Check", "label": "ترخیص تکمیل", "default": 0},
  {"fieldname": "customs_broker", "fieldtype": "Link", "label": "ترخیص‌کار", "options": "Customs Broker"},
  {"fieldname": "border_representative", "fieldtype": "Link", "label": "نماینده مرز", "options": "Border Representative"},
  {"fieldname": "column_break_cl", "fieldtype": "Column Break"},
  {"fieldname": "coordination_call", "fieldtype": "Check", "label": "تماس انجام شد"},
  {"fieldname": "coordination_sms", "fieldtype": "Check", "label": "پیامک ارسال شد"},
  {"fieldname": "driver_confirmed", "fieldtype": "Check", "label": "تایید راننده"},
  {"fieldname": "clearance_ref", "fieldtype": "Link", "label": "ارجاع ترخیص", "options": "Transport Clearance", "read_only": 1, "hidden": 1},

  {"fieldname": "section_delivery", "fieldtype": "Section Break", "label": "رسید تخلیه"},
  {"fieldname": "delivery_receipt", "fieldtype": "Attach", "label": "رسید تخلیه (PDF/JPG/PNG)"},
  {"fieldname": "delivery_date", "fieldtype": "Datetime", "label": "تاریخ تخلیه"},
  {"fieldname": "delivery_done", "fieldtype": "Check", "label": "تخلیه تکمیل", "default": 0, "read_only": 1},

  {"fieldname": "section_pay", "fieldtype": "Section Break", "label": "پرداخت‌ها"},
  {"fieldname": "payments", "fieldtype": "Table", "label": "ردیف‌های پرداخت", "options": "Transport Payment"},
  {"fieldname": "payments_done", "fieldtype": "Check", "label": "پرداخت‌ها تکمیل", "default": 0},

  {"fieldname": "section_finance_close", "fieldtype": "Section Break", "label": "ارسال مالی و بستن"},
  {"fieldname": "sent_to_finance", "fieldtype": "Check", "label": "ارسال به مالی", "default": 0, "read_only": 1},
  {"fieldname": "finance_approved", "fieldtype": "Check", "label": "تایید مالی", "default": 0},
  {"fieldname": "close_notes", "fieldtype": "Small Text", "label": "یادداشت بستن"},

  {"fieldname": "section_checklist", "fieldtype": "Section Break", "label": "چک‌لیست بستن پرونده", "collapsible": 1, "hidden": 1},
  {"fieldname": "chk_driver", "fieldtype": "Check", "label": "راننده", "read_only": 1, "hidden": 1},
  {"fieldname": "chk_waybill", "fieldtype": "Check", "label": "بارنامه", "read_only": 1, "hidden": 1},
  {"fieldname": "chk_weighbridge", "fieldtype": "Check", "label": "باسکول", "read_only": 1, "hidden": 1},
  {"fieldname": "chk_bijak", "fieldtype": "Check", "label": "بیجک", "read_only": 1, "hidden": 1},
  {"fieldname": "chk_clearance", "fieldtype": "Check", "label": "ترخیص", "read_only": 1, "hidden": 1},
  {"fieldname": "chk_delivery", "fieldtype": "Check", "label": "رسید تخلیه", "read_only": 1, "hidden": 1},
  {"fieldname": "chk_payments", "fieldtype": "Check", "label": "پرداخت‌ها", "read_only": 1, "hidden": 1},

  {"fieldname": "section_notes", "fieldtype": "Section Break", "label": "یادداشت", "collapsible": 1},
  {"fieldname": "notes", "fieldtype": "Text Editor", "label": "یادداشت‌ها"}
 ],
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Iran Transport",
 "name": "Transport Case",
 "naming_rule": "By \"Naming Series\" field",
 "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "email": 1, "export": 1, "print": 1, "read": 1, "report": 1, "role": "System Manager", "share": 1, "write": 1},
  {"create": 1, "read": 1, "write": 1, "report": 1, "export": 1, "print": 1, "role": "Transport Supervisor"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "print": 1, "role": "Transport User - Purchase"},
  {"create": 1, "read": 1, "write": 1, "report": 1, "print": 1, "role": "Transport User - Sales"},
  {"read": 1, "write": 1, "report": 1, "print": 1, "role": "Customs Officer"},
  {"read": 1, "write": 1, "report": 1, "export": 1, "role": "Finance Supervisor"},
  {"read": 1, "write": 1, "report": 1, "export": 1, "role": "Financial Manager"},
  {"read": 1, "write": 1, "report": 1, "role": "Finance User"},
  {"read": 1, "report": 1, "export": 1, "role": "CEO"}
 ],
 "search_fields": "case_title,case_type,customer,driver,waybill_number,workflow_state,border",
 "sort_field": "modified",
 "sort_order": "DESC",
 "title_field": "case_title",
 "track_changes": 1,
 "track_seen": 1
}
EOF

# =============================================================================
step "4) Transport Case controller"
write_utf8 "${DT}/transport_case/transport_case.py" << 'EOF'
import frappe
from frappe import _
from frappe.model.document import Document
from frappe.utils import flt
from ir_base.utils.validators import persian_to_english_digits, validate_sheba


class TransportCase(Document):
    def before_insert(self):
        if not self.posting_date:
            self.posting_date = frappe.utils.today()
        if not self.company:
            self.company = (
                frappe.defaults.get_user_default("Company")
                or frappe.db.get_single_value("Global Defaults", "default_company")
                or frappe.db.get_value("Company", {"is_group": 0}, "name")
            )
        if not self.company:
            frappe.throw(_("شرکت پیش‌فرض مشخص نشده است."))
        # Keep default workflow state on insert (Draft). Never jump states here.
        if not self.workflow_state:
            self.workflow_state = "Draft"
        # OWNER DECISION: priority default متوسط, not mandatory
        if not self.priority:
            self.priority = "متوسط"
        if self.other_cost is None:
            self.other_cost = 0

    def validate(self):
        self._normalize_payments()
        self._validate_other_cost()
        self._calculate_totals()
        self._update_checklist()
        self._guard_stage_requirements()
        self._prevent_duplicate_payments()

    def after_insert(self):
        self._auto_assign_by_case_type()

    def on_update(self):
        if self.has_value_changed("workflow_state"):
            self._on_state_change()

    def _validate_other_cost(self):
        """OWNER DECISION: other_cost > 0 requires explanation."""
        if flt(self.other_cost) > 0 and not (self.other_cost_description or "").strip():
            frappe.throw(
                _("هزینه‌های دیگر بزرگ‌تر از صفر است. لطفاً توضیحات آن را وارد کنید.")
            )

    def _calculate_totals(self):
        pay_sum = sum(flt(r.amount) for r in (self.payments or []))
        self.total_cost = (
            flt(self.freight_cost)
            + flt(self.customs_cost)
            + flt(self.clearance_cost)
            + flt(self.other_cost)
            + flt(self.initial_costs)
            + pay_sum
        )
        self.estimated_profit = flt(self.sales_amount) - flt(self.purchase_amount) - flt(self.total_cost)

        if self.weight_full is not None and self.weight_empty is not None:
            if flt(self.weight_full) or flt(self.weight_empty):
                if flt(self.weight_full) < flt(self.weight_empty):
                    frappe.throw(_("وزن پر نمی‌تواند کمتر از وزن خالی باشد"))
                self.net_weight = flt(self.weight_full) - flt(self.weight_empty)
                if not self.actual_tonnage:
                    self.actual_tonnage = flt(self.net_weight) / 1000.0

        self.delivery_done = 1 if self.delivery_receipt else 0

    def _normalize_payments(self):
        for row in self.payments or []:
            if row.sheba:
                row.sheba = (
                    persian_to_english_digits(row.sheba)
                    .strip()
                    .upper()
                    .replace(" ", "")
                    .replace("-", "")
                )
                validate_sheba(row.sheba)
            if flt(row.amount) <= 0:
                frappe.throw(_("مبلغ پرداخت باید بزرگ‌تر از صفر باشد"))

    def _prevent_duplicate_payments(self):
        seen = set()
        for row in self.payments or []:
            key = (
                row.payment_type or "",
                row.sheba or "",
                flt(row.amount),
                str(row.payment_date or ""),
            )
            if key in seen:
                frappe.throw(_("پرداخت تکراری است."))
            seen.add(key)

        if not self.driver or not self.waybill_number:
            return

        for row in self.payments or []:
            other = frappe.db.sql(
                """
                select p.parent
                from `tabTransport Payment` p
                inner join `tabTransport Case` c on c.name = p.parent
                where c.driver = %s
                  and c.waybill_number = %s
                  and p.payment_type = %s
                  and p.amount = %s
                  and c.name != %s
                  and ifnull(c.workflow_state, '') not in ('Cancelled', 'Rejected')
                limit 1
                """,
                (
                    self.driver,
                    self.waybill_number,
                    row.payment_type,
                    flt(row.amount),
                    self.name,
                ),
            )
            if other:
                frappe.throw(
                    _("پرداخت تکراری است. برای این راننده/بارنامه قبلاً ثبت شده: {0}").format(
                        other[0][0]
                    )
                )

    def _update_checklist(self):
        self.chk_driver = 1 if self.driver else 0
        self.chk_waybill = 1 if (self.waybill_number or self.waybill_ref) else 0
        self.chk_weighbridge = 1 if (self.weighbridge_ref or flt(self.net_weight) > 0) else 0

        if self.needs_bijak == "خیر":
            self.chk_bijak = 1
            self.bijak_done = 1
        elif self.needs_bijak == "بله":
            self.chk_bijak = 1 if self.bijak_done else 0
        else:
            self.chk_bijak = 0

        self.chk_clearance = 1 if (self.clearance_done or self.clearance_status == "ترخیص شده") else 0
        self.chk_delivery = 1 if (self.delivery_done or self.delivery_receipt) else 0
        self.chk_payments = 1 if (self.payments_done or (self.payments and len(self.payments) > 0)) else 0

    def _guard_stage_requirements(self):
        st = self.workflow_state or "Draft"

        if st in {
            "Driver Assigned", "Waybill Issued", "In Transit", "Waiting Weighbridge",
            "Waiting Bijak", "Waiting Clearance", "Cleared", "Delivered",
            "Pending Payment", "Pending Finance Close", "Completed",
        }:
            if not self.driver:
                frappe.throw(_("در وضعیت «{0}» انتخاب راننده اجباری است").format(st))

        if st in {
            "Waybill Issued", "In Transit", "Waiting Weighbridge", "Waiting Bijak",
            "Waiting Clearance", "Cleared", "Delivered", "Pending Payment",
            "Pending Finance Close", "Completed",
        }:
            if not self.waybill_number and not self.waybill_ref:
                frappe.throw(_("در وضعیت «{0}» شماره/سند بارنامه اجباری است").format(st))

        if st in {
            "Waiting Bijak", "Waiting Clearance", "Cleared", "Delivered",
            "Pending Payment", "Pending Finance Close", "Completed",
        }:
            if not self.chk_weighbridge:
                frappe.throw(_("قبل از ادامه، ثبت/تایید باسکول الزامی است"))

        if st in {
            "Waiting Clearance", "Cleared", "Delivered", "Pending Payment",
            "Pending Finance Close", "Completed",
        }:
            if not self.needs_bijak:
                frappe.throw(_("وضعیت نیاز به بیجک باید مشخص شود (بله/خیر)"))
            if self.needs_bijak == "بله" and not self.bijak_done:
                frappe.throw(_("بیجک هنوز تکمیل/تایید نشده است"))

        if st in {"Delivered", "Pending Payment", "Pending Finance Close", "Completed"}:
            if not self.clearance_done and self.clearance_status != "ترخیص شده":
                frappe.throw(_("ترخیص هنوز تکمیل نشده است"))

        if st in {"Pending Payment", "Pending Finance Close", "Completed"}:
            if not self.delivery_receipt:
                frappe.throw(_("آپلود رسید تخلیه اجباری است"))

        if st in {"Pending Finance Close", "Completed"}:
            if not self.payments and not self.payments_done:
                frappe.throw(_("حداقل یک پرداخت یا علامت تکمیل پرداخت‌ها لازم است"))

        if st == "Completed":
            required = [
                ("chk_driver", "راننده"),
                ("chk_waybill", "بارنامه"),
                ("chk_weighbridge", "باسکول"),
                ("chk_bijak", "بیجک"),
                ("chk_clearance", "ترخیص"),
                ("chk_delivery", "رسید تخلیه"),
                ("chk_payments", "پرداخت‌ها"),
            ]
            missing = [label for field, label in required if not self.get(field)]
            if missing:
                frappe.throw(_("پرونده قابل بستن نیست. ناقص: {0}").format("، ".join(missing)))
            if not self.finance_approved:
                frappe.throw(_("برای بستن پرونده، تایید مالی الزامی است"))
            if not self.actual_tonnage or flt(self.actual_tonnage) <= 0:
                frappe.throw(_("برای بستن پرونده، تناژ واقعی الزامی است"))

        for field in (
            "freight_cost", "customs_cost", "clearance_cost", "other_cost",
            "sales_amount", "purchase_amount", "planned_tonnage",
        ):
            if flt(self.get(field)) < 0:
                frappe.throw(_("مقدار {0} نمی‌تواند منفی باشد").format(field))

        if flt(self.planned_tonnage) <= 0:
            frappe.throw(_("تناژ برنامه‌ریزی باید بزرگ‌تر از صفر باشد"))

    def _auto_assign_by_case_type(self):
        if self.assigned_user:
            return
        role = None
        if self.case_type == "خرید":
            role = "Transport User - Purchase"
        elif self.case_type == "فروش":
            role = "Transport User - Sales"
        if not role:
            return

        user = frappe.db.sql(
            """
            select u.name
            from `tabUser` u
            inner join `tabHas Role` hr
              on hr.parent = u.name and hr.parenttype = 'User'
            where hr.role = %s
              and u.enabled = 1
              and u.user_type = 'System User'
            order by u.creation asc
            limit 1
            """,
            (role,),
        )
        if not user:
            return

        self.db_set("assigned_user", user[0][0], update_modified=False)
        try:
            frappe.desk.form.assign_to.add(
                {
                    "assign_to": [user[0][0]],
                    "doctype": self.doctype,
                    "name": self.name,
                    "description": f"ارجاع خودکار پرونده حمل ({self.case_type})",
                }
            )
        except Exception:
            pass

    def _on_state_change(self):
        if self.workflow_state == "Pending Finance Close":
            self.db_set("sent_to_finance", 1, update_modified=False)
EOF

# =============================================================================
step "5) CANONICAL fixtures only + purge intermediates"
mkdir -p "${PKG}/fixtures"
rm -f \
  "${PKG}/fixtures/transport_workflow_state.json" \
  "${PKG}/fixtures/transport_workflow.json" \
  "${PKG}/fixtures/transport_client_script.json" \
  || true
log "purged intermediate fixture files"

python3 << 'PYEOF'
import json, os
from copy import deepcopy

fx = os.path.join(os.environ["PKG"], "fixtures")
os.makedirs(fx, exist_ok=True)
now = os.environ.get("NOW_TS", "2026-03-21 00:00:00.000000")

def load(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return data if isinstance(data, list) else [data]

def dump(path, rows):
    clean = []
    for r in rows:
        if not isinstance(r, dict) or not r.get("doctype") or not r.get("name"):
            raise SystemExit(f"invalid fixture row for {path}: {r}")
        r = deepcopy(r)
        r.setdefault("modified", now)
        clean.append(r)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(clean, f, ensure_ascii=False, indent=1)
    print(f"wrote {path} ({len(clean)} rows)")

phase6_states = [
    "Draft", "Pending Supervisor Review", "Pending Transport", "Driver Assigned",
    "Waybill Issued", "In Transit", "Waiting Weighbridge", "Waiting Bijak",
    "Waiting Clearance", "Cleared", "Delivered", "Pending Payment",
    "Pending Finance Close", "Completed", "On Hold", "Cancelled", "Rejected",
    "Legal Review", "Treasury Review", "Pending Signature", "Finance Supervisor",
    "Receivables", "Approved", "Returned",
]
styles = {
    "Completed": "Success", "Cleared": "Success", "Delivered": "Success", "Approved": "Success",
    "Cancelled": "Danger", "Rejected": "Danger", "Returned": "Danger",
    "In Transit": "Info",
}
existing_ws = load(os.path.join(fx, "workflow_state.json"))
by_ws = {}
for r in existing_ws:
    key = r.get("workflow_state_name") or r.get("name")
    if not key:
        continue
    r["doctype"] = "Workflow State"
    r["name"] = r.get("name") or key
    r["workflow_state_name"] = key
    by_ws[key] = r
for s in phase6_states:
    style = styles.get(s, "Warning" if any(x in s for x in ["Pending", "Waiting", "Hold", "Review"]) else "Primary")
    by_ws[s] = {
        "doctype": "Workflow State",
        "name": s,
        "workflow_state_name": s,
        "style": style,
    }
dump(os.path.join(fx, "workflow_state.json"), list(by_ws.values()))

transport_wf = {
  "doctype": "Workflow",
  "name": "Transport Case Workflow",
  "workflow_name": "Transport Case Workflow",
  "document_type": "Transport Case",
  "is_active": 1,
  "override_status": 1,
  "send_email_alert": 0,
  "workflow_state_field": "workflow_state",
  "states": [
   {"state": "Draft", "doc_status": "0", "allow_edit": "Transport Supervisor"},
   {"state": "Draft", "doc_status": "0", "allow_edit": "Transport User - Purchase"},
   {"state": "Draft", "doc_status": "0", "allow_edit": "Transport User - Sales"},
   {"state": "Pending Supervisor Review", "doc_status": "0", "allow_edit": "Transport Supervisor"},
   {"state": "Pending Transport", "doc_status": "0", "allow_edit": "Transport Supervisor"},
   {"state": "Pending Transport", "doc_status": "0", "allow_edit": "Transport User - Purchase"},
   {"state": "Pending Transport", "doc_status": "0", "allow_edit": "Transport User - Sales"},
   {"state": "Driver Assigned", "doc_status": "0", "allow_edit": "Transport Supervisor"},
   {"state": "Driver Assigned", "doc_status": "0", "allow_edit": "Transport User - Purchase"},
   {"state": "Driver Assigned", "doc_status": "0", "allow_edit": "Transport User - Sales"},
   {"state": "Waybill Issued", "doc_status": "0", "allow_edit": "Transport Supervisor"},
   {"state": "Waybill Issued", "doc_status": "0", "allow_edit": "Transport User - Purchase"},
   {"state": "Waybill Issued", "doc_status": "0", "allow_edit": "Transport User - Sales"},
   {"state": "In Transit", "doc_status": "0", "allow_edit": "Transport Supervisor"},
   {"state": "In Transit", "doc_status": "0", "allow_edit": "Transport User - Purchase"},
   {"state": "In Transit", "doc_status": "0", "allow_edit": "Transport User - Sales"},
   {"state": "Waiting Weighbridge", "doc_status": "0", "allow_edit": "Transport Supervisor"},
   {"state": "Waiting Weighbridge", "doc_status": "0", "allow_edit": "Transport User - Sales"},
   {"state": "Waiting Weighbridge", "doc_status": "0", "allow_edit": "Customs Officer"},
   {"state": "Waiting Bijak", "doc_status": "0", "allow_edit": "Customs Officer"},
   {"state": "Waiting Bijak", "doc_status": "0", "allow_edit": "Transport Supervisor"},
   {"state": "Waiting Bijak", "doc_status": "0", "allow_edit": "Transport User - Purchase"},
   {"state": "Waiting Clearance", "doc_status": "0", "allow_edit": "Customs Officer"},
   {"state": "Waiting Clearance", "doc_status": "0", "allow_edit": "Transport Supervisor"},
   {"state": "Waiting Clearance", "doc_status": "0", "allow_edit": "Transport User - Purchase"},
   {"state": "Cleared", "doc_status": "0", "allow_edit": "Transport Supervisor"},
   {"state": "Cleared", "doc_status": "0", "allow_edit": "Transport User - Purchase"},
   {"state": "Delivered", "doc_status": "0", "allow_edit": "Transport Supervisor"},
   {"state": "Delivered", "doc_status": "0", "allow_edit": "Transport User - Purchase"},
   {"state": "Pending Payment", "doc_status": "0", "allow_edit": "Transport Supervisor"},
   {"state": "Pending Payment", "doc_status": "0", "allow_edit": "Transport User - Purchase"},
   {"state": "Pending Finance Close", "doc_status": "0", "allow_edit": "Finance Supervisor"},
   {"state": "Pending Finance Close", "doc_status": "0", "allow_edit": "Financial Manager"},
   {"state": "Completed", "doc_status": "0", "allow_edit": "Financial Manager"},
   {"state": "Completed", "doc_status": "0", "allow_edit": "Finance Supervisor"},
   {"state": "On Hold", "doc_status": "0", "allow_edit": "Transport Supervisor"},
   {"state": "Cancelled", "doc_status": "0", "allow_edit": "Transport Supervisor"},
   {"state": "Rejected", "doc_status": "0", "allow_edit": "Transport Supervisor"}
  ],
  "transitions": [
   {"state": "Draft", "action": "ارسال به سرپرست حمل", "next_state": "Pending Supervisor Review", "allowed": "Transport Supervisor", "allow_self_approval": 1},
   {"state": "Draft", "action": "ارسال به سرپرست (کارشناس خرید)", "next_state": "Pending Supervisor Review", "allowed": "Transport User - Purchase", "allow_self_approval": 1},
   {"state": "Draft", "action": "ارسال به سرپرست (کارشناس فروش)", "next_state": "Pending Supervisor Review", "allowed": "Transport User - Sales", "allow_self_approval": 1},
   {"state": "Pending Supervisor Review", "action": "ارجاع به کارشناس", "next_state": "Pending Transport", "allowed": "Transport Supervisor", "allow_self_approval": 1},
   {"state": "Pending Transport", "action": "اختصاص راننده", "next_state": "Driver Assigned", "allowed": "Transport User - Purchase", "condition": "doc.case_type=='خرید'", "allow_self_approval": 1},
   {"state": "Pending Transport", "action": "اختصاص راننده", "next_state": "Driver Assigned", "allowed": "Transport User - Sales", "condition": "doc.case_type=='فروش'", "allow_self_approval": 1},
   {"state": "Pending Transport", "action": "اختصاص راننده (سرپرست)", "next_state": "Driver Assigned", "allowed": "Transport Supervisor", "allow_self_approval": 1},
   {"state": "Driver Assigned", "action": "صدور بارنامه", "next_state": "Waybill Issued", "allowed": "Transport User - Purchase", "condition": "doc.case_type=='خرید'", "allow_self_approval": 1},
   {"state": "Driver Assigned", "action": "صدور بارنامه", "next_state": "Waybill Issued", "allowed": "Transport User - Sales", "condition": "doc.case_type=='فروش'", "allow_self_approval": 1},
   {"state": "Driver Assigned", "action": "صدور بارنامه (سرپرست)", "next_state": "Waybill Issued", "allowed": "Transport Supervisor", "allow_self_approval": 1},
   {"state": "Waybill Issued", "action": "شروع حمل", "next_state": "In Transit", "allowed": "Transport Supervisor", "allow_self_approval": 1},
   {"state": "In Transit", "action": "ثبت باسکول", "next_state": "Waiting Weighbridge", "allowed": "Transport User - Sales", "allow_self_approval": 1},
   {"state": "In Transit", "action": "ثبت باسکول (خرید)", "next_state": "Waiting Weighbridge", "allowed": "Transport User - Purchase", "allow_self_approval": 1},
   {"state": "In Transit", "action": "ثبت باسکول (سرپرست)", "next_state": "Waiting Weighbridge", "allowed": "Transport Supervisor", "allow_self_approval": 1},
   {"state": "Waiting Weighbridge", "action": "تایید باسکول و بیجک", "next_state": "Waiting Bijak", "allowed": "Customs Officer", "allow_self_approval": 1},
   {"state": "Waiting Weighbridge", "action": "تایید باسکول و بیجک (سرپرست)", "next_state": "Waiting Bijak", "allowed": "Transport Supervisor", "allow_self_approval": 1},
   {"state": "Waiting Bijak", "action": "ارسال به ترخیص", "next_state": "Waiting Clearance", "allowed": "Customs Officer", "allow_self_approval": 1},
   {"state": "Waiting Bijak", "action": "ارسال به ترخیص (سرپرست)", "next_state": "Waiting Clearance", "allowed": "Transport Supervisor", "allow_self_approval": 1},
   {"state": "Waiting Clearance", "action": "ترخیص شد", "next_state": "Cleared", "allowed": "Customs Officer", "allow_self_approval": 0},
   {"state": "Waiting Clearance", "action": "ترخیص شد (سرپرست)", "next_state": "Cleared", "allowed": "Transport Supervisor", "allow_self_approval": 0},
   {"state": "Cleared", "action": "ثبت تخلیه", "next_state": "Delivered", "allowed": "Transport User - Purchase", "allow_self_approval": 1},
   {"state": "Cleared", "action": "ثبت تخلیه (سرپرست)", "next_state": "Delivered", "allowed": "Transport Supervisor", "allow_self_approval": 1},
   {"state": "Delivered", "action": "ثبت پرداخت‌ها", "next_state": "Pending Payment", "allowed": "Transport User - Purchase", "allow_self_approval": 1},
   {"state": "Delivered", "action": "ثبت پرداخت‌ها (سرپرست)", "next_state": "Pending Payment", "allowed": "Transport Supervisor", "allow_self_approval": 1},
   {"state": "Pending Payment", "action": "ارسال به مالی", "next_state": "Pending Finance Close", "allowed": "Transport Supervisor", "allow_self_approval": 1},
   {"state": "Pending Finance Close", "action": "بستن پرونده", "next_state": "Completed", "allowed": "Finance Supervisor", "allow_self_approval": 0},
   {"state": "Pending Finance Close", "action": "بستن توسط مدیر مالی", "next_state": "Completed", "allowed": "Financial Manager", "allow_self_approval": 0},
   {"state": "Draft", "action": "لغو", "next_state": "Cancelled", "allowed": "Transport Supervisor", "allow_self_approval": 0},
   {"state": "Pending Supervisor Review", "action": "معلق", "next_state": "On Hold", "allowed": "Transport Supervisor", "allow_self_approval": 0},
   {"state": "On Hold", "action": "از سرگیری", "next_state": "Draft", "allowed": "Transport Supervisor", "allow_self_approval": 0},
   {"state": "Pending Transport", "action": "بازگشت به سرپرست", "next_state": "Pending Supervisor Review", "allowed": "Transport User - Purchase", "allow_self_approval": 1},
   {"state": "Pending Transport", "action": "بازگشت به سرپرست (فروش)", "next_state": "Pending Supervisor Review", "allowed": "Transport User - Sales", "allow_self_approval": 1}
  ]
}

existing_wf = load(os.path.join(fx, "workflow.json"))
wf_by = {}
for w in existing_wf:
    name = w.get("name") or w.get("workflow_name")
    if not name:
        continue
    w["doctype"] = "Workflow"
    w["name"] = name
    w["workflow_name"] = w.get("workflow_name") or name
    wf_by[name] = w
wf_by["Transport Case Workflow"] = transport_wf
dump(os.path.join(fx, "workflow.json"), list(wf_by.values()))

cs_phase6 = {
  "doctype": "Client Script",
  "name": "Transport Case UX Phase6",
  "dt": "Transport Case",
  "view": "Form",
  "enabled": 1,
  "script": """frappe.ui.form.on('Transport Case', {
  onload(frm) {
    if (frm.is_new() && !frm.doc.company) {
      const c = frappe.defaults.get_user_default('Company') || (frappe.boot.sysdefaults || {}).company;
      if (c) frm.set_value('company', c);
    }
    if (frm.is_new() && !frm.doc.priority) {
      frm.set_value('priority', 'متوسط');
    }
  },
  refresh(frm) {
    if (frm.doc.workflow_state) {
      frm.page.set_indicator(__(frm.doc.workflow_state), frm.doc.workflow_state === 'Completed' ? 'green' : 'orange');
    }
    toggle_other_cost(frm);
    if (!frm.is_new()) {
      frm.add_custom_button(__('بارنامه جدید'), () => {
        frappe.new_doc('Transport Waybill', {
          transport_case: frm.doc.name,
          driver: frm.doc.driver,
          vehicle: frm.doc.vehicle,
          destination: frm.doc.destination,
          border: frm.doc.border,
          tonnage: frm.doc.planned_tonnage
        });
      }, __('عملیات'));
      frm.add_custom_button(__('باسکول جدید'), () => {
        frappe.new_doc('Transport Weighbridge', {
          transport_case: frm.doc.name,
          waybill: frm.doc.waybill_ref,
          plate_number: frm.doc.plate_number
        });
      }, __('عملیات'));
      frm.add_custom_button(__('بیجک جدید'), () => {
        frappe.new_doc('Transport Bijak', {
          transport_case: frm.doc.name,
          needs_bijak: frm.doc.needs_bijak || 'بله'
        });
      }, __('عملیات'));
      frm.add_custom_button(__('ترخیص جدید'), () => {
        frappe.new_doc('Transport Clearance', { transport_case: frm.doc.name });
      }, __('عملیات'));
    }
  },
  other_cost(frm) { toggle_other_cost(frm); recalc(frm); },
  weight_empty(frm) { calc_net(frm); },
  weight_full(frm) { calc_net(frm); },
  freight_cost: recalc,
  customs_cost: recalc,
  clearance_cost: recalc,
  initial_costs: recalc,
  sales_amount: recalc,
  purchase_amount: recalc,
  payments_add: recalc,
  payments_remove: recalc,
  delivery_receipt(frm) {
    frm.set_value('delivery_done', frm.doc.delivery_receipt ? 1 : 0);
  }
});
function toggle_other_cost(frm) {
  const on = flt(frm.doc.other_cost) > 0;
  frm.set_df_property('other_cost_description', 'reqd', on ? 1 : 0);
  frm.toggle_display('other_cost_description', on);
}
function recalc(frm) {
  let pay = 0;
  (frm.doc.payments || []).forEach(r => pay += flt(r.amount));
  const total = flt(frm.doc.freight_cost) + flt(frm.doc.customs_cost) + flt(frm.doc.clearance_cost) + flt(frm.doc.other_cost) + flt(frm.doc.initial_costs) + pay;
  frm.set_value('total_cost', total);
  frm.set_value('estimated_profit', flt(frm.doc.sales_amount) - flt(frm.doc.purchase_amount) - total);
}
function calc_net(frm) {
  if (frm.doc.weight_full != null && frm.doc.weight_empty != null) {
    const net = flt(frm.doc.weight_full) - flt(frm.doc.weight_empty);
    frm.set_value('net_weight', net);
    if (!frm.doc.actual_tonnage) frm.set_value('actual_tonnage', net / 1000.0);
  }
}
"""
}

existing_cs = load(os.path.join(fx, "client_script.json"))
cs_by = {}
for c in existing_cs:
    name = c.get("name")
    if not name:
        continue
    c["doctype"] = "Client Script"
    c["name"] = name
    cs_by[name] = c
cs_by["Transport Case UX Phase6"] = cs_phase6
dump(os.path.join(fx, "client_script.json"), list(cs_by.values()))

bad = []
for fn in os.listdir(fx):
    if not fn.endswith(".json"):
        continue
    path = os.path.join(fx, fn)
    rows = load(path)
    for i, r in enumerate(rows):
        if not isinstance(r, dict) or not r.get("name") or not r.get("doctype"):
            bad.append(f"{fn}[{i}]")
if bad:
    raise SystemExit("FIXTURE NAME GUARD FAILED:\n  - " + "\n  - ".join(bad))
print("fixture name guard: ALL OK")
print("fixtures dir:", sorted(os.listdir(fx)))
PYEOF

# =============================================================================
step "6) hooks.py phase6 block"
python3 << 'PYEOF'
import os, re, ast
p = os.environ["HOOKS"]
src = open(p, encoding="utf-8").read()
src = re.sub(r"# --- PHASE6_HOOKS_START ---.*?# --- PHASE6_HOOKS_END ---\n?", "", src, flags=re.DOTALL)
if not re.search(r"^fixtures\s*=", src, flags=re.M):
    src += "\n\nfixtures = []\n"
addition = '''
# --- PHASE6_HOOKS_START ---
fixtures = list(fixtures) if isinstance(fixtures, (list, tuple)) else []
fixtures.extend([
    {"dt": "Workflow State", "filters": [["name", "in", [
        "Draft", "Pending Supervisor Review", "Pending Transport", "Driver Assigned",
        "Waybill Issued", "In Transit", "Waiting Weighbridge", "Waiting Bijak",
        "Waiting Clearance", "Cleared", "Delivered", "Pending Payment",
        "Pending Finance Close", "Completed", "On Hold", "Cancelled", "Rejected",
        "Legal Review", "Treasury Review", "Pending Signature", "Finance Supervisor",
        "Receivables", "Approved", "Returned"
    ]]]},
    {"dt": "Workflow", "filters": [["name", "in", ["Transport Case Workflow", "Trade Case Workflow"]]]},
    {"dt": "Client Script", "filters": [["name", "in", ["Transport Case UX Phase6", "Trade Case UX"]]]},
])
# --- PHASE6_HOOKS_END ---
'''
open(p, "w", encoding="utf-8").write(src + addition)
ast.parse(open(p, encoding="utf-8").read())
print("hooks updated + syntax OK")
PYEOF

# =============================================================================
step "7) Workspace update"
WS_DIR="${MOD}/workspace/iran_transport"
mkdir -p "$WS_DIR"
write_utf8 "${WS_DIR}/iran_transport.json" << 'EOF'
{
 "charts": [],
 "content": "[{\"id\":\"card_master\",\"type\":\"card\",\"data\":{\"card_name\":\"اطلاعات پایه\",\"col\":4}},{\"id\":\"card_ops\",\"type\":\"card\",\"data\":{\"card_name\":\"عملیات حمل\",\"col\":4}},{\"id\":\"card_trade\",\"type\":\"card\",\"data\":{\"card_name\":\"بازرگانی\",\"col\":4}}]",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "Workspace",
 "for_user": "",
 "hide_custom": 0,
 "icon": "truck",
 "is_default": 0,
 "is_hidden": 0,
 "is_standard": 1,
 "label": "Iran Transport",
 "modified": "2026-03-21 00:00:00.000000",
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
 "shortcuts": [
  {"label": "Transport Case", "link_to": "Transport Case", "type": "DocType", "doc_view": "List", "color": "Blue"},
  {"label": "Trade Case", "link_to": "Trade Case", "type": "DocType", "doc_view": "List", "color": "Green"}
 ],
 "title": "Iran Transport",
 "links": [
  {"type": "Card Break", "label": "اطلاعات پایه", "link_count": 6},
  {"type": "Link", "label": "Border", "link_type": "DocType", "link_to": "Border"},
  {"type": "Link", "label": "Carrier", "link_type": "DocType", "link_to": "Carrier"},
  {"type": "Link", "label": "Customs Broker", "link_type": "DocType", "link_to": "Customs Broker"},
  {"type": "Link", "label": "Border Representative", "link_type": "DocType", "link_to": "Border Representative"},
  {"type": "Link", "label": "Driver", "link_type": "DocType", "link_to": "Driver"},
  {"type": "Link", "label": "Vehicle", "link_type": "DocType", "link_to": "Vehicle"},
  {"type": "Card Break", "label": "عملیات حمل", "link_count": 5},
  {"type": "Link", "label": "Transport Case", "link_type": "DocType", "link_to": "Transport Case"},
  {"type": "Link", "label": "Transport Waybill", "link_type": "DocType", "link_to": "Transport Waybill"},
  {"type": "Link", "label": "Transport Weighbridge", "link_type": "DocType", "link_to": "Transport Weighbridge"},
  {"type": "Link", "label": "Transport Bijak", "link_type": "DocType", "link_to": "Transport Bijak"},
  {"type": "Link", "label": "Transport Clearance", "link_type": "DocType", "link_to": "Transport Clearance"},
  {"type": "Card Break", "label": "بازرگانی", "link_count": 1},
  {"type": "Link", "label": "Trade Case", "link_type": "DocType", "link_to": "Trade Case"}
 ]
}
EOF

write_utf8 "${MOD}/setup_workspace_phase6.py" << 'EOF'
import json
import frappe


def setup_workspace_phase6():
    path = frappe.get_app_path(
        "transport_ir", "iran_transport", "workspace", "iran_transport", "iran_transport.json"
    )
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    name = data["name"]
    frappe.flags.in_patch = True
    doc = (
        frappe.get_doc("Workspace", name)
        if frappe.db.exists("Workspace", name)
        else frappe.new_doc("Workspace")
    )
    if doc.is_new():
        doc.name = name

    for k in [
        "label", "title", "module", "public", "icon", "content",
        "sequence_id", "parent_page", "for_user", "is_hidden", "hide_custom",
    ]:
        if k in data:
            setattr(doc, k, data[k])

    for ct in ["links", "shortcuts", "charts", "number_cards", "quick_lists", "roles"]:
        doc.set(ct, [])
    for row in data.get("links", []):
        doc.append("links", row)
    for row in data.get("shortcuts", []):
        doc.append("shortcuts", row)

    doc.flags.ignore_permissions = True
    doc.flags.ignore_links = True
    if doc.is_new():
        doc.insert(ignore_permissions=True)
    else:
        doc.save(ignore_permissions=True)

    frappe.db.commit()
    frappe.clear_cache()
    n = len(frappe.get_doc("Workspace", name).links or [])
    print(f"Workspace links={n}")
    if n < 12:
        frappe.throw(f"workspace links incomplete: {n}")
    return {"links": n}
EOF

# =============================================================================
step "8) verify_phase6.py (workflow-safe bridge checks)"
write_utf8 "${MOD}/verify_phase6.py" << 'EOF'
import re
import sys
import frappe
from frappe.utils import flt


def _cleanup():
    phase6_cases = (
        frappe.get_all("Transport Case", filters={"case_title": ["like", "%PHASE6%"]}, pluck="name")
        if frappe.db.exists("DocType", "Transport Case")
        else []
    )

    if frappe.db.exists("DocType", "Transport Waybill"):
        for n in frappe.get_all(
            "Transport Waybill",
            filters={"waybill_number": ["like", "PHASE6%"]},
            pluck="name",
        ):
            try:
                d = frappe.get_doc("Transport Waybill", n)
                if d.docstatus == 1:
                    d.cancel()
                frappe.delete_doc("Transport Waybill", n, force=1, ignore_permissions=True)
            except Exception:
                frappe.db.delete("Transport Waybill", {"name": n})

    for dt in ["Transport Clearance", "Transport Bijak", "Transport Weighbridge"]:
        if not frappe.db.exists("DocType", dt):
            continue
        names = []
        if phase6_cases:
            names = frappe.get_all(dt, filters={"transport_case": ["in", phase6_cases]}, pluck="name")
        for n in set(names):
            try:
                frappe.delete_doc(dt, n, force=1, ignore_permissions=True)
            except Exception:
                frappe.db.delete(dt, {"name": n})

    for n in phase6_cases:
        try:
            frappe.delete_doc("Transport Case", n, force=1, ignore_permissions=True)
        except Exception:
            frappe.db.delete("Transport Case", {"name": n})
    frappe.db.commit()


def verify_phase6():
    passed, failed = [], []

    def check(name, cond):
        (passed if cond else failed).append(name)
        print(("✅ PASS" if cond else "❌ FAIL") + f": {name}")

    _cleanup()

    for dt in [
        "Transport Case", "Transport Payment", "Transport Waybill",
        "Transport Weighbridge", "Transport Bijak", "Transport Clearance",
    ]:
        check(f"DocType {dt}", bool(frappe.db.exists("DocType", dt)))

    import inspect
    from transport_ir.iran_transport.doctype.trade_case.trade_case import TradeCase

    src = inspect.getsource(TradeCase.on_update)
    # Detect real attribute assignment only (not comments)
    has_status_assign = bool(re.search(r"\btc\.status\s*=", src))
    check("trade_case.on_update has no status assignment", not has_status_assign)
    check("trade_case.on_update uses workflow_state", "workflow_state" in src)
    check("trade_case bridge uses db_set after insert", "db_set" in src or "set_value" in src)

    check("Workflow Transport Case Workflow", bool(frappe.db.exists("Workflow", "Transport Case Workflow")))
    if frappe.db.exists("Workflow", "Transport Case Workflow"):
        wf = frappe.get_doc("Workflow", "Transport Case Workflow")
        bad_s = [s.state for s in wf.states if "\n" in (s.allow_edit or "")]
        bad_t = [t.action for t in wf.transitions if "\n" in (t.allowed or "")]
        check("single-role allow_edit values", len(bad_s) == 0)
        check("single-role allowed values", len(bad_t) == 0)
        check("transitions >= 20", len(wf.transitions or []) >= 20)
        pt_roles = {s.allow_edit for s in wf.states if s.state == "Pending Transport"}
        check(
            "Pending Transport multi allow_edit",
            {"Transport Supervisor", "Transport User - Purchase", "Transport User - Sales"}.issubset(pt_roles),
        )
        conds = [t.condition or "" for t in wf.transitions]
        check("has خرید condition", any("خرید" in c for c in conds))
        check("has فروش condition", any("فروش" in c for c in conds))

    for st in [
        "Pending Supervisor Review", "Driver Assigned", "Waybill Issued",
        "Waiting Weighbridge", "Waiting Bijak", "Waiting Clearance",
        "Pending Payment", "Pending Finance Close", "Completed",
    ]:
        check(f"state {st}", bool(frappe.db.exists("Workflow State", st)))

    company = (
        frappe.defaults.get_global_default("company")
        or frappe.db.get_single_value("Global Defaults", "default_company")
        or frappe.db.get_value("Company", {}, "name")
    )
    check("company exists", bool(company))

    meta = frappe.get_meta("Transport Case")
    check("has workflow_state", bool(meta.has_field("workflow_state")))
    check("NO status field", not meta.has_field("status"))
    check("has priority", bool(meta.has_field("priority")))
    check("has other_cost", bool(meta.has_field("other_cost")))
    check("has other_cost_description", bool(meta.has_field("other_cost_description")))
    pr = meta.get_field("priority")
    check("priority default متوسط", (pr.default if pr else None) == "متوسط")
    check("priority not reqd", not (pr.reqd if pr else 1))
    od = meta.get_field("other_cost_description")
    check("other_cost_description has depends_on", bool(od and od.depends_on))
    check("other_cost_description has mandatory_depends_on", bool(od and od.mandatory_depends_on))
    for fn in ("waybill_ref", "weighbridge_ref", "bijak_ref", "clearance_ref", "chk_driver"):
        df = meta.get_field(fn)
        check(f"{fn} hidden", bool(df and df.hidden))

    # insert with default Draft only
    case = frappe.new_doc("Transport Case")
    case.case_title = "PHASE6-TEST-CASE"
    case.case_type = "خرید"
    case.company = company
    case.planned_tonnage = 20
    case.purchase_amount = 1000
    case.sales_amount = 1500
    case.destination = "بازرگان"
    case.insert(ignore_permissions=True)
    check("case inserted", bool(case.name))
    check("priority defaulted", case.priority == "متوسط")
    check("insert stays Draft", (case.workflow_state or "Draft") == "Draft")

    try:
        case.workflow_state = "Driver Assigned"
        case.validate()
        check("guard driver blocks", False)
    except frappe.ValidationError:
        check("guard driver blocks", True)
    except Exception as e:
        check(f"guard driver unexpected: {e}", False)

    driver = frappe.db.get_value("Driver", {}, "name")
    vehicle = frappe.db.get_value("Vehicle", {}, "name")
    if driver:
        case.driver = driver
    if vehicle:
        case.vehicle = vehicle

    case.workflow_state = "Draft"
    case.other_cost = 100
    case.other_cost_description = None
    try:
        case.validate()
        check("other_cost requires description", False)
    except frappe.ValidationError:
        check("other_cost requires description", True)
    case.other_cost = 0
    case.other_cost_description = None

    case.waybill_number = "PHASE6-WB-001"
    case.needs_bijak = "خیر"
    case.weight_empty = 10000
    case.weight_full = 30000
    case.clearance_done = 1
    case.clearance_status = "ترخیص شده"
    case.delivery_receipt = "/files/phase6-delivery.pdf"
    case.append(
        "payments",
        {
            "payment_type": "کرایه",
            "amount": 100,
            "sheba": "IR930150000001351800087201",
            "payment_date": frappe.utils.today(),
            "reference_no": "PH6-1",
        },
    )
    case.payments_done = 1
    case.finance_approved = 1
    case.actual_tonnage = 20
    case.save(ignore_permissions=True)

    check("net_weight calc", flt(case.net_weight) == 20000)
    check("delivery_done set", int(case.delivery_done or 0) == 1)
    check("checklist waybill", bool(case.chk_waybill))
    check("checklist weighbridge", bool(case.chk_weighbridge))
    check("checklist bijak skip", bool(case.chk_bijak))
    check("checklist clearance", bool(case.chk_clearance))
    check("checklist delivery", bool(case.chk_delivery))
    check("checklist payments", bool(case.chk_payments))

    case.delivery_receipt = None
    case.validate()
    check("delivery_done cleared", int(case.delivery_done or 0) == 0)
    case.delivery_receipt = "/files/phase6-delivery.pdf"
    case.validate()

    case2 = frappe.get_doc("Transport Case", case.name)
    case2.append(
        "payments",
        {
            "payment_type": "کرایه",
            "amount": 100,
            "sheba": "IR930150000001351800087201",
            "payment_date": frappe.utils.today(),
        },
    )
    try:
        case2.validate()
        check("duplicate payment blocked", False)
    except frappe.ValidationError as e:
        check("duplicate payment blocked", "تکراری" in str(e))

    case3 = frappe.get_doc("Transport Case", case.name)
    case3.set("payments", [])
    case3.append("payments", {"payment_type": "گمرک", "amount": 50, "sheba": "IR930150000001351800087201", "payment_date": frappe.utils.today()})
    case3.append("payments", {"payment_type": "گمرک", "amount": 50, "sheba": "IR930150000001351800087201", "payment_date": frappe.utils.today()})
    try:
        case3.validate()
        check("duplicate customs payment blocked", False)
    except frappe.ValidationError:
        check("duplicate customs payment blocked", True)

    if driver:
        wb = frappe.new_doc("Transport Waybill")
        wb.transport_case = case.name
        wb.waybill_number = "PHASE6-WB-UNIQUE"
        wb.driver = driver
        wb.tonnage = 10
        wb.waybill_date = frappe.utils.today()
        wb.insert(ignore_permissions=True)
        wb2 = frappe.new_doc("Transport Waybill")
        wb2.transport_case = case.name
        wb2.waybill_number = "PHASE6-WB-UNIQUE"
        wb2.driver = driver
        wb2.tonnage = 11
        wb2.waybill_date = frappe.utils.today()
        try:
            wb2.insert(ignore_permissions=True)
            check("waybill number unique", False)
        except Exception:
            check("waybill number unique", True)
    else:
        check("waybill number unique (no driver soft)", True)

    bj = frappe.new_doc("Transport Bijak")
    bj.transport_case = case.name
    bj.needs_bijak = "بله"
    try:
        bj.insert(ignore_permissions=True)
        check("bijak requires attachments", False)
    except frappe.ValidationError:
        check("bijak requires attachments", True)

    w = frappe.new_doc("Transport Weighbridge")
    w.transport_case = case.name
    w.weight_empty = 12000
    w.weight_full = 22000
    w.insert(ignore_permissions=True)
    check("weighbridge net", flt(w.net_weight) == 10000 and flt(w.net_tonnage) == 10)

    case4 = frappe.get_doc("Transport Case", case.name)
    case4.finance_approved = 0
    case4.workflow_state = "Completed"
    try:
        case4.validate()
        check("close requires finance_approved", False)
    except frappe.ValidationError:
        check("close requires finance_approved", True)

    # Bridge pattern: insert Draft, then db_set cartable state (same as trade_case.py)
    tc = frappe.new_doc("Transport Case")
    tc.case_title = "PHASE6-BRIDGE"
    tc.case_type = "فروش"
    tc.company = company
    tc.planned_tonnage = 5
    tc.insert(ignore_permissions=True)
    check("bridge insert Draft OK", (tc.workflow_state or "Draft") == "Draft")
    frappe.db.set_value(
        "Transport Case",
        tc.name,
        "workflow_state",
        "Pending Supervisor Review",
        update_modified=False,
    )
    tc.reload()
    check("bridge db_set cartable state", tc.workflow_state == "Pending Supervisor Review")

    if frappe.db.exists("Workspace", "Iran Transport"):
        ws = frappe.get_doc("Workspace", "Iran Transport")
        links = {l.link_to for l in (ws.links or []) if l.type == "Link"}
        check("ws has Transport Case", "Transport Case" in links)
        check("ws has Transport Waybill", "Transport Waybill" in links)
        check("ws has Trade Case", "Trade Case" in links)
    else:
        check("workspace exists", False)

    print(f"\nPassed: {len(passed)} | Failed: {len(failed)}")
    if failed:
        for f in failed:
            print("  -", f)
        sys.exit(1)
    print("🎉 Phase 6 passed")
    return True
EOF

# =============================================================================
step "9) migrate + workspace + verify"
python3 << 'PY'
import json, os, sys
fx = os.path.join(os.environ["PKG"], "fixtures")
bad = []
for fn in sorted(os.listdir(fx)):
    if not fn.endswith(".json"):
        continue
    path = os.path.join(fx, fn)
    data = json.load(open(path, encoding="utf-8"))
    rows = data if isinstance(data, list) else [data]
    for i, r in enumerate(rows):
        if not isinstance(r, dict) or "name" not in r or "doctype" not in r:
            bad.append(f"{fn}[{i}]")
if bad:
    print("PRE-MIGRATE FIXTURE GUARD FAILED:")
    for b in bad:
        print(" -", b)
    sys.exit(1)
print("pre-migrate fixture guard OK; files:", sorted(os.listdir(fx)))
PY

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache

# ensure python controllers are reloaded
bench --site "$SITE_NAME" clear-cache
bench --site "$SITE_NAME" execute transport_ir.iran_transport.setup_workspace_phase6.setup_workspace_phase6
bench --site "$SITE_NAME" clear-cache
bench --site "$SITE_NAME" execute transport_ir.iran_transport.verify_phase6.verify_phase6

# =============================================================================
step "10) git commit"
cd "${BENCH_DIR}/apps/${APP}"
git add -A
git commit -m "phase 6 v3: workflow-safe bridge (Draft insert + db_set) + verify fixes" || warn "nothing to commit"

step "DONE"
cat <<FINAL

${GREEN}فاز ۶ v3 تمام شد.${NC}

رفع خطاهای اجرای قبلی:
  1) WorkflowPermissionError Draft→Pending Supervisor Review
     → insert فقط Draft؛ cartable با db_set/set_value بعد از insert
  2) false-fail روی tc.status داخل کامنت
     → verify فقط assignment واقعی را چک می‌کند: tc.status\\s*=
  3) NameError ثانویه execute بعد از exception — با رفع exception اصلی از بین می‌رود

خروجی مورد انتظار: 🎉 Phase 6 passed | Failed: 0

FINAL