# Registers this unpacked application for the current user's Open With menu.
# Does not change the default application or protected UserChoice values.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$Executable = (Join-Path $PSScriptRoot 'aiplayer.exe'),
  [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$classes = 'HKCU:\Software\Classes'
$appKey = Join-Path $classes 'Applications\aiplayer.exe'
$progId = 'AIPlayer.Video'
$extensions = '.mp4', '.mkv', '.webm', '.avi', '.mov', '.m4v', '.ts', '.m2ts', '.flv', '.wmv'
if ($Remove) {
  if ($PSCmdlet.ShouldProcess('Current-user AIPlayer Open With entries', 'Remove')) {
    foreach ($extension in $extensions) {
      $key = Join-Path $classes "$extension\OpenWithProgids"
      if (Test-Path $key) { Remove-ItemProperty -Path $key -Name $progId -ErrorAction SilentlyContinue }
    }
    Remove-Item -Path $appKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $classes $progId) -Recurse -Force -ErrorAction SilentlyContinue
  }
  return
}
$resolved = (Resolve-Path -LiteralPath $Executable).ProviderPath
if ([IO.Path]::GetFileName($resolved) -ine 'aiplayer.exe') { throw 'Select the packaged aiplayer.exe.' }
if ($resolved.Contains('"')) { throw 'Executable path must not contain quotes.' }
if ($PSCmdlet.ShouldProcess($resolved, 'Register current-user Open With entries')) {
  $command = '"' + $resolved + '" "%1"'
  New-Item -Path $appKey -Force | Out-Null
  New-ItemProperty -Path $appKey -Name 'FriendlyAppName' -Value 'AIPlayer' -PropertyType String -Force | Out-Null
  foreach ($root in @($appKey, (Join-Path $classes $progId))) {
    New-Item -Path "$root\shell\open\command" -Force | Out-Null
    Set-Item -Path "$root\shell\open\command" -Value $command
    New-Item -Path "$root\DefaultIcon" -Force | Out-Null
    Set-Item -Path "$root\DefaultIcon" -Value ('"' + $resolved + '",0')
  }
  New-Item -Path "$appKey\SupportedTypes" -Force | Out-Null
  foreach ($extension in $extensions) {
    New-ItemProperty -Path "$appKey\SupportedTypes" -Name $extension -Value '' -PropertyType String -Force | Out-Null
    $key = Join-Path $classes "$extension\OpenWithProgids"
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name $progId -Value '' -PropertyType String -Force | Out-Null
  }
  Write-Host 'AIPlayer is available in Open With. Select a default player yourself in Windows Settings if desired.'
}
