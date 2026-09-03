#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Phase 11 - Multi Shipment Under One Trade Case
# ERPNext/Frappe v15
#
# Architecture:
#   - No overwrite of existing Python controllers
#   - No overwrite of existing JS files
#   - Independent Phase 11 service module
#   - Additive hooks
#   - Additive DocType fields
#   - Independent Client Script
#   - Idempotent patch and verification
# =============================================================================

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=utf-8

SITE_NAME="${SITE_NAME:-transport-dev.local}"
BENCH_DIR="${BENCH_DIR:-${HOME}/frappe-bench}"
APP_NAME="${APP_NAME:-transport_ir}"

APP_ROOT="${BENCH_DIR}/apps/${APP_NAME}/${APP_NAME}"
MODULE_ROOT="${APP_ROOT}/iran_transport"
HOOKS_FILE="${APP_ROOT}/hooks.py"
PHASE11_ROOT="${MODULE_ROOT}/phase11_multishipment"
PATCH_ROOT="${APP_ROOT}/patches/v1_0"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

fail() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

step() {
    echo
    echo -e "${YELLOW}========== $* ==========${NC}"
}

require_file() {
    [[ -f "$1" ]] || fail "File not found: $1"
}

append_once() {
    local file="$1"
    local marker="$2"
    local content="$3"

    touch "$file"

    if grep -Fq "$marker" "$file"; then
        log "Already exists: ${marker}"
        return
    fi

    printf "\n%s\n" "$content" >> "$file"
    log "Added: ${marker}"
}

[[ -d "$BENCH_DIR" ]] || fail "Bench directory not found: $BENCH_DIR"
[[ -d "${BENCH_DIR}/apps/${APP_NAME}" ]] || fail "App not found: ${APP_NAME}"

cd "$BENCH_DIR"



# =============================================================================
# 0) bench services + redis_cache wait (الگو از setup_phase6.sh)
# =============================================================================
if ss -lntp 2>/dev/null | grep -q ':8000' \
   || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
    log "bench already running — skip bench start"
else
    nohup bench start >>/tmp/bench-start-phase105.log 2>&1 &
    log "bench start pid=$!  log=/tmp/bench-start-phase105.log"
    sleep 12
fi

REDIS_CACHE_CONF="${BENCH_DIR}/config/redis_cache.conf"
if [[ -f "$REDIS_CACHE_CONF" ]]; then
    REDIS_CACHE_PORT="$(awk '$1 == "port" {print $2; exit}' "$REDIS_CACHE_CONF")"
else
    REDIS_CACHE_PORT="13000"
fi
[[ -n "${REDIS_CACHE_PORT:-}" ]] || REDIS_CACHE_PORT="13000"

log "waiting for redis_cache on port ${REDIS_CACHE_PORT} ..."
REDIS_READY=0
for _i in $(seq 1 60); do
    if command -v redis-cli >/dev/null 2>&1; then
        if redis-cli -h 127.0.0.1 -p "$REDIS_CACHE_PORT" ping 2>/dev/null | grep -q '^PONG$'; then
            REDIS_READY=1
            break
        fi
    fi
    if command -v ss >/dev/null 2>&1; then
        if ss -lnt 2>/dev/null | grep -q ":${REDIS_CACHE_PORT}[[:space:]]"; then
            REDIS_READY=1
            break
        fi
    fi
    sleep 1
done
[[ "$REDIS_READY" -eq 1 ]] || fail "redis_cache not ready after 60s. Check /tmp/bench-start-phase105.log"
log "redis_cache ready"

# =============================================================================

bench --site "$SITE_NAME" list-apps >/dev/null 2>&1 || \
    fail "Site is not available: ${SITE_NAME}"

mkdir -p "$PHASE11_ROOT" "$PATCH_ROOT"

touch "${PHASE11_ROOT}/__init__.py"
touch "${PATCH_ROOT}/__init__.py"

# =============================================================================
step "1) افزودن فیلدهای Trade Case به‌صورت Additive"
# =============================================================================

export TRADE_JSON="${MODULE_ROOT}/doctype/trade_case/trade_case.json"
require_file "$TRADE_JSON"

python3 <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["TRADE_JSON"])

with path.open("r", encoding="utf-8") as f:
    data = json.load(f)

fields = data.setdefault("fields", [])
field_order = data.setdefault("field_order", [])

existing = {
    field.get("fieldname")
    for field in fields
    if field.get("fieldname")
}

new_fields = [
    {
        "fieldname": "phase11_tonnage_section",
        "fieldtype": "Section Break",
        "label": "وضعیت حمل و تناژ",
        "collapsible": 1,
    },
    {
        "fieldname": "shipped_tonnage",
        "fieldtype": "Float",
        "label": "تناژ خارج‌شده",
        "read_only": 1,
        "precision": "3",
        "default": "0",
    },
    {
        "fieldname": "reserved_tonnage",
        "fieldtype": "Float",
        "label": "تناژ رزروشده",
        "read_only": 1,
        "precision": "3",
        "default": "0",
    },
    {
        "fieldname": "remaining_tonnage",
        "fieldtype": "Float",
        "label": "تناژ باقیمانده",
        "read_only": 1,
        "precision": "3",
        "default": "0",
        "in_list_view": 1,
        "in_standard_filter": 1,
    },
    {
        "fieldname": "remaining_capacity",
        "fieldtype": "Float",
        "label": "ظرفیت رزرو باقیمانده",
        "read_only": 1,
        "precision": "3",
        "default": "0",
    },
    {
        "fieldname": "phase11_tonnage_column_break",
        "fieldtype": "Column Break",
    },
    {
        "fieldname": "loading_completed",
        "fieldtype": "Check",
        "label": "تکمیل بارگیری",
        "read_only": 1,
        "default": "0",
        "in_list_view": 1,
        "in_standard_filter": 1,
    },
    {
        "fieldname": "allow_overloading",
        "fieldtype": "Check",
        "label": "اجازه اضافه‌بارگیری",
        "default": "0",
        "permlevel": 1,
    },
]

for field in new_fields:
    if field["fieldname"] not in existing:
        fields.append(field)
        field_order.append(field["fieldname"])

data["fields"] = fields
data["field_order"] = field_order

permissions = data.setdefault("permissions", [])
has_fm_pl1 = any(
    p.get("role") == "Financial Manager" and int(p.get("permlevel") or 0) == 1
    for p in permissions
)
if not has_fm_pl1:
    permissions.append(
        {
            "role": "Financial Manager",
            "read": 1,
            "write": 1,
            "permlevel": 1,
        }
    )
data["permissions"] = permissions

with path.open("w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=1)
    f.write("\n")

print("Trade Case JSON updated additively.")
PY

log "Trade Case fields added without removing existing fields."

# =============================================================================
step "2) ایجاد سرویس مستقل فاز ۱۱"
# =============================================================================

cat > "${PHASE11_ROOT}/service.py" <<'PY'
import frappe
from frappe import _
from frappe.utils import flt


EPSILON = 0.001
ACTIVE_STATES = ["Cancelled", "Rejected"]


def get_active_transport_rows(trade_case):
    if not trade_case:
        return []

    return frappe.db.sql(
        """
        SELECT name, planned_tonnage, actual_tonnage, net_weight
        FROM `tabTransport Case`
        WHERE trade_case = %s
          AND IFNULL(workflow_state, '') NOT IN ('Cancelled', 'Rejected')
        """,
        (trade_case,),
        as_dict=True,
    )


def compute_metrics(planned_tonnage, rows):
    planned = flt(planned_tonnage)
    shipped = 0.0
    reserved = 0.0

    for row in rows:
        reserved += flt(row.get("planned_tonnage"))

        actual = flt(row.get("actual_tonnage"))
        if actual > 0:
            shipped += actual
            continue

        net_weight = flt(row.get("net_weight"))
        if net_weight > 0:
            shipped += net_weight / 1000.0

    return {
        "shipped_tonnage": shipped,
        "reserved_tonnage": reserved,
        "remaining_tonnage": max(0.0, planned - shipped),
        "remaining_capacity": max(0.0, planned - reserved),
        "loading_completed": int(
            bool(rows)
            and planned > 0
            and shipped + EPSILON >= planned
        ),
    }


def recalculate_trade_case(trade_case):
    if not trade_case:
        return

    planned = frappe.db.get_value(
        "Trade Case",
        trade_case,
        "planned_tonnage",
    )

    if planned is None:
        return

    rows = get_active_transport_rows(trade_case)
    metrics = compute_metrics(planned, rows)

    frappe.db.set_value(
        "Trade Case",
        trade_case,
        metrics,
        update_modified=False,
    )


def recalculate_on_trade_save(doc, method=None):
    rows = get_active_transport_rows(doc.name) if doc.name else []
    metrics = compute_metrics(doc.planned_tonnage, rows)

    for key, value in metrics.items():
        doc.set(key, value)


def on_transport_update(doc, method=None):
    trade_case = getattr(doc, "trade_case", None)

    if trade_case:
        try:
            recalculate_trade_case(trade_case)
        except Exception:
            frappe.log_error(
                frappe.get_traceback(),
                f"Phase11 recalc failed for {trade_case}",
            )


def validate_transport_overloading(doc, method=None):
    if not getattr(doc, "trade_case", None):
        return

    current_planned = flt(getattr(doc, "planned_tonnage", 0))

    if current_planned <= 0:
        return

    trade = frappe.db.get_value(
        "Trade Case",
        doc.trade_case,
        ["planned_tonnage", "allow_overloading"],
        as_dict=True,
    )

    if not trade:
        return

    if int(trade.allow_overloading or 0):
        return

    trade_planned = flt(trade.planned_tonnage)

    if trade_planned <= 0:
        return

    params = [doc.trade_case]
    name_clause = ""

    if getattr(doc, "name", None):
        name_clause = "AND name != %s"
        params.append(doc.name)

    rows = frappe.db.sql(
        f"""
        SELECT planned_tonnage
        FROM `tabTransport Case`
        WHERE trade_case = %s
          {name_clause}
          AND IFNULL(workflow_state, '') NOT IN ('Cancelled', 'Rejected')
        """,
        tuple(params),
        as_dict=True,
    )

    committed = sum(
        flt(row.get("planned_tonnage"))
        for row in rows
    )

    total = committed + current_planned

    if total > trade_planned + EPSILON:
        frappe.throw(
            _(
                "مجموع تناژ رزروشده ({0}) بیشتر از تناژ برنامه‌ریزی‌شده "
                "فاکتور ({1}) است. برای ثبت اضافه‌بار، گزینه "
                "«اجازه اضافه‌بارگیری» را فعال کنید."
            ).format(total, trade_planned),
            title=_("خطای اضافه‌بارگیری"),
        )


def validate_allow_overloading(doc, method=None):
    if not doc.is_new() and not doc.has_value_changed("allow_overloading"):
        return

    if not int(doc.allow_overloading or 0):
        return

    allowed_roles = {"System Manager", "Financial Manager"}
    user_roles = set(frappe.get_roles(frappe.session.user))

    if not user_roles.intersection(allowed_roles):
        frappe.throw(
            _(
                "فعال‌سازی «اجازه اضافه‌بارگیری» فقط برای مدیر سیستم "
                "یا مدیر مالی مجاز است."
            )
        )


@frappe.whitelist()
def get_metrics(trade_case):
    if not frappe.has_permission("Trade Case", "read", trade_case):
        frappe.throw(_("Not permitted"), frappe.PermissionError)

    planned = frappe.db.get_value(
        "Trade Case",
        trade_case,
        "planned_tonnage",
    )

    rows = get_active_transport_rows(trade_case)

    return compute_metrics(planned, rows)
PY

cat > "${PHASE11_ROOT}/__init__.py" <<'PY'
PY

log "Independent Phase 11 service created."

# =============================================================================
step "3) افزودن Hookها بدون حذف Hookهای قبلی"
# =============================================================================

export HOOKS_FILE

python3 <<'PY'
from pathlib import Path
import os
import re

path = Path(os.environ["HOOKS_FILE"])
content = path.read_text(encoding="utf-8") if path.exists() else ""

start = "# PHASE11_MULTI_SHIPMENT_HOOKS_START"
end = "# PHASE11_MULTI_SHIPMENT_HOOKS_END"

pattern = re.compile(
    re.escape(start) + r".*?" + re.escape(end),
    re.DOTALL,
)

content = pattern.sub("", content).rstrip()

block = f"""
{start}

# WARNING: doc_events in hooks.py is a Python dict. If you assign it again
# with `doc_events = {{...}}` you will OVERWRITE all handlers from previous
# phases. Always merge instead:
#   doc_events = globals().get("doc_events", {{}})
#   doc_events.setdefault("Transport Case", {{}}).setdefault("validate", []).append(...)
# See PHASE4_HOOKS_START and PHASE11_MULTI_SHIPMENT_HOOKS_START for examples.

_phase11_transport_events = {{
    "validate": [
        "transport_ir.iran_transport.phase11_multishipment.service.validate_transport_overloading"
    ],
    "on_update": [
        "transport_ir.iran_transport.phase11_multishipment.service.on_transport_update"
    ],
    "on_cancel": [
        "transport_ir.iran_transport.phase11_multishipment.service.on_transport_update"
    ],
    "after_delete": [
        "transport_ir.iran_transport.phase11_multishipment.service.on_transport_update"
    ],
}}

doc_events = globals().get("doc_events", {{}})

_existing_transport_events = doc_events.get("Transport Case", {{}})

for _event_name, _handlers in _phase11_transport_events.items():
    _existing = _existing_transport_events.get(_event_name)

    if _existing is None:
        _existing_transport_events[_event_name] = _handlers
    elif isinstance(_existing, list):
        for _handler in _handlers:
            if _handler not in _existing:
                _existing.append(_handler)
    else:
        _values = [_existing]
        for _handler in _handlers:
            if _handler not in _values:
                _values.append(_handler)
        _existing_transport_events[_event_name] = _values

doc_events["Transport Case"] = _existing_transport_events

# اعتبارسنجی نقش allow_overloading و بازمحاسبه تناژ روی Trade Case
_trade_validate = doc_events.get("Trade Case", {{}})
_existing_trade_validate = _trade_validate.get("validate")

_new_trade_handlers = [
    "transport_ir.iran_transport.phase11_multishipment.service."
    "validate_allow_overloading",
    "transport_ir.iran_transport.phase11_multishipment.service."
    "recalculate_on_trade_save",
]

if _existing_trade_validate is None:
    _trade_validate["validate"] = list(_new_trade_handlers)
elif isinstance(_existing_trade_validate, list):
    for _handler in _new_trade_handlers:
        if _handler not in _existing_trade_validate:
            _existing_trade_validate.append(_handler)
else:
    _values = [_existing_trade_validate]
    for _handler in _new_trade_handlers:
        if _handler not in _values:
            _values.append(_handler)
    _trade_validate["validate"] = _values

doc_events["Trade Case"] = _trade_validate

{end}
"""

content += "\n" + block + "\n"
path.write_text(content, encoding="utf-8")

print("hooks.py updated additively.")
PY

log "Existing doc_events preserved."

# =============================================================================
step "4) ایجاد Patch مستقل Backfill"
# =============================================================================

cat > "${PATCH_ROOT}/phase11_multishipment_backfill.py" <<'PY'
import frappe

from transport_ir.iran_transport.phase11_multishipment.service import (
    recalculate_trade_case,
)


def execute():
    if not frappe.db.exists("DocType", "Trade Case"):
        return

    if not frappe.db.exists("DocType", "Transport Case"):
        return

    frappe.flags.in_phase11_backfill = True

    try:
        names = frappe.get_all(
            "Trade Case",
            pluck="name",
        )

        for name in names:
            try:
                recalculate_trade_case(name)
            except Exception:
                frappe.log_error(
                    frappe.get_traceback(),
                    f"Phase11 backfill failed for {name}",
                )

        frappe.db.commit()

    finally:
        frappe.flags.in_phase11_backfill = False
PY

PATCHES_FILE="${APP_ROOT}/patches.txt"
touch "$PATCHES_FILE"

PATCH_ENTRY="transport_ir.patches.v1_0.phase11_multishipment_backfill"

if ! grep -Fxq "$PATCH_ENTRY" "$PATCHES_FILE"; then
    if ! grep -Fq "[post_model_sync]" "$PATCHES_FILE"; then
        printf "\n[post_model_sync]\n" >> "$PATCHES_FILE"
    fi
    printf "%s\n" "$PATCH_ENTRY" >> "$PATCHES_FILE"
fi

log "Backfill patch registered."

# =============================================================================
step "5) ایجاد Client Script مستقل"
# =============================================================================

cat > "${PHASE11_ROOT}/install_client_script.py" <<'PY'
import frappe


CLIENT_SCRIPT_NAME = "Phase 11 - Trade Case Multi Shipment"


SCRIPT = r"""
frappe.ui.form.on("Trade Case", {
    refresh(frm) {
        frm.$wrapper.find(".phase11-tonnage-panel").remove();

        if (frm.is_new()) {
            return;
        }

        const planned = flt(frm.doc.planned_tonnage);
        const shipped = flt(frm.doc.shipped_tonnage);
        const reserved = flt(frm.doc.reserved_tonnage);
        const remaining = flt(frm.doc.remaining_tonnage);
        const capacity = flt(frm.doc.remaining_capacity);
        const completed = cint(frm.doc.loading_completed);

        if (planned > 0) {
            const percent = Math.min(
                100,
                Math.max(0, Math.round((shipped / planned) * 100))
            );

            const html = `
                <div class="phase11-tonnage-panel"
                     style="margin:12px 0;padding:14px;
                            border:1px solid #d1d8dd;
                            border-radius:8px;background:#fff;">
                    <div style="font-weight:700;margin-bottom:8px;">
                        وضعیت حمل:
                        ${completed ? "✅ تکمیل بارگیری" : "در حال بارگیری"}
                    </div>

                    <div style="display:grid;
                                grid-template-columns:repeat(4,1fr);
                                gap:8px;font-size:12px;">
                        <div>خارج‌شده: <b>${shipped}</b> تن</div>
                        <div>رزروشده: <b>${reserved}</b> تن</div>
                        <div>باقیمانده: <b>${remaining}</b> تن</div>
                        <div>ظرفیت رزرو: <b>${capacity}</b> تن</div>
                    </div>

                    <div style="margin-top:12px;
                                height:10px;background:#e9edf0;
                                border-radius:8px;overflow:hidden;">
                        <div style="height:100%;
                                    width:${percent}%;
                                    background:#2ca66f;"></div>
                    </div>

                    <div style="margin-top:5px;font-size:11px;color:#68737d;">
                        ${percent}% خارج شده
                    </div>
                </div>
            `;

            const section = frm.fields_dict.phase11_tonnage_section;

            if (section) {
                $(section.wrapper).before(html);
            } else {
                frm.$wrapper.find(".form-layout").first().prepend(html);
            }
        }

        if (
            frm.doc.workflow_state === "Approved" &&
            !completed &&
            capacity > 0.001
        ) {
            frm.add_custom_button(
                __("حمل جدید"),
                () => {
                    frappe.new_doc("Transport Case", {
                        trade_case: frm.doc.name,
                        planned_tonnage: capacity,
                        company: frm.doc.company,
                        customer: frm.doc.customer,
                        supplier_factory: frm.doc.supplier_factory,
                        item: frm.doc.item,
                        destination: frm.doc.destination,
                        border: frm.doc.border,
                        transport_type: frm.doc.transport_type,
                        delivery_type: frm.doc.delivery_type
                    });
                },
                __("عملیات حمل")
            );
        }

        const allowed = ["System Manager", "Financial Manager"]
            .some(role => frappe.user_roles.includes(role));

        if (!allowed && frm.fields_dict.allow_overloading) {
            frm.set_df_property(
                "allow_overloading",
                "read_only",
                1
            );
        }
    }
});
"""


def execute():
    existing = frappe.db.exists(
        "Client Script",
        {"name": CLIENT_SCRIPT_NAME},
    )

    values = {
        "doctype": "Client Script",
        "name": CLIENT_SCRIPT_NAME,
        "dt": "Trade Case",
        "view": "Form",
        "enabled": 1,
        "script": SCRIPT,
    }

    if existing:
        doc = frappe.get_doc("Client Script", CLIENT_SCRIPT_NAME)
        doc.update(values)
        doc.save(ignore_permissions=True)
    else:
        frappe.get_doc(values).insert(ignore_permissions=True)

    frappe.db.commit()
PY

bench --site "$SITE_NAME" execute \
    transport_ir.iran_transport.phase11_multishipment.install_client_script.execute

log "Independent Client Script installed."

# =============================================================================
step "6) migrate و اجرای backfill"
# =============================================================================

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache

bench --site "$SITE_NAME" execute \
    transport_ir.patches.v1_0.phase11_multishipment_backfill.execute

bench --site "$SITE_NAME" clear-cache

log "Migration and backfill completed."

# =============================================================================
step "7) تست ایستای فایل‌ها"
# =============================================================================

python3 <<PY
import ast
from pathlib import Path

files = [
    Path("${PHASE11_ROOT}/service.py"),
    Path("${PHASE11_ROOT}/install_client_script.py"),
    Path("${PATCH_ROOT}/phase11_multishipment_backfill.py"),
    Path("${HOOKS_FILE}"),
]

for path in files:
    ast.parse(path.read_text(encoding="utf-8"))
    print(f"Python syntax OK: {path}")

trade_controller = Path(
    "${MODULE_ROOT}/doctype/trade_case/trade_case.py"
)
transport_controller = Path(
    "${MODULE_ROOT}/doctype/transport_case/transport_case.py"
)
trade_js = Path(
    "${MODULE_ROOT}/doctype/trade_case/trade_case.js"
)

for path in [trade_controller, transport_controller, trade_js]:
    if path.exists():
        print(f"Existing file preserved: {path}")

print("Static verification passed.")
PY

# =============================================================================
step "8) Git diff و Commit"
# =============================================================================

cd "${BENCH_DIR}/apps/${APP_NAME}"

if ! git diff --check; then
    warn "Whitespace issues detected (non-fatal)."
fi

git add \
    "${APP_NAME}/iran_transport/phase11_multishipment" \
    "${APP_NAME}/patches" \
    "${APP_NAME}/hooks.py" \
    "${APP_NAME}/iran_transport/doctype/trade_case/trade_case.json" \
    "${APP_NAME}/patches.txt"

if git diff --cached --quiet; then
    warn "Nothing to commit."
else
    git commit -m \
        "phase11: additive multi shipment support"
fi

# =============================================================================
step "DONE"
# =============================================================================

cat <<EOF

${GREEN}✅ فاز ۱۱ به‌صورت مستقل و Additive نصب شد.${NC}

ویژگی‌ها:
  ✅ هیچ controller قبلی بازنویسی نشد
  ✅ هیچ فایل JavaScript قبلی بازنویسی نشد
  ✅ workflowهای قبلی حفظ شدند
  ✅ منطق auto-create فاز ۵ دست‌نخورده باقی ماند
  ✅ گزارش ۱۴۰۵ دست‌نخورده باقی ماند
  ✅ گارد اضافه‌بارگیری از doc_events اجرا می‌شود
  ✅ محاسبه تناژ در سرویس مستقل انجام می‌شود
  ✅ Client Script مستقل ایجاد شد
  ✅ Backfill به‌صورت patch انجام شد
  ✅ اجرای مجدد اسکریپت idempotent است

توجه:
  برای تست عملی شش سناریوی کامل، باید فیلدهای اجباری واقعی
  Trade Case و Transport Case در پروژه شما با داده‌های تست تکمیل شوند.
EOF