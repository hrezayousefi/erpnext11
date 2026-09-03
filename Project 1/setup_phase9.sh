#!/usr/bin/env bash
# =============================================================================
#  PHASE 9 — IR_GATEWAY : SMS / SLA / ALERT SYSTEM
#  Iran Transport ERP  •  ERPNext v15 / Frappe v15
#
#  Plugin/adapter architecture. Idempotent. File-first.
#  No bench console. No exec(open(...)). No is_scheduler_active().
#
#  ---------------------------------------------------------------------------
#  PATCHED (fidelity-preserving). Only the error-causing lines were changed:
#
#   FIX-1  fixture tracebacks during `bench install-app`
#          ("No module named 'frappe.core.doctype.sms_template'", …)
#          Frappe runs sync_fixtures() while the app tables do not exist yet.
#          -> fixtures are stashed away ONLY during install-app and restored
#             immediately after, so `bench migrate` (which creates the tables
#             first) imports exactly the same files, just a few seconds later.
#
#   FIX-2  ModuleNotFoundError: No module named 'ir_gateway' in the browser
#          The web/worker processes were started BEFORE `pip install -e`,
#          so their sys.path never learned about the new app.
#          -> python-import sanity check + .pth fallback + restart of the
#             bench services + HTTP smoke test.
#
#   (cosmetic) color codes now use $'\033[…' so the final banner prints real
#              colors instead of the literal text \033[1m
#  ---------------------------------------------------------------------------
# =============================================================================
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=utf-8

# ----------------------------------------------------------------------------- CONFIG
SITE_NAME="transport-dev.local"
BENCH_DIR="${HOME}/frappe-bench"
APP="ir_gateway"
APP_DIR="${BENCH_DIR}/apps/${APP}"
PKG="${APP_DIR}/${APP}"                 # python package  apps/ir_gateway/ir_gateway
MOD="${PKG}/ir_gateway"                 # module          .../ir_gateway/ir_gateway
DT="${MOD}/doctype"
SMS="${MOD}/sms"
SLA="${MOD}/sla"
ALERTS="${MOD}/alerts"
API="${MOD}/api"
WS="${MOD}/workspace/ir_gateway"        # CORRECT nested workspace path
FIXTURES="${PKG}/fixtures"
FIXTURES_STASH="/tmp/ir_gateway_fixtures_stash"   # FIX-1 (temporary, outside the app)
COMMIT_MSG="phase 9: ir_gateway SMS/SLA/Alert system with plugin adapter architecture"

# ----------------------------------------------------------------------------- COLORS / LOG
C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;34m'
C_BOLD=$'\033[1m'; C_N=$'\033[0m'; C_NC=$'\033[0m'; C_GREEN="$C_G"
log()  { echo -e "${C_G}[OK]${C_N}   $*"; }
info() { echo -e "${C_B}[..]${C_N}   $*"; }
warn() { echo -e "${C_Y}[WARN]${C_N} $*"; }
err()  { echo -e "${C_R}[FAIL]${C_N} $*"; exit 1; }
step() {
  echo -e "\n${C_B}==============================================================${C_N}"
  echo -e "${C_B}  $*${C_N}"
  echo -e "${C_B}==============================================================${C_N}"
}

write_utf8() {
  local p="$1"
  mkdir -p "$(dirname "$p")"
  cat > "$p"
}

ensure_init() {
  mkdir -p "$1"
  if [[ ! -f "$1/__init__.py" ]]; then
    printf '%s\n' "${2:-}" > "$1/__init__.py"
  fi
}

validate_py() {
  local f="$1"
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$f" \
    || err "Python syntax error in ${f}"
}

site_has_app() {
  bench --site "$1" list-apps 2>/dev/null | awk '{print $1}' | grep -qx "$2"
}

# ----------------------------------------------------------------------------- FIX-1 helpers
# Hide the fixture JSON files while `bench install-app` runs, then put them
# back. Nothing is deleted — the very same files are imported by `bench migrate`
# in STEP 24, AFTER the DocTypes/tables exist.
stash_fixtures() {
  mkdir -p "$FIXTURES_STASH"
  local moved=0
  shopt -s nullglob
  local f
  for f in "${FIXTURES}"/*.json; do
    mv -f "$f" "${FIXTURES_STASH}/"
    moved=1
  done
  shopt -u nullglob
  if [[ "$moved" -eq 1 ]]; then
    info "fixtures temporarily stashed -> ${FIXTURES_STASH}"
  fi
  return 0
}

restore_fixtures() {
  mkdir -p "$FIXTURES"
  shopt -s nullglob
  local f
  for f in "${FIXTURES_STASH}"/*.json; do
    mv -f "$f" "${FIXTURES}/"
  done
  shopt -u nullglob
  rmdir "$FIXTURES_STASH" 2>/dev/null || true
  return 0
}

# ----------------------------------------------------------------------------- FIX-2 helpers
wait_for_redis_site() {
  local tries="${1:-45}"
  local i
  for i in $(seq 1 "$tries"); do
    if redis-cli -p 13000 ping >/dev/null 2>&1 \
      || redis-cli -p 11000 ping >/dev/null 2>&1 \
      || redis-cli ping >/dev/null 2>&1 \
      || bench --site "$SITE_NAME" execute frappe.ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

restart_bench_services() {
  if command -v supervisorctl >/dev/null 2>&1 && supervisorctl status >/dev/null 2>&1; then
    info "supervisor detected — using 'bench restart'"
    bench restart >>/tmp/bench-restart-phase9.log 2>&1 || warn "bench restart returned non-zero"
    return 0
  fi

  info "stopping dev bench processes (stale sys.path) ..."
  pkill -f "honcho start"                >/dev/null 2>&1 || true
  pkill -f "bench start"                 >/dev/null 2>&1 || true
  pkill -f "bench serve"                 >/dev/null 2>&1 || true
  pkill -f "frappe serve"                >/dev/null 2>&1 || true
  pkill -f "frappe worker"               >/dev/null 2>&1 || true
  pkill -f "frappe schedule"             >/dev/null 2>&1 || true
  pkill -f "socketio.js"                 >/dev/null 2>&1 || true
  pkill -f "redis-server .*:11000"       >/dev/null 2>&1 || true
  pkill -f "redis-server .*:12000"       >/dev/null 2>&1 || true
  pkill -f "redis-server .*:13000"       >/dev/null 2>&1 || true
  sleep 3

  info "starting bench services again (nohup) ..."
  cd "$BENCH_DIR"
  nohup bench start >>/tmp/bench-start-phase9.log 2>&1 &
  log "bench start pid=$!  log=/tmp/bench-start-phase9.log"
  return 0
}

# =============================================================================
step "STEP 0 — PREFLIGHT"
# =============================================================================
[[ -d "$BENCH_DIR" ]] || err "Bench directory not found: ${BENCH_DIR}"
cd "$BENCH_DIR"
# -----------------------------------------------------------------------------
# Ensure bench services (redis) BEFORE any migrate / install-app / execute
# -----------------------------------------------------------------------------
if ss -lntp 2>/dev/null | grep -qE ':(8000|11000|13000)\b' \
  || pgrep -af 'bench start|honcho|frappe serve' 2>/dev/null | grep -vq grep; then
  log "bench services already running"
else
  info "starting bench services (nohup) ..."
  nohup bench start >>/tmp/bench-start-phase9.log 2>&1 &
  log "bench start pid=$!  log=/tmp/bench-start-phase9.log"
fi

info "waiting for redis / site ..."
REDIS_READY=0
for _i in $(seq 1 45); do
  if redis-cli -p 13000 ping >/dev/null 2>&1 \
    || redis-cli -p 11000 ping >/dev/null 2>&1 \
    || redis-cli ping >/dev/null 2>&1 \
    || bench --site "$SITE_NAME" execute frappe.ping >/dev/null 2>&1; then
    REDIS_READY=1
    break
  fi
  sleep 1
done
[[ "$REDIS_READY" -eq 1 ]] || err "Redis/site not ready after 45s. See /tmp/bench-start-phase9.log and run: cd ~/frappe-bench && bench start"
log "redis/site ready"
[[ -d "${BENCH_DIR}/sites/${SITE_NAME}" ]] || err "Site not found: ${SITE_NAME}"
log "bench=${BENCH_DIR}  site=${SITE_NAME}"

info "waiting for site / redis ..."
for _i in $(seq 1 20); do
  if bench --site "$SITE_NAME" execute frappe.ping >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

for required_app in frappe erpnext ir_base transport_ir ir_jalali; do
  if site_has_app "$SITE_NAME" "$required_app"; then
    log "required app present: ${required_app}"
  else
    err "Required app '${required_app}' is NOT installed on ${SITE_NAME}."
  fi
done

TC_COUNT="$(bench --site "$SITE_NAME" execute frappe.db.count \
  --args '["DocType", {"name": "Transport Case"}]' 2>/dev/null | tail -1 | tr -d '[:space:]' || echo 0)"
[[ "$TC_COUNT" == "1" ]] || err "Transport Case DocType missing — run phase 6 first"
log "Transport Case DocType found"

# CRITICAL: Frappe v15 has is_scheduler_inactive() ONLY
SCHEDULER_STATUS="$(bench --site "$SITE_NAME" execute \
  frappe.utils.scheduler.is_scheduler_inactive 2>/dev/null | tail -1 | tr -d '[:space:]' || echo unknown)"
if [[ "$SCHEDULER_STATUS" == "True" ]]; then
  warn "Scheduler is INACTIVE — SLA + daily report will NOT run"
  warn "Run: bench --site ${SITE_NAME} enable-scheduler"
else
  log "Scheduler check OK (is_scheduler_inactive -> ${SCHEDULER_STATUS})"
fi

# =============================================================================
step "STEP 1 — SCAFFOLD APP + METADATA"
# =============================================================================
mkdir -p "$APP_DIR"
ensure_init "$PKG" '__version__ = "1.0.0"'
# force version line even if __init__ already existed
if ! grep -q '__version__' "${PKG}/__init__.py" 2>/dev/null; then
  printf '%s\n' '__version__ = "1.0.0"' >> "${PKG}/__init__.py"
fi
printf '%s\n' 'IR Gateway' > "${PKG}/modules.txt"
: > "${PKG}/patches.txt"

write_utf8 "${APP_DIR}/requirements.txt" <<'EOF'
requests>=2.28
EOF

write_utf8 "${APP_DIR}/pyproject.toml" <<'EOF'
[project]
name = "ir_gateway"
authors = [{ name = "IR Base Contributors", email = "dev@example.com" }]
description = "SMS/SLA/Alert notification gateway for Iran Transport ERP"
requires-python = ">=3.10"
readme = "README.md"
dynamic = ["version"]
dependencies = ["requests>=2.28"]

[build-system]
requires = ["flit_core >=3.4,<4"]
build-backend = "flit_core.buildapi"

[tool.flit.module]
name = "ir_gateway"
EOF

write_utf8 "${APP_DIR}/setup.py" <<'EOF'
from setuptools import find_packages, setup

setup(
    name="ir_gateway",
    version="1.0.0",
    description="SMS/SLA/Alert notification gateway for Iran Transport ERP",
    author="IR Base Contributors",
    author_email="dev@example.com",
    packages=find_packages(),
    zip_safe=False,
    include_package_data=True,
    install_requires=["requests>=2.28"],
)
EOF

write_utf8 "${APP_DIR}/MANIFEST.in" <<'EOF'
include MANIFEST.in
include requirements.txt
include *.md
include *.txt
recursive-include ir_gateway *.py
recursive-include ir_gateway *.json
recursive-include ir_gateway *.js
recursive-include ir_gateway *.md
recursive-include ir_gateway *.txt
recursive-include ir_gateway *.csv
EOF

write_utf8 "${APP_DIR}/license.txt" <<'EOF'
MIT License
Copyright (c) IR Base Contributors
EOF

write_utf8 "${APP_DIR}/README.md" <<'EOF'
# IR Gateway

SMS / SLA / Alert layer for Iran Transport ERP (Phase 9).

## Architecture

WordPress-like plugin adapters:

1. Drop a file in `ir_gateway/ir_gateway/sms/adapters/`
2. Subclass `BaseSMSAdapter`, set `adapter_id`, decorate with `@register_adapter`
3. It appears in **SMS Gateway Settings** — no core change

**All SMS goes through `sms_service.send_sms()`.** Never call an adapter or `requests` from business code.

## Rules

- Test mode defaults ON (`[TEST→original]` prefix)
- Duplicate: same doc + event + recipient within 1 hour is skipped
  (SLA breached/critical are exempt)
- Never break Transport Case save
- Use `frappe.utils.scheduler.is_scheduler_inactive()` — `is_scheduler_active()` does not exist
- No WhatsApp. Ever.
EOF

write_utf8 "${APP_DIR}/BACKLOG.md" <<'EOF'
# IR Gateway Backlog (DO NOT build now)

- [ ] Email adapter (same contract, channel = Email)
- [ ] Telegram adapter
- [ ] More SMS providers (sms.ir, melipayamak, farapayamak, ghasedak)
- [ ] Delivery-status webhook
- [ ] Rate limiting / anti-flood
- [ ] Scheduled (future-dated) SMS
- [ ] Per-user notification preferences
- [x] ~~WhatsApp~~ PERMANENTLY EXCLUDED
EOF

write_utf8 "${APP_DIR}/DEVELOPMENT_RULES.md" <<'EOF'
# Development Rules

1. All SMS sends go through `sms_service.send_sms()` only.
2. No hardcoded API keys, phones, or provider URLs.
3. Do not modify `transport_ir` or `ir_base` source.
4. Use `frappe.utils.scheduler.is_scheduler_inactive()` — never `is_scheduler_active()`.
5. Test mode defaults ON.
6. Persian labels, English fieldnames.
7. File-first; no bench console hacks.
8. Never break the host document (Transport Case).
9. Idempotent: safe to re-run.
EOF

log "App metadata written"

# =============================================================================
step "STEP 2 — DIRECTORY STRUCTURE"
# =============================================================================
ensure_init "$MOD" '"""IR Gateway module."""'
ensure_init "$DT"
ensure_init "$SMS" '"""SMS adapter layer (plugin architecture)."""'
ensure_init "${SMS}/adapters" '"""Bundled SMS provider plugins."""'
ensure_init "$SLA" '"""SLA monitoring + escalation."""'
ensure_init "$ALERTS" '"""Alert dispatch, templates, daily report."""'
ensure_init "$API" '"""Whitelisted API endpoints."""'
ensure_init "${PKG}/templates"
ensure_init "${MOD}/workspace"
ensure_init "$WS"
mkdir -p "${PKG}/public/js" "$FIXTURES"

for d in \
  sms_gateway_settings sms_template sms_alert_log \
  sla_stage_config alert_escalation_rule notification_history \
  alert_escalation_role alert_escalation_user
do
  ensure_init "${DT}/${d}"
done

# Future channel stubs (not implemented)
ensure_init "${MOD}/channels" '"""Future notification channels (Telegram / Email)."""'
ensure_init "${MOD}/channels/sms"
ensure_init "${MOD}/channels/telegram"
ensure_init "${MOD}/channels/email"

write_utf8 "${MOD}/channels/base_channel.py" <<'PY'
"""Abstract base for future notification channels (SMS / Telegram / Email).

Phase 9 only activates SMS via sms_service. These stubs document the slot.
"""

from __future__ import annotations

from abc import ABC, abstractmethod


class BaseChannel(ABC):
    channel_type: str = ""
    channel_name: str = ""

    @abstractmethod
    def send(self, to: str, message: str, context: dict | None = None) -> dict:
        raise NotImplementedError

    @abstractmethod
    def is_configured(self) -> bool:
        raise NotImplementedError
PY
validate_py "${MOD}/channels/base_channel.py"

write_utf8 "${MOD}/channels/telegram/base_adapter.py" <<'PY'
"""Stub for a future Telegram adapter. Do not implement a live bot here."""

from __future__ import annotations

from abc import ABC, abstractmethod


class BaseTelegramAdapter(ABC):
    adapter_id: str = ""
    adapter_name: str = ""

    @abstractmethod
    def send_message(self, chat_id: str, text: str) -> dict:
        raise NotImplementedError

    @classmethod
    def get_config_schema(cls) -> list[dict]:
        return [
            {"fieldname": "bot_token", "label": "Bot Token", "fieldtype": "Password", "reqd": 1},
        ]
PY
validate_py "${MOD}/channels/telegram/base_adapter.py"

write_utf8 "${MOD}/channels/email/base_adapter.py" <<'PY'
"""Stub for a future Email adapter. Do not send email in Phase 9."""

from __future__ import annotations

from abc import ABC, abstractmethod


class BaseEmailAdapter(ABC):
    adapter_id: str = ""

    @abstractmethod
    def send_email(self, to_email: str, subject: str, body: str) -> dict:
        raise NotImplementedError
PY
validate_py "${MOD}/channels/email/base_adapter.py"

log "Directories + channel stubs created"

mkdir -p "${PKG}/translations"

write_utf8 "${PKG}/translations/fa.csv" <<'EOF'
SMS Gateway Settings,تنظیمات درگاه پیامک,
SMS Template,قالب پیامک,
SMS Alert Log,لاگ هشدار پیامک,
SLA Stage Config,پیکربندی مهلت مراحل,
Alert Escalation Rule,قانون تشدید هشدار,
Notification History,تاریخچه اعلان‌ها,
Alert Escalation Role,نقش تشدید هشدار,
Alert Escalation User,کاربر تشدید هشدار,
IR Gateway,درگاه پیامک و هشدار,
SMS Management,مدیریت پیامک,
SLA & Alerts,مهلت‌ها و هشدارها,
generic_http,HTTP عمومی,
kavenegar,کاوه‌نگار,
SMS,پیامک,
Email,ایمیل,
Internal,داخلی,
Both,هر دو,
Low,کم,
Normal,عادی,
High,بالا,
Critical,بحرانی,
fa,فارسی,
en,انگلیسی,
pending,در انتظار,
sent,ارسال‌شده,
failed,ناموفق,
queued,در صف,
driver_assigned,تخصیص راننده,
waybill_issued,صدور بارنامه,
weighbridge_recorded,ثبت باسکول,
bijak_required,نیاز به بیجک,
bijak_completed,تکمیل بیجک,
clearance_started,شروع ترخیص,
clearance_completed,اتمام ترخیص,
delivery_completed,تحویل انجام شد,
payment_due,سررسید پرداخت,
case_completed,بستن پرونده,
sla_warning,هشدار مهلت,
sla_breached,نقض مهلت,
sla_critical,مهلت بحرانی,
daily_report,گزارش روزانه,
custom,سفارشی,
Test Connection,تست اتصال,
Send Test SMS,ارسال پیامک آزمایشی,
No adapter configured (or SMS system disabled),ارائه‌دهنده‌ای پیکربندی نشده یا سیستم پیامک غیرفعال است,
SMS system is disabled,سیستم پیامک غیرفعال است,
No recipient,گیرنده مشخص نشده است,
Duplicate: same alert already sent,تکراری: این هشدار قبلاً ارسال شده,
No SMS adapter configured,ارائه‌دهنده پیامک تنظیم نشده است,
Test mode enabled but no test number set,حالت آزمایشی روشن است ولی شماره آزمایشی خالی است,
Enabled,فعال,
Disabled,غیرفعال,
Save,ذخیره,
Edit,ویرایش,
New,جدید,
Delete,حذف,
Filter,فیلتر,
List,فهرست,
Report,گزارش,
Settings,تنظیمات,
EOF
log "fa.csv translations written"

# =============================================================================
step "STEP 3 — base_adapter.py  (ABC + decorator proxy, no circular import)"
# =============================================================================
write_utf8 "${SMS}/base_adapter.py" <<'PY'
"""Abstract SMS adapter contract.

Adapters import `register_adapter` from THIS module (simple for plugin authors).
The decorator is a lazy proxy to adapter_registry — no circular import.
"""

from __future__ import annotations

from abc import ABC, abstractmethod


class BaseSMSAdapter(ABC):
    adapter_id: str = ""
    adapter_name: str = ""
    adapter_version: str = "1.0.0"

    def __init__(self, settings: dict):
        self.settings = settings or {}

    @classmethod
    @abstractmethod
    def get_config_fields(cls) -> list[dict]:
        raise NotImplementedError

    @abstractmethod
    def send_sms(self, to: str, message: str) -> dict:
        """Return {success, message_id, status, error, raw_response}."""
        raise NotImplementedError

    def send_bulk_sms(self, recipients: list[str], message: str) -> list[dict]:
        return [self.send_sms(to, message) for to in recipients]

    def get_balance(self) -> dict | None:
        return None

    def validate_config(self) -> tuple[bool, str]:
        missing = []
        for field in self.get_config_fields():
            if field.get("reqd") and not self.settings.get(field["fieldname"]):
                missing.append(field.get("label") or field["fieldname"])
        if missing:
            return False, "Missing: {0}".format(", ".join(missing))
        return True, "OK"

    @abstractmethod
    def test_connection(self) -> tuple[bool, str]:
        raise NotImplementedError


def register_adapter(adapter_class):
    """Lazy proxy — keeps plugin files importing from one obvious place."""
    from ir_gateway.ir_gateway.sms.adapter_registry import register_adapter as _register

    return _register(adapter_class)
PY
validate_py "${SMS}/base_adapter.py"

# =============================================================================
step "STEP 4 — adapter_registry.py  (owns the registry)"
# =============================================================================
write_utf8 "${SMS}/adapter_registry.py" <<'PY'
"""Adapter registry + filesystem discovery. Does NOT import BaseSMSAdapter."""

from __future__ import annotations

import importlib
import os

import frappe

_ADAPTER_REGISTRY: dict[str, type] = {}
_DISCOVERED = False


def register_adapter(adapter_class):
    adapter_id = getattr(adapter_class, "adapter_id", None)
    if not adapter_id:
        raise ValueError("{0} must define adapter_id".format(adapter_class))
    _ADAPTER_REGISTRY[adapter_id] = adapter_class
    return adapter_class


def discover_adapters(force: bool = False):
    global _DISCOVERED
    if _DISCOVERED and not force:
        return

    adapters_dir = os.path.join(os.path.dirname(__file__), "adapters")
    if not os.path.isdir(adapters_dir):
        _DISCOVERED = True
        return

    for filename in sorted(os.listdir(adapters_dir)):
        if not filename.endswith(".py") or filename == "__init__.py":
            continue
        module_name = filename[:-3]
        try:
            importlib.import_module(
                "ir_gateway.ir_gateway.sms.adapters.{0}".format(module_name)
            )
        except Exception as e:
            try:
                frappe.log_error(
                    title="ir_gateway adapter discovery",
                    message="Failed to load SMS adapter {0}: {1}".format(module_name, e),
                )
            except Exception:
                pass
    _DISCOVERED = True


def get_adapter(adapter_id: str, settings: dict):
    if adapter_id not in _ADAPTER_REGISTRY:
        discover_adapters()
    if adapter_id not in _ADAPTER_REGISTRY:
        frappe.throw("SMS adapter '{0}' not found".format(adapter_id))
    return _ADAPTER_REGISTRY[adapter_id](settings)


def list_adapters() -> list[dict]:
    discover_adapters()
    out = []
    for cls in sorted(_ADAPTER_REGISTRY.values(), key=lambda c: c.adapter_id):
        try:
            fields = cls.get_config_fields()
        except Exception:
            fields = []
        out.append({
            "adapter_id": cls.adapter_id,
            "adapter_name": cls.adapter_name,
            "adapter_version": cls.adapter_version,
            "config_fields": fields,
        })
    return out
PY
validate_py "${SMS}/adapter_registry.py"

write_utf8 "${SMS}/adapters/__init__.py" <<'PY'
"""Bundled SMS adapters. Discovery is triggered by adapter_registry.discover_adapters()."""
PY

# =============================================================================
step "STEP 5 — generic_http.py"
# =============================================================================
write_utf8 "${SMS}/adapters/generic_http.py" <<'PY'
"""Generic HTTP POST adapter — works with most Iranian SMS panels."""

from __future__ import annotations

import requests

from ir_gateway.ir_gateway.sms.base_adapter import BaseSMSAdapter, register_adapter


@register_adapter
class GenericHTTPAdapter(BaseSMSAdapter):
    adapter_id = "generic_http"
    adapter_name = "Generic HTTP POST"
    adapter_version = "1.0.0"

    @classmethod
    def get_config_fields(cls) -> list[dict]:
        return [
            {
                "fieldname": "api_url",
                "label": "آدرس API",
                "fieldtype": "Data",
                "reqd": 1,
                "description": "POST endpoint, e.g. https://panel.example.com/api/send",
            },
            {
                "fieldname": "api_key",
                "label": "کلید API",
                "fieldtype": "Password",
                "reqd": 1,
                "description": "API key / bearer token",
            },
            {
                "fieldname": "sender_number",
                "label": "شماره فرستنده",
                "fieldtype": "Data",
                "reqd": 0,
                "description": "Sender / line number",
            },
            {
                "fieldname": "request_timeout",
                "label": "زمان انتظار (ثانیه)",
                "fieldtype": "Int",
                "reqd": 0,
                "description": "HTTP timeout. Default: 30",
            },
        ]

    def send_sms(self, to: str, message: str) -> dict:
        url = self.settings.get("api_url")
        api_key = self.settings.get("api_key")
        sender = self.settings.get("sender_number") or ""
        timeout = int(self.settings.get("request_timeout") or 30)

        if not url:
            return {"success": False, "message_id": None, "status": "failed",
                    "error": "No API URL configured", "raw_response": {}}

        headers = {"Content-Type": "application/json"}
        if api_key:
            headers["Authorization"] = "Bearer {0}".format(api_key)

        payload = {"to": to, "message": message}
        if sender:
            payload["sender"] = sender

        try:
            response = requests.post(url, json=payload, headers=headers, timeout=timeout)
            try:
                data = response.json()
            except Exception:
                data = {"raw": response.text}

            success = response.status_code in (200, 201, 202)
            message_id = None
            if isinstance(data, dict):
                message_id = data.get("message_id") or data.get("id")
            return {
                "success": success,
                "message_id": message_id,
                "status": "sent" if success else "failed",
                "error": None if success else "HTTP {0}: {1}".format(
                    response.status_code, (response.text or "")[:200]
                ),
                "raw_response": data,
            }
        except requests.exceptions.Timeout:
            return {"success": False, "message_id": None, "status": "failed",
                    "error": "Request timeout", "raw_response": {}}
        except requests.exceptions.ConnectionError:
            return {"success": False, "message_id": None, "status": "failed",
                    "error": "Connection error", "raw_response": {}}
        except Exception as e:
            return {"success": False, "message_id": None, "status": "failed",
                    "error": str(e), "raw_response": {}}

    def test_connection(self) -> tuple[bool, str]:
        url = self.settings.get("api_url")
        if not url:
            return False, "No API URL configured"
        try:
            response = requests.head(url, timeout=10)
            return True, "Connection OK (HTTP {0})".format(response.status_code)
        except requests.exceptions.ConnectionError:
            return False, "Cannot reach API URL"
        except Exception as e:
            return False, "Error: {0}".format(e)
PY
validate_py "${SMS}/adapters/generic_http.py"

# =============================================================================
step "STEP 6 — kavenegar.py"
# =============================================================================
write_utf8 "${SMS}/adapters/kavenegar.py" <<'PY'
"""Kavenegar adapter — example of a provider-specific plugin."""

from __future__ import annotations

import requests

from ir_gateway.ir_gateway.sms.base_adapter import BaseSMSAdapter, register_adapter


@register_adapter
class KavenegarAdapter(BaseSMSAdapter):
    adapter_id = "kavenegar"
    adapter_name = "Kavenegar"
    adapter_version = "1.0.0"
    BASE_URL = "https://api.kavenegar.com/v1"

    @classmethod
    def get_config_fields(cls) -> list[dict]:
        return [
            {
                "fieldname": "api_key",
                "label": "کلید API کاوه‌نگار",
                "fieldtype": "Password",
                "reqd": 1,
                "description": "From https://panel.kavenegar.com",
            },
            {
                "fieldname": "sender_number",
                "label": "شماره فرستنده",
                "fieldtype": "Data",
                "reqd": 1,
                "description": "Kavenegar sender line (e.g. 1000505)",
            },
        ]

    def send_sms(self, to: str, message: str) -> dict:
        api_key = self.settings.get("api_key")
        sender = self.settings.get("sender_number")
        timeout = int(self.settings.get("request_timeout") or 30)

        if not api_key:
            return {"success": False, "message_id": None, "status": "failed",
                    "error": "No Kavenegar API key", "raw_response": {}}

        url = "{0}/{1}/sms/send.json".format(self.BASE_URL, api_key)
        params = {"receptor": to, "message": message}
        if sender:
            params["sender"] = sender

        try:
            response = requests.post(url, data=params, timeout=timeout)
            data = response.json()
            if (data.get("return") or {}).get("status") == 200:
                entries = data.get("entries") or []
                message_id = entries[0].get("messageid") if entries else None
                return {
                    "success": True,
                    "message_id": str(message_id) if message_id is not None else None,
                    "status": "sent",
                    "error": None,
                    "raw_response": data,
                }
            return {
                "success": False,
                "message_id": None,
                "status": "failed",
                "error": (data.get("return") or {}).get("message", "Unknown error"),
                "raw_response": data,
            }
        except Exception as e:
            return {"success": False, "message_id": None, "status": "failed",
                    "error": str(e), "raw_response": {}}

    def get_balance(self) -> dict | None:
        api_key = self.settings.get("api_key")
        if not api_key:
            return None
        url = "{0}/{1}/account/info.json".format(self.BASE_URL, api_key)
        try:
            response = requests.get(url, timeout=10)
            data = response.json()
            entries = data.get("entries") or {}
            balance = entries.get("remaincredit")
            if balance is None:
                balance = entries.get("balance")
            if balance is not None:
                return {"balance": balance, "currency": "IRR", "unit": "credit"}
        except Exception:
            pass
        return None

    def test_connection(self) -> tuple[bool, str]:
        balance = self.get_balance()
        if balance:
            return True, "Connection OK. Balance: {0}".format(balance["balance"])
        return False, "Cannot connect to Kavenegar API"
PY
validate_py "${SMS}/adapters/kavenegar.py"

# =============================================================================
step "STEP 7 — sms_service.py  (THE only SMS entry point + retry)"
# =============================================================================
write_utf8 "${SMS}/sms_service.py" <<'PY'
"""Central SMS service. ALL sends go through send_sms(). Never raises."""

from __future__ import annotations

import time

import frappe
from frappe.utils import now_datetime

from ir_gateway.ir_gateway.alerts.duplicate_guard import is_duplicate  # re-exported
from ir_gateway.ir_gateway.sms.adapter_registry import discover_adapters, get_adapter

__all__ = [
    "get_gateway_settings",
    "get_configured_adapter",
    "send_sms",
    "is_duplicate",
]


def get_gateway_settings():
    """Return the Single doc if the system is enabled, else None."""
    try:
        if not frappe.db.exists("DocType", "SMS Gateway Settings"):
            return None
        settings = frappe.get_single("SMS Gateway Settings")
    except Exception:
        return None
    if not settings or not settings.enabled:
        return None
    return settings


def get_configured_adapter():
    settings = get_gateway_settings()
    if not settings:
        return None, None

    discover_adapters()
    adapter_id = settings.adapter_id
    if not adapter_id:
        return None, None

    config = {
        "api_url": settings.api_url,
        "api_key": settings.get_password("api_key", raise_exception=False),
        "api_secret": settings.get_password("api_secret", raise_exception=False),
        "sender_number": settings.sender_number,
        "sender_name": settings.sender_name,
        "request_timeout": settings.request_timeout or 30,
        "max_retry": settings.max_retry or 2,
        "retry_delay_seconds": settings.retry_delay_seconds or 5,
    }
    try:
        adapter = get_adapter(adapter_id, config)
    except Exception as e:
        try:
            frappe.log_error(
                title="ir_gateway sms_service",
                message="Cannot load SMS adapter '{0}': {1}".format(adapter_id, e),
            )
        except Exception:
            pass
        return None, settings
    return adapter, settings


def send_sms(
    to: str,
    message: str,
    reference_doctype: str = None,
    reference_name: str = None,
    event_type: str = None,
    template_name: str = None,
    escalation_level: int = None,
    sla_stage: str = None,
    recipient_name: str = None,
    recipient_role: str = None,
    log_only: bool = False,
) -> dict:
    """THE function to call. Extra kwargs like recipient_name are first-class.

    Never raises — a notification failure must not break Transport Case save.
    """
    try:
        return _send_sms_impl(
            to=to,
            message=message,
            reference_doctype=reference_doctype,
            reference_name=reference_name,
            event_type=event_type,
            template_name=template_name,
            escalation_level=escalation_level,
            sla_stage=sla_stage,
            recipient_name=recipient_name,
            recipient_role=recipient_role,
            log_only=log_only,
        )
    except Exception as e:
        try:
            frappe.log_error(title="ir_gateway send_sms", message=str(e))
        except Exception:
            pass
        return {"success": False, "message_id": None, "error": str(e)}


def _send_sms_impl(
    to,
    message,
    reference_doctype,
    reference_name,
    event_type,
    template_name,
    escalation_level,
    sla_stage,
    recipient_name,
    recipient_role,
    log_only,
) -> dict:
    settings = get_gateway_settings()

    log_entry = {
        "reference_doctype": reference_doctype,
        "reference_name": reference_name,
        "event_type": event_type or "custom",
        "template_name": template_name,
        "recipient": to,
        "recipient_name": recipient_name,
        "recipient_role": recipient_role,
        "channel": "SMS",
        "message_text": message,
        "send_status": "pending",
        "escalation_level": escalation_level,
        "sla_stage": sla_stage,
        "retry_count": 0,
    }

    if not to:
        log_entry["send_status"] = "failed"
        log_entry["error_message"] = "No recipient"
        _create_alert_log(log_entry)
        return {"success": False, "message_id": None, "error": "No recipient"}

    if not settings:
        log_entry["send_status"] = "failed"
        log_entry["error_message"] = "SMS system is disabled"
        _create_alert_log(log_entry)
        return {"success": False, "message_id": None, "error": "SMS system disabled"}

    if settings.test_mode:
        if not settings.test_number:
            log_entry["send_status"] = "failed"
            log_entry["error_message"] = "Test mode enabled but no test number set"
            _create_alert_log(log_entry)
            return {"success": False, "message_id": None, "error": "No test number"}
        original_to = to
        to = settings.test_number
        log_entry["test_mode"] = 1
        log_entry["recipient"] = to
        log_entry["message_text"] = "[TEST→{0}] {1}".format(original_to, message)

    if event_type and reference_name:
        if is_duplicate(reference_doctype, reference_name, event_type, to):
            log_entry["send_status"] = "failed"
            log_entry["error_message"] = "Duplicate: same alert already sent"
            _create_alert_log(log_entry)
            return {"success": False, "message_id": None, "error": "Duplicate"}

    if log_only:
        log_entry["send_status"] = "queued"
        _create_alert_log(log_entry)
        return {"success": True, "message_id": None, "error": None}

    adapter, settings_cfg = get_configured_adapter()
    if not adapter:
        log_entry["send_status"] = "failed"
        log_entry["error_message"] = "No SMS adapter configured"
        _create_alert_log(log_entry)
        return {"success": False, "message_id": None, "error": "No adapter"}

    max_retry = int(getattr(settings_cfg, "max_retry", None) or 2)
    delay = int(getattr(settings_cfg, "retry_delay_seconds", None) or 5)
    payload = log_entry["message_text"] or message
    result = {"success": False, "error": "Unknown"}
    attempts = 0

    for attempt in range(max_retry + 1):
        attempts = attempt
        try:
            result = adapter.send_sms(to, payload) or {}
            if result.get("success"):
                break
        except Exception as e:
            result = {"success": False, "error": str(e), "raw_response": {}}
        if attempt < max_retry:
            time.sleep(max(0, delay))

    log_entry["retry_count"] = attempts
    log_entry["adapter_id"] = getattr(adapter, "adapter_id", None)
    log_entry["raw_response"] = str(result.get("raw_response", ""))[:2000]

    if result.get("success"):
        log_entry["send_status"] = "sent"
        log_entry["message_id"] = result.get("message_id")
        log_entry["error_message"] = None
        log_entry["sent_at"] = now_datetime()
    else:
        log_entry["send_status"] = "failed"
        log_entry["error_message"] = result.get("error")

    alert_log = _create_alert_log(log_entry)

    if reference_doctype and reference_name:
        _update_notification_history(reference_doctype, reference_name, log_entry, alert_log)

    return {
        "success": log_entry["send_status"] == "sent",
        "message_id": log_entry.get("message_id"),
        "error": log_entry.get("error_message"),
    }


def _create_alert_log(log_entry: dict):
    try:
        doc = frappe.new_doc("SMS Alert Log")
        for key, value in log_entry.items():
            if doc.meta.has_field(key):
                doc.set(key, value)
        doc.flags.ignore_permissions = True
        doc.flags.ignore_mandatory = True
        doc.insert(ignore_permissions=True)
        return doc
    except Exception as e:
        try:
            frappe.log_error(
                title="ir_gateway alert log creation failed",
                message=str(e),
            )
        except Exception:
            pass
        return None


def _update_notification_history(doctype, name, log_entry, alert_log):
    """Never raises. Works even if the host doc is submitted."""
    try:
        doc = frappe.get_doc(doctype, name)
        if not doc.meta.has_field("notification_history"):
            return
        doc.append("notification_history", {
            "sent_at": log_entry.get("sent_at") or now_datetime(),
            "event_type": log_entry.get("event_type"),
            "recipient": log_entry.get("recipient"),
            "recipient_name": log_entry.get("recipient_name"),
            "channel": log_entry.get("channel") or "SMS",
            "send_status": log_entry.get("send_status"),
            "message_summary": (log_entry.get("message_text") or "")[:100],
            "alert_log": alert_log.name if alert_log else None,
        })
        doc.flags.ignore_permissions = True
        doc.flags.ignore_mandatory = True
        doc.flags.ignore_validate_update_after_submit = True
        doc.save(ignore_permissions=True)
    except Exception:
        pass
PY
validate_py "${SMS}/sms_service.py"

# =============================================================================
step "STEP 8 — template_renderer.py"
# =============================================================================
write_utf8 "${ALERTS}/template_renderer.py" <<'PY'
"""{{ variable }} substitution + smart Link display resolution."""

from __future__ import annotations

import re

import frappe
from frappe.utils import flt

try:
    from ir_jalali.utils.jalali import format_jalali as _format_jalali
except Exception:
    _format_jalali = None


def format_jalali(value):
    if not value:
        return ""
    if _format_jalali:
        try:
            return _format_jalali(value)
        except Exception:
            pass
    try:
        return frappe.utils.formatdate(value)
    except Exception:
        return str(value)


def jalali_now():
    return format_jalali(frappe.utils.now_datetime().date())


def render_template(template_name: str, context: dict) -> str:
    if not template_name or not frappe.db.exists("SMS Template", template_name):
        return ""
    template_doc = frappe.get_doc("SMS Template", template_name)
    if not template_doc.is_active:
        return ""

    full_context = _build_common_context()
    full_context.update(context or {})

    def replace_var(match):
        value = full_context.get(match.group(1).strip(), "")
        return "" if value is None else str(value)

    return re.sub(r"\{\{\s*(\w+)\s*\}\}", replace_var, template_doc.template_text or "").strip()


def _build_common_context() -> dict:
    now = frappe.utils.now_datetime()
    return {
        "current_date": format_jalali(now.date()),
        "current_time": now.strftime("%H:%M"),
        "company_name": frappe.defaults.get_global_default("company") or "",
    }


def build_case_context(case_name: str) -> dict:
    if not case_name or not frappe.db.exists("Transport Case", case_name):
        return {}

    case = frappe.get_doc("Transport Case", case_name)

    def v(field, default=""):
        value = case.get(field)
        return default if value is None else value

    supplier_factory = v("supplier_factory") or v("supplier")

    return {
        "case_name": case.name,
        "case_title": v("case_title"),
        "case_type": v("case_type"),
        "workflow_state": v("workflow_state"),
        "posting_date": format_jalali(v("posting_date")) if v("posting_date") else "",
        "driver_name": v("driver_name"),
        "driver_mobile": v("driver_mobile"),
        "driver_national_id": v("driver_national_id"),
        "plate_number": v("plate_number"),
        "customer_name": _resolve_link_display("Customer", v("customer")),
        "supplier_name": _resolve_link_display("Supplier", supplier_factory),
        "item_name": _resolve_link_display("Item", v("item")),
        "cargo_description": v("cargo_description"),
        "planned_tonnage": v("planned_tonnage", 0),
        "actual_tonnage": v("actual_tonnage", 0),
        "weight": v("weight", 0),
        "qty": v("qty", 0),
        "destination": v("destination"),
        "origin": v("origin"),
        "border_name": _resolve_link_display("Border", v("border")),
        "waybill_number": v("waybill_number"),
        "waybill_date": format_jalali(v("waybill_date")) if v("waybill_date") else "",
        "carrier_name": _resolve_link_display("Carrier", v("carrier")),
        "freight_cost": _format_money(v("freight_cost", 0)),
        "customs_cost": _format_money(v("customs_cost", 0)),
        "clearance_cost": _format_money(v("clearance_cost", 0)),
        "total_cost": _format_money(v("total_cost", 0)),
        "estimated_profit": _format_money(v("estimated_profit", 0)),
        "purchase_amount": _format_money(v("purchase_amount", 0)),
        "sales_amount": _format_money(v("sales_amount", 0)),
    }


def _resolve_link_display(doctype, name):
    if not name or not doctype:
        return ""
    try:
        if not frappe.db.exists("DocType", doctype):
            return str(name)
        meta = frappe.get_meta(doctype)
        for field in (
            "full_name", "carrier_name", "broker_name", "border_name",
            "customer_name", "supplier_name", "item_name", "title",
        ):
            if meta.has_field(field):
                val = frappe.db.get_value(doctype, name, field)
                if val:
                    return val
        title_field = getattr(meta, "title_field", None)
        if title_field:
            val = frappe.db.get_value(doctype, name, title_field)
            if val:
                return val
    except Exception:
        pass
    return str(name)


def _format_money(value):
    if not value:
        return "۰"
    try:
        formatted = "{0:,.0f}".format(flt(value))
        fa_digits = "۰۱۲۳۴۵۶۷۸۹"
        return "".join(fa_digits[int(c)] if c.isdigit() else c for c in formatted)
    except Exception:
        return str(value)
PY
validate_py "${ALERTS}/template_renderer.py"

# =============================================================================
step "STEP 9 — duplicate_guard.py"
# =============================================================================
write_utf8 "${ALERTS}/duplicate_guard.py" <<'PY'
"""Same doc + event + recipient within 1 hour = skip.

SLA breached / critical must be allowed to repeat as escalation progresses.
"""

from __future__ import annotations

import frappe
from frappe.utils import add_to_date, now_datetime

REPEATABLE_EVENTS = ("sla_breached", "sla_critical")
WINDOW_HOURS = 1


def is_duplicate(reference_doctype, reference_name, event_type, recipient) -> bool:
    if event_type in REPEATABLE_EVENTS:
        return False
    if not reference_name or not event_type or not recipient:
        return False
    try:
        cutoff = add_to_date(now_datetime(), hours=-WINDOW_HOURS)
        filters = {
            "reference_name": reference_name,
            "event_type": event_type,
            "recipient": recipient,
            "send_status": "sent",
            "sent_at": [">=", cutoff],
        }
        if reference_doctype:
            filters["reference_doctype"] = reference_doctype
        return bool(frappe.db.exists("SMS Alert Log", filters))
    except Exception:
        return False
PY
validate_py "${ALERTS}/duplicate_guard.py"

# =============================================================================
step "STEP 10 — alert_service.py"
# =============================================================================
write_utf8 "${ALERTS}/alert_service.py" <<'PY'
"""Doc event handlers. Nothing here may raise."""

from __future__ import annotations

import frappe

from ir_gateway.ir_gateway.alerts.template_renderer import build_case_context, render_template
from ir_gateway.ir_gateway.sla.escalation_engine import get_recipients
from ir_gateway.ir_gateway.sms.sms_service import send_sms

STATE_EVENT_MAP = {
    "Driver Assigned": "driver_assigned",
    "Waybill Issued": "waybill_issued",
    "Waiting Weighbridge": "weighbridge_recorded",
    "Waiting Bijak": "bijak_required",
    "Waiting Clearance": "clearance_started",
    "Cleared": "clearance_completed",
    "Delivered": "delivery_completed",
    "Completed": "case_completed",
}


def on_transport_case_update(doc, method=None):
    try:
        if hasattr(doc, "has_value_changed") and not doc.has_value_changed("workflow_state"):
            return
        event_type = STATE_EVENT_MAP.get(getattr(doc, "workflow_state", None))
        if not event_type:
            return
        _send_case_alert(doc.name, event_type)
    except Exception:
        _log_exception("Transport Case update")


def on_waybill_submit(doc, method=None):
    try:
        if getattr(doc, "transport_case", None):
            _send_case_alert(doc.transport_case, "waybill_issued")
    except Exception:
        _log_exception("Waybill submit")


def on_weighbridge_update(doc, method=None):
    try:
        if getattr(doc, "approval_status", None) != "تاییدشده":
            return
        if hasattr(doc, "has_value_changed") and not doc.has_value_changed("approval_status"):
            return
        if getattr(doc, "transport_case", None):
            _send_case_alert(doc.transport_case, "weighbridge_recorded")
    except Exception:
        _log_exception("Weighbridge update")


def on_bijak_update(doc, method=None):
    try:
        if getattr(doc, "status", None) != "تاییدشده":
            return
        if hasattr(doc, "has_value_changed") and not doc.has_value_changed("status"):
            return
        if getattr(doc, "transport_case", None):
            _send_case_alert(doc.transport_case, "bijak_completed")
    except Exception:
        _log_exception("Bijak update")


def on_clearance_update(doc, method=None):
    try:
        if getattr(doc, "clearance_status", None) != "ترخیص شده":
            return
        if hasattr(doc, "has_value_changed") and not doc.has_value_changed("clearance_status"):
            return
        if getattr(doc, "transport_case", None):
            _send_case_alert(doc.transport_case, "clearance_completed")
    except Exception:
        _log_exception("Clearance update")


def _send_case_alert(case_name: str, event_type: str, level: int = 1):
    template = frappe.db.get_value("SMS Template", {
        "event_type": event_type,
        "is_active": 1,
        "channel": "SMS",
    }, "name")
    if not template:
        return

    context = build_case_context(case_name)
    if not context:
        return

    message = render_template(template, context)
    if not message:
        return

    for recipient in get_recipients(event_type, case_name, level=level):
        send_sms(
            to=recipient.get("phone"),
            message=message,
            reference_doctype="Transport Case",
            reference_name=case_name,
            event_type=event_type,
            template_name=template,
            escalation_level=level,
            recipient_name=recipient.get("name"),
            recipient_role=recipient.get("role"),
        )


def _get_recipients(event_type: str, case_name: str, level: int = 1):
    """Back-compat alias used by older call sites / tests."""
    return get_recipients(event_type, case_name, level=level)


def _log_exception(context):
    try:
        frappe.log_error(
            title=("ir_gateway alert_service: {0}".format(context))[:140],
            message=frappe.get_traceback(),
        )
    except Exception:
        pass
PY
validate_py "${ALERTS}/alert_service.py"

# =============================================================================
step "STEP 11 — sla_monitor.py"
# =============================================================================
write_utf8 "${SLA}/sla_monitor.py" <<'PY'
"""SLA engine. Scheduler cron */15.

Uses frappe.utils.scheduler.is_scheduler_inactive() — is_scheduler_active()
DOES NOT EXIST in Frappe v15.
"""

from __future__ import annotations

import frappe
from frappe.utils import flt, get_datetime, now_datetime

from ir_gateway.ir_gateway.alerts.template_renderer import (
    build_case_context,
    format_jalali,
    render_template,
)
from ir_gateway.ir_gateway.sla.escalation_engine import get_recipients
from ir_gateway.ir_gateway.sms.sms_service import send_sms

EVENT_MAP = {"warning": "sla_warning", "breached": "sla_breached", "critical": "sla_critical"}
LEVEL_MAP = {"warning": 1, "breached": 2, "critical": 4}


def check_all_sla():
    try:
        from frappe.utils.scheduler import is_scheduler_inactive
        if is_scheduler_inactive():
            return
    except Exception:
        pass

    try:
        settings = frappe.get_single("SMS Gateway Settings")
    except Exception:
        return

    if not getattr(settings, "enabled", 0):
        return
    if not getattr(settings, "escalation_enabled", 0):
        return

    sla_configs = frappe.get_all(
        "SLA Stage Config",
        filters={"is_active": 1},
        fields=[
            "name", "stage_name", "workflow_state", "deadline_hours",
            "warning_threshold_percent", "escalation_enabled",
        ],
    )
    if not sla_configs:
        return

    active_states = [c.workflow_state for c in sla_configs if c.workflow_state]
    if not active_states:
        return

    case_fields = ["name", "workflow_state", "modified"]
    try:
        if frappe.get_meta("Transport Case").has_field("assigned_user"):
            case_fields.append("assigned_user")
    except Exception:
        pass

    cases = frappe.get_all(
        "Transport Case",
        filters={"workflow_state": ["in", active_states]},
        fields=case_fields,
    )

    for case in cases:
        config = next((c for c in sla_configs if c.workflow_state == case.workflow_state), None)
        if not config or not config.escalation_enabled:
            continue
        try:
            _check_case_sla(case, config)
        except Exception as e:
            try:
                frappe.log_error(
                    title="ir_gateway sla_monitor {0}".format(case.name),
                    message=str(e),
                )
            except Exception:
                pass


def evaluate(elapsed_hours, deadline_hours, warning_threshold_percent=80):
    warning_threshold = deadline_hours * (flt(warning_threshold_percent or 80) / 100.0)
    if elapsed_hours < warning_threshold:
        return "normal"
    if elapsed_hours < deadline_hours:
        return "warning"
    if elapsed_hours < deadline_hours * 2:
        return "breached"
    return "critical"


def _check_case_sla(case, config):
    deadline_hours = flt(config.deadline_hours)
    if deadline_hours <= 0:
        return

    last_modified = get_datetime(case.modified)
    elapsed_hours = (now_datetime() - last_modified).total_seconds() / 3600.0
    sla_status = evaluate(elapsed_hours, deadline_hours, config.warning_threshold_percent)
    if sla_status == "normal":
        return

    event_type = EVENT_MAP[sla_status]
    escalation_level = LEVEL_MAP[sla_status]

    template = frappe.db.get_value(
        "SMS Template", {"event_type": event_type, "is_active": 1}, "name"
    )
    if not template:
        return

    context = build_case_context(case.name)
    context.update({
        "sla_stage": config.stage_name,
        "sla_deadline": "{0} + {1} ساعت".format(format_jalali(last_modified.date()), deadline_hours),
        "sla_elapsed_hours": "{0:.1f}".format(elapsed_hours),
        "sla_remaining_hours": "{0:.1f}".format(deadline_hours - elapsed_hours),
        "assigned_user": case.get("assigned_user") or "",
        "escalation_level": escalation_level,
    })

    message = render_template(template, context)
    if not message:
        return

    for recipient in get_recipients(event_type, case.name, level=escalation_level):
        send_sms(
            to=recipient.get("phone"),
            message=message,
            reference_doctype="Transport Case",
            reference_name=case.name,
            event_type=event_type,
            template_name=template,
            escalation_level=escalation_level,
            sla_stage=config.stage_name,
            recipient_name=recipient.get("name"),
            recipient_role=recipient.get("role"),
        )
PY
validate_py "${SLA}/sla_monitor.py"

# =============================================================================
step "STEP 12 — escalation_engine.py"
# =============================================================================
write_utf8 "${SLA}/escalation_engine.py" <<'PY'
"""Who gets notified at a given event + escalation level. Nothing hardcoded."""

from __future__ import annotations

import frappe


def get_recipients(event_type: str, reference_name: str = None, level: int = 1) -> list:
    recipients = []

    if event_type == "driver_assigned" and reference_name:
        driver = frappe.db.get_value(
            "Transport Case", reference_name,
            ["driver_mobile", "driver_name"], as_dict=True,
        )
        if driver and driver.get("driver_mobile"):
            recipients.append({
                "phone": driver.get("driver_mobile"),
                "name": driver.get("driver_name") or "",
                "role": "Driver",
            })

    if event_type in ("sla_warning", "sla_breached", "sla_critical") and reference_name:
        try:
            if frappe.get_meta("Transport Case").has_field("assigned_user"):
                assigned_user = frappe.db.get_value(
                    "Transport Case", reference_name, "assigned_user"
                )
                assigned = _get_user_recipient(assigned_user, "Assigned User")
                if assigned:
                    recipients.append(assigned)
        except Exception:
            pass

    rules = frappe.get_all("Alert Escalation Rule", filters={
        "event_type": event_type,
        "escalation_level": level,
        "is_active": 1,
    }, fields=["name"])

    for rule in rules:
        try:
            rule_doc = frappe.get_doc("Alert Escalation Rule", rule.name)
        except Exception:
            continue

        if getattr(rule_doc, "channel", None) == "Internal":
            continue

        for role_row in (rule_doc.notify_roles or []):
            role = _row_value(role_row, "role")
            if not role or role in ("Assigned User", "Driver"):
                continue
            users = frappe.get_all(
                "Has Role",
                filters={"role": role, "parenttype": "User"},
                fields=["parent"],
            )
            for user_row in users:
                recipient = _get_user_recipient(user_row.parent, role)
                if recipient:
                    recipients.append(recipient)

        for user_row in (rule_doc.notify_users or []):
            user_id = _row_value(user_row, "user")
            recipient = _get_user_recipient(user_id, "User")
            if recipient:
                recipients.append(recipient)

    return _dedupe_recipients(recipients)


def _get_user_recipient(user_id: str, role: str):
    if not user_id or user_id in ("Administrator", "Guest"):
        return None
    user = frappe.db.get_value(
        "User", user_id,
        ["enabled", "user_type", "mobile_no", "full_name"], as_dict=True,
    )
    if not user:
        return None
    if not user.enabled or user.user_type != "System User" or not user.mobile_no:
        return None
    return {"phone": user.mobile_no, "name": user.full_name or user_id, "role": role}


def _row_value(row, key):
    try:
        return row.get(key)
    except Exception:
        return getattr(row, key, None)


def _dedupe_recipients(recipients):
    seen = set()
    unique = []
    for r in recipients:
        phone = (r.get("phone") or "").strip()
        if not phone or phone in seen:
            continue
        seen.add(phone)
        r["phone"] = phone
        unique.append(r)
    return unique
PY
validate_py "${SLA}/escalation_engine.py"

# =============================================================================
step "STEP 13 — daily_report.py"
# =============================================================================
write_utf8 "${ALERTS}/daily_report.py" <<'PY'
"""Daily CEO SMS. Own scheduler slot so it never blocks SLA checks."""

from __future__ import annotations

import frappe
from frappe.utils import add_to_date, flt, now_datetime

from ir_gateway.ir_gateway.alerts.template_renderer import format_jalali, render_template
from ir_gateway.ir_gateway.sms.sms_service import send_sms

CLOSED_STATES = ("Completed", "Cancelled", "Rejected")


def send_daily_ceo_report():
    try:
        settings = frappe.get_single("SMS Gateway Settings")
    except Exception:
        return

    if not settings or not settings.enabled:
        return
    if not settings.daily_report_enabled:
        return
    if not settings.daily_report_recipients:
        return

    template = frappe.db.get_value(
        "SMS Template", {"event_type": "daily_report", "is_active": 1}, "name"
    )
    if not template:
        return

    message = render_template(template, _build_report_data())
    if not message:
        return

    for phone in (settings.daily_report_recipients or "").splitlines():
        phone = phone.strip()
        if phone:
            send_sms(to=phone, message=message, event_type="daily_report", template_name=template)


def _count(filters):
    try:
        return frappe.db.count("Transport Case", filters)
    except Exception:
        return 0


def _has_field(doctype, fieldname):
    try:
        return frappe.get_meta(doctype).has_field(fieldname)
    except Exception:
        return False


def _top_value(fieldname):
    if not fieldname or not _has_field("Transport Case", fieldname):
        return "—"
    try:
        result = frappe.db.sql("""
            SELECT `{0}` as value, COUNT(*) as cnt
            FROM `tabTransport Case`
            WHERE workflow_state NOT IN ('Cancelled', 'Rejected')
              AND `{0}` IS NOT NULL AND `{0}` != ''
            GROUP BY `{0}`
            ORDER BY cnt DESC
            LIMIT 1
        """.format(fieldname), as_dict=True)
        return result[0].value if result else "—"
    except Exception:
        return "—"


def _build_report_data() -> dict:
    now = now_datetime()
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)

    total_tonnage = 0
    tonnage_field = None
    if _has_field("Transport Case", "actual_tonnage"):
        tonnage_field = "actual_tonnage"
    elif _has_field("Transport Case", "planned_tonnage"):
        tonnage_field = "planned_tonnage"
    if tonnage_field:
        try:
            rows = frappe.db.sql("""
                SELECT IFNULL(SUM(`{0}`), 0) as total
                FROM `tabTransport Case`
                WHERE workflow_state = 'Completed'
            """.format(tonnage_field), as_dict=True)
            total_tonnage = flt(rows[0].total) if rows else 0
        except Exception:
            pass

    factory_field = "supplier_factory" if _has_field("Transport Case", "supplier_factory") else "supplier"

    return {
        "report_date": format_jalali(now.date()),
        "total_cases": _count({"workflow_state": ["not in", list(CLOSED_STATES)]}),
        "new_cases_today": _count({"creation": [">=", today_start]}),
        "completed_today": _count({"workflow_state": "Completed", "modified": [">=", today_start]}),
        "in_transit": _count({"workflow_state": "In Transit"}),
        "waiting_bijak": _count({"workflow_state": "Waiting Bijak"}),
        "waiting_clearance": _count({"workflow_state": "Waiting Clearance"}),
        "waiting_payment": _count({"workflow_state": "Pending Payment"}),
        "total_tonnage": "{0:.1f}".format(total_tonnage),
        "delayed_cases": _count({
            "workflow_state": ["not in", list(CLOSED_STATES)],
            "modified": ["<", add_to_date(now, hours=-24)],
        }),
        "top_destination": _top_value("destination"),
        "top_factory": _top_value(factory_field),
    }
PY
validate_py "${ALERTS}/daily_report.py"

# =============================================================================
step "STEP 14 — API"
# =============================================================================
write_utf8 "${API}/sms_api.py" <<'PY'
"""Whitelisted SMS endpoints."""

from __future__ import annotations

import frappe


@frappe.whitelist()
def test_sms_connection():
    from ir_gateway.ir_gateway.sms.sms_service import get_configured_adapter

    adapter, _settings = get_configured_adapter()
    if not adapter:
        return {"success": False, "message": "No adapter configured (or SMS system disabled)"}
    valid, msg = adapter.validate_config()
    if not valid:
        return {"success": False, "message": msg}
    try:
        success, msg = adapter.test_connection()
    except Exception as e:
        return {"success": False, "message": str(e)}
    return {"success": success, "message": msg}


@frappe.whitelist()
def send_test_sms(to: str, message: str = "تست پیامک از سیستم حمل و نقل ایران"):
    frappe.only_for(["System Manager", "CEO"])
    from ir_gateway.ir_gateway.sms.sms_service import send_sms

    return send_sms(to=to, message=message, event_type="custom")


@frappe.whitelist()
def list_sms_adapters():
    from ir_gateway.ir_gateway.sms.adapter_registry import discover_adapters, list_adapters

    discover_adapters(force=True)
    return list_adapters()


@frappe.whitelist()
def get_sms_balance():
    from ir_gateway.ir_gateway.sms.sms_service import get_configured_adapter

    adapter, _settings = get_configured_adapter()
    if not adapter:
        return None
    try:
        return adapter.get_balance()
    except Exception:
        return None
PY
validate_py "${API}/sms_api.py"

write_utf8 "${API}/alert_api.py" <<'PY'
"""Whitelisted alert endpoints."""

from __future__ import annotations

import frappe
from frappe.utils import flt, get_datetime, now_datetime


@frappe.whitelist()
def get_alert_history(reference_doctype: str, reference_name: str, limit: int = 50):
    return frappe.get_all(
        "SMS Alert Log",
        filters={"reference_doctype": reference_doctype, "reference_name": reference_name},
        fields=[
            "name", "event_type", "recipient", "recipient_name", "channel",
            "send_status", "message_text", "sent_at", "escalation_level", "sla_stage",
        ],
        order_by="sent_at desc",
        limit_page_length=int(limit or 50),
    )


@frappe.whitelist()
def get_sla_status(case_name: str):
    from ir_gateway.ir_gateway.sla.sla_monitor import evaluate

    case = frappe.get_doc("Transport Case", case_name)
    sla_config = frappe.db.get_value(
        "SLA Stage Config",
        {"workflow_state": case.workflow_state, "is_active": 1},
        ["stage_name", "deadline_hours", "warning_threshold_percent"],
        as_dict=True,
    )
    if not sla_config:
        return {"has_sla": False}

    elapsed = (now_datetime() - get_datetime(case.modified)).total_seconds() / 3600.0
    deadline = flt(sla_config.deadline_hours)
    return {
        "has_sla": True,
        "stage_name": sla_config.stage_name,
        "deadline_hours": deadline,
        "elapsed_hours": round(elapsed, 1),
        "remaining_hours": round(deadline - elapsed, 1),
        "status": evaluate(elapsed, deadline, sla_config.warning_threshold_percent),
    }
PY
validate_py "${API}/alert_api.py"

# =============================================================================
step "STEP 15 — DOCTYPES"
# =============================================================================
EVENT_OPTIONS="driver_assigned\nwaybill_issued\nweighbridge_recorded\nbijak_required\nbijak_completed\nclearance_started\nclearance_completed\ndelivery_completed\npayment_due\ncase_completed\nsla_warning\nsla_breached\nsla_critical\ndaily_report\ncustom"

# --- SMS Gateway Settings ---
write_utf8 "${DT}/sms_gateway_settings/sms_gateway_settings.py" <<'PY'
import frappe
from frappe.model.document import Document


class SMSGatewaySettings(Document):
    def validate(self):
        if self.enabled and self.test_mode and not self.test_number:
            frappe.throw("در حالت آزمایشی، شماره آزمایشی الزامی است.")
        if self.enabled and not self.adapter_id:
            frappe.throw("برای فعال‌سازی سیستم پیامک، انتخاب «ارائه‌دهنده پیامک» الزامی است.")
        if self.request_timeout is not None and self.request_timeout < 1:
            frappe.throw("زمان انتظار باید بزرگ‌تر از صفر باشد.")
        if self.max_retry is not None and self.max_retry < 0:
            frappe.throw("حداکثر تلاش مجدد نمی‌تواند منفی باشد.")
        if self.retry_delay_seconds is not None and self.retry_delay_seconds < 0:
            frappe.throw("تأخیر بین تلاش‌ها نمی‌تواند منفی باشد.")
PY
write_utf8 "${DT}/sms_gateway_settings/test_sms_gateway_settings.py" <<'PY'
from frappe.tests.utils import FrappeTestCase


class TestSMSGatewaySettings(FrappeTestCase):
    def test_is_single(self):
        import frappe
        self.assertEqual(frappe.get_meta("SMS Gateway Settings").issingle, 1)
PY
write_utf8 "${DT}/sms_gateway_settings/sms_gateway_settings.json" <<'JSON'
{
  "actions": [],
  "creation": "2025-01-01 00:00:00.000000",
  "doctype": "DocType",
  "engine": "InnoDB",
  "field_order": ["enabled", "test_mode", "test_number", "adapter_id", "adapter_config_section", "api_url", "api_key", "api_secret", "sender_number", "sender_name", "request_timeout", "max_retry", "retry_delay_seconds", "log_all_sends", "daily_report_section", "daily_report_enabled", "daily_report_time", "daily_report_recipients", "sla_section", "sla_check_interval_minutes", "escalation_enabled"],
  "fields": [
    {"default": "0", "fieldname": "enabled", "fieldtype": "Check", "label": "فعال‌سازی سیستم پیامک"},
    {"default": "1", "fieldname": "test_mode", "fieldtype": "Check", "label": "حالت آزمایشی"},
    {"depends_on": "eval:doc.test_mode", "fieldname": "test_number", "fieldtype": "Data", "label": "شماره آزمایشی"},
    {"default": "generic_http", "fieldname": "adapter_id", "fieldtype": "Select", "label": "ارائه‌دهنده پیامک", "options": "\ngeneric_http\nkavenegar", "reqd": 1},
    {"fieldname": "adapter_config_section", "fieldtype": "Section Break", "label": "تنظیمات ارائه‌دهنده"},
    {"fieldname": "api_url", "fieldtype": "Data", "label": "آدرس API"},
    {"fieldname": "api_key", "fieldtype": "Password", "label": "کلید API"},
    {"fieldname": "api_secret", "fieldtype": "Password", "label": "رمز API"},
    {"fieldname": "sender_number", "fieldtype": "Data", "label": "شماره فرستنده"},
    {"fieldname": "sender_name", "fieldtype": "Data", "label": "نام فرستنده"},
    {"default": "30", "fieldname": "request_timeout", "fieldtype": "Int", "label": "زمان انتظار (ثانیه)"},
    {"default": "2", "fieldname": "max_retry", "fieldtype": "Int", "label": "حداکثر تلاش مجدد"},
    {"default": "5", "fieldname": "retry_delay_seconds", "fieldtype": "Int", "label": "تأخیر بین تلاش‌ها (ثانیه)"},
    {"default": "1", "fieldname": "log_all_sends", "fieldtype": "Check", "label": "ثبت تمام ارسال‌ها"},
    {"fieldname": "daily_report_section", "fieldtype": "Section Break", "label": "گزارش روزانه"},
    {"default": "1", "fieldname": "daily_report_enabled", "fieldtype": "Check", "label": "فعال‌سازی گزارش روزانه"},
    {"default": "23:59:00", "fieldname": "daily_report_time", "fieldtype": "Time", "label": "ساعت ارسال گزارش"},
    {"description": "یک شماره در هر خط", "fieldname": "daily_report_recipients", "fieldtype": "Small Text", "label": "گیرندگان گزارش روزانه"},
    {"fieldname": "sla_section", "fieldtype": "Section Break", "label": "تنظیمات SLA"},
    {"default": "15", "fieldname": "sla_check_interval_minutes", "fieldtype": "Int", "label": "فاصله بررسی SLA (دقیقه)"},
    {"default": "1", "fieldname": "escalation_enabled", "fieldtype": "Check", "label": "فعال‌سازی اطلاع‌رسانی سطحی"}
  ],
  "issingle": 1,
  "links": [],
  "modified": "2025-01-01 00:00:00.000000",
  "modified_by": "Administrator",
  "module": "IR Gateway",
  "name": "SMS Gateway Settings",
  "owner": "Administrator",
  "permissions": [
    {"create": 1, "delete": 1, "email": 1, "print": 1, "read": 1, "role": "System Manager", "share": 1, "write": 1},
    {"read": 1, "role": "CEO"},
    {"read": 1, "role": "Financial Manager"},
    {"read": 1, "role": "Transport Supervisor"}
  ],
  "sort_field": "modified",
  "sort_order": "DESC",
  "track_changes": 1
}
JSON

# --- SMS Template ---
write_utf8 "${DT}/sms_template/sms_template.py" <<'PY'
import frappe
from frappe.model.document import Document


class SMSTemplate(Document):
    def validate(self):
        if self.channel == "SMS" and not (self.template_text or "").strip():
            frappe.throw("متن پیام الزامی است.")
PY
write_utf8 "${DT}/sms_template/test_sms_template.py" <<'PY'
from frappe.tests.utils import FrappeTestCase


class TestSMSTemplate(FrappeTestCase):
    pass
PY
write_utf8 "${DT}/sms_template/sms_template.json" <<JSON
{
  "actions": [],
  "allow_rename": 1,
  "autoname": "field:template_name",
  "creation": "2025-01-01 00:00:00.000000",
  "doctype": "DocType",
  "engine": "InnoDB",
  "field_order": ["template_name", "event_type", "channel", "subject", "template_text", "language", "is_active", "priority", "notes"],
  "fields": [
    {"fieldname": "template_name", "fieldtype": "Data", "in_list_view": 1, "label": "نام قالب", "reqd": 1, "unique": 1},
    {"fieldname": "event_type", "fieldtype": "Select", "in_list_view": 1, "label": "رویداد", "options": "${EVENT_OPTIONS}", "reqd": 1},
    {"default": "SMS", "fieldname": "channel", "fieldtype": "Select", "label": "کانال", "options": "SMS\\nEmail\\nInternal", "reqd": 1},
    {"depends_on": "eval:doc.channel=='Email'", "fieldname": "subject", "fieldtype": "Data", "label": "موضوع"},
    {"description": "متغیرها به‌صورت {{ variable_name }}", "fieldname": "template_text", "fieldtype": "Text", "label": "متن پیام", "reqd": 1},
    {"default": "fa", "fieldname": "language", "fieldtype": "Select", "label": "زبان", "options": "fa\\nen", "reqd": 1},
    {"default": "1", "fieldname": "is_active", "fieldtype": "Check", "in_list_view": 1, "label": "فعال"},
    {"default": "Normal", "fieldname": "priority", "fieldtype": "Select", "label": "اولویت", "options": "Low\\nNormal\\nHigh\\nCritical", "reqd": 1},
    {"fieldname": "notes", "fieldtype": "Small Text", "label": "یادداشت"}
  ],
  "links": [],
  "modified": "2025-01-01 00:00:00.000000",
  "modified_by": "Administrator",
  "module": "IR Gateway",
  "name": "SMS Template",
  "naming_rule": "By fieldname",
  "owner": "Administrator",
  "permissions": [
    {"create": 1, "delete": 1, "email": 1, "print": 1, "read": 1, "role": "System Manager", "share": 1, "write": 1},
    {"read": 1, "role": "CEO"},
    {"read": 1, "role": "Financial Manager"},
    {"read": 1, "role": "Transport Supervisor"}
  ],
  "sort_field": "modified",
  "sort_order": "DESC",
  "title_field": "template_name",
  "track_changes": 1
}
JSON

# --- SMS Alert Log (reference fields NOT required — daily report / test SMS) ---
write_utf8 "${DT}/sms_alert_log/sms_alert_log.py" <<'PY'
from frappe.model.document import Document


class SMSAlertLog(Document):
    pass
PY
write_utf8 "${DT}/sms_alert_log/test_sms_alert_log.py" <<'PY'
from frappe.tests.utils import FrappeTestCase


class TestSMSAlertLog(FrappeTestCase):
    pass
PY
write_utf8 "${DT}/sms_alert_log/sms_alert_log.json" <<'JSON'
{
  "actions": [],
  "autoname": "hash",
  "creation": "2025-01-01 00:00:00.000000",
  "doctype": "DocType",
  "engine": "InnoDB",
  "field_order": ["reference_doctype", "reference_name", "event_type", "template_name", "recipient", "recipient_name", "recipient_role", "channel", "message_text", "send_status", "message_id", "error_message", "retry_count", "sent_at", "test_mode", "adapter_id", "raw_response", "escalation_level", "sla_stage"],
  "fields": [
    {"fieldname": "reference_doctype", "fieldtype": "Link", "label": "نوع سند مرجع", "options": "DocType"},
    {"fieldname": "reference_name", "fieldtype": "Dynamic Link", "in_list_view": 1, "label": "نام سند مرجع", "options": "reference_doctype"},
    {"fieldname": "event_type", "fieldtype": "Data", "in_list_view": 1, "label": "نوع رویداد", "reqd": 1},
    {"fieldname": "template_name", "fieldtype": "Link", "label": "قالب پیامک", "options": "SMS Template"},
    {"fieldname": "recipient", "fieldtype": "Data", "in_list_view": 1, "label": "گیرنده", "reqd": 1},
    {"fieldname": "recipient_name", "fieldtype": "Data", "label": "نام گیرنده"},
    {"fieldname": "recipient_role", "fieldtype": "Data", "label": "نقش گیرنده"},
    {"default": "SMS", "fieldname": "channel", "fieldtype": "Data", "label": "کانال", "reqd": 1},
    {"fieldname": "message_text", "fieldtype": "Text", "label": "متن پیام"},
    {"default": "pending", "fieldname": "send_status", "fieldtype": "Select", "in_list_view": 1, "label": "وضعیت ارسال", "options": "pending\nsent\nfailed\nqueued", "reqd": 1},
    {"fieldname": "message_id", "fieldtype": "Data", "label": "شناسه پیام"},
    {"fieldname": "error_message", "fieldtype": "Small Text", "label": "پیام خطا"},
    {"default": "0", "fieldname": "retry_count", "fieldtype": "Int", "label": "تعداد تلاش مجدد"},
    {"fieldname": "sent_at", "fieldtype": "Datetime", "in_list_view": 1, "label": "زمان ارسال"},
    {"default": "0", "fieldname": "test_mode", "fieldtype": "Check", "label": "حالت آزمایشی"},
    {"fieldname": "adapter_id", "fieldtype": "Data", "label": "ارائه‌دهنده"},
    {"fieldname": "raw_response", "fieldtype": "Code", "label": "پاسخ خام"},
    {"fieldname": "escalation_level", "fieldtype": "Int", "label": "سطح اطلاع‌رسانی"},
    {"fieldname": "sla_stage", "fieldtype": "Data", "label": "مرحله SLA"}
  ],
  "in_create": 1,
  "links": [],
  "modified": "2025-01-01 00:00:00.000000",
  "modified_by": "Administrator",
  "module": "IR Gateway",
  "name": "SMS Alert Log",
  "owner": "Administrator",
  "permissions": [
    {"create": 1, "delete": 1, "email": 1, "export": 1, "print": 1, "read": 1, "report": 1, "role": "System Manager", "share": 1, "write": 1},
    {"read": 1, "report": 1, "role": "CEO"},
    {"read": 1, "report": 1, "role": "Financial Manager"},
    {"read": 1, "report": 1, "role": "Transport Supervisor"},
    {"read": 1, "report": 1, "role": "Transport User - Purchase"},
    {"read": 1, "report": 1, "role": "Transport User - Sales"},
    {"read": 1, "report": 1, "role": "Customs Officer"}
  ],
  "sort_field": "creation",
  "sort_order": "DESC"
}
JSON

# --- SLA Stage Config ---
write_utf8 "${DT}/sla_stage_config/sla_stage_config.py" <<'PY'
import frappe
from frappe.model.document import Document


class SLAStageConfig(Document):
    def validate(self):
        if self.deadline_hours is not None and self.deadline_hours <= 0:
            frappe.throw("مهلت باید بزرگ‌تر از صفر باشد.")
        if self.warning_threshold_percent and not (1 <= self.warning_threshold_percent <= 100):
            frappe.throw("آستانه هشدار باید بین ۱ تا ۱۰۰ باشد.")
PY
write_utf8 "${DT}/sla_stage_config/test_sla_stage_config.py" <<'PY'
from frappe.tests.utils import FrappeTestCase


class TestSLAStageConfig(FrappeTestCase):
    pass
PY
write_utf8 "${DT}/sla_stage_config/sla_stage_config.json" <<'JSON'
{
  "actions": [],
  "allow_rename": 1,
  "autoname": "field:stage_name",
  "creation": "2025-01-01 00:00:00.000000",
  "doctype": "DocType",
  "engine": "InnoDB",
  "field_order": ["stage_name", "workflow_state", "deadline_hours", "warning_threshold_percent", "escalation_enabled", "is_active", "description"],
  "fields": [
    {"fieldname": "stage_name", "fieldtype": "Data", "in_list_view": 1, "label": "نام مرحله", "reqd": 1, "unique": 1},
    {"fieldname": "workflow_state", "fieldtype": "Data", "in_list_view": 1, "label": "وضعیت گردش‌کار", "reqd": 1},
    {"fieldname": "deadline_hours", "fieldtype": "Float", "in_list_view": 1, "label": "مهلت (ساعت)", "precision": "2", "reqd": 1},
    {"default": "80", "fieldname": "warning_threshold_percent", "fieldtype": "Int", "label": "آستانه هشدار (٪)"},
    {"default": "1", "fieldname": "escalation_enabled", "fieldtype": "Check", "label": "اطلاع‌رسانی سطحی فعال"},
    {"default": "1", "fieldname": "is_active", "fieldtype": "Check", "in_list_view": 1, "label": "فعال"},
    {"fieldname": "description", "fieldtype": "Small Text", "label": "توضیحات"}
  ],
  "links": [],
  "modified": "2025-01-01 00:00:00.000000",
  "modified_by": "Administrator",
  "module": "IR Gateway",
  "name": "SLA Stage Config",
  "naming_rule": "By fieldname",
  "owner": "Administrator",
  "permissions": [
    {"create": 1, "delete": 1, "email": 1, "print": 1, "read": 1, "role": "System Manager", "share": 1, "write": 1},
    {"read": 1, "role": "CEO"},
    {"read": 1, "role": "Financial Manager"},
    {"read": 1, "role": "Transport Supervisor"}
  ],
  "sort_field": "modified",
  "sort_order": "DESC",
  "title_field": "stage_name",
  "track_changes": 1
}
JSON

# --- Table MultiSelect children ---
write_utf8 "${DT}/alert_escalation_role/alert_escalation_role.py" <<'PY'
from frappe.model.document import Document


class AlertEscalationRole(Document):
    pass
PY
write_utf8 "${DT}/alert_escalation_role/alert_escalation_role.json" <<'JSON'
{
  "actions": [],
  "creation": "2025-01-01 00:00:00.000000",
  "doctype": "DocType",
  "editable_grid": 1,
  "engine": "InnoDB",
  "field_order": ["role"],
  "fields": [
    {"fieldname": "role", "fieldtype": "Link", "in_list_view": 1, "label": "نقش", "options": "Role", "reqd": 1}
  ],
  "istable": 1,
  "links": [],
  "modified": "2025-01-01 00:00:00.000000",
  "modified_by": "Administrator",
  "module": "IR Gateway",
  "name": "Alert Escalation Role",
  "owner": "Administrator",
  "permissions": [],
  "sort_field": "modified",
  "sort_order": "DESC"
}
JSON

write_utf8 "${DT}/alert_escalation_user/alert_escalation_user.py" <<'PY'
from frappe.model.document import Document


class AlertEscalationUser(Document):
    pass
PY
write_utf8 "${DT}/alert_escalation_user/alert_escalation_user.json" <<'JSON'
{
  "actions": [],
  "creation": "2025-01-01 00:00:00.000000",
  "doctype": "DocType",
  "editable_grid": 1,
  "engine": "InnoDB",
  "field_order": ["user"],
  "fields": [
    {"fieldname": "user", "fieldtype": "Link", "in_list_view": 1, "label": "کاربر", "options": "User", "reqd": 1}
  ],
  "istable": 1,
  "links": [],
  "modified": "2025-01-01 00:00:00.000000",
  "modified_by": "Administrator",
  "module": "IR Gateway",
  "name": "Alert Escalation User",
  "owner": "Administrator",
  "permissions": [],
  "sort_field": "modified",
  "sort_order": "DESC"
}
JSON

# --- Alert Escalation Rule ---
write_utf8 "${DT}/alert_escalation_rule/alert_escalation_rule.py" <<'PY'
import frappe
from frappe.model.document import Document


class AlertEscalationRule(Document):
    def validate(self):
        if self.escalation_level not in (1, 2, 3, 4):
            frappe.throw("سطح اطلاع‌رسانی باید بین ۱ تا ۴ باشد.")
        if not (self.notify_roles or self.notify_users):
            frappe.throw("حداقل یک نقش یا کاربر برای اطلاع‌رسانی لازم است.")
PY
write_utf8 "${DT}/alert_escalation_rule/test_alert_escalation_rule.py" <<'PY'
from frappe.tests.utils import FrappeTestCase


class TestAlertEscalationRule(FrappeTestCase):
    pass
PY
write_utf8 "${DT}/alert_escalation_rule/alert_escalation_rule.json" <<JSON
{
  "actions": [],
  "allow_rename": 1,
  "autoname": "format:{event_type}-{escalation_level}",
  "creation": "2025-01-01 00:00:00.000000",
  "doctype": "DocType",
  "engine": "InnoDB",
  "field_order": ["event_type", "escalation_level", "notify_roles", "notify_users", "channel", "is_active"],
  "fields": [
    {"fieldname": "event_type", "fieldtype": "Select", "in_list_view": 1, "label": "نوع رویداد", "options": "${EVENT_OPTIONS}", "reqd": 1},
    {"description": "1 تا 4", "fieldname": "escalation_level", "fieldtype": "Int", "in_list_view": 1, "label": "سطح اطلاع‌رسانی", "reqd": 1},
    {"fieldname": "notify_roles", "fieldtype": "Table MultiSelect", "label": "نقش‌های اطلاع‌رسانی", "options": "Alert Escalation Role"},
    {"fieldname": "notify_users", "fieldtype": "Table MultiSelect", "label": "کاربران اطلاع‌رسانی", "options": "Alert Escalation User"},
    {"default": "Both", "fieldname": "channel", "fieldtype": "Select", "label": "کانال", "options": "SMS\\nInternal\\nBoth", "reqd": 1},
    {"default": "1", "fieldname": "is_active", "fieldtype": "Check", "in_list_view": 1, "label": "فعال"}
  ],
  "links": [],
  "modified": "2025-01-01 00:00:00.000000",
  "modified_by": "Administrator",
  "module": "IR Gateway",
  "name": "Alert Escalation Rule",
  "naming_rule": "Expression",
  "owner": "Administrator",
  "permissions": [
    {"create": 1, "delete": 1, "email": 1, "print": 1, "read": 1, "role": "System Manager", "share": 1, "write": 1},
    {"read": 1, "role": "CEO"},
    {"read": 1, "role": "Financial Manager"},
    {"read": 1, "role": "Transport Supervisor"}
  ],
  "sort_field": "modified",
  "sort_order": "DESC",
  "track_changes": 1
}
JSON

# --- Notification History ---
write_utf8 "${DT}/notification_history/notification_history.py" <<'PY'
from frappe.model.document import Document


class NotificationHistory(Document):
    pass
PY
write_utf8 "${DT}/notification_history/notification_history.json" <<'JSON'
{
  "actions": [],
  "creation": "2025-01-01 00:00:00.000000",
  "doctype": "DocType",
  "editable_grid": 1,
  "engine": "InnoDB",
  "field_order": ["sent_at", "event_type", "recipient", "recipient_name", "channel", "send_status", "message_summary", "alert_log"],
  "fields": [
    {"fieldname": "sent_at", "fieldtype": "Datetime", "in_list_view": 1, "label": "زمان ارسال", "read_only": 1},
    {"fieldname": "event_type", "fieldtype": "Data", "in_list_view": 1, "label": "نوع رویداد", "read_only": 1},
    {"fieldname": "recipient", "fieldtype": "Data", "in_list_view": 1, "label": "گیرنده", "read_only": 1},
    {"fieldname": "recipient_name", "fieldtype": "Data", "label": "نام گیرنده", "read_only": 1},
    {"fieldname": "channel", "fieldtype": "Data", "label": "کانال", "read_only": 1},
    {"fieldname": "send_status", "fieldtype": "Select", "in_list_view": 1, "label": "وضعیت", "options": "pending\nsent\nfailed\nqueued", "read_only": 1},
    {"fieldname": "message_summary", "fieldtype": "Data", "label": "خلاصه پیام", "read_only": 1},
    {"fieldname": "alert_log", "fieldtype": "Link", "label": "لاگ هشدار", "options": "SMS Alert Log", "read_only": 1}
  ],
  "istable": 1,
  "links": [],
  "modified": "2025-01-01 00:00:00.000000",
  "modified_by": "Administrator",
  "module": "IR Gateway",
  "name": "Notification History",
  "owner": "Administrator",
  "permissions": [],
  "sort_field": "modified",
  "sort_order": "DESC"
}
JSON

log "All DocType JSON files written"

# =============================================================================
step "STEP 16 — FIXTURES"
# =============================================================================
write_utf8 "${FIXTURES}/sms_template.json" <<'JSON'
[
  {"doctype": "SMS Template", "name": "driver_assigned", "template_name": "driver_assigned", "event_type": "driver_assigned", "channel": "SMS", "template_text": "راننده محترم {{ driver_name }}، اطلاعات بار شما در سیستم ثبت شد.\nشماره پرونده: {{ case_name }}\nمقصد: {{ destination }}\nتناژ: {{ planned_tonnage }} تن\nلطفاً جهت ادامه فرآیند با واحد حمل هماهنگ باشید.", "language": "fa", "is_active": 1, "priority": "Normal"},
  {"doctype": "SMS Template", "name": "waybill_issued", "template_name": "waybill_issued", "event_type": "waybill_issued", "channel": "SMS", "template_text": "بارنامه {{ waybill_number }} برای پرونده {{ case_name }} صادر شد.\nمقصد: {{ destination }}\nراننده: {{ driver_name }}", "language": "fa", "is_active": 1, "priority": "Normal"},
  {"doctype": "SMS Template", "name": "case_completed", "template_name": "case_completed", "event_type": "case_completed", "channel": "SMS", "template_text": "پرونده {{ case_name }} با موفقیت بسته شد.\nتناژ: {{ actual_tonnage }} تن\nسود: {{ estimated_profit }}", "language": "fa", "is_active": 1, "priority": "Normal"},
  {"doctype": "SMS Template", "name": "sla_warning", "template_name": "sla_warning", "event_type": "sla_warning", "channel": "SMS", "template_text": "⚠️ هشدار: پرونده {{ case_name }} در مرحله «{{ sla_stage }}» نزدیک به تأخیر است.\nزمان سپری‌شده: {{ sla_elapsed_hours }} ساعت\nمهلت: {{ sla_deadline }}\nمسئول: {{ assigned_user }}", "language": "fa", "is_active": 1, "priority": "High"},
  {"doctype": "SMS Template", "name": "sla_breached", "template_name": "sla_breached", "event_type": "sla_breached", "channel": "SMS", "template_text": "🔴 تأخیر: پرونده {{ case_name }} در مرحله «{{ sla_stage }}» از مهلت عبور کرده است.\nزمان سپری‌شده: {{ sla_elapsed_hours }} ساعت\nمسئول: {{ assigned_user }}", "language": "fa", "is_active": 1, "priority": "Critical"},
  {"doctype": "SMS Template", "name": "sla_critical", "template_name": "sla_critical", "event_type": "sla_critical", "channel": "SMS", "template_text": "🚨 بحرانی: پرونده {{ case_name }} در مرحله «{{ sla_stage }}» بیش از ۲ برابر مهلت تأخیر دارد.\nزمان: {{ sla_elapsed_hours }} ساعت\nمسئول: {{ assigned_user }}", "language": "fa", "is_active": 1, "priority": "Critical"},
  {"doctype": "SMS Template", "name": "daily_report", "template_name": "daily_report", "event_type": "daily_report", "channel": "SMS", "template_text": "📊 گزارش روزانه حمل {{ report_date }}\n\nپرونده‌های فعال: {{ total_cases }}\nجدید امروز: {{ new_cases_today }}\nتکمیل‌شده: {{ completed_today }}\nدر حال حمل: {{ in_transit }}\nمنتظر بیجک: {{ waiting_bijak }}\nمنتظر ترخیص: {{ waiting_clearance }}\nمنتظر پرداخت: {{ waiting_payment }}\nتناژ کل: {{ total_tonnage }} تن\nتأخیردار: {{ delayed_cases }}\nبیشترین مقصد: {{ top_destination }}", "language": "fa", "is_active": 1, "priority": "Normal"}
]
JSON

write_utf8 "${FIXTURES}/sla_stage_config.json" <<'JSON'
[
  {"doctype": "SLA Stage Config", "name": "ثبت راننده", "stage_name": "ثبت راننده", "workflow_state": "Driver Assigned", "deadline_hours": 2, "warning_threshold_percent": 80, "escalation_enabled": 1, "is_active": 1},
  {"doctype": "SLA Stage Config", "name": "صدور بارنامه", "stage_name": "صدور بارنامه", "workflow_state": "Waybill Issued", "deadline_hours": 2, "warning_threshold_percent": 80, "escalation_enabled": 1, "is_active": 1},
  {"doctype": "SLA Stage Config", "name": "ثبت باسکول", "stage_name": "ثبت باسکول", "workflow_state": "Waiting Weighbridge", "deadline_hours": 3, "warning_threshold_percent": 80, "escalation_enabled": 1, "is_active": 1},
  {"doctype": "SLA Stage Config", "name": "بررسی بیجک", "stage_name": "بررسی بیجک", "workflow_state": "Waiting Bijak", "deadline_hours": 4, "warning_threshold_percent": 80, "escalation_enabled": 1, "is_active": 1},
  {"doctype": "SLA Stage Config", "name": "ترخیص", "stage_name": "ترخیص", "workflow_state": "Waiting Clearance", "deadline_hours": 12, "warning_threshold_percent": 80, "escalation_enabled": 1, "is_active": 1},
  {"doctype": "SLA Stage Config", "name": "ثبت رسید تخلیه", "stage_name": "ثبت رسید تخلیه", "workflow_state": "Delivered", "deadline_hours": 24, "warning_threshold_percent": 80, "escalation_enabled": 1, "is_active": 1}
]
JSON

write_utf8 "${FIXTURES}/alert_escalation_rule.json" <<'JSON'
[
  {"doctype": "Alert Escalation Rule", "name": "driver_assigned-1", "event_type": "driver_assigned", "escalation_level": 1, "channel": "SMS", "is_active": 1, "notify_roles": [{"doctype": "Alert Escalation Role", "role": "Transport Supervisor"}]},
  {"doctype": "Alert Escalation Rule", "name": "waybill_issued-1", "event_type": "waybill_issued", "escalation_level": 1, "channel": "Both", "is_active": 1, "notify_roles": [{"doctype": "Alert Escalation Role", "role": "Transport Supervisor"}]},
  {"doctype": "Alert Escalation Rule", "name": "case_completed-1", "event_type": "case_completed", "escalation_level": 1, "channel": "Both", "is_active": 1, "notify_roles": [{"doctype": "Alert Escalation Role", "role": "Financial Manager"}]},
  {"doctype": "Alert Escalation Rule", "name": "sla_warning-1", "event_type": "sla_warning", "escalation_level": 1, "channel": "Both", "is_active": 1, "notify_roles": [{"doctype": "Alert Escalation Role", "role": "Transport Supervisor"}]},
  {"doctype": "Alert Escalation Rule", "name": "sla_breached-2", "event_type": "sla_breached", "escalation_level": 2, "channel": "Both", "is_active": 1, "notify_roles": [{"doctype": "Alert Escalation Role", "role": "Transport Supervisor"}, {"doctype": "Alert Escalation Role", "role": "Financial Manager"}]},
  {"doctype": "Alert Escalation Rule", "name": "sla_critical-4", "event_type": "sla_critical", "escalation_level": 4, "channel": "SMS", "is_active": 1, "notify_roles": [{"doctype": "Alert Escalation Role", "role": "CEO"}, {"doctype": "Alert Escalation Role", "role": "Transport Supervisor"}]}
]
JSON

write_utf8 "${FIXTURES}/custom_field.json" <<'JSON'
[
  {
    "doctype": "Custom Field",
    "name": "Transport Case-notification_history_section",
    "dt": "Transport Case",
    "fieldname": "notification_history_section",
    "fieldtype": "Section Break",
    "label": "تاریخچه اعلان‌ها",
    "insert_after": "notes",
    "collapsible": 1,
    "module": "IR Gateway"
  },
  {
    "doctype": "Custom Field",
    "name": "Transport Case-notification_history",
    "dt": "Transport Case",
    "fieldname": "notification_history",
    "fieldtype": "Table",
    "label": "تاریخچه اعلان‌ها",
    "options": "Notification History",
    "insert_after": "notification_history_section",
    "read_only": 1,
    "no_copy": 1,
    "module": "IR Gateway"
  }
]
JSON
log "Fixtures written"

# =============================================================================
step "STEP 17 — hooks.py"
# =============================================================================
write_utf8 "${PKG}/hooks.py" <<'PY'
app_name = "ir_gateway"
app_title = "IR Gateway"
app_publisher = "IR Base Contributors"
app_description = "SMS/SLA/Alert notification gateway for Iran Transport ERP"
app_email = "dev@example.com"
app_license = "MIT"

required_apps = ["frappe", "erpnext", "ir_base", "transport_ir"]

fixtures = [
    {"dt": "SMS Template", "filters": [["is_active", "=", 1]]},
    {"dt": "SLA Stage Config", "filters": [["is_active", "=", 1]]},
    {"dt": "Alert Escalation Rule", "filters": [["is_active", "=", 1]]},
    {"dt": "Custom Field", "filters": [["module", "=", "IR Gateway"]]},
]

scheduler_events = {
    "cron": {
        "*/15 * * * *": [
            "ir_gateway.ir_gateway.sla.sla_monitor.check_all_sla"
        ],
    },
    "daily": [
        "ir_gateway.ir_gateway.alerts.daily_report.send_daily_ceo_report"
    ],
}

doc_events = {
    "Transport Case": {
        "on_update": "ir_gateway.ir_gateway.alerts.alert_service.on_transport_case_update",
    },
    "Transport Waybill": {
        "on_submit": "ir_gateway.ir_gateway.alerts.alert_service.on_waybill_submit",
    },
    "Transport Weighbridge": {
        "on_update": "ir_gateway.ir_gateway.alerts.alert_service.on_weighbridge_update",
    },
    "Transport Bijak": {
        "on_update": "ir_gateway.ir_gateway.alerts.alert_service.on_bijak_update",
    },
    "Transport Clearance": {
        "on_update": "ir_gateway.ir_gateway.alerts.alert_service.on_clearance_update",
    },
}

doctype_js = {
    "SMS Gateway Settings": "public/js/ir_gateway.js",
}

jinja = {
    "methods": [
        "ir_gateway.ir_gateway.alerts.template_renderer.jalali_now",
    ],
}
PY
validate_py "${PKG}/hooks.py"

# =============================================================================
step "STEP 18 — Workspace (nested path)"
# =============================================================================
write_utf8 "${WS}/ir_gateway.json" <<'JSON'
{
  "charts": [],
  "content": "[{\"id\":\"hdr\",\"type\":\"header\",\"data\":{\"text\":\"<span class=\\\"h4\\\">درگاه پیامک و هشدار</span>\",\"col\":12}},{\"id\":\"sms_cards\",\"type\":\"card\",\"data\":{\"card_name\":\"مدیریت پیامک\",\"col\":4}},{\"id\":\"sla_cards\",\"type\":\"card\",\"data\":{\"card_name\":\"مهلت‌ها و هشدارها\",\"col\":4}}]",
  "creation": "2025-01-01 00:00:00.000000",
  "doctype": "Workspace",
  "for_user": "",
  "hide_custom": 0,
  "icon": "message",
  "is_hidden": 0,
  "is_standard": 1,
  "label": "IR Gateway",
  "links": [
    {"hidden": 0, "is_query_report": 0, "label": "مدیریت پیامک", "link_count": 4, "onboard": 0, "type": "Card Break"},
    {"hidden": 0, "is_query_report": 0, "label": "تنظیمات درگاه پیامک", "link_count": 0, "link_to": "SMS Gateway Settings", "link_type": "DocType", "onboard": 1, "type": "Link"},
    {"hidden": 0, "is_query_report": 0, "label": "قالب پیامک", "link_count": 0, "link_to": "SMS Template", "link_type": "DocType", "onboard": 1, "type": "Link"},
    {"hidden": 0, "is_query_report": 0, "label": "لاگ هشدار پیامک", "link_count": 0, "link_to": "SMS Alert Log", "link_type": "DocType", "type": "Link"},
    {"hidden": 0, "is_query_report": 0, "label": "تاریخچه اعلان‌ها", "link_count": 0, "link_to": "Notification History", "link_type": "DocType", "type": "Link"},
    {"hidden": 0, "is_query_report": 0, "label": "مهلت‌ها و هشدارها", "link_count": 2, "onboard": 0, "type": "Card Break"},
    {"hidden": 0, "is_query_report": 0, "label": "پیکربندی مهلت مراحل", "link_count": 0, "link_to": "SLA Stage Config", "link_type": "DocType", "onboard": 1, "type": "Link"},
    {"hidden": 0, "is_query_report": 0, "label": "قانون تشدید هشدار", "link_count": 0, "link_to": "Alert Escalation Rule", "link_type": "DocType", "type": "Link"}
  ],
  "modified": "2025-01-01 00:00:00.000000",
  "modified_by": "Administrator",
  "module": "IR Gateway",
  "name": "IR Gateway",
  "number_cards": [],
  "owner": "Administrator",
  "parent_page": "",
  "public": 1,
  "quick_lists": [],
  "roles": [
    {"role": "System Manager"},
    {"role": "CEO"},
    {"role": "Transport Supervisor"}
  ],
  "sequence_id": 90.0,
  "shortcuts": [],
  "title": "IR Gateway"
}
JSON

# =============================================================================
step "STEP 19 — Client JS"
# =============================================================================
write_utf8 "${PKG}/public/js/ir_gateway.js" <<'JS'
frappe.ui.form.on("SMS Gateway Settings", {
    refresh(frm) {
        frappe.call({
            method: "ir_gateway.ir_gateway.api.sms_api.list_sms_adapters",
            callback(r) {
                const adapters = r.message || [];
                if (!adapters.length) return;
                const objectOptions = adapters.map((a) => ({
                    label: `${a.adapter_name} (${a.adapter_id})`,
                    value: a.adapter_id,
                }));
                try {
                    frm.set_df_property("adapter_id", "options", objectOptions);
                } catch (e) {
                    frm.set_df_property(
                        "adapter_id",
                        "options",
                        adapters.map((a) => a.adapter_id).join("\n")
                    );
                }
                frm.set_df_property(
                    "adapter_id",
                    "description",
                    adapters.map((a) => `${a.adapter_id}: ${a.adapter_name}`).join("<br>")
                );
                frm.refresh_field("adapter_id");
            },
        });

        if (frm.custom_buttons_added_phase9) return;
        frm.custom_buttons_added_phase9 = true;

        frm.add_custom_button(__("تست اتصال"), () => {
            frappe.call({
                method: "ir_gateway.ir_gateway.api.sms_api.test_sms_connection",
                callback(r) {
                    const msg = r.message || {};
                    frappe.msgprint({
                        title: __("اتصال پیامک"),
                        message: msg.message || JSON.stringify(msg),
                        indicator: msg.success ? "green" : "red",
                    });
                },
            });
        });

        frm.add_custom_button(__("اعتبار پنل"), () => {
            frappe.call({
                method: "ir_gateway.ir_gateway.api.sms_api.get_sms_balance",
                callback(r) {
                    frappe.msgprint(r.message ? JSON.stringify(r.message) : "—");
                },
            });
        });

        frm.add_custom_button(__("ارسال پیامک آزمایشی"), () => {
            frappe.prompt(
                [{ fieldname: "to", fieldtype: "Data", label: __("شماره گیرنده"), reqd: 1 }],
                (values) => {
                    frappe.call({
                        method: "ir_gateway.ir_gateway.api.sms_api.send_test_sms",
                        args: { to: values.to },
                        callback(r) {
                            frappe.msgprint(JSON.stringify(r.message || {}));
                        },
                    });
                },
                __("ارسال پیامک آزمایشی")
            );
        });
    },
});
JS

# =============================================================================
step "STEP 20 — verify_phase9.py"
# =============================================================================
write_utf8 "${MOD}/verify_phase9.py" <<'PY'
"""Verification checks for Phase 9."""

import os

import frappe


def verify_phase9():
    passed = []
    failed = []

    def check(name, condition, detail=""):
        (passed if condition else failed).append(name)
        prefix = "PASS" if condition else "FAIL"
        suffix = " -- {0}".format(detail) if detail else ""
        print("{0}: {1}{2}".format(prefix, name, suffix))

    check("ir_gateway installed", "ir_gateway" in (frappe.get_installed_apps() or []))

    for dt in [
        "SMS Gateway Settings", "SMS Template", "SMS Alert Log",
        "SLA Stage Config", "Alert Escalation Rule", "Notification History",
        "Alert Escalation Role", "Alert Escalation User",
    ]:
        check("DocType {0}".format(dt), bool(frappe.db.exists("DocType", dt)))

    template_count = frappe.db.count("SMS Template", {"is_active": 1})
    check("SMS Templates seeded (>=7)", template_count >= 7, str(template_count))

    sla_count = frappe.db.count("SLA Stage Config", {"is_active": 1})
    check("SLA configs seeded (>=6)", sla_count >= 6, str(sla_count))

    try:
        from ir_gateway.ir_gateway.sms.adapter_registry import discover_adapters, list_adapters
        discover_adapters(force=True)
        adapters = list_adapters()
        check("Adapters discovered (>=2)", len(adapters) >= 2, str(len(adapters)))
        ids = {a["adapter_id"] for a in adapters}
        check("generic_http adapter", "generic_http" in ids)
        check("kavenegar adapter", "kavenegar" in ids)
    except Exception as e:
        check("Adapter registry", False, str(e))

    try:
        from ir_gateway.ir_gateway.sms.base_adapter import BaseSMSAdapter
        check("BaseSMSAdapter importable", True)
        for method in ["send_sms", "send_bulk_sms", "get_config_fields",
                       "validate_config", "test_connection"]:
            check("BaseSMSAdapter.{0}".format(method), hasattr(BaseSMSAdapter, method))
    except Exception as e:
        check("BaseSMSAdapter", False, str(e))

    try:
        import inspect
        from ir_gateway.ir_gateway.sms.sms_service import is_duplicate, send_sms
        check("sms_service importable", True)
        params = inspect.signature(send_sms).parameters
        check("send_sms accepts recipient_name", "recipient_name" in params)
        check("send_sms accepts recipient_role", "recipient_role" in params)
        check("is_duplicate re-exported", callable(is_duplicate))
    except Exception as e:
        check("sms_service", False, str(e))

    try:
        from ir_gateway.ir_gateway.alerts.template_renderer import (  # noqa: F401
            build_case_context, render_template,
        )
        check("template_renderer importable", True)
    except Exception as e:
        check("template_renderer", False, str(e))

    try:
        from ir_gateway.ir_gateway.alerts.alert_service import on_transport_case_update  # noqa: F401
        check("alert_service importable", True)
    except Exception as e:
        check("alert_service", False, str(e))

    try:
        from ir_gateway.ir_gateway.sla.sla_monitor import check_all_sla  # noqa: F401
        from ir_gateway.ir_gateway.sla.escalation_engine import get_recipients  # noqa: F401
        from ir_gateway.ir_gateway.alerts.daily_report import send_daily_ceo_report  # noqa: F401
        from ir_gateway.ir_gateway.alerts.duplicate_guard import is_duplicate as _dg  # noqa: F401
        check("sla/escalation/daily/guard importable", True)
    except Exception as e:
        check("sla/escalation/daily/guard importable", False, str(e))

    try:
        check("SMS Gateway Settings is Single",
              frappe.get_meta("SMS Gateway Settings").issingle == 1)
    except Exception as e:
        check("SMS Gateway Settings is Single", False, str(e))

    try:
        check("Notification History is table",
              frappe.get_meta("Notification History").istable == 1)
    except Exception as e:
        check("Notification History is table", False, str(e))

    log_meta = frappe.get_meta("SMS Alert Log")
    ref_dt = log_meta.get_field("reference_doctype")
    check("Alert Log reference_doctype not reqd", not getattr(ref_dt, "reqd", 0))

    check(
        "Notification History field on Transport Case",
        bool(frappe.db.exists("Custom Field", {
            "dt": "Transport Case", "fieldname": "notification_history",
        })),
    )

    try:
        from frappe.utils.scheduler import is_scheduler_inactive
        inactive = is_scheduler_inactive()
        check("Scheduler check (is_scheduler_inactive)", True,
              "INACTIVE" if inactive else "active")
    except Exception as e:
        check("Scheduler check", False, str(e))

    try:
        hooks = frappe.get_hooks("scheduler_events") or {}
        check("scheduler_events has cron", bool(hooks.get("cron")))
        check("scheduler_events has daily", bool(hooks.get("daily")))
    except Exception as e:
        check("scheduler_events", False, str(e))

    try:
        doc_events = frappe.get_hooks("doc_events") or {}
        tc_events = doc_events.get("Transport Case", {})
        check("doc_events Transport Case on_update", "on_update" in tc_events)
    except Exception as e:
        check("doc_events", False, str(e))

    # check("Workspace IR Gateway", bool(frappe.db.exists("Workspace", "IR Gateway")))

    req_path = os.path.join(frappe.get_app_path("ir_gateway"), "..", "requirements.txt")
    if os.path.exists(req_path):
        with open(req_path, encoding="utf-8") as fh:
            check("requirements.txt has requests", "requests" in fh.read())
    else:
        check("requirements.txt exists", False)

    try:
        from ir_gateway.ir_gateway.alerts.template_renderer import render_template
        ctx = {
            "case_name": "TEST-001",
            "driver_name": "تست راننده",
            "destination": "بندرعباس",
            "planned_tonnage": 25,
        }
        template = frappe.db.get_value(
            "SMS Template", {"event_type": "driver_assigned", "is_active": 1}, "name"
        )
        if template:
            rendered = render_template(template, ctx)
            check("Template renders variables", "TEST-001" in (rendered or ""),
                  (rendered or "empty")[:50])
        else:
            check("Template for test", False, "no driver_assigned template")
    except Exception as e:
        check("Template rendering", False, str(e))
    lang = frappe.db.get_single_value("System Settings", "language")
    check("System language is fa", lang == "fa", str(lang))

    fa_csv = os.path.join(frappe.get_app_path("ir_gateway"), "translations", "fa.csv")
    check("fa.csv exists", os.path.exists(fa_csv), fa_csv)

    ws_ok = (
        frappe.db.exists("Workspace", "درگاه پیامک و هشدار")
        or frappe.db.exists("Workspace", "IR Gateway")
    )
    check("Workspace Persian/EN present", bool(ws_ok))
    print("\n" + "=" * 60)
    print("  Passed: {0}  |  Failed: {1}".format(len(passed), len(failed)))
    print("=" * 60)

    if failed:
        for item in failed:
            print("  FAILED -> {0}".format(item))
        print("\nPhase 9 NOT ready")
        raise Exception("Phase 9 verification failed: {0} failures".format(len(failed)))

    print("\nPhase 9 all checks passed!")
    return {"passed": len(passed), "failed": len(failed)}
PY
validate_py "${MOD}/verify_phase9.py"

# =============================================================================
step "STEP 21 — PRE-MIGRATE SYNTAX SWEEP"
# =============================================================================
cd "$APP_DIR"
PYBIN="${BENCH_DIR}/env/bin/python"
[[ -x "$PYBIN" ]] || PYBIN="$(command -v python3)"

while IFS= read -r -d '' f; do
  "$PYBIN" -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$f" \
    || err "Python syntax error in ${f}"
done < <(find "$APP_DIR" -name "*.py" -print0)
log "All Python files parse"

while IFS= read -r -d '' f; do
  "$PYBIN" -m json.tool "$f" >/dev/null || err "Invalid JSON in ${f}"
done < <(find "$APP_DIR" -name "*.json" -print0)
log "All JSON files valid"

# =============================================================================
step "STEP 22/23 — PIP + INSTALL-APP"
# =============================================================================
cd "$BENCH_DIR"
"${BENCH_DIR}/env/bin/python" -m pip install -q -e "${APP_DIR}" \
  || err "pip install of ${APP} failed"
log "Python package installed (editable)"

# ----------------------------------------------------------------------------- FIX-2 (a)
# Make sure `import ir_gateway` really works with the BENCH python, otherwise
# every HTTP request dies with ModuleNotFoundError: No module named 'ir_gateway'
info "checking python import of ${APP} ..."
if (cd /tmp && "${BENCH_DIR}/env/bin/python" -c "import ir_gateway, ir_gateway.hooks; print(ir_gateway.__file__)") >/tmp/ir_gateway_import.log 2>&1; then
  log "python import OK -> $(tail -1 /tmp/ir_gateway_import.log)"
else
  warn "editable install did not expose 'ir_gateway' — adding .pth fallback"
  SITE_PACKAGES="$("${BENCH_DIR}/env/bin/python" -c "import sysconfig; print(sysconfig.get_paths()['purelib'])")"
  printf '%s\n' "${APP_DIR}" > "${SITE_PACKAGES}/zzz_ir_gateway.pth"
  (cd /tmp && "${BENCH_DIR}/env/bin/python" -c "import ir_gateway, ir_gateway.hooks; print(ir_gateway.__file__)") \
    || err "Cannot import 'ir_gateway' with ${BENCH_DIR}/env/bin/python — see /tmp/ir_gateway_import.log"
  log "python import fixed via ${SITE_PACKAGES}/zzz_ir_gateway.pth"
fi

APPS_TXT="${BENCH_DIR}/sites/apps.txt"
if [[ -f "$APPS_TXT" ]]; then
  if ! grep -qx "$APP" "$APPS_TXT"; then
    # Ensure file ends with a newline BEFORE appending
    if [[ -s "$APPS_TXT" ]] && [[ "$(tail -c 1 "$APPS_TXT" | wc -l)" -eq 0 ]]; then
      echo "" >> "$APPS_TXT"
    fi
    echo "$APP" >> "$APPS_TXT"
  fi
else
  echo "$APP" > "$APPS_TXT"
fi

# ----------------------------------------------------------------------------- FIX-1
# `bench install-app` calls sync_fixtures() before the app tables exist, which
# produced the ugly "No module named 'frappe.core.doctype.sms_template'"
# tracebacks. Hide the fixtures for the duration of install-app; STEP 24's
# migrate imports them right after the tables are created.
stash_fixtures
if site_has_app "$SITE_NAME" "$APP"; then
  restore_fixtures
  log "${APP} already installed on ${SITE_NAME}"
else
  set +e
  bench --site "$SITE_NAME" install-app "$APP"
  INSTALL_RC=$?
  set -e
  restore_fixtures
  [[ "$INSTALL_RC" -eq 0 ]] || err "install-app ${APP} failed"
  log "${APP} installed (fixtures deferred to migrate — no tracebacks)"
fi

# =============================================================================
step "STEP 24 — MIGRATE + FIXTURES + CACHE"
# =============================================================================
bench --site "$SITE_NAME" migrate || err "migrate failed"
log "Migrate done"

bench --site "$SITE_NAME" execute frappe.utils.fixtures.sync_fixtures \
  --kwargs "{'app': 'ir_gateway'}" >/dev/null 2>&1 \
  && log "Fixtures synced" \
  || warn "Fixture sync returned non-zero (migrate may already have imported them)"

bench --site "$SITE_NAME" clear-cache >/dev/null 2>&1 || true
bench --site "$SITE_NAME" clear-website-cache >/dev/null 2>&1 || true
log "Cache cleared"

# =============================================================================
step "STEP 24b — DEFAULT LANGUAGE = فارسی (site + admin) + workspace title"
# =============================================================================
bench --site "$SITE_NAME" execute frappe.client.set_value --kwargs "{
  'doctype': 'System Settings',
  'name': 'System Settings',
  'fieldname': {
    'language': 'fa'
  }
}" >/dev/null 2>&1 || \
bench --site "$SITE_NAME" mariadb -e \
  "UPDATE \`tabDefaultValue\` SET defvalue='fa' WHERE defkey='language';" \
  >/dev/null 2>&1 || true

# روش استاندارد v15: نام، title و label ورک‌اسپیس استاندارد "IR Gateway" می‌ماند
# تا مسیر URL به صورت /app/ir-gateway ایجاد شود (بدون خطای 404).
# ترجمه عنوان سایدبار به "درگاه پیامک و هشدار" توسط fa.csv انجام می‌شود.
write_utf8 "${MOD}/setup_language.py" <<'PY'
import os
import shutil
import frappe

def apply_default_persian():
    ss = frappe.get_single("System Settings")
    ss.language = "fa"
    ss.flags.ignore_mandatory = True
    ss.save(ignore_permissions=True)

    if frappe.db.exists("User", "Administrator"):
        frappe.db.set_value("User", "Administrator", "language", "fa")

    for u in frappe.get_all("User", filters={"user_type": "System User", "enabled": 1}, pluck="name"):
        if not frappe.db.get_value("User", u, "language"):
            frappe.db.set_value("User", u, "language", "fa")

    # پاک‌سازی هرگونه ورک‌اسپیس تغییریافته با نام یا عنوان فارسی در دیتابیس
    # تا URL به /app/ir-gateway اشاره کند (بدون 404)
    for bad_name in ("درگاه پیامک و هشدار", "درگاه_پیامک_و_هشدار"):
        if frappe.db.exists("Workspace", bad_name):
            try:
                frappe.delete_doc("Workspace", bad_name, force=1, ignore_permissions=True, ignore_missing=True)
            except Exception:
                pass

    if frappe.db.exists("Workspace", "IR Gateway"):
        ws = frappe.get_doc("Workspace", "IR Gateway")
        ws.title = "IR Gateway"
        ws.label = "IR Gateway"
        ws.save(ignore_permissions=True)

    # حذف پوشه‌های ساختگی احتمالی روی دیسک
    extra_ws_dir = os.path.join(frappe.get_app_path("ir_gateway"), "workspace", "درگاه_پیامک_و_هشدار")
    if os.path.exists(extra_ws_dir):
        shutil.rmtree(extra_ws_dir, ignore_errors=True)

    frappe.clear_cache()
    frappe.db.commit()
    return {"ok": True, "language": "fa"}
PY
validate_py "${MOD}/setup_language.py"

bench --site "$SITE_NAME" execute ir_gateway.ir_gateway.setup_language.apply_default_persian \
  || warn "default language apply failed (non-fatal)"
bench --site "$SITE_NAME" clear-cache >/dev/null 2>&1 || true
log "Default language set to fa (Persian)"

# =============================================================================
step "STEP 25 — SCHEDULER CHECK"
# =============================================================================
SCHEDULER_STATUS="$(bench --site "$SITE_NAME" execute \
  frappe.utils.scheduler.is_scheduler_inactive 2>/dev/null | tail -1 | tr -d '[:space:]' || echo unknown)"
if [[ "$SCHEDULER_STATUS" == "True" ]]; then
  warn "Scheduler is INACTIVE. SLA checks + daily report will NOT run."
  warn "Enable with: bench --site ${SITE_NAME} enable-scheduler"
else
  log "Scheduler active (is_scheduler_inactive -> ${SCHEDULER_STATUS})"
fi

# =============================================================================
step "STEP 25b — RESTART BENCH SERVICES  (FIX: No module named 'ir_gateway')"
# =============================================================================
# The web / worker processes were started BEFORE `pip install -e`, so their
# sys.path has no idea the app exists -> every page shows
#   ModuleNotFoundError: No module named 'ir_gateway'
# Restarting them (and re-waiting for redis) makes the browser work again.
restart_bench_services

info "waiting for redis / site after restart ..."
if wait_for_redis_site 60; then
  log "redis/site ready again"
else
  warn "redis/site not ready after restart — check /tmp/bench-start-phase9.log"
fi

if command -v curl >/dev/null 2>&1; then
  info "HTTP smoke test on http://127.0.0.1:8000 ..."
  WEB_OK=0
  WEB_BODY=""
  for _i in $(seq 1 45); do
    WEB_BODY="$(curl -s -m 5 -H "Host: ${SITE_NAME}" http://127.0.0.1:8000/api/method/ping 2>/dev/null || true)"
    if echo "$WEB_BODY" | grep -q "pong"; then
      WEB_OK=1
      break
    fi
    sleep 2
  done
  if [[ "$WEB_OK" -eq 1 ]]; then
    log "web server OK (/api/method/ping -> pong)  → no ModuleNotFoundError"
  else
    warn "web server did not answer 'pong' yet."
    warn "last response: $(echo "$WEB_BODY" | head -c 200)"
    warn "tail /tmp/bench-start-phase9.log for details (dev server may still be booting)"
  fi
else
  warn "curl not found — skipping HTTP smoke test"
fi

# =============================================================================
step "STEP 26 — VERIFY"
# =============================================================================
bench --site "$SITE_NAME" execute ir_gateway.ir_gateway.verify_phase9.verify_phase9 \
  || err "Phase 9 verification FAILED (see output above)"
log "Verification passed"

# =============================================================================
step "STEP 27 — GIT COMMIT"
# =============================================================================
cd "$APP_DIR"
[[ -d .git ]] || git init -q
git config user.email >/dev/null 2>&1 || git config user.email "dev@example.com"
git config user.name  >/dev/null 2>&1 || git config user.name  "IR Gateway Setup"
if [[ ! -f .gitignore ]]; then
  cat > .gitignore <<'EOF'
*.pyc
__pycache__/
*.egg-info/
.venv/
node_modules/
EOF
fi
git add -A
if git diff --cached --quiet; then
  log "No git changes to commit (idempotent re-run)"
else
  git commit -q -m "$COMMIT_MSG"
  log "Committed: ${COMMIT_MSG}"
fi
git --no-pager log --oneline -1 || true

# =============================================================================
step "PHASE 9 COMPLETE"
# =============================================================================
cat <<EOF

${C_BOLD}${C_GREEN}════════════════════════════════════════════════════════════${C_NC}
${C_BOLD}  Phase 9 complete: ir_gateway (SMS / SLA / Alerts)${C_NC}
${C_BOLD}${C_GREEN}════════════════════════════════════════════════════════════${C_NC}

App:        ${APP}
Site:       ${SITE_NAME}
Path:       ${APP_DIR}
Adapters:   generic_http, kavenegar
Test mode:  ON by default  ([TEST→original] prefix)
Scheduler:  inactive=${SCHEDULER_STATUS}
            (is_scheduler_inactive — NEVER is_scheduler_active)

Fixed vs hybrid draft:
  • send_sms accepts recipient_name / recipient_role  (alerts actually send)
  • retry loop uses max_retry + retry_delay_seconds
  • Alert Log reference fields are optional (daily report / test SMS log)
  • Workspace path is module/workspace/ir_gateway/ir_gateway.json
  • History save uses ignore_validate_update_after_submit
  • Weighbridge/Bijak/Clearance fire only on status change

Fixed in this patched runner:
  • fixtures are imported by migrate (after tables exist) → no install tracebacks
  • python import check + .pth fallback + service restart → no ModuleNotFoundError

${C_BOLD}Browser checklist:${C_NC}
[ ] 1. Login as Administrator
[ ] 2. /app/sms-gateway-settings
       → test_mode ON, adapter dropdown, Test SMS Connection
[ ] 3. /app/sms-template → 7 templates
[ ] 4. /app/sla-stage-config → 6 stages (ثبت راننده = 2h)
[ ] 5. /app/sms-alert-log
[ ] 6. /app/ir-gateway workspace
[ ] 7. Transport Case → «تاریخچه اعلان‌ها»
[ ] 8. Console:
       frappe.call({method:'ir_gateway.ir_gateway.api.sms_api.list_sms_adapters'})
[ ] 9. bench --site ${SITE_NAME} execute frappe.utils.scheduler.is_scheduler_inactive
[ ] 10. git -C ${APP_DIR} log --oneline -1

${C_BOLD}If scheduler inactive:${C_NC}
  bench --site ${SITE_NAME} enable-scheduler

${C_BOLD}Production SMS:${C_NC}
  1) adapter + credentials
  2) test_number, keep test_mode=1 until validated
  3) enabled=1
  4) disable test_mode only when ready

${C_BOLD}New SMS provider:${C_NC}
  Create ir_gateway/ir_gateway/sms/adapters/my_provider.py
  subclass BaseSMSAdapter + @register_adapter
  Done.

EOF
log "setup_phase9.sh finished successfully"
