@echo off
setlocal

if "%PG_CONFIG%"=="" (
    for /f "delims=" %%i in ('where pg_config 2^>nul') do set "PG_CONFIG=%%i"
)
if "%PG_CONFIG%"=="" (
    echo ERROR: pg_config not found. Set PG_CONFIG or add PostgreSQL bin to PATH.
    exit /b 1
)

for /f "delims=" %%i in ('"%PG_CONFIG%" --pkglibdir') do set "LIBDIR=%%i"
for /f "delims=" %%i in ('"%PG_CONFIG%" --sharedir') do set "SHAREDIR=%%i"

copy /Y pgaudix.dll "%LIBDIR%\pgaudix.dll"
if errorlevel 1 goto :copy_failed
copy /Y pgaudix.control "%SHAREDIR%\extension\pgaudix.control"
if errorlevel 1 goto :copy_failed
copy /Y pgaudix--*.sql "%SHAREDIR%\extension\"
if errorlevel 1 goto :copy_failed

echo pgaudix installed successfully.
echo Connect to your database and run: CREATE EXTENSION pgaudix;
exit /b 0

:copy_failed
echo ERROR: could not copy the extension files. Run this script from the folder that contains pgaudix.dll, as an administrator if PostgreSQL is installed under Program Files.
exit /b 1
