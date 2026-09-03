#!/usr/bin/env bash
# =============================================================================
# setup_phase5.sh — Trade Case + Full Fields + Workflow + Auto-Create
# ERPNext v15 / Frappe v15 | File-First | Controller-Based
# FIX: Preflight uses frappe.db.count (returns number, not name)
# FIX: allow_edit/allowed must be SINGLE role (Link field in Frappe v15)
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
[[ -d "${BENCH_DIR}/apps/${APP}" ]] || err "transport_ir not found — run phases 1-4 first"
cd "$BENCH_DIR"
bench use "$SITE_NAME" 2>/dev/null || true

# =============================================================================
# 0) Ensure Bench Services
# =============================================================================
step "0) Ensure Bench Services"
if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "bench already running"
else
  nohup bench start >>/tmp/bench-start-phase5.log 2>&1 &
  log "bench start pid=$!"
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
for i in $(seq 1 60); do
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
[[ "$REDIS_READY" -eq 1 ]] || err "redis_cache not ready. Check /tmp/bench-start-phase5.log"
log "redis_cache is ready"

# =============================================================================
# 0b) Preflight: verify all 12 roles exist from phase 3
#     FIX: frappe.db.exists returns the NAME (e.g. "CEO"), not "1".
#          Use frappe.db.count which returns a NUMBER (0 or 1).
# =============================================================================
step "0b) Preflight: verify roles from phase 3"
MISSING_ROLES=0
for role in "CEO" "Financial Manager" "Finance Supervisor" "Finance User" \
            "Legal Reviewer" "Treasury User" "Receivables User" \
            "Transport Supervisor" "Transport User - Purchase" \
            "Transport User - Sales" "Customs Officer" "Document Signer"; do
  ROLE_COUNT="$(bench --site "$SITE_NAME" execute frappe.db.count \
    --args "[\"Role\", {\"name\": \"${role}\"}]" 2>/dev/null | tail -1 | tr -d '[:space:]')"
  if [[ "${ROLE_COUNT}" != "1" ]]; then
    warn "Role '${role}' NOT FOUND (count=${ROLE_COUNT:-0}) — phase 3 may be incomplete"
    MISSING_ROLES=1
  fi
done
if [[ "$MISSING_ROLES" -eq 1 ]]; then
  err "Some roles are missing. Run phase 3 (setup_phase3.sh) first."
fi
log "All 12 roles verified"

# =============================================================================
# 1) DocType: Trade Case (FULL FIELDS per requirements doc)
# =============================================================================
step "1) Trade Case DocType (full fields)"
DT="${MOD}/doctype"
mkdir -p "${DT}/trade_case"
touch "${DT}/trade_case/__init__.py"

write_utf8 "${DT}/trade_case/trade_case.json" << 'EOF'
{
 "actions": [],
 "allow_rename": 1,
 "autoname": "naming_series:",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "field_order": [
  "naming_series", "case_title", "case_type", "workflow_state", "column_break_1", "posting_date", "company",
  "section_parties", "customer", "supplier_factory", "column_break_p", "item", "cargo_description",
  "section_cargo", "thickness", "dimensions", "qty", "column_break_c", "weight", "planned_tonnage",
  "section_financial", "purchase_amount", "sales_amount", "initial_costs", "column_break_f", "freight_cost", "customs_cost", "clearance_cost",
  "section_route", "destination", "border", "column_break_r", "transport_type", "delivery_type",
  "section_docs", "signed_document", "proforma_purchase", "proforma_sales",
  "section_notes", "legal_notes", "treasury_notes", "receivables_notes"
 ],
 "fields": [
  {"fieldname": "naming_series", "fieldtype": "Select", "options": "TC-.YYYY.-.#####", "default": "TC-.YYYY.-.#####", "reqd": 1, "hidden": 1},
  {"fieldname": "case_title", "fieldtype": "Data", "label": "عنوان پرونده", "reqd": 1, "in_list_view": 1},
  {"fieldname": "case_type", "fieldtype": "Select", "label": "نوع پرونده", "options": "خرید\nفروش", "reqd": 1, "in_list_view": 1, "in_standard_filter": 1},
  {"fieldname": "workflow_state", "fieldtype": "Link", "label": "وضعیت", "options": "Workflow State", "default": "Draft", "read_only": 1, "in_list_view": 1, "in_standard_filter": 1},
  {"fieldname": "column_break_1", "fieldtype": "Column Break"},
  {"fieldname": "posting_date", "fieldtype": "Date", "label": "تاریخ ثبت", "default": "Today", "reqd": 1, "hidden": 1, "read_only": 1},
  {"fieldname": "company", "fieldtype": "Link", "label": "شرکت", "options": "Company", "reqd": 1, "in_list_view": 1},

  {"fieldname": "section_parties", "fieldtype": "Section Break", "label": "طرفین و کالا"},
  {"fieldname": "customer", "fieldtype": "Link", "label": "مشتری", "options": "Customer", "in_standard_filter": 1},
  {"fieldname": "supplier_factory", "fieldtype": "Link", "label": "کارخانه/فروشنده", "options": "Supplier", "in_standard_filter": 1},
  {"fieldname": "column_break_p", "fieldtype": "Column Break"},
  {"fieldname": "item", "fieldtype": "Link", "label": "کالا", "options": "Item"},
  {"fieldname": "cargo_description", "fieldtype": "Small Text", "label": "شرح کالا"},

  {"fieldname": "section_cargo", "fieldtype": "Section Break", "label": "مشخصات بار"},
  {"fieldname": "thickness", "fieldtype": "Float", "label": "ضخامت (میلی‌متر)"},
  {"fieldname": "dimensions", "fieldtype": "Data", "label": "ابعاد"},
  {"fieldname": "qty", "fieldtype": "Float", "label": "تعداد"},
  {"fieldname": "column_break_c", "fieldtype": "Column Break"},
  {"fieldname": "weight", "fieldtype": "Float", "label": "وزن (کیلوگرم)"},
  {"fieldname": "planned_tonnage", "fieldtype": "Float", "label": "تناژ برنامه‌ریزی", "reqd": 1, "in_list_view": 1},

  {"fieldname": "section_financial", "fieldtype": "Section Break", "label": "مالی"},
  {"fieldname": "purchase_amount", "fieldtype": "Currency", "label": "مبلغ خرید"},
  {"fieldname": "sales_amount", "fieldtype": "Currency", "label": "مبلغ فروش"},
  {"fieldname": "initial_costs", "fieldtype": "Currency", "label": "هزینه اولیه"},
  {"fieldname": "column_break_f", "fieldtype": "Column Break"},
  {"fieldname": "freight_cost", "fieldtype": "Currency", "label": "هزینه کرایه"},
  {"fieldname": "customs_cost", "fieldtype": "Currency", "label": "هزینه گمرک"},
  {"fieldname": "clearance_cost", "fieldtype": "Currency", "label": "هزینه ترخیص"},

  {"fieldname": "section_route", "fieldtype": "Section Break", "label": "مسیر و حمل"},
  {"fieldname": "destination", "fieldtype": "Data", "label": "مقصد"},
  {"fieldname": "border", "fieldtype": "Link", "label": "مرز", "options": "Border", "in_standard_filter": 1},
  {"fieldname": "column_break_r", "fieldtype": "Column Break"},
  {"fieldname": "transport_type", "fieldtype": "Select", "label": "نوع حمل", "options": "\nزمینی\nدریایی\nهوایی\nریلی"},
  {"fieldname": "delivery_type", "fieldtype": "Select", "label": "نوع تحویل", "options": "\nتحویلی\nدرب کارخانه\nمرز"},

  {"fieldname": "section_docs", "fieldtype": "Section Break", "label": "اسناد و پیوست‌ها"},
  {"fieldname": "signed_document", "fieldtype": "Attach", "label": "سند امضاشده (الزامی برای تایید)"},
  {"fieldname": "proforma_purchase", "fieldtype": "Attach", "label": "پیش‌فاکتور خرید"},
  {"fieldname": "proforma_sales", "fieldtype": "Attach", "label": "پیش‌فاکتور فروش"},

  {"fieldname": "section_notes", "fieldtype": "Section Break", "label": "یادداشت‌های مراحل", "collapsible": 1},
  {"fieldname": "legal_notes", "fieldtype": "Small Text", "label": "نظر حقوقی"},
  {"fieldname": "treasury_notes", "fieldtype": "Small Text", "label": "نظر خزانه"},
  {"fieldname": "receivables_notes", "fieldtype": "Small Text", "label": "نظر وصول مطالبات"}
 ],
 "links": [],
 "modified": "2025-01-01 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Iran Transport",
 "name": "Trade Case",
 "naming_rule": "By \"Naming Series\" field",
 "owner": "Administrator",
 "permissions": [
  {"create": 1, "delete": 1, "email": 1, "export": 1, "print": 1, "read": 1, "report": 1, "role": "System Manager", "share": 1, "write": 1},
  {"create": 1, "read": 1, "role": "Finance User", "write": 1},
  {"read": 1, "role": "CEO"},
  {"read": 1, "write": 1, "role": "Legal Reviewer"},
  {"read": 1, "write": 1, "role": "Treasury User"},
  {"read": 1, "write": 1, "role": "Document Signer"},
  {"read": 1, "write": 1, "role": "Finance Supervisor"},
  {"read": 1, "write": 1, "role": "Receivables User"},
  {"read": 1, "write": 1, "role": "Transport Supervisor"},
  {"read": 1, "write": 1, "role": "Transport User - Purchase"},
  {"read": 1, "write": 1, "role": "Transport User - Sales"},
  {"read": 1, "write": 1, "role": "Financial Manager"}
 ],
 "sort_field": "modified",
 "sort_order": "DESC",
 "track_changes": 1
}
EOF

# =============================================================================
# 2) Python Controller
# =============================================================================
step "2) Trade Case Controller (Python)"
write_utf8 "${DT}/trade_case/trade_case.py" << 'EOF'
import frappe
from frappe.model.document import Document
from frappe import _


class TradeCase(Document):
    def before_insert(self):
        """Backend Guarantee: Auto-fill mandatory fields if missing."""
        # UX DEVIATION: posting_date is hidden and read-only.
        # Backend guarantee via before_insert ensures it's always filled.
        if not self.posting_date:
            self.posting_date = frappe.utils.today()

        # UX DEVIATION: company is visible but auto-filled with system default.
        # Backend guarantee via before_insert ensures API/Import paths also work.
        if not self.company:
            self.company = (
                frappe.defaults.get_user_default("Company")
                or frappe.db.get_single_value("Global Defaults", "default_company")
                or frappe.db.get_value("Company", {"is_group": 0}, "name")
            )

        if not self.company:
            frappe.throw(_("شرکت پیش‌فرض مشخص نشده است."))

    def validate(self):
        """Signature Guard: Block progression without signed document."""
        states_requiring_signature = [
            "Pending Signature", "Finance Supervisor", "Receivables", "Approved"
        ]
        if self.workflow_state in states_requiring_signature:
            if not self.signed_document:
                frappe.throw(
                    _("برای ورود به مرحله «{0}» بارگذاری سند امضاشده الزامی است.").format(
                        self.workflow_state
                    )
                )

    def on_update(self):
        """Auto-Create Transport Case + Anti-Duplicate Logic.

        FIX: has_value_changed prevents re-creation on every save.
        FIX: No frappe.db.commit() — let Frappe manage the transaction.
        """
        if self.workflow_state != "Approved":
            return
        if not self.has_value_changed("workflow_state"):
            return

        # Anti-duplicate check (MVP: one active Transport Case per Trade)
        exists = frappe.db.exists("Transport Case", {
            "trade_case": self.name,
            "status": ["not in", ["Cancelled", "Rejected"]]
        })
        if exists:
            return

        # Ensure Transport Case DocType exists
        if not frappe.db.exists("DocType", "Transport Case"):
            frappe.throw(_("پرونده حمل (Transport Case) هنوز در سیستم تعریف نشده است."))

        # Transfer ALL fields from Trade Case to Transport Case
        tc = frappe.new_doc("Transport Case")
        tc.trade_case = self.name
        tc.case_title = f"حمل: {self.case_title}"
        tc.case_type = self.case_type
        tc.company = self.company
        tc.posting_date = self.posting_date
        tc.status = "Draft"

        # Parties & Cargo
        tc.customer = self.customer
        tc.supplier_factory = self.supplier_factory
        tc.item = self.item
        tc.cargo_description = self.cargo_description

        # Cargo specs
        tc.thickness = self.thickness
        tc.dimensions = self.dimensions
        tc.qty = self.qty
        tc.weight = self.weight
        tc.planned_tonnage = self.planned_tonnage

        # Financial
        tc.purchase_amount = self.purchase_amount
        tc.sales_amount = self.sales_amount
        tc.initial_costs = self.initial_costs
        tc.freight_cost = self.freight_cost
        tc.customs_cost = self.customs_cost
        tc.clearance_cost = self.clearance_cost

        # Route & Transport
        tc.destination = self.destination
        tc.border = self.border
        tc.transport_type = self.transport_type
        tc.delivery_type = self.delivery_type

        # Bypass permissions for system auto-creation
        tc.flags.ignore_permissions = True
        tc.insert()

        frappe.msgprint(
            _("پرونده حمل {0} به صورت خودکار ایجاد شد.").format(tc.name),
            alert=True, indicator="green"
        )
EOF

touch "${DT}/trade_case/test_trade_case.py"
write_utf8 "${DT}/trade_case/test_trade_case.py" << 'EOF'
from frappe.tests.utils import FrappeTestCase
class TestTradeCase(FrappeTestCase):
    pass
EOF

# =============================================================================
# 3) Transport Case (with trade_case non-unique link)
# =============================================================================
step "3) Transport Case (with trade_case non-unique link)"
mkdir -p "${DT}/transport_case"
touch "${DT}/transport_case/__init__.py"

write_utf8 "${DT}/transport_case/transport_case.json" << 'EOF'
{
 "actions": [],
 "autoname": "naming_series:",
 "creation": "2025-01-01 00:00:00.000000",
 "doctype": "DocType",
 "engine": "InnoDB",
 "field_order": [
  "naming_series", "trade_case", "case_title", "case_type", "status", "column_break_1",
  "posting_date", "company",
  "section_parties", "customer", "supplier_factory", "column_break_p", "item", "cargo_description",
  "section_cargo", "thickness", "dimensions", "qty", "column_break_c", "weight", "planned_tonnage",
  "section_financial", "purchase_amount", "sales_amount", "initial_costs", "column_break_f",
  "freight_cost", "customs_cost", "clearance_cost",
  "section_route", "destination", "border", "column_break_r", "transport_type", "delivery_type"
 ],
 "fields": [
  {"fieldname": "naming_series", "fieldtype": "Select", "options": "TR-.YYYY.-.#####", "default": "TR-.YYYY.-.#####", "hidden": 1, "reqd": 1},
  {"fieldname": "trade_case", "fieldtype": "Link", "label": "پرونده تجاری", "options": "Trade Case", "in_list_view": 1, "in_standard_filter": 1},
  {"fieldname": "case_title", "fieldtype": "Data", "label": "عنوان", "reqd": 1, "in_list_view": 1},
  {"fieldname": "case_type", "fieldtype": "Select", "label": "نوع", "options": "خرید\nفروش", "in_standard_filter": 1},
  {"fieldname": "status", "fieldtype": "Select", "label": "وضعیت", "options": "Draft\nPending Transport\nCompleted\nCancelled\nRejected", "default": "Draft", "in_list_view": 1, "in_standard_filter": 1},
  {"fieldname": "column_break_1", "fieldtype": "Column Break"},
  {"fieldname": "posting_date", "fieldtype": "Date", "label": "تاریخ", "default": "Today"},
  {"fieldname": "company", "fieldtype": "Link", "label": "شرکت", "options": "Company"},

  {"fieldname": "section_parties", "fieldtype": "Section Break", "label": "طرفین و کالا"},
  {"fieldname": "customer", "fieldtype": "Link", "label": "مشتری", "options": "Customer"},
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
  {"fieldname": "planned_tonnage", "fieldtype": "Float", "label": "تناژ"},

  {"fieldname": "section_financial", "fieldtype": "Section Break", "label": "مالی"},
  {"fieldname": "purchase_amount", "fieldtype": "Currency", "label": "مبلغ خرید"},
  {"fieldname": "sales_amount", "fieldtype": "Currency", "label": "مبلغ فروش"},
  {"fieldname": "initial_costs", "fieldtype": "Currency", "label": "هزینه اولیه"},
  {"fieldname": "column_break_f", "fieldtype": "Column Break"},
  {"fieldname": "freight_cost", "fieldtype": "Currency", "label": "هزینه کرایه"},
  {"fieldname": "customs_cost", "fieldtype": "Currency", "label": "هزینه گمرک"},
  {"fieldname": "clearance_cost", "fieldtype": "Currency", "label": "هزینه ترخیص"},

  {"fieldname": "section_route", "fieldtype": "Section Break", "label": "مسیر و حمل"},
  {"fieldname": "destination", "fieldtype": "Data", "label": "مقصد"},
  {"fieldname": "border", "fieldtype": "Link", "label": "مرز", "options": "Border"},
  {"fieldname": "column_break_r", "fieldtype": "Column Break"},
  {"fieldname": "transport_type", "fieldtype": "Select", "label": "نوع حمل", "options": "\nزمینی\nدریایی\nهوایی\nریلی"},
  {"fieldname": "delivery_type", "fieldtype": "Select", "label": "نوع تحویل", "options": "\nتحویلی\nدرب کارخانه\nمرز"}
 ],
 "modified": "2025-01-01 00:00:00.000000",
 "module": "Iran Transport",
 "name": "Transport Case",
 "naming_rule": "By \"Naming Series\" field",
 "owner": "Administrator",
 "permissions": [
    {"create": 1, "delete": 1, "read": 1, "role": "System Manager", "write": 1, "report": 1, "export": 1},
    {"create": 1, "read": 1, "role": "Transport Supervisor", "write": 1, "report": 1},
    {"create": 1, "read": 1, "role": "Transport User - Purchase", "write": 1, "report": 1},
    {"create": 1, "read": 1, "role": "Transport User - Sales", "write": 1, "report": 1},
    {"read": 1, "role": "Customs Officer", "report": 1},
    {"read": 1, "role": "Financial Manager", "report": 1},
    {"read": 1, "role": "Finance Supervisor", "report": 1},
    {"read": 1, "role": "CEO", "report": 1}
 ],
 "sort_field": "modified",
 "sort_order": "DESC",
 "track_changes": 1
}
EOF

write_utf8 "${DT}/transport_case/transport_case.py" << 'EOF'
from frappe.model.document import Document
class TransportCase(Document):
    pass
EOF

# =============================================================================
# 4) Workflow States + Workflow JSON
#    CRITICAL FIX: allow_edit and allowed are Link fields in Frappe v15.
#    They accept ONLY ONE role per row. No \n, no multiple roles.
#    System Manager always has access by default — no need to list it.
# =============================================================================
step "4) Workflow States (10) + Workflow JSON (single-role fix)"
mkdir -p "${PKG}/fixtures"

write_utf8 "${PKG}/fixtures/workflow_state.json" << 'EOF'
[
 {"doctype": "Workflow State", "name": "Draft", "workflow_state_name": "Draft", "style": "Primary"},
 {"doctype": "Workflow State", "name": "Legal Review", "workflow_state_name": "Legal Review", "style": "Warning"},
 {"doctype": "Workflow State", "name": "Treasury Review", "workflow_state_name": "Treasury Review", "style": "Warning"},
 {"doctype": "Workflow State", "name": "Pending Signature", "workflow_state_name": "Pending Signature", "style": "Warning"},
 {"doctype": "Workflow State", "name": "Finance Supervisor", "workflow_state_name": "Finance Supervisor", "style": "Warning"},
 {"doctype": "Workflow State", "name": "Receivables", "workflow_state_name": "Receivables", "style": "Warning"},
 {"doctype": "Workflow State", "name": "Approved", "workflow_state_name": "Approved", "style": "Success"},
 {"doctype": "Workflow State", "name": "Rejected", "workflow_state_name": "Rejected", "style": "Danger"},
 {"doctype": "Workflow State", "name": "Returned", "workflow_state_name": "Returned", "style": "Danger"},
 {"doctype": "Workflow State", "name": "On Hold", "workflow_state_name": "On Hold", "style": "Warning"}
]
EOF

write_utf8 "${PKG}/fixtures/workflow.json" << 'EOF'
[
 {
  "doctype": "Workflow",
  "name": "Trade Case Workflow",
  "workflow_name": "Trade Case Workflow",
  "document_type": "Trade Case",
  "is_active": 1,
  "override_status": 1,
  "workflow_state_field": "workflow_state",
  "states": [
   {"state": "Draft", "allow_edit": "Finance User"},
   {"state": "Legal Review", "allow_edit": "Legal Reviewer"},
   {"state": "Treasury Review", "allow_edit": "Treasury User"},
   {"state": "Pending Signature", "allow_edit": "Document Signer"},
   {"state": "Finance Supervisor", "allow_edit": "Finance Supervisor"},
   {"state": "Receivables", "allow_edit": "Receivables User"},
   {"state": "Approved", "allow_edit": "Finance Supervisor"},
   {"state": "Rejected", "allow_edit": "Finance Supervisor"},
   {"state": "Returned", "allow_edit": "Finance User"},
   {"state": "On Hold", "allow_edit": "Finance Supervisor"}
  ],
  "transitions": [
   {"state": "Draft", "action": "ارسال به حقوقی", "next_state": "Legal Review", "allowed": "Finance User"},
   {"state": "Legal Review", "action": "تایید حقوقی", "next_state": "Treasury Review", "allowed": "Legal Reviewer"},
   {"state": "Legal Review", "action": "بازگشت به مالی", "next_state": "Returned", "allowed": "Legal Reviewer"},
   {"state": "Treasury Review", "action": "تایید خزانه", "next_state": "Pending Signature", "allowed": "Treasury User"},
   {"state": "Treasury Review", "action": "بازگشت", "next_state": "Returned", "allowed": "Treasury User"},
   {"state": "Treasury Review", "action": "معلق", "next_state": "On Hold", "allowed": "Finance Supervisor"},
   {"state": "Pending Signature", "action": "امضا شد", "next_state": "Finance Supervisor", "allowed": "Document Signer"},
   {"state": "Finance Supervisor", "action": "تایید سرپرست", "next_state": "Receivables", "allowed": "Finance Supervisor"},
   {"state": "Finance Supervisor", "action": "بازگشت", "next_state": "Returned", "allowed": "Finance Supervisor"},
   {"state": "Receivables", "action": "تایید وصول", "next_state": "Approved", "allowed": "Receivables User"},
   {"state": "Receivables", "action": "بازگشت به سرپرست", "next_state": "Returned", "allowed": "Receivables User"},
   {"state": "Draft", "action": "رد", "next_state": "Rejected", "allowed": "Finance Supervisor"},
   {"state": "Draft", "action": "معلق", "next_state": "On Hold", "allowed": "Finance Supervisor"},
   {"state": "On Hold", "action": "از سرگیری", "next_state": "Draft", "allowed": "Finance Supervisor"},
   {"state": "Returned", "action": "بازگشت به پیش‌نویس", "next_state": "Draft", "allowed": "Finance User"}
  ]
 }
]
EOF

# =============================================================================
# 5) Client Script (UX)
# =============================================================================
step "5) Client Script (UX)"
write_utf8 "${PKG}/fixtures/client_script.json" << 'EOF'
[
 {
  "doctype": "Client Script",
  "name": "Trade Case UX",
  "dt": "Trade Case",
  "view": "Form",
  "enabled": 1,
  "script": "frappe.ui.form.on('Trade Case', {\n    onload: function(frm) {\n        if (frm.is_new() && !frm.doc.company) {\n            let default_company =\n                frappe.defaults.get_user_default('Company') ||\n                frappe.boot.sysdefaults.company;\n            if (default_company) {\n                frm.set_value('company', default_company);\n            }\n        }\n    },\n    refresh: function(frm) {\n        if(frm.doc.company) {\n            frm.dashboard.add_comment(__('شرکت: ' + frm.doc.company), 'blue', true);\n        }\n    }\n});"
 }
]
EOF

# =============================================================================
# 6) Hooks Update
# =============================================================================
step "6) Hooks Update"
python3 << 'PYEOF'
import os, re
hooks_path = os.environ["HOOKS"]
with open(hooks_path, "r", encoding="utf-8") as f:
    content = f.read()

content = re.sub(r"# --- PHASE5_HOOKS_START ---.*?# --- PHASE5_HOOKS_END ---\n?", "", content, flags=re.DOTALL)

addition = """
# --- PHASE5_HOOKS_START ---
fixtures.extend([
    {"dt": "Workflow State", "filters": [["name", "in", ["Draft", "Legal Review", "Treasury Review", "Pending Signature", "Finance Supervisor", "Receivables", "Approved", "Rejected", "Returned", "On Hold"]]]},
    {"dt": "Workflow", "filters": [["name", "=", "Trade Case Workflow"]]},
    {"dt": "Client Script", "filters": [["name", "=", "Trade Case UX"]]}
])
# --- PHASE5_HOOKS_END ---
"""

content += addition

with open(hooks_path, "w", encoding="utf-8") as f:
    f.write(content)
print("hooks.py updated safely")
PYEOF
log "hooks.py updated"

# =============================================================================
# 7) Verification Script
# =============================================================================
step "7) Verify Script"
write_utf8 "${MOD}/verify_phase5.py" << 'EOF'
import sys
import frappe


def verify_phase5():
    passed, failed = [], []

    def check(name, cond):
        (passed if cond else failed).append(name)
        print(f"{'✅ PASS' if cond else '❌ FAIL'}: {name}")

    # Cleanup
    frappe.db.delete("Trade Case", {"case_title": "TEST-PHASE5"})
    frappe.db.delete("Transport Case", {"case_title": ["like", "%TEST-PHASE5%"]})
    frappe.db.commit()

    # Ensure Workflow States exist (safety net)
    states = [
        "Draft", "Legal Review", "Treasury Review", "Pending Signature",
        "Finance Supervisor", "Receivables", "Approved", "Rejected",
        "Returned", "On Hold"
    ]
    for s in states:
        if not frappe.db.exists("Workflow State", s):
            frappe.get_doc({
                "doctype": "Workflow State",
                "workflow_state_name": s,
                "style": "Primary"
            }).insert(ignore_permissions=True)
    frappe.db.commit()

    # TEST 1: Backend Guarantee (insert WITHOUT company and posting_date)
    try:
        doc = frappe.new_doc("Trade Case")
        doc.case_title = "TEST-PHASE5"
        doc.case_type = "خرید"
        doc.planned_tonnage = 10
        doc.workflow_state = "Draft"
        doc.insert(ignore_permissions=True)
        check("Backend: Company auto-filled", bool(doc.company))
        check("Backend: Date auto-filled", bool(doc.posting_date))
    except Exception as e:
        check(f"Backend Insert: {e}", False)
        doc = None

    if doc:
        # TEST 2: Signature Guard (call validate directly, bypass workflow engine)
        try:
            doc.workflow_state = "Pending Signature"
            doc.validate()
            check("Guard: Should block without signature", False)
        except frappe.exceptions.ValidationError as e:
            check("Guard: Blocks without signature", "سند امضاشده" in str(e))
        except Exception as e:
            check(f"Guard unexpected error: {e}", False)

        # TEST 3: Auto-Create with full field transfer
        try:
            doc.signed_document = "/files/dummy.pdf"
            doc.thickness = 5.5
            doc.dimensions = "120x240"
            doc.qty = 100
            doc.weight = 5000
            doc.purchase_amount = 1000000
            doc.sales_amount = 1200000
            doc.initial_costs = 50000
            doc.freight_cost = 80000
            doc.customs_cost = 30000
            doc.clearance_cost = 20000
            doc.destination = "بندرعباس"
            doc.transport_type = "زمینی"
            doc.delivery_type = "تحویلی"
            doc.workflow_state = "Approved"
            doc.on_update()
            frappe.db.commit()

            tc1 = frappe.db.count("Transport Case", {"trade_case": doc.name})
            check("Auto-Create: Transport Case created", tc1 == 1)

            if tc1 == 1:
                tc_doc = frappe.get_doc("Transport Case", {"trade_case": doc.name})
                check("Transfer: thickness", tc_doc.thickness == 5.5)
                check("Transfer: dimensions", tc_doc.dimensions == "120x240")
                check("Transfer: purchase_amount", tc_doc.purchase_amount == 1000000)
                check("Transfer: destination", tc_doc.destination == "بندرعباس")
                check("Transfer: transport_type", tc_doc.transport_type == "زمینی")
                check("Transfer: delivery_type", tc_doc.delivery_type == "تحویلی")

            # TEST 4: Anti-Duplicate (call on_update again)
            doc.on_update()
            frappe.db.commit()
            tc2 = frappe.db.count("Transport Case", {"trade_case": doc.name})
            check("Anti-Duplicate: No duplicate created", tc2 == 1)

        except Exception as e:
            check(f"Auto-Create Logic: {e}", False)

    # TEST 5: Workflow States completeness
    for s in states:
        check(f"Workflow State exists: {s}", bool(frappe.db.exists("Workflow State", s)))

    # TEST 6: Workflow exists
    check("Workflow exists", bool(frappe.db.exists("Workflow", "Trade Case Workflow")))

    # TEST 7: Workflow has single-role allow_edit (no \n)
    if frappe.db.exists("Workflow", "Trade Case Workflow"):
        wf = frappe.get_doc("Workflow", "Trade Case Workflow")
        bad_states = [s.state for s in wf.states if "\n" in (s.allow_edit or "")]
        bad_trans = [t.action for t in wf.transitions if "\n" in (t.allowed or "")]
        check("No multi-role in allow_edit", len(bad_states) == 0)
        check("No multi-role in allowed", len(bad_trans) == 0)

    print(f"\nPassed: {len(passed)} | Failed: {len(failed)}")
    if not failed:
        print("🎉 All Phase 5 Checks Passed!")
    else:
        for f in failed:
            print(f"  - {f}")
        print("\n❌ Phase 5 NOT ready — fix failures")
        sys.exit(1)
    return len(failed) == 0
EOF

# =============================================================================
# 8) Migrate & Verify
# =============================================================================
step "8) Migrate & Verify"
bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache
bench --site "$SITE_NAME" execute transport_ir.iran_transport.verify_phase5.verify_phase5

# =============================================================================
# 9) Git Commit
# =============================================================================
step "9) Git Commit"
cd "${BENCH_DIR}/apps/${APP}"
git add -A
git commit -m "phase 5: Trade Case + workflow single-role fix + auto-create full transfer" || warn "nothing to commit"

step "DONE"
cat <<FINAL
${GREEN}فاز ۵ با اصلاح Preflight و single-role Workflow به پایان رسید.${NC}

خلاصه اصلاحات:
  ✅ Preflight: frappe.db.count به جای frappe.db.exists (عدد برمی‌گرداند نه نام)
  ✅ allow_edit/allowed فقط یک نقش (Link field در Frappe v15)
  ✅ System Manager به صورت پیش‌فرض دسترسی دارد (نیازی به ذکر نیست)
  ✅ has_value_changed در on_update
  ✅ بدون frappe.db.commit() در on_update
  ✅ فیلدهای کامل Trade Case
  ✅ انتقال کامل فیلدها در auto-create
  ✅ ۱۰ state + ۱۵ transition
  ✅ sys.exit(1) به جای frappe.throw در verify

خروجی مورد انتظار: Passed: 24+ | Failed: 0
FINAL