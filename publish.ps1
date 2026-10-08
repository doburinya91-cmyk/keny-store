# Публикация игры в Keny Store: перетащи APK на этот скрипт — он всё сделает сам.
# Примеры:
#   .\publish.ps1 -Apk "C:\Games\MyGame.apk"
#   .\publish.ps1 -Apk "C:\Games\MyGame.apk" -Icon "C:\Games\icon.png" -Description "Крутая игра"
#   .\publish.ps1 -Apk "C:\Games\MyGame.apk" -Icon "i.png" -Tagline "Экшен в неоновом Майами" -Screenshots "s1.jpg,s2.jpg"
#   .\publish.ps1 -Apk "C:\Games\MyGame.apk" -DryRun   # проверка без загрузки
param(
    [Parameter(Mandatory = $true)][string]$Apk,
    [string]$Icon = "",
    [string]$Name = "",
    [string]$Tagline = "",
    [string]$Description = "",
    [string]$Screenshots = "",
    [string]$Video = "",
    [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$OutputEncoding = [Text.Encoding]::UTF8

$repoRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$apkPath   = (Resolve-Path $Apk).Path
$apkFile   = [IO.Path]::GetFileName($apkPath)

# --- gh CLI: winget кладёт его в Program Files, в PATH он есть не везде ---
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) {
    $candidate = "C:\Program Files\GitHub CLI\gh.exe"
    if (Test-Path $candidate) { $gh = $candidate } else { throw "Не нашёл gh CLI. Установи: winget install --id GitHub.cli" }
}

# --- владелец и имя репозитория из git remote ---
$remote = git -C $repoRoot config --get remote.origin.url
if ($remote -match "github\.com[:/](?<o>[^/]+)/(?<r>[^/]+?)(\.git)?$") {
    $owner = $Matches.o
    $repo  = $Matches.r
} else {
    throw "Не понял remote.origin.url: $remote"
}

# --- читаем имя пакета, версию и название прямо из APK через aapt из SDK ---
$sdkRoots = @(
    "$env:LOCALAPPDATA\Android\Sdk",
    "$env:USERPROFILE\sdk",
    "$env:ANDROID_HOME",
    "C:\Program Files\Unity\Hub\Editor\2022.3.62f3\Editor\Data\PlaybackEngines\AndroidPlayer\SDK"
) | Where-Object { $_ }

$aaptFound = foreach ($root in $sdkRoots) {
    Get-ChildItem (Join-Path $root "build-tools") -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName "aapt.exe" } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
}
$aapt = $aaptFound | Select-Object -First 1

if (-not $aapt) { throw "aapt не найден ни в одном из SDK: $($sdkRoots -join ', ')" }

Write-Host "Читаю метаданные APK через aapt..." -ForegroundColor Cyan
$badging = & $aapt dump badging $apkPath
if ($LASTEXITCODE -ne 0) { throw "aapt не смог прочитать APK" }

$pkgLine = ($badging | Select-String "^package:" | Select-Object -First 1).Line
if ($pkgLine -match "name='(?<n>[^']+)'")                        { $id = $Matches.n }
if ($pkgLine -match "versionCode='(?<v>[^']+)'")                 { $versionCode = $Matches.v }
if ($pkgLine -match "versionName='(?<v>[^']*)'")                 { $versionName = $Matches.v }
$lblLine = ($badging | Select-String "^application-label:" | Select-Object -First 1).Line
if ($lblLine -match "application-label:'(?<l>[^']*)'")           { $label = $Matches.l.Replace("\'", "'") }

if (-not $id) { throw "Не нашёл имя пакета в APK" }
if ($Name) { $label = $Name }
if (-not $label) { $label = $id }
if (-not $versionName) { $versionName = "?" }
if (-not $versionCode) { $versionCode = "1" }

$sizeBytes = [math]::Round((Get-Item $apkPath).Length / 1MB, 1)
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
    $iconExt = [IO.Path]::GetExtension($iconPath)
    Copy-Item $iconPath (Join-Path $iconsDir "$id$iconExt") -Force
    $iconUrl = "$pagesBase/icons/$id$iconExt"
    Write-Host "Иконка: $iconUrl" -ForegroundColor Cyan
}

# --- скриншоты (необязательно, через запятую) ---
$shotUrls = @()
if ($Screenshots) {
    $shotsDir = Join-Path $repoRoot "screenshots\$id"
    if (-not (Test-Path $shotsDir)) { New-Item -ItemType Directory -Path $shotsDir -Force | Out-Null }
    else { Get-ChildItem $shotsDir | Remove-Item -Force }
    $n = 0
    foreach ($s in ($Screenshots -split "," | Where-Object { $_.Trim() })) {
        $n++
        $src = (Resolve-Path $s.Trim()).Path
        $ext = [IO.Path]::GetExtension($src)
        Copy-Item $src (Join-Path $shotsDir "$n$ext") -Force
        $shotUrls += "$pagesBase/screenshots/$id/$n$ext"
    }
    Write-Host "Скриншотов: $($shotUrls.Count)" -ForegroundColor Cyan
}

# --- промо-видео (необязательно): лежит в репозитории, играется прямо на витрине ---
$videoUrl = ""
if ($Video) {
    $videoPath = (Resolve-Path $Video).Path
    $mb = [math]::Round((Get-Item $videoPath).Length / 1MB, 1)
    if ($mb -gt 15) { Write-Host "Видео $mb МБ — витрина с ним грузится медленно. Сожми через ffmpeg." -ForegroundColor Yellow }
    $videosDir = Join-Path $repoRoot "videos"
    if (-not (Test-Path $videosDir)) { New-Item -ItemType Directory -Path $videosDir | Out-Null }
    $videoExt = [IO.Path]::GetExtension($videoPath)
    Copy-Item $videoPath (Join-Path $videosDir "$id$videoExt") -Force
    $videoUrl = "$pagesBase/videos/$id$videoExt"
    Write-Host "Видео: $videoUrl ($mb МБ)" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Игра:    $label ($id)" -ForegroundColor Green
Write-Host "Версия:  $versionName (code $versionCode)"
Write-Host "Размер:  $sizeBytes МБ"
Write-Host "APK:     $apkUrl"
Write-Host "Репозиторий: $owner/$repo"
Write-Host ""

if ($DryRun) {
    Write-Host "DryRun: ничего не загружаю и не пушу. Данные в каталоге не менял." -ForegroundColor Yellow
    exit 0
}

# --- загружаем APK в GitHub Release (тег = имя пакета) ---
Write-Host "Загружаю APK в GitHub Release '$tag'..." -ForegroundColor Cyan
& $gh release view $tag --repo "$owner/$repo" | Out-Null
if ($LASTEXITCODE -eq 0) {
    & $gh release upload $tag $apkPath --clobber --repo "$owner/$repo"
} else {
    & $gh release create $tag $apkPath --repo "$owner/$repo" -t $releaseNm -n "Версия $versionName"
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
    $entry.size        = $sizeBytes
    if ($Description) { $entry.description = $Description }
    if ($Tagline)     { $entry.tagline     = $Tagline }
    if ($iconUrl)     { $entry.icon        = $iconUrl }
    if ($shotUrls.Count) { $entry.screenshots = $shotUrls }
    if ($videoUrl) {
        # в старой записи поля video может не быть — заводим его
        if ($entry.PSObject.Properties['video']) { $entry.video = $videoUrl }
        else { $entry | Add-Member -NotePropertyName video -NotePropertyValue $videoUrl }
    }
    $entry.apk = $apkUrl
    Write-Host "Игра уже была в каталоге — обновил запись." -ForegroundColor Green
} else {
    $entry = [PSCustomObject]@{
        id          = $id
        name        = $label
        version     = $versionName
        versionCode = [int]$versionCode
        size        = $sizeBytes
        tagline     = $Tagline
        description = $Description
        icon        = $iconUrl
        screenshots = $shotUrls
        video       = $videoUrl
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
# Git Credential Manager иначе висит окном логина и не отдаёт управление gh-хелперу
$env:GCM_INTERACTIVE = "never"
$env:GIT_TERMINAL_PROMPT = "0"
$toAdd = @('catalog.json', 'icons', 'screenshots')
if (Test-Path (Join-Path $repoRoot 'videos')) { $toAdd += 'videos' }
git -C $repoRoot add @toAdd 2>$null
$dirty = git -C $repoRoot status --porcelain
if ($dirty) {
    git -C $repoRoot commit -m "$label v$versionName" | Out-Null
} else {
    Write-Host "В репозитории нечего коммитить." -ForegroundColor Yellow
}
git -C $repoRoot push
if ($LASTEXITCODE -ne 0) { throw "git push не удался" }

Write-Host ""
Write-Host "Готово! Через ~1 минуту игра появится на $pagesBase" -ForegroundColor Green
