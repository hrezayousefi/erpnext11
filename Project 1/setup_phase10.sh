#!/usr/bin/env bash
# =============================================================================
# setup_phase10.sh — Phase 10A Financial Integration Hub (CORRECTED)
# App isolation: NEVER touch transport_ir / ir_base / ir_jalali / ir_gateway
# Native hooks only in ir_integration/hooks.py
# =============================================================================
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONIOENCODING=utf-8

SITE_NAME="transport-dev.local"   # shell only — never written into app files
BENCH_DIR="${HOME}/frappe-bench"
APP="ir_integration"
APP_DIR="${BENCH_DIR}/apps/${APP}"
PKG="${APP_DIR}/${APP}"
MOD="${PKG}/ir_integration"
DT="${MOD}/doctype"
CAP="${MOD}/capabilities"
ADP="${MOD}/adapters"
SRV="${MOD}/services"
API="${MOD}/api"
PAGE="${MOD}/page/financial_dashboard"
WS="${MOD}/workspace/ir_integration"
WSFIN="${MOD}/workspace/finance_integration"
FIX="${PKG}/fixtures"
SETUP="${MOD}/setup"
JS="${PKG}/public/js"
TRN="${PKG}/translations"

COMMIT_MSG="phase 10a: ir_integration financial hub (capability adapters, dry-run, native hooks only)"

C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_NC=$'\033[0m'
log()  { printf "%s[INFO]%s %s\n" "$C_BLUE" "$C_NC" "$*"; }
info() { printf "%s[ OK ]%s %s\n" "$C_GREEN" "$C_NC" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "$C_YELLOW" "$C_NC" "$*"; }
err()  { printf "%s[ERR ]%s %s\n" "$C_RED" "$C_NC" "$*" >&2; exit 1; }
step() { printf "\n%s%s=====> %s%s\n" "$C_BOLD" "$C_YELLOW" "$*" "$C_NC"; }
write_utf8() { mkdir -p "$(dirname "$1")"; cat > "$1"; }
ensure_init() { mkdir -p "$1"; [[ -f "$1/__init__.py" ]] || : > "$1/__init__.py"; }

PYBIN="${BENCH_DIR}/env/bin/python"
[[ -x "$PYBIN" ]] || PYBIN="$(command -v python3 || true)"
[[ -n "$PYBIN" ]] || err "No python"

validate_py() {
  "$PYBIN" - "$1" <<'EOF' || err "Python syntax error: $1"
import ast, sys, pathlib
ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
EOF
}
validate_json() { "$PYBIN" -m json.tool "$1" >/dev/null || err "Invalid JSON: $1"; }
site_has_app() { bench --site "$1" list-apps 2>/dev/null | awk '{print $1}' | grep -Fxq "$2"; }
redis_cache_port() {
  local conf="${BENCH_DIR}/config/redis_cache.conf"
  if [[ -f "$conf" ]]; then
    awk '$1 == "port" {print $2; exit}' "$conf"
  else
    printf '%s\n' "13000"
  fi
}
redis_cache_ready() {
  local port
  port="$(redis_cache_port)"
  redis-cli -p "$port" ping >/dev/null 2>&1
}
wait_redis_cache() {
  local ok=0
  for _i in $(seq 1 45); do
    if redis_cache_ready; then
      ok=1
      break
    fi
    sleep 1
  done
  [[ "$ok" -eq 1 ]]
}
validate_fixture_names() {
  "$PYBIN" - "$FIX" <<'EOF' || err "Every fixture document must include doctype and name"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
missing = []
for path in sorted(root.glob("*.json")):
    docs = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(docs, dict):
        docs = [docs]
    for index, doc in enumerate(docs):
        if not isinstance(doc, dict) or not doc.get("doctype") or not doc.get("name"):
            missing.append(f"{path.name}[{index}]")
if missing:
    raise SystemExit("Missing doctype/name: " + ", ".join(missing))
EOF
}

# -----------------------------------------------------------------------------
step "0. Preflight + ensure bench services"
# -----------------------------------------------------------------------------
command -v bench >/dev/null || err "bench not found"
[[ -d "$BENCH_DIR" ]] || err "missing bench"
[[ -f "${BENCH_DIR}/sites/${SITE_NAME}/site_config.json" ]] || err "site missing"
cd "$BENCH_DIR"
if redis_cache_ready; then
  log "redis_cache already running on port $(redis_cache_port)"
else
  nohup bench start >>/tmp/bench-start-phase10.log 2>&1 &
  log "bench start pid=$!"
fi
info "waiting for redis_cache ..."
wait_redis_cache || err "redis_cache not ready. See /tmp/bench-start-phase10.log"
info "redis_cache ready on port $(redis_cache_port)"
for ra in frappe erpnext ir_base transport_ir ir_jalali ir_gateway; do
  site_has_app "$SITE_NAME" "$ra" || err "required app missing: $ra"
done
_count() {
  bench --site "$SITE_NAME" execute frappe.db.count \
    --args "[\"DocType\", {\"name\": \"$1\"}]" 2>/dev/null | tail -1 | tr -d '[:space:]'
}
[[ "$(_count 'Transport Case')" == "1" ]] || err "Transport Case missing"
[[ "$(_count 'Sales Invoice')" == "1" ]] || err "Sales Invoice missing"
[[ "$(_count 'SMS Gateway Settings')" == "1" ]] || err "SMS Gateway Settings missing"
info "deps ok"

# -----------------------------------------------------------------------------
step "1. Scaffold (manual only — bench new-app options vary by version)"
# -----------------------------------------------------------------------------
mkdir -p "$APP_DIR"
mkdir -p "$PKG" "$MOD"
write_utf8 "${PKG}/__init__.py" <<'PY'
__version__ = "1.0.0"
PY
write_utf8 "${PKG}/modules.txt" <<'TXT'
IR Integration
TXT
: > "${PKG}/patches.txt"
write_utf8 "${APP_DIR}/requirements.txt" <<'TXT'
requests>=2.28
TXT
write_utf8 "${APP_DIR}/license.txt" <<'TXT'
MIT License
Copyright (c) IR Base Contributors
TXT
write_utf8 "${APP_DIR}/pyproject.toml" <<'TOML'
[project]
name = "ir_integration"
version = "1.0.0"
description = "Financial Integration Hub"
requires-python = ">=3.10"
dependencies = ["requests>=2.28"]
[build-system]
requires = ["setuptools>=61.0.0", "wheel"]
build-backend = "setuptools.build_meta"
TOML
write_utf8 "${APP_DIR}/setup.py" <<'PY'
from setuptools import setup, find_packages
setup(name="ir_integration", version="1.0.0", packages=find_packages(),
      zip_safe=False, include_package_data=True, install_requires=["requests>=2.28"])
PY
write_utf8 "${APP_DIR}/MANIFEST.in" <<'TXT'
include *.md *.txt
recursive-include ir_integration *.json *.py *.js
recursive-include ir_integration/translations *.csv
TXT
write_utf8 "${APP_DIR}/README.md" <<'MD'
# IR Integration
Capability-based adapters. Core never imports a vendor.
Entry point: `integration_service.push_to_external()`.
MD
write_utf8 "${APP_DIR}/DEVELOPMENT_RULES.md" <<'MD'
1. Only `ir_integration` files. Never touch transport_ir / ir_base / ir_jalali / ir_gateway.
2. Native hooks only in this app's hooks.py. Frappe merges doc_events.
3. No sed/cat mutation of other apps.
4. No site name in app code.
5. Dry-run default. Failures logged, never raised onto host docs.
6. WhatsApp excluded.
MD
write_utf8 "${APP_DIR}/BACKLOG.md" <<'MD'
## Phase 10B
- Real Sepidar JWT / push / pull
## Phase 10C
- Reconciliation, retry queue, SMS mismatch alerts
## Never
- WhatsApp, chat, maps, BI builders
MD

# -----------------------------------------------------------------------------
step "2. Directories (this app only)"
# -----------------------------------------------------------------------------
ensure_init "$PKG"; ensure_init "$MOD"; ensure_init "$DT"
ensure_init "$CAP"; ensure_init "$ADP"; ensure_init "${ADP}/sepidar"
ensure_init "$SRV"; ensure_init "$API"; ensure_init "${MOD}/page"
ensure_init "$PAGE"; ensure_init "${MOD}/workspace"; ensure_init "$WS"
ensure_init "$WSFIN"; ensure_init "$SETUP"; ensure_init "$JS"; mkdir -p "$FIX"
mkdir -p "$TRN"
for d in external_integration_settings external_system integration_mapping \
         integration_log integration_sync_status reconciliation_rule; do
  ensure_init "${DT}/${d}"
done

# -----------------------------------------------------------------------------
step "3. Capabilities + adapters"
# -----------------------------------------------------------------------------
write_utf8 "${CAP}/base.py" <<'PY'
from __future__ import annotations
from abc import ABC, abstractmethod

class BaseCapability(ABC):
    capability_name: str = ""

class AuthenticationCapability(BaseCapability):
    capability_name = "authentication"
    @abstractmethod
    def authenticate(self) -> tuple[bool, str]: ...
    @abstractmethod
    def get_auth_mode(self) -> str: ...

class CustomerCapability(BaseCapability):
    capability_name = "customer"
    @abstractmethod
    def get_customers(self) -> list[dict]: ...
    @abstractmethod
    def push_customer(self, data: dict) -> dict: ...

class ItemCapability(BaseCapability):
    capability_name = "item"
    @abstractmethod
    def get_items(self) -> list[dict]: ...
    @abstractmethod
    def push_item(self, data: dict) -> dict: ...

class InvoiceCapability(BaseCapability):
    capability_name = "invoice"
    @abstractmethod
    def push_sales_invoice(self, data: dict, mapping: dict) -> dict: ...
    @abstractmethod
    def push_purchase_invoice(self, data: dict, mapping: dict) -> dict: ...
    @abstractmethod
    def get_invoice_status(self, ext_id: str) -> dict: ...

class PaymentCapability(BaseCapability):
    capability_name = "payment"
    @abstractmethod
    def push_payment(self, data: dict, mapping: dict) -> dict: ...
    @abstractmethod
    def get_payment_status(self, ext_id: str) -> dict: ...

class ReconciliationCapability(BaseCapability):
    capability_name = "reconciliation"
    @abstractmethod
    def get_balances(self) -> list[dict]: ...
    @abstractmethod
    def reconcile(self, erp_rec: dict, ext_rec: dict) -> dict: ...
PY
write_utf8 "${CAP}/__init__.py" <<'PY'
from ir_integration.ir_integration.capabilities.base import *  # noqa
PY

write_utf8 "${ADP}/base_adapter.py" <<'PY'
from __future__ import annotations
from abc import ABC, abstractmethod

class BaseExternalAdapter(ABC):
    adapter_id = ""
    adapter_name = ""
    adapter_version = "1.0.0"
    system_type = ""
    capabilities: list[str] = []

    def __init__(self, settings: dict):
        self.settings = settings or {}

    def supports(self, capability_name: str) -> bool:
        return capability_name in (self.capabilities or [])

    @classmethod
    @abstractmethod
    def get_config_fields(cls) -> list[dict]: ...

    @classmethod
    @abstractmethod
    def get_mapping_fields(cls) -> list[dict]: ...

    @abstractmethod
    def test_connection(self) -> tuple[bool, str]: ...

    @abstractmethod
    def dry_run(self, action: str, payload: dict, mapping: dict) -> dict: ...

    def validate_config(self) -> tuple[bool, str]:
        missing = [f.get("label") or f["fieldname"]
                   for f in self.get_config_fields()
                   if f.get("reqd") and not self.settings.get(f["fieldname"])]
        return (False, "Missing: " + ", ".join(missing)) if missing else (True, "OK")

    @classmethod
    def describe(cls) -> dict:
        return {
            "adapter_id": cls.adapter_id,
            "adapter_name": cls.adapter_name,
            "adapter_version": cls.adapter_version,
            "system_type": cls.system_type,
            "capabilities": list(cls.capabilities or []),
            "config_fields": cls.get_config_fields(),
            "mapping_fields": cls.get_mapping_fields(),
        }

def register_adapter(adapter_class):
    from ir_integration.ir_integration.adapters.adapter_registry import register_adapter as _r
    return _r(adapter_class)
PY

write_utf8 "${ADP}/adapter_registry.py" <<'PY'
from __future__ import annotations
import importlib, os
import frappe

BASE_PACKAGE = "ir_integration.ir_integration.adapters"
SKIP = {"__init__.py", "base_adapter.py", "adapter_registry.py"}
_ADAPTER_REGISTRY: dict[str, type] = {}
_DISCOVERED = False

def register_adapter(adapter_class):
    aid = getattr(adapter_class, "adapter_id", None)
    if not aid:
        raise ValueError("adapter_id required")
    _ADAPTER_REGISTRY[aid] = adapter_class
    return adapter_class

def discover_adapters(force: bool = False) -> None:
    global _DISCOVERED
    if _DISCOVERED and not force:
        return
    root = os.path.dirname(os.path.abspath(__file__))
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith((".", "_"))]
        rel = os.path.relpath(dirpath, root)
        parts = [] if rel == "." else rel.split(os.sep)
        for filename in sorted(filenames):
            if not filename.endswith(".py") or filename in SKIP or filename.startswith("_"):
                continue
            dotted = ".".join([BASE_PACKAGE] + parts + [filename[:-3]])
            try:
                importlib.import_module(dotted)
            except Exception:
                try:
                    frappe.log_error(title=f"adapter discovery {dotted}"[:140],
                                     message=frappe.get_traceback())
                except Exception:
                    pass
    _DISCOVERED = True

def get_adapter(adapter_id: str, settings: dict):
    if adapter_id not in _ADAPTER_REGISTRY:
        discover_adapters(force=True)
    if adapter_id not in _ADAPTER_REGISTRY:
        frappe.throw(f"External adapter '{adapter_id}' not found")
    return _ADAPTER_REGISTRY[adapter_id](settings)

def get_adapter_class(adapter_id: str):
    if adapter_id not in _ADAPTER_REGISTRY:
        discover_adapters(force=True)
    return _ADAPTER_REGISTRY.get(adapter_id)

def list_adapters() -> list[dict]:
    discover_adapters()
    out = []
    for cls in sorted(_ADAPTER_REGISTRY.values(), key=lambda c: c.adapter_name or ""):
        try:
            out.append(cls.describe())
        except Exception:
            out.append({"adapter_id": cls.adapter_id, "adapter_name": cls.adapter_name,
                        "capabilities": getattr(cls, "capabilities", [])})
    return out

def list_adapters_with_capabilities() -> list[dict]:
    return list_adapters()

def list_adapter_ids() -> list[str]:
    discover_adapters()
    return sorted(_ADAPTER_REGISTRY.keys())
PY
write_utf8 "${ADP}/__init__.py" <<'PY'
from ir_integration.ir_integration.adapters.adapter_registry import (
    discover_adapters, get_adapter, list_adapters, list_adapters_with_capabilities,
    list_adapter_ids, register_adapter,
)
__all__ = ["discover_adapters", "get_adapter", "list_adapters",
           "list_adapters_with_capabilities", "list_adapter_ids", "register_adapter"]
PY

write_utf8 "${ADP}/sepidar/sepidar_mapping.py" <<'PY'
from __future__ import annotations
import json
DEFAULT_ACCOUNT_MAP = {
    "freight_cost": "هزینه حمل", "customs_cost": "هزینه گمرک",
    "clearance_cost": "هزینه ترخیص", "demurrage_cost": "حق توقف",
    "border_agent_fee": "حق‌العمل نماینده مرزی",
    "purchase_amount": "خرید", "sales_amount": "فروش",
    "carrier_payable": "حساب پرداختنی-حاملان",
    "customer_receivable": "حساب دریافتنی-مشتریان",
}
DEFAULT_DOCTYPE_MAP = {
    "Transport Case": "سند حمل", "Trade Case": "سند بازرگانی",
    "Sales Invoice": "فاکتور فروش", "Purchase Invoice": "فاکتور خرید",
    "Payment Entry": "سند پرداخت",
}
def parse_json_map(raw, default=None):
    default = dict(default or {})
    if not raw:
        return default
    if isinstance(raw, dict):
        return {**default, **raw}
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            return {**default, **parsed}
    except Exception:
        pass
    return default
def get_effective_mapping(mapping: dict) -> dict:
    mapping = mapping or {}
    return {
        "account_map": parse_json_map(mapping.get("account_map"), DEFAULT_ACCOUNT_MAP),
        "doctype_map": parse_json_map(mapping.get("doctype_map"), DEFAULT_DOCTYPE_MAP),
        "party_map": parse_json_map(mapping.get("party_map"), {}),
        "cost_center_map": parse_json_map(mapping.get("cost_center_map"), {}),
        "project_map": parse_json_map(mapping.get("project_map"), {}),
    }
PY
write_utf8 "${ADP}/sepidar/sepidar_auth.py" <<'PY'
class SepidarAuthManager:
    def __init__(self, settings: dict):
        self.settings = settings
    def register_device(self):
        raise NotImplementedError("Phase 10B")
    def login(self):
        raise NotImplementedError("Phase 10B")
PY
write_utf8 "${ADP}/sepidar/sepidar_adapter.py" <<'PY'
from __future__ import annotations
import json
from ir_integration.ir_integration.adapters.base_adapter import BaseExternalAdapter, register_adapter
from ir_integration.ir_integration.adapters.sepidar.sepidar_mapping import (
    DEFAULT_ACCOUNT_MAP, DEFAULT_DOCTYPE_MAP, get_effective_mapping,
)

@register_adapter
class SepidarAdapter(BaseExternalAdapter):
    adapter_id = "sepidar"
    adapter_name = "Sepidar Accounting (Hamkaran System)"
    adapter_version = "1.0.0"
    system_type = "Accounting"
    capabilities = ["authentication", "customer", "item", "invoice", "payment"]

    @classmethod
    def get_config_fields(cls):
        return [
            {"fieldname": "auth_mode", "label": "حالت احراز هویت", "fieldtype": "Select", "reqd": 0, "default": "login"},
            {"fieldname": "api_url", "label": "آدرس API", "fieldtype": "Data"},
            {"fieldname": "dry_run", "label": "حالت آزمایشی", "fieldtype": "Check", "default": 1},
        ]

    @classmethod
    def get_mapping_fields(cls):
        return [
            {"fieldname": "account_map", "label": "نگاشت حساب‌ها", "fieldtype": "Code", "default": DEFAULT_ACCOUNT_MAP},
            {"fieldname": "doctype_map", "label": "نگاشت اسناد", "fieldtype": "Code", "default": DEFAULT_DOCTYPE_MAP},
        ]

    def is_dry_run(self) -> bool:
        v = self.settings.get("dry_run", 1)
        return bool(int(v or 0)) if str(v).isdigit() else bool(v)

    def dry_run(self, action: str, payload: dict, mapping: dict) -> dict:
        preview = {"action": action, "system": "sepidar",
                   "payload": payload, "mapping_used": get_effective_mapping(mapping),
                   "status": "dry_run"}
        return {"success": True, "status": "dry_run", "error": None,
                "preview_data": preview,
                "file_content": json.dumps(preview, ensure_ascii=False, indent=2, default=str),
                "raw_response": {}}

    def test_connection(self):
        if self.is_dry_run():
            return True, "Dry-run mode — no real connection"
        raise NotImplementedError("Phase 10B")
PY
write_utf8 "${ADP}/sepidar/__init__.py" <<'PY'
PY

# -----------------------------------------------------------------------------
step "4. Services + API + dashboard data"
# -----------------------------------------------------------------------------
write_utf8 "${SRV}/integration_service.py" <<'PY'
from __future__ import annotations
import json
import frappe
from frappe.utils import add_to_date, cint, now_datetime
from ir_integration.ir_integration.adapters.adapter_registry import discover_adapters, get_adapter

DEFAULT_DUPLICATE_WINDOW = 60

def get_integration_settings():
    try:
        return frappe.get_single("External Integration Settings")
    except Exception:
        return None

def is_integration_enabled() -> bool:
    s = get_integration_settings()
    return bool(s and cint(s.integration_enabled))

def is_feature_enabled(feature_name: str) -> bool:
    if not is_integration_enabled():
        return False
    s = get_integration_settings()
    if not s:
        return False
    field = f"enable_{feature_name}"
    return cint(s.get(field)) if s.meta.has_field(field) else True

def should_hide_from_ui() -> bool:
    s = get_integration_settings()
    if not s or not is_integration_enabled():
        return True
    return cint(s.hide_from_ui)

def get_configured_adapter(system_name=None):
    if not system_name:
        s = get_integration_settings()
        system_name = getattr(s, "default_external_system", None) if s else None
    if not system_name or not frappe.db.exists("External System", system_name):
        return None, None
    system_doc = frappe.get_doc("External System", system_name)
    if not cint(system_doc.is_active) or not system_doc.adapter_id:
        return None, system_doc
    discover_adapters()
    config = {
        "api_url": system_doc.api_url,
        "username": system_doc.username,
        "password": system_doc.get_password("password", raise_exception=False),
        "company_code": system_doc.company_code,
        "dry_run": cint(system_doc.dry_run),
        "auth_mode": system_doc.auth_mode,
    }
    if system_doc.config_json:
        try:
            extra = json.loads(system_doc.config_json)
            if isinstance(extra, dict):
                config.update(extra)
        except Exception:
            pass
    try:
        return get_adapter(system_doc.adapter_id, config), system_doc
    except Exception:
        frappe.log_error(title="adapter load failed", message=frappe.get_traceback())
        return None, system_doc

def get_mapping_for_system(system_name, mapping_type=None):
    filters = {"external_system": system_name, "is_active": 1}
    if mapping_type:
        filters["mapping_type"] = mapping_type
    rows = frappe.get_all("Integration Mapping", filters=filters, fields=["name"],
                          order_by="modified desc", limit_page_length=1)
    if not rows:
        return {}
    doc = frappe.get_doc("Integration Mapping", rows[0].name)
    try:
        return json.loads(doc.map_json) if doc.map_json else {}
    except Exception:
        return {}

def _prevent_duplicate(reference_doctype, reference_name, external_system_name, action) -> bool:
    if not reference_name or not external_system_name:
        return False
    cutoff = add_to_date(now_datetime(), minutes=-DEFAULT_DUPLICATE_WINDOW)
    filters = {
        "reference_name": reference_name,
        "external_system": external_system_name,
        "action": action,
        "status": "success",
        "sent_at": [">=", cutoff],
    }
    if reference_doctype:
        filters["reference_doctype"] = reference_doctype
    try:
        return bool(frappe.db.exists("Integration Log", filters))
    except Exception:
        return False

def _dump(value):
    if value in (None, "", {}, []):
        return ""
    try:
        return json.dumps(value, ensure_ascii=False, indent=2, default=str)[:60000]
    except Exception:
        return str(value)[:60000]

def _create_integration_log(entry: dict):
    try:
        doc = frappe.new_doc("Integration Log")
        for k, v in (entry or {}).items():
            if doc.meta.has_field(k):
                doc.set(k, v)
        doc.flags.ignore_permissions = True
        doc.flags.ignore_links = True
        doc.flags.ignore_mandatory = True
        doc.insert(ignore_permissions=True)
        return doc
    except Exception:
        try:
            frappe.log_error(title="log create failed", message=frappe.get_traceback())
        except Exception:
            pass
        return None

def _result(success, status, error=None, log=None, preview=None):
    return {"success": bool(success), "status": status, "error": error,
            "log_name": getattr(log, "name", None), "preview_data": preview or {}}

def _save_external_id(reference_doctype, reference_name, result, system_doc=None):
    """Write back external id / sync status onto the host document when fields exist."""
    if not result or not result.get("success"):
        return
    ext_id = (
        result.get("external_id")
        or (result.get("raw_response") or {}).get("id")
        or (result.get("preview_data") or {}).get("external_id")
    )
    try:
        meta = frappe.get_meta(reference_doctype)
        updates = {}
        if ext_id and meta.has_field("external_id"):
            updates["external_id"] = ext_id
        if meta.has_field("external_sync_status"):
            updates["external_sync_status"] = "synced"
        if meta.has_field("last_external_sync"):
            updates["last_external_sync"] = now_datetime()
        if system_doc and meta.has_field("external_system"):
            updates["external_system"] = system_doc.name
        if not updates:
            return
        doc = frappe.get_doc(reference_doctype, reference_name)
        for k, v in updates.items():
            doc.db_set(k, v, update_modified=False)
    except Exception:
        try:
            frappe.log_error(title="save external_id failed", message=frappe.get_traceback())
        except Exception:
            pass

def _dispatch_real_export(adapter, action, payload, mapping):
    """Per-capability dispatch for real (non-dry-run) export path."""
    if action == "push_customer" and hasattr(adapter, "push_customer"):
        return adapter.push_customer(payload)
    elif action == "push_item" and hasattr(adapter, "push_item"):
        return adapter.push_item(payload)
    elif action == "push_sales_invoice" and hasattr(adapter, "push_sales_invoice"):
        return adapter.push_sales_invoice(payload, mapping)
    elif action == "push_purchase_invoice" and hasattr(adapter, "push_purchase_invoice"):
        return adapter.push_purchase_invoice(payload, mapping)
    elif action == "push_payment" and hasattr(adapter, "push_payment"):
        return adapter.push_payment(payload, mapping)
    elif action == "push_cost" and hasattr(adapter, "push_sales_invoice"):
        return adapter.push_sales_invoice(payload, mapping)
    raise NotImplementedError(f"Real export for action '{action}' not implemented in Phase 10A")

def push_to_external(reference_doctype, reference_name, external_system_name=None,
                     action="push_cost", dry_run=True, force=False):
    entry = {"reference_doctype": reference_doctype, "reference_name": reference_name,
             "external_system": external_system_name, "action": action,
             "status": "pending", "sent_at": now_datetime()}
    if not is_integration_enabled():
        entry.update(status="feature_disabled", error_message="integration disabled")
        return _result(False, "feature_disabled", entry["error_message"], _create_integration_log(entry))

    adapter, system_doc = get_configured_adapter(external_system_name)
    if not system_doc:
        entry.update(status="failed", error_message="No external system")
        return _result(False, "failed", entry["error_message"], _create_integration_log(entry))
    entry["external_system"] = system_doc.name
    if not adapter:
        entry.update(status="failed", error_message="adapter unavailable")
        return _result(False, "failed", entry["error_message"], _create_integration_log(entry))

    cap_map = {"push_customer": "customer", "push_item": "item",
               "push_sales_invoice": "invoice", "push_purchase_invoice": "invoice",
               "push_payment": "payment", "reconcile": "reconciliation"}
    needed = cap_map.get(action)
    if needed and not adapter.supports(needed):
        entry.update(status="not_implemented", error_message=f"capability {needed} not supported")
        return _result(False, "not_implemented", entry["error_message"], _create_integration_log(entry))

    adapter_dry = bool(adapter.settings.get("dry_run", 1))
    effective_dry = adapter_dry if dry_run is None else bool(cint(dry_run))
    if effective_dry:
        entry["action"] = "dry_run"

    if not effective_dry and not force and _prevent_duplicate(
            reference_doctype, reference_name, system_doc.name, action):
        entry.update(status="duplicate", error_message="duplicate export")
        return _result(False, "duplicate", entry["error_message"], _create_integration_log(entry))

    if not frappe.db.exists(reference_doctype, reference_name):
        entry.update(status="failed", error_message="document not found")
        return _result(False, "failed", entry["error_message"], _create_integration_log(entry))

    payload = frappe.get_doc(reference_doctype, reference_name).as_dict()
    mapping = get_mapping_for_system(system_doc.name)
    try:
        if effective_dry:
            result = adapter.dry_run(action, payload, mapping)
        else:
            result = _dispatch_real_export(adapter, action, payload, mapping)
    except NotImplementedError as e:
        entry.update(status="not_implemented", error_message=str(e))
        return _result(False, "not_implemented", str(e), _create_integration_log(entry))
    except Exception as e:
        frappe.log_error(title="export failed", message=frappe.get_traceback())
        entry.update(status="failed", error_message=str(e))
        return _result(False, "failed", str(e), _create_integration_log(entry))

    preview = result.get("preview_data") or {}
    entry["status"] = result.get("status") or "dry_run"
    entry["error_message"] = result.get("error")
    entry["request_payload"] = _dump(preview)
    log = _create_integration_log(entry)
    if not effective_dry and result.get("success"):
        _save_external_id(reference_doctype, reference_name, result, system_doc)
    return _result(bool(result.get("success")), entry["status"], entry.get("error_message"), log, preview)

def pull_from_external(external_system_name, entity_type, filters=None):
    entry = {"external_system": external_system_name, "action": "pull_item",
             "status": "not_implemented", "sent_at": now_datetime(),
             "error_message": "Phase 10B"}
    _create_integration_log(entry)
    return {"success": False, "status": "not_implemented", "data": []}

def test_external_connection(system_name=None):
    adapter, system_doc = get_configured_adapter(system_name)
    if not system_doc:
        return {"success": False, "message": "No system"}
    if not adapter:
        return {"success": False, "message": "adapter unavailable"}
    try:
        ok, msg = adapter.test_connection()
        return {"success": ok, "message": msg, "system": system_doc.name}
    except Exception as e:
        return {"success": False, "message": str(e)}
PY
write_utf8 "${SRV}/mapping_service.py" <<'PY'
from __future__ import annotations
import json
import frappe

def get_mapping(mapping_name: str) -> dict:
    if not frappe.db.exists("Integration Mapping", mapping_name):
        return {}
    doc = frappe.get_doc("Integration Mapping", mapping_name)
    try:
        return json.loads(doc.map_json) if doc.map_json else {}
    except Exception:
        return {}

def apply_mapping(data: dict, mapping: dict) -> dict:
    return {mapping.get(k, k): v for k, v in (data or {}).items()}

def validate_mapping(map_json: str):
    try:
        parsed = json.loads(map_json)
        return (True, "OK") if isinstance(parsed, dict) else (False, "must be object")
    except Exception as e:
        return False, str(e)

def list_mapping_types():
    return ["Account", "Party", "Item", "CostCenter", "Project", "Doctype"]
PY
write_utf8 "${SRV}/sync_service.py" <<'PY'
import frappe
def sync_party(*a, **k):
    return {"success": False, "status": "not_implemented"}
def sync_item(*a, **k):
    return {"success": False, "status": "not_implemented"}
def sync_invoice(*a, **k):
    return {"success": False, "status": "not_implemented"}
def get_sync_status(reference_doctype, reference_name):
    logs = frappe.get_all("Integration Log",
        filters={"reference_doctype": reference_doctype, "reference_name": reference_name},
        fields=["status", "sent_at"], order_by="sent_at desc", limit_page_length=1)
    return logs[0] if logs else {"status": "pending", "sent_at": None}
PY
write_utf8 "${SRV}/__init__.py" <<'PY'
PY

write_utf8 "${MOD}/dashboard/__init__.py" <<'PY'
PY
# keep python aggregator used by page
ensure_init "${MOD}/dashboard"
write_utf8 "${MOD}/dashboard/financial_dashboard.py" <<'PY'
from __future__ import annotations
import frappe
from frappe.utils import today

def get_dashboard_data() -> dict:
    systems = []
    for sys in frappe.get_all("External System", filters={"is_active": 1},
                              fields=["name", "system_name", "dry_run"]):
        success = frappe.db.count("Integration Log",
            {"external_system": sys.name, "status": "success", "sent_at": [">=", today()]})
        failed = frappe.db.count("Integration Log",
            {"external_system": sys.name, "status": "failed", "sent_at": [">=", today()]})
        systems.append({"name": sys.system_name,
                        "status": "dry_run" if sys.dry_run else "connected",
                        "today": {"success": success, "failed": failed}})
    recent = frappe.get_all("Integration Log",
        fields=["name", "external_system", "status", "sent_at", "action"],
        order_by="sent_at desc", limit_page_length=10)
    mismatches = frappe.get_all("Integration Log", filters={"status": "mismatch"},
        fields=["name", "reference_name"], limit_page_length=5)
    return {"systems": systems, "recent_logs": recent, "mismatches": mismatches,
            "pending_count": frappe.db.count("Integration Log", {"status": "pending"})}
PY

write_utf8 "${API}/integration_api.py" <<'PY'
from __future__ import annotations
import frappe
WRITE_ROLES = ["System Manager", "Financial Manager", "Finance Supervisor"]

@frappe.whitelist()
def list_external_adapters():
    from ir_integration.ir_integration.adapters.adapter_registry import list_adapters
    return list_adapters()

@frappe.whitelist()
def list_external_adapters_with_capabilities():
    from ir_integration.ir_integration.adapters.adapter_registry import list_adapters_with_capabilities
    return list_adapters_with_capabilities()

@frappe.whitelist()
def test_external_connection(system_name=None):
    from ir_integration.ir_integration.services.integration_service import test_external_connection as t
    return t(system_name)

@frappe.whitelist()
def dry_run_action(reference_doctype, reference_name, system_name=None, action="push_cost"):
    frappe.only_for(WRITE_ROLES)
    from ir_integration.ir_integration.services.integration_service import push_to_external
    return push_to_external(reference_doctype, reference_name, system_name, action, dry_run=True)

@frappe.whitelist()
def push_to_external(reference_doctype, reference_name, system_name=None,
                     action="push_cost", dry_run=1, force=0):
    frappe.only_for(WRITE_ROLES)
    from ir_integration.ir_integration.services.integration_service import push_to_external as p
    return p(reference_doctype, reference_name, system_name, action,
             dry_run=frappe.utils.cint(dry_run), force=bool(frappe.utils.cint(force)))

@frappe.whitelist()
def pull_from_external(system_name, entity_type, filters=None):
    frappe.only_for(WRITE_ROLES)
    from ir_integration.ir_integration.services.integration_service import pull_from_external as p
    return p(system_name, entity_type, filters)

@frappe.whitelist()
def get_integration_history(reference_doctype, reference_name, limit=50):
    return frappe.get_all("Integration Log",
        filters={"reference_doctype": reference_doctype, "reference_name": reference_name},
        fields=["name", "external_system", "action", "status", "error_message", "sent_at"],
        order_by="sent_at desc", limit_page_length=int(limit or 50))

@frappe.whitelist()
def get_financial_dashboard():
    from ir_integration.ir_integration.dashboard.financial_dashboard import get_dashboard_data
    return get_dashboard_data()

@frappe.whitelist()
def retry_integration(log_name):
    frappe.only_for(WRITE_ROLES)
    return {"success": False, "status": "not_implemented"}

@frappe.whitelist()
def check_adapter_capabilities(adapter_id):
    from ir_integration.ir_integration.adapters.adapter_registry import get_adapter_class
    cls = get_adapter_class(adapter_id)
    return list(getattr(cls, "capabilities", []) or [])

@frappe.whitelist()
def get_feature_flags():
    from ir_integration.ir_integration.services.integration_service import get_integration_settings
    s = get_integration_settings()
    return s.as_dict() if s else {}

@frappe.whitelist()
def is_integration_visible():
    from ir_integration.ir_integration.services.integration_service import (
        is_integration_enabled, should_hide_from_ui,
    )
    enabled = is_integration_enabled()
    return {"visible": enabled and not should_hide_from_ui(), "enabled": enabled}
PY
write_utf8 "${API}/__init__.py" <<'PY'
PY

# -----------------------------------------------------------------------------
step "5. DocTypes (6 only; dashboard is a Page)"
# -----------------------------------------------------------------------------
write_utf8 "${DT}/external_integration_settings/external_integration_settings.json" <<'JSON'
{"doctype":"DocType","name":"External Integration Settings","module":"IR Integration","issingle":1,"engine":"InnoDB","track_changes":1,
"field_order":["integration_enabled","hide_from_ui","test_mode","feature_flags_section","enable_push_invoices","enable_push_payments","enable_push_costs","enable_pull_accounts","enable_pull_parties","enable_reconciliation","enable_dashboard","enable_form_buttons","enable_workspace_links","access_control_section","allow_finance_manager","allow_finance_user","allow_ceo_view","default_section","default_external_system","default_mapping"],
"fields":[
{"fieldname":"integration_enabled","fieldtype":"Check","label":"فعال‌سازی یکپارچه‌سازی","default":"0"},
{"fieldname":"hide_from_ui","fieldtype":"Check","label":"مخفی کردن از رابط کاربری","default":"1"},
{"fieldname":"test_mode","fieldtype":"Check","label":"حالت آزمایشی","default":"1"},
{"fieldname":"feature_flags_section","fieldtype":"Section Break","label":"پرچم‌های ویژگی"},
{"fieldname":"enable_push_invoices","fieldtype":"Check","label":"ارسال فاکتورها","default":"0","depends_on":"eval:doc.integration_enabled==1"},
{"fieldname":"enable_push_payments","fieldtype":"Check","label":"ارسال پرداخت‌ها","default":"0","depends_on":"eval:doc.integration_enabled==1"},
{"fieldname":"enable_push_costs","fieldtype":"Check","label":"ارسال هزینه‌ها","default":"0","depends_on":"eval:doc.integration_enabled==1"},
{"fieldname":"enable_pull_accounts","fieldtype":"Check","label":"دریافت حساب‌ها","default":"0","depends_on":"eval:doc.integration_enabled==1"},
{"fieldname":"enable_pull_parties","fieldtype":"Check","label":"دریافت طرف‌ها","default":"0","depends_on":"eval:doc.integration_enabled==1"},
{"fieldname":"enable_reconciliation","fieldtype":"Check","label":"مغایرت‌گیری","default":"0","depends_on":"eval:doc.integration_enabled==1"},
{"fieldname":"enable_dashboard","fieldtype":"Check","label":"داشبورد مالی","default":"1","depends_on":"eval:doc.integration_enabled==1"},
{"fieldname":"enable_form_buttons","fieldtype":"Check","label":"دکمه‌های فرم","default":"1","depends_on":"eval:doc.integration_enabled==1"},
{"fieldname":"enable_workspace_links","fieldtype":"Check","label":"لینک‌های ورک‌اسپیس","default":"1","depends_on":"eval:doc.integration_enabled==1"},
{"fieldname":"access_control_section","fieldtype":"Section Break","label":"کنترل دسترسی"},
{"fieldname":"allow_finance_manager","fieldtype":"Check","label":"مدیر مالی","default":"1"},
{"fieldname":"allow_finance_user","fieldtype":"Check","label":"کاربر مالی","default":"1"},
{"fieldname":"allow_ceo_view","fieldtype":"Check","label":"مشاهده مدیرعامل","default":"0"},
{"fieldname":"default_section","fieldtype":"Section Break","label":"پیش‌فرض‌ها"},
{"fieldname":"default_external_system","fieldtype":"Link","options":"External System","label":"سیستم بیرونی پیش‌فرض"},
{"fieldname":"default_mapping","fieldtype":"Link","options":"Integration Mapping","label":"نگاشت پیش‌فرض"}
],"permissions":[
{"role":"System Manager","read":1,"write":1,"create":1,"delete":1},
{"role":"Financial Manager","read":1},
{"role":"CEO","read":1}
]}
JSON
write_utf8 "${DT}/external_integration_settings/external_integration_settings.py" <<'PY'
from frappe.model.document import Document
class ExternalIntegrationSettings(Document):
    pass
PY

write_utf8 "${DT}/external_system/external_system.json" <<'JSON'
{"doctype":"DocType","name":"External System","module":"IR Integration","autoname":"field:system_name","naming_rule":"By fieldname","engine":"InnoDB","track_changes":1,"allow_rename":1,
"field_order":["system_name","adapter_id","system_type","is_active","is_master","auth_mode","connection_section","api_url","serial","generation_version","username","password","integration_id","arbitrary_code","encrypted_code","bearer_token","company_code","dry_run","timeout_seconds","max_retries","retry_delay_seconds","advanced_section","config_json","notes"],
"fields":[
{"fieldname":"system_name","fieldtype":"Data","label":"نام سیستم","reqd":1,"unique":1,"in_list_view":1},
{"fieldname":"adapter_id","fieldtype":"Data","label":"شناسه ارائه‌دهنده (Adapter)","reqd":1,"in_list_view":1,"description":"شناسهٔ آداپتور ثبت‌شده در رجیستری (مثال: sepidar). لیست معتبر پویا است."},
{"fieldname":"system_type","fieldtype":"Select","label":"نوع سیستم","options":"Accounting\nCRM\nPayment\nExport\nOther","default":"Accounting"},
{"fieldname":"is_active","fieldtype":"Check","label":"فعال","default":"1"},
{"fieldname":"is_master","fieldtype":"Select","label":"منبع اصلی","options":"ERPNext\nExternal","default":"External"},
{"fieldname":"auth_mode","fieldtype":"Select","label":"حالت احراز هویت","options":"login\ndirect_keys\napi_key","default":"login"},
{"fieldname":"connection_section","fieldtype":"Section Break","label":"اتصال"},
{"fieldname":"api_url","fieldtype":"Data","label":"آدرس API"},
{"fieldname":"serial","fieldtype":"Data","label":"شماره سریال"},
{"fieldname":"generation_version","fieldtype":"Data","label":"نسخه"},
{"fieldname":"username","fieldtype":"Data","label":"نام کاربری"},
{"fieldname":"password","fieldtype":"Password","label":"رمز عبور"},
{"fieldname":"integration_id","fieldtype":"Data","label":"شناسه یکپارچه‌سازی"},
{"fieldname":"arbitrary_code","fieldtype":"Data","label":"کد دلخواه"},
{"fieldname":"encrypted_code","fieldtype":"Password","label":"کد رمزنگاری‌شده"},
{"fieldname":"bearer_token","fieldtype":"Password","label":"توکن"},
{"fieldname":"company_code","fieldtype":"Data","label":"کد شرکت"},
{"fieldname":"dry_run","fieldtype":"Check","label":"حالت آزمایشی","default":"1"},
{"fieldname":"timeout_seconds","fieldtype":"Int","label":"تایم‌اوت","default":"30"},
{"fieldname":"max_retries","fieldtype":"Int","label":"حداکثر تلاش","default":"2"},
{"fieldname":"retry_delay_seconds","fieldtype":"Int","label":"تاخیر تلاش","default":"5"},
{"fieldname":"advanced_section","fieldtype":"Section Break","label":"پیشرفته","collapsible":1},
{"fieldname":"config_json","fieldtype":"Code","options":"JSON","label":"تنظیمات اضافی"},
{"fieldname":"notes","fieldtype":"Small Text","label":"یادداشت"}
],"permissions":[
{"role":"System Manager","read":1,"write":1,"create":1,"delete":1},
{"role":"Financial Manager","read":1,"write":1},
{"role":"Finance User","read":1}
],"title_field":"system_name"}
JSON
write_utf8 "${DT}/external_system/external_system.py" <<'PY'
import json, frappe
from frappe.model.document import Document
class ExternalSystem(Document):
    def validate(self):
        if not self.adapter_id:
            frappe.throw("انتخاب ارائه‌دهنده الزامی است.")
        # اعتبارسنجی پویا از رجیستری، نه از یک Select استاتیک
        from ir_integration.ir_integration.adapters.adapter_registry import discover_adapters, get_adapter_class
        discover_adapters()
        if not get_adapter_class(self.adapter_id):
            frappe.throw(f"آداپتور '{self.adapter_id}' در رجیستری یافت نشد.")
        if self.config_json:
            try:
                if not isinstance(json.loads(self.config_json), dict):
                    raise ValueError
            except Exception:
                frappe.throw("تنظیمات اضافی باید JSON object باشد.")
PY

write_utf8 "${DT}/integration_mapping/integration_mapping.json" <<'JSON'
{"doctype":"DocType","name":"Integration Mapping","module":"IR Integration","autoname":"field:mapping_name","naming_rule":"By fieldname","engine":"InnoDB","track_changes":1,
"fields":[
{"fieldname":"external_system","fieldtype":"Link","options":"External System","label":"سیستم بیرونی","reqd":1,"in_list_view":1},
{"fieldname":"mapping_name","fieldtype":"Data","label":"نام نگاشت","reqd":1,"unique":1,"in_list_view":1},
{"fieldname":"mapping_type","fieldtype":"Select","label":"نوع نگاشت","options":"Account\nParty\nItem\nCostCenter\nProject\nDoctype","reqd":1,"default":"Account"},
{"fieldname":"is_active","fieldtype":"Check","label":"فعال","default":"1"},
{"fieldname":"map_json","fieldtype":"Code","options":"JSON","label":"نگاشت","reqd":1},
{"fieldname":"description","fieldtype":"Small Text","label":"توضیحات"}
],"field_order":["external_system","mapping_name","mapping_type","is_active","map_json","description"],
"permissions":[{"role":"System Manager","read":1,"write":1,"create":1,"delete":1},{"role":"Financial Manager","read":1,"write":1},{"role":"Finance User","read":1}],
"title_field":"mapping_name"}
JSON
write_utf8 "${DT}/integration_mapping/integration_mapping.py" <<'PY'
import json, frappe
from frappe.model.document import Document
class IntegrationMapping(Document):
    def validate(self):
        if self.map_json:
            try:
                if not isinstance(json.loads(self.map_json), dict):
                    raise ValueError
            except Exception:
                frappe.throw("نگاشت باید JSON object باشد.")
PY

write_utf8 "${DT}/integration_log/integration_log.json" <<'JSON'
{"doctype":"DocType","name":"Integration Log","module":"IR Integration","autoname":"hash","engine":"InnoDB",
"field_order":["reference_doctype","reference_name","external_system","action","status","sent_at","external_id","error_message","payload_section","request_payload","response_payload","dry_run_file","retry_section","retry_count","max_retries","next_retry_at","duration_ms","feature_flag"],
"fields":[
{"fieldname":"reference_doctype","fieldtype":"Link","options":"DocType","label":"نوع سند مرجع"},
{"fieldname":"reference_name","fieldtype":"Dynamic Link","options":"reference_doctype","label":"نام سند مرجع","in_list_view":1},
{"fieldname":"external_system","fieldtype":"Link","options":"External System","label":"سیستم بیرونی","in_list_view":1},
{"fieldname":"action","fieldtype":"Select","label":"عملیات","options":"push_customer\npush_item\npush_sales_invoice\npush_purchase_invoice\npush_payment\npush_cost\npull_customer\npull_item\ntest_connection\ndry_run\nreconcile","default":"push_cost"},
{"fieldname":"status","fieldtype":"Select","label":"وضعیت","options":"pending\nsuccess\nfailed\nduplicate\ndry_run\nqueued\nmismatch\nnot_implemented\nfeature_disabled","default":"pending","in_list_view":1},
{"fieldname":"sent_at","fieldtype":"Datetime","label":"زمان","in_list_view":1},
{"fieldname":"external_id","fieldtype":"Data","label":"شناسه بیرونی"},
{"fieldname":"error_message","fieldtype":"Small Text","label":"پیام خطا"},
{"fieldname":"payload_section","fieldtype":"Section Break","label":"محتوا","collapsible":1},
{"fieldname":"request_payload","fieldtype":"Code","options":"JSON","label":"درخواست"},
{"fieldname":"response_payload","fieldtype":"Code","options":"JSON","label":"پاسخ"},
{"fieldname":"dry_run_file","fieldtype":"Attach","label":"فایل پیش‌نمایش"},
{"fieldname":"retry_section","fieldtype":"Section Break","label":"تلاش مجدد","collapsible":1},
{"fieldname":"retry_count","fieldtype":"Int","label":"تعداد تلاش","default":"0"},
{"fieldname":"max_retries","fieldtype":"Int","label":"حداکثر تلاش","default":"3"},
{"fieldname":"next_retry_at","fieldtype":"Datetime","label":"تلاش بعدی"},
{"fieldname":"duration_ms","fieldtype":"Int","label":"مدت"},
{"fieldname":"feature_flag","fieldtype":"Data","label":"پرچم ویژگی"}
],"permissions":[
{"role":"System Manager","read":1,"write":1,"create":1,"delete":1,"report":1,"export":1},
{"role":"Financial Manager","read":1,"report":1,"export":1},
{"role":"Finance User","read":1,"report":1},
{"role":"Transport Supervisor","read":1},
{"role":"CEO","read":1,"report":1}
],"sort_field":"sent_at","sort_order":"DESC"}
JSON
write_utf8 "${DT}/integration_log/integration_log.py" <<'PY'
from frappe.model.document import Document
class IntegrationLog(Document):
    pass
PY

write_utf8 "${DT}/integration_sync_status/integration_sync_status.json" <<'JSON'
{"doctype":"DocType","name":"Integration Sync Status","module":"IR Integration","istable":1,"editable_grid":1,"engine":"InnoDB",
"field_order":["entity_type","erpnext_id","external_id","sync_status","last_sync","error_message"],
"fields":[
{"fieldname":"entity_type","fieldtype":"Data","label":"نوع موجودیت","in_list_view":1},
{"fieldname":"erpnext_id","fieldtype":"Data","label":"شناسه ERP","in_list_view":1},
{"fieldname":"external_id","fieldtype":"Data","label":"شناسه بیرونی"},
{"fieldname":"sync_status","fieldtype":"Select","label":"وضعیت","options":"synced\npending\nerror\nmismatch"},
{"fieldname":"last_sync","fieldtype":"Datetime","label":"آخرین همگام‌سازی"},
{"fieldname":"error_message","fieldtype":"Small Text","label":"پیام خطا"}
],"permissions":[]}
JSON
write_utf8 "${DT}/integration_sync_status/integration_sync_status.py" <<'PY'
from frappe.model.document import Document
class IntegrationSyncStatus(Document):
    pass
PY

write_utf8 "${DT}/reconciliation_rule/reconciliation_rule.json" <<'JSON'
{"doctype":"DocType","name":"Reconciliation Rule","module":"IR Integration","autoname":"field:rule_name","naming_rule":"By fieldname","engine":"InnoDB","track_changes":1,
"fields":[
{"fieldname":"external_system","fieldtype":"Link","options":"External System","label":"سیستم بیرونی","reqd":1},
{"fieldname":"rule_name","fieldtype":"Data","label":"نام قانون","reqd":1,"unique":1},
{"fieldname":"erpnext_doctype","fieldtype":"Data","label":"نوع سند ERP","reqd":1},
{"fieldname":"external_entity_type","fieldtype":"Data","label":"نوع موجودیت بیرونی","reqd":1},
{"fieldname":"match_fields","fieldtype":"Small Text","label":"فیلدهای تطبیق"},
{"fieldname":"tolerance_percent","fieldtype":"Float","label":"درصد خطا","default":"0.01"},
{"fieldname":"is_active","fieldtype":"Check","label":"فعال","default":"1"}
],"field_order":["external_system","rule_name","erpnext_doctype","external_entity_type","match_fields","tolerance_percent","is_active"],
"permissions":[{"role":"System Manager","read":1,"write":1,"create":1,"delete":1},{"role":"Financial Manager","read":1,"write":1,"create":1},{"role":"Finance User","read":1}],
"title_field":"rule_name"}
JSON
write_utf8 "${DT}/reconciliation_rule/reconciliation_rule.py" <<'PY'
from frappe.model.document import Document
class ReconciliationRule(Document):
    pass
PY

# -----------------------------------------------------------------------------
step "6. Page + workspace + setup_workspace (no workspace_link fixture)"
# -----------------------------------------------------------------------------
write_utf8 "${PAGE}/financial_dashboard.json" <<'JSON'
{
  "doctype": "Page",
  "name": "financial-dashboard",
  "page_name": "financial-dashboard",
  "title": "داشبورد مالی یکپارچه‌سازی",
  "module": "IR Integration",
  "standard": "Yes",
  "icon": "chart-bar",
  "restrict_to_domain": ""
}
JSON
write_utf8 "${PAGE}/financial_dashboard.js" <<'JS'
frappe.pages["financial-dashboard"].on_page_load = function (wrapper) {
    const page = frappe.ui.make_app_page({
        parent: wrapper,
        title: __("داشبورد مالی یکپارچه‌سازی"),
        single_column: true,
    });
    const $body = $(wrapper).find(".layout-main-section");
    $body.html("<div class='padding'>Loading…</div>");
    frappe.call({
        method: "ir_integration.ir_integration.api.integration_api.get_financial_dashboard",
        callback(r) {
            const d = r.message || {};
            const systems = (d.systems || []).map(s =>
                `<div class="col-sm-4"><div class="card p-3"><b>${frappe.utils.escape_html(s.name)}</b><br>${s.status}<br>OK ${s.today && s.today.success || 0} / Fail ${s.today && s.today.failed || 0}</div></div>`
            ).join("");
            const logs = (d.recent_logs || []).map(l =>
                `<li>${frappe.utils.escape_html(String(l.sent_at || ""))} — ${l.status} — ${l.action}</li>`
            ).join("");
            $body.html(`<div class="row">${systems}</div><h5 class="mt-4">Recent</h5><ul>${logs}</ul>`);
        },
    });
};
JS

# Workspace: English name/label/title only — Persian display via translations/fa.csv
# (Frappe v15 routes from slug(title); Persian title → 404 vs slug(name)=ir-integration)
write_utf8 "${WS}/ir_integration.json" <<'JSON'
{
  "doctype": "Workspace",
  "name": "IR Integration",
  "label": "IR Integration",
  "title": "IR Integration",
  "module": "IR Integration",
  "icon": "tir-finance",
  "public": 1,
  "is_standard": 1,
  "sequence_id": 100.0,
  "content": "[{\"id\":\"irint_systems\",\"type\":\"card\",\"data\":{\"card_name\":\"سیستم‌های بیرونی\",\"col\":4}},{\"id\":\"irint_logs\",\"type\":\"card\",\"data\":{\"card_name\":\"لاگ و پایش\",\"col\":4}}]",
  "links": [
    {"type": "Card Break", "label": "سیستم‌های بیرونی", "link_count": 4, "hidden": 0, "onboard": 0},
    {"type": "Link", "label": "تنظیمات یکپارچه‌سازی", "link_type": "DocType", "link_to": "External Integration Settings", "hidden": 0, "onboard": 0, "is_query_report": 0},
    {"type": "Link", "label": "سیستم‌های بیرونی", "link_type": "DocType", "link_to": "External System", "hidden": 0, "onboard": 0, "is_query_report": 0},
    {"type": "Link", "label": "نگاشت‌ها", "link_type": "DocType", "link_to": "Integration Mapping", "hidden": 0, "onboard": 0, "is_query_report": 0},
    {"type": "Link", "label": "قوانین مغایرت", "link_type": "DocType", "link_to": "Reconciliation Rule", "hidden": 0, "onboard": 0, "is_query_report": 0},
    {"type": "Card Break", "label": "لاگ و پایش", "link_count": 2, "hidden": 0, "onboard": 0},
    {"type": "Link", "label": "لاگ ارسال‌ها", "link_type": "DocType", "link_to": "Integration Log", "hidden": 0, "onboard": 0, "is_query_report": 0},
    {"type": "Link", "label": "داشبورد مالی", "link_type": "Page", "link_to": "financial-dashboard", "hidden": 0, "onboard": 0, "is_query_report": 0}
  ],
  "roles": [
    {"role": "System Manager"},
    {"role": "Financial Manager"},
    {"role": "Finance Supervisor"},
    {"role": "Finance User"},
    {"role": "CEO"}
  ]
}
JSON

# Do NOT hide Desk/sidebar DOM by matching translated Persian text.
# fa.csv maps "IR Integration" → "یکپارچه‌سازی مالی و حسابداری"; global
# $(".widget").text().indexOf("یکپارچه‌سازی") would hide this workspace itself
# after SPA page-change (and retry timers made it worse). Form buttons still
# use is_integration_visible() scoped to each form.
write_utf8 "${WSFIN}/finance_integration.js" <<'JS'
// No client-side DOM hiding.
// Workspace / sidebar visibility must not scrape translated text on SPA routes.
JS

write_utf8 "${SETUP}/setup_workspace.py" <<'PY'
"""Idempotent Finance workspace link injection. Never edits another app's files."""
from __future__ import annotations
import frappe

FINANCE_CANDIDATES = ["Finance", "IR Finance", "Financial Manager", "مالی", "امور مالی"]
CARD = "یکپارچه‌سازی حسابداری"
LINKS = [
    ("تنظیمات یکپارچه‌سازی", "External Integration Settings"),
    ("سیستم‌های بیرونی", "External System"),
    ("نگاشت‌ها", "Integration Mapping"),
    ("لاگ ارسال‌ها", "Integration Log"),
]

def setup_finance_workspace_links():
    name = None
    for c in FINANCE_CANDIDATES:
        if frappe.db.exists("Workspace", c):
            name = c
            break
    if not name:
        for row in frappe.get_all("Workspace", fields=["name", "label", "title"]):
            hay = " ".join(str(row.get(k) or "") for k in ("name", "label", "title")).lower()
            if "finance" in hay or "مالی" in hay:
                name = row["name"]
                break
    if not name:
        frappe.logger().info("ir_integration: Finance workspace not found")
        return
    doc = frappe.get_doc("Workspace", name)
    existing = {(row.get("link_to") or "") for row in (doc.get("links") or [])}
    has_card = any(row.get("type") == "Card Break" and row.get("label") == CARD
                   for row in (doc.get("links") or []))
    missing = [(lbl, tgt) for lbl, tgt in LINKS if tgt not in existing]
    if not missing:
        return
    if not has_card:
        doc.append("links", {"type": "Card Break", "label": CARD, "link_count": len(missing),
                             "hidden": 0, "onboard": 0})
    for lbl, tgt in missing:
        if not frappe.db.exists("DocType", tgt):
            continue
        doc.append("links", {"type": "Link", "label": lbl, "link_type": "DocType",
                             "link_to": tgt, "hidden": 0, "onboard": 0, "is_query_report": 0})
    doc.flags.ignore_permissions = True
    doc.flags.ignore_links = True
    doc.flags.ignore_version = True
    doc.save(ignore_permissions=True)
PY

write_utf8 "${SETUP}/workspace_normalize.py" <<'PY'
"""Normalize IR Integration workspace identity (ASCII name/title) + purge Persian duplicates.

Frappe v15 builds sidebar route from slug(title) but resolves against slug(name).
Persian title → /app/<persian-slug> 404. English name/label/title + fa.csv display.
Mirrors phase-9 apply_default_persian pattern. Never edits other apps' files.
"""
from __future__ import annotations
import os
import shutil
import frappe

CANONICAL = "IR Integration"
ICON = "tir-finance"
# Known bad identities from earlier deploys (Persian title / slug / ZWNJ variants)
PERSIAN_DUPES = [
    "یکپارچه‌سازی مالی و حسابداری",
    "یکپارچه‌سازی-مالی-و-حسابداری",
    "یکپارچه‌سازی مالی و حسابداری\u200c",
    "یکپارچه\u200cسازی مالی و حسابداری",
]

def _has_non_ascii(value: str) -> bool:
    try:
        str(value or "").encode("ascii")
        return False
    except UnicodeEncodeError:
        return True

def _purge_persian_workspace_folders() -> None:
    """Remove on-disk workspace folders with non-ASCII names under this app only."""
    here = os.path.dirname(os.path.abspath(__file__))
    ws_root = os.path.normpath(os.path.join(here, "..", "workspace"))
    if not os.path.isdir(ws_root):
        return
    for entry in os.listdir(ws_root):
        path = os.path.join(ws_root, entry)
        if not os.path.isdir(path):
            continue
        if entry in ("ir_integration", "finance_integration"):
            continue
        if _has_non_ascii(entry) or entry.startswith("درگاه"):
            try:
                shutil.rmtree(path)
            except Exception:
                pass

def normalize_workspace() -> None:
    # 1) Delete Persian-named / slug-named duplicate Workspace docs
    for bad in PERSIAN_DUPES:
        if frappe.db.exists("Workspace", bad):
            try:
                frappe.delete_doc("Workspace", bad, force=1, ignore_permissions=True)
            except Exception:
                frappe.db.sql("DELETE FROM `tabWorkspace` WHERE name=%s", bad)
                frappe.db.sql("DELETE FROM `tabWorkspace Link` WHERE parent=%s", bad)

    # Also catch any remaining non-ASCII workspace whose module is IR Integration
    for row in frappe.get_all(
        "Workspace",
        filters={"module": "IR Integration"},
        fields=["name", "title", "label"],
    ):
        if row["name"] == CANONICAL:
            continue
        blob = " ".join(str(row.get(k) or "") for k in ("name", "title", "label"))
        if _has_non_ascii(blob) or "یکپارچه" in blob:
            try:
                frappe.delete_doc("Workspace", row["name"], force=1, ignore_permissions=True)
            except Exception:
                frappe.db.sql("DELETE FROM `tabWorkspace` WHERE name=%s", row["name"])
                frappe.db.sql("DELETE FROM `tabWorkspace Link` WHERE parent=%s", row["name"])

    # 2) Force canonical Workspace identity (ASCII name == label == title)
    if frappe.db.exists("Workspace", CANONICAL):
        doc = frappe.get_doc("Workspace", CANONICAL)
        dirty = False
        for field, value in (
            ("title", CANONICAL),
            ("label", CANONICAL),
            ("icon", ICON),
            ("public", 1),
            ("module", "IR Integration"),
        ):
            if doc.meta.has_field(field) and doc.get(field) != value:
                doc.set(field, value)
                dirty = True
        if dirty:
            doc.flags.ignore_permissions = True
            doc.flags.ignore_links = True
            doc.flags.ignore_version = True
            doc.save(ignore_permissions=True)
    else:
        # Ensure standard workspace from app files is imported on next migrate;
        # create a minimal public shell so sidebar is immediately correct.
        doc = frappe.new_doc("Workspace")
        doc.name = CANONICAL
        doc.label = CANONICAL
        doc.title = CANONICAL
        doc.module = "IR Integration"
        doc.icon = ICON
        doc.public = 1
        doc.is_standard = 1
        doc.flags.ignore_permissions = True
        doc.insert(ignore_permissions=True)

    # 3) On-disk cleanup (this app only)
    _purge_persian_workspace_folders()

    frappe.db.commit()
    frappe.clear_cache()
PY
write_utf8 "${SETUP}/__init__.py" <<'PY'
PY

# Persian display labels — never put these in Workspace name/label/title
write_utf8 "${TRN}/fa.csv" <<'CSV'
IR Integration,یکپارچه‌سازی مالی و حسابداری,
External System,سیستم بیرونی,
Integration Mapping,نگاشت‌ها,
Integration Log,لاگ ارسال‌ها,
External Integration Settings,تنظیمات یکپارچه‌سازی,
Reconciliation Rule,قوانین مغایرت,
Financial Integration Dashboard,داشبورد مالی یکپارچه‌سازی,
CSV

# -----------------------------------------------------------------------------
step "7. Fixtures (no workspace_link.json) + hooks (this app only)"
# -----------------------------------------------------------------------------
write_utf8 "${FIX}/external_system.json" <<'JSON'
[{"doctype":"External System","name":"Sepidar","system_name":"Sepidar","adapter_id":"sepidar","system_type":"Accounting","is_master":"External","is_active":1,"dry_run":1,"auth_mode":"login"}]
JSON
write_utf8 "${FIX}/integration_mapping.json" <<'JSON'
[
 {"doctype":"Integration Mapping","name":"Sepidar Account Mapping","external_system":"Sepidar","mapping_name":"Sepidar Account Mapping","mapping_type":"Account","is_active":1,
  "map_json":"{\"freight_cost\":\"هزینه حمل\",\"customs_cost\":\"هزینه گمرک\",\"clearance_cost\":\"هزینه ترخیص\",\"demurrage_cost\":\"حق توقف\",\"border_agent_fee\":\"حق‌العمل نماینده مرزی\",\"purchase_amount\":\"خرید\",\"sales_amount\":\"فروش\",\"carrier_payable\":\"حساب پرداختنی-حاملان\",\"customer_receivable\":\"حساب دریافتنی-مشتریان\"}"},
 {"doctype":"Integration Mapping","name":"Sepidar Party Mapping","external_system":"Sepidar","mapping_name":"Sepidar Party Mapping","mapping_type":"Party","is_active":1,"map_json":"{}"},
 {"doctype":"Integration Mapping","name":"Sepidar Item Mapping","external_system":"Sepidar","mapping_name":"Sepidar Item Mapping","mapping_type":"Item","is_active":1,"map_json":"{}"},
 {"doctype":"Integration Mapping","name":"Sepidar Cost Center Mapping","external_system":"Sepidar","mapping_name":"Sepidar Cost Center Mapping","mapping_type":"CostCenter","is_active":1,"map_json":"{}"},
 {"doctype":"Integration Mapping","name":"Sepidar Doctype Mapping","external_system":"Sepidar","mapping_name":"Sepidar Doctype Mapping","mapping_type":"Doctype","is_active":1,
  "map_json":"{\"Transport Case\":\"سند حمل\",\"Sales Invoice\":\"فاکتور فروش\"}"}
]
JSON
write_utf8 "${FIX}/custom_field.json" <<'JSON'
[
 {"doctype":"Custom Field","name":"Transport Case-integration_section","dt":"Transport Case","module":"IR Integration","fieldname":"integration_section","fieldtype":"Section Break","label":"یکپارچه‌سازی مالی","insert_after":"naming_series"},
 {"doctype":"Custom Field","name":"Transport Case-external_system","dt":"Transport Case","module":"IR Integration","fieldname":"external_system","fieldtype":"Link","options":"External System","label":"سیستم بیرونی","insert_after":"integration_section"},
 {"doctype":"Custom Field","name":"Transport Case-external_id","dt":"Transport Case","module":"IR Integration","fieldname":"external_id","fieldtype":"Data","label":"شناسه بیرونی","read_only":1,"insert_after":"external_system"},
 {"doctype":"Custom Field","name":"Transport Case-external_sync_status","dt":"Transport Case","module":"IR Integration","fieldname":"external_sync_status","fieldtype":"Select","options":"pending\nsynced\nerror\nmismatch","label":"وضعیت همگام‌سازی","read_only":1,"insert_after":"external_id"},
 {"doctype":"Custom Field","name":"Transport Case-last_external_sync","dt":"Transport Case","module":"IR Integration","fieldname":"last_external_sync","fieldtype":"Datetime","label":"آخرین همگام‌سازی","read_only":1,"insert_after":"external_sync_status"},
 {"doctype":"Custom Field","name":"Transport Case-integration_mapping","dt":"Transport Case","module":"IR Integration","fieldname":"integration_mapping","fieldtype":"Link","options":"Integration Mapping","label":"نگاشت","insert_after":"last_external_sync"},
 {"doctype":"Custom Field","name":"Sales Invoice-integration_section","dt":"Sales Invoice","module":"IR Integration","fieldname":"integration_section","fieldtype":"Section Break","label":"یکپارچه‌سازی مالی","insert_after":"naming_series"},
 {"doctype":"Custom Field","name":"Sales Invoice-external_system","dt":"Sales Invoice","module":"IR Integration","fieldname":"external_system","fieldtype":"Link","options":"External System","label":"سیستم بیرونی","insert_after":"integration_section"},
 {"doctype":"Custom Field","name":"Sales Invoice-external_id","dt":"Sales Invoice","module":"IR Integration","fieldname":"external_id","fieldtype":"Data","label":"شناسه بیرونی","read_only":1,"insert_after":"external_system"},
 {"doctype":"Custom Field","name":"Sales Invoice-external_sync_status","dt":"Sales Invoice","module":"IR Integration","fieldname":"external_sync_status","fieldtype":"Select","options":"pending\nsynced\nerror\nmismatch","label":"وضعیت همگام‌سازی","read_only":1,"insert_after":"external_id"},
 {"doctype":"Custom Field","name":"Sales Invoice-last_external_sync","dt":"Sales Invoice","module":"IR Integration","fieldname":"last_external_sync","fieldtype":"Datetime","label":"آخرین همگام‌سازی","read_only":1,"insert_after":"external_sync_status"},
 {"doctype":"Custom Field","name":"Sales Invoice-integration_mapping","dt":"Sales Invoice","module":"IR Integration","fieldname":"integration_mapping","fieldtype":"Link","options":"Integration Mapping","label":"نگاشت","insert_after":"last_external_sync"},
 {"doctype":"Custom Field","name":"Purchase Invoice-integration_section","dt":"Purchase Invoice","module":"IR Integration","fieldname":"integration_section","fieldtype":"Section Break","label":"یکپارچه‌سازی مالی","insert_after":"naming_series"},
 {"doctype":"Custom Field","name":"Purchase Invoice-external_system","dt":"Purchase Invoice","module":"IR Integration","fieldname":"external_system","fieldtype":"Link","options":"External System","label":"سیستم بیرونی","insert_after":"integration_section"},
 {"doctype":"Custom Field","name":"Purchase Invoice-external_id","dt":"Purchase Invoice","module":"IR Integration","fieldname":"external_id","fieldtype":"Data","label":"شناسه بیرونی","read_only":1,"insert_after":"external_system"},
 {"doctype":"Custom Field","name":"Purchase Invoice-external_sync_status","dt":"Purchase Invoice","module":"IR Integration","fieldname":"external_sync_status","fieldtype":"Select","options":"pending\nsynced\nerror\nmismatch","label":"وضعیت همگام‌سازی","read_only":1,"insert_after":"external_id"},
 {"doctype":"Custom Field","name":"Purchase Invoice-last_external_sync","dt":"Purchase Invoice","module":"IR Integration","fieldname":"last_external_sync","fieldtype":"Datetime","label":"آخرین همگام‌سازی","read_only":1,"insert_after":"external_sync_status"},
 {"doctype":"Custom Field","name":"Purchase Invoice-integration_mapping","dt":"Purchase Invoice","module":"IR Integration","fieldname":"integration_mapping","fieldtype":"Link","options":"Integration Mapping","label":"نگاشت","insert_after":"last_external_sync"},
 {"doctype":"Custom Field","name":"Payment Entry-integration_section","dt":"Payment Entry","module":"IR Integration","fieldname":"integration_section","fieldtype":"Section Break","label":"یکپارچه‌سازی مالی","insert_after":"naming_series"},
 {"doctype":"Custom Field","name":"Payment Entry-external_system","dt":"Payment Entry","module":"IR Integration","fieldname":"external_system","fieldtype":"Link","options":"External System","label":"سیستم بیرونی","insert_after":"integration_section"},
 {"doctype":"Custom Field","name":"Payment Entry-external_id","dt":"Payment Entry","module":"IR Integration","fieldname":"external_id","fieldtype":"Data","label":"شناسه بیرونی","read_only":1,"insert_after":"external_system"},
 {"doctype":"Custom Field","name":"Payment Entry-external_sync_status","dt":"Payment Entry","module":"IR Integration","fieldname":"external_sync_status","fieldtype":"Select","options":"pending\nsynced\nerror\nmismatch","label":"وضعیت همگام‌سازی","read_only":1,"insert_after":"external_id"},
 {"doctype":"Custom Field","name":"Payment Entry-last_external_sync","dt":"Payment Entry","module":"IR Integration","fieldname":"last_external_sync","fieldtype":"Datetime","label":"آخرین همگام‌سازی","read_only":1,"insert_after":"external_sync_status"},
 {"doctype":"Custom Field","name":"Payment Entry-integration_mapping","dt":"Payment Entry","module":"IR Integration","fieldname":"integration_mapping","fieldtype":"Link","options":"Integration Mapping","label":"نگاشت","insert_after":"last_external_sync"},
 {"doctype":"Custom Field","name":"Customer-external_system","dt":"Customer","module":"IR Integration","fieldname":"external_system","fieldtype":"Link","options":"External System","label":"سیستم بیرونی","insert_after":"customer_name"},
 {"doctype":"Custom Field","name":"Customer-external_customer_id","dt":"Customer","module":"IR Integration","fieldname":"external_customer_id","fieldtype":"Data","label":"شناسه مشتری بیرونی","read_only":1,"insert_after":"external_system"},
 {"doctype":"Custom Field","name":"Customer-last_customer_sync","dt":"Customer","module":"IR Integration","fieldname":"last_customer_sync","fieldtype":"Datetime","label":"آخرین همگام‌سازی","read_only":1,"insert_after":"external_customer_id"},
 {"doctype":"Custom Field","name":"Supplier-external_system","dt":"Supplier","module":"IR Integration","fieldname":"external_system","fieldtype":"Link","options":"External System","label":"سیستم بیرونی","insert_after":"supplier_name"},
 {"doctype":"Custom Field","name":"Supplier-external_supplier_id","dt":"Supplier","module":"IR Integration","fieldname":"external_supplier_id","fieldtype":"Data","label":"شناسه تامین‌کننده بیرونی","read_only":1,"insert_after":"external_system"},
 {"doctype":"Custom Field","name":"Supplier-last_supplier_sync","dt":"Supplier","module":"IR Integration","fieldname":"last_supplier_sync","fieldtype":"Datetime","label":"آخرین همگام‌سازی","read_only":1,"insert_after":"external_supplier_id"}
]
JSON

write_utf8 "${PKG}/hooks.py" <<'PY'
app_name = "ir_integration"
app_title = "IR Integration"
app_publisher = "IR Base Contributors"
app_description = "Financial Integration Hub for Iran Transport ERP"
app_email = "dev@example.com"
app_license = "MIT"

# Native merge only. Never edit other apps' hooks.py.
required_apps = ["frappe", "erpnext", "ir_base", "transport_ir", "ir_jalali", "ir_gateway"]

fixtures = [
    {"dt": "External System", "filters": [["is_active", "=", 1]]},
    {"dt": "Integration Mapping", "filters": [["is_active", "=", 1]]},
    {"dt": "Custom Field", "filters": [["module", "=", "IR Integration"]]},
]

after_migrate = [
    "ir_integration.ir_integration.setup.setup_workspace.setup_finance_workspace_links",
    "ir_integration.ir_integration.setup.workspace_normalize.normalize_workspace",
]
after_install = [
    "ir_integration.ir_integration.setup.setup_workspace.setup_finance_workspace_links",
    "ir_integration.ir_integration.setup.workspace_normalize.normalize_workspace",
]

# Phase 10A: no automatic document triggers. Frappe merges empty dicts safely.
doc_events = {}
scheduler_events = {}

doctype_js = {
    "External Integration Settings": "public/js/integration_settings.js",
    "External System": "public/js/integration_system.js",
    "Transport Case": "public/js/integration_buttons.js",
    "Sales Invoice": "public/js/integration_buttons.js",
    "Purchase Invoice": "public/js/integration_buttons.js",
    "Payment Entry": "public/js/integration_buttons.js",
}

# No global app_include_js DOM scrapers.
# Previous finance_workspace_visibility.js hid any .widget/.sidebar item whose
# translated text contained «یکپارچه‌سازی», which also matched this app's own
# workspace label from fa.csv after SPA page-change.
app_include_js = []
PY

# Neutral stub kept so stale asset paths / prior deploys do not 404 if referenced.
write_utf8 "${JS}/finance_workspace_visibility.js" <<'JS'
(function () {
    // Intentionally empty.
    // Do not hide workspace/sidebar DOM globally by matching translated text.
    // Form-level visibility remains in integration_buttons.js via is_integration_visible().
})();
JS

write_utf8 "${JS}/integration_buttons.js" <<'JS'
function ir_int_add_buttons(frm) {
    frappe.call({
        method: "ir_integration.ir_integration.api.integration_api.is_integration_visible",
        callback(r) {
            const vis = r.message || {};
            if (!vis.visible || !vis.enabled) return;
            const allowed = ["System Manager", "Financial Manager", "Finance Supervisor", "Finance User"];
            if (!frappe.user_roles.some((x) => allowed.includes(x))) return;

            frm.add_custom_button(__("پیش‌نمایش ارسال"), () => {
                frappe.call({
                    method: "ir_integration.ir_integration.api.integration_api.dry_run_action",
                    args: { reference_doctype: frm.doctype, reference_name: frm.docname, action: "push_cost" },
                    freeze: true,
                    callback(rr) {
                        const res = rr.message || {};
                        frappe.msgprint({
                            title: "Dry Run — " + (res.status || ""),
                            indicator: res.success ? "green" : "red",
                            message: "<pre style='direction:ltr;text-align:left;max-height:420px;overflow:auto'>" +
                                frappe.utils.escape_html(JSON.stringify(res.preview_data || {}, null, 2)) + "</pre>",
                        });
                    },
                });
            }, __("یکپارچه‌سازی"));

            frm.add_custom_button(__("ارسال به سیستم بیرونی"), () => {
                frappe.confirm(__("آیا مطمئن هستید؟"), () => {
                    frappe.call({
                        method: "ir_integration.ir_integration.api.integration_api.push_to_external",
                        args: { reference_doctype: frm.doctype, reference_name: frm.docname, action: "push_cost", dry_run: 0 },
                        freeze: true,
                        callback(rr) {
                            const res = rr.message || {};
                            frappe.msgprint({ title: "Export", indicator: res.success ? "green" : "red",
                                message: res.error || res.status || "ok" });
                        },
                    });
                });
            }, __("یکپارچه‌سازی"));

            frm.add_custom_button(__("تاریخچه یکپارچه‌سازی"), () => {
                frappe.call({
                    method: "ir_integration.ir_integration.api.integration_api.get_integration_history",
                    args: { reference_doctype: frm.doctype, reference_name: frm.docname },
                    callback(rr) {
                        const logs = rr.message || [];
                        frappe.msgprint({ title: __("History"),
                            message: "<ul>" + logs.map((l) => `<li>${l.sent_at} ${l.status} ${l.action}</li>`).join("") + "</ul>" });
                    },
                });
            }, __("یکپارچه‌سازی"));

            const st = frm.doc.external_sync_status;
            if (st === "synced") frm.dashboard.set_headline_alert(__("Synced"), "green");
            else if (st === "pending") frm.dashboard.set_headline_alert(__("Pending sync"), "orange");
            else if (st === "error" || st === "mismatch") frm.dashboard.set_headline_alert(__("Sync error"), "red");
        },
    });
}
["Transport Case", "Sales Invoice", "Purchase Invoice", "Payment Entry"].forEach((dt) => {
    frappe.ui.form.on(dt, { refresh: ir_int_add_buttons });
});
JS
write_utf8 "${JS}/integration_settings.js" <<'JS'
frappe.ui.form.on("External Integration Settings", {
    refresh(frm) {
        if (frm.doc.test_mode) {
            frm.dashboard.set_headline_alert(__("Test / dry-run mode"), "orange");
        }
        frm.add_custom_button(__("Test Connection"), () => {
            frappe.call({
                method: "ir_integration.ir_integration.api.integration_api.test_external_connection",
                args: { system_name: frm.doc.default_external_system },
                callback(r) {
                    const m = r.message || {};
                    frappe.msgprint({ message: m.message || JSON.stringify(m), indicator: m.success ? "green" : "red" });
                },
            });
        });
    },
});
JS
write_utf8 "${JS}/integration_system.js" <<'JS'
frappe.ui.form.on("External System", {
    adapter_id(frm) { /* آزاد؛ اعتبارسنجی سمت سرور در validate() انجام می‌شود */ },
    refresh(frm) {
        frappe.call({
            method: "ir_integration.ir_integration.api.integration_api.list_external_adapters",
            callback(r) {
                const ids = (r.message || []).map(a => a.adapter_id);
                if (frm.fields_dict.adapter_id) {
                    frm.fields_dict.adapter_id.awesomplete_options = ids; // پیشنهاد نه محدودیت
                }
                frm.set_df_property("adapter_id", "description",
                    (r.message || []).map(a => `${a.adapter_id} — ${a.adapter_name}`).join("<br>"));
            },
        });
        if (!frm.is_new()) {
            frm.add_custom_button(__("Test Connection"), () => {
                frappe.call({
                    method: "ir_integration.ir_integration.api.integration_api.test_external_connection",
                    args: { system_name: frm.doc.name },
                    callback(r) {
                        const m = r.message || {};
                        frappe.msgprint({ message: m.message || "", indicator: m.success ? "green" : "red" });
                    },
                });
            });
        }
    },
});
JS
write_utf8 "${JS}/financial_dashboard.js" <<'JS'
// Shared renderer used by Page financial-dashboard
window.ir_int_render_dashboard = function ($el, data) {
    $el.empty();
    (data.systems || []).forEach((s) => {
        $el.append(`<div>${frappe.utils.escape_html(s.name)} — ${s.status}</div>`);
    });
};
JS

# -----------------------------------------------------------------------------
step "8. verify_phase10.py (corrected duplicate + page + workspace)"
# -----------------------------------------------------------------------------
write_utf8 "${MOD}/verify_phase10.py" <<'PY'
import os
import pathlib
import frappe

DOCTYPES = [
    "External Integration Settings", "External System", "Integration Mapping",
    "Integration Log", "Integration Sync Status", "Reconciliation Rule",
]
APP_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

def _set_integration_enabled(value):
    """Write Single value and drop every cache layer get_single may hit."""
    frappe.db.set_single_value("External Integration Settings", "integration_enabled", value)
    frappe.clear_document_cache("External Integration Settings")
    frappe.db.commit()
    try:
        frappe.clear_cache(doctype="External Integration Settings")
    except Exception:
        pass
    # Drop in-process local doc cache used by get_single / get_doc
    try:
        if hasattr(frappe.local, "document_cache"):
            frappe.local.document_cache = {}
    except Exception:
        pass
    try:
        cache = getattr(frappe.local, "cache", None)
        if isinstance(cache, dict):
            for key in list(cache.keys()):
                if "External Integration Settings" in str(key):
                    cache.pop(key, None)
    except Exception:
        pass

def verify_phase10():
    passed, failed, warned = [], [], []
    def check(name, cond, detail=""):
        (passed if cond else failed).append(name)
        print(f"[{'PASS' if cond else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    def soft(name, cond, detail=""):
        if cond:
            passed.append(name); print(f"[PASS] {name}")
        else:
            warned.append(name); print(f"[WARN] {name} {detail}")

    check("ir_integration installed", "ir_integration" in (frappe.get_installed_apps() or []))
    for dt in DOCTYPES:
        check(f"DocType {dt}", bool(frappe.db.exists("DocType", dt)))
    check("Settings is Single", frappe.get_meta("External Integration Settings").issingle == 1)
    check("Sync Status is child", frappe.get_meta("Integration Sync Status").istable == 1)

    from ir_integration.ir_integration.adapters.adapter_registry import discover_adapters, list_adapters, get_adapter_class, get_adapter
    discover_adapters(force=True)
    ads = list_adapters()
    check(">=1 adapter", len(ads) >= 1)
    check("sepidar registered", any(a.get("adapter_id") == "sepidar" for a in ads))
    caps = getattr(get_adapter_class("sepidar"), "capabilities", [])
    check("sepidar caps", all(c in caps for c in ["authentication", "customer", "item", "invoice", "payment"]), str(caps))

    from ir_integration.ir_integration.adapters.base_adapter import BaseExternalAdapter
    for m in ("get_config_fields", "get_mapping_fields", "test_connection", "dry_run"):
        check(f"base.{m}", hasattr(BaseExternalAdapter, m))
    from ir_integration.ir_integration.services import integration_service, mapping_service  # noqa
    check("services importable", True)

    check("Sepidar fixture", bool(frappe.db.exists("External System", "Sepidar")))
    check("5 mappings", frappe.db.count("Integration Mapping", {"is_active": 1}) >= 5)
    for dt in ["Transport Case", "Sales Invoice", "Purchase Invoice", "Payment Entry"]:
        check(f"CF {dt}", bool(frappe.db.exists("Custom Field", {"dt": dt, "fieldname": "external_system"})))
    check("Workspace IR Integration", bool(frappe.db.exists("Workspace", "IR Integration")))
    check("Page financial-dashboard", bool(frappe.db.exists("Page", "financial-dashboard")))

    # Workspace identity must be ASCII (name == label == title) — no Persian route slug
    if frappe.db.exists("Workspace", "IR Integration"):
        ws = frappe.db.get_value(
            "Workspace", "IR Integration",
            ["name", "title", "label", "icon", "public"], as_dict=True,
        )
        check("ws title ASCII", ws and ws.title == "IR Integration", str(ws and ws.title))
        check("ws label ASCII", ws and ws.label == "IR Integration", str(ws and ws.label))
        check("ws icon set", ws and ws.icon in ("tir-finance", "message", "link"), str(ws and ws.icon))
        check("ws public", ws and int(ws.public or 0) == 1)
        # No leftover Persian-named workspace for this module
        bad = frappe.db.sql(
            "SELECT name FROM tabWorkspace WHERE module=%s AND name != %s AND name LIKE %s",
            ("IR Integration", "IR Integration", "%یکپارچه%"),
        )
        check("no Persian workspace dupe", not bad, str(bad))

    meta = frappe.get_meta("Integration Log")
    st = meta.get_field("status")
    check("status has not_implemented", st and "not_implemented" in (st.options or ""))

    # dry-run — capture true original, then force-enable for functional probes
    s = frappe.get_single("External Integration Settings")
    old_enabled = s.integration_enabled
    _set_integration_enabled(1)
    res = integration_service.push_to_external("External System", "Sepidar", "Sepidar", "push_cost", dry_run=True)
    check("dry-run success", bool(res.get("success")), str(res.get("status")))
    check("dry-run preview", bool(res.get("preview_data")))
    if res.get("log_name"):
        check("log dry_run", frappe.db.get_value("Integration Log", res["log_name"], "status") == "dry_run")
        frappe.delete_doc("Integration Log", res["log_name"], force=True, ignore_permissions=True)

    # kill switch — always assert disabled blocks push
    _set_integration_enabled(0)
    r_off = integration_service.push_to_external(
        "External System", "Sepidar", "Sepidar", "push_cost", dry_run=True,
    )
    check("kill switch blocks push when disabled",
          r_off.get("status") == "feature_disabled", str(r_off.get("status")))
    if r_off.get("log_name"):
        frappe.delete_doc("Integration Log", r_off["log_name"], force=True, ignore_permissions=True)

    # Re-enable for remaining capability tests (NOT old_enabled — that is often 0 by default).
    # Restoring old_enabled here masked "not_implemented" as "feature_disabled".
    _set_integration_enabled(1)

    # duplicate via controlled log (test fixture only — ignore_links for non-existent Dynamic Link target)
    log_doc = frappe.new_doc("Integration Log")
    log_doc.reference_doctype = "Transport Case"
    log_doc.reference_name = "TEST-DUP-001"
    log_doc.external_system = "Sepidar"
    log_doc.action = "push_cost"
    log_doc.status = "success"
    log_doc.sent_at = frappe.utils.now_datetime()
    log_doc.flags.ignore_permissions = True
    log_doc.flags.ignore_links = True
    log_doc.insert(ignore_permissions=True)
    check("dup same action", integration_service._prevent_duplicate("Transport Case", "TEST-DUP-001", "Sepidar", "push_cost") is True)
    check("dup other action", integration_service._prevent_duplicate("Transport Case", "TEST-DUP-001", "Sepidar", "push_invoice") is False)
    frappe.delete_doc("Integration Log", log_doc.name, ignore_permissions=True, force=True)

    ad = get_adapter("sepidar", {"dry_run": 1})
    check("no recon capability", ad.supports("reconciliation") is False)
    r2 = integration_service.push_to_external("External System", "Sepidar", "Sepidar", "reconcile", dry_run=True)
    check("unsupported -> not_implemented", r2.get("status") == "not_implemented", str(r2.get("status")))
    if r2.get("log_name"):
        check("log not_implemented", frappe.db.get_value("Integration Log", r2["log_name"], "status") == "not_implemented")
        frappe.delete_doc("Integration Log", r2["log_name"], force=True, ignore_permissions=True)

    from ir_integration.ir_integration.setup.setup_workspace import setup_finance_workspace_links
    setup_finance_workspace_links()
    setup_finance_workspace_links()
    # count Integration Log links on finance if found
    from ir_integration.ir_integration.setup.setup_workspace import FINANCE_CANDIDATES
    fin = next((c for c in FINANCE_CANDIDATES if frappe.db.exists("Workspace", c)), None)
    if fin:
        n = frappe.db.count("Workspace Link", {"parent": fin, "link_to": "Integration Log"})
        check("workspace links idempotent", n == 1, str(n))
    else:
        soft("finance workspace", False, "not found")

    from ir_integration.ir_integration.dashboard.financial_dashboard import get_dashboard_data
    check("dashboard data", "systems" in get_dashboard_data())

    # Source-only scan (exclude this verifier) — avoids false positives from grep/subprocess
    ban_site = "transport-dev.local"
    ban_patterns = ("bench console", "exec(open")
    skip_names = {"verify_phase10.py"}
    skip_dirs = {".git", "__pycache__", "node_modules", ".eggs"}
    src_hits_site, src_hits_exec = [], []
    root = pathlib.Path(APP_ROOT)
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if any(part in skip_dirs or part.endswith(".egg-info") for part in path.parts):
            continue
        if path.name in skip_names:
            continue
        if path.suffix.lower() not in {".py", ".js", ".json", ".md", ".txt", ".toml"}:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        rel = str(path.relative_to(root))
        if ban_site in text:
            src_hits_site.append(rel)
        for pat in ban_patterns:
            if pat in text:
                src_hits_exec.append(f"{rel}:{pat}")
                break
    check("no site name in app", not src_hits_site, ", ".join(src_hits_site[:5]))
    check("no console/exec", not src_hits_exec, ", ".join(src_hits_exec[:5]))

    hooks = frappe.get_hooks("required_apps", app_name="ir_integration") or []
    flat = []
    for i in hooks:
        flat.extend(i if isinstance(i, (list, tuple)) else [i])
    check("required transport_ir", "transport_ir" in flat)

    # Restore true original feature flag (often 0) only after all functional probes
    _set_integration_enabled(old_enabled)

    frappe.db.commit()
    print("=" * 60)
    print(f"Passed {len(passed)} Failed {len(failed)} Warn {len(warned)}")
    if failed:
        raise Exception(f"{len(failed)} failures")
    print("Phase 10 all checks passed!")
    return {"passed": len(passed), "failed": len(failed), "warnings": len(warned)}
PY

# -----------------------------------------------------------------------------
step "9. Syntax sweep then install (apps.txt newline-safe)"
# -----------------------------------------------------------------------------
while IFS= read -r -d '' f; do validate_py "$f"; done < <(find "$APP_DIR" -name "*.py" -print0)
while IFS= read -r -d '' f; do validate_json "$f"; done < <(find "$APP_DIR" -name "*.json" -print0)
validate_fixture_names
info "syntax ok"

cd "$BENCH_DIR"
"$PYBIN" -m pip install -q -e "$APP_DIR" || err "pip failed"
APPS_TXT="${BENCH_DIR}/sites/apps.txt"
if [[ -f "$APPS_TXT" ]]; then
  if ! grep -qx "$APP" "$APPS_TXT"; then
    if [[ -s "$APPS_TXT" ]] && [[ "$(tail -c 1 "$APPS_TXT" | wc -l)" -eq 0 ]]; then
      printf "\n" >> "$APPS_TXT"
    fi
    printf "%s\n" "$APP" >> "$APPS_TXT"
  fi
else
  printf "%s\n" "$APP" > "$APPS_TXT"
fi
"$PYBIN" - "$APPS_TXT" <<'EOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
lines = [l.strip() for l in p.read_text(encoding="utf-8").splitlines() if l.strip()]
out, seen = [], set()
for l in lines:
    if l not in seen:
        seen.add(l); out.append(l)
p.write_text("\n".join(out) + "\n", encoding="utf-8")
EOF

if ! site_has_app "$SITE_NAME" "$APP"; then
  bench --site "$SITE_NAME" install-app "$APP" || err "install-app failed"
fi
bench --site "$SITE_NAME" migrate || err "migrate failed"
# Live repair: force ASCII workspace identity + purge Persian route dupes
bench --site "$SITE_NAME" execute ir_integration.ir_integration.setup.workspace_normalize.normalize_workspace \
  || warn "workspace_normalize failed — sidebar route may 404 until fixed"
bench build --app "$APP" >/dev/null 2>&1 || warn "bench build failed — JS assets may 404 until next full build"
bench --site "$SITE_NAME" clear-cache >/dev/null 2>&1 || true
bench --site "$SITE_NAME" execute ir_integration.ir_integration.verify_phase10.verify_phase10 \
  || err "verify failed"

cd "$APP_DIR"
[[ -d .git ]] || git init -q
[[ -f .gitignore ]] || printf '%s\n' "*.pyc" "__pycache__/" "*.egg-info/" > .gitignore
git add -A
git diff --cached --quiet || git commit -q -m "$COMMIT_MSG"
info "Phase 10A complete — hooks only in ir_integration; other apps untouched"