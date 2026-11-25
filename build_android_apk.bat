
@echo off
setlocal

echo ========================================
echo         KINCARE APK BUILDER
echo ========================================

cd /d "%~dp0"

if not exist "local_build_config.bat" (
    echo ERROR: local_build_config.bat is missing.
    exit /b 1
)

call "%~dp0local_build_config.bat"

if not defined SUPABASE_URL (
    echo ERROR: SUPABASE_URL is missing.
    exit /b 1
)

if not defined SUPABASE_PUBLISHABLE_KEY (
    echo ERROR: SUPABASE_PUBLISHABLE_KEY is missing.
    exit /b 1
)

if not "%SUPABASE_URL:YOUR_=%"=="%SUPABASE_URL%" (
    echo ERROR: Replace the placeholder Supabase URL.
    exit /b 1
)

if not "%SUPABASE_PUBLISHABLE_KEY:YOUR_=%"=="%SUPABASE_PUBLISHABLE_KEY%" (
    echo ERROR: Replace the placeholder Supabase key.
    exit /b 1
)

echo.
echo Building KinCare Android APK...

cd /d "%~dp0android_app"

call "C:\tools\flutter\bin\flutter.bat" build apk --debug --dart-define=SUPABASE_URL=%SUPABASE_URL% --dart-define=SUPABASE_PUBLISHABLE_KEY=%SUPABASE_PUBLISHABLE_KEY%

if errorlevel 1 (
    echo.
    echo APK BUILD FAILED.
    exit /b 1
)

echo.
echo ========================================
echo          BUILD SUCCESSFUL
echo ========================================
echo APK location:
echo %~dp0android_app\build\app\outputs\flutter-apk\app-debug.apk

explorer "%~dp0android_app\build\app\outputs\flutter-apk"

endlocal
