param([string]$InputDoc, [string]$OutputPdf)
$ErrorActionPreference = 'Stop'
$app = $null
$doc = $null
try {
    $app = New-Object -ComObject Word.Application
    $app.Visible = $false
    $app.DisplayAlerts = 0
    $doc = $app.Documents.Open($InputDoc, $false, $true, $false)
    $doc.Repaginate()
    $doc.ExportAsFixedFormat($OutputPdf, 17)
    Write-Output ('Pages: ' + $doc.ComputeStatistics(2))
} finally {
    if ($null -ne $doc) { $doc.Close(0); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($doc) }
    if ($null -ne $app) { $app.Quit(); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($app) }
}
