@echo off
REM ------------------------------------------------
REM build.bat
REM Compile, renomme et injecte le checksum
REM Usage : build extra_rom
REM ------------------------------------------------

if "%1"=="" (
    echo Usage: build ^<nom_fichier_sans_extension^>
    exit /b 1
)

..\..\bin\JWasm.exe -bin %1.asm
if errorlevel 1 (
    echo Erreur d'assemblage.
    exit /b 1
)

ren %1.BIN %1.bin

powershell -ExecutionPolicy Bypass -File injecter_checksum.ps1 %1.bin

echo.
echo Compilation et checksum termines : %1.bin