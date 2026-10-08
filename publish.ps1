# Публикация игры в Keny Store: перетащи APK на этот скрипт — он всё сделает сам.
# Примеры:
#   .\publish.ps1 -Apk "C:\Games\MyGame.apk"
#   .\publish.ps1 -Apk "C:\Games\MyGame.apk" -Icon "C:\Games\icon.png" -Description "Крутая игра"
#   .\publish.ps1 -Apk "C:\Games\MyGame.apk" -DryRun   # проверка без загрузки
param(
    [Parameter(Mandatory = $true)][string]$Apk,
    [string]$Icon = "",
    [string]$Name = "",
    [string]$Description = "",
    [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$OutputEncoding = [Text.Encoding]::UTF8

$repoRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$apkPath   = (Resolve-Path $Apk).Path
$apkFile   = [IO.Path]::GetFileName($apkPath)

# --- владелец и имя репозитория из git remote ---
$remote = git -C $repoRoot config --get remote.origin.url
if ($remote -match "github\.com[:/](?<o>[^/]+)/(?<r>[^/]+?)(\.git)?$") {
    $owner = $Matches.o
    $repo  = $Matches.r
} else {
    throw "Не понял remote.origin.url: $remote"
}

# --- читаем имя пакета, версию и название прямо из APK через aapt из SDK ---
$aapt = Get-ChildItem "$env:USERPROFILE\sdk\build-tools" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName "aapt.exe" } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1

if ($aapt) {
    Write-Host "Читаю метаданные APK через aapt..." -ForegroundColor Cyan
    $badging = & $aapt dump badging $apkPath
    if ($LASTEXITCODE -ne 0) { throw "aapt не смог прочитать APK" }

    $pkgLine = ($badging | Select-String "^package:" | Select-Object -First 1).Line
    if ($pkgLine -match "name='(?<n>[^']+)'")                          { $id = $Matches.n }
    if ($pkgLine -match "versionCode='(?<v>[^']+)'")                   { $versionCode = $Matches.v }
    if ($pkgLine -match "versionName='(?<v>[^']*)'")                   { $versionName = $Matches.v }
    $lblLine = ($badging | Select-String "^application-label:" | Select-Object -First 1).Line
    if ($lblLine -match "application-label:'(?<l>[^']*)'")             { $label = $Matches.l.Replace("\'", "'") }

    if (-not $id) { throw "Не нашёл имя пакета в APK" }
} else {
    throw "aapt не найден в $env:USERPROFILE\sdk\build-tools. Поставь Android SDK build-tools."
}

if ($Name) { $label = $Name }
if (-not $label) { $label = $id }
if (-not $versionName) { $versionName = "?" }

$tag        = $id
$releaseNm  = $label
$apkUrl     = "https://github.com/$owner/$repo/releases/download/$tag/$apkFile"
$pagesBase  = "https://$owner.github.io/$repo"
$catalogPath = Join-Path $repoRoot "catalog.json"

# --- иконка (необязательно) ---
$iconUrl = ""
if ($Icon) {
    $iconPath = (Resolve-Path $Icon).Path
    $iconsDir = Join-Path $repoRoot "icons"
    if (-not (Test-Path $iconsDir)) { New-Item -ItemType Directory -Path $iconsDir | Out-Null }
    Copy-Item $iconPath (Join-Path $iconsDir "$id.png") -Force
    $iconUrl = "$pagesBase/icons/$id.png"
    Write-Host "Иконка: $iconUrl" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Игра:    $label ($id)" -ForegroundColor Green
Write-Host "Версия:  $versionName (code $versionCode)"
Write-Host "APK:     $apkUrl"
Write-Host "Репозиторий: $owner/$repo"
Write-Host ""

if ($DryRun) {
    Write-Host "DryRun: ничего не загружаю и не пушу. Данные в каталоге не менял." -ForegroundColor Yellow
    exit 0
}

# --- загружаем APK в GitHub Release (тег = имя пакета) ---
Write-Host "Загружаю APK в GitHub Release '$tag'..." -ForegroundColor Cyan
gh release view $tag --repo "$owner/$repo" | Out-Null
if ($LASTEXITCODE -eq 0) {
    gh release upload $tag $apkPath --clobber --repo "$owner/$repo"
} else {
    gh release create $tag $apkPath --repo "$owner/$repo" -t $releaseNm -n "Версия $versionName"
}
if ($LASTEXITCODE -ne 0) { throw "Не удалось загрузить релиз" }

# --- обновляем catalog.json ---
Write-Host "Обновляю catalog.json..." -ForegroundColor Cyan
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$catalog = Get-Content $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
$games = @($catalog.games)

$entry = $games | Where-Object { $_.id -eq $id } | Select-Object -First 1
if ($entry) {
    $entry.name        = $label
    $entry.version     = $versionName
    $entry.versionCode = [int]$versionCode
    if ($Description) { $entry.description = $Description }
    if ($iconUrl)     { $entry.icon = $iconUrl }
    $entry.apk = $apkUrl
    Write-Host "Игра уже была в каталоге — обновил запись." -ForegroundColor Green
} else {
    $entry = [PSCustomObject]@{
        id          = $id
        name        = $label
        version     = $versionName
        versionCode = [int]$versionCode
        description = $Description
        icon        = $iconUrl
        apk         = $apkUrl
    }
    $games += $entry
    Write-Host "Новая игра добавлена в каталог." -ForegroundColor Green
}

$catalog.games   = $games
$catalog.updated = Get-Date -Format "yyyy-MM-dd"
[System.IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 6), $utf8NoBom)

# --- пушим: GitHub Pages сам пересоберёт витрину за ~1 минуту ---
Write-Host "Пушу на GitHub..." -ForegroundColor Cyan
git -C $repoRoot add catalog.json icons 2>$null
git -C $repoRoot commit -m "$label v$versionName" | Out-Null
git -C $repoRoot push
if ($LASTEXITCODE -ne 0) { throw "git push не удался" }

Write-Host ""
Write-Host "Готово! Через ~1 минуту игра появится на $pagesBase" -ForegroundColor Green
