$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutputDir = Join-Path $Root "Results\presentation_wind_forecast_sequence"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$WindOnPath = Join-Path $Root "data\windon_data_2025_ned.csv"
$WindOffPath = Join-Path $Root "data\windoff_data_2025_ned.csv"
$ErrorPath = Join-Path $Root "Results\thesis_runs\_shared_inputs\wind_forecast_error_shared_final_20260502.csv"

$ConversionFactor = 0.00095
$WindCapacity = 12000.0
$XMin = 0.0
$XMax = 48.0
$YMin = 600.0
$YMax = 12500.0

function Get-WindSeries($path) {
    $rows = Import-Csv -Path $path
    $series = New-Object System.Collections.Generic.List[double]
    foreach ($row in $rows) {
        if ($row.'validfrom (UTC)' -ge "2025-01-01 00:00:00") {
            $series.Add([double]$row.'volume (kWh)' * $ConversionFactor)
        }
    }
    return $series
}

$WindOn = Get-WindSeries $WindOnPath
$WindOff = Get-WindSeries $WindOffPath
$ActualWind = @{}
$n = [Math]::Min($WindOn.Count, $WindOff.Count)
for ($i = 0; $i -lt $n; $i++) {
    $ActualWind[$i + 1] = $WindOn[$i] + $WindOff[$i]
}

$ForecastErrors = @{}
Import-Csv -Path $ErrorPath | ForEach-Object {
    $ForecastErrors["$($_.window_start_hour),$($_.abs_hour)"] = [double]$_.forecast_error
}

function Get-ForecastWind($startHour, $absHour) {
    $actual = $ActualWind[$absHour]
    if ($absHour -eq $startHour) {
        return $actual
    }

    $key = "$startHour,$absHour"
    $err = if ($ForecastErrors.ContainsKey($key)) { $ForecastErrors[$key] } else { 0.0 }
    $af = $actual / $WindCapacity
    $newAf = [Math]::Max(0.0, [Math]::Min(1.0, $af * (1.0 + $err)))
    return $WindCapacity * $newAf
}

function Draw-CenteredText($graphics, $text, $font, $brush, $x, $y) {
    $size = $graphics.MeasureString($text, $font)
    $graphics.DrawString($text, $font, $brush, [single]($x - $size.Width / 2), [single]($y - $size.Height / 2))
}

function Draw-RotatedCenteredText($graphics, $text, $font, $brush, $x, $y) {
    $state = $graphics.Save()
    $graphics.TranslateTransform([single]$x, [single]$y)
    $graphics.RotateTransform(-90)
    Draw-CenteredText $graphics $text $font $brush 0 0
    $graphics.Restore($state)
}

function Save-WindPlot($maxClearing, $outputName) {
    $width = 1400
    $height = 820
    $left = 165
    $right = 305
    $top = 95
    $bottom = 105
    $plotW = $width - $left - $right
    $plotH = $height - $top - $bottom

    $bmp = New-Object System.Drawing.Bitmap $width, $height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $g.Clear([System.Drawing.Color]::White)

    $black = [System.Drawing.Brushes]::Black
    $gridPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(45, 190, 190, 190)), 1
    $axisPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 80, 80, 80)), 2
    $titleFont = New-Object System.Drawing.Font "Arial", 26
    $labelFont = New-Object System.Drawing.Font "Arial", 22
    $tickFont = New-Object System.Drawing.Font "Arial", 16
    $legendFont = New-Object System.Drawing.Font "Arial", 18

    function XMap([double]$x) { return $left + (($x - $XMin) / ($XMax - $XMin)) * $plotW }
    function YMap([double]$y) { return $top + (($YMax - $y) / ($YMax - $YMin)) * $plotH }

    foreach ($xt in @(0, 10, 20, 30, 40)) {
        $xp = XMap $xt
        $g.DrawLine($gridPen, [single]$xp, [single]$top, [single]$xp, [single]($top + $plotH))
        $g.DrawLine($axisPen, [single]$xp, [single]($top + $plotH - 8), [single]$xp, [single]($top + $plotH + 2))
        Draw-CenteredText $g ([string]$xt) $tickFont $black $xp ($top + $plotH + 30)
    }

    foreach ($yt in @(2500, 5000, 7500, 10000)) {
        $yp = YMap $yt
        $g.DrawLine($gridPen, [single]$left, [single]$yp, [single]($left + $plotW), [single]$yp)
        $g.DrawLine($axisPen, [single]($left - 2), [single]$yp, [single]($left + 8), [single]$yp)
        $size = $g.MeasureString([string]$yt, $tickFont)
        $g.DrawString([string]$yt, $tickFont, $black, [single]($left - $size.Width - 22), [single]($yp - $size.Height / 2))
    }

    $g.DrawLine($axisPen, [single]$left, [single]$top, [single]$left, [single]($top + $plotH))
    $g.DrawLine($axisPen, [single]$left, [single]($top + $plotH), [single]($left + $plotW), [single]($top + $plotH))

    Draw-CenteredText $g "Wind Generation Forecasts in Consecutive Clearings" $titleFont $black ($width / 2) 38
    Draw-CenteredText $g "Global Hour" $labelFont $black ($left + $plotW / 2) ($height - 38)
    Draw-RotatedCenteredText $g "Wind Generation (MW)" $labelFont $black 47 ($top + $plotH / 2)

    $baseColors = @(
        [System.Drawing.Color]::FromArgb(31, 119, 180),
        [System.Drawing.Color]::FromArgb(160, 160, 160),
        [System.Drawing.Color]::FromArgb(255, 127, 14),
        [System.Drawing.Color]::FromArgb(255, 190, 90),
        [System.Drawing.Color]::FromArgb(148, 173, 54),
        [System.Drawing.Color]::FromArgb(214, 112, 158),
        [System.Drawing.Color]::FromArgb(138, 150, 64),
        [System.Drawing.Color]::FromArgb(203, 99, 150)
    )

    for ($clearing = 1; $clearing -le $maxClearing; $clearing++) {
        $color = $baseColors[($clearing - 1) % $baseColors.Count]
        $lineColor = [System.Drawing.Color]::FromArgb(150, $color.R, $color.G, $color.B)
        $pen = New-Object System.Drawing.Pen $lineColor, 2
        $prevX = $null
        $prevY = $null
        for ($absHour = $clearing; $absHour -le 48; $absHour++) {
            $value = Get-ForecastWind $clearing $absHour
            $x = XMap $absHour
            $y = YMap $value
            if ($null -ne $prevX) {
                $g.DrawLine($pen, [single]$prevX, [single]$prevY, [single]$x, [single]$y)
            }
            $prevX = $x
            $prevY = $y
        }
        $pen.Dispose()
    }

    $legendX = 1090
    $legendY = 105
    $legendW = 245
    $legendClearings = if ($maxClearing -eq 20) { @(1, 2, 3, 4, 5, 10, 20) } else { 1..$maxClearing }
    $legendStep = 31
    $legendH = 35 + $legendStep * $legendClearings.Count
    $legendPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 70, 70, 70)), 2
    $g.FillRectangle([System.Drawing.Brushes]::White, $legendX, $legendY, $legendW, $legendH)
    $g.DrawRectangle($legendPen, $legendX, $legendY, $legendW, $legendH)
    for ($legendIdx = 0; $legendIdx -lt $legendClearings.Count; $legendIdx++) {
        $clearing = $legendClearings[$legendIdx]
        $rowY = $legendY + 28 + $legendStep * $legendIdx
        $color = $baseColors[($clearing - 1) % $baseColors.Count]
        $lineColor = [System.Drawing.Color]::FromArgb(170, $color.R, $color.G, $color.B)
        $pen = New-Object System.Drawing.Pen $lineColor, 3
        $g.DrawLine($pen, [single]($legendX + 18), [single]$rowY, [single]($legendX + 94), [single]$rowY)
        $g.DrawString("Clearing $clearing", $legendFont, $black, [single]($legendX + 110), [single]($rowY - 14))
        $pen.Dispose()
    }

    $path = Join-Path $OutputDir $outputName
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
}

1..4 | ForEach-Object { Save-WindPlot $_ "wind_forecasts_clearings_1_to_$_.png" }
Save-WindPlot 20 "wind_forecasts_clearings_1_to_20.png"
Write-Host "Wrote wind forecast sequence figures to: $OutputDir"
