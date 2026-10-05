<#
.SYNOPSIS
Automatically moves VocaFlow pronunciation requests between USB-connected
Android phones and the local VOICEVOX/Kanjium generator.

.DESCRIPTION
Run with -Watch while the PC is on. It uses only ADB and local files: no card
data is uploaded and no Firestore data is changed. The app queues exact
Japanese term/reading pairs in its own external app directory. This worker
creates a pack, puts it back in that directory, and the app installs it.
#>
[CmdletBinding()]
param(
    [string]$AdbPath = 'D:\DevTools\Android\platform-tools\adb.exe',
    [string]$GeneratorPath = '',
    [string]$DictionaryPath = 'D:\DevTools\VocaFlowSpeech\data\kanjium-accents.txt',
    [string]$EngineUrl = 'http://127.0.0.1:50021',
    [string]$WorkDirectory = 'D:\DevTools\VocaFlowSpeech\usb-bridge',
    [string]$PowerShellPath = '',
    [int]$PollSeconds = 30,
    [switch]$Watch
)

# ADB reports ordinary transfer progress on stderr. Native stderr must not be
# promoted to a terminating PowerShell error; each external command below
# checks its own exit code instead.
$ErrorActionPreference = 'Continue'
$GeneratorPath = if ([string]::IsNullOrWhiteSpace($GeneratorPath)) {
    Join-Path $PSScriptRoot 'generate_pitch_samples.ps1'
} else {
    $GeneratorPath
}
$PowerShellPath = if ([string]::IsNullOrWhiteSpace($PowerShellPath)) {
    $command = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -eq $command) { throw 'PowerShell 7 (pwsh) is required for UTF-8 Japanese synthesis.' }
    $command.Source
} else {
    $PowerShellPath
}
$package = 'com.vocaflow.app'
$remoteRoot = "/sdcard/Android/data/$package/files/pronunciation-bridge"

foreach ($path in @($AdbPath, $GeneratorPath, $DictionaryPath, $PowerShellPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required file was not found: $path" }
}
New-Item -ItemType Directory -Force -Path $WorkDirectory | Out-Null

function Get-Devices {
    & $AdbPath devices | Select-Object -Skip 1 | ForEach-Object {
        $parts = $_ -split '\s+'
        if ($parts.Count -ge 2 -and $parts[1] -eq 'device') { $parts[0] }
    }
}

function Sync-Device([string]$serial) {
    $local = Join-Path $WorkDirectory $serial
    $output = Join-Path $local 'output'
    New-Item -ItemType Directory -Force -Path $local, $output | Out-Null
    $null = & $AdbPath -s $serial shell "mkdir -p '$remoteRoot/incoming'" 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the phone handoff folder.' }
    $requests = Join-Path $local 'requests.json'
    # ADB writes normal transfer progress to stderr. Capture it explicitly so
    # $ErrorActionPreference does not mistake a successful pull for a failure.
    $pullOutput = & $AdbPath -s $serial pull "$remoteRoot/requests.json" $requests 2>&1
    if ($LASTEXITCODE -ne 0) { return }
    if (-not (Test-Path -LiteralPath $requests)) { return }
    try {
        # Dart writes UTF-8 without a BOM. Windows PowerShell otherwise treats
        # it as the system ANSI code page and corrupts Japanese requests.
        $queue = [IO.File]::ReadAllText($requests, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch { Write-Warning "[$serial] invalid request list"; return }
    if ($queue.schemaVersion -ne 1 -or $null -eq $queue.requests -or $queue.requests.Count -eq 0) { return }
    $tsv = Join-Path $local 'pending.tsv'
    [IO.File]::WriteAllLines(
        $tsv,
        @($queue.requests | Select-Object -First 50 | ForEach-Object { "$($_.term)`t$($_.reading)" }),
        [Text.UTF8Encoding]::new($false)
    )
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $job = Join-Path $output $stamp
    $pack = Join-Path $local "pitch-$stamp.vfpitch.zip"
    & $PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $GeneratorPath -InputPath $tsv -DictionaryPath $DictionaryPath -OutputDirectory $job -EngineUrl $EngineUrl -PackPath $pack
    if ($LASTEXITCODE -ne 0) { throw 'Local speech generation failed.' }
    $manifest = [IO.File]::ReadAllText((Join-Path $job 'manifest.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($manifest.entries.Count -eq 0) { Remove-Item -LiteralPath $pack -Force -ErrorAction SilentlyContinue; return }
    $null = & $AdbPath -s $serial push $pack "$remoteRoot/incoming/$(Split-Path -Leaf $pack)" 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Could not deliver the generated pack to the phone.' }
    Write-Host "[$serial] delivered $($manifest.entries.Count) pronunciation candidates."
}

do {
    foreach ($serial in Get-Devices) {
        try { Sync-Device $serial } catch { Write-Warning "[$serial] $($_.Exception.Message)" }
    }
    if ($Watch) { Start-Sleep -Seconds $PollSeconds }
} while ($Watch)
