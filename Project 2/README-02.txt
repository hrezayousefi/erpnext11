================================================================================
README-02.txt  —  راهنمای script-02.sh
اسکلت اپ اصلی «iran_trade_erp» + ۱۳ نقش + ۱۲ کاربر واقعی + الگوی ضد ۴۰۴
================================================================================

۱) جایگاه: 01 → [script-02] → 03
۲) پیش‌نیاز: اپ iran_common نصب باشد (اسکریپت با ABORT صریح چک می‌کند).
۳) اجرا:  SITE_NAME=transport-dev.local bash script-02.sh
   متغیرهای اختیاری: CEO1_EMAIL / CEO1_NAME / CEO2_EMAIL / CEO2_NAME /
                     DEFAULT_PASSWORD / COMPANY_NAME / COMPANY_ABBR

۴) آنچه ساخته می‌شود
---------------------
apps/iran_trade_erp/iran_trade_erp/
  hooks.py                    ← با بلوک نشانه‌دار SCRIPT02_HOOKS_START/END
  fixtures/role.json          ← ۱۳ نقش
  translations/fa.csv         ← برچسب فارسی همه نقش‌ها
  iran_trade/utils/naming_guard.py   ← الگوی ضد ۴۰۴ + گارد گیرنده
  iran_trade/setup/seed_org.py       ← شرکت/سال مالی/۱۲ کاربر/Administrator مقدس
  iran_trade/doctype/supervisor_team/        «تیم سرپرستی»
  iran_trade/doctype/supervisor_team_member/ «عضو تیم سرپرستی»
  verify_script02.py

۵) کاربران واقعی ساخته‌شده
----------------------------
هادی کرمیان        → CEO + Document Signer   (نقش دوگانه — تصحیح خطای نسخه قبل)
سعید یوسفی         → CEO + Document Signer   (نقش دوگانه)
مدیر مالی           → Financial Manager
احسان نهال‌پرور     → Finance Supervisor
فائزه حیدری         → Finance User
پویا سلیمانی        → Legal Reviewer
عطیه اعلایی         → Treasury User
زهرا میرزایی        → Receivables User
نجمه افراشته‌پور    → Transport Supervisor
خانم امینی          → Transport User - Purchase
محدثه عنایتی        → Transport User - Sales
آقای محمدی          → Customs Officer

۶) جدول یافته / وضعیت / ارجاع / اقدام
---------------------------------------
| یافته                                        | وضعیت  | ارجاع                                | اقدام |
|----------------------------------------------|--------|--------------------------------------|-------|
| دو نقش CEO و Document Signer به دو نفر جدا داده شده بود | رفع شد | setup_realign_gate.sh ensure_users | هر دو مدیرعامل، هر دو نقش |
| کرمیان اصلاً در USER_ROLE_MAP نبود            | رفع شد | mid-phases-v3/README_phase5.5 §۵      | افزوده شد |
| Administrator نقش کسب‌وکاری می‌گرفت           | رفع شد | 4.txt «ادعای مشترک ۵»                 | restore_administrator |
| «۴۰۴ فارسی» سه بار مستقل تکرار شده بود        | پیشگیری| TECHNICAL_CODEX §8                    | naming_guard.assert_ascii_identifier |
| نقش عمومی Supervisor ساخته می‌شد              | پیشگیری| mid-phases-v3/README_phase11.pre §۹   | Supervisor Team DocType به‌جای نقش |
| فرض «هر نقش فقط یک نفر»                       | رفع شد | چک‌لیست کارفرما                        | users_with_role چند-کاربره |

۷) Verify داخلی
-----------------
۱۳ نقش موجود | شرکت و سال مالی | دو مدیرعامل واقعی | نقش دوگانه هر دو |
Administrator بدون نقش کسب‌وکاری | filter_recipients حذف Administrator/Guest |
«تیم سرپرستی» ساخته شد | سناریوی منفی: شناسه فارسی Workspace مسدود می‌شود

۸) اگر خطا داد
---------------
- «ABORT: اپ iran_common نصب نیست» → ابتدا script-01.sh
- verify «دو مدیرعامل واقعی» شکست → CEO1_EMAIL/CEO2_EMAIL را ست و دوباره اجرا کنید.

۹) Idempotency / Rollback
---------------------------
کاربران/نقش‌ها/شرکت دوباره ساخته نمی‌شوند. بلوک hooks با Regex حذف و بازنویسی می‌شود.
Rollback: uninstall-app iran_trade_erp (اپ iran_common دست‌نخورده می‌ماند).
