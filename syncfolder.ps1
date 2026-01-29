<#
.SYNOPSIS
Скрипт для синхронизации нескольких пар папок с возможностью выбора направления и режима сравнения файлов.

.DESCRIPTION
Скрипт синхронизирует содержимое нескольких пар папок с тремя вариантами направления:
- LeftToRight  (из Source в Destination)
- RightToLeft  (из Destination в Source)
- Both         (двусторонняя синхронизация: обновление с обеих сторон)

Поддерживает несколько пар папок через массив FolderPairs:
[
  {
    "Source": "C:\\test_dir\\Project\\MyApp1",
    "Destination": "C:\\test_dir\\Backup\\MyApp1"
  },
  {
    "Source": "C:\\test_dir\\Project\\MyApp2",
    "Destination": "C:\\test_dir\\Backup\\MyApp2"
  }
]

Режимы сравнения файлов (CompareMode):
- TimeAndSize  — по дате изменения и размеру файла (быстро, по умолчанию)
- ContentHash  — по хэшу содержимого (надёжно, но медленнее)

Дополнительно:
- исключение подпапок (ExcludeDirectories);
- фильтры по маскам файлов: IncludePatterns (включать), ExcludePatterns (исключать);
- односторонняя синхронизация удаляет лишние файлы в получателе;
- двусторонняя синхронизация управляет удалением через TwoWayDeletionSide;
- запуск по JSON-настройкам (settings.json) — режим по умолчанию;
- логирование действий в файл (LogPath):
  - один лог-файл в день: <basename>-YYYY-MM-DD<ext>;
  - в каждой строке есть RunId (идентификатор запуска);
  - ротация логов по числу дней (LogRetentionDays);
- стандартные -WhatIf и -Confirm (SupportsShouldProcess).
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param (
    [ValidateSet("LeftToRight", "RightToLeft", "Both")]
    [string]$SyncDirection,

    [string[]]$ExcludeDirectories = @(),

    [ValidateSet("TimeAndSize", "ContentHash")]
    [string]$CompareMode,

    [string[]]$IncludePatterns = @(),

    [string[]]$ExcludePatterns = @(),

    [string]$LogPath,

    [int]$LogRetentionDays,

    [ValidateSet("None", "Source", "Destination")]
    [string]$TwoWayDeletionSide,

    [string]$SettingsPath
)

# ---- Константы и служебные переменные ----

$validDirections = @("LeftToRight", "RightToLeft", "Both")
$validCompareModes = @("TimeAndSize", "ContentHash")
$validTwoWayDelete = @("None", "Source", "Destination")

# RunId для текущего запуска (будет в каждой строке лога)
$script:RunId = "{0}-{1:0000}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), (Get-Random -Maximum 10000)
# Фактический путь к лог-файлу за текущий день
$script:LogFilePath = $null

# Массив пар папок для синхронизации
$script:FolderPairs = @()

# ---- Автопоиск settings.json рядом со скриптом, если SettingsPath не задан ----

if (-not $SettingsPath) {
    $autoSettings = Join-Path -Path $PSScriptRoot -ChildPath 'settings.json'
    if (Test-Path -LiteralPath $autoSettings -PathType Leaf) {
        $SettingsPath = $autoSettings
    }
}

# ---- Загрузка настроек из JSON (если указан SettingsPath) ----

if ($SettingsPath) {
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        throw "Файл настроек не найден: $SettingsPath"
    }

    try {
        $configJson = Get-Content -LiteralPath $SettingsPath -Raw -ErrorAction Stop
        $config = $configJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $msg = "Не удалось прочитать или разобрать JSON из файла настроек '{0}': {1}" -f $SettingsPath, $_.Exception.Message
        throw $msg
    }

    # ---- Извлечение пар папок из настроек ----

    # Основной способ: массив FolderPairs
    if ($config.FolderPairs) {
        try {
            $pairIndex = 1
            foreach ($pair in $config.FolderPairs) {
                if (-not $pair.Source -or -not $pair.Destination) {
                    Write-Warning "Найдена неполная пара папок в FolderPairs: $($pair | ConvertTo-Json -Compress)"
                    continue
                }

                $script:FolderPairs += @{
                    Source      = [string]$pair.Source
                    Destination = [string]$pair.Destination
                    Number      = $pairIndex.ToString()
                }
                $pairIndex++
            }
        }
        catch {
            Write-Warning "Ошибка при обработке FolderPairs: $_"
        }
    }

    # Если FolderPairs не найден или пуст
    if ($script:FolderPairs.Count -eq 0) {
        throw "Не указаны пары папок для синхронизации в настройках (отсутствует или пуст параметр FolderPairs)."
    }

    # Остальные настройки
    if (-not $SyncDirection -and $config.SyncDirection) {
        if ($config.SyncDirection -notin $validDirections) {
            $msg = "SyncDirection из settings.json имеет недопустимое значение: {0}. Допустимые: {1}" -f $config.SyncDirection, ($validDirections -join ', ')
            throw $msg
        }
        $SyncDirection = [string]$config.SyncDirection
    }

    if (($ExcludeDirectories.Count -eq 0) -and $config.ExcludeDirectories) {
        $ExcludeDirectories = [string[]]$config.ExcludeDirectories
    }

    if (-not $CompareMode -and $config.CompareMode) {
        if ($config.CompareMode -notin $validCompareModes) {
            $msg = "CompareMode из settings.json имеет недопустимое значение: {0}. Допустимые: {1}" -f $config.CompareMode, ($validCompareModes -join ', ')
            throw $msg
        }
        $CompareMode = [string]$config.CompareMode
    }

    if (($IncludePatterns.Count -eq 0) -and $config.IncludePatterns) {
        $IncludePatterns = [string[]]$config.IncludePatterns
    }

    if (($ExcludePatterns.Count -eq 0) -and $config.ExcludePatterns) {
        $ExcludePatterns = [string[]]$config.ExcludePatterns
    }

    if (-not $LogPath -and $config.LogPath) {
        $LogPath = [string]$config.LogPath
    }

    if (-not $LogRetentionDays -and $config.LogRetentionDays) {
        $LogRetentionDays = [int]$config.LogRetentionDays
    }

    if (-not $TwoWayDeletionSide -and $config.TwoWayDeletionSide) {
        if ($config.TwoWayDeletionSide -notin $validTwoWayDelete) {
            $msg = "TwoWayDeletionSide из settings.json имеет недопустимое значение: {0}. Допустимые: {1}" -f $config.TwoWayDeletionSide, ($validTwoWayDelete -join ', ')
            throw $msg
        }
        $TwoWayDeletionSide = [string]$config.TwoWayDeletionSide
    }
}

# ---- Значения по умолчанию и финальная валидация ----

if ($script:FolderPairs.Count -eq 0) {
    throw "Не указаны пары папок для синхронизации (в settings.json отсутствует параметр FolderPairs)."
}

if (-not $SyncDirection) {
    throw "Не указан SyncDirection (ни параметром, ни в settings.json)."
}
if ($SyncDirection -notin $validDirections) {
    $msg = "SyncDirection '{0}' недопустим. Допустимые: {1}" -f $SyncDirection, ($validDirections -join ', ')
    throw $msg
}

if (-not $CompareMode) {
    $CompareMode = "TimeAndSize"
}
if ($CompareMode -notin $validCompareModes) {
    $msg = "CompareMode '{0}' недопустим. Допустимые: {1}" -f $CompareMode, ($validCompareModes -join ', ')
    throw $msg
}

if (-not $TwoWayDeletionSide) {
    $TwoWayDeletionSide = "None"
}
if ($TwoWayDeletionSide -notin $validTwoWayDelete) {
    $msg = "TwoWayDeletionSide '{0}' недопустим. Допустимые: {1}" -f $TwoWayDeletionSide, ($validTwoWayDelete -join ', ')
    throw $msg
}

if (-not $LogRetentionDays) {
    $LogRetentionDays = 0
}
if ($LogRetentionDays -lt 0) {
    throw "LogRetentionDays не может быть отрицательным."
}

# ---- Инициализация логирования ----

function Initialize-Logging {
    if (-not $LogPath) { return }

    try {
        $logDir = Split-Path -Path $LogPath -Parent
        $logFileName = Split-Path -Path $LogPath -Leaf

        if (-not $logDir -or $logDir -eq '.') {
            $logDir = $PSScriptRoot
        }

        $nameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($logFileName)
        $ext = [System.IO.Path]::GetExtension($logFileName)

        if (-not $nameWithoutExt) {
            $nameWithoutExt = "syncfolder"
        }
        if (-not $ext) {
            $ext = ".log"
        }

        $datePart = (Get-Date).ToString("yyyy-MM-dd")
        $script:LogFilePath = Join-Path -Path $logDir -ChildPath ("{0}-{1}{2}" -f $nameWithoutExt, $datePart, $ext)

        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        if ($LogRetentionDays -gt 0) {
            $cutoff = (Get-Date).Date.AddDays( - [int]$LogRetentionDays)
            $pattern = "{0}-*{1}" -f $nameWithoutExt, $ext

            Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like $pattern -and $_.LastWriteTime.Date -lt $cutoff
            } |
            ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        $script:LogFilePath = $null
    }
}

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "ACTION", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )
    if (-not $script:LogFilePath) { return }

    try {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $line = "[{0}] [RUN:{1}] [{2}] {3}" -f $ts, $script:RunId, $Level, $Message
        Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Логирование не должно ломать скрипт
    }
}

# ---- Вспомогательные функции ----

function Get-FileSignature {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [ValidateSet("TimeAndSize", "ContentHash")]
        [string]$CompareMode
    )

    $file = Get-Item -LiteralPath $FilePath -ErrorAction SilentlyContinue
    if ($null -eq $file) {
        return $null
    }

    $info = [ordered]@{
        LastWriteTime = $file.LastWriteTime
        Length        = $file.Length
        FullName      = $file.FullName
    }

    if ($CompareMode -eq "ContentHash") {
        try {
            $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop
            $info.Hash = $hash.Hash
        }
        catch {
            $info.Hash = $null
        }
    }

    return $info
}

function Test-IsExcludedPath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FullPath,

        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [string[]]$ExcludeDirectories = @()
    )

    if (-not $ExcludeDirectories -or $ExcludeDirectories.Count -eq 0) {
        return $false
    }

    $normalizedRoot = $RootPath.TrimEnd('\', '/')
    if ($FullPath.Length -le $normalizedRoot.Length) {
        return $false
    }

    $relative = $FullPath.Substring($normalizedRoot.Length).TrimStart('\', '/')
    if ([string]::IsNullOrEmpty($relative)) {
        return $false
    }

    $firstSegment = ($relative -split '[\\/]', 2)[0]

    return $ExcludeDirectories -contains $firstSegment
}

function Test-MatchIncludePattern {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string[]]$IncludePatterns = @()
    )

    if (-not $IncludePatterns -or $IncludePatterns.Count -eq 0) {
        return $true
    }

    foreach ($pattern in $IncludePatterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Test-MatchExcludePattern {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string[]]$ExcludePatterns = @()
    )

    if (-not $ExcludePatterns -or $ExcludePatterns.Count -eq 0) {
        return $false
    }

    foreach ($pattern in $ExcludePatterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

# ---- Синхронизация ----

function Sync-Files {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FromPath,

        [Parameter(Mandatory = $true)]
        [string]$ToPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet("LeftToRight", "RightToLeft", "Both")]
        [string]$Mode,

        [string[]]$ExcludeDirectories = @(),

        [string[]]$IncludePatterns = @(),

        [string[]]$ExcludePatterns = @(),

        [Parameter(Mandatory = $true)]
        [ValidateSet("TimeAndSize", "ContentHash")]
        [string]$CompareMode,

        [bool]$EnableDeletion = $false,

        [string]$PairNumber = ""
    )

    $normalizedFromPath = (Resolve-Path -LiteralPath $FromPath).Path.TrimEnd('\', '/')
    $normalizedToPath = (Resolve-Path -LiteralPath $ToPath).Path.TrimEnd('\', '/')

    $directionDescription = switch ($Mode) {
        "LeftToRight" { "из источника в назначение" }
        "RightToLeft" { "из назначения в источник" }
        "Both" { "двусторонняя (обновление)" }
    }

    $pairInfo = ""
    if ($PairNumber) {
        $pairInfo = " [Пара $PairNumber]"
    }

    Write-Host "Синхронизация $directionDescription$pairInfo ($normalizedFromPath -> $normalizedToPath) [CompareMode=$CompareMode, Deletion=$EnableDeletion]..." -ForegroundColor Cyan
    if ($PairNumber) {
        Write-Log  "START_SYNC_PAIR${PairNumber}: Mode=$Mode From='$normalizedFromPath' To='$normalizedToPath' CompareMode=$CompareMode Deletion=$EnableDeletion" "INFO"
    }
    else {
        Write-Log  "START_SYNC: Mode=$Mode From='$normalizedFromPath' To='$normalizedToPath' CompareMode=$CompareMode Deletion=$EnableDeletion" "INFO"
    }

    $sourceFiles = Get-ChildItem -LiteralPath $normalizedFromPath -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        -not (Test-IsExcludedPath -FullPath $_.FullName -RootPath $normalizedFromPath -ExcludeDirectories $ExcludeDirectories) -and
        (Test-MatchIncludePattern -Name $_.Name -IncludePatterns $IncludePatterns) -and
        -not (Test-MatchExcludePattern -Name $_.Name -ExcludePatterns $ExcludePatterns)
    }

    $destFiles = Get-ChildItem -LiteralPath $normalizedToPath -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        -not (Test-IsExcludedPath -FullPath $_.FullName -RootPath $normalizedToPath -ExcludeDirectories $ExcludeDirectories) -and
        (Test-MatchIncludePattern -Name $_.Name -IncludePatterns $IncludePatterns) -and
        -not (Test-MatchExcludePattern -Name $_.Name -ExcludePatterns $ExcludePatterns)
    }

    $sourceHash = @{}
    $destHash = @{}

    foreach ($file in $sourceFiles) {
        $sig = Get-FileSignature -FilePath $file.FullName -CompareMode $CompareMode
        if ($null -eq $sig) { continue }
        $relativePath = $file.FullName.Substring($normalizedFromPath.Length).TrimStart('\', '/')
        $sourceHash[$relativePath] = $sig
    }

    foreach ($file in $destFiles) {
        $sig = Get-FileSignature -FilePath $file.FullName -CompareMode $CompareMode
        if ($null -eq $sig) { continue }
        $relativePath = $file.FullName.Substring($normalizedToPath.Length).TrimStart('\', '/')
        $destHash[$relativePath] = $sig
    }

    $newFilesCount = 0
    $updatedFilesCount = 0
    $deletedFilesCount = 0

    foreach ($key in $sourceHash.Keys) {
        $sourceFile = $sourceHash[$key]
        $destFile = if ($destHash.ContainsKey($key)) { $destHash[$key] } else { $null }

        $destFullPath = Join-Path -Path $normalizedToPath -ChildPath $key

        if ($null -eq $destFile) {
            $sourceFullPath = $sourceFile.FullName
            $destDir = [System.IO.Path]::GetDirectoryName($destFullPath)

            if (-not (Test-Path -LiteralPath $destDir)) {
                Write-Host "  Создаём директорию: $destDir" -ForegroundColor Yellow
                if ($PSCmdlet.ShouldProcess($destDir, "Создание директории")) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                    if ($PairNumber) {
                        Write-Log "CREATE_DIR_PAIR${PairNumber}: '$destDir'" "ACTION"
                    }
                    else {
                        Write-Log "CREATE_DIR: '$destDir'" "ACTION"
                    }
                }
            }

            Write-Host "  Копируем новый файл: $key" -ForegroundColor Green
            if ($PSCmdlet.ShouldProcess($destFullPath, "Копирование нового файла из '$sourceFullPath'")) {
                Copy-Item -LiteralPath $sourceFullPath -Destination $destFullPath -Force
                if ($PairNumber) {
                    Write-Log "COPY_NEW_PAIR${PairNumber}: '$sourceFullPath' -> '$destFullPath'" "ACTION"
                }
                else {
                    Write-Log "COPY_NEW: '$sourceFullPath' -> '$destFullPath'" "ACTION"
                }
                $newFilesCount++
            }
        }
        else {
            $needUpdate = $false

            if ($CompareMode -eq "TimeAndSize") {
                if ($sourceFile.LastWriteTime -gt $destFile.LastWriteTime -or
                    $sourceFile.Length -ne $destFile.Length) {
                    $needUpdate = $true
                }
            }
            else {
                if ($sourceFile.Hash -ne $destFile.Hash) {
                    $needUpdate = $true
                }
            }

            if ($needUpdate) {
                Write-Host "  Обновляем файл: $key" -ForegroundColor Blue
                if ($PSCmdlet.ShouldProcess($destFullPath, "Обновление файла из '$($sourceFile.FullName)'")) {
                    Copy-Item -LiteralPath $sourceFile.FullName -Destination $destFullPath -Force
                    if ($PairNumber) {
                        Write-Log "COPY_UPDATE_PAIR${PairNumber}: '$($sourceFile.FullName)' -> '$destFullPath'" "ACTION"
                    }
                    else {
                        Write-Log "COPY_UPDATE: '$($sourceFile.FullName)' -> '$destFullPath'" "ACTION"
                    }
                    $updatedFilesCount++
                }
            }
        }
    }

    if ($EnableDeletion) {
        foreach ($key in $destHash.Keys) {
            if (-not $sourceHash.ContainsKey($key)) {
                $destFullPath = Join-Path -Path $normalizedToPath -ChildPath $key
                Write-Host "  Удаляем файл: $key" -ForegroundColor Red
                if ($PSCmdlet.ShouldProcess($destFullPath, "Удаление файла")) {
                    Remove-Item -LiteralPath $destFullPath -Force -ErrorAction SilentlyContinue
                    if ($PairNumber) {
                        Write-Log "DELETE_FILE_PAIR${PairNumber}: '$destFullPath'" "ACTION"
                    }
                    else {
                        Write-Log "DELETE_FILE: '$destFullPath'" "ACTION"
                    }
                    $deletedFilesCount++
                }
            }
        }

        $destDirs = Get-ChildItem -LiteralPath $normalizedToPath -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            -not (Test-IsExcludedPath -FullPath $_.FullName -RootPath $normalizedToPath -ExcludeDirectories $ExcludeDirectories)
        }

        foreach ($dir in $destDirs) {
            $relativePath = $dir.FullName.Substring($normalizedToPath.Length).TrimStart('\', '/')
            $sourceDirPath = Join-Path -Path $normalizedFromPath -ChildPath $relativePath

            if (-not (Test-Path -LiteralPath $sourceDirPath)) {
                $items = Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -eq $items) {
                    Write-Host "  Удаляем пустую директорию: $relativePath" -ForegroundColor Magenta
                    if ($PSCmdlet.ShouldProcess($dir.FullName, "Удаление пустой директории")) {
                        Remove-Item -LiteralPath $dir.FullName -Force -Recurse -ErrorAction SilentlyContinue
                        if ($PairNumber) {
                            Write-Log "DELETE_DIR_PAIR${PairNumber}: '$($dir.FullName)'" "ACTION"
                        }
                        else {
                            Write-Log "DELETE_DIR: '$($dir.FullName)'" "ACTION"
                        }
                    }
                }
            }
        }
    }

    if ($PairNumber) {
        Write-Log "END_SYNC_PAIR${PairNumber}: Mode=$Mode From='$normalizedFromPath' To='$normalizedToPath' New=$newFilesCount Updated=$updatedFilesCount Deleted=$deletedFilesCount" "INFO"
    }
    else {
        Write-Log "END_SYNC: Mode=$Mode From='$normalizedFromPath' To='$normalizedToPath' New=$newFilesCount Updated=$updatedFilesCount Deleted=$deletedFilesCount" "INFO"
    }
    Write-Host "  Сводка${pairInfo}: Новых: $newFilesCount, Обновлено: $updatedFilesCount, Удалено: $deletedFilesCount" -ForegroundColor Gray
}

# ---- Основной код ----

try {
    Initialize-Logging

    Write-Log "SCRIPT_START: Direction=$SyncDirection CompareMode=$CompareMode SettingsPath='$SettingsPath' PairsCount=$($script:FolderPairs.Count)" "INFO"
    Write-Host "Начинаем синхронизацию $($script:FolderPairs.Count) пар папок..." -ForegroundColor Cyan

    foreach ($pair in $script:FolderPairs) {
        $sourcePath = $pair.Source
        $destinationPath = $pair.Destination
        $pairNumber = $pair.Number

        if ($pairNumber) {
            Write-Host "`nОбработка пары (пара $pairNumber):" -ForegroundColor Yellow
        }
        else {
            Write-Host "`nОбработка пары:" -ForegroundColor Yellow
        }
        Write-Host "  Источник: $sourcePath" -ForegroundColor White
        Write-Host "  Назначение: $destinationPath" -ForegroundColor White

        if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
            Write-Host "  Предупреждение: Исходная папка не существует: $sourcePath" -ForegroundColor Red
            if ($pairNumber) {
                Write-Log  "WARN_PAIR${pairNumber}: Исходная папка не существует: '$sourcePath'" "WARN"
            }
            else {
                Write-Log  "WARN: Исходная папка не существует: '$sourcePath'" "WARN"
            }
            continue
        }

        if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
            Write-Host "  Папка назначения не существует, создаём: $destinationPath" -ForegroundColor Yellow
            if ($PSCmdlet.ShouldProcess($destinationPath, "Создание папки назначения")) {
                New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
                if ($pairNumber) {
                    Write-Log "CREATE_DIR_PAIR${pairNumber}: '$destinationPath'" "ACTION"
                }
                else {
                    Write-Log "CREATE_DIR: '$destinationPath'" "ACTION"
                }
            }
        }

        switch ($SyncDirection) {
            "LeftToRight" {
                Sync-Files -FromPath $sourcePath -ToPath $destinationPath -Mode "LeftToRight" `
                    -ExcludeDirectories $ExcludeDirectories -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns `
                    -CompareMode $CompareMode -EnableDeletion:$true -PairNumber $pairNumber
            }
            "RightToLeft" {
                Sync-Files -FromPath $destinationPath -ToPath $sourcePath -Mode "RightToLeft" `
                    -ExcludeDirectories $ExcludeDirectories -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns `
                    -CompareMode $CompareMode -EnableDeletion:$true -PairNumber $pairNumber
            }
            "Both" {
                switch ($TwoWayDeletionSide) {
                    "Source" {
                        Sync-Files -FromPath $sourcePath -ToPath $destinationPath -Mode "Both" `
                            -ExcludeDirectories $ExcludeDirectories -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns `
                            -CompareMode $CompareMode -EnableDeletion:$true -PairNumber $pairNumber

                        Sync-Files -FromPath $destinationPath -ToPath $sourcePath -Mode "Both" `
                            -ExcludeDirectories $ExcludeDirectories -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns `
                            -CompareMode $CompareMode -EnableDeletion:$false -PairNumber $pairNumber
                    }
                    "Destination" {
                        Sync-Files -FromPath $sourcePath -ToPath $destinationPath -Mode "Both" `
                            -ExcludeDirectories $ExcludeDirectories -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns `
                            -CompareMode $CompareMode -EnableDeletion:$false -PairNumber $pairNumber

                        Sync-Files -FromPath $destinationPath -ToPath $sourcePath -Mode "Both" `
                            -ExcludeDirectories $ExcludeDirectories -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns `
                            -CompareMode $CompareMode -EnableDeletion:$true -PairNumber $pairNumber
                    }
                    "None" {
                        Sync-Files -FromPath $sourcePath -ToPath $destinationPath -Mode "Both" `
                            -ExcludeDirectories $ExcludeDirectories -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns `
                            -CompareMode $CompareMode -EnableDeletion:$false -PairNumber $pairNumber

                        Sync-Files -FromPath $destinationPath -ToPath $sourcePath -Mode "Both" `
                            -ExcludeDirectories $ExcludeDirectories -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns `
                            -CompareMode $CompareMode -EnableDeletion:$false -PairNumber $pairNumber
                    }
                }
            }
        }
    }

    Write-Log "SCRIPT_END: Direction=$SyncDirection PairsCount=$($script:FolderPairs.Count)" "INFO"
    Write-Host "`nСинхронизация завершена. Обработано пар папок: $($script:FolderPairs.Count)" -ForegroundColor Green
}
catch {
    Write-Host "`nОшибка: $($_.Exception.Message)" -ForegroundColor Red
    Write-Log  ("ERROR: {0}" -f $_.Exception.Message) "ERROR"
    exit 1
}