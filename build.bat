@echo off
title KindOS Builder - IMG + ISO (Kindrel V20)
echo ==========================================
echo Building KindOS V20 with Kindrel + Modules
echo ==========================================
cd /d C:\KindOS
if not exist build mkdir build
if not exist KindOS mkdir KindOS

REM ==========================================
REM BOOT
REM ==========================================
echo.
echo [1/5] Compiling boot.asm...
nasm -f bin C:\KindOS\boot.asm -o C:\KindOS\build\boot.bin
if errorlevel 1 goto err

REM ==========================================
REM KINDREL (Kernel)
REM ==========================================
echo [2/5] Compiling kindrel_v20.asm...
nasm -f bin C:\KindOS\kindrel.asm -o C:\KindOS\build\kindrel.bin
if errorlevel 1 goto err

REM ==========================================
REM STAGE 4: Mouse Driver
REM ==========================================
echo [3/5] Compiling stage4.asm...
nasm -f bin C:\KindOS\stage4.asm -o C:\KindOS\build\stage4.bin
if errorlevel 1 goto err

REM ==========================================
REM STAGE 5: Disk + FAT12/16/32
REM ==========================================
echo [4/5] Compiling stage5.asm...
nasm -f bin C:\KindOS\stage5.asm -o C:\KindOS\build\stage5.bin
if errorlevel 1 goto err

REM ==========================================
REM STAGE 6: File Manager
REM ==========================================
echo [5/5] Compiling stage6.asm...
nasm -f bin C:\KindOS\stage6.asm -o C:\KindOS\build\stage6.bin
if errorlevel 1 goto err

REM ==========================================
REM BUILD FLOPPY IMG (1.44 MB)
REM ==========================================
echo.
echo =========================================
echo Building floppy IMG (1.44 MB)...
echo =========================================

powershell -ExecutionPolicy Bypass -Command "$img = New-Object byte[] 1474560; $boot = [IO.File]::ReadAllBytes('C:\KindOS\build\boot.bin'); $kindrel = [IO.File]::ReadAllBytes('C:\KindOS\build\kindrel.bin'); $stage4 = [IO.File]::ReadAllBytes('C:\KindOS\build\stage4.bin'); $stage5 = [IO.File]::ReadAllBytes('C:\KindOS\build\stage5.bin'); $stage6 = [IO.File]::ReadAllBytes('C:\KindOS\build\stage6.bin'); $boot.CopyTo($img, 0); $kindrel.CopyTo($img, 512); $stage4.CopyTo($img, 512 + 0x20000); $stage5.CopyTo($img, 512 + 0x30000); $stage6.CopyTo($img, 512 + 0x40000); [IO.File]::WriteAllBytes('C:\KindOS\kindrel_NEW.img', $img); Write-Host 'SUCCESS: Created C:\KindOS\kindrel_NEW.img' -ForegroundColor Green"

if errorlevel 1 goto err

REM ==========================================
REM CREATE ISO DIRECTORY
REM ==========================================
if not exist C:\KindOS\iso_root mkdir C:\KindOS\iso_root
if not exist C:\KindOS\iso_root\boot mkdir C:\KindOS\iso_root\boot

copy /y C:\KindOS\build\boot.bin C:\KindOS\iso_root\boot\ > nul
copy /y C:\KindOS\build\kindrel.bin C:\KindOS\iso_root\boot\ > nul
copy /y C:\KindOS\build\stage4.bin C:\KindOS\iso_root\boot\ > nul
copy /y C:\KindOS\build\stage5.bin C:\KindOS\iso_root\boot\ > nul
copy /y C:\KindOS\build\stage6.bin C:\KindOS\iso_root\boot\ > nul

REM ==========================================
REM BUILD ISO (El Torito)
REM ==========================================
echo.
echo =========================================
echo Building ISO...
echo =========================================

set ISO_TOOL=
where oscdimg >nul 2>&1 && set ISO_TOOL=oscdimg
if not defined ISO_TOOL where mkisofs >nul 2>&1 && set ISO_TOOL=mkisofs
if not defined ISO_TOOL where genisoimage >nul 2>&1 && set ISO_TOOL=genisoimage
if not defined ISO_TOOL where xorriso >nul 2>&1 && set ISO_TOOL=xorriso

if not defined ISO_TOOL (
    echo [WARN] No ISO tool found!
    echo        Install one of these:
    echo        - oscdimg from Windows ADK
    echo        - mkisofs from cdrtools
    echo        - xorriso
    echo.
    echo        IMG is ready: C:\KindOS\kindrel_NEW.img
    goto iso_done
)

echo Using: %ISO_TOOL%

if "%ISO_TOOL%"=="oscdimg" (
    oscdimg -bC:\KindOS\iso_root\boot\boot.bin -no-emul-boot -boot-load-size 4 C:\KindOS\iso_root C:\KindOS\KindOS.iso
    goto iso_ok
)

if "%ISO_TOOL%"=="mkisofs" (
    mkisofs -o C:\KindOS\KindOS.iso -b boot/boot.bin -no-emul-boot -boot-load-size 4 -boot-info-table C:\KindOS\iso_root
    goto iso_ok
)

if "%ISO_TOOL%"=="genisoimage" (
    genisoimage -o C:\KindOS\KindOS.iso -b boot/boot.bin -no-emul-boot -boot-load-size 4 -boot-info-table C:\KindOS\iso_root
    goto iso_ok
)

if "%ISO_TOOL%"=="xorriso" (
    xorriso -as mkisofs -o C:\KindOS\KindOS.iso -b boot/boot.bin -no-emul-boot -boot-load-size 4 -boot-info-table C:\KindOS\iso_root
    goto iso_ok
)

:iso_ok
if exist C:\KindOS\KindOS.iso (
    echo SUCCESS: Created C:\KindOS\KindOS.iso -ForegroundColor Green
) else (
    echo [ERROR] ISO creation failed!
    goto err
)

:iso_done

REM ==========================================
REM COPY TO KINDOS FOLDER
REM ==========================================
echo.
echo =========================================
echo Copying to KindOS folder...
echo =========================================
copy /y C:\KindOS\kindrel_NEW.img C:\KindOS\KindOS\ > nul
if exist C:\KindOS\KindOS.iso copy /y C:\KindOS\KindOS.iso C:\KindOS\KindOS\ > nul
echo Images copied to C:\KindOS\KindOS\

echo.
echo =========================================
echo =========================================
echo.
echo   FINAL IMAGES:
echo   -------------
echo   C:\KindOS\kindrel_NEW.img - for QEMU/floppy
if exist C:\KindOS\KindOS.iso echo   C:\KindOS\KindOS.iso - for Ventoy/BIOS
echo.
echo   Location: C:\KindOS\KindOS\
echo.
echo =========================================
echo =========================================
echo.
pause
exit /b 0

:err
echo.
echo =========================================
echo BUILD FAILED!
echo =========================================
pause
exit /b 1