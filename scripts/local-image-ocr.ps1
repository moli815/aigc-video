param([Parameter(Mandatory=$true)][string]$ImagePath,[Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null=[Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
$null=[Windows.Graphics.Imaging.BitmapDecoder,Windows.Foundation,ContentType=WindowsRuntime]
$null=[Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
$null=[Windows.Globalization.Language,Windows.Globalization,ContentType=WindowsRuntime]
$taskMethod=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
function Await-Result($Operation,[Type]$ResultType) {
  $task=$taskMethod.MakeGenericMethod($ResultType).Invoke($null,@($Operation));$task.Wait();return $task.Result
}
$file=Await-Result ([Windows.Storage.StorageFile]::GetFileFromPathAsync((Resolve-Path -LiteralPath $ImagePath).Path)) ([Windows.Storage.StorageFile])
$stream=Await-Result ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
try {
  $decoder=Await-Result ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $engine=[Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new('zh-Hans-CN'))
  if($null -eq $engine){throw 'LOCAL_CHINESE_OCR_UNAVAILABLE'}
  $limit=[Windows.Media.Ocr.OcrEngine]::MaxImageDimension
  $scale=[Math]::Min(1.0,$limit/[Math]::Max($decoder.PixelWidth,$decoder.PixelHeight))
  $transform=[Windows.Graphics.Imaging.BitmapTransform]::new()
  $transform.ScaledWidth=[uint32][Math]::Max(1,[Math]::Floor($decoder.PixelWidth*$scale))
  $transform.ScaledHeight=[uint32][Math]::Max(1,[Math]::Floor($decoder.PixelHeight*$scale))
  $bitmap=Await-Result ($decoder.GetSoftwareBitmapAsync([Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,[Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied,$transform,[Windows.Graphics.Imaging.ExifOrientationMode]::RespectExifOrientation,[Windows.Graphics.Imaging.ColorManagementMode]::DoNotColorManage)) ([Windows.Graphics.Imaging.SoftwareBitmap])
  try {
    $result=Await-Result ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
    $out=@{engine='Windows.Media.Ocr';language='zh-Hans-CN';width=$decoder.PixelWidth;height=$decoder.PixelHeight;scale=$scale;text=$result.Text;lines=@($result.Lines | ForEach-Object { @{text=$_.Text;words=@($_.Words | ForEach-Object { @{text=$_.Text;x=$_.BoundingRect.X;y=$_.BoundingRect.Y;width=$_.BoundingRect.Width;height=$_.BoundingRect.Height} })} })}
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($out | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    Write-Output ('OCR completed: '+$out.lines.Count+' lines')
  } finally {$bitmap.Dispose()}
} finally {$stream.Dispose()}
