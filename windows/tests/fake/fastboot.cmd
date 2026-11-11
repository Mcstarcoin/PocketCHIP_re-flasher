@echo off
rem Stand-in for fastboot.exe in the dry-run test. Logs each call.
if defined PCF_FAKE_LOG echo fastboot %*>>"%PCF_FAKE_LOG%"
if /i "%~1"=="devices" (
  echo FAKE0001	fastboot
  exit /b 0
)
if /i "%~1"=="flash" (
  for %%i in (1 2 3) do (
    echo Sending sparse 'UBI' %%i/3 ^(262140 KB^) OKAY 1>&2
    echo Writing sparse 'UBI' %%i/3 OKAY 1>&2
  )
)
exit /b 0
