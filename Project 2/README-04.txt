================================================================================
README-04.txt  —  راهنمای script-04.sh
هسته دامنه: پرونده بازرگانی، اقلام چندکالایی، میز مدیرعامل، موتور واحد مالی
================================================================================

۱) جایگاه: 03 → [script-04] → 05
۲) پیش‌نیاز: fx.py و naming_guard.py و بلوک SCRIPT03 (ABORT صریح).
۳) اجرا:  SITE_NAME=transport-dev.local bash script-04.sh

۴) مدل داده Trade Case (چهار تب شماره‌دار)
--------------------------------------------
تب ۱ درخواست و طرفین : case_title، case_type(خرید/فروش/ترکیبی)، requested_by★،
                        company، posting_date، fulfillment_status، customer،
                        supplier_factory، assigned_user، sla_last_action_on
تب ۲ اقلام و مالی    : items (Trade Case Item)، planned_tonnage،
                        purchase_amount_base، sales_amount_base،
                        estimated_profit، has_multi_currency، مسیر و تحویل
تب ۳ بررسی و امضا    : ۵ چک حقوقی، سقف خزانه، اسناد و امضا، ۶ چک سرپرست مالی
تب ۴ اتصال و بستن    : source_doctype/document/row، linked_purchase/sales_case،
                        sales_invoice/purchase_invoice/payment_entry (Link واقعی)،
                        بستن دستی + Snapshot، مسیرهای استثنا

★ requested_by = «مدیرعامل دستوردهنده» — فیلد دائمی و الزامی.
  سیستم بررسی می‌کند کاربر واقعاً نقش CEO داشته باشد و Administrator نباشد.

۵) موتور واحد هزینه و سود (money_engine.py)
---------------------------------------------
total_operational_cost = freight + customs + clearance + insurance + other + initial
total_settled          = Σ base_amount پرداخت‌ها     ← تسویه است، نه هزینه
settlement_balance     = هزینه − تسویه
estimated_profit       = sales_base − purchase_base − هزینه عملیاتی
کلاینت فقط get_cost_preview را صدا می‌زند؛ هیچ محاسبه دومی در JS نیست.

۶) جدول یافته / وضعیت / ارجاع / اقدام
---------------------------------------
| یافته                                        | وضعیت  | ارجاع                                | اقدام |
|----------------------------------------------|--------|--------------------------------------|-------|
| Trade Case فقط یک فیلد item تکی داشت          | رفع شد | setup_phase5.sh trade_case.json      | جدول Trade Case Item |
| فیلد فاکتور Data بود نه Link                  | رفع شد | setup_phase84.sh:320-373             | Link واقعی SI/PI/PE |
| هیچ فیلد ارزی رویدادی نبود                    | رفع شد | MULTI_CURRENCY_DESIGN.txt            | FX هر ردیف |
| «مدیرعامل دستوردهنده» وجود نداشت              | افزوده | خواسته صریح کارفرما                   | requested_by + گارد نقش |
| «در انتظار تأمین کالا» وجود نداشت             | افزوده | خواسته صریح کارفرما                   | fulfillment_status |
| نوع «ترکیبی/دلالی» وجود نداشت                 | افزوده | ماهیت دلالی شرکت                      | case_type سه‌گزینه‌ای |
| دوباره‌شماری پرداخت به‌عنوان هزینه            | رفع شد | setup_phase6.sh _calculate_totals    | money_engine واحد |
| سه فرمول سود متفاوت                           | رفع شد | 4.txt «ادعای مشترک ۶»                 | یک تابع، یک عدد |
| ریست ساعت SLA با هر ذخیره                     | رفع شد | 4.txt «ادعای گزارش ۱»                 | _touch_sla_clock فقط با تغییر مرحله |

۷) Verify داخلی
-----------------
۴ DocType | تعداد فیلد در بازه معقول | برچسب فارسی همه فیلدها |
requested_by موجود | «در انتظار تأمین کالا» در گزینه‌ها | «ترکیبی» موجود |
Link واقعی حسابداری | Dynamic Link سند اصلی |
سناریوی ترکیبی ۱۰۰+۱۰۰ تن با IRR+USD: تناژ ۲۰۰، چندارزی=۱، پایه‌ها درست |
سود = فروش − خرید − هزینه | عدد فرم == عدد API |
سناریوی منفی: Administrator دستوردهنده نمی‌شود |
پارک در «در انتظار تأمین کالا» | بستن دستی با Snapshot | بستن بدون دلیل مسدود

۸) اگر خطا داد
---------------
- «کاربر انتخاب‌شده نقش مدیرعامل ندارد» → عمدی است؛ کاربر CEO انتخاب کنید.
- «نرخ تبدیل ... یافت نشد» → ابتدا نرخ USD→IRR را در تنظیمات خزانه وارد کنید.

۹) Idempotency / Rollback
---------------------------
DocTypeها با نام ثابت بازنویسی می‌شوند. بلوک SCRIPT04 قابل حذف است.
هیچ هوک موازی روی Trade Case ثبت نشده تا «لایه‌لایه شدن پچ‌ها» تکرار نشود.
