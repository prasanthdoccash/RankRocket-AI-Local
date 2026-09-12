$ErrorActionPreference = 'Stop'
flutter build apk --release
$apk = 'build\app\outputs\flutter-apk\app-release.apk'
$namedApk = 'build\app\outputs\flutter-apk\RankRocket AI.apk'
if (-not (Test-Path -LiteralPath $apk)) {
  throw "Flutter did not produce $apk"
}
Move-Item -LiteralPath $apk -Destination $namedApk -Force
Write-Output "Built $namedApk"
