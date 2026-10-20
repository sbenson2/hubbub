@echo off
rem Fetches depot_tools, the webrtc-sdk wrapper (with Hubbub's wrapper.patch) and
rem the WebRTC sources, then applies the wrapper's own patches. Takes about 20 min
rem and ~30 GB on a first run. Set WORK first to use another directory.
setlocal EnableExtensions
if not defined WORK set "WORK=C:\wrtc\work"
set "HERE=%~dp0"
set "WRAPPER_COMMIT=070aa6d"
set "R_COMMIT=ba469aa2093ba950066258ca0a59a6fbd1295582"
set "W=%WORK%\wrapper"
set "vs2022_install=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
set DEPOT_TOOLS_WIN_TOOLCHAIN=0
set GYP_MSVS_VERSION=2022
set GIT_CONFIG_COUNT=3
set "GIT_CONFIG_KEY_0=core.autocrlf" & set "GIT_CONFIG_VALUE_0=false"
set "GIT_CONFIG_KEY_1=core.filemode" & set "GIT_CONFIG_VALUE_1=false"
set "GIT_CONFIG_KEY_2=core.longpaths" & set "GIT_CONFIG_VALUE_2=true"
if not exist "%WORK%" mkdir "%WORK%"
cd /d "%WORK%" || exit /b 1
rem Use `call git` everywhere: depot_tools puts a git.bat shim on PATH, and
rem running it without `call` ends this script after the first git command.
if not exist depot_tools call git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git || exit /b 1
set "PATH=%WORK%\depot_tools;%PATH%"
rem Wrapper = webrtc-sdk/libwebrtc at WRAPPER_COMMIT (tag libwebrtc.m150.7871.03) + wrapper.patch.
if not exist "%W%\.git" call git clone https://github.com/webrtc-sdk/libwebrtc.git "%W%" || exit /b 1
call git -C "%W%" checkout -f %WRAPPER_COMMIT% || exit /b 1
call git -C "%W%" clean -fdx || exit /b 1
call git -C "%W%" apply "%HERE%wrapper.patch" || exit /b 1
copy /y "%W%\build\.gclient" .gclient >nul || exit /b 1
rem The blank echo keeps target_os on its own line even if .gclient has no
rem trailing newline; `echo.` (not `echo`) because `echo` alone prints its state.
>>.gclient echo.
>>.gclient echo target_os = ["win"]
if not exist src call git clone https://github.com/webrtc-sdk/webrtc.git src || exit /b 1
call git -C src fetch origin || exit /b 1
call git -C src checkout -f %R_COMMIT% || exit /b 1
call gclient.bat sync --with_branch_heads --jobs=8
if errorlevel 1 exit /b 1
call git -C src checkout -f %R_COMMIT% || exit /b 1
call git -C src rev-parse HEAD
if exist src\libwebrtc rmdir /s /q src\libwebrtc
xcopy "%W%\include" src\libwebrtc\include /E /I /Y >nul
xcopy "%W%\src" src\libwebrtc\src /E /I /Y >nul
xcopy "%W%\patches" src\libwebrtc\patches /E /I /Y >nul
xcopy "%W%\test" src\libwebrtc\test /E /I /Y >nul
copy /y "%W%\BUILD.gn" src\libwebrtc\ >nul
copy /y "%W%\LICENSE" src\libwebrtc\ >nul
cd src
copy /y .vpython3 .. >nul
for %%P in (custom_audio_source_m150 add_libwebrtc_build_target allow_176k4_192k_shared_mode_formats disable_win_builtin_aec_dmo) do (
  call git apply "libwebrtc\patches\%%P.patch" -v --ignore-space-change --ignore-whitespace --whitespace=nowarn || exit /b 1
)
cd ..
echo SYNC_OK
