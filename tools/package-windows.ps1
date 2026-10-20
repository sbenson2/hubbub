# Packages the Flutter release build into the Velopack installer and update feed.
#   powershell -File tools\package-windows.ps1 [-Version 0.1.0] [-Source <Release dir>] [-OutDir dist\windows]
# Output in dist\windows (git-ignored): HubbubSetup.exe (the one download), Hubbub-<ver>-full.nupkg,
# Hubbub-<ver>-delta.nupkg (when an earlier release is in the folder) and releases.win.json (the
# update feed). Upload the lot to the release; HubbubSetup.exe is what users get.
# Needs the vpk tool:  dotnet tool install -g vpk
param(
  [string]$Version,
  [string]$Source,
  [string]$OutDir,
  [string]$Channel = 'win'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $Source) { $Source = Join-Path $repo 'app\build\windows\x64\runner\Release' }
if (-not $OutDir) { $OutDir = Join-Path $repo 'dist\windows' }

# The version comes from app/pubspec.yaml ("0.1.0+1" -> 0.1.0, "0.1.2-beta.1+3" -> 0.1.2-beta.1);
# -Version overrides it. A SemVer prerelease suffix is accepted.
if (-not $Version) {
  $line = Select-String -Path (Join-Path $repo 'app\pubspec.yaml') -Pattern '^version:\s*(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)' | Select-Object -First 1
  if (-not $line) { throw 'no semver version: line in app\pubspec.yaml' }
  $Version = $line.Matches[0].Groups[1].Value
}
if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$') { throw "version '$Version' is not major.minor.patch or major.minor.patch-prerelease" }

foreach ($f in 'hubbub.exe', 'hubbub_app.dll', 'flutter_windows.dll', 'livekit-server.exe') {
  if (-not (Test-Path (Join-Path $Source $f))) { throw "$f missing from $Source; run: flutter build windows --release (and tools/fetch-livekit.sh windows amd64)" }
}
$vpk = Get-Command vpk -ErrorAction SilentlyContinue
if (-not $vpk) { $vpk = Join-Path $env:USERPROFILE '.dotnet\tools\vpk.exe' } else { $vpk = $vpk.Source }
if (-not (Test-Path $vpk)) { throw 'vpk not found; run: dotnet tool install -g vpk' }

New-Item -ItemType Directory -Force $OutDir | Out-Null
$icon = Join-Path $repo 'app\windows\runner\resources\app_icon.ico'
# Earlier releases already in $OutDir are what vpk builds the delta against.
& $vpk pack --packId Hubbub --packTitle Hubbub --packAuthors Hubbub --packVersion $Version `
  --packDir $Source --mainExe hubbub.exe --icon $icon --runtime win-x64 --channel $Channel `
  --shortcuts 'Desktop,StartMenuRoot' --outputDir $OutDir
if ($LASTEXITCODE -ne 0) { throw "vpk pack failed ($LASTEXITCODE)" }

# vpk names the installer Hubbub-<channel>-Setup.exe; users get a plain name.
Copy-Item (Join-Path $OutDir "Hubbub-$Channel-Setup.exe") (Join-Path $OutDir 'HubbubSetup.exe') -Force
Write-Host "Packaged Hubbub $Version into $OutDir"
Get-ChildItem $OutDir | Where-Object { $_.Name -match 'HubbubSetup.exe|nupkg|releases' } | Format-Table Name, Length
