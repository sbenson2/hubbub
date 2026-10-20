@echo off
rem Builds libwebrtc.dll from the tree sync.cmd prepared and packs
rem %WORK%\libwebrtc-win-x64-release.zip. Takes about 18 min. Run sync.cmd first.
setlocal EnableExtensions
if not defined WORK set "WORK=C:\wrtc\work"
set "vs2022_install=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
set DEPOT_TOOLS_WIN_TOOLCHAIN=0
set GYP_MSVS_VERSION=2022
set GIT_CONFIG_COUNT=3
set "GIT_CONFIG_KEY_0=core.autocrlf" & set "GIT_CONFIG_VALUE_0=false"
set "GIT_CONFIG_KEY_1=core.filemode" & set "GIT_CONFIG_VALUE_1=false"
set "GIT_CONFIG_KEY_2=core.longpaths" & set "GIT_CONFIG_VALUE_2=true"
cd /d "%WORK%" || exit /b 1
set "PATH=%WORK%\depot_tools;%PATH%"
if not exist "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\dbghelp.dll" (echo NEED_DEBUGGING_TOOLS & exit /b 3)
call gn.bat gen src\out-x64-release --root="src" --args="is_debug=false is_clang=true target_cpu=\"x64\" use_custom_libcxx=false rtc_libvpx_build_vp9=true enable_libaom=true rtc_include_tests=true rtc_build_examples=false rtc_build_tools=false is_component_build=false rtc_enable_protobuf=false rtc_use_h264=true ffmpeg_branding=\"Chrome\" rtc_use_h265=true symbol_level=0 enable_iterator_debugging=false"
if errorlevel 1 exit /b 1
set "NINJA=src\third_party\ninja\ninja.exe"
if not exist "%NINJA%" set "NINJA=ninja.bat"
call %NINJA% -C src\out-x64-release libwebrtc libwebrtc_cpp_api_unittests || exit /b 1
set "OUT=%WORK%\libwebrtc-x64-release"
if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%OUT%\lib" "%OUT%\include"
copy src\out-x64-release\libwebrtc.dll "%OUT%\lib" && copy src\out-x64-release\libwebrtc.dll.lib "%OUT%\lib" && copy src\libwebrtc\LICENSE "%OUT%\"
xcopy "src\libwebrtc\include\*.h" "%OUT%\include" /C /S /I /F /H >nul
rem tar.exe (bsdtar) writes forward-slash entry names; PowerShell 5.1 Compress-Archive
rem writes backslashes, which non-Windows extractors mishandle.
if exist libwebrtc-win-x64-release.zip del libwebrtc-win-x64-release.zip
tar.exe -a -c -f libwebrtc-win-x64-release.zip libwebrtc-x64-release || exit /b 1
powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 '%WORK%\libwebrtc-win-x64-release.zip').Hash.ToLower()"
echo BUILD_OK
