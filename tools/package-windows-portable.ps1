param(
    [string]$ImageDirectory = 'desktop/build/compose/binaries/main/app',
    [string]$OutputDirectory = 'dist'
)

$ErrorActionPreference = 'Stop'
$versionLine = Get-Content 'gradle.properties' | Where-Object { $_ -match '^zedsecure.versionName=' } | Select-Object -First 1
$version = ($versionLine -split '=', 2)[1].Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid application version' }
$image = Get-ChildItem $ImageDirectory -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'ZedSecure.exe') } | Select-Object -First 1
if (-not $image) { throw 'The application image does not contain ZedSecure.exe' }
if (-not (Test-Path (Join-Path $image.FullName 'runtime/bin/server/jvm.dll'))) { throw 'The portable Java runtime is missing' }

$out = New-Item -ItemType Directory -Path $OutputDirectory -Force
$archiveName = "ZedSecure-$version-Aether-Windows-x64-Portable.zip"
$archive = Join-Path $out.FullName $archiveName
$readme = @'
ZedSecure + Aether — نسخهٔ پرتابل ویندوز ۶۴بیتی

۱. کل فایل ZIP را استخراج کنید.
۲. داخل پوشهٔ ZedSecure، فایل ZedSecure.exe را اجرا کنید.
۳. از بخش سرورها (Servers)، افزودن (+) و سپس Aether را انتخاب کنید.
۴. پروفایل را ذخیره و انتخاب کنید و اتصال (Connect) را بزنید.

برای Aether از حالت پروکسی سیستم (System Proxy) استفاده کنید.
تمام پوشه‌ها و فایل‌ها را کنار برنامه نگه دارید؛ فایل EXE را به‌تنهایی جابه‌جا نکنید.
جاوا همراه برنامه است و نیاز به نصب جداگانه ندارد.
تنظیمات برنامه در پروفایل کاربر ویندوز ذخیره می‌شوند.

این خروجی برای تست است؛ اتصال واقعی به وارپ به شرایط شبکهٔ شما وابسته است.
'@
Set-Content (Join-Path $image.FullName 'README-fa.txt') $readme -Encoding utf8

Push-Location $image.Parent.FullName
try {
    & 7z a -tzip -mx=5 $archive $image.Name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Creating the portable ZIP failed' }
} finally { Pop-Location }

# Exercise the archive, its bundled runtime and its own core, from a path with spaces.
$check = Join-Path ([IO.Path]::GetTempPath()) ('ZedSecure portable check ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $check | Out-Null
Expand-Archive -LiteralPath $archive -DestinationPath $check
$root = Join-Path $check $image.Name
$exe = Join-Path $root 'ZedSecure.exe'
if (-not (Test-Path $exe)) { throw 'The ZIP does not contain the launcher' }
if (-not (Test-Path (Join-Path $root 'runtime/bin/server/jvm.dll'))) { throw 'The ZIP does not contain its Java runtime' }
if (Get-ChildItem $root -Recurse -Filter '*.msi') { throw 'An installer was included in the portable ZIP' }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$core = Join-Path $check 'aether.exe'
$found = $false
foreach ($file in Get-ChildItem (Join-Path $root 'app') -Recurse -Filter '*.jar') {
    $jar = [IO.Compression.ZipFile]::OpenRead($file.FullName)
    try {
        $entry = $jar.GetEntry('bin/windows/aether.exe')
        if ($entry) {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $core, $true)
            if (-not $jar.GetEntry('bin/windows/aether-licenses/aether-LICENSE.txt')) { throw 'Bundled Aether license is missing' }
            $found = $true
            break
        }
    } finally { $jar.Dispose() }
}
if (-not $found) { throw 'Aether is missing from the portable application resources' }
$expectedCore = Get-FileHash 'desktop/src/main/resources/bin/windows/aether.exe' -Algorithm SHA256
if ((Get-FileHash $core -Algorithm SHA256).Hash -ne $expectedCore.Hash) { throw 'Packaged Aether differs from the pinned core' }
$help = & $core help 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $help -notmatch '--quick-reconnect') { throw 'The extracted Aether core failed to run' }

$stdout = Join-Path $out.FullName 'windows-launcher-stdout.txt'
$stderr = Join-Path $out.FullName 'windows-launcher-stderr.txt'
$p = Start-Process -FilePath $exe -ArgumentList '--version' -PassThru -Wait -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if ($p.ExitCode -ne 0) { throw "The packaged launcher failed with exit code $($p.ExitCode)" }
$printed = Get-Content $stdout -Raw -ErrorAction SilentlyContinue
if ($printed -and $printed.Trim() -ne "ZedSecure $version") { throw "Unexpected application version: $printed" }

$p = $null
$opened = $false
try {
    $p = Start-Process -FilePath $exe -PassThru -WorkingDirectory $root -RedirectStandardOutput (Join-Path $out.FullName 'windows-gui-stdout.txt') -RedirectStandardError (Join-Path $out.FullName 'windows-gui-stderr.txt')
    $deadline = [DateTime]::UtcNow.AddSeconds(40)
    while ([DateTime]::UtcNow -lt $deadline) {
        $p.Refresh()
        if ($p.HasExited) { throw "The portable app exited before opening a window: $($p.ExitCode)" }
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $opened = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $opened) {
        $p | Select-Object Id, ProcessName, HasExited, MainWindowHandle, MainWindowTitle | ConvertTo-Json | Set-Content (Join-Path $out.FullName 'windows-gui-process.json')
        Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -eq $p.Id -or $_.ParentProcessId -eq $p.Id } | Select-Object ProcessId, ParentProcessId, Name, CommandLine | ConvertTo-Json | Set-Content (Join-Path $out.FullName 'windows-gui-process-tree.json')
        try {
            & (Join-Path $env:JAVA_HOME 'bin/jcmd.exe') $p.Id Thread.print 2>&1 | Out-File (Join-Path $out.FullName 'windows-gui-threads.txt') -Encoding utf8
        } catch { $_ | Out-File (Join-Path $out.FullName 'windows-gui-threads.txt') -Encoding utf8 }
        throw 'The portable application did not open a window'
    }
} finally {
    if ($p -and -not $p.HasExited) {
        Stop-Process -Id $p.Id -Force
        $null = $p.WaitForExit(10000)
    }
}

$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content (Join-Path $out.FullName 'SHA256SUMS.txt') "$hash  $archiveName" -Encoding ascii
$receipt = [ordered]@{
    version = $version
    source_commit = $env:GITHUB_SHA
    archive = $archiveName
    sha256 = $hash
    architecture = 'windows-x86_64'
    bundled_runtime = $true
    aether_core_sha256 = $expectedCore.Hash.ToLowerInvariant()
    extracted_core_help = 'PASS'
    launcher_exit = 'PASS'
    gui_window = 'PASS'
    installer_included = $false
    live_warp_connectivity = 'NOT_TESTED'
}
$receipt | ConvertTo-Json | Set-Content (Join-Path $out.FullName 'windows-portable-validation.json') -Encoding utf8
Remove-Item $check -Recurse -Force
Write-Host "Portable application and GUI smoke check passed: $archive"
