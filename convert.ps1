# 哔哩哔哩 m4s 转 mp4 脚本
# 自动下载 ffmpeg 并合并 audio.m4s + video.m4s

$ErrorActionPreference = "Stop"

$videoDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$audioFile = Join-Path $videoDir "120\audio.m4s"
$videoFile = Join-Path $videoDir "120\video.m4s"
$entryFile = Join-Path $videoDir "entry.json"

# 读取标题
$title = "output"
if (Test-Path $entryFile) {
    $entry = Get-Content $entryFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($entry.title) {
        $title = $entry.title
    }
}
# 清理非法文件名字符
$title = $title -replace '[\\/:*?"<>|]', '_'
$outputFile = Join-Path $videoDir "$title.mp4"

# 检查输入文件
if (-not (Test-Path $audioFile)) {
    Write-Error "找不到 audio.m4s: $audioFile"
    exit 1
}
if (-not (Test-Path $videoFile)) {
    Write-Error "找不到 video.m4s: $videoFile"
    exit 1
}

Write-Host "标题: $title"
Write-Host "输出: $outputFile"

# 查找或下载 ffmpeg
$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
if (-not $ffmpeg) {
    $localFfmpeg = Join-Path $videoDir "ffmpeg.exe"
    if (Test-Path $localFfmpeg) {
        $ffmpeg = $localFfmpeg
    } else {
        Write-Host "ffmpeg 未找到，正在下载..." -ForegroundColor Yellow
        $zipUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
        $zipPath = Join-Path $videoDir "ffmpeg.zip"
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
        } catch {
            Write-Error "下载 ffmpeg 失败，请手动安装后重试: https://www.gyan.dev/ffmpeg/builds/"
            exit 1
        }
        Write-Host "解压 ffmpeg..."
        Expand-Archive -Path $zipPath -DestinationPath $videoDir -Force
        $extracted = Get-ChildItem -Path $videoDir -Filter "ffmpeg.exe" -Recurse | Select-Object -First 1
        if (-not $extracted) {
            Write-Error "解压后找不到 ffmpeg.exe"
            exit 1
        }
        Copy-Item $extracted.FullName $localFfmpeg -Force
        Remove-Item $zipPath -Force
        # 清理解压出来的目录
        Get-ChildItem -Path $videoDir -Directory | Where-Object { $_.Name -like "ffmpeg-*" } | Remove-Item -Recurse -Force
        $ffmpeg = $localFfmpeg
        Write-Host "ffmpeg 下载完成" -ForegroundColor Green
    }
} else {
    $ffmpeg = $ffmpeg.Source
}

Write-Host "使用 ffmpeg: $ffmpeg"
Write-Host "开始合并..."

# 合并 m4s 为 mp4（-c copy 不重新编码，速度快且无损）
& $ffmpeg -i $videoFile -i $audioFile -c copy -y $outputFile

if ($LASTEXITCODE -eq 0) {
    Write-Host "转换成功: $outputFile" -ForegroundColor Green
} else {
    Write-Error "转换失败"
    exit 1
}
