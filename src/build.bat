@echo off
setlocal

REM Build script for the AcDbMText::text() leak reproduction.
REM
REM Usage:
REM   build.bat <RealDWG-SDK-Root>
REM
REM Examples:
REM   build.bat "C:\path\to\RealDWG 2025"
REM
REM   The script auto-locates Visual Studio (2022 or newer) via vswhere.
REM   Override by setting VCVARS env var to the vcvars64.bat path.
REM
REM SDK root must contain:
REM   inc\               -- C++ headers (dbents.h, dbapserv.h, etc.)
REM   lib\               -- import libs (acdb25.lib, AcPal.lib)
REM
REM   The script tries a few common header/lib subfolder names
REM   (inc/Inc/include and lib/Lib/libs/Libs).

REM If INCDIR and LIBDIR are pre-set in env, skip the SDK-root probe.
REM Useful when headers and import libs live in unrelated directory trees.
if defined INCDIR if defined LIBDIR goto :env_paths

if "%~1"=="" (
    echo Usage: build.bat ^<RealDWG-SDK-Root^>
    echo    or: set INCDIR=^<headers-dir^> ^&^& set LIBDIR=^<libs-dir^> ^&^& build.bat
    exit /b 1
)

set "SDK=%~1"
if not exist "%SDK%" (
    echo SDK root not found: %SDK%
    exit /b 1
)

REM Try common header/lib layouts.
set "INCDIR="
if exist "%SDK%\inc\dbents.h"     set "INCDIR=%SDK%\inc"
if exist "%SDK%\Inc\dbents.h"     set "INCDIR=%SDK%\Inc"
if exist "%SDK%\include\dbents.h" set "INCDIR=%SDK%\include"
if exist "%SDK%\dbents.h"         set "INCDIR=%SDK%"
if "%INCDIR%"=="" (
    echo Could not locate dbents.h under %SDK%. Set INCDIR manually.
    exit /b 1
)

set "LIBDIR="
if exist "%SDK%\lib\acdb25.lib"  set "LIBDIR=%SDK%\lib"
if exist "%SDK%\Lib\acdb25.lib"  set "LIBDIR=%SDK%\Lib"
if exist "%SDK%\libs\acdb25.lib" set "LIBDIR=%SDK%\libs"
if exist "%SDK%\Libs\acdb25.lib" set "LIBDIR=%SDK%\Libs"
if exist "%SDK%\acdb25.lib"      set "LIBDIR=%SDK%"
if "%LIBDIR%"=="" (
    echo Could not locate acdb25.lib under %SDK%. Set LIBDIR manually.
    exit /b 1
)

:env_paths
if not exist "%INCDIR%\dbents.h" (
    echo dbents.h not found in INCDIR=%INCDIR%
    exit /b 1
)
if not exist "%LIBDIR%\acdb25.lib" (
    echo acdb25.lib not found in LIBDIR=%LIBDIR%
    exit /b 1
)

echo Include dir: %INCDIR%
echo Library dir: %LIBDIR%

REM Locate Visual Studio vcvars64.bat
if defined VCVARS goto :have_vcvars
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    echo vswhere.exe not found at "%VSWHERE%". Install Visual Studio 2022 or set VCVARS.
    exit /b 1
)
"%VSWHERE%" -latest -find "VC\Auxiliary\Build\vcvars64.bat" > "%TEMP%\__vcvars_path.txt"
set /p VCVARS=<"%TEMP%\__vcvars_path.txt"
del "%TEMP%\__vcvars_path.txt" >nul 2>&1

:have_vcvars
if not exist "%VCVARS%" (
    echo vcvars64.bat not found: %VCVARS%
    exit /b 1
)
call "%VCVARS%" >nul

set "SCRIPT_DIR=%~dp0"
set "OUT=%SCRIPT_DIR%..\build"
if not exist "%OUT%" mkdir "%OUT%"

cl /nologo /EHsc /Zi /Od /MDd /std:c++17 /W3 /DWIN32_LEAN_AND_MEAN /DUNICODE /D_UNICODE ^
   /I "%INCDIR%" ^
   "%SCRIPT_DIR%helloworld.cpp" ^
   /Fo:"%OUT%\helloworld.obj" /Fd:"%OUT%\helloworld.pdb" ^
   /link /OUT:"%OUT%\helloworld.exe" /DEBUG /SUBSYSTEM:CONSOLE ^
   /LIBPATH:"%LIBDIR%" acdb25.lib AcPal.lib delayimp.lib ^
   /DELAYLOAD:acdb25.dll /DELAYLOAD:AcPal.dll

if errorlevel 1 exit /b 1

echo.
echo Built: %OUT%\helloworld.exe
echo.
echo To run, copy helloworld.exe (and helloworld.pdb) next to acdb25.dll, then:
echo   helloworld.exe "<your-RealDWG-registry-key>" 30
echo.
echo Set MODE=writeread to generate a tiny test DWG and reproduce the leak.
