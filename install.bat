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
copy /Y pgaudix.control "%SHAREDIR%\extension\pgaudix.control"
copy /Y pgaudix--0.1.0.sql "%SHAREDIR%\extension\pgaudix--0.1.0.sql"

echo pgaudix installed successfully.
echo Connect to your database and run: CREATE EXTENSION pgaudix;
