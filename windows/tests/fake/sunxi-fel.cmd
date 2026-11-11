@echo off
rem Stand-in for sunxi-fel.exe in the dry-run test. Logs each call.
if defined PCF_FAKE_LOG echo fel %*>>"%PCF_FAKE_LOG%"
if /i "%~1"=="read" (
  >"%~4" echo nand_erasesize=400000
  >>"%~4" echo nand_writesize=4000
  >>"%~4" echo nand_oobsize=680
)
exit /b 0
