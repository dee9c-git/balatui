# Generates balatui.ico (multi-size) from assets/thumbnail.png.
# Pure PowerShell + System.Drawing, no ImageMagick required.
# The banner is letterboxed (fit + centered) onto a square transparent canvas.
#
# Usage: ./generate-icon.ps1 [-Source <path>] [-Output <path>]

param(
    [string]$Source = (Join-Path $PSScriptRoot "..\..\assets\thumbnail.png"),
    [string]$Output = (Join-Path $PSScriptRoot "balatui.ico")
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $Source)) {
    throw "Source image not found: $Source"
}

$Sizes = @(16, 24, 32, 48, 64, 128, 256)
$CanvasPadding = 0.10 # pad 10% of canvas so the banner doesn't touch the edges

$src = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Source))
try {
    $srcRatio = $src.Width / $src.Height
    $frames = [System.Collections.Generic.List[byte[]]]::new()

    foreach ($size in $Sizes) {
        $bmp = [System.Drawing.Bitmap]::new($size, $size,
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

            $max = $size * (1 - 2 * $CanvasPadding)
            $w = [Math]::Floor($max)
            $h = [Math]::Floor($max / $srcRatio)
            if ($w -gt $h * $srcRatio) { $w = [Math]::Floor($h * $srcRatio) }
            if ($h -gt $w / $srcRatio) { $h = [Math]::Floor($w / $srcRatio) }

            $x = [Math]::Floor(($size - $w) / 2)
            $y = [Math]::Floor(($size - $h) / 2)
            $g.DrawImage($src, $x, $y, $w, $h)
        }
        finally {
            $g.Dispose()
        }

        $ms = [System.IO.MemoryStream]::new()
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $frames.Add($ms.ToArray())
        $ms.Dispose()
        $bmp.Dispose()
    }

    $outDir = Split-Path -Parent $Output
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    # ICO container: 6-byte header + 16-byte directory per image, then PNG payloads.
    $fs = [System.IO.File]::Create($Output)
    try {
        $bw = [System.IO.BinaryWriter]::new($fs)
        $bw.Write([uint16]0)                    # reserved
        $bw.Write([uint16]1)                    # type: icon
        $bw.Write([uint16]$frames.Count)        # image count

        $offset = 6 + 16 * $frames.Count
        for ($i = 0; $i -lt $frames.Count; $i++) {
            $size = $Sizes[$i]
            $data = $frames[$i]
            $bw.Write([byte]($size -band 0xFF)) # width (256 -> 0)
            $bw.Write([byte]($size -band 0xFF)) # height (256 -> 0)
            $bw.Write([byte]0)                  # palette size
            $bw.Write([byte]0)                  # reserved
            $bw.Write([uint16]1)                # color planes
            $bw.Write([uint16]32)               # bits per pixel
            $bw.Write([uint32]$data.Length)     # payload bytes
            $bw.Write([uint32]$offset)          # payload offset
            $offset += $data.Length
        }
        foreach ($data in $frames) { $bw.Write($data) }
        $bw.Flush()
    }
    finally {
        $fs.Dispose()
    }
}
finally {
    $src.Dispose()
}

$sizeKb = [Math]::Round((Get-Item -LiteralPath $Output).Length / 1KB, 1)
Write-Host "Generated $Output ($sizeKb KB, $($frames.Count) sizes)"