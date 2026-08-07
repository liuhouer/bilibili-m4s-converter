# B站 danmaku.xml 转 ASS 弹幕字幕脚本
# 支持滚动弹幕、顶部固定、底部固定

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$xmlFile = Join-Path $scriptDir "danmaku.xml"
$entryFile = Join-Path $scriptDir "entry.json"

if (-not (Test-Path $xmlFile)) {
    Write-Error "找不到 danmaku.xml: $xmlFile"
    exit 1
}

# 读取标题
$title = "danmaku"
if (Test-Path $entryFile) {
    $entry = Get-Content $entryFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($entry.title) { $title = $entry.title }
}
$title = $title -replace '[\\/:*?"<>|]', '_'
$outputFile = Join-Path $scriptDir "$title.ass"

Write-Host "正在解析 $xmlFile ..."
[xml]$xml = Get-Content $xmlFile -Raw -Encoding UTF8
$danmakuList = $xml.i.d

# 视频分辨率 (从 entry.json 或默认 1920x1080)
$playResX = 1920
$playResY = 1080
if (Test-Path $entryFile) {
    $entry = Get-Content $entryFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($entry.ep.width -and $entry.ep.height) {
        $playResX = $entry.ep.width
        $playResY = $entry.ep.height
    }
}

# ASS 基础字号（B站默认25对应1080p，按比例缩放）
$baseFontSize = [int](25 * ($playResX / 1920))
if ($baseFontSize -lt 18) { $baseFontSize = 18 }
if ($baseFontSize -gt 72) { $baseFontSize = 72 }

# 轨道配置
$scrollTracks = 20          # 滚动弹幕轨道数
$topTracks = 8              # 顶部固定轨道数
$bottomTracks = 5           # 底部固定轨道数
$scrollDuration = 8.0       # 滚动弹幕持续时间(秒)
$fixedDuration = 5.0        # 固定弹幕持续时间(秒)

# 计算轨道Y坐标
$trackMargin = 10
$trackHeight = $baseFontSize + 8
$scrollAreaTop = [int]($playResY * 0.08)
$scrollAreaBottom = [int]($playResY * 0.85)
$scrollTrackStep = [int](($scrollAreaBottom - $scrollAreaTop) / [Math]::Max(1, $scrollTracks - 1))
$scrollYCoords = @()
for ($i = 0; $i -lt $scrollTracks; $i++) {
    $scrollYCoords += $scrollAreaTop + $i * $scrollTrackStep
}

$topYCoords = @()
for ($i = 0; $i -lt $topTracks; $i++) {
    $topYCoords += 30 + $i * ($baseFontSize + 6)
}

$bottomYCoords = @()
for ($i = 0; $i -lt $bottomTracks; $i++) {
    $bottomYCoords += $playResY - 30 - $i * ($baseFontSize + 6)
}

# 轨道状态：记录每条轨道最后一条弹幕的结束时间
$scrollTrackEnd = New-Object double[] $scrollTracks
for ($i = 0; $i -lt $scrollTracks; $i++) { $scrollTrackEnd[$i] = -999 }
$topTrackEnd = New-Object double[] $topTracks
for ($i = 0; $i -lt $topTracks; $i++) { $topTrackEnd[$i] = -999 }
$bottomTrackEnd = New-Object double[] $bottomTracks
for ($i = 0; $i -lt $bottomTracks; $i++) { $bottomTrackEnd[$i] = -999 }

# 辅助函数：格式化 ASS 时间 HH:MM:SS.cc
function Format-AssTime($seconds) {
    $h = [int][Math]::Floor($seconds / 3600)
    $m = [int][Math]::Floor(($seconds % 3600) / 60)
    $s = [int][Math]::Floor($seconds % 60)
    $cs = [int][Math]::Floor(($seconds - [Math]::Floor($seconds)) * 100)
    return "{0:D1}:{1:D2}:{2:D2}.{3:D2}" -f $h, $m, $s, $cs
}

# 辅助函数：RGB十进制 转 BGR十六进制 (&H00BBGGRR&)
function Convert-ToAssColor($decimalColor) {
    $r = ($decimalColor -band 0xFF)
    $g = (($decimalColor -shr 8) -band 0xFF)
    $b = (($decimalColor -shr 16) -band 0xFF)
    return "&H00{0:X2}{1:X2}{2:X2}&" -f $b, $g, $r
}

# 辅助函数：估算文本宽度（中文字符=1.0, 其他=0.55）
function Get-TextWidth($text, $fontSize) {
    $width = 0
    foreach ($char in $text.ToCharArray()) {
        if ([int]$char -ge 0x4E00 -and [int]$char -le 0x9FFF) {
            $width += 1.0
        } else {
            $width += 0.55
        }
    }
    return [int]($width * $fontSize)
}

# 辅助函数：分配轨道
function Assign-Track($trackEnds, $startTime, $duration, $yCoords) {
    $endTime = $startTime + $duration
    for ($i = 0; $i -lt $trackEnds.Count; $i++) {
        if ($trackEnds[$i] -le $startTime) {
            $trackEnds[$i] = $endTime
            return $yCoords[$i]
        }
    }
    # 全部冲突，找最早结束的轨道
    $minIdx = 0
    $minVal = $trackEnds[0]
    for ($i = 1; $i -lt $trackEnds.Count; $i++) {
        if ($trackEnds[$i] -lt $minVal) {
            $minVal = $trackEnds[$i]
            $minIdx = $i
        }
    }
    $trackEnds[$minIdx] = $endTime
    return $yCoords[$minIdx]
}

# 解析弹幕
$events = @()
$processed = 0
$total = $danmakuList.Count

foreach ($d in $danmakuList) {
    $processed++
    if ($processed % 1000 -eq 0) {
        Write-Host "处理中... $processed / $total"
    }

    $p = $d.p -split ","
    if ($p.Count -lt 4) { continue }

    $startSec = [double]$p[0]
    $mode = [int]$p[1]
    $biliSize = [int]$p[2]
    $color = [int]$p[3]
    $text = $d.'#text'
    if (-not $text) { $text = "" }
    $text = $text.Trim()
    if ($text.Length -eq 0) { continue }

    # 过滤不可见字符（保留常用字符）
    $text = $text -replace '[\x00-\x08\x0B-\x0C\x0E-\x1F]', ''
    if ($text.Length -eq 0) { continue }

    # 字体大小按比例缩放
    $fontSize = [int]($biliSize * ($playResX / 1920))
    if ($fontSize -lt 12) { $fontSize = 12 }

    $assColor = Convert-ToAssColor $color
    $textWidth = Get-TextWidth $text $fontSize

    $startTime = Format-AssTime $startSec

    switch ($mode) {
        { $_ -in 1,2,3,6 } {
            # 滚动弹幕
            $endSec = $startSec + $scrollDuration
            $endTime = Format-AssTime $endSec
            $y = Assign-Track $scrollTrackEnd $startSec $scrollDuration $scrollYCoords
            $x1 = $playResX + $textWidth + 50
            $x2 = -$textWidth - 50
            $assText = "{\move($x1,$y,$x2,$y)\c$assColor\fs$fontSize}$text"
            $events += "Dialogue: 0,$startTime,$endTime,Default,,0,0,0,,$assText"
        }
        5 {
            # 顶部固定
            $endSec = $startSec + $fixedDuration
            $endTime = Format-AssTime $endSec
            $y = Assign-Track $topTrackEnd $startSec $fixedDuration $topYCoords
            $x = [int](($playResX - $textWidth) / 2)
            $assText = "{\an8\c$assColor\fs$fontSize}$text"
            $events += "Dialogue: 0,$startTime,$endTime,Default,,0,0,0,,$assText"
        }
        4 {
            # 底部固定
            $endSec = $startSec + $fixedDuration
            $endTime = Format-AssTime $endSec
            $y = Assign-Track $bottomTrackEnd $startSec $fixedDuration $bottomYCoords
            $assText = "{\an2\c$assColor\fs$fontSize}$text"
            $events += "Dialogue: 0,$startTime,$endTime,Default,,0,0,0,,$assText"
        }
        default {
            # 其他模式按滚动处理
            $endSec = $startSec + $scrollDuration
            $endTime = Format-AssTime $endSec
            $y = Assign-Track $scrollTrackEnd $startSec $scrollDuration $scrollYCoords
            $x1 = $playResX + $textWidth + 50
            $x2 = -$textWidth - 50
            $assText = "{\move($x1,$y,$x2,$y)\c$assColor\fs$fontSize}$text"
            $events += "Dialogue: 0,$startTime,$endTime,Default,,0,0,0,,$assText"
        }
    }
}

# 生成 ASS 文件
$assHeader = @"
[Script Info]
Title: $title
ScriptType: v4.00+
PlayResX: $playResX
PlayResY: $playResY

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Microsoft YaHei,$baseFontSize,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1.5,0,2,20,20,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"@

$assContent = $assHeader + "`r`n" + ($events -join "`r`n")
[System.IO.File]::WriteAllText($outputFile, $assContent, [System.Text.UTF8Encoding]::new($false))

Write-Host "转换完成!" -ForegroundColor Green
Write-Host "输出文件: $outputFile"
Write-Host "总弹幕数: $($events.Count)"
Write-Host "视频分辨率: ${playResX}x${playResY}"
Write-Host ""
Write-Host "使用说明："
Write-Host "  - 用 VLC / PotPlayer / MPV 播放 MP4 时，将 .ass 文件拖入播放器即可加载弹幕"
Write-Host "  - 或把 .ass 文件改名与 .mp4 同名（如 功夫.ass + 功夫.mp4），部分播放器会自动加载"
