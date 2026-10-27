@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "FACTORY_WINRM_CERTIFICATE_MODE_LOCKED="

cd /d "%~dp0"

set "AZURE_LOCAL_FACTORY_RUNNER_PROFILE=AzureLocalExecution"

:SelectCertificateMode
cls

echo =========================================================
echo        AZURE LOCAL DEPLOYMENT MANAGER
echo =========================================================
echo.
echo Select WinRM Certificate Validation Mode:
echo.
echo   1 - Strict Certificate Validation
echo       Require trusted CA chain and revocation validation.
echo.
echo   2 - Approved Temporary Certificate Exception
echo       Skip CA and revocation validation for troubleshooting.
echo       FQDN/CN validation remains enabled.
echo.

set /p CERT_SELECTION=Enter selection [1 or 2]:

if "%CERT_SELECTION%"=="1" (
    set "FACTORY_WINRM_CERTIFICATE_MODE=Strict"
    set "FACTORY_ALLOW_UNTRUSTED_WINRM="
    set "FACTORY_WINRM_CERTIFICATE_MODE_LOCKED=Launcher"
    goto LaunchManager
)

if "%CERT_SELECTION%"=="2" (
    echo.
    echo WARNING: This option temporarily skips CA and revocation checks.

    set "CERT_CONFIRMATION="
    set /p "CERT_CONFIRMATION=Type APPROVED to continue: "

    rem Remove spaces from the confirmation value.
    set "CERT_CONFIRMATION=!CERT_CONFIRMATION: =!"

    if /I "!CERT_CONFIRMATION!"=="APPROVED" (
        set "FACTORY_WINRM_CERTIFICATE_MODE=ApprovedTemporaryException"
        set "FACTORY_ALLOW_UNTRUSTED_WINRM=APPROVED_TEMPORARY_EXCEPTION"
        set "FACTORY_WINRM_CERTIFICATE_MODE_LOCKED=Launcher"
        goto LaunchManager
    )

    echo.
    echo Temporary certificate exception was not approved.
    pause
    goto SelectCertificateMode
)

echo.
echo Invalid selection. Enter 1 or 2.
pause
goto SelectCertificateMode

:LaunchManager
echo.
echo WinRM Certificate Mode:
echo   %FACTORY_WINRM_CERTIFICATE_MODE%
echo.

pwsh.exe -NoProfile -File ".\launcher\Start-AzureLocalDeploymentManager.ps1"

set EXIT_CODE=%ERRORLEVEL%

endlocal
exit /b %EXIT_CODE%