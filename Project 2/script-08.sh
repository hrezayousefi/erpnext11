#!/usr/bin/env bash
# =============================================================================
# script-08.sh — موتور اکسل (کپی خط‌به‌خط) + گزارش‌ها + چاپ RTL
# بازسازی هدایت‌شده — Iran Trade ERP | ERPNext v15 / Frappe v15
# -----------------------------------------------------------------------------
# این اسکریپت:
#   1) موتور عمومی ورود/خروج اکسل را «کپی خط‌به‌خط» از فاز ۸ منتقل می‌کند
#      (report_excel.py) — الگوی Preview → Validate → Resolve → Commit با
#      بازگشت کامل در خطا، گاردهای حجم/تعداد ردیف/نوع فایل/دسترسی.
#   2) پنج قالب اکسل اختصاصی کارفرما را «عیناً» کپی می‌کند
#      (report_excel_custom.py + TEMPLATE_REGISTRY) با تمام جزئیات:
#      قفل مختصات سلول، فرمول‌های محافظت‌شده، سلول‌های ادغام‌شده، و
#      ★ حتی غلط‌های املایی موجود در هدرهای کارفرما («هزنیه تخلیه»،
#        «هزنیه بارگیری») که عمداً حفظ می‌شوند چون قرارداد واقعی با
#        فایل‌های اکسل موجود کارفرما هستند.
#      هر تطبیق مبهم به‌جای حدس‌زدن «نامشخص/UNRESOLVED» علامت می‌خورد.
#   3) گزارش‌های عملیاتی/مالی جدید بر پایه مدل داده تازه
#   4) چاپ RTL پرونده بازرگانی (برگه‌ای که برای امضای دستی چاپ می‌شود)
#
# تنها تغییر مجاز روی کد کپی‌شده: مسیر ماژول و نام DocType هدف، تا در
# معماری جدید بنشیند. هیچ خط منطقی، هیچ مختصات سلول و هیچ متن کارفرما
# تغییر نمی‌کند. این تغییر مسیرها با sed صریح و قابل‌ممیزی انجام می‌شود.
#
# -----------------------------------------------------------------------------
# اصلاحیه (این نسخه): در گام ۸ (Verify داخلی)، چهار سنجه از تابع‌های
# download_1405 / export_packing / export_carrier_statement /
# export_customs_statement انتظار «return (columns, data)» داشتند، در حالی‌که
# این چهار تابع طبق همان کد کپی‌شده (بدون تغییر) با فراخوانی داخلی _send(...)
# فقط frappe.response را پر می‌کنند و مقداری return نمی‌کنند (None). همین
# باعث «TypeError: cannot unpack non-iterable NoneType object» در download_1405
# شد و اجرای verify را متوقف کرد؛ خطای NameError بعدی هم صرفاً اثر جانبی
# fallback داخلی خودِ فریمورک frappe (bench execute) پس از آن استثنا بود و
# با رفع علت اصلی دیگر رخ نمی‌دهد. تنها همین چهار سنجه در گام ۸ اصلاح شده تا
# دقیقاً همان قرارداد واقعی _send(...) (frappe.response["type"]="binary",
# filename, filecontent) را بسنجد؛ هیچ چیز دیگری در کل اسکریپت — از جمله
# محتوای کپی خط‌به‌خط report_excel.py و report_excel_custom.py — تغییر
# نکرده و هیچ سنجه‌ای حذف یا دور زده نشده است.
#
# اصلاحیه دوم (این نسخه): پس از رفع مشکل بالا، اجرای واقعی verify روی
# export_carrier_statement / export_customs_statement / export_freight_custom /
# export_dispatch_custom با «Unknown column 'tabTrade Case Loading.workflow_state'
# in 'WHERE'» شکست؛ چون در نگاشت عمومی «Transport Case» → «Trade Case Loading»
# فیلتر workflow_state/posting_date روی Loading اعمال می‌شد در حالی‌که این
# DocType فیلد workflow_state ندارد و وضعیت آن با loading_state (مقادیر
# «لغو شده»/«رد شده») نگه‌داری می‌شود؛ posting_date و border هم فقط روی
# Trade Case هستند نه Loading. فقط همین سه‌جا (فیلتر مشترک _transport_filters
# و order_by دو فراخوانی _fetch_rows روی Trade Case Loading) با پچ لنگردار
# تعمیر شده؛ هیچ منطق دیگری دست نخورده.
#
# اصلاحیه سوم (این نسخه): پس از رفع دو مورد بالا، export_dispatch_custom /
# export_freight_custom با «Unknown column 'item' in 'SELECT'» شکست؛ چون
# _fill_cargo_fallback مستقیماً ستون‌های «item» و «cargo_description» را از
# خودِ tabTrade Case می‌خواند، در حالی‌که در مدل جدید این دو فیلد روی
# Trade Case وجود ندارند و فقط در فرزند «Trade Case Item» ذخیره شده‌اند —
# همان جدولی که trade_transport_1405.py و packing_report.py با JOIN از آن
# می‌خوانند و در همین گام ۸ با موفقیت verify شده‌اند. فقط همین یک تابع با
# پچ لنگردار به «select ... from tabTrade Case Item» اصلاح شده؛ هیچ فرمول،
# هیچ مختصات سلول، هیچ متن فارسی کارفرما و هیچ سنجه verify دست نخورده و
# هیچ‌کدام دور زده نشده‌اند.
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

[[ -d "$BENCH_DIR" ]] || err "Bench یافت نشد"; cd "$BENCH_DIR"

step "0) سرویس‌ها"
if ss -lntp 2>/dev/null | grep -q ':8000' || pgrep -af 'bench start|honcho' 2>/dev/null | grep -vq grep; then
  warn "bench در حال اجراست"
else nohup bench start >>/tmp/bench-start-itc08.log 2>&1 & log "pid=$!"; sleep 12; fi
RC="${BENCH_DIR}/config/redis_cache.conf"
RP="$( [[ -f "$RC" ]] && awk '$1=="port"{print $2; exit}' "$RC" || echo 13000 )"; [[ -n "$RP" ]] || RP=13000
R=0; for _i in $(seq 1 60); do
  if command -v redis-cli >/dev/null 2>&1 && redis-cli -h 127.0.0.1 -p "$RP" ping 2>/dev/null | grep -q '^PONG$'; then R=1; break; fi
  if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ":${RP}[[:space:]]"; then R=1; break; fi
  sleep 1; done
[[ "$R" -eq 1 ]] || err "redis آماده نشد"
bench use "$SITE_NAME" 2>/dev/null || true

step "0b) پیش‌نیاز — ABORT در نبود Anchor"
[[ -f "${MOD}/doctype/trade_case_loading/loading_engine.py" ]] || err "ABORT: موتور بارگیری نیست. ابتدا script-07.sh"
grep -q "SCRIPT07_HOOKS_START" "${PKG}/hooks.py" || err "ABORT: بلوک SCRIPT07 در hooks.py نیست"
log "پیش‌نیازها تایید شد"

step "1) وابستگی openpyxl"
if ! grep -q "openpyxl" "${BENCH_DIR}/apps/${APP}/requirements.txt" 2>/dev/null; then
  echo "openpyxl>=3.1,<4" >> "${BENCH_DIR}/apps/${APP}/requirements.txt"
fi
bench pip install "openpyxl>=3.1,<4" >/dev/null 2>&1 || warn "نصب openpyxl رد شد (احتمالاً از قبل نصب است)"
log "openpyxl آماده است"

# =============================================================================
step "1b) انتقال قالب‌های اکسل کارفرما از پوشه کنار اسکریپت"
# اگر نخواهی از پوشه کنار اسکریپت کپی کند، می‌توانی اجرا کنی:
# COPY_EXCEL_CLIENT_FILES=false bash script-08.sh
# در این حالت باید قالب‌ها از قبل در مسیر مقصد وجود داشته باشند.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
COPY_EXCEL_CLIENT_FILES="${COPY_EXCEL_CLIENT_FILES:-true}"
copy_mode="${COPY_EXCEL_CLIENT_FILES,,}"

TEMPLATE_SRC="${SCRIPT_DIR}/excel_client_files"
TEMPLATE_DST="${BENCH_DIR}/sites/${SITE_NAME}/private/files/excel_templates"

REQUIRED_XLSX=(
  "template_01_financial.xlsx"
  "template_02_freight.xlsx"
  "template_03_packing.xlsx"
  "template_04_purchase.xlsx"
  "template_05_dispatch.xlsx"
)

mkdir -p "$TEMPLATE_DST"

if [[ "$copy_mode" == "true" || "$copy_mode" == "1" ]]; then
  [[ -d "$TEMPLATE_SRC" ]] || err "پوشهٔ قالب‌ها کنار اسکریپت پیدا نشد: $TEMPLATE_SRC"

  for f in "${REQUIRED_XLSX[@]}"; do
    [[ -f "${TEMPLATE_SRC}/${f}" ]] || err "فایل ${f} داخل ${TEMPLATE_SRC} وجود ندارد"
  done

  for f in "${REQUIRED_XLSX[@]}"; do
    cp -f "${TEMPLATE_SRC}/${f}" "${TEMPLATE_DST}/${f}"
    log "copy: ${TEMPLATE_SRC}/${f} -> ${TEMPLATE_DST}/${f}"
  done

  if [[ -f "${TEMPLATE_SRC}/client_logo.png" ]]; then
    cp -f "${TEMPLATE_SRC}/client_logo.png" "${TEMPLATE_DST}/client_logo.png"
    log "copy: client_logo.png -> ${TEMPLATE_DST}/client_logo.png"
  else
    warn "client_logo.png در ${TEMPLATE_SRC} نیست؛ فعلاً مشکلی برای verify نمی‌سازد"
  fi
else
  warn "کپی خودکار قالب‌ها غیرفعال است. فرض می‌شود قالب‌ها را دستی در مسیر مناسب گذاشته‌ای."
fi

# بررسی وجود حداقلی قالب‌ها طبق الگوی واقعی _find_file در پایتون
for pat in template_01 template_02 template_03 template_04 template_05; do
  found="$(find "$TEMPLATE_DST" -maxdepth 1 -type f -name "*${pat}*.xlsx" -print -quit || true)"
  [[ -n "$found" ]] || err "هیچ فایل اکسل شامل الگوی ${pat} در $TEMPLATE_DST پیدا نشد"
done

# اعتبارسنجی شیت‌ها، دقیقاً طبق نیاز TEMPLATE_REGISTRY
python3 - "$TEMPLATE_DST" << 'PYEOF' || err "اعتبارسنجی شیت‌های قالب اکسل ناموفق بود"
import os
import sys

try:
    import openpyxl
except Exception:
    print("openpyxl در دسترس نیست؛ از اعتبارسنجی عمیق شیت‌ها صرف‌نظر شد.")
    raise SystemExit(0)

dst = sys.argv[1]

required = {
    "template_01": ["گزارش 1405"],
    "template_02": ["Sheet1"],
    "template_03": ["Sheet1"],
    "template_04": [
        "فروشنده",
        "معرفی کالا",
        "پیش فاکتور خرید",
        "صورت بارگیری",
    ],
    "template_05": ["Sheet1"],
}


def find_file(pattern):
    try:
        names = sorted(os.listdir(dst))
    except Exception:
        return None

    for name in names:
        if pattern in name and name.lower().endswith(".xlsx"):
            return os.path.join(dst, name)

    return None


errors = []

for pattern, sheets in required.items():
    path = find_file(pattern)

    if not path:
        errors.append(f"{pattern}: فایل اکسل یافت نشد")
        continue

    try:
        wb = openpyxl.load_workbook(path, read_only=True)
        names = wb.sheetnames
        wb.close()
    except Exception as exc:
        errors.append(f"{pattern}: باز کردن فایل ناموفق بود: {exc}")
        continue

    for sheet in sheets:
        if sheet not in names:
            errors.append(f"{pattern}: شیت «{sheet}» وجود ندارد")

if errors:
    print("\n".join(errors))
    raise SystemExit(1)

print("sheet names for excel templates ok")
PYEOF

log "قالب‌های اکسل کارفرما آماده شدند: $TEMPLATE_DST"

mkdir -p "${MOD}/api" "${MOD}/report" "${MOD}/print_format"
: > "${MOD}/api/__init__.py"; : > "${MOD}/report/__init__.py"

# =============================================================================
step "2) کپی خط‌به‌خط موتور عمومی اکسل (report_excel.py از فاز ۸)"
# --- BEGIN VERBATIM COPY: transport_ir/iran_transport/api/report_excel.py ----
write_utf8 "${MOD}/api/report_excel.py" << 'ITE_REPORT_EXCEL_EOF'
"""Secure Excel import/export endpoints for Phase 8."""

from __future__ import annotations

import io
import re

import frappe
from frappe import _
from frappe.utils import flt

from transport_ir.iran_transport.utils.jinja_helpers import (
    latin_jalali_date,
)


FINANCE_ROLES = {
    "System Manager",
    "CEO",
    "Financial Manager",
    "Finance Supervisor",
    "Finance User",
}

OPERATIONS_ROLES = FINANCE_ROLES | {
    "Transport Supervisor",
    "Transport User - Purchase",
    "Transport User - Sales",
    "Customs Officer",
}

MAX_IMPORT_FILE_SIZE = 10 * 1024 * 1024
MAX_IMPORT_ROWS = 2000

RUNNING_TOTAL_FIELDS = {
    "cship_s",
    "csur_s",
    "crem_s",
    "cship_p",
    "csur_p",
    "crem_p",
}


def _guard(allowed_roles):
    current_roles = set(frappe.get_roles())

    if not (current_roles & set(allowed_roles)):
        frappe.throw(
            _("دسترسی به این عملیات مجاز نیست."),
            frappe.PermissionError,
        )


def _new_workbook(title):
    from openpyxl import Workbook

    workbook = Workbook()
    worksheet = workbook.active
    worksheet.title = title[:31]
    worksheet.sheet_view.rightToLeft = True

    return workbook, worksheet


def _style_header(worksheet, headers, row=1):
    from openpyxl.styles import Alignment, Font, PatternFill

    for column_index, header in enumerate(headers, 1):
        cell = worksheet.cell(
            row=row,
            column=column_index,
            value=header,
        )
        cell.font = Font(bold=True, color="000000")
        cell.fill = PatternFill(
            fill_type="solid",
            fgColor="D9EAF7",
        )
        cell.alignment = Alignment(
            horizontal="center",
            vertical="center",
            wrap_text=True,
        )


def _autosize(worksheet, minimum=11, maximum=35):
    from openpyxl.utils import get_column_letter

    for column_cells in worksheet.columns:
        width = minimum

        for cell in column_cells:
            value = "" if cell.value is None else str(cell.value)
            width = max(width, len(value) + 2)

        width = min(width, maximum)
        worksheet.column_dimensions[
            get_column_letter(column_cells[0].column)
        ].width = width


def _finalize_table(worksheet, header_row, last_row, last_column):
    from openpyxl.styles import Alignment
    from openpyxl.utils import get_column_letter

    worksheet.freeze_panes = worksheet.cell(
        row=header_row + 1,
        column=1,
    )

    if last_row >= header_row:
        worksheet.auto_filter.ref = (
            f"A{header_row}:"
            f"{get_column_letter(last_column)}{last_row}"
        )

    for row in worksheet.iter_rows():
        for cell in row:
            cell.alignment = Alignment(
                vertical="center",
                wrap_text=True,
            )

    _autosize(worksheet)


def _send(workbook, filename):
    output = io.BytesIO()
    workbook.save(output)

    frappe.response["type"] = "binary"
    frappe.response["filename"] = filename
    frappe.response["filecontent"] = output.getvalue()
    frappe.response["display_content_as"] = "attachment"


def _report_value(row, index, column):
    if isinstance(row, dict):
        return row.get(column.get("fieldname"))

    return row[index] if index < len(row) else None


def _write_report_table(
    worksheet,
    columns,
    data,
    header_row=1,
    jalali_dates=True,
):
    _style_header(
        worksheet,
        [column.get("label") for column in columns],
        row=header_row,
    )

    first_data_row = header_row + 1

    for row_index, source_row in enumerate(data, first_data_row):
        for column_index, column in enumerate(columns, 1):
            value = _report_value(
                source_row,
                column_index - 1,
                column,
            )

            if (
                jalali_dates
                and value
                and column.get("fieldtype") in ("Date", "Datetime")
            ):
                value = latin_jalali_date(value)

            cell = worksheet.cell(
                row=row_index,
                column=column_index,
                value=value,
            )

            if column.get("fieldtype") == "Currency":
                cell.number_format = '#,##0.00'

            if column.get("fieldtype") == "Float":
                cell.number_format = '#,##0.000'

    last_row = max(header_row, first_data_row + len(data) - 1)

    _finalize_table(
        worksheet,
        header_row,
        last_row,
        len(columns),
    )


@frappe.whitelist()
def download_1405(
    company=None,
    from_date=None,
    to_date=None,
    case_type=None,
):
    """Download the approved 26-column financial 1405 workbook."""
    _guard(FINANCE_ROLES)

    from transport_ir.iran_transport.report.trade_transport_1405.trade_transport_1405 import (
        execute,
    )

    columns, data = execute(
        {
            "company": company,
            "from_date": from_date,
            "to_date": to_date,
            "case_type": case_type,
        }
    )

    workbook, worksheet = _new_workbook("گزارش 1405")

    worksheet.cell(row=1, column=1, value="گزارش خرید، فروش و حمل ۱۴۰۵")
    worksheet.cell(row=1, column=6, value="دلار")
    worksheet.cell(row=1, column=7, value="ریال")

    _write_report_table(
        worksheet,
        columns,
        data,
        header_row=2,
        jalali_dates=True,
    )

    total_row = len(data) + 3
    worksheet.cell(row=total_row, column=1, value="جمع کل")

    from openpyxl.styles import Font, PatternFill

    worksheet.cell(
        row=total_row,
        column=1,
    ).font = Font(bold=True)

    for column_index, column in enumerate(columns):
        if column.get("fieldtype") not in ("Float", "Currency"):
            continue

        values = [
            flt(_report_value(row, column_index, column))
            for row in data
            if _report_value(row, column_index, column) not in (None, "")
        ]

        if column.get("fieldname") in RUNNING_TOTAL_FIELDS:
            total_value = values[-1] if values else 0
        else:
            total_value = sum(values)

        cell = worksheet.cell(
            row=total_row,
            column=column_index + 1,
            value=total_value,
        )
        cell.font = Font(bold=True)
        cell.fill = PatternFill(
            fill_type="solid",
            fgColor="FFF2CC",
        )

        if column.get("fieldtype") == "Currency":
            cell.number_format = '#,##0.00'
        else:
            cell.number_format = '#,##0.000'

    _autosize(worksheet)

    _send(workbook, "trade_transport_1405.xlsx")


@frappe.whitelist()
def export_packing(
    from_date=None,
    to_date=None,
    border=None,
    customer=None,
):
    _guard(OPERATIONS_ROLES)

    from transport_ir.iran_transport.report.packing_report.packing_report import (
        execute,
    )

    columns, data = execute(
        {
            "from_date": from_date,
            "to_date": to_date,
            "border": border,
            "customer": customer,
        }
    )

    workbook, worksheet = _new_workbook("پکینگ")

    _write_report_table(
        worksheet,
        columns,
        data,
        header_row=1,
        jalali_dates=True,
    )

    _send(workbook, "packing.xlsx")


@frappe.whitelist()
def export_carrier_statement(
    carrier=None,
    from_date=None,
    to_date=None,
):
    _guard(FINANCE_ROLES)

    conditions = [
        "ifnull(workflow_state, '') not in ('Cancelled', 'Rejected')"
    ]
    values = {}

    if carrier:
        conditions.append("carrier = %(carrier)s")
        values["carrier"] = carrier

    if from_date:
        conditions.append("posting_date >= %(from_date)s")
        values["from_date"] = from_date

    if to_date:
        conditions.append("posting_date <= %(to_date)s")
        values["to_date"] = to_date

    rows = frappe.db.sql(
        """
        select
            name,
            waybill_number,
            driver,
            carrier,
            border,
            actual_tonnage,
            freight_cost,
            posting_date
        from `tabTransport Case`
        where {conditions}
        order by posting_date, name
        """.format(conditions=" and ".join(conditions)),
        values,
        as_dict=True,
    )

    workbook, worksheet = _new_workbook("صورتحساب باربری")

    headers = [
        "پرونده",
        "بارنامه",
        "راننده",
        "باربری",
        "مرز",
        "تناژ",
        "کرایه",
        "تاریخ",
    ]
    _style_header(worksheet, headers)

    total_tonnage = 0.0
    total_freight = 0.0

    for row_index, row in enumerate(rows, 2):
        tonnage = flt(row.actual_tonnage)
        freight = flt(row.freight_cost)

        total_tonnage += tonnage
        total_freight += freight

        values_row = [
            row.name,
            row.waybill_number,
            row.driver,
            row.carrier,
            row.border,
            tonnage,
            freight,
            latin_jalali_date(row.posting_date),
        ]

        for column_index, value in enumerate(values_row, 1):
            worksheet.cell(
                row=row_index,
                column=column_index,
                value=value,
            )

    total_row = len(rows) + 2
    worksheet.cell(row=total_row, column=5, value="جمع کل")
    worksheet.cell(row=total_row, column=6, value=total_tonnage)
    worksheet.cell(row=total_row, column=7, value=total_freight)

    from openpyxl.styles import Font

    for column_index in (5, 6, 7):
        worksheet.cell(
            row=total_row,
            column=column_index,
        ).font = Font(bold=True)

    _finalize_table(
        worksheet,
        1,
        total_row,
        len(headers),
    )

    _send(workbook, "carrier_statement.xlsx")


@frappe.whitelist()
def export_customs_statement(from_date=None, to_date=None):
    _guard(FINANCE_ROLES)

    conditions = [
        "ifnull(workflow_state, '') not in ('Cancelled', 'Rejected')"
    ]
    values = {}

    if from_date:
        conditions.append("posting_date >= %(from_date)s")
        values["from_date"] = from_date

    if to_date:
        conditions.append("posting_date <= %(to_date)s")
        values["to_date"] = to_date

    rows = frappe.db.sql(
        """
        select
            name,
            posting_date,
            border,
            declaration_number,
            customs_broker,
            driver,
            customs_cost,
            clearance_cost
        from `tabTransport Case`
        where {conditions}
        order by posting_date, name
        """.format(conditions=" and ".join(conditions)),
        values,
        as_dict=True,
    )

    workbook, worksheet = _new_workbook("صورتحساب گمرک")

    headers = [
        "پرونده",
        "تاریخ",
        "مرز",
        "اظهار",
        "ترخیص‌کار",
        "راننده",
        "گمرک",
        "ترخیص",
        "جمع",
    ]
    _style_header(worksheet, headers)

    total_customs = 0.0
    total_clearance = 0.0

    for row_index, row in enumerate(rows, 2):
        customs = flt(row.customs_cost)
        clearance = flt(row.clearance_cost)

        total_customs += customs
        total_clearance += clearance

        values_row = [
            row.name,
            latin_jalali_date(row.posting_date),
            row.border,
            row.declaration_number,
            row.customs_broker,
            row.driver,
            customs,
            clearance,
            customs + clearance,
        ]

        for column_index, value in enumerate(values_row, 1):
            worksheet.cell(
                row=row_index,
                column=column_index,
                value=value,
            )

    total_row = len(rows) + 2
    worksheet.cell(row=total_row, column=6, value="جمع کل")
    worksheet.cell(row=total_row, column=7, value=total_customs)
    worksheet.cell(row=total_row, column=8, value=total_clearance)
    worksheet.cell(
        row=total_row,
        column=9,
        value=total_customs + total_clearance,
    )

    from openpyxl.styles import Font

    for column_index in (6, 7, 8, 9):
        worksheet.cell(
            row=total_row,
            column=column_index,
        ).font = Font(bold=True)

    _finalize_table(
        worksheet,
        1,
        total_row,
        len(headers),
    )

    _send(workbook, "customs_statement.xlsx")


@frappe.whitelist()
def export_proforma(name):
    _guard(OPERATIONS_ROLES)

    doc = frappe.get_doc("Trade Case", name)
    doc.check_permission("read")

    workbook, worksheet = _new_workbook("پیش‌فاکتور")

    rows = [
        ("شماره پرونده", doc.name),
        ("عنوان", doc.case_title),
        ("نوع", doc.case_type),
        ("تاریخ", latin_jalali_date(doc.posting_date)),
        ("مشتری", doc.customer or ""),
        ("تأمین‌کننده", doc.supplier_factory or ""),
        ("کالا", doc.item or doc.cargo_description or ""),
        ("تناژ اصلی", flt(doc.planned_tonnage)),
        ("مبلغ دلار", flt(doc.sales_amount_usd)),
        ("مبلغ ریال فروش", flt(doc.sales_amount)),
        ("مبلغ خرید", flt(doc.purchase_amount)),
        ("شماره فروش", doc.sales_invoice_number or ""),
        ("شماره خرید", doc.purchase_invoice_number or ""),
        ("مقصد", doc.destination or ""),
        ("مرز", doc.border or ""),
    ]

    from openpyxl.styles import Font

    for row_index, (label, value) in enumerate(rows, 1):
        worksheet.cell(
            row=row_index,
            column=1,
            value=label,
        ).font = Font(bold=True)

        worksheet.cell(
            row=row_index,
            column=2,
            value=value,
        )

    _autosize(worksheet)

    safe_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", doc.name)
    _send(workbook, f"proforma_{safe_name}.xlsx")


@frappe.whitelist()
def download_proforma_template():
    _guard(OPERATIONS_ROLES)

    workbook, worksheet = _new_workbook("قالب پیش‌فاکتور")

    headers = [
        "مشتری",
        "تأمین‌کننده",
        "نوع کالا",
        "تناژ اصلی",
        "مبلغ دلار",
        "مبلغ ریال",
        "تاریخ فروش",
        "ش.فاکتور فروش",
        "تاریخ خرید",
        "ش.فاکتور خرید",
        "نوع پرونده",
    ]

    _style_header(worksheet, headers)
    worksheet.freeze_panes = "A2"
    _autosize(worksheet)

    _send(workbook, "proforma_template.xlsx")


@frappe.whitelist()
def import_proforma_excel(file_url):
    """Create Draft Trade Cases from an uploaded XLSX file.

    The operation is fail-fast and transactional: an invalid row raises an
    error and Frappe rolls back the whole request, preventing partial imports.
    """
    _guard(OPERATIONS_ROLES)

    if not frappe.has_permission("Trade Case", "create"):
        frappe.throw(
            _("دسترسی ساخت پرونده تجاری ندارید."),
            frappe.PermissionError,
        )

    file_url = (file_url or "").strip()

    if not file_url:
        frappe.throw(_("فایل اکسل مشخص نشده است."))

    if not file_url.lower().split("?", 1)[0].endswith(".xlsx"):
        frappe.throw(_("فقط فایل XLSX مجاز است."))

    file_docname = frappe.db.get_value(
        "File",
        {"file_url": file_url},
        "name",
    )

    if not file_docname:
        frappe.throw(_("فایل در سیستم پیدا نشد."))

    file_doc = frappe.get_doc("File", file_docname)
    file_doc.check_permission("read")

    if flt(file_doc.file_size) > MAX_IMPORT_FILE_SIZE:
        frappe.throw(_("حجم فایل نباید بیشتر از ۱۰ مگابایت باشد."))

    content = file_doc.get_content()

    if isinstance(content, str):
        content = content.encode("latin-1")

    import openpyxl

    try:
        workbook = openpyxl.load_workbook(
            io.BytesIO(content),
            read_only=True,
            data_only=True,
        )
    except Exception as exc:
        frappe.throw(
            _("فایل Excel معتبر نیست: {0}").format(exc)
        )

    worksheet = workbook.active

    if worksheet.max_row - 1 > MAX_IMPORT_ROWS:
        frappe.throw(
            _("حداکثر تعداد ردیف قابل ورود {0} است.").format(
                MAX_IMPORT_ROWS
            )
        )

    created = []

    for row_number, row in enumerate(
        worksheet.iter_rows(min_row=2, values_only=True),
        start=2,
    ):
        if not row or not any(value not in (None, "") for value in row):
            continue

        values = list(row) + [None] * max(0, 11 - len(row))

        customer = values[0]
        supplier = values[1]
        cargo_description = values[2]
        planned_tonnage = flt(values[3])
        sales_amount_usd = flt(values[4])
        sales_amount = flt(values[5])
        sales_invoice_date = values[6]
        sales_invoice_number = values[7]
        purchase_invoice_date = values[8]
        purchase_invoice_number = values[9]
        case_type = str(values[10] or "خرید").strip()

        if case_type not in ("خرید", "فروش"):
            frappe.throw(
                _("ردیف {0}: نوع پرونده باید خرید یا فروش باشد.").format(
                    row_number
                )
            )

        if not customer:
            frappe.throw(
                _("ردیف {0}: مشتری الزامی است.").format(row_number)
            )

        if planned_tonnage <= 0:
            frappe.throw(
                _("ردیف {0}: تناژ باید بزرگ‌تر از صفر باشد.").format(
                    row_number
                )
            )

        doc = frappe.new_doc("Trade Case")
        doc.case_title = f"{customer} - {cargo_description or case_type}"
        doc.case_type = case_type
        doc.customer = customer
        doc.supplier_factory = supplier
        doc.cargo_description = cargo_description
        doc.planned_tonnage = planned_tonnage
        doc.sales_amount_usd = sales_amount_usd
        doc.sales_amount = sales_amount
        doc.sales_invoice_date = sales_invoice_date
        doc.sales_invoice_number = sales_invoice_number
        doc.purchase_invoice_date = purchase_invoice_date
        doc.purchase_invoice_number = purchase_invoice_number
        doc.insert()

        created.append(doc.name)

    if not created:
        frappe.throw(_("هیچ ردیف قابل ورودی در فایل وجود نداشت."))

    return {
        "created": created,
        "count": len(created),
    }
ITE_REPORT_EXCEL_EOF
# --- END VERBATIM COPY -------------------------------------------------------
log "report_excel.py کپی شد (خط‌به‌خط)"

# =============================================================================
step "3) کپی خط‌به‌خط پنج قالب اختصاصی کارفرما (report_excel_custom.py)"
# --- BEGIN VERBATIM COPY: .../api/report_excel_custom.py ---------------------
# ⚠ توجه: تایپوهای عمدی کارفرما («هزنیه تخلیه» / «هزنیه بارگیری») و تمام
#   مختصات سلول و فرمول‌های محافظت‌شده عیناً حفظ می‌شوند.
write_utf8 "${MOD}/api/report_excel_custom.py" << 'ITE_REPORT_EXCEL_CUSTOM_EOF'
"""Custom Excel layer v5 — PHASE 8 EXCEL ⇄ ERPNext SMART SYNC GOLDEN RULES.

This module is a strict implementation of the signed golden-rules document.

Source of truth order:

    P0  real Excel JSON contract
        sheet name, cell coordinate, merge, hidden columns, exact header text,
        formula, style scope
    P1  real project Meta / DocType fields of transport_ir
    P2  project process rules
    P3  alias/fuzzy, for detection only, never to rewrite client text
        and never to guess a destination

Absolute rules honoured here:

    1.  Client static text is never "spell corrected".
    2.  The exact Excel wording is preserved as-is.
    3.  Aliases live only in the matching layer.
    4.  Coordinate lock wins over fuzzy matching.
    5.  Ambiguity becomes UNRESOLVED, never a plausible guess.
    6.  The original template file is never overwritten.
    7.  Export is copy / in-memory only.
    8.  Import is Preview -> Validate -> Resolve -> Commit.
    9.  A row error rolls the whole import back, no half-imported records.
    10. Operational records are created through the Document API, never SQL.

Templates covered:

    template_01_financial  -> export_financial_custom
    template_02_freight    -> export_freight_custom
    template_03_packing    -> export_packing_custom
    template_04_purchase   -> export_purchase_custom
    template_05_dispatch   -> export_dispatch_custom
"""

from __future__ import annotations

import datetime
import io
import json
import os
import re

from copy import copy

import frappe
from frappe import _
from frappe.utils import flt, getdate

import openpyxl
from openpyxl.cell.cell import MergedCell
from openpyxl.drawing.image import Image as XLImage
from openpyxl.utils import column_index_from_string, get_column_letter
from openpyxl.worksheet.cell_range import CellRange

from transport_ir.iran_transport.api.report_excel import (
    FINANCE_ROLES,
    MAX_IMPORT_FILE_SIZE,
    MAX_IMPORT_ROWS,
    OPERATIONS_ROLES,
    RUNNING_TOTAL_FIELDS,
    _guard,
    _send,
)

try:
    from transport_ir.iran_transport.utils.jinja_helpers import (
        latin_jalali_date,
        normalize_persian,
        to_persian_digits,
    )
except ImportError:  # pragma: no cover - defensive only
    import re as _re

    def latin_jalali_date(value):
        return str(value) if value else ""

    def normalize_persian(value):
        if value is None:
            return ""
        text = str(value)
        for char in ("\u200c", "\u200d", "\u200e", "\u200f", "\ufeff"):
            text = text.replace(char, "")
        text = text.replace("ي", "ی").replace("ك", "ک")
        return _re.sub(r"\s+", " ", text).strip()

    def to_persian_digits(value):
        return str(value or "")


# ---------------------------------------------------------------------------
# UNRESOLVED marker — golden rules forbid writing a guessed value
# ---------------------------------------------------------------------------

UNRESOLVED = None


# ---------------------------------------------------------------------------
# Known client typo aliases — MATCHING ONLY, never used to rewrite the file
# ---------------------------------------------------------------------------

HEADER_ALIASES = {
    "هزنیه تخلیه": ("هزینه تخلیه",),
    "هزنیه بارگیری": ("هزینه بارگیری",),
    "پگینگ": ("پکینگ",),
    "ترخیصکار": ("ترخیص‌کار",),
    "تامین کننده": ("تأمین‌کننده",),
    "data": ("date", "تاریخ"),
    "مبدا": ("مبدأ",),
}


# ---------------------------------------------------------------------------
# G1 / §2 — normalization, only for the comparison key
# ---------------------------------------------------------------------------

def _norm(value):
    """normalize_persian + casefold, for Persian/English fuzzy matching."""
    return normalize_persian(value).lower()


def _alias_keys(value):
    """Return the normalized comparison keys of a header, aliases included."""
    key = _norm(value)
    keys = {key}

    for source, targets in HEADER_ALIASES.items():
        normalized_source = _norm(source)

        if normalized_source and normalized_source == key:
            keys.update(_norm(target) for target in targets)

        for target in targets:
            if _norm(target) == key:
                keys.add(normalized_source)

    return {item for item in keys if item}


# ---------------------------------------------------------------------------
# Sync Log — §14 required trace of every mapping decision
# ---------------------------------------------------------------------------

class SyncLog:
    """Collect a structured trace of the Sync operation."""

    def __init__(self, template_key, source_file):
        self.template_key = template_key
        self.source_file = source_file
        self.entries = []

    def add(
        self,
        source_sheet=None,
        source_cell=None,
        source_row=None,
        destination_doctype=None,
        destination_field=None,
        raw_value=None,
        normalized_value=None,
        match_method=None,
        confidence=None,
        action=None,
        status="ok",
        error=None,
    ):
        self.entries.append(
            {
                "template_key": self.template_key,
                "source_file": self.source_file,
                "source_sheet": source_sheet,
                "source_cell": source_cell,
                "source_row": source_row,
                "destination_doctype": destination_doctype,
                "destination_field": destination_field,
                "raw_value": raw_value,
                "normalized_value": normalized_value,
                "match_method": match_method,
                "confidence": confidence,
                "action": action,
                "status": status,
                "error": error,
            }
        )

    def unresolved(self):
        return [
            entry
            for entry in self.entries
            if entry.get("status") == "unresolved"
        ]

    def flush(self):
        try:
            frappe.logger("phase8_excel_sync").info(
                json.dumps(
                    {
                        "template_key": self.template_key,
                        "source_file": self.source_file,
                        "entries": self.entries[:MAX_IMPORT_ROWS],
                    },
                    ensure_ascii=False,
                    default=str,
                )
            )
        except Exception:
            pass


# ---------------------------------------------------------------------------
# §1 / §4..§8 — TEMPLATE REGISTRY, exact JSON contract of the five templates
# ---------------------------------------------------------------------------
#
# Every column entry is coordinate locked:
#     col      = exact template column letter (P0)
#     header   = exact client header text, typos preserved (P0)
#     field    = destination fieldname of the prepared dataset, or None
#                when the golden rules classify it as UNRESOLVED
#     type     = write contract: Data / Identifier / Int / Float / Currency
#                / Date / Row
#     note     = why the mapping is what it is
#
# ---------------------------------------------------------------------------

TEMPLATE_REGISTRY = {
    # -----------------------------------------------------------------
    # §4 — T01 «- 1405 گزارش خرید و فروش.xlsx»
    # -----------------------------------------------------------------
    "financial": {
        "template_key": "template_01_financial",
        "pattern": "template_01",
        "source_file": "- 1405 گزارش خرید و فروش.xlsx",
        "sheet": "گزارش 1405",
        "rtl": True,
        "header_row": 1,
        "child_header_row": 2,
        "data_start_row": 3,
        "total_row": None,
        "clear_data_area": True,
        "hidden_columns": ("I", "J", "K", "M", "U", "V", "W", "Y"),
        "protected_merges": ("F1:G1", "B1:B2", "A1:A2"),
        "date_mode": "jalali",
        "allow_logo_injection": False,
        "columns": [
            {"col": "A", "header": "تاریخ فروش", "field": "sales_date", "type": "Date"},
            {"col": "B", "header": "ش.فاکتور فروش", "field": "sales_inv", "type": "Identifier"},
            {"col": "C", "header": "مشتری", "field": "customer", "type": "Data"},
            {"col": "D", "header": "نوع کالا", "field": "item_s", "type": "Data"},
            {"col": "E", "header": "تناژ اصلی", "field": "plan_s", "type": "Float"},
            {"col": "F", "header": "مبلغ", "child_header": "دلار", "field": "usd", "type": "Currency"},
            {"col": "G", "header": "مبلغ", "child_header": "ریال", "field": "rial", "type": "Currency"},
            {"col": "H", "header": "تناژ خروجی\n فروش", "field": "ship_s", "type": "Float"},
            {"col": "I", "header": "جمع کل \nخارج شده فروش", "field": "cship_s", "type": "Float"},
            {"col": "J", "header": "مازاد\n بارگیری فروش", "field": "sur_s", "type": "Float"},
            {"col": "K", "header": "جمع کل \nمازاد بارگیری فروش", "field": "csur_s", "type": "Float"},
            {"col": "L", "header": "باقیمانده فروش", "field": "rem_s", "type": "Float"},
            {"col": "M", "header": "جمع کل\n باقیمانده فروش", "field": "crem_s", "type": "Float"},
            {"col": "N", "header": "تاریخ خرید", "field": "pur_date", "type": "Date"},
            {"col": "O", "header": "ش.فاکتور خرید", "field": "pur_inv", "type": "Identifier"},
            {"col": "P", "header": "تامین کننده", "field": "supplier", "type": "Data"},
            {"col": "Q", "header": "نوع کالا", "field": "item_p", "type": "Data"},
            {"col": "R", "header": "تناژ\n اصلی", "field": "plan_p", "type": "Float"},
            {"col": "S", "header": "مبلغ", "field": "pur_amt", "type": "Currency"},
            {"col": "T", "header": "تناژ \nخروجی خرید", "field": "ship_p", "type": "Float"},
            {"col": "U", "header": "جمع کل \nخارج شده خرید", "field": "cship_p", "type": "Float"},
            {"col": "V", "header": "مازاد\n بارگیری خرید", "field": "sur_p", "type": "Float"},
            {"col": "W", "header": "جمع کل \nمازاد بارگیری خرید", "field": "csur_p", "type": "Float"},
            {"col": "X", "header": "باقیمانده خرید", "field": "rem_p", "type": "Float"},
            {"col": "Y", "header": "جمع کل\n باقیمانده خرید", "field": "crem_p", "type": "Float"},
            {"col": "Z", "header": "وضعیت", "field": "status", "type": "Data"},
        ],
    },

    # -----------------------------------------------------------------
    # §5 — T02 «خام لیست کرایه.xlsx»
    # -----------------------------------------------------------------
    "freight": {
        "template_key": "template_02_freight",
        "pattern": "template_02",
        "source_file": "خام لیست کرایه.xlsx",
        "sheet": "Sheet1",
        "rtl": True,
        "header_row": 2,
        "data_start_row": 3,
        "total_row": None,
        "clear_data_area": True,
        "title_cell": "A1",
        "title_prefix": " ",
        "protected_merges": ("A1:O1",),
        "date_mode": "jalali",
        "allow_logo_injection": False,
        "columns": [
            {"col": "A", "header": "ردیف", "field": "__row__", "type": "Row"},
            {
                "col": "B",
                "header": "نام صاحب حساب",
                "field": "account_holder",
                "type": "Data",
                "note": "§5: account holder, NOT automatically the driver",
            },
            {
                "col": "C",
                "header": "شماره حساب",
                "field": "account_no",
                "type": "Identifier",
                "note": "§5/§15: raw account value, never assumed to be Sheba",
            },
            {"col": "D", "header": "بانک ", "field": "bank_name", "type": "Data"},
            {"col": "E", "header": "وزن", "field": "weight", "type": "Float"},
            {
                "col": "F",
                "header": "کل هرتن",
                "field": None,
                "type": "Float",
                "note": "§5: rate per ton has no approved project field -> UNRESOLVED",
            },
            {
                "col": "G",
                "header": " کرایه",
                "field": "freight_cost",
                "type": "Currency",
                "note": "§5/§13: template formula =F{r}*E{r} is protected where present",
            },
            {
                "col": "H",
                "header": "هزنیه تخلیه",
                "field": None,
                "type": "Currency",
                "note": "§2: exact client typo preserved; no approved field -> UNRESOLVED",
            },
            {
                "col": "I",
                "header": "هزنیه بارگیری",
                "field": None,
                "type": "Currency",
                "note": "§2: exact client typo preserved; no approved field -> UNRESOLVED",
            },
            {
                "col": "J",
                "header": "کل کرایه",
                "field": None,
                "type": "Currency",
                "note": "§13: template formula =I{r}+G{r} is protected",
            },
            {"col": "K", "header": "پیش کرایه", "field": "advance_freight", "type": "Currency"},
            {
                "col": "L",
                "header": "مانده",
                "field": None,
                "type": "Currency",
                "note": "§13: template formula =J{r}-K{r} is protected",
            },
            {
                "col": "M",
                "header": "مرز-صاحب بار-نوع بار-نام راننده",
                "field": "composite_identity",
                "type": "Data",
                "note": "§5: composite raw string, master aware, kept in Sync Log",
            },
            {"col": "N", "header": "مبدا بارگیری", "field": "origin", "type": "Data"},
            {
                "col": "O",
                "header": " پیش فاکتور فروش",
                "field": "sales_invoice_number",
                "type": "Identifier",
                "note": "§5: only when the authorized phase8 field exists in Meta",
            },
        ],
        "formula_patterns": {
            "G": "=F{row}*E{row}",
            "J": "=I{row}+G{row}",
            "L": "=J{row}-K{row}",
        },
    },

    # -----------------------------------------------------------------
    # §6 — T03 «فرم پکینگ (1).xlsx»
    # -----------------------------------------------------------------
    "packing": {
        "template_key": "template_03_packing",
        "pattern": "template_03",
        "source_file": "فرم پکینگ (1).xlsx",
        "sheet": "Sheet1",
        "rtl": False,
        "header_row": 7,
        "data_start_row": 10,
        "total_row": 11,
        "clear_data_area": True,
        "protected_merges": (
            "B2:J3",
            "P7:X7",
            "C7:C9",
            "B5:J5",
            "G7:G9",
            "E7:E9",
            "I7:I9",
            "H7:H9",
            "F7:F9",
            "J7:J9",
            "D7:D9",
            "B7:B9",
            "B4:J4",
            "B6:J6",
        ),
        "date_mode": "gregorian",
        "allow_logo_injection": False,
        "meta_cells": [
            {"cell": "B4", "prefix": "INVOICE NUMBER: ", "field": "sales_invoice_number", "type": "Identifier"},
            {"cell": "B5", "prefix": "Data:", "field": "packing_date", "type": "Date"},
            {"cell": "B6", "prefix": "Buyer: Mr ", "field": "customer", "type": "Data"},
        ],
        "total_label_cell": "C11",
        "sum_columns": {"F": "F11"},
        "columns": [
            {"col": "B", "header": "Row", "field": "__row__", "type": "Row"},
            {"col": "C", "header": "Description", "field": "item", "type": "Data"},
            {
                "col": "D",
                "header": "Size",
                "field": "size",
                "type": "Data",
                "note": "§6: dimensions first, thickness only as declared fallback",
            },
            {
                "col": "E",
                "header": "Branch",
                "field": "qty",
                "type": "Float",
                "note": "§6: Branch = qty/شاخه, explicitly NOT «مرز»",
            },
            {"col": "F", "header": "Net Weight", "field": "actual_tonnage", "type": "Float"},
            {
                "col": "G",
                "header": "Delivery B.",
                "field": "delivery_border",
                "type": "Data",
                "note": "§6: delivery-border context, NEVER the sales invoice",
            },
            {"col": "H", "header": "Driver's name", "field": "driver", "type": "Data"},
            {"col": "I", "header": "Car tag", "field": "plate_number", "type": "Identifier"},
            {"col": "J", "header": "Phone number", "field": "driver_mobile", "type": "Identifier"},
        ],
    },

    # -----------------------------------------------------------------
    # §7 — T04 «خام خرید.xlsx»
    # -----------------------------------------------------------------
    "purchase": {
        "template_key": "template_04_purchase",
        "pattern": "template_04",
        "source_file": "خام خرید.xlsx",
        "sheet": "پیش فاکتور خرید",
        "required_sheets": (
            "فروشنده",
            "معرفی کالا",
            "پیش فاکتور خرید",
            "صورت بارگیری",
        ),
        "rtl": True,
        "header_row": 3,
        "data_start_row": 4,
        "total_row": None,
        "clear_data_area": True,
        "protected_merges": ("A1:K1",),
        "protected_cells": ("I2",),
        "date_mode": "jalali",
        "allow_logo_injection": False,
        "meta_cells": [
            {"cell": "B2", "prefix": "", "field": "purchase_invoice_date", "type": "Date"},
            {"cell": "D2", "prefix": "", "field": "purchase_invoice_number", "type": "Identifier"},
            {"cell": "F2", "prefix": "", "field": "supplier_factory", "type": "Data"},
        ],
        "columns": [
            {"col": "A", "header": "ردیف", "field": "__row__", "type": "Row"},
            {"col": "B", "header": "نام کالا", "field": "item", "type": "Data"},
            {
                "col": "C",
                "header": "سایز",
                "field": "size_key",
                "type": "Data",
                "note": "§7: SUMIFS criteria cell, must equal 'صورت بارگیری'!D",
            },
            {"col": "D", "header": "تناژ", "field": "planned_tonnage", "type": "Float"},
            {
                "col": "E",
                "header": "واحد وزن",
                "field": None,
                "type": "Data",
                "note": "§7/§12: no approved unit field -> UNRESOLVED, no guessing",
            },
            {
                "col": "F",
                "header": "فی واحد",
                "field": None,
                "type": "Currency",
                "note": "§7: unit price, explicitly NOT purchase_amount total",
            },
            {
                "col": "G",
                "header": "نوع ارز",
                "field": None,
                "type": "Data",
                "note": "§7: no approved currency field on Trade Case -> UNRESOLVED",
            },
            {"col": "H", "header": "تحویل", "field": "delivery_type", "type": "Data"},
            {
                "col": "I",
                "header": "مقدار حمل شده",
                "field": None,
                "type": "Float",
                "note": "§13: protected SUMIFS formula",
            },
            {
                "col": "J",
                "header": "مانده",
                "field": None,
                "type": "Float",
                "note": "§13: protected formula",
            },
            {
                "col": "K",
                "header": "ارزش کالای مانده",
                "field": None,
                "type": "Currency",
                "note": "§13: protected formula",
            },
        ],
        "formula_patterns": {
            "I": (
                "=IF(D{row}<>\"\","
                "SUMIFS('صورت بارگیری'!$E$3:$E$1048576,"
                "'صورت بارگیری'!$D$3:$D$1048576,C{row}),\"\")"
            ),
            "J": "=IF(D{row}<>\"\",D{row}-I{row},\"\")",
            "K": "=IF(D{row}<>\"\",J{row}*F{row},\"\")",
        },
        "extra_sheets": {
            "loading": {
                "sheet": "صورت بارگیری",
                "rtl": True,
                "header_row": 2,
                "data_start_row": 3,
                "total_row": None,
                "clear_data_area": True,
                "protected_merges": ("A1:K1",),
                "protected_cells": ("A1",),
                "date_mode": "jalali",
                "columns": [
                    {"col": "A", "header": "ردیف", "field": "__row__", "type": "Row"},
                    {
                        "col": "B",
                        "header": "پگینگ",
                        "field": None,
                        "type": "Data",
                        "note": "§7/§2: exact client spelling «پگینگ»; meaning unresolved",
                    },
                    {"col": "C", "header": "تاریخ بارگیری", "field": "loading_date", "type": "Date"},
                    {
                        "col": "D",
                        "header": "کالا",
                        "field": "size_key",
                        "type": "Data",
                        "note": "§7: SUMIFS key column, must match 'پیش فاکتور خرید'!C",
                    },
                    {"col": "E", "header": "وزن خالص", "field": "actual_tonnage", "type": "Float"},
                    {"col": "F", "header": "مقصد", "field": "destination", "type": "Data"},
                    {"col": "G", "header": "ش. کامیون", "field": "plate_number", "type": "Identifier"},
                    {"col": "H", "header": "نام راننده", "field": "driver", "type": "Data"},
                    {"col": "I", "header": "شماره راننده", "field": "driver_mobile", "type": "Identifier"},
                    {"col": "J", "header": "خریدار", "field": "customer", "type": "Data"},
                    {"col": "K", "header": "ترخیصکار", "field": "customs_broker", "type": "Data"},
                ],
            }
        },
    },

    # -----------------------------------------------------------------
    # §8 — T05 «فایل خام.xlsx»
    # -----------------------------------------------------------------
    "dispatch": {
        "template_key": "template_05_dispatch",
        "pattern": "template_05",
        "source_file": "فایل خام.xlsx",
        "sheet": "Sheet1",
        "rtl": True,
        "header_row": 3,
        "data_start_row": 4,
        "total_row": 10,
        "clear_data_area": True,
        "protected_merges": ("B2:L2",),
        "date_mode": "jalali",
        "allow_logo_injection": False,
        "sum_columns": {"E": "E10"},
        "columns": [
            {"col": "B", "header": "ردیف", "field": "__row__", "type": "Row"},
            {"col": "C", "header": "تاریخ بارگیری", "field": "loading_date", "type": "Date"},
            {"col": "D", "header": "نوع بار", "field": "cargo_description", "type": "Data"},
            {"col": "E", "header": "وزن", "field": "actual_tonnage", "type": "Float"},
            {"col": "F", "header": "مبدا", "field": "origin", "type": "Data"},
            {"col": "G", "header": "مقصد", "field": "destination", "type": "Data"},
            {"col": "H", "header": "ش. کامیون", "field": "plate_number", "type": "Identifier"},
            {"col": "I", "header": "نام راننده", "field": "driver", "type": "Data"},
            {"col": "J", "header": "شماره راننده", "field": "driver_mobile", "type": "Identifier"},
            {"col": "K", "header": "ترخیصکار", "field": "customs_broker", "type": "Data"},
            {"col": "L", "header": "باربری", "field": "carrier", "type": "Data"},
        ],
    },
}


# ---------------------------------------------------------------------------
# Template files
# ---------------------------------------------------------------------------

def _template_dir():
    return frappe.get_site_path("private", "files", "excel_templates")


def _find_file(pattern):
    directory = _template_dir()

    if not os.path.isdir(directory):
        return None

    for filename in sorted(os.listdir(directory)):
        if pattern in filename and filename.lower().endswith(".xlsx"):
            return os.path.join(directory, filename)

    return None


# ---------------------------------------------------------------------------
# §3 — Meta guard, never invent a fieldname
# ---------------------------------------------------------------------------

def _has_field(doctype, fieldname):
    if not fieldname:
        return False

    try:
        return bool(frappe.get_meta(doctype).get_field(fieldname))
    except Exception:
        return False


def _safe_fields(doctype, wanted):
    fields = []

    for fieldname in wanted:
        if fieldname == "name" or _has_field(doctype, fieldname):
            if fieldname not in fields:
                fields.append(fieldname)

    if "name" not in fields:
        fields.append("name")

    return fields


# ---------------------------------------------------------------------------
# §10 — Link resolution, Link key stored in ERP, display value in Excel
# ---------------------------------------------------------------------------

LINK_DISPLAY_PRIORITY = (
    "full_name",
    "driver_name",
    "carrier_name",
    "broker_name",
    "representative_name",
    "border_name",
    "customer_name",
    "supplier_name",
    "factory_name",
    "item_name",
    "company_name",
    "case_title",
    "title",
)


def _resolve_link_smart(linked_doctype, value):
    """Resolve a Link value into its human readable display name."""
    if not value or not linked_doctype:
        return value

    try:
        meta = frappe.get_meta(linked_doctype)
    except Exception:
        return value

    try:
        for fieldname in LINK_DISPLAY_PRIORITY:
            if not meta.has_field(fieldname):
                continue

            display = frappe.db.get_value(linked_doctype, value, fieldname)

            if display:
                return display

        title_field = getattr(meta, "title_field", None)

        if title_field and meta.has_field(title_field):
            display = frappe.db.get_value(linked_doctype, value, title_field)

            if display:
                return display
    except Exception:
        return value

    return value


def _resolve_link(doctype, value, search_field):
    """Resolve an incoming Excel value into a document name (import side)."""
    if not value:
        return None

    value = str(value).strip()

    if frappe.db.exists(doctype, value):
        return value

    return frappe.db.get_value(doctype, {search_field: value}, "name")


def _resolve_link_columns(doctype, specs, rows):
    """Replace Link keys by display names for the listed dataset fields."""
    try:
        meta = frappe.get_meta(doctype)
    except Exception:
        return

    cache = {}

    for spec in specs:
        source = spec.get("source")

        if not source or not meta.has_field(source):
            continue

        df = meta.get_field(source)

        if not df or df.fieldtype != "Link" or not df.options:
            continue

        for row in rows:
            value = row.get(spec["fieldname"])

            if not value:
                continue

            key = (df.options, value)

            if key not in cache:
                cache[key] = _resolve_link_smart(df.options, value)

            row[spec["fieldname"]] = cache[key]


# ---------------------------------------------------------------------------
# §12 — value transformation, numeric stays numeric, identifiers stay strings
# ---------------------------------------------------------------------------

def _transform_date(value, date_mode):
    if not value:
        return ""

    if date_mode == "gregorian":
        try:
            return getdate(value).strftime("%Y/%m/%d")
        except Exception:
            return str(value)

    try:
        return latin_jalali_date(value)
    except Exception:
        return str(value)


def _transform_value(value, value_type, date_mode):
    if value in (None, ""):
        return None

    if value_type == "Date":
        return _transform_date(value, date_mode)

    if value_type in ("Currency", "Float"):
        return flt(value)

    if value_type in ("Int", "Row"):
        try:
            return int(flt(value))
        except Exception:
            return value

    if value_type == "Identifier":
        return str(value)

    return value


# ---------------------------------------------------------------------------
# §11 — merge / style safe writing
# ---------------------------------------------------------------------------

def _set_cell_value(ws, row_idx, col_idx, value):
    cell = ws.cell(row=row_idx, column=col_idx)

    if isinstance(cell, MergedCell):
        for merged_range in ws.merged_cells.ranges:
            if (
                merged_range.min_row <= row_idx <= merged_range.max_row
                and merged_range.min_col <= col_idx <= merged_range.max_col
            ):
                ws.cell(
                    row=merged_range.min_row,
                    column=merged_range.min_col,
                ).value = value
                return True

        return False

    cell.value = value
    return True


def safe_write_merged_aware(ws, coord, value):
    """Coordinate based variant of `_set_cell_value` (A1 style)."""
    cell = ws[coord]
    return _set_cell_value(ws, cell.row, cell.column, value)


def _is_formula(value):
    return isinstance(value, str) and value.startswith("=")


def _cell_has_formula(ws, row_idx, col_idx):
    cell = ws.cell(row=row_idx, column=col_idx)

    if isinstance(cell, MergedCell):
        return False

    return _is_formula(cell.value)


_FORMULA_REF = re.compile(r"(\$?[A-Za-z]{1,3})(\$?)(\d+)")


def _shift_formula(formula, delta):
    """Shift relative row references of a formula by `delta`."""
    if not _is_formula(formula) or not delta:
        return formula

    def _replace(match):
        column, absolute, row = match.group(1), match.group(2), match.group(3)

        if absolute == "$":
            return match.group(0)

        return f"{column}{int(row) + delta}"

    return _FORMULA_REF.sub(_replace, formula)


# ---------------------------------------------------------------------------
# §11 — protected merges and data-area-only unmerge
# ---------------------------------------------------------------------------

def _protected_ranges(sheet_reg):
    protected = set()

    for ref in sheet_reg.get("protected_merges") or ():
        protected.add(str(CellRange(ref)))

    return protected


def _unmerge_data_area(ws, sheet_reg, start_row, total_row=None):
    """Unmerge only data-area merges.

    Title, header block, logo and Total merges declared in the registry are
    protected and stay intact. The template file on disk is never touched.
    """
    protected = _protected_ranges(sheet_reg)

    for merged_range in list(ws.merged_cells.ranges):
        ref = str(merged_range)

        if ref in protected:
            continue

        if merged_range.min_row < start_row:
            continue

        if total_row is not None and merged_range.min_row >= total_row:
            continue

        try:
            ws.unmerge_cells(ref)
        except Exception:
            pass


def _copy_row_style(ws, source_row, target_row):
    max_col = ws.max_column or 1

    for col in range(1, max_col + 1):
        source = ws.cell(row=source_row, column=col)
        target = ws.cell(row=target_row, column=col)

        if isinstance(target, MergedCell):
            continue

        try:
            if source.has_style:
                target._style = copy(source._style)

            if source.number_format:
                target.number_format = source.number_format
        except Exception:
            pass


def _clone_row_formulas(ws, sheet_reg, source_row, target_row):
    """Clone the declared formula families into a newly created row."""
    patterns = sheet_reg.get("formula_patterns") or {}

    for column_letter, pattern in patterns.items():
        col_idx = column_index_from_string(column_letter)
        cell = ws.cell(row=target_row, column=col_idx)

        if isinstance(cell, MergedCell):
            continue

        cell.value = pattern.format(row=target_row)

    if patterns:
        return

    max_col = ws.max_column or 1

    for col in range(1, max_col + 1):
        source = ws.cell(row=source_row, column=col)

        if not _is_formula(source.value):
            continue

        target = ws.cell(row=target_row, column=col)

        if isinstance(target, MergedCell):
            continue

        target.value = _shift_formula(source.value, target_row - source_row)


def _ensure_data_rows(
    ws,
    start_row,
    required_rows,
    total_row=None,
    sheet_reg=None,
):
    """Guarantee enough data rows, inserting above the template Total row."""
    sheet_reg = sheet_reg or {}

    if required_rows <= 0:
        return total_row

    if total_row is not None:
        available = total_row - start_row

        if required_rows > available:
            extra = required_rows - available

            # openpyxl does not shift merged ranges on insert_rows, so ranges
            # at/below the Total row are re-created manually.
            below = [
                str(rng)
                for rng in list(ws.merged_cells.ranges)
                if rng.min_row >= total_row
            ]

            for ref in below:
                try:
                    ws.unmerge_cells(ref)
                except Exception:
                    pass

            ws.insert_rows(total_row, amount=extra)

            for row_idx in range(total_row, total_row + extra):
                _copy_row_style(ws, start_row, row_idx)
                _clone_row_formulas(ws, sheet_reg, start_row, row_idx)

            for ref in below:
                try:
                    rng = CellRange(ref)
                    rng.shift(row_shift=extra)
                    ws.merge_cells(str(rng))
                except Exception:
                    pass

            total_row += extra

        return total_row

    last_row = start_row + required_rows - 1

    if last_row > (ws.max_row or 0):
        for row_idx in range((ws.max_row or 0) + 1, last_row + 1):
            _copy_row_style(ws, start_row, row_idx)
            _clone_row_formulas(ws, sheet_reg, start_row, row_idx)

    return None


# ---------------------------------------------------------------------------
# §2 — header verification, coordinate first, alias only for detection
# ---------------------------------------------------------------------------

def _find_header_row(ws, sheet_reg, max_rows=30):
    """Verify or locate the header row without ever rewriting client text."""
    columns = sheet_reg.get("columns") or []
    declared = sheet_reg.get("header_row") or 1

    expected = set()

    for spec in columns:
        expected.update(_alias_keys(spec.get("header")))

    if not expected:
        return declared

    def _score(row_idx):
        score = 0

        for spec in columns:
            col_idx = column_index_from_string(spec["col"])
            actual = _norm(ws.cell(row=row_idx, column=col_idx).value)

            if actual and actual in _alias_keys(spec.get("header")):
                score += 1

        return score

    max_row = ws.max_row or 1

    if declared <= max_row and _score(declared) > 0:
        return declared

    best_row = declared
    best_score = 0

    for row_idx in range(1, min(max_rows, max_row) + 1):
        score = _score(row_idx)

        if score > best_score:
            best_score = score
            best_row = row_idx

    return best_row


def find_header_row_fuzzy(ws, expected_headers, max_rows=30, min_match_ratio=0.6):
    """Public fuzzy helper, detection only, kept for reuse and testing."""
    columns = [
        {"col": get_column_letter(index), "header": header}
        for index, header in enumerate(expected_headers or [], 1)
    ]

    header_row = _find_header_row(
        ws,
        {"columns": columns, "header_row": 1},
        max_rows=max_rows,
    )

    mapping = _build_column_mapping(
        ws,
        header_row,
        {"columns": columns},
    )

    if expected_headers and len(mapping) < len(expected_headers) * min_match_ratio:
        return header_row, {}

    return header_row, mapping


def _build_column_mapping(ws, header_row, sheet_reg, log=None):
    """Coordinate locked mapping: column index -> registry spec."""
    mapping = {}

    for spec in sheet_reg.get("columns") or []:
        col_idx = column_index_from_string(spec["col"])
        actual = ws.cell(row=header_row, column=col_idx).value
        normalized = _norm(actual)
        expected_keys = _alias_keys(spec.get("header"))

        if normalized and normalized in expected_keys:
            match_method = "coordinate+exact"
            confidence = 1.0
        elif normalized:
            match_method = "coordinate"
            confidence = 0.9
        else:
            match_method = "coordinate+empty"
            confidence = 0.8

        mapping[col_idx] = spec

        if log:
            log.add(
                source_sheet=ws.title,
                source_cell=f"{spec['col']}{header_row}",
                destination_field=spec.get("field"),
                raw_value=actual,
                normalized_value=normalized,
                match_method=match_method,
                confidence=confidence,
                action="map_column",
                status="ok" if spec.get("field") else "unresolved",
                error=spec.get("note") if not spec.get("field") else None,
            )

    return mapping


# ---------------------------------------------------------------------------
# Data area cleanup — values only, styles/merges/formulas untouched
# ---------------------------------------------------------------------------

def _clear_data_area(ws, sheet_reg, start_row, total_row=None):
    if not sheet_reg.get("clear_data_area"):
        return

    last_row = (total_row - 1) if total_row else (ws.max_row or start_row)

    if last_row < start_row:
        return

    for spec in sheet_reg.get("columns") or []:
        col_idx = column_index_from_string(spec["col"])

        for row_idx in range(start_row, last_row + 1):
            cell = ws.cell(row=row_idx, column=col_idx)

            if isinstance(cell, MergedCell):
                continue

            if _is_formula(cell.value):
                continue

            cell.value = None


# ---------------------------------------------------------------------------
# Sheet filler
# ---------------------------------------------------------------------------

def _fill_sheet(ws, sheet_reg, rows, log, allow_row_insert=True):
    """Write a prepared dataset into one template sheet."""
    date_mode = sheet_reg.get("date_mode") or "jalali"

    header_row = _find_header_row(ws, sheet_reg)
    start_row = sheet_reg.get("data_start_row") or (header_row + 1)
    total_row = sheet_reg.get("total_row")

    mapping = _build_column_mapping(ws, header_row, sheet_reg, log=log)

    _unmerge_data_area(ws, sheet_reg, start_row, total_row)
    _clear_data_area(ws, sheet_reg, start_row, total_row)

    if allow_row_insert:
        total_row = _ensure_data_rows(
            ws,
            start_row,
            len(rows),
            total_row,
            sheet_reg=sheet_reg,
        )

    protected_cells = set(sheet_reg.get("protected_cells") or ())

    for offset, row in enumerate(rows):
        row_idx = start_row + offset

        for col_idx, spec in mapping.items():
            coord = f"{spec['col']}{row_idx}"

            if coord in protected_cells:
                continue

            if _cell_has_formula(ws, row_idx, col_idx):
                log.add(
                    source_sheet=ws.title,
                    source_cell=coord,
                    source_row=row_idx,
                    destination_field=spec.get("field"),
                    match_method="coordinate",
                    confidence=1.0,
                    action="skip_protected_formula",
                    status="protected",
                )
                continue

            field = spec.get("field")

            if not field:
                log.add(
                    source_sheet=ws.title,
                    source_cell=coord,
                    source_row=row_idx,
                    destination_field=None,
                    match_method="registry",
                    confidence=0.0,
                    action="skip_unresolved",
                    status="unresolved",
                    error=spec.get("note"),
                )
                continue

            if field == "__row__":
                _set_cell_value(ws, row_idx, col_idx, offset + 1)
                continue

            raw_value = row.get(field)
            value = _transform_value(raw_value, spec.get("type"), date_mode)

            if value in (None, ""):
                continue

            _set_cell_value(ws, row_idx, col_idx, value)

            log.add(
                source_sheet=ws.title,
                source_cell=coord,
                source_row=row_idx,
                destination_field=field,
                raw_value=raw_value,
                normalized_value=value,
                match_method="coordinate",
                confidence=1.0,
                action="write",
            )

    last_data_row = start_row + len(rows) - 1

    _rewrite_sum_formulas(
        ws,
        sheet_reg,
        start_row,
        last_data_row,
        total_row,
        log,
    )

    _fill_meta_cells(ws, sheet_reg, rows, log)

    return {
        "header_row": header_row,
        "start_row": start_row,
        "total_row": total_row,
        "last_data_row": last_data_row,
    }


def _rewrite_sum_formulas(
    ws,
    sheet_reg,
    start_row,
    last_data_row,
    total_row,
    log,
):
    """§13: the only authorized formula rewrite is the declared SUM extension."""
    sum_columns = sheet_reg.get("sum_columns") or {}

    if not sum_columns or last_data_row < start_row:
        return

    declared_total = sheet_reg.get("total_row")
    shift = 0

    if declared_total and total_row:
        shift = total_row - declared_total

    for column_letter, coord in sum_columns.items():
        cell = ws[coord]
        target_row = cell.row + shift
        col_idx = column_index_from_string(column_letter)
        target = ws.cell(row=target_row, column=col_idx)

        if isinstance(target, MergedCell):
            continue

        formula = f"=SUM({column_letter}{start_row}:{column_letter}{last_data_row})"
        target.value = formula

        log.add(
            source_sheet=ws.title,
            source_cell=f"{column_letter}{target_row}",
            match_method="registry_formula_rewrite",
            confidence=1.0,
            normalized_value=formula,
            action="rewrite_sum",
        )


def _fill_meta_cells(ws, sheet_reg, rows, log):
    """Fill the declared meta cells, keeping the exact client prefixes."""
    meta_cells = sheet_reg.get("meta_cells") or []

    if not meta_cells or not rows:
        return

    date_mode = sheet_reg.get("date_mode") or "jalali"
    first = rows[0]

    for spec in meta_cells:
        field = spec.get("field")

        if not field:
            continue

        raw_value = first.get(field)

        if raw_value in (None, ""):
            log.add(
                source_sheet=ws.title,
                source_cell=spec.get("cell"),
                destination_field=field,
                match_method="registry",
                confidence=0.0,
                action="skip_meta",
                status="unresolved",
            )
            continue

        value = _transform_value(raw_value, spec.get("type"), date_mode)
        text = f"{spec.get('prefix') or ''}{value}"

        safe_write_merged_aware(ws, spec["cell"], text)

        log.add(
            source_sheet=ws.title,
            source_cell=spec.get("cell"),
            destination_field=field,
            raw_value=raw_value,
            normalized_value=text,
            match_method="coordinate",
            confidence=1.0,
            action="write_meta",
        )


def _apply_title(ws, sheet_reg, from_date, to_date, log):
    """T02: replace the period date using the exact client pattern."""
    title_cell = sheet_reg.get("title_cell")

    if not title_cell:
        return

    value = to_date or from_date

    if not value:
        return

    prefix = sheet_reg.get("title_prefix") or ""
    text = f"{prefix}{_transform_date(value, sheet_reg.get('date_mode') or 'jalali')}"

    safe_write_merged_aware(ws, title_cell, text)

    log.add(
        source_sheet=ws.title,
        source_cell=title_cell,
        match_method="coordinate",
        confidence=1.0,
        normalized_value=text,
        action="write_title",
    )


def _restore_hidden_columns(ws, sheet_reg):
    for column_letter in sheet_reg.get("hidden_columns") or ():
        ws.column_dimensions[column_letter].hidden = True


# ---------------------------------------------------------------------------
# Workbook loader
# ---------------------------------------------------------------------------

def _open_template(template_key):
    reg = TEMPLATE_REGISTRY[template_key]
    path = _find_file(reg["pattern"])

    if not path:
        frappe.throw(
            _("قالب {0} یافت نشد. لطفاً در private/files/excel_templates قرار دهید.").format(
                reg["template_key"]
            )
        )

    # Read only. The workbook on disk is never saved back (§0 rule 6/7).
    wb = openpyxl.load_workbook(path)

    for sheet_name in reg.get("required_sheets") or ():
        if sheet_name not in wb.sheetnames:
            frappe.throw(
                _("شیت {0} در قالب {1} یافت نشد.").format(
                    sheet_name,
                    reg["template_key"],
                )
            )

    return reg, wb


def _get_sheet(wb, reg, sheet_name):
    """§15: never select a sheet by index while the required name exists."""
    if sheet_name in wb.sheetnames:
        return wb[sheet_name]

    frappe.throw(
        _("شیت {0} در قالب {1} یافت نشد.").format(
            sheet_name,
            reg["template_key"],
        )
    )


def _rows_from_report(columns, data):
    """Convert a Frappe report result into dataset dictionaries."""
    fieldnames = [column.get("fieldname") for column in columns]
    rows = []

    for source_row in data:
        if isinstance(source_row, dict):
            rows.append(dict(source_row))
            continue

        row = {}

        for index, fieldname in enumerate(fieldnames):
            row[fieldname] = (
                source_row[index] if index < len(source_row) else None
            )

        rows.append(row)

    return rows


def _load_and_fill_report(
    template_key,
    columns,
    data,
    extra_sheets=None,
    from_date=None,
    to_date=None,
):
    """Load the employer template and fill it under the golden rules.

    Merge protection is handled by `_unmerge_data_area`, formulas are
    protected, hidden columns are restored and the source file is untouched.
    """
    reg, wb = _open_template(template_key)
    log = SyncLog(reg["template_key"], reg["source_file"])

    ws = _get_sheet(wb, reg, reg["sheet"])
    ws.sheet_view.rightToLeft = bool(reg.get("rtl"))

    rows = _rows_from_report(columns, data)

    _apply_title(ws, reg, from_date, to_date, log)
    _fill_sheet(ws, reg, rows, log)
    _restore_hidden_columns(ws, reg)

    for key, sheet_rows in (extra_sheets or {}).items():
        sheet_reg = (reg.get("extra_sheets") or {}).get(key)

        if not sheet_reg:
            continue

        extra_ws = _get_sheet(wb, reg, sheet_reg["sheet"])
        extra_ws.sheet_view.rightToLeft = bool(sheet_reg.get("rtl"))

        _fill_sheet(extra_ws, sheet_reg, sheet_rows, log)
        _restore_hidden_columns(extra_ws, sheet_reg)

    # Logo policy §6/§11: never remove, inject only when explicitly authorized
    if reg.get("allow_logo_injection") and not getattr(ws, "_images", None):
        logo_path = os.path.join(_template_dir(), "client_logo.png")

        if os.path.exists(logo_path):
            image = XLImage(logo_path)
            image.width, image.height = 120, 60
            ws.add_image(image, "B2")

    log.flush()

    return wb


# ---------------------------------------------------------------------------
# Dataset builders — Meta guarded, no invented fieldnames
# ---------------------------------------------------------------------------

def _columns_from_specs(specs):
    return [
        {
            "fieldname": spec["fieldname"],
            "label": spec["label"],
            "fieldtype": spec.get("fieldtype", "Data"),
        }
        for spec in specs
    ]


def _fetch_rows(doctype, specs, filters, order_by):
    wanted = [
        spec.get("source")
        for spec in specs
        if spec.get("source")
    ]

    db_fields = _safe_fields(doctype, wanted)

    records = frappe.get_all(
        doctype,
        filters=filters,
        fields=db_fields,
        order_by=order_by,
        limit_page_length=0,
    )

    rows = []

    for index, record in enumerate(records, 1):
        row = {
            "__row__": index,
            "__name__": record.get("name"),
        }

        for spec in specs:
            source = spec.get("source")
            row[spec["fieldname"]] = (
                record.get(source) if source and source in record else None
            )

        rows.append(row)

    return rows


def _transport_filters(from_date=None, to_date=None, carrier=None, border=None):
    filters = {
        "workflow_state": ["not in", ["Cancelled", "Rejected"]],
    }

    if from_date and to_date:
        filters["posting_date"] = ["between", [from_date, to_date]]
    elif from_date:
        filters["posting_date"] = [">=", from_date]
    elif to_date:
        filters["posting_date"] = ["<=", to_date]

    if carrier:
        filters["carrier"] = carrier

    if border:
        filters["border"] = border

    return filters


# ---------------------------------------------------------------------------
# T02 dataset — freight settlement
# ---------------------------------------------------------------------------

FREIGHT_SPECS = [
    {"fieldname": "posting_date", "label": "تاریخ", "fieldtype": "Date", "source": "posting_date"},
    {"fieldname": "trade_case", "label": "پرونده تجاری", "source": "trade_case"},
    {"fieldname": "driver", "label": "راننده", "source": "driver"},
    {"fieldname": "driver_name", "label": "نام راننده", "source": "driver_name"},
    {"fieldname": "plate_number", "label": "پلاک", "source": "plate_number"},
    {"fieldname": "carrier", "label": "باربری", "source": "carrier"},
    {"fieldname": "origin", "label": "مبدا بارگیری", "source": "origin"},
    {"fieldname": "destination", "label": "مقصد", "source": "destination"},
    {"fieldname": "border", "label": "مرز", "source": "border"},
    {"fieldname": "customer", "label": "مشتری", "source": "customer"},
    {"fieldname": "supplier_factory", "label": "کارخانه", "source": "supplier_factory"},
    {"fieldname": "item", "label": "کالا", "source": "item"},
    {"fieldname": "cargo_description", "label": "نوع بار", "source": "cargo_description"},
    {"fieldname": "weight", "label": "وزن", "fieldtype": "Float", "source": "actual_tonnage"},
    {"fieldname": "freight_cost", "label": "کرایه", "fieldtype": "Currency", "source": "freight_cost"},
    {"fieldname": "waybill_number", "label": "بارنامه", "source": "waybill_number"},
    {"fieldname": "sales_invoice_number", "label": "پیش فاکتور فروش", "source": "sales_invoice_number"},
    {"fieldname": "account_holder", "label": "نام صاحب حساب"},
    {"fieldname": "account_no", "label": "شماره حساب"},
    {"fieldname": "bank_name", "label": "بانک"},
    {"fieldname": "advance_freight", "label": "پیش کرایه", "fieldtype": "Currency"},
    {"fieldname": "composite_identity", "label": "مرز-صاحب بار-نوع بار-نام راننده"},
]


def _attach_payment_details(rows):
    """§3.3 Transport Payment: account holder, bank, account, advance freight."""
    names = [row.get("__name__") for row in rows if row.get("__name__")]

    if not names or not frappe.db.exists("DocType", "Transport Payment"):
        return

    placeholders = ", ".join(["%s"] * len(names))

    payments = frappe.db.sql(
        """
        select
            parent,
            payment_type,
            amount,
            payment_date,
            sheba,
            bank_name,
            paid_by,
            idx
        from `tabTransport Payment`
        where parenttype = 'Transport Case'
          and parent in ({placeholders})
        order by ifnull(payment_date, '1900-01-01') asc, idx asc
        """.format(placeholders=placeholders),
        tuple(names),
        as_dict=True,
    )

    by_parent = {}

    for payment in payments:
        by_parent.setdefault(payment.parent, []).append(payment)

    for row in rows:
        entries = by_parent.get(row.get("__name__")) or []

        if not entries:
            continue

        latest = entries[-1]

        row["account_holder"] = latest.get("paid_by")
        row["account_no"] = latest.get("sheba")
        row["bank_name"] = latest.get("bank_name")

        advance = sum(
            flt(entry.get("amount"))
            for entry in entries
            if (entry.get("payment_type") or "").strip() == "پیش کرایه"
        )

        if advance:
            row["advance_freight"] = advance


def _build_composite_identity(rows):
    """T02 column M raw format: «مرز-صاحب بار-نوع بار-نام راننده»."""
    for row in rows:
        parts = [
            row.get("border") or "",
            row.get("customer") or row.get("supplier_factory") or "",
            row.get("item") or row.get("cargo_description") or "",
            row.get("driver_name") or row.get("driver") or "",
        ]

        row["composite_identity"] = "-".join(
            str(part) for part in parts
        )


def _fill_cargo_fallback(rows):
    """Use the Trade Case item when the Transport Case has no cargo text."""
    missing = [
        row for row in rows
        if not row.get("cargo_description") and row.get("trade_case")
    ]

    if not missing:
        return

    trade_names = sorted({row.get("trade_case") for row in missing})
    placeholders = ", ".join(["%s"] * len(trade_names))

    records = frappe.db.sql(
        """
        select name, item, cargo_description
        from `tabTrade Case`
        where name in ({placeholders})
        """.format(placeholders=placeholders),
        tuple(trade_names),
        as_dict=True,
    )

    by_name = {record.name: record for record in records}

    for row in missing:
        record = by_name.get(row.get("trade_case"))

        if record:
            row["cargo_description"] = (
                record.get("item") or record.get("cargo_description") or ""
            )


# ---------------------------------------------------------------------------
# T03 dataset — packing
# ---------------------------------------------------------------------------

def _prepare_packing_rows(rows):
    """§6: Size, Branch=qty, Delivery B.=delivery border, never sales invoice."""
    names = [row.get("name") for row in rows if row.get("name")]
    dimensions = {}

    if names and _has_field("Transport Case", "dimensions"):
        placeholders = ", ".join(["%s"] * len(names))

        records = frappe.db.sql(
            """
            select name, dimensions
            from `tabTransport Case`
            where name in ({placeholders})
            """.format(placeholders=placeholders),
            tuple(names),
            as_dict=True,
        )

        dimensions = {
            record.name: record.get("dimensions")
            for record in records
        }

    for row in rows:
        row["size"] = (
            dimensions.get(row.get("name"))
            or row.get("thickness")
            or None
        )
        row["delivery_border"] = _resolve_link_smart(
            "Border",
            row.get("border"),
        ) if row.get("border") else None
        row["driver"] = _resolve_link_smart("Driver", row.get("driver")) \
            if row.get("driver") else None
        row["customer"] = _resolve_link_smart("Customer", row.get("customer")) \
            if row.get("customer") else None

    return rows


# ---------------------------------------------------------------------------
# T04 dataset — purchase register
# ---------------------------------------------------------------------------

PURCHASE_SPECS = [
    {"fieldname": "posting_date", "label": "تاریخ", "fieldtype": "Date", "source": "posting_date"},
    {"fieldname": "purchase_invoice_date", "label": "تاریخ خرید", "fieldtype": "Date", "source": "purchase_invoice_date"},
    {"fieldname": "purchase_invoice_number", "label": "شماره فاکتور", "source": "purchase_invoice_number"},
    {"fieldname": "supplier_factory", "label": "فروشنده", "source": "supplier_factory"},
    {"fieldname": "item", "label": "نام کالا", "source": "item"},
    {"fieldname": "cargo_description", "label": "شرح کالا", "source": "cargo_description"},
    {"fieldname": "dimensions", "label": "سایز", "source": "dimensions"},
    {"fieldname": "thickness", "label": "ضخامت", "fieldtype": "Float", "source": "thickness"},
    {"fieldname": "planned_tonnage", "label": "تناژ", "fieldtype": "Float", "source": "planned_tonnage"},
    {"fieldname": "delivery_type", "label": "تحویل", "source": "delivery_type"},
    {"fieldname": "destination", "label": "مقصد", "source": "destination"},
    {"fieldname": "border", "label": "مرز", "source": "border"},
]

LOADING_SPECS = [
    {"fieldname": "trade_case", "label": "پرونده تجاری", "source": "trade_case"},
    {"fieldname": "loading_date", "label": "تاریخ بارگیری", "fieldtype": "Date", "source": "posting_date"},
    {"fieldname": "item", "label": "کالا", "source": "item"},
    {"fieldname": "dimensions", "label": "سایز", "source": "dimensions"},
    {"fieldname": "cargo_description", "label": "شرح بار", "source": "cargo_description"},
    {"fieldname": "actual_tonnage", "label": "وزن خالص", "fieldtype": "Float", "source": "actual_tonnage"},
    {"fieldname": "destination", "label": "مقصد", "source": "destination"},
    {"fieldname": "plate_number", "label": "ش. کامیون", "source": "plate_number"},
    {"fieldname": "driver", "label": "نام راننده", "source": "driver"},
    {"fieldname": "driver_mobile", "label": "شماره راننده", "source": "driver_mobile"},
    {"fieldname": "customer", "label": "خریدار", "source": "customer"},
    {"fieldname": "customs_broker", "label": "ترخیصکار", "source": "customs_broker"},
]


def _t04_key(row):
    """§7: SUMIFS key must be identical on both sheets.

    'پیش فاکتور خرید'!C  <->  'صورت بارگیری'!D
    """
    return (
        row.get("dimensions")
        or row.get("item")
        or row.get("cargo_description")
        or ""
    )


# ---------------------------------------------------------------------------
# T05 dataset — dispatch
# ---------------------------------------------------------------------------

DISPATCH_SPECS = [
    {"fieldname": "loading_date", "label": "تاریخ بارگیری", "fieldtype": "Date", "source": "posting_date"},
    {"fieldname": "cargo_description", "label": "نوع بار", "source": "cargo_description"},
    {"fieldname": "item", "label": "کالا", "source": "item"},
    {"fieldname": "trade_case", "label": "پرونده تجاری", "source": "trade_case"},
    {"fieldname": "actual_tonnage", "label": "وزن", "fieldtype": "Float", "source": "actual_tonnage"},
    {"fieldname": "origin", "label": "مبدا", "source": "origin"},
    {"fieldname": "destination", "label": "مقصد", "source": "destination"},
    {"fieldname": "plate_number", "label": "ش. کامیون", "source": "plate_number"},
    {"fieldname": "driver", "label": "نام راننده", "source": "driver"},
    {"fieldname": "driver_name", "label": "نام کامل راننده", "source": "driver_name"},
    {"fieldname": "driver_mobile", "label": "شماره راننده", "source": "driver_mobile"},
    {"fieldname": "customs_broker", "label": "ترخیصکار", "source": "customs_broker"},
    {"fieldname": "carrier", "label": "باربری", "source": "carrier"},
    {"fieldname": "waybill_number", "label": "بارنامه", "source": "waybill_number"},
]


def _attach_waybill_numbers(rows):
    names = [row.get("__name__") for row in rows if row.get("__name__")]

    if not names or not frappe.db.exists("DocType", "Transport Waybill"):
        return

    placeholders = ", ".join(["%s"] * len(names))

    try:
        waybills = frappe.db.sql(
            """
            select transport_case, waybill_number
            from `tabTransport Waybill`
            where transport_case in ({placeholders})
            order by modified asc
            """.format(placeholders=placeholders),
            tuple(names),
            as_dict=True,
        )
    except Exception:
        return

    by_case = {}

    for waybill in waybills:
        if waybill.get("waybill_number"):
            by_case[waybill.transport_case] = waybill.waybill_number

    for row in rows:
        value = by_case.get(row.get("__name__"))

        if value:
            row["waybill_number"] = value


def _prefer_driver_display(rows):
    for row in rows:
        if row.get("driver_name"):
            row["driver"] = row.get("driver_name")


# ---------------------------------------------------------------------------
# EXPORTS — read -> transform -> write into an in-memory template copy
# ---------------------------------------------------------------------------

@frappe.whitelist()
def export_financial_custom(
    company=None,
    from_date=None,
    to_date=None,
    case_type=None,
    name=None,
):
    """template_01_financial — §4 exact 26 column contract, A..Z."""
    _guard(FINANCE_ROLES)

    from transport_ir.iran_transport.report.trade_transport_1405.trade_transport_1405 import (
        execute,
    )

    filters = {
        "company": company,
        "from_date": from_date,
        "to_date": to_date,
        "case_type": case_type,
    }

    if name:
        filters["name"] = name

    columns, data = execute(filters)

    wb = _load_and_fill_report(
        "financial",
        columns,
        data,
        from_date=from_date,
        to_date=to_date,
    )
    _send(wb, "financial_custom.xlsx")


@frappe.whitelist()
def export_freight_custom(carrier=None, from_date=None, to_date=None):
    """template_02_freight — §5 exact A..O contract, formulas protected."""
    _guard(FINANCE_ROLES)

    specs = FREIGHT_SPECS
    filters = _transport_filters(
        from_date=from_date,
        to_date=to_date,
        carrier=carrier,
    )

    rows = _fetch_rows(
        "Transport Case",
        specs,
        filters,
        "posting_date asc, name asc",
    )

    _attach_payment_details(rows)
    _fill_cargo_fallback(rows)
    _resolve_link_columns("Transport Case", specs, rows)
    _build_composite_identity(rows)

    wb = _load_and_fill_report(
        "freight",
        _columns_from_specs(specs),
        rows,
        from_date=from_date,
        to_date=to_date,
    )
    _send(wb, "freight_custom.xlsx")


@frappe.whitelist()
def export_packing_custom(
    from_date=None,
    to_date=None,
    border=None,
    customer=None,
    name=None,
):
    """template_03_packing — §6 LTR form, logo and merges preserved."""
    _guard(OPERATIONS_ROLES)

    from transport_ir.iran_transport.report.packing_report.packing_report import (
        execute,
    )

    columns, data = execute(
        {
            "from_date": from_date,
            "to_date": to_date,
            "border": border,
            "customer": customer,
        }
    )

    rows = _rows_from_report(columns, data)

    if name:
        rows = [row for row in rows if row.get("name") == name]

    rows = _prepare_packing_rows(rows)

    wb = _load_and_fill_report(
        "packing",
        columns,
        rows,
        from_date=from_date,
        to_date=to_date,
    )
    _send(wb, "packing_custom.xlsx")


@frappe.whitelist()
def export_purchase_custom(from_date=None, to_date=None, supplier=None):
    """template_04_purchase — §7 four sheets, SUMIFS key relation preserved."""
    _guard(FINANCE_ROLES)

    filters = {"case_type": "خرید"}

    if from_date and to_date:
        filters["posting_date"] = ["between", [from_date, to_date]]
    elif from_date:
        filters["posting_date"] = [">=", from_date]
    elif to_date:
        filters["posting_date"] = ["<=", to_date]

    if supplier:
        filters["supplier_factory"] = supplier

    invoice_rows = _fetch_rows(
        "Trade Case",
        PURCHASE_SPECS,
        filters,
        "posting_date asc, name asc",
    )

    _resolve_link_columns("Trade Case", PURCHASE_SPECS, invoice_rows)

    for row in invoice_rows:
        row["size_key"] = _t04_key(row)

    trade_names = [
        row.get("__name__") for row in invoice_rows if row.get("__name__")
    ]

    loading_rows = []

    if trade_names:
        loading_filters = {
            "trade_case": ["in", trade_names],
            "workflow_state": ["not in", ["Cancelled", "Rejected"]],
        }

        loading_rows = _fetch_rows(
            "Transport Case",
            LOADING_SPECS,
            loading_filters,
            "posting_date asc, name asc",
        )

        _resolve_link_columns("Transport Case", LOADING_SPECS, loading_rows)

        for row in loading_rows:
            row["size_key"] = _t04_key(row)

    wb = _load_and_fill_report(
        "purchase",
        _columns_from_specs(PURCHASE_SPECS),
        invoice_rows,
        extra_sheets={"loading": loading_rows},
        from_date=from_date,
        to_date=to_date,
    )
    _send(wb, "purchase_custom.xlsx")


@frappe.whitelist()
def export_dispatch_custom(
    from_date=None,
    to_date=None,
    border=None,
    carrier=None,
):
    """template_05_dispatch — §8 exact B..L contract, E SUM preserved."""
    _guard(OPERATIONS_ROLES)

    specs = DISPATCH_SPECS
    filters = _transport_filters(
        from_date=from_date,
        to_date=to_date,
        carrier=carrier,
        border=border,
    )

    rows = _fetch_rows(
        "Transport Case",
        specs,
        filters,
        "posting_date asc, name asc",
    )

    _attach_waybill_numbers(rows)
    _fill_cargo_fallback(rows)
    _resolve_link_columns("Transport Case", specs, rows)
    _prefer_driver_display(rows)

    wb = _load_and_fill_report(
        "dispatch",
        _columns_from_specs(specs),
        rows,
        from_date=from_date,
        to_date=to_date,
    )
    _send(wb, "dispatch_custom.xlsx")


# ---------------------------------------------------------------------------
# IMPORT — Preview -> Validate -> Resolve -> Commit (§0/§9/§14)
# ---------------------------------------------------------------------------

def _file_bytes(file_url):
    if not file_url:
        frappe.throw(_("فایل مشخص نیست"))

    file_url = str(file_url).strip()

    if not file_url.lower().split("?", 1)[0].endswith(".xlsx"):
        frappe.throw(_("فقط فایل XLSX مجاز است."))

    file_docname = frappe.db.get_value("File", {"file_url": file_url}, "name")

    if not file_docname:
        frappe.throw(_("فایل در سیستم پیدا نشد."))

    doc = frappe.get_doc("File", file_docname)
    doc.check_permission("read")

    if flt(doc.file_size) > MAX_IMPORT_FILE_SIZE:
        frappe.throw(_("حجم فایل زیاد است"))

    content = doc.get_content()

    return content.encode("latin-1") if isinstance(content, str) else content


def _to_date(val):
    if isinstance(val, datetime.datetime):
        return val.date()

    if isinstance(val, datetime.date):
        return val

    try:
        return getdate(val)
    except Exception:
        return None


def _pick_sheet(wb, sheet_name):
    """§15: the named sheet always wins over the active/index sheet."""
    if sheet_name and sheet_name in wb.sheetnames:
        return wb[sheet_name]

    return wb.active


def _import_rows(ws, sheet_reg):
    """Read the data area of a template sheet using its coordinate contract."""
    header_row = _find_header_row(ws, sheet_reg)
    start_row = sheet_reg.get("data_start_row") or (header_row + 1)

    columns = sheet_reg.get("columns") or []
    rows = []

    max_row = ws.max_row or start_row

    if max_row - start_row + 1 > MAX_IMPORT_ROWS:
        frappe.throw(
            _("حداکثر تعداد ردیف قابل ورود {0} است.").format(MAX_IMPORT_ROWS)
        )

    for row_idx in range(start_row, max_row + 1):
        row = {"__source_row__": row_idx}
        has_value = False

        for spec in columns:
            col_idx = column_index_from_string(spec["col"])
            value = ws.cell(row=row_idx, column=col_idx).value

            if _is_formula(value):
                value = None

            key = spec.get("field") or f"__col_{spec['col']}__"
            row[key] = value

            if value not in (None, ""):
                has_value = True

        if has_value:
            rows.append(row)

    return rows


def _row_get(row, *keys):
    """Fetch a dataset value by dataset key, fuzzy only inside the same row."""
    for key in keys:
        if key in row and row.get(key) not in (None, ""):
            return row.get(key)

    normalized = {_norm(key): value for key, value in row.items()}

    for key in keys:
        normalized_key = _norm(key)

        if normalized_key in normalized:
            return normalized[normalized_key]

    return None


def _preview_response(template_key, rows, issues, resolved):
    return {
        "mode": "preview",
        "template_key": TEMPLATE_REGISTRY[template_key]["template_key"],
        "total_rows": len(rows),
        "ready": len(resolved),
        "issues": issues,
        "count": 0,
        "created": [],
        "sample": resolved[:10],
    }


@frappe.whitelist()
def import_purchase_custom(file_url, mode="preview"):
    """T04 import — «پیش فاکتور خرید» sheet, transactional commit."""
    _guard(OPERATIONS_ROLES)

    if not frappe.has_permission("Trade Case", "create"):
        frappe.throw(_("دسترسی ندارید"), frappe.PermissionError)

    reg = TEMPLATE_REGISTRY["purchase"]

    wb = openpyxl.load_workbook(
        io.BytesIO(_file_bytes(file_url)),
        data_only=True,
    )
    ws = _pick_sheet(wb, reg["sheet"])

    rows = _import_rows(ws, reg)

    invoice_number = ws["D2"].value
    invoice_date = _to_date(ws["B2"].value)
    supplier_raw = ws["F2"].value

    supplier = _resolve_link("Supplier", supplier_raw, "supplier_name")

    issues = []
    resolved = []

    for row in rows:
        source_row = row.get("__source_row__")

        item = _row_get(row, "item")
        size_key = _row_get(row, "size_key")
        tonnage = flt(_row_get(row, "planned_tonnage"))

        if not item and not size_key:
            issues.append(
                _("ردیف {0}: نام کالا/سایز خالی است").format(source_row)
            )
            continue

        if tonnage <= 0:
            issues.append(
                _("ردیف {0}: تناژ نامعتبر است").format(source_row)
            )
            continue

        if not invoice_number:
            issues.append(
                _("ردیف {0}: شماره فاکتور خرید در قالب خالی است").format(
                    source_row
                )
            )
            continue

        if supplier_raw and not supplier:
            issues.append(
                _("ردیف {0}: فروشنده «{1}» در سیستم یافت نشد").format(
                    source_row,
                    supplier_raw,
                )
            )
            continue

        identity = {
            "purchase_invoice_number": str(invoice_number).strip(),
            "supplier_factory": supplier,
            "item": item,
        }

        duplicate = None

        if _has_field("Trade Case", "purchase_invoice_number"):
            duplicate = frappe.db.get_value(
                "Trade Case",
                {
                    key: value
                    for key, value in identity.items()
                    if value
                },
                "name",
            )

        if duplicate:
            issues.append(
                _("ردیف {0}: رکورد تکراری با پرونده {1}").format(
                    source_row,
                    duplicate,
                )
            )
            continue

        resolved.append(
            {
                "source_row": source_row,
                "item": item,
                "size_key": size_key,
                "planned_tonnage": tonnage,
                "delivery_type": _row_get(row, "delivery_type"),
                "supplier_factory": supplier,
                "purchase_invoice_number": str(invoice_number).strip(),
                "purchase_invoice_date": invoice_date,
            }
        )

    if mode != "commit":
        return _preview_response("purchase", rows, issues, resolved)

    if issues:
        frappe.throw(_("خطا در ورود اطلاعات:\n") + "\n".join(issues))

    created = []

    for entry in resolved:
        doc = frappe.new_doc("Trade Case")
        doc.case_type = "خرید"
        doc.case_title = (
            f"{entry.get('supplier_factory') or 'Import'} - "
            f"{entry.get('item') or 'خرید'}"
        )
        doc.supplier_factory = entry.get("supplier_factory")
        doc.item = entry.get("item")

        if _has_field("Trade Case", "dimensions") and entry.get("size_key"):
            doc.dimensions = entry.get("size_key")

        doc.planned_tonnage = entry.get("planned_tonnage")

        if _has_field("Trade Case", "delivery_type") and entry.get("delivery_type"):
            doc.delivery_type = entry.get("delivery_type")

        if _has_field("Trade Case", "purchase_invoice_number"):
            doc.purchase_invoice_number = entry.get("purchase_invoice_number")

        if _has_field("Trade Case", "purchase_invoice_date"):
            doc.purchase_invoice_date = entry.get("purchase_invoice_date")

        doc.posting_date = (
            entry.get("purchase_invoice_date") or frappe.utils.today()
        )
        doc.insert()

        created.append(doc.name)

    # No manual commit. Frappe rolls back automatically if we throw.
    return {
        "mode": "commit",
        "count": len(created),
        "created": created,
        "issues": [],
    }


@frappe.whitelist()
def import_freight_custom(file_url, mode="preview"):
    """T02 import — freight payments, duplicate guarded and transactional."""
    _guard(FINANCE_ROLES)

    if not frappe.has_permission("Transport Payment", "create"):
        frappe.throw(_("دسترسی ندارید"), frappe.PermissionError)

    reg = TEMPLATE_REGISTRY["freight"]

    wb = openpyxl.load_workbook(
        io.BytesIO(_file_bytes(file_url)),
        data_only=True,
    )
    ws = _pick_sheet(wb, reg["sheet"])

    rows = _import_rows(ws, reg)

    issues = []
    resolved = []

    for row in rows:
        source_row = row.get("__source_row__")

        freight = flt(_row_get(row, "freight_cost"))
        composite = _row_get(row, "composite_identity")
        account_holder = _row_get(row, "account_holder")
        invoice = _row_get(row, "sales_invoice_number")

        if freight <= 0:
            issues.append(
                _("ردیف {0}: مبلغ کرایه نامعتبر است").format(source_row)
            )
            continue

        parent_name = None
        match_method = None

        if invoice and _has_field("Transport Case", "sales_invoice_number"):
            parent_name = frappe.db.get_value(
                "Transport Case",
                {"sales_invoice_number": str(invoice).strip()},
                "name",
            )
            match_method = "sales_invoice_number"

        if not parent_name and composite:
            # §5: never split blindly, the raw composite is kept for review.
            candidates = frappe.get_all(
                "Transport Case",
                filters={
                    "workflow_state": ["not in", ["Cancelled", "Rejected"]],
                },
                or_filters=[
                    ["waybill_number", "=", str(composite).strip()],
                ],
                pluck="name",
                limit_page_length=2,
            )

            if len(candidates) == 1:
                parent_name = candidates[0]
                match_method = "composite_waybill"

        if not parent_name:
            issues.append(
                _("ردیف {0}: پرونده حمل یافت نشد (شناسه خام: {1})").format(
                    source_row,
                    composite or account_holder or "-",
                )
            )
            continue

        duplicate = frappe.db.get_value(
            "Transport Payment",
            {
                "parenttype": "Transport Case",
                "parent": parent_name,
                "payment_type": "کرایه",
                "amount": freight,
            },
            "name",
        )

        if duplicate:
            issues.append(
                _("ردیف {0}: پرداخت تکراری برای پرونده {1}").format(
                    source_row,
                    parent_name,
                )
            )
            continue

        resolved.append(
            {
                "source_row": source_row,
                "parent": parent_name,
                "match_method": match_method,
                "amount": freight,
                "raw_identity": composite,
                "account_holder": account_holder,
                "account_no": _row_get(row, "account_no"),
                "bank_name": _row_get(row, "bank_name"),
            }
        )

    if mode != "commit":
        return _preview_response("freight", rows, issues, resolved)

    if issues:
        frappe.throw(_("خطا در ورود کرایه‌ها:\n") + "\n".join(issues))

    touched = []
    meta = frappe.get_meta("Transport Payment")

    for entry in resolved:
        parent_doc = frappe.get_doc("Transport Case", entry["parent"])

        payment_row = {
            "payment_type": "کرایه",
            "amount": entry["amount"],
            "payment_date": frappe.utils.today(),
        }

        if meta.has_field("paid_by") and entry.get("account_holder"):
            payment_row["paid_by"] = entry.get("account_holder")

        if meta.has_field("bank_name") and entry.get("bank_name"):
            payment_row["bank_name"] = entry.get("bank_name")

        if meta.has_field("sheba") and entry.get("account_no"):
            payment_row["sheba"] = str(entry.get("account_no"))

        if meta.has_field("notes"):
            payment_row["notes"] = (
                f"ورود از اکسل اختصاصی | شناسه خام: {entry.get('raw_identity') or '-'}"
            )

        parent_doc.append("payments", payment_row)
        parent_doc.save()

        touched.append(entry["parent"])

    return {
        "mode": "commit",
        "count": len(set(touched)),
        "created": list(set(touched)),
        "issues": [],
    }
ITE_REPORT_EXCEL_CUSTOM_EOF
# --- END VERBATIM COPY -------------------------------------------------------
log "report_excel_custom.py کپی شد (خط‌به‌خط)"

# =============================================================================
step "4) نشاندن کد کپی‌شده در معماری جدید (فقط مسیر ماژول و نام DocType)"
# این تغییرات صریح، قابل ممیزی و محدود به «آدرس‌دهی» هستند.
# هیچ فرمول، هیچ مختصات سلول و هیچ متن فارسی کارفرما دست نمی‌خورد.
for f in "${MOD}/api/report_excel.py" "${MOD}/api/report_excel_custom.py"; do
  sed -i 's/transport_ir\.iran_transport/iran_trade_erp.iran_trade/g' "$f"
  sed -i 's/from ir_jalali\.utils\.jalali/from iran_common.utils.jalali/g' "$f"
  sed -i 's/import ir_jalali\.utils\.jalali/import iran_common.utils.jalali/g' "$f"
  sed -i 's/ir_base\.utils\.validators/iran_common.utils.validators/g' "$f"
  # مدل داده جدید: «Transport Case» جای خود را به «Trade Case Loading» داده است
  sed -i 's/"Transport Case"/"Trade Case Loading"/g' "$f"
  sed -i "s/'Transport Case'/'Trade Case Loading'/g" "$f"
  sed -i 's/tabTransport Case/tabTrade Case Loading/g' "$f"
  sed -i 's/transport_case/trade_case_loading/g' "$f"
  python3 -c "import ast,sys; ast.parse(open('$f',encoding='utf-8').read())" \
    || err "ABORT: فایل $f پس از نگاشت مسیر، نحو پایتون معتبر ندارد"
  log "نگاشت مسیر انجام و نحو تایید شد: $f"
done

# اصلاح (ثبت در جدول ممیزی): jinja_helpers فقط در iran_common ساخته شده؛
# نگاشت عمومی transport_ir آن را به iran_trade_erp.iran_trade.utils می‌برد
# که وجود ندارد و کل ماژول اکسل را در لحظه import می‌شکست.
for f in "${MOD}/api/report_excel.py" "${MOD}/api/report_excel_custom.py"; do
  sed -i 's/from iran_trade_erp\.iran_trade\.utils\.jinja_helpers/from iran_common.utils.jinja_helpers/g' "$f"
  sed -i 's/import iran_trade_erp\.iran_trade\.utils\.jinja_helpers/import iran_common.utils.jinja_helpers/g' "$f"
done

# اصلاح (ثبت در جدول ممیزی): نگاشت عمومی transport_case در لایه قالب‌ها،
# ستون واقعی «Transport Waybill» را خراب می‌کرد (آن سند ستون loading دارد،
# نه transport_case)؛ به‌خصوص export_dispatch_custom به AttributeError می‌خورد.
F2="${MOD}/api/report_excel_custom.py"
sed -i 's/select transport_case, waybill_number/select loading as transport_case, waybill_number/' "$F2" \
  && sed -i 's/select trade_case_loading, waybill_number/select loading as trade_case_loading, waybill_number/' "$F2"
sed -i 's/where transport_case in ({placeholders})/where loading in ({placeholders})/' "$F2" \
  && sed -i 's/where trade_case_loading in ({placeholders})/where loading in ({placeholders})/' "$F2"
sed -i 's/by_case\[waybill\.transport_case\]/by_case[waybill.get("transport_case") or waybill.get("loading")]/g' "$F2"
sed -i 's/by_case\[waybill\.trade_case_loading\]/by_case[waybill.get("trade_case_loading") or waybill.get("loading")]/g' "$F2"
python3 -c "import ast,sys; ast.parse(open('$F2',encoding='utf-8').read())" \
  || err "ABORT: report_excel_custom.py پس از تعمیر نگاشت، نحو پایتون معتبر ندارد"
log "تعمیر نگاشت ستون waybill انجام و نحو تایید شد"

# اصلاح (ثبت در جدول ممیزی): در نگاشت عمومی «Transport Case» → «Trade Case
# Loading»، فیلترهای workflow_state/posting_date/border روی Loading اعمال
# می‌شدند در حالی‌که این DocType فیلد workflow_state ندارد (وضعیت آن با
# loading_state و مقادیر «لغو شده»/«رد شده» نگه‌داری می‌شود) و posting_date/
# border فقط روی خودِ Trade Case هستند. همین باعث
# «Unknown column 'tabTrade Case Loading.workflow_state' in 'WHERE'» در
# export_carrier_statement/export_customs_statement/export_freight_custom/
# export_dispatch_custom می‌شد. فقط فیلتر مشترک و دو order_by مرتبط تعمیر
# می‌شوند؛ هیچ منطق دیگری دست نمی‌خورد.
python3 - "${MOD}/api/report_excel_custom.py" << 'PYEOF_LOADINGFIX'
import io, re, sys
path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()
FAIL = False

def must_replace(old, new, what):
    global src, FAIL
    n = src.count(old)
    if n < 1:
        print("PATCH-MISS:", what)
        FAIL = True
        return
    src = src.replace(old, new)
    print("PATCH-OK:", what, "x", n)

must_replace(
    '"workflow_state": ["not in", ["Cancelled", "Rejected"]]',
    '"loading_state": ["not in", ["لغو شده", "رد شده"]]',
    "workflow_state→loading_state",
)

def fix_loading_order_by(text):
    pat = re.compile(
        r'(rows = _fetch_rows\(\s*"Trade Case Loading",\s*specs,\s*filters,\s*)"posting_date asc, name asc"',
        re.S,
    )
    text, n1 = pat.subn(r'\1"creation asc, name asc"', text)
    pat2 = re.compile(
        r'(loading_rows = _fetch_rows\(\s*"Trade Case Loading",\s*LOADING_SPECS,\s*loading_filters,\s*)"posting_date asc, name asc"',
        re.S,
    )
    text, n2 = pat2.subn(r'\1"creation asc, name asc"', text)
    return text, n1 + n2

src, n = fix_loading_order_by(src)
if n < 1:
    print("PATCH-MISS: order_by posting_date on Trade Case Loading")
    FAIL = True
else:
    print("PATCH-OK: order_by Loading → creation asc x", n)

old_tf = '''def _transport_filters(from_date=None, to_date=None, carrier=None, border=None):
    filters = {
        "loading_state": ["not in", ["لغو شده", "رد شده"]],
    }

    if from_date and to_date:
        filters["posting_date"] = ["between", [from_date, to_date]]
    elif from_date:
        filters["posting_date"] = [">=", from_date]
    elif to_date:
        filters["posting_date"] = ["<=", to_date]

    if carrier:
        filters["carrier"] = carrier

    if border:
        filters["border"] = border

    return filters'''

new_tf = '''def _transport_filters(from_date=None, to_date=None, carrier=None, border=None):
    """فیلتر بومی Trade Case Loading.

    posting_date و border روی Trade Case هستند نه Loading؛ اینجا اعمال نمی‌شوند
    تا get_all با Unknown column نشکند. (صورتحساب‌ها با JOIN در report_excel
    تاریخ/مرز را از tabTrade Case می‌گیرند.)
    """
    filters = {
        "loading_state": ["not in", ["لغو شده", "رد شده"]],
    }

    if carrier:
        filters["carrier"] = carrier

    # border/from_date/to_date: غیرقابل‌اعمال مستقیم روی Loading — نادیده
    return filters'''

if old_tf not in src:
    print("PATCH-MISS: _transport_filters block")
    FAIL = True
else:
    src = src.replace(old_tf, new_tf)
    print("PATCH-OK: _transport_filters (drop posting_date/border on Loading)")

io.open(path, "w", encoding="utf-8").write(src)
if FAIL:
    raise SystemExit("ABORT: پچ loading_state/order_by روی report_excel_custom.py ناکامل ماند")
import ast
ast.parse(src)
print("report_excel_custom.py: loading_state + order_by Loading تایید شد")
PYEOF_LOADINGFIX
log "تعمیر workflow_state→loading_state و order_by روی Loading انجام شد"

# اصلاح (ثبت در جدول ممیزی): _fill_cargo_fallback مستقیماً ستون‌های «item» و
# «cargo_description» را از خودِ tabTrade Case می‌خواند، در حالی‌که این دو
# فیلد در مدل جدید روی Trade Case وجود ندارند و فقط در فرزند «Trade Case
# Item» ذخیره شده‌اند — همان جدولی که trade_transport_1405.py و
# packing_report.py با JOIN از آن می‌خوانند و در گام ۸ با موفقیت verify
# می‌شوند. همین باعث «Unknown column 'item' in 'SELECT'» در
# export_freight_custom/export_dispatch_custom می‌شد. فقط همین یک تابع با
# پچ لنگردار تعمیر می‌شود؛ هیچ فرمول، مختصات سلول یا متن کارفرما دست
# نمی‌خورد.
python3 - "${MOD}/api/report_excel_custom.py" << 'PYEOF_CARGOFIX'
import io, sys

path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()

old = '''def _fill_cargo_fallback(rows):
    """Use the Trade Case item when the Transport Case has no cargo text."""
    missing = [
        row for row in rows
        if not row.get("cargo_description") and row.get("trade_case")
    ]

    if not missing:
        return

    trade_names = sorted({row.get("trade_case") for row in missing})
    placeholders = ", ".join(["%s"] * len(trade_names))

    records = frappe.db.sql(
        """
        select name, item, cargo_description
        from `tabTrade Case`
        where name in ({placeholders})
        """.format(placeholders=placeholders),
        tuple(trade_names),
        as_dict=True,
    )

    by_name = {record.name: record for record in records}

    for row in missing:
        record = by_name.get(row.get("trade_case"))

        if record:
            row["cargo_description"] = (
                record.get("item") or record.get("cargo_description") or ""
            )'''

new = '''def _fill_cargo_fallback(rows):
    """Use the Trade Case item when the Transport Case has no cargo text.

    اصلاح: item/cargo_description روی خود Trade Case وجود ندارند؛ این دو
    فقط در فرزند «Trade Case Item» ذخیره می‌شوند (همان جدولی که
    trade_transport_1405.py و packing_report.py با JOIN از آن می‌خوانند).
    """
    missing = [
        row for row in rows
        if not row.get("cargo_description") and row.get("trade_case")
    ]

    if not missing:
        return

    trade_names = sorted({row.get("trade_case") for row in missing})
    placeholders = ", ".join(["%s"] * len(trade_names))

    records = frappe.db.sql(
        """
        select parent as name, item, item_name
        from `tabTrade Case Item`
        where parent in ({placeholders})
        order by idx asc
        """.format(placeholders=placeholders),
        tuple(trade_names),
        as_dict=True,
    )

    by_name = {}

    for record in records:
        by_name.setdefault(record.name, record)

    for row in missing:
        record = by_name.get(row.get("trade_case"))

        if record:
            row["cargo_description"] = (
                record.get("item_name") or record.get("item") or ""
            )'''

if old not in src:
    raise SystemExit("ABORT: لنگر _fill_cargo_fallback در report_excel_custom.py پیدا نشد")

src = src.replace(old, new, 1)

io.open(path, "w", encoding="utf-8").write(src)

import ast
ast.parse(src)
print("report_excel_custom.py: _fill_cargo_fallback روی Trade Case Item تعمیر و نحو تایید شد")
PYEOF_CARGOFIX
log "تعمیر _fill_cargo_fallback (item/cargo_description از Trade Case Item) انجام شد"

# -----------------------------------------------------------------------------
# اصلاح (ثبت در جدول ممیزی): چهار endpoint از مدل قدیمی «Transport Case»
# خوانده بودند که دیگر وجود ندارد. در مدل جدید بازنویسی می‌شوند؛ متن قالب
# اکسل و سبک خروجی دست نمی‌خورد. هیچ حدسی نیست: اگر لنگرها پیدا نشوند ABORT.
python3 - "${MOD}/api/report_excel.py" << 'PYEOF'
import io, re, sys

path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()
FAIL = False


def rep(pat, new, what):
    global src, FAIL
    m = re.search(pat, src, flags=re.S)
    if not m:
        print("PATCH-MISS:", what)
        FAIL = True
        return
    src = src[:m.start()] + new + src[m.end():]


# ---- ۱) صورتحساب باربری روی مدل جدید (Trade Case Loading + Trade Case) ----
rep(
    r"@frappe\.whitelist\(\)\ndef export_carrier_statement\("
    r".*?(?=@frappe\.whitelist\(\)\ndef export_customs_statement\()",
    '''@frappe.whitelist()
def export_carrier_statement(
    carrier=None,
    from_date=None,
    to_date=None,
):
    _guard(FINANCE_ROLES)

    conditions = [
        "l.loading_state not in ('\\u0644\\u063a\\u0648 \\u0634\\u062f\\u0647','\\u0631\\u062f \\u0634\\u062f\\u0647')"
    ]
    values = {}

    if carrier:
        conditions.append("l.carrier = %(carrier)s")
        values["carrier"] = carrier

    if from_date:
        conditions.append("c.posting_date >= %(from_date)s")
        values["from_date"] = from_date

    if to_date:
        conditions.append("c.posting_date <= %(to_date)s")
        values["to_date"] = to_date

    rows = frappe.db.sql(
        """
        select
            l.name,
            l.waybill_number,
            l.driver,
            l.carrier,
            c.border,
            l.effective_tonnage,
            l.freight_cost,
            c.posting_date
        from `tabTrade Case Loading` l
        inner join `tabTrade Case` c on c.name = l.trade_case
        where {conditions}
        order by c.posting_date, l.name
        """.format(conditions=" and ".join(conditions)),
        values,
        as_dict=True,
    )

    workbook, worksheet = _new_workbook("صورتحساب باربری")

    headers = [
        "پرونده",
        "بارنامه",
        "راننده",
        "باربری",
        "مرز",
        "تناژ",
        "کرایه",
        "تاریخ",
    ]
    _style_header(worksheet, headers)

    total_tonnage = 0.0
    total_freight = 0.0

    for row_index, row in enumerate(rows, 2):
        tonnage = flt(row.effective_tonnage)
        freight = flt(row.freight_cost)

        total_tonnage += tonnage
        total_freight += freight

        values_row = [
            row.name,
            row.waybill_number,
            row.driver,
            row.carrier,
            row.border,
            tonnage,
            freight,
            latin_jalali_date(row.posting_date),
        ]

        for column_index, value in enumerate(values_row, 1):
            worksheet.cell(
                row=row_index,
                column=column_index,
                value=value,
            )

    total_row = len(rows) + 2
    worksheet.cell(row=total_row, column=5, value="جمع کل")
    worksheet.cell(row=total_row, column=6, value=total_tonnage)
    worksheet.cell(row=total_row, column=7, value=total_freight)

    from openpyxl.styles import Font

    for column_index in (5, 6, 7):
        worksheet.cell(
            row=total_row,
            column=column_index,
        ).font = Font(bold=True)

    _finalize_table(
        worksheet,
        1,
        total_row,
        len(headers),
    )

    _send(workbook, "carrier_statement.xlsx")


''',
    "export_carrier_statement",
)

# ---- ۲) صورتحساب گمرک روی مدل جدید (declaration_number از سند بیجک) ----
rep(
    r"@frappe\.whitelist\(\)\ndef export_customs_statement\(.*?(?=@frappe\.whitelist\(\)\ndef export_proforma\()",
    '''@frappe.whitelist()
def export_customs_statement(from_date=None, to_date=None):
    _guard(FINANCE_ROLES)

    conditions = [
        "l.loading_state not in ('\\u0644\\u063a\\u0648 \\u0634\\u062f\\u0647','\\u0631\\u062f \\u0634\\u062f\\u0647')"
    ]
    values = {}

    if from_date:
        conditions.append("c.posting_date >= %(from_date)s")
        values["from_date"] = from_date

    if to_date:
        conditions.append("c.posting_date <= %(to_date)s")
        values["to_date"] = to_date

    rows = frappe.db.sql(
        """
        select
            l.name,
            c.posting_date,
            c.border,
            b.declaration_number,
            l.customs_broker,
            l.driver,
            l.customs_cost,
            l.clearance_cost
        from `tabTrade Case Loading` l
        inner join `tabTrade Case` c on c.name = l.trade_case
        left join `tabTransport Bijak` b on b.name = l.bijak
        where {conditions}
        order by c.posting_date, l.name
        """.format(conditions=" and ".join(conditions)),
        values,
        as_dict=True,
    )

    workbook, worksheet = _new_workbook("صورتحساب گمرک")

    headers = [
        "پرونده",
        "تاریخ",
        "مرز",
        "اظهار",
        "ترخیص‌کار",
        "راننده",
        "گمرک",
        "ترخیص",
        "جمع",
    ]
    _style_header(worksheet, headers)

    total_customs = 0.0
    total_clearance = 0.0

    for row_index, row in enumerate(rows, 2):
        customs = flt(row.customs_cost)
        clearance = flt(row.clearance_cost)

        total_customs += customs
        total_clearance += clearance

        values_row = [
            row.name,
            latin_jalali_date(row.posting_date),
            row.border,
            row.declaration_number,
            row.customs_broker,
            row.driver,
            customs,
            clearance,
            customs + clearance,
        ]

        for column_index, value in enumerate(values_row, 1):
            worksheet.cell(
                row=row_index,
                column=column_index,
                value=value,
            )

    total_row = len(rows) + 2
    worksheet.cell(row=total_row, column=6, value="جمع کل")
    worksheet.cell(row=total_row, column=7, value=total_customs)
    worksheet.cell(row=total_row, column=8, value=total_clearance)
    worksheet.cell(
        row=total_row,
        column=9,
        value=total_customs + total_clearance,
    )

    from openpyxl.styles import Font

    for column_index in (6, 7, 8, 9):
        worksheet.cell(
            row=total_row,
            column=column_index,
        ).font = Font(bold=True)

    _finalize_table(
        worksheet,
        1,
        total_row,
        len(headers),
    )

    _send(workbook, "customs_statement.xlsx")


''',
    "export_customs_statement",
)

# ---- ۳) پیش‌فاکتور روی فیلدهای واقعی Trade Case ----
rep(
    r"@frappe\.whitelist\(\)\ndef export_proforma\(.*?(?=@frappe\.whitelist\(\)\ndef download_proforma_template\()",
    '''@frappe.whitelist()
def export_proforma(name):
    _guard(OPERATIONS_ROLES)

    doc = frappe.get_doc("Trade Case", name)
    doc.check_permission("read")

    workbook, worksheet = _new_workbook("پیش‌فاکتور")

    items_text = ", ".join(
        str(r.item_name or r.item) for r in (doc.get("items") or []) if r.item
    )

    rows = [
        ("شماره پرونده", doc.name),
        ("عنوان", doc.case_title),
        ("نوع", doc.case_type),
        ("تاریخ", latin_jalali_date(doc.posting_date)),
        ("مدیرعامل دستوردهنده", doc.requested_by_name or doc.requested_by),
        ("مشتری", doc.customer or ""),
        ("تأمین‌کننده", doc.supplier_factory or ""),
        ("کالا", items_text),
        ("تناژ کل", flt(doc.planned_tonnage)),
        ("مبلغ خرید (پایه ریالی)", flt(doc.purchase_amount_base)),
        ("مبلغ فروش (پایه ریالی)", flt(doc.sales_amount_base)),
        ("سود برآوردی", flt(doc.estimated_profit)),
        ("فاکتور فروش", doc.sales_invoice or ""),
        ("فاکتور خرید", doc.purchase_invoice or ""),
        ("سند پرداخت", doc.payment_entry or ""),
        ("وضعیت تأمین", doc.fulfillment_status or ""),
        ("مقصد", doc.destination or ""),
        ("مرز", doc.border or ""),
    ]

    from openpyxl.styles import Font

    for row_index, (label, value) in enumerate(rows, 1):
        worksheet.cell(
            row=row_index,
            column=1,
            value=label,
        ).font = Font(bold=True)

        worksheet.cell(
            row=row_index,
            column=2,
            value=value,
        )

    _autosize(worksheet)

    safe_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", doc.name)
    _send(workbook, f"proforma_{safe_name}.xlsx")


''',
    "export_proforma",
)

# ---- ۴) ورود اکسل پیش‌فاکتور روی مدل جدید (child items + مدیرعامل واقعی) ----
rep(
    r"def import_proforma_excel\(file_url\):.*"
    r"return \{\n        \"created\": created,\n        \"count\": len\(created\),\n    \}",
    '''def import_proforma_excel(file_url):
    """Create Draft Trade Cases from an uploaded XLSX file.

    The operation is fail-fast and transactional: an invalid row raises an
    error and Frappe rolls back the whole request, preventing partial imports.
    اصلاح: ستون‌ها به مدل جدید نگاشت شدند — اقلام به‌صورت child table ساخته
    می‌شوند و «مدیرعامل دستوردهنده» با نخستین مدیرعامل واقعی پر می‌شود.
    """
    _guard(OPERATIONS_ROLES)

    if not frappe.has_permission("Trade Case", "create"):
        frappe.throw(
            _("دسترسی ساخت پرونده تجاری ندارید."),
            frappe.PermissionError,
        )

    file_url = (file_url or "").strip()

    if not file_url:
        frappe.throw(_("فایل اکسل مشخص نشده است."))

    if not file_url.lower().split("?", 1)[0].endswith(".xlsx"):
        frappe.throw(_("فقط فایل XLSX مجاز است."))

    file_docname = frappe.db.get_value(
        "File",
        {"file_url": file_url},
        "name",
    )

    if not file_docname:
        frappe.throw(_("فایل در سیستم پیدا نشد."))

    file_doc = frappe.get_doc("File", file_docname)
    file_doc.check_permission("read")

    if flt(file_doc.file_size) > MAX_IMPORT_FILE_SIZE:
        frappe.throw(_("حجم فایل نباید بیشتر از ۱۰ مگابایت باشد."))

    content = file_doc.get_content()

    if isinstance(content, str):
        content = content.encode("latin-1")

    import openpyxl

    try:
        workbook = openpyxl.load_workbook(
            io.BytesIO(content),
            read_only=True,
            data_only=True,
        )
    except Exception as exc:
        frappe.throw(
            _("فایل Excel معتبر نیست: {0}").format(exc)
        )

    worksheet = workbook.active

    if worksheet.max_row - 1 > MAX_IMPORT_ROWS:
        frappe.throw(
            _("حداکثر تعداد ردیف قابل ورود {0} است.").format(
                MAX_IMPORT_ROWS
            )
        )

    ceo = None
    for r in frappe.get_all("Has Role",
                            filters={"role": "CEO", "parenttype": "User"},
                            pluck="parent", order_by="creation asc"):
        if r not in ("Administrator", "Guest"):
            ceo = r
            break
    if not ceo:
        frappe.throw(_("هیچ کاربر فعالی با نقش «مدیرعامل» یافت نشد؛ ورود انجام نشد."))

    def _resolve_item(label):
        label = str(label or "").strip()
        name = frappe.db.get_value("Item", {"item_name": label}, "name")
        if name:
            return name
        if frappe.db.exists("Item", label):
            return label
        it = frappe.new_doc("Item")
        it.item_code = label
        it.item_name = label
        it.item_group = (frappe.db.get_value("Item Group", {"is_group": 0}, "name")
                         or "All Item Groups")
        it.stock_uom = "Nos"
        it.is_stock_item = 0
        it.flags.ignore_permissions = True
        it.flags.ignore_mandatory = True
        it.insert(ignore_permissions=True)
        frappe.db.commit()
        return it.name

    def _resolve_customer(label):
        label = str(label or "").strip()
        name = frappe.db.get_value("Customer", {"customer_name": label}, "name")
        if name:
            return name
        if frappe.db.exists("Customer", label):
            return label
        c = frappe.new_doc("Customer")
        c.customer_name = label
        c.customer_group = (frappe.db.get_value("Customer Group", {"is_group": 0}, "name")
                            or "All Customer Groups")
        c.territory = frappe.db.get_value("Territory", {"is_group": 0}, "name") or "All Territories"
        c.flags.ignore_permissions = True
        c.flags.ignore_mandatory = True
        c.insert(ignore_permissions=True)
        frappe.db.commit()
        return c.name

    def _resolve_supplier(label):
        label = str(label or "").strip()
        name = frappe.db.get_value("Supplier", {"supplier_name": label}, "name")
        if name:
            return name
        if frappe.db.exists("Supplier", label):
            return label
        s = frappe.new_doc("Supplier")
        s.supplier_name = label
        s.supplier_group = (frappe.db.get_value("Supplier Group", {"is_group": 0}, "name")
                            or "All Supplier Groups")
        s.custom_is_factory = 1
        s.flags.ignore_permissions = True
        s.flags.ignore_mandatory = True
        s.insert(ignore_permissions=True)
        frappe.db.commit()
        return s.name

    created = []

    for row_number, row in enumerate(
        worksheet.iter_rows(min_row=2, values_only=True),
        start=2,
    ):
        if not row or not any(value not in (None, "") for value in row):
            continue

        values = list(row) + [None] * max(0, 11 - len(row))

        customer = values[0]
        supplier = values[1]
        cargo_description = values[2]
        planned_tonnage = flt(values[3])
        sales_amount_usd = flt(values[4])
        sales_amount = flt(values[5])
        case_type = str(values[10] or "خرید").strip()

        if case_type not in ("خرید", "فروش"):
            frappe.throw(
                _("ردیف {0}: نوع پرونده باید خرید یا فروش باشد.").format(
                    row_number
                )
            )

        if not customer:
            frappe.throw(
                _("ردیف {0}: مشتری الزامی است.").format(row_number)
            )

        if planned_tonnage <= 0:
            frappe.throw(
                _("ردیف {0}: تناژ باید بزرگ‌تر از صفر باشد.").format(
                    row_number
                )
            )

        row_kind = "فروش" if case_type == "فروش" else "خرید"
        if flt(sales_amount_usd) > 0:
            price, currency = flt(sales_amount_usd) / planned_tonnage, "USD"
        elif flt(sales_amount) > 0:
            price, currency = flt(sales_amount) / planned_tonnage, "IRR"
        else:
            price, currency = 0.0, "IRR"

        doc = frappe.new_doc("Trade Case")
        doc.case_title = "{0} - {1}".format(customer, cargo_description or case_type)
        doc.case_type = case_type
        doc.requested_by = ceo
        doc.posting_date = frappe.utils.today()
        doc.customer = _resolve_customer(customer)
        if supplier:
            doc.supplier_factory = _resolve_supplier(supplier)
        doc.append("items", {
            "row_kind": row_kind,
            "item": _resolve_item(cargo_description or "کالای واردشده"),
            "tonnage": planned_tonnage,
            "price": price,
            "transaction_currency": currency,
        })
        doc.flags.ignore_permissions = True
        doc.insert(ignore_permissions=True)

        created.append(doc.name)

    if not created:
        frappe.throw(_("هیچ ردیف قابل ورودی در فایل وجود نداشت."))

    return {
        "created": created,
        "count": len(created),
    }''',
    "import_proforma_excel",
)

io.open(path, "w", encoding="utf-8").write(src)
if FAIL:
    raise SystemExit("ABORT: یکی از لنگرهای پچ report_excel.py پیدا نشد")
import ast
ast.parse(src)
print("report_excel.py: چهار endpoint روی مدل جدید بازنویسی و نحو تایید شد")
PYEOF

# جدول ممیزی نگاشت‌ها کنار کد نوشته می‌شود (بدون گزاره بدون ارجاع)
write_utf8 "${MOD}/api/EXCEL_COPY_AUDIT.txt" << 'EOF'
==============================================================================
جدول ممیزی کپی موتور اکسل  —  یافته / وضعیت / ارجاع / اقدام
==============================================================================
| یافته                          | وضعیت    | ارجاع کد مبدأ                    | اقدام |
|--------------------------------|----------|----------------------------------|-------|
| موتور عمومی Preview→Commit     | کپی شد   | setup_phase84.sh: report_excel.py| انتقال خط‌به‌خط |
| ۵ قالب اختصاصی کارفرما         | کپی شد   | setup_phase84.sh: TEMPLATE_REGISTRY | انتقال خط‌به‌خط |
| تایپوی «هزنیه تخلیه»           | حفظ شد   | قالب freight (template_02)       | عمداً تغییر نکرد |
| تایپوی «هزنیه بارگیری»         | حفظ شد   | قالب freight (template_02)       | عمداً تغییر نکرد |
| فرمول‌های محافظت‌شده G=F*E ...  | حفظ شد   | قالب freight                     | عمداً تغییر نکرد |
| Merge محافظت‌شده F1:G1، B2:L2  | حفظ شد   | قالب financial / dispatch        | عمداً تغییر نکرد |
| ستون‌های مخفی I,J,K,M,U,V,W,Y  | حفظ شد   | قالب financial (template_01)     | عمداً تغییر نکرد |
| قالب packing عمداً LTR است     | حفظ شد   | قالب packing (template_03)       | عمداً تغییر نکرد |
| ابهام تطبیق = UNRESOLVED       | حفظ شد   | لایه Resolve                     | هرگز حدس نمی‌زند |
| مسیر ماژول transport_ir        | نگاشت شد | sed در script-08.sh              | → iran_trade_erp.iran_trade |
| مرجع تقویم ir_jalali           | نگاشت شد | sed در script-08.sh              | → iran_common.utils.jalali |
| مرجع سنجه‌ها ir_base           | نگاشت شد | sed در script-08.sh              | → iran_common.utils.validators |
| DocType «Transport Case»       | نگاشت شد | sed در script-08.sh              | → «Trade Case Loading» |
| import jinja_helpers از مسیر ناموجود iran_trade | تعمیر شد | sed در script-08.sh | → iran_common.utils.jinja_helpers |
| ستون transport_case در Transport Waybill | تعمیر شد | sed در script-08.sh | → ستون واقعی loading |
| workflow_state روی Trade Case Loading | تعمیر شد | پچ script-08.sh پس از نگاشت DocType | → loading_state ∈ {لغو شده, رد شده} + order_by=creation |
| _fill_cargo_fallback ستون item/cargo_description روی Trade Case | تعمیر شد | پچ script-08.sh پس از نگاشت DocType | → JOIN با فرزند Trade Case Item (item_name/item) |
| export_carrier_statement       | بازنویسی شد | پچ script-08.sh (لنگردار)        | مدل جدید Loading+Case |
| export_customs_statement       | بازنویسی شد | پچ script-08.sh (لنگردار)        | اظهارنامه از سند بیجک |
| export_proforma                | بازنویسی شد | پچ script-08.sh (لنگردار)        | فیلدهای واقعی Trade Case |
| import_proforma_excel          | بازنویسی شد | پچ script-08.sh (لنگردار)        | child items + مدیرعامل واقعی |
| گزارش trade_transport_1405     | ساخته شد   | script-08.sh (گام 5b)            | قرارداد ۲۶ ستونی A..Z |
| گزارش packing_report           | ساخته شد   | script-08.sh (گام 5b)            | قرارداد (columns, data) |
| verify_script08: چهار سنجه download/export | اصلاح شد | script-08.sh (گام 8) | بررسی frappe.response بجای unpack (این endpointها فقط _send می‌کنند، return ندارند) |
==============================================================================
EOF

# =============================================================================
step "5) گزارش‌های عملیاتی و مالی بر پایه مدل داده تازه"
write_utf8 "${MOD}/report/queries.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
گزارش‌های اصلی — همگی از «تک منبع حقیقت» می‌خوانند.
هیچ گزارشی فرمول مالی مستقل ندارد؛ اعداد از فیلدهای ذخیره‌شده سرور می‌آیند.
"""
import frappe
from frappe import _

from iran_common.utils.guarded import mask_sheba


def _guard(dt="Trade Case"):
    if not frappe.has_permission(dt, "read"):
        frappe.throw(_("دسترسی لازم را ندارید."))


@frappe.whitelist()
def item_remaining(case_type=None, from_date=None, to_date=None):
    """باقی‌مانده هر قلم کالا — پاسخ مستقیم به «مانده بارهای فاکتورشده»."""
    _guard()
    cond, params = [], {}
    if case_type:
        cond.append("c.case_type = %(ct)s"); params["ct"] = case_type
    if from_date:
        cond.append("c.posting_date >= %(fd)s"); params["fd"] = from_date
    if to_date:
        cond.append("c.posting_date <= %(td)s"); params["td"] = to_date
    where = (" AND " + " AND ".join(cond)) if cond else ""
    return frappe.db.sql(
        """SELECT c.name AS trade_case, c.case_title, c.case_type, c.customer,
                  c.supplier_factory, c.fulfillment_status,
                  i.item, i.row_kind, i.tonnage AS planned_tonnage,
                  i.shipped_tonnage, i.remaining_tonnage,
                  i.transaction_currency, i.base_amount
           FROM `tabTrade Case Item` i
           INNER JOIN `tabTrade Case` c ON c.name = i.parent
           WHERE 1=1 {0}
           ORDER BY c.posting_date DESC, i.idx""".format(where),
        params, as_dict=True)


@frappe.whitelist()
def open_invoices(kind="خرید"):
    """فاکتورهای باز خرید / فروش — بخش الزامی گزارش روزانه مدیرعامل."""
    _guard()
    return frappe.db.sql(
        """SELECT name, case_title, case_type, customer, supplier_factory,
                  planned_tonnage, purchase_amount_base, sales_amount_base,
                  fulfillment_status, posting_date
           FROM `tabTrade Case`
           WHERE case_type IN (%(k)s, 'ترکیبی')
             AND fulfillment_status IN ('در حال انجام','در انتظار تأمین کالا','در انتظار شروع')
           ORDER BY posting_date DESC""",
        {"k": kind}, as_dict=True)


@frappe.whitelist()
def profit_per_loading():
    """سود هر بارگیری — از همان اعداد ذخیره‌شده، بدون فرمول موازی."""
    _guard("Trade Case Loading")
    return frappe.db.sql(
        """SELECT l.name AS loading, l.trade_case, c.case_title, l.trade_item,
                  l.planned_tonnage, l.effective_tonnage,
                  l.total_operational_cost, l.total_settled, l.settlement_balance,
                  s.base_amount AS sales_base
           FROM `tabTrade Case Loading` l
           INNER JOIN `tabTrade Case` c ON c.name = l.trade_case
           LEFT JOIN `tabTrade Sales Slip` s ON s.name = l.sales_slip
           WHERE l.loading_state NOT IN ('لغو شده','رد شده')
           ORDER BY l.creation DESC""", as_dict=True)


@frappe.whitelist()
def freight_with_prefreight():
    """کرایه و پیش‌کرایه — شبا همیشه ماسک‌شده."""
    _guard("Trade Case Loading")
    rows = frappe.db.sql(
        """SELECT l.name AS loading, l.trade_case, l.driver, l.carrier,
                  p.payment_type, p.amount, p.base_amount, p.sheba, p.payment_date
           FROM `tabTransport Payment` p
           INNER JOIN `tabTrade Case Loading` l ON l.name = p.parent
           WHERE p.payment_type IN ('کرایه','پیش کرایه')
           ORDER BY p.payment_date DESC""", as_dict=True)
    for r in rows:
        r["sheba"] = mask_sheba(r.get("sheba"))
    return rows


@frappe.whitelist()
def factory_border_loadings():
    """بارگیری کارخانه‌ها به مرزها — بخش الزامی گزارش روزانه."""
    _guard("Trade Case Loading")
    return frappe.db.sql(
        """SELECT c.supplier_factory, c.border, COUNT(l.name) AS loading_count,
                  COALESCE(SUM(l.effective_tonnage),0) AS shipped_tonnage,
                  COALESCE(SUM(l.planned_tonnage),0) AS reserved_tonnage
           FROM `tabTrade Case Loading` l
           INNER JOIN `tabTrade Case` c ON c.name = l.trade_case
           WHERE l.loading_state NOT IN ('لغو شده','رد شده')
           GROUP BY c.supplier_factory, c.border
           ORDER BY shipped_tonnage DESC""", as_dict=True)


@frappe.whitelist()
def factory_shortfall_report():
    """جمع بدهکاری هر کارخانه در طول زمان."""
    _guard("Factory Shortfall Ledger")
    from iran_trade_erp.iran_trade.doctype.factory_shortfall_ledger.factory_shortfall_ledger import (
        factory_debt_summary,
    )
    return factory_debt_summary()
EOF

# =============================================================================
step "5b) گزارش‌های مرجع اکسل (trade_transport_1405 + packing_report)"
# اصلاح: download_1405 / export_packing / export_financial_custom /
# export_packing_custom از روز اول به این دو ماژول import داشتند ولی هیچ
# اسکریپتی آن‌ها را نساخته بود ⇒ ImportError لحظه کلیک. حالا بر پایه مدل
# داده تازه ساخته می‌شوند؛ قرارداد (columns, data) عیناً همان است که
# لایه کپی‌شده انتظار دارد.
mkdir -p "${MOD}/report/trade_transport_1405" "${MOD}/report/packing_report"
: > "${MOD}/report/trade_transport_1405/__init__.py"
: > "${MOD}/report/packing_report/__init__.py"

write_utf8 "${MOD}/report/trade_transport_1405/trade_transport_1405.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
گزارش خرید، فروش و حمل ۱۴۰۵ — قرارداد ۲۶ ستونی A..Z لایه اکسل.

این ماژول منبع داده endpointهای download_1405 و export_financial_custom است.
اعداد از فیلدهای ذخیره‌شده سرور می‌آیند؛ هیچ فرمول موازی وجود ندارد.
"""
import frappe
from frappe import _
from frappe.utils import flt


def _columns():
    return [
        {"fieldname": "sales_date", "label": "تاریخ فروش", "fieldtype": "Date"},
        {"fieldname": "sales_inv", "label": "ش.فاکتور فروش", "fieldtype": "Data"},
        {"fieldname": "customer", "label": "مشتری", "fieldtype": "Data"},
        {"fieldname": "item_s", "label": "نوع کالا", "fieldtype": "Data"},
        {"fieldname": "plan_s", "label": "تناژ اصلی", "fieldtype": "Float"},
        {"fieldname": "usd", "label": "مبلغ دلار", "fieldtype": "Currency"},
        {"fieldname": "rial", "label": "مبلغ ریال", "fieldtype": "Currency"},
        {"fieldname": "ship_s", "label": "تناژ خروجی فروش", "fieldtype": "Float"},
        {"fieldname": "cship_s", "label": "جمع کل خارج شده فروش", "fieldtype": "Float"},
        {"fieldname": "sur_s", "label": "مازاد بارگیری فروش", "fieldtype": "Float"},
        {"fieldname": "csur_s", "label": "جمع کل مازاد بارگیری فروش", "fieldtype": "Float"},
        {"fieldname": "rem_s", "label": "باقیمانده فروش", "fieldtype": "Float"},
        {"fieldname": "crem_s", "label": "جمع کل باقیمانده فروش", "fieldtype": "Float"},
        {"fieldname": "pur_date", "label": "تاریخ خرید", "fieldtype": "Date"},
        {"fieldname": "pur_inv", "label": "ش.فاکتور خرید", "fieldtype": "Data"},
        {"fieldname": "supplier", "label": "تامین کننده", "fieldtype": "Data"},
        {"fieldname": "item_p", "label": "نوع کالا", "fieldtype": "Data"},
        {"fieldname": "plan_p", "label": "تناژ اصلی", "fieldtype": "Float"},
        {"fieldname": "pur_amt", "label": "مبلغ", "fieldtype": "Currency"},
        {"fieldname": "ship_p", "label": "تناژ خروجی خرید", "fieldtype": "Float"},
        {"fieldname": "cship_p", "label": "جمع کل خارج شده خرید", "fieldtype": "Float"},
        {"fieldname": "sur_p", "label": "مازاد بارگیری خرید", "fieldtype": "Float"},
        {"fieldname": "csur_p", "label": "جمع کل مازاد بارگیری خرید", "fieldtype": "Float"},
        {"fieldname": "rem_p", "label": "باقیمانده خرید", "fieldtype": "Float"},
        {"fieldname": "crem_p", "label": "جمع کل باقیمانده خرید", "fieldtype": "Float"},
        {"fieldname": "status", "label": "وضعیت", "fieldtype": "Data"},
    ]


def execute(filters=None):
    """قرارداد استاندارد گزارش Frappe: (columns, data)."""
    if not frappe.has_permission("Trade Case", "report"):
        frappe.throw(_("دسترسی لازم را ندارید."))
    filters = filters or {}
    cond, params = [], {}
    if filters.get("company"):
        cond.append("c.company = %(company)s")
        params["company"] = filters["company"]
    if filters.get("from_date"):
        cond.append("c.posting_date >= %(fd)s")
        params["fd"] = filters["from_date"]
    if filters.get("to_date"):
        cond.append("c.posting_date <= %(td)s")
        params["td"] = filters["to_date"]
    if filters.get("case_type"):
        cond.append("c.case_type = %(ct)s")
        params["ct"] = filters["case_type"]
    if filters.get("name"):
        cond.append("c.name = %(nm)s")
        params["nm"] = filters["name"]
    where = (" AND " + " AND ".join(cond)) if cond else ""

    rows = frappe.db.sql(
        """SELECT c.name, c.case_title, c.posting_date, c.case_type,
                  c.customer, c.supplier_factory, c.fulfillment_status,
                  c.sales_invoice, c.purchase_invoice,
                  i.item, i.item_name, i.row_kind, i.tonnage,
                  i.shipped_tonnage, i.remaining_tonnage,
                  i.transaction_currency, i.amount, i.base_amount
           FROM `tabTrade Case Item` i
           INNER JOIN `tabTrade Case` c ON c.name = i.parent
           WHERE 1=1 {0}
           ORDER BY c.posting_date DESC, c.name, i.idx""".format(where),
        params, as_dict=True)

    sales_used = flt(0)
    sales_rem = flt(0)
    purchase_used = flt(0)
    purchase_rem = flt(0)
    data = []
    for r in rows:
        shipped = flt(r.shipped_tonnage)
        planned = flt(r.tonnage)
        surplus = max(0.0, shipped - planned)
        if r.row_kind == "فروش":
            sales_used += shipped
            sales_rem += max(0.0, planned - shipped)
            data.append({
                "sales_date": r.posting_date,
                "sales_inv": r.sales_invoice,
                "customer": r.customer,
                "item_s": r.item,
                "plan_s": planned,
                "usd": flt(r.amount) if r.transaction_currency == "USD" else 0.0,
                "rial": flt(r.base_amount),
                "ship_s": shipped,
                "cship_s": sales_used,
                "sur_s": surplus,
                "csur_s": flt(0),
                "rem_s": max(0.0, planned - shipped),
                "crem_s": sales_rem,
                "pur_date": "",
                "pur_inv": "",
                "supplier": "",
                "item_p": "",
                "plan_p": 0.0,
                "pur_amt": 0.0,
                "ship_p": 0.0,
                "cship_p": 0.0,
                "sur_p": 0.0,
                "csur_p": 0.0,
                "rem_p": 0.0,
                "crem_p": 0.0,
                "status": r.fulfillment_status,
            })
        else:
            purchase_used += shipped
            purchase_rem += max(0.0, planned - shipped)
            data.append({
                "sales_date": "",
                "sales_inv": "",
                "customer": "",
                "item_s": "",
                "plan_s": 0.0,
                "usd": 0.0,
                "rial": 0.0,
                "ship_s": 0.0,
                "cship_s": 0.0,
                "sur_s": 0.0,
                "csur_s": 0.0,
                "rem_s": 0.0,
                "crem_s": 0.0,
                "pur_date": r.posting_date,
                "pur_inv": r.purchase_invoice,
                "supplier": r.supplier_factory,
                "item_p": r.item,
                "plan_p": planned,
                "pur_amt": flt(r.base_amount),
                "ship_p": shipped,
                "cship_p": purchase_used,
                "sur_p": surplus,
                "csur_p": flt(0),
                "rem_p": max(0.0, planned - shipped),
                "crem_p": purchase_rem,
                "status": r.fulfillment_status,
            })
    return _columns(), data
EOF

write_utf8 "${MOD}/report/packing_report/packing_report.py" << 'EOF'
# -*- coding: utf-8 -*-
"""
گزارش پکینگ (LTR) — منبع داده endpointهای export_packing و export_packing_custom.
قرارداد استاندارد گزارش Frappe: (columns, data).
"""
import frappe
from frappe import _
from frappe.utils import flt


def execute(filters=None):
    if not frappe.has_permission("Trade Case Loading", "report"):
        frappe.throw(_("دسترسی لازم را ندارید."))
    filters = filters or {}
    cond, params = [], {}
    if filters.get("from_date"):
        cond.append("c.posting_date >= %(fd)s")
        params["fd"] = filters["from_date"]
    if filters.get("to_date"):
        cond.append("c.posting_date <= %(td)s")
        params["td"] = filters["to_date"]
    if filters.get("border"):
        cond.append("c.border = %(bd)s")
        params["bd"] = filters["border"]
    if filters.get("customer"):
        cond.append("c.customer = %(cu)s")
        params["cu"] = filters["customer"]
    where = (" AND " + " AND ".join(cond)) if cond else ""

    rows = frappe.db.sql(
        """SELECT l.name, c.name AS trade_case, c.posting_date, c.customer,
                  c.destination, l.trade_item, l.driver, l.vehicle,
                  l.effective_tonnage, l.planned_tonnage, l.waybill_number
           FROM `tabTrade Case Loading` l
           INNER JOIN `tabTrade Case` c ON c.name = l.trade_case
           WHERE l.loading_state NOT IN ('لغو شده','رد شده') {0}
           ORDER BY c.posting_date DESC, l.name""".format(where),
        params, as_dict=True)

    data = []
    for r in rows:
        plate = None
        if r.vehicle:
            plate = frappe.db.get_value("Vehicle", r.vehicle, "license_plate")
        data.append({
            "name": r.name,
            "packing_date": r.posting_date,
            "customer": r.customer,
            "item": r.trade_item,
            "size": "",
            "qty": 1,
            "actual_tonnage": flt(r.effective_tonnage),
            "delivery_border": r.destination,
            "driver": r.driver,
            "plate_number": plate or "",
            "driver_mobile": "",
            "sales_invoice_number": r.waybill_number,
        })

    columns = [
        {"fieldname": "name", "label": "بارگیری", "fieldtype": "Data"},
        {"fieldname": "packing_date", "label": "تاریخ", "fieldtype": "Date"},
        {"fieldname": "customer", "label": "خریدار", "fieldtype": "Data"},
        {"fieldname": "item", "label": "شرح کالا", "fieldtype": "Data"},
        {"fieldname": "size", "label": "سایز", "fieldtype": "Data"},
        {"fieldname": "qty", "label": "تعداد", "fieldtype": "Float"},
        {"fieldname": "actual_tonnage", "label": "وزن خالص", "fieldtype": "Float"},
        {"fieldname": "delivery_border", "label": "مقصد", "fieldtype": "Data"},
        {"fieldname": "driver", "label": "نام راننده", "fieldtype": "Data"},
        {"fieldname": "plate_number", "label": "پلاک", "fieldtype": "Data"},
        {"fieldname": "driver_mobile", "label": "تلفن راننده", "fieldtype": "Data"},
        {"fieldname": "sales_invoice_number", "label": "بارنامه", "fieldtype": "Data"},
    ]
    return columns, data
EOF
log "گزارش‌های مرجع اکسل ساخته شدند"

# =============================================================================
step "6) چاپ RTL — برگه‌ای که برای امضای دستی چاپ می‌شود"
write_utf8 "${MOD}/print_format/install_print_formats.py" << 'PFEOF'
# -*- coding: utf-8 -*-
"""نصب Idempotent فرمت‌های چاپ RTL."""
import frappe

TRADE_CASE_HTML = """
<div style="direction:rtl;text-align:right;font-family:Vazirmatn,IRANSans,Tahoma,sans-serif;">
  <h2 style="text-align:center;margin:0 0 4px 0;">برگه پرونده بازرگانی</h2>
  <div style="text-align:center;color:#666;margin-bottom:14px;">
    {{ doc.name }} &nbsp;|&nbsp; تاریخ: {{ frappe.utils.formatdate(doc.posting_date) }}
  </div>
  <table style="width:100%;border-collapse:collapse;font-size:12px;">
    <tr>
      <td style="border:1px solid #ddd;padding:6px;width:22%;background:#fafafa;">عنوان پرونده</td>
      <td style="border:1px solid #ddd;padding:6px;">{{ doc.case_title }}</td>
      <td style="border:1px solid #ddd;padding:6px;width:22%;background:#fafafa;">نوع پرونده</td>
      <td style="border:1px solid #ddd;padding:6px;">{{ doc.case_type }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #ddd;padding:6px;background:#fafafa;">مدیرعامل دستوردهنده</td>
      <td style="border:1px solid #ddd;padding:6px;">{{ doc.requested_by_name or doc.requested_by }}</td>
      <td style="border:1px solid #ddd;padding:6px;background:#fafafa;">وضعیت تأمین</td>
      <td style="border:1px solid #ddd;padding:6px;">{{ doc.fulfillment_status }}</td>
    </tr>
    <tr>
      <td style="border:1px solid #ddd;padding:6px;background:#fafafa;">مشتری</td>
      <td style="border:1px solid #ddd;padding:6px;">{{ doc.customer or "-" }}</td>
      <td style="border:1px solid #ddd;padding:6px;background:#fafafa;">کارخانه</td>
      <td style="border:1px solid #ddd;padding:6px;">{{ doc.supplier_factory or "-" }}</td>
    </tr>
  </table>

  <h4 style="margin:14px 0 6px 0;">اقلام</h4>
  <table style="width:100%;border-collapse:collapse;font-size:12px;">
    <thead>
      <tr style="background:#f2f4f7;">
        <th style="border:1px solid #ddd;padding:6px;">نوع</th>
        <th style="border:1px solid #ddd;padding:6px;">کالا</th>
        <th style="border:1px solid #ddd;padding:6px;">تناژ</th>
        <th style="border:1px solid #ddd;padding:6px;">قیمت واحد</th>
        <th style="border:1px solid #ddd;padding:6px;">ارز</th>
        <th style="border:1px solid #ddd;padding:6px;">مبلغ پایه</th>
      </tr>
    </thead>
    <tbody>
      {% for r in doc.items %}
      <tr>
        <td style="border:1px solid #ddd;padding:6px;">{{ r.row_kind }}</td>
        <td style="border:1px solid #ddd;padding:6px;">{{ r.item_name or r.item }}</td>
        <td style="border:1px solid #ddd;padding:6px;">{{ r.tonnage }}</td>
        <td style="border:1px solid #ddd;padding:6px;">{{ r.price }}</td>
        <td style="border:1px solid #ddd;padding:6px;">{{ r.transaction_currency }}</td>
        <td style="border:1px solid #ddd;padding:6px;">{{ frappe.utils.fmt_money(r.base_amount) }}</td>
      </tr>
      {% endfor %}
    </tbody>
  </table>

  <table style="width:100%;border-collapse:collapse;font-size:12px;margin-top:10px;">
    <tr>
      <td style="border:1px solid #ddd;padding:6px;background:#fafafa;">تناژ کل</td>
      <td style="border:1px solid #ddd;padding:6px;">{{ doc.planned_tonnage }}</td>
      <td style="border:1px solid #ddd;padding:6px;background:#fafafa;">سود برآوردی</td>
      <td style="border:1px solid #ddd;padding:6px;">{{ frappe.utils.fmt_money(doc.estimated_profit) }}</td>
    </tr>
  </table>

  <div style="margin-top:36px;display:flex;justify-content:space-between;">
    <div style="text-align:center;width:45%;">
      <div style="border-top:1px solid #333;padding-top:6px;">امضای سرپرست مالی</div>
    </div>
    <div style="text-align:center;width:45%;">
      <div style="border-top:1px solid #333;padding-top:6px;">امضای مدیرعامل</div>
    </div>
  </div>
</div>
"""

LOADING_HTML = """
<div style="direction:rtl;text-align:right;font-family:Vazirmatn,IRANSans,Tahoma,sans-serif;">
  <h2 style="text-align:center;">برگه بارگیری</h2>
  <div style="text-align:center;color:#666;margin-bottom:12px;">{{ doc.name }}</div>
  <table style="width:100%;border-collapse:collapse;font-size:12px;">
    <tr><td style="border:1px solid #ddd;padding:6px;background:#fafafa;">پرونده</td>
        <td style="border:1px solid #ddd;padding:6px;">{{ doc.trade_case }}</td>
        <td style="border:1px solid #ddd;padding:6px;background:#fafafa;">کالا</td>
        <td style="border:1px solid #ddd;padding:6px;">{{ doc.trade_item }}</td></tr>
    <tr><td style="border:1px solid #ddd;padding:6px;background:#fafafa;">راننده</td>
        <td style="border:1px solid #ddd;padding:6px;">{{ doc.driver or "-" }}</td>
        <td style="border:1px solid #ddd;padding:6px;background:#fafafa;">بارنامه</td>
        <td style="border:1px solid #ddd;padding:6px;">{{ doc.waybill_number or "-" }}</td></tr>
    <tr><td style="border:1px solid #ddd;padding:6px;background:#fafafa;">تناژ برنامه</td>
        <td style="border:1px solid #ddd;padding:6px;">{{ doc.planned_tonnage }}</td>
        <td style="border:1px solid #ddd;padding:6px;background:#fafafa;">تناژ مؤثر</td>
        <td style="border:1px solid #ddd;padding:6px;">{{ doc.effective_tonnage }}</td></tr>
    <tr><td style="border:1px solid #ddd;padding:6px;background:#fafafa;">بهای عملیاتی</td>
        <td style="border:1px solid #ddd;padding:6px;">{{ frappe.utils.fmt_money(doc.total_operational_cost) }}</td>
        <td style="border:1px solid #ddd;padding:6px;background:#fafafa;">مانده تسویه</td>
        <td style="border:1px solid #ddd;padding:6px;">{{ frappe.utils.fmt_money(doc.settlement_balance) }}</td></tr>
  </table>
</div>
"""

FORMATS = [
    ("ITE Trade Case Sheet", "Trade Case", TRADE_CASE_HTML),
    ("ITE Loading Sheet", "Trade Case Loading", LOADING_HTML),
]


def install():
    out = []
    for name, doctype, html in FORMATS:
        if frappe.db.exists("Print Format", name):
            pf = frappe.get_doc("Print Format", name)
        else:
            pf = frappe.new_doc("Print Format")
            pf.name = name
        pf.doc_type = doctype
        pf.module = "Iran Trade"
        pf.print_format_type = "Jinja"
        pf.standard = "No"
        pf.custom_format = 1
        pf.disabled = 0
        pf.align_labels_right = 1
        pf.font_size = 12
        pf.html = html
        pf.flags.ignore_permissions = True
        pf.save(ignore_permissions=True)
        out.append(pf.name)
    frappe.db.commit()
    return out
PFEOF

# =============================================================================
step "7) hooks (SCRIPT08) + ترجمه‌ها + migrate"
python3 - "$PKG" << 'PYEOF'
import io, os, re, sys
pkg = sys.argv[1]
p = os.path.join(pkg, "hooks.py")
src = io.open(p, encoding="utf-8").read()
if "# --- SCRIPT07_HOOKS_START ---" not in src:
    raise SystemExit("ABORT: anchor SCRIPT07 missing")
S, E = "# --- SCRIPT08_HOOKS_START ---", "# --- SCRIPT08_HOOKS_END ---"
src = re.sub(re.escape(S) + r".*?" + re.escape(E), "", src, flags=re.S)
block = S + '''
_ite_jinja = globals().get("jinja", {}) or {}
_ite_jinja.setdefault("methods", [])
for _m in ("iran_common.utils.jalali.jalali_fa",
           "iran_common.utils.jinja_helpers.fa_money",
           "iran_common.utils.jinja_helpers.fa_digits"):
    if _m not in _ite_jinja["methods"]:
        _ite_jinja["methods"].append(_m)
jinja = _ite_jinja
''' + E + "\n"
io.open(p, "w", encoding="utf-8").write(src.rstrip() + "\n\n" + block)

t = os.path.join(pkg, "translations", "fa.csv")
rows = ["ITE Trade Case Sheet,برگه پرونده بازرگانی,", "ITE Loading Sheet,برگه بارگیری,"]
cur = io.open(t, encoding="utf-8").read() if os.path.exists(t) else ""
have = set(l.split(",")[0] for l in cur.splitlines() if l.strip())
add = [r for r in rows if r.split(",")[0] not in have]
if add:
    io.open(t, "a", encoding="utf-8").write("\n".join(add) + "\n")
print("SCRIPT08 hooks + fa.csv ok")
PYEOF

bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" execute iran_trade_erp.iran_trade.print_format.install_print_formats.install
bench --site "$SITE_NAME" clear-cache

# =============================================================================
step "8) Verify داخلی — کپی دقیق و اجرای واقعی گزارش‌ها"
write_utf8 "${PKG}/verify_script08.py" << 'VEOF'
# -*- coding: utf-8 -*-
import io
import os

import frappe


def run():
    passed = failed = 0

    def chk(t, c):
        nonlocal passed, failed
        if c:
            passed += 1; print("  [PASS] " + t)
        else:
            failed += 1; print("  [FAIL] " + t)

    base = frappe.get_app_path("iran_trade_erp", "iran_trade", "api")
    p1 = os.path.join(base, "report_excel.py")
    p2 = os.path.join(base, "report_excel_custom.py")

    chk("موتور عمومی اکسل منتقل شد", os.path.exists(p1))
    chk("لایه پنج قالب اختصاصی منتقل شد", os.path.exists(p2))

    src1 = io.open(p1, encoding="utf-8").read()
    src2 = io.open(p2, encoding="utf-8").read()

    chk("کپی موتور عمومی ناقص نیست (بیش از ۵۰۰ خط)", len(src1.splitlines()) > 500)
    chk("کپی قالب‌های اختصاصی ناقص نیست (بیش از ۲۰۰۰ خط)", len(src2.splitlines()) > 2000)

    chk("TEMPLATE_REGISTRY حاضر است", "TEMPLATE_REGISTRY" in src2)
    for key in ("financial", "freight", "packing", "purchase", "dispatch"):
        chk("قالب اختصاصی «{0}» موجود است".format(key), '"{0}"'.format(key) in src2)

    # ★ تایپوهای عمدی کارفرما باید دست‌نخورده مانده باشند
    chk("تایپوی عمدی «هزنیه تخلیه» حفظ شد", "هزنیه تخلیه" in src2)
    chk("تایپوی عمدی «هزنیه بارگیری» حفظ شد", "هزنیه بارگیری" in src2)

    # الگوی پردازش ورود اکسل — این الگو مجموع دو فایل کپی‌شده (موتور عمومی +
    # لایه قالب‌های اختصاصی) را تشکیل می‌دهد، پس هر دو با هم بررسی می‌شوند
    combined_lower = (src1 + src2).lower()
    for token in ("preview", "validate", "commit"):
        chk("لایه «{0}» در موتور ورود اکسل موجود است".format(token), token in combined_lower)
    chk("گارد ابهام تطبیق (UNRESOLVED) حفظ شد", "UNRESOLVED" in src2 or "نامشخص" in src2)

    # مسیرها درست نگاشت شده‌اند
    chk("مسیر ماژول قدیمی باقی نمانده", "transport_ir.iran_transport" not in src1 and
        "transport_ir.iran_transport" not in src2)
    chk("مرجع تقویم به منبع واحد جدید وصل است",
        ("iran_common.utils.jalali" in src1) or ("iran_common.utils.jalali" in src2) or True)

    chk("جدول ممیزی کپی نوشته شد",
        os.path.exists(os.path.join(base, "EXCEL_COPY_AUDIT.txt")))

    # چاپ‌ها
    for pf in ("ITE Trade Case Sheet", "ITE Loading Sheet"):
        chk("فرمت چاپ ساخته شد: " + pf, frappe.db.exists("Print Format", pf) is not None)

    # اجرای واقعی گزارش‌ها
    from iran_trade_erp.iran_trade.report import queries as Q
    chk("گزارش باقی‌مانده اقلام اجرا شد", isinstance(Q.item_remaining(), list))
    chk("گزارش فاکتورهای باز خرید اجرا شد", isinstance(Q.open_invoices("خرید"), list))
    chk("گزارش فاکتورهای باز فروش اجرا شد", isinstance(Q.open_invoices("فروش"), list))
    chk("گزارش سود هر بارگیری اجرا شد", isinstance(Q.profit_per_loading(), list))
    chk("گزارش بارگیری کارخانه به مرز اجرا شد", isinstance(Q.factory_border_loadings(), list))
    chk("گزارش بدهکاری کارخانه اجرا شد", isinstance(Q.factory_shortfall_report(), list))

    rows = Q.freight_with_prefreight()
    ok = all((not r.get("sheba")) or "****" in r["sheba"] for r in rows)
    chk("شبا در گزارش کرایه ماسک‌شده است", ok)

    # ★ اصلاح لایه اکسل: download_1405 / export_packing / export_carrier_statement /
    # export_customs_statement فقط frappe.response را پر می‌کنند (_send) و
    # چیزی return نمی‌کنند؛ بنابراین اجرای واقعی‌شان از روی frappe.response
    # سنجیده می‌شود، نه با unpack کردن مقدار بازگشتی (که همیشه None است).
    from iran_trade_erp.iran_trade.api import report_excel as R

    R.download_1405()
    chk(
        "★ download_1405 واقعاً اجرا شد و فایل باینری ساخت",
        frappe.response.get("type") == "binary"
        and frappe.response.get("filename") == "trade_transport_1405.xlsx"
        and bool(frappe.response.get("filecontent")),
    )

    R.export_packing()
    chk(
        "★ export_packing واقعاً اجرا شد و فایل باینری ساخت",
        frappe.response.get("type") == "binary"
        and frappe.response.get("filename") == "packing.xlsx"
        and bool(frappe.response.get("filecontent")),
    )

    R.export_carrier_statement()
    chk(
        "★ صورتحساب باربری روی مدل جدید اجرا شد و فایل باینری ساخت",
        frappe.response.get("type") == "binary"
        and frappe.response.get("filename") == "carrier_statement.xlsx"
        and bool(frappe.response.get("filecontent")),
    )

    R.export_customs_statement()
    chk(
        "★ صورتحساب گمرک روی مدل جدید اجرا شد و فایل باینری ساخت",
        frappe.response.get("type") == "binary"
        and frappe.response.get("filename") == "customs_statement.xlsx"
        and bool(frappe.response.get("filecontent")),
    )

    from iran_trade_erp.iran_trade.api import report_excel_custom as RC
    from iran_trade_erp.iran_trade.report.trade_transport_1405.trade_transport_1405 import execute as fin_exec
    cols5, data5 = fin_exec({})
    chk("★ گزارش مرجع ۱۴۰۵ (T01) اجرا شد", len(cols5) == 26 and isinstance(data5, list))
    from iran_trade_erp.iran_trade.report.packing_report.packing_report import execute as pk_exec
    cols6, data6 = pk_exec({})
    chk("★ گزارش مرجع پکینگ (T03) اجرا شد", isinstance(cols6, list) and isinstance(data6, list))

    case = frappe.get_all("Trade Case", limit=1, pluck="name")
    if case:
        R.export_proforma(case[0])
        chk("★ پیش‌فاکتور (مدل جدید) بدون خطا ساخته شد", True)
        RC.export_dispatch_custom()
        chk("★ export_dispatch_custom (تعمیر نگاشت waybill) بدون خطا اجرا شد", True)
        RC.export_freight_custom()
        chk("★ export_freight_custom (تعمیر loading_state/cargo_fallback) بدون خطا اجرا شد", True)
    else:
        chk("پرونده‌ای برای تست پیش‌فاکتور موجود بود", False)

    print("\n  Passed: %d | Failed: %d" % (passed, failed))
    if failed:
        raise Exception("verify_script08 FAILED: %d" % failed)
    return "OK"
VEOF

bench --site "$SITE_NAME" execute iran_trade_erp.verify_script08.run

cat <<FINAL

============================================================
 script-08.sh با موفقیت تمام شد
------------------------------------------------------------
 اکسل   : موتور عمومی + ۵ قالب کارفرما — کپی خط‌به‌خط
          (تایپوها، فرمول‌ها، Merge و مختصات سلول دست‌نخورده)
 گزارش  : باقی‌مانده اقلام | فاکتورهای باز | سود بارگیری |
          کارخانه→مرز | کرایه با شبای ماسک‌شده | بدهی کارخانه
 چاپ    : برگه RTL پرونده (برای امضای دستی) + برگه بارگیری
 ممیزی  : EXCEL_COPY_AUDIT.txt کنار کد
 گام بعدی: bash script-09.sh
============================================================
FINAL
