<#!
.SYNOPSIS
Creates locally synthesized WAV samples from an exact Kanjium spelling/reading
lookup. It never uploads vocabulary data and never changes VocaFlow cards.

.DESCRIPTION
Input is UTF-8 tab-separated `term<TAB>reading`. Each exact dictionary accent
candidate becomes a separate WAV. The script asks a local VOICEVOX Engine to
recalculate mora pitch after setting the candidate's accent position; changing
only the JSON accent number is insufficient.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InputPath,

    [Parameter(Mandatory)]
    [string]$DictionaryPath,

    [Parameter(Mandatory)]
    [string]$OutputDirectory,

    [string]$EngineUrl = 'http://127.0.0.1:50021',

    [int]$Speaker = 2,

    [string]$PackPath
)

$ErrorActionPreference = 'Stop'

function Convert-ToKatakana([string]$Reading) {
    $buffer = [System.Text.StringBuilder]::new()
    foreach ($character in $Reading.Trim().ToCharArray()) {
        $code = [int][char]$character
        if ($code -ge 0x3041 -and $code -le 0x3096) {
            [void]$buffer.Append([char]($code + 0x60))
        } else {
            [void]$buffer.Append($character)
        }
    }
    return $buffer.ToString()
}

function Get-Morae([string]$Reading) {
    $smallKana = @('ァ', 'ィ', 'ゥ', 'ェ', 'ォ', 'ャ', 'ュ', 'ョ', 'ヮ', 'ヵ', 'ヶ')
    $morae = [System.Collections.Generic.List[string]]::new()
    foreach ($character in (Convert-ToKatakana $Reading).ToCharArray()) {
        $text = [string]$character
        if ($smallKana -contains $text) {
            if ($morae.Count -eq 0) {
                throw "Reading starts with a small kana: $Reading"
            }
            $morae[$morae.Count - 1] += $text
        } else {
            $morae.Add($text)
        }
    }
    if ($morae.Count -eq 0) {
        throw 'Reading is empty.'
    }
    return $morae.ToArray()
}

function Invoke-VoicevoxPost([string]$Path, [object]$Body) {
    $json = $Body | ConvertTo-Json -Depth 20 -Compress -AsArray
    return Invoke-RestMethod -Method Post -Uri "$EngineUrl$Path" -ContentType 'application/json' -Body $json
}

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Input file was not found: $InputPath"
}
if (-not (Test-Path -LiteralPath $DictionaryPath)) {
    throw "Dictionary file was not found: $DictionaryPath"
}

$engineVersion = Invoke-RestMethod -Uri "$EngineUrl/version"
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$audioDirectory = Join-Path $OutputDirectory 'audio'
New-Item -ItemType Directory -Force -Path $audioDirectory | Out-Null

$dictionary = @{}
foreach ($line in [System.IO.File]::ReadLines($DictionaryPath)) {
    $fields = $line.Trim() -split "`t"
    if ($fields.Count -ne 3) { continue }
    $key = "$($fields[0])$([char]0)$($fields[1])"
    $accents = @($fields[2] -split ',' | ForEach-Object {
        if ($_.Trim() -match '(\d+)$') { [int]$Matches[1] }
    })
    $dictionary[$key] = $accents
}

$results = [System.Collections.Generic.List[object]]::new()
$sampleIndex = 0
foreach ($line in [System.IO.File]::ReadLines($InputPath)) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
    $fields = $line.Trim() -split "`t"
    if ($fields.Count -ne 2) {
        $results.Add([pscustomobject]@{ status = 'invalid-input'; source = $line })
        continue
    }
    $term = $fields[0]
    $reading = $fields[1]
    $key = "$term$([char]0)$reading"
    if (-not $dictionary.ContainsKey($key)) {
        $results.Add([pscustomobject]@{ status = 'not-found'; term = $term; reading = $reading })
        continue
    }

    $morae = Get-Morae $reading
    $baseKana = $morae -join ''
    $remainingMorae = if ($morae.Count -gt 1) {
        $morae[1..($morae.Count - 1)] -join ''
    } else {
        ''
    }
    $accentProbe = "$($morae[0])'$remainingMorae"
    $encodedProbe = [uri]::EscapeDataString($accentProbe)
    $phrase = (Invoke-RestMethod -Method Post -Uri "$EngineUrl/accent_phrases?text=$encodedProbe&speaker=$Speaker&is_kana=true")[0]
    $encodedKana = [uri]::EscapeDataString($baseKana)
    $query = Invoke-RestMethod -Method Post -Uri "$EngineUrl/audio_query?text=$encodedKana&speaker=$Speaker"

    foreach ($accent in $dictionary[$key]) {
        if ($accent -lt 0 -or $accent -gt $morae.Count) {
            $results.Add([pscustomobject]@{ status = 'invalid-accent'; term = $term; reading = $reading; accent = $accent })
            continue
        }
        $phrase.accent = $accent
        $recalculated = Invoke-VoicevoxPost "/mora_data?speaker=$Speaker" @($phrase)
        $query.accent_phrases = @($recalculated[0])
        $fileName = ('{0:d3}-{1}-{2}.wav' -f $sampleIndex, $term, $accent)
        $outputPath = Join-Path $audioDirectory $fileName
        $queryJson = $query | ConvertTo-Json -Depth 20 -Compress
        Invoke-WebRequest -Method Post -Uri "$EngineUrl/synthesis?speaker=$Speaker" -ContentType 'application/json' -Body $queryJson -OutFile $outputPath
        $results.Add([pscustomobject]@{
            status = 'generated'; term = $term; reading = $reading; accent = $accent
            file = $fileName; morae = $morae
            moraPitches = @($recalculated[0].moras | ForEach-Object { $_.pitch })
            queryHash = (Get-FileHash -Algorithm SHA256 -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($queryJson)))).Hash
        })
        $sampleIndex++
    }
}

$manifest = [pscustomobject]@{
    schemaVersion = 1
    packId = [guid]::NewGuid().ToString('N')
    engineVersion = $engineVersion
    speaker = $Speaker
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    dictionarySha256 = (Get-FileHash -Algorithm SHA256 $DictionaryPath).Hash
    results = $results
    entries = @($results | Where-Object status -eq 'generated' | ForEach-Object {
        [pscustomobject]@{
            term = $_.term
            reading = $_.reading
            accentPosition = $_.accent
            audioPath = "audio/$($_.file)"
        }
    })
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 (Join-Path $OutputDirectory 'manifest.json')
if ($PackPath) {
    if (Test-Path -LiteralPath $PackPath) {
        throw "Pack path already exists: $PackPath"
    }
    Compress-Archive -Path (Join-Path $OutputDirectory 'manifest.json'), $audioDirectory -DestinationPath $PackPath
}
$manifest
