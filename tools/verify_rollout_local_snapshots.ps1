param([string]$AuditDirectory = 'audit/structure-sync-20261020', [string]$AfterSuffix = 'after68')
$ErrorActionPreference = 'Stop'
function Read-Preferences([string]$Path) {
  [xml]$document = Get-Content -LiteralPath $Path -Raw
  $values = @{}
  foreach ($entry in $document.map.ChildNodes) {
    $values[$entry.name] = if ($entry.HasAttribute('value')) { $entry.GetAttribute('value') } else { $entry.InnerText }
  }
  return $values
}
function Canonical($Value) {
  if ($Value -is [System.Collections.IDictionary]) {
    $ordered = [ordered]@{}
    foreach ($key in @($Value.Keys | Sort-Object)) { $ordered[$key] = Canonical $Value[$key] }
    return $ordered
  }
  if ($Value -is [array]) {
    $items = @(foreach ($item in $Value) { ,(Canonical $item) })
    return ,$items
  }
  if ($Value -is [pscustomobject]) {
    $ordered = [ordered]@{}
    foreach ($property in @($Value.psobject.Properties | Sort-Object Name)) { $ordered[$property.Name] = Canonical $property.Value }
    return $ordered
  }
  return $Value
}
function Json($Value) { ConvertTo-Json -InputObject (Canonical $Value) -Depth 100 -Compress }
function Progress-Json($Raw) {
  if ($null -eq $Raw -or $Raw -eq '') { return $Raw }
  try { return Json (ConvertFrom-Json -InputObject $Raw -Depth 100) }
  catch { return $Raw } # Android SharedPreferences string-list encoding.
}
$settings = @('quickBook','sessionSize','targetName','targetDate','horizontalSwipe','reverseSwipe','readingAboveTerm','showExamples','flipCard','autoPlayPronunciation','undoHaptics','japaneseFont','termFontSize','readingFontSize','meaningFontSize','exampleFontSize','exampleMeaningFontSize','meaningFontWeight','meaningOpacity','chatGptConversationUrl','chatGptWordPromptTemplate','chatGptKanjiPromptTemplate','openDictionaryInApp')
$results = foreach ($device in @('s23','a52')) {
  $before = Read-Preferences "$AuditDirectory/$device-before68/FlutterSharedPreferences.xml"
  $after = Read-Preferences "$AuditDirectory/$device-$AfterSuffix/FlutterSharedPreferences.xml"
  $uid = $before['flutter.activeAccount.v1']
  if ($uid -ne $after['flutter.activeAccount.v1']) { throw "$device account changed" }
  $oldBooks = $before['flutter.books'] | ConvertFrom-Json -Depth 100
  $newBooks = $after['flutter.books'] | ConvertFrom-Json -Depth 100
  $differences = @()
  $expectedIncomingCorrections = @()
  if ((Json @($oldBooks.id)) -ne (Json @($newBooks.id))) { $differences += 'book order/IDs' }
  $cardsChecked = 0
  foreach ($book in $oldBooks) {
    $new = $newBooks | Where-Object id -eq $book.id
    if ((Json @($book.words.id)) -ne (Json @($new.words.id))) { $differences += "order/IDs:$($book.id)" }
    $wordMap = @{}; foreach ($word in $new.words) { $wordMap[[string]$word.id] = $word }
    foreach ($word in $book.words) {
      $replacement = $wordMap[[string]$word.id]
      foreach ($field in @('term','reading','meaning','example','exampleMeaning','explanation','state','correctCount','wrongCount','lastStudiedAt','lastWrongAt','isFavorite','favoriteUpdatedAt')) {
        if ((Json $word.$field) -cne (Json $replacement.$field)) {
          $label = "$($book.id)/$($word.id):$field"
          # The disconnected A52s still had the earlier approved test marker
          # from build66. Server baseline15 was already empty before this run.
          if ($device -eq 'a52' -and $book.id -eq '1789576241164569' -and
              $word.id -eq 304983559 -and $field -eq 'explanation' -and
              $word.explanation -ceq 'VF_SYNC_66_S23_TEST' -and
              $replacement.explanation -ceq '') { $expectedIncomingCorrections += $label }
          else { $differences += $label }
        }
      }
      $cardsChecked++
    }
  }
  $settingsDifferences = @($settings | Where-Object { $before["flutter.$_"] -cne $after["flutter.$_"] })
  $progressDifferences = @(@('activeStudies','activeStudyTombstones','completed','completedAt','rangeCoursePassesV2','dailyStudyStats','studyEventLog') | Where-Object { (Progress-Json $before["flutter.$_"]) -cne (Progress-Json $after["flutter.$_"]) })
  $tracker = $after["flutter.cardChangeTracker.v1.$uid"] | ConvertFrom-Json -Depth 100
  $cloud = $after["flutter.cloudChangeTracker.v2.$uid"] | ConvertFrom-Json -Depth 100
  $session = ($after['flutter.activeStudies'] | ConvertFrom-Json -Depth 100).'1789576241164569:current'
  [pscustomobject]@{
    device = $device; books = @($newBooks).Count; cardsChecked = $cardsChecked
    contentOrLearningDifferences = $differences
    expectedIncomingCorrections = $expectedIncomingCorrections
    settingsDifferences = $settingsDifferences; progressPreferenceDifferences = $progressDifferences
    cardPending = @($tracker.pending).Count; cardRefreshPending = @($tracker.refreshCards.psobject.Properties).Count
    cardError = $tracker.lastError; lastCardSuccess = $tracker.lastSuccess
    automaticBackupEnabled = $after["flutter.autoBackup.enabled.$uid"]
    learningPending = $cloud.learningStateDirty
    settingsPending = @($cloud.settingsKeys).Count; settingsError = $cloud.settingsLastError
    archivePending = @($cloud.archiveIds).Count
    currentSession = @{ rangeStart=$session.rangeStart; rangeEnd=$session.rangeEnd; memorized=$session.memorized; total=$session.total; round=$session.roundNumber; roundTotal=$session.roundTotal; deferred=@($session.roundUnknownIds).Count }
  }
}
$results | ConvertTo-Json -Depth 15
if (@($results | Where-Object { $_.contentOrLearningDifferences.Count -or $_.settingsDifferences.Count -or $_.progressPreferenceDifferences.Count -or $_.cardPending -or $_.cardRefreshPending -or $_.cardError -or $_.learningPending -or $_.settingsPending -or $_.settingsError -or $_.archivePending }).Count) { exit 2 }
