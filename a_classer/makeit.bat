@echo off

    if exist "test-de-base.obj" del "test-de-base.obj"
    if exist "test-de-base.exe" del "test-de-base.exe"

    \masm32\bin\ml /c /coff "test-de-base.asm"
    if errorlevel 1 goto errasm

    // \masm32\bin\PoLink /SUBSYSTEM:CONSOLE "test-de-base.obj"
     \masm32\bin\PoLink /AT /Fl "test-de-base.obj"
    if errorlevel 1 goto errlink
    dir "test-de-base.*"
    goto TheEnd

  :errlink
    echo _
    echo Link error
    goto TheEnd

  :errasm
    echo _
    echo Assembly Error
    goto TheEnd
    
  :TheEnd

pause
