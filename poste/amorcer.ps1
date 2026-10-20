# Amorce (ASCII seulement : lisible par Windows PowerShell 5.1 sans BOM) d'un poste Windows AEGIS, sur une machine neuve. Compatible Windows PowerShell 5.1 (celui livre avec Windows).
#   irm https://raw.githubusercontent.com/calahan-io/.github/main/poste/amorcer.ps1 | iex
# Variables facultatives : $env:AEGIS_RACINE (defaut : ~\AEGIS-CORP), $env:AEGIS_ARGS (options passees a "aegis.ps1 install").
# Installe Git, GitHub CLI et PowerShell 7 s'ils manquent (winget), clone calahan-io/.github (public), puis passe la main
# a poste/aegis.ps1 install. Relancer ce script est sans danger.
$ErrorActionPreference = 'Stop'
$racine = if ($env:AEGIS_RACINE) { $env:AEGIS_RACINE } else { Join-Path $HOME 'AEGIS-CORP' }
$entree = Join-Path $racine '.github'

function Rafraichir-Chemin {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

Write-Host "AEGIS - amorce du poste dans $racine" -ForegroundColor Cyan
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  throw "winget est absent : installez 'App Installer' depuis le Microsoft Store, puis relancez."
}
foreach ($p in @(@('git', 'Git.Git'), @('gh', 'GitHub.cli'), @('pwsh', 'Microsoft.PowerShell'))) {
  if (Get-Command $p[0] -ErrorAction SilentlyContinue) { Write-Host "  ok $($p[0])"; continue }
  Write-Host "  ... installation de $($p[1])"
  winget install --id $p[1] --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
  Rafraichir-Chemin
  if (-not (Get-Command $p[0] -ErrorAction SilentlyContinue)) { throw "$($p[0]) introuvable apres installation : ouvrez un nouveau terminal et relancez." }
}

if (Test-Path (Join-Path $entree '.git')) {
  Write-Host "  ... mise a jour de $entree"
  git -C $entree pull --ff-only --quiet
} else {
  if (-not (Test-Path $racine)) { New-Item -ItemType Directory -Path $racine | Out-Null }
  Write-Host "  ... clone de calahan-io/.github (LF)"
  git clone -c core.autocrlf=false -c core.eol=lf --quiet https://github.com/calahan-io/.github.git $entree
  if ($LASTEXITCODE -ne 0) { throw "clone de calahan-io/.github impossible" }
}

$options = if ($env:AEGIS_ARGS) { $env:AEGIS_ARGS -split '\s+' } else { @() }
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $entree 'poste\aegis.ps1') install --racine $racine @options
if ($LASTEXITCODE -ne 0) { Write-Host "Le poste n'est pas entierement pret : voir le bilan ci-dessus, puis relancer aegis.ps1 install." -ForegroundColor Yellow }
