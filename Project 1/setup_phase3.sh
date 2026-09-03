#!/usr/bin/env bash
# =============================================================================
# setup_phase3.sh  —  Roles fixture + transport_ir scaffold + Workspace + BACKLOG
# ERPNext v15 / Frappe v15
#
# قوانین:
#   File-First | بدون drop | بدون سؤال تعاملی
#   بدون bench console | بدون install.py | بدون after_install فعال
#   Workspace از طریق JSON (نه UI) — idempotent
#   کاربران در این فاز ساخته نمی‌شوند (فاز جدا)
#
# استفاده:
#   nano ~/setup_phase3.sh
#   chmod +x ~/setup_phase3.sh
#   ~/setup_phase3.sh
# =============================================================================
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 PYTHONIOENCODING=utf-8

SITE_NAME="transport-dev.local"
BENCH_DIR="${HOME}/frappe-bench"
BASE_APP="ir_base"
APP_NAME="transport_ir"
MODULE_NAME="Iran Transport"
MODULE_DIR="iran_transport"

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
site_has_app() { bench --site "$1" list-apps 2>/dev/null | grep -qE "^${2}([[:space:]]|$)"; }

[[ -d "$BENCH_DIR" ]] || err "Bench not found: $BENCH_DIR"
cd "$BENCH_DIR"

# =============================================================================
# 0) preflight — بررسی فاز ۲ + bench start
# =============================================================================
step "0) preflight"
[[ -d "apps/${BASE_APP}" ]] || err "ir_base not found — phase 2 incomplete"
[[ -d "apps/${BASE_APP}/${BASE_APP}/doctype" ]] && err "wrong 2-layer folder exists in ir_base (phase 2 bug)"

# bench use — درس مهمی که از فاز ۲ یاد گرفتیم
bench use "$SITE_NAME" 2>/dev/null || warn "bench use failed (continue with --site)"

# bench start در پس‌زمینه
if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "bench already running — skip bench start"
else
  nohup bench start >>/tmp/bench-start-phase3.log 2>&1 &
  echo $! >/tmp/bench-start-phase3.pid
  log "bench start pid=$(cat /tmp/bench-start-phase3.pid) log=/tmp/bench-start-phase3.log"
  sleep 12
fi

# =============================================================================
# 1) ir_base — fixtures/role.json (12 نقش custom)
# =============================================================================
step "1) ir_base fixtures/role.json"

mkdir -p "apps/${BASE_APP}/${BASE_APP}/fixtures"

write_utf8 "apps/${BASE_APP}/${BASE_APP}/fixtures/role.json" << 'EOF'
[
  {
    "doctype": "Role",
    "name": "CEO",
    "role_name": "CEO",
    "desk_access": 1,
    "is_custom": 1,
    "disabled": 0
  },
  {
    "doctype": "Role",
    "name": "Financial Manager",
    "role_name": "Financial Manager",
    "desk_access": 1,
    "is_custom": 1,
    "disabled": 0
  },
  {
    "doctype": "Role",
    "name": "Finance Supervisor",
    "role_name": "Finance Supervisor",
    "desk_access": 1,
    "is_custom": 1,
    "disabled": 0
  },
  {
    "doctype": "Role",
    "name": "Finance User",
    "role_name": "Finance User",
    "desk_access": 1,
    "is_custom": 1,
    "disabled": 0
  },
  {
    "doctype": "Role",
    "name": "Legal Reviewer",
    "role_name": "Legal Reviewer",
    "desk_access": 1,
    "is_custom": 1,
    "disabled": 0
  },
  {
    "doctype": "Role",
    "name": "Treasury User",
    "role_name": "Treasury User",
    "desk_access": 1,
    "is_custom": 1,
    "disabled": 0
  },
  {
    "doctype": "Role",
    "name": "Receivables User",
    "role_name": "Receivables User",
    "desk_access": 1,
    "is_custom": 1,
    "disabled": 0
  },
  {
    "doctype": "Role",
    "name": "Transport Supervisor",
    "role_name": "Transport Supervisor",
    "desk_access": 1,
    "is_custom": 1,
    "disabled": 0
  },
  {
    "doctype": "Role",
    "name": "Transport User - Purchase",
    "role_name": "Transport User - Purchase",
    "desk_access": 1,
    "is_custom": 1,
    "disabled": 0
  },
  {
    "doctype": "Role",
    "name": "Transport User - Sales",
    "role_name": "Transport User - Sales",
    "desk_access": 1,
    "is_custom": 1,
    "disabled": 0
  },
  {
    "doctype": "Role",
    "name": "Customs Officer",
    "role_name": "Customs Officer",
    "desk_access": 1,
    "is_custom": 1,
    "disabled": 0
  },
  {
    "doctype": "Role",
    "name": "Document Signer",
    "role_name": "Document Signer",
    "desk_access": 1,
    "is_custom": 1,
    "disabled": 0
  }
]
EOF

python3 -m json.tool "apps/${BASE_APP}/${BASE_APP}/fixtures/role.json" >/dev/null && log "role.json valid" || err "role.json invalid"

# =============================================================================
# 2) ir_base — hooks.py fixtures hook
# =============================================================================
step "2) ir_base hooks.py fixtures hook"

BHOOKS="apps/${BASE_APP}/${BASE_APP}/hooks.py"
[[ -f "$BHOOKS" ]] || err "missing $BHOOKS"

if grep -q "IR_BASE_FIXTURES_START" "$BHOOKS"; then
  warn "fixtures hook already present — skip"
else
cat >> "$BHOOKS" << 'EOF'

# --- IR_BASE_FIXTURES_START ---
fixtures = [
    {
        "dt": "Role",
        "filters": [
            [
                "name",
                "in",
                [
                    "CEO",
                    "Financial Manager",
                    "Finance Supervisor",
                    "Finance User",
                    "Legal Reviewer",
                    "Treasury User",
                    "Receivables User",
                    "Transport Supervisor",
                    "Transport User - Purchase",
                    "Transport User - Sales",
                    "Customs Officer",
                    "Document Signer"
                ]
            ]
        ]
    }
]
# --- IR_BASE_FIXTURES_END ---
EOF
  log "fixtures hook appended to ir_base/hooks.py"
fi

# =============================================================================
# 3) scaffold transport_ir (اگر نیست)
# =============================================================================
step "3) scaffold ${APP_NAME}"

if [[ ! -d "apps/${APP_NAME}" ]]; then
  if ! timeout 120 bash -c 'printf "%s\n" \
      "Transport IR" \
      "Iran transport, customs and settlement operations" \
      "IR Base Contributors" \
      "dev@example.com" \
      "mit" \
      "n" | bench new-app transport_ir'; then
    err "bench new-app transport_ir failed"
  fi
  log "new-app transport_ir done"
else
  warn "apps/${APP_NAME} exists — skip new-app, Force Replace only"
fi

PKG="apps/${APP_NAME}/${APP_NAME}"
THOOKS="${PKG}/hooks.py"
[[ -f "$THOOKS" ]] || err "missing $THOOKS"

# پاکسازی انحراف‌های قبلی
rm -f "${PKG}/install.py" "${PKG}/import_doctype.py" || true

# =============================================================================
# 4) transport_ir — hooks.py (required_apps) + modules.txt
# =============================================================================
step "4) transport_ir hooks.py + modules.txt"

# کامنت کردن after_install فعال
sed -i -E 's/^([[:space:]]*after_install[[:space:]]*=)/# \1/' "$THOOKS" || true

# required_apps
if grep -qE '^[[:space:]]*required_apps[[:space:]]*=' "$THOOKS"; then
  sed -i -E 's|^[[:space:]]*required_apps[[:space:]]*=.*|required_apps = ["frappe", "erpnext", "ir_base"]|' "$THOOKS"
elif grep -qE '^app_version[[:space:]]*=' "$THOOKS"; then
  sed -i -E '/^app_version[[:space:]]*=/a required_apps = ["frappe", "erpnext", "ir_base"]' "$THOOKS"
elif grep -qE '^app_license[[:space:]]*=' "$THOOKS"; then
  sed -i -E '/^app_license[[:space:]]*=/a required_apps = ["frappe", "erpnext", "ir_base"]' "$THOOKS"
else
  printf '\nrequired_apps = ["frappe", "erpnext", "ir_base"]\n' >> "$THOOKS"
fi

# modules.txt
printf '%s\n' "$MODULE_NAME" > "${PKG}/modules.txt"
log "modules.txt -> ${MODULE_NAME}"

echo "----- transport_ir hooks check -----"
grep -nE 'required_apps|^[[:space:]]*after_install' "$THOOKS" || true
echo "------------------------------------"

# =============================================================================
# 5) module folder skeleton
# =============================================================================
step "5) module folder ${MODULE_DIR}"

mkdir -p "${PKG}/${MODULE_DIR}/doctype"
mkdir -p "${PKG}/${MODULE_DIR}/workspace"

write_utf8 "${PKG}/${MODULE_DIR}/__init__.py" << 'EOF'
# Iran Transport module
EOF

write_utf8 "${PKG}/${MODULE_DIR}/doctype/__init__.py" << 'EOF'
# DocTypes package
EOF

write_utf8 "${PKG}/${MODULE_DIR}/workspace/__init__.py" << 'EOF'
# Workspaces
EOF

# =============================================================================
# 6) Workspace خالی (File-First — نه UI)
# مسیر: transport_ir/iran_transport/workspace/iran_transport/iran_transport.json
# =============================================================================
step "6) empty Workspace (File-First)"

WS_DIR="${PKG}/${MODULE_DIR}/workspace/iran_transport"
mkdir -p "$WS_DIR"

write_utf8 "${WS_DIR}/__init__.py" << 'EOF'
# Workspace package
EOF

write_utf8 "${WS_DIR}/iran_transport.json" << 'EOF'
{
  "charts": [],
  "content": "[]",
  "creation": "2025-01-01 00:00:00.000000",
  "doctype": "Workspace",
  "for_user": "",
  "hide_custom": 0,
  "icon": "truck",
  "is_default": 0,
  "is_standard": 1,
  "label": "Iran Transport",
  "links": [],
  "modified": "2025-01-01 00:00:00.000000",
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
  "title": "Iran Transport"
}
EOF

python3 -m json.tool "${WS_DIR}/iran_transport.json" >/dev/null && log "workspace.json valid" || err "workspace.json invalid"

# =============================================================================
# 7) BACKLOG.md
# =============================================================================
step "7) BACKLOG.md"

write_utf8 "apps/${APP_NAME}/BACKLOG.md" << 'EOF'
# BACKLOG — transport_ir

## Out of core for now
- Chat / organizational messaging
- Interactive transport map (future slot only)
- External BI / Power BI
- Generic form builder
- Generic report builder
- Advanced dashboard builder
- Full archive / OCR / AI features

## Explicitly out
- WhatsApp: removed due to weak/impractical API fit for this project

## Later via extension points only
- Additional notification channels (Email/Telegram/...) through Channel Adapter
- Additional accounting/ERP systems through External System + Integration Log
- Multi-shipment per Trade Case (trade_case link is non-unique by design)
- Smarter external validation/services through hooks/services (no core rewrite)

## Golden rules
1. Deferred features must not block future design.
2. External communication only via adapter/service.
3. No field/relation locks that prevent future growth.
EOF

# =============================================================================
# 8) install-app + migrate
# =============================================================================
step "8) install-app + migrate"

cd "$BENCH_DIR"

if ! site_has_app "$SITE_NAME" "$APP_NAME"; then
  bench --site "$SITE_NAME" install-app "$APP_NAME"
else
  warn "${APP_NAME} already installed — migrate only"
fi

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache
log "migrate + clear-cache done"

# =============================================================================
# 9) verification
# =============================================================================
step "9) verification"

echo "--- list-apps ---"
bench --site "$SITE_NAME" list-apps

echo "--- custom roles count (expect 12) ---"
bench --site "$SITE_NAME" execute frappe.db.count --args '["Role", {"is_custom": 1}]' || true

echo "--- sample role ---"
bench --site "$SITE_NAME" execute frappe.db.exists --args '["Role", "Transport User - Purchase"]' || true

echo "--- module def ---"
bench --site "$SITE_NAME" execute frappe.db.exists --args '["Module Def", "Iran Transport"]' || true

echo "--- workspace ---"
bench --site "$SITE_NAME" execute frappe.db.exists --args '["Workspace", "Iran Transport"]' || true

# =============================================================================
# 10) git commit — هر دو اپ
# =============================================================================
step "10) git commit"

# ir_base
cd "apps/${BASE_APP}"
if [[ ! -d .git ]]; then git init; fi
git config user.email >/dev/null 2>&1 || git config user.email "dev@example.com"
git config user.name  >/dev/null 2>&1 || git config user.name "IR Base Contributors"
git add -A
git commit -m "phase 3: add 12 custom roles fixture" || warn "ir_base: nothing to commit"
log "ir_base committed"

# transport_ir
cd "../${APP_NAME}"
if [[ ! -d .git ]]; then git init; fi
git config user.email >/dev/null 2>&1 || git config user.email "dev@example.com"
git config user.name  >/dev/null 2>&1 || git config user.name "IR Base Contributors"
git add -A
git commit -m "phase 3: scaffold transport_ir + empty workspace + backlog" || warn "transport_ir: nothing to commit"
log "transport_ir committed"

cd "$BENCH_DIR"

# =============================================================================
step "DONE"
cat <<FINAL

${GREEN}فاز ۳ تمام شد.${NC}

Site:       http://${SITE_NAME}:8000/app
Workspace:  http://${SITE_NAME}:8000/app/iran-transport
Roles:      12 custom roles in ir_base fixtures

ساختار نهایی:
apps/ir_base/
  ir_base/fixtures/role.json         (12 roles)
  ir_base/hooks.py                   (fixtures hook appended)

apps/transport_ir/
  BACKLOG.md
  transport_ir/hooks.py              (required_apps includes ir_base)
  transport_ir/iran_transport/
    __init__.py
    doctype/__init__.py
    workspace/iran_transport/iran_transport.json

تذکر مهم:
  - کاربران واقعی (فائزه، احسان و...) در این فاز ساخته نشدند
  - ساخت کاربران در فاز مدیریت کاربران (فاز جداگانه) انجام می‌شود
  - داده‌های کاربران نباید در Git باشند

Checklist:
  [ ] list-apps: frappe, erpnext, ir_base, transport_ir
  [ ] custom roles count = 12
  [ ] Role "Transport User - Purchase" exists
  [ ] Module Def "Iran Transport" exists
  [ ] Workspace "Iran Transport" exists (URL: /app/iran-transport)
  [ ] BACKLOG.md in apps/transport_ir/
  [ ] No operational DocType created
  [ ] Two git commits (ir_base + transport_ir)

FINAL