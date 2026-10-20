#Requires -Version 7.2
<#
.SYNOPSIS
  aegis — installe, met à jour et diagnostique le poste de développement AEGIS (Windows).

.DESCRIPTION
  Réplique l'atelier AEGIS-CORP : outils (winget), sept clones calahan-io côte à côte (LF, comme la CI), espace de
  travail VS Code, atelier npm, chaîne Rust, extensions VS Code, skills de mimir. Tout est décrit dans manifeste.json.
  Idempotent : relancer « install » répare, il ne casse rien. Le pendant Linux / Bluefin est aegis.sh.

  aegis.ps1 <commande> [options]
    install    installe ou répare le poste
    update     met à jour le bootstrap, les clones sur main, la racine, l'atelier npm, VS Code (--outils : winget aussi)
    doctor     diagnostic, sans rien modifier (--json pour une sortie machine)
    guide      ouvre le kit de démarrage (readme.html servi sur 127.0.0.1:7480) ou le README de la racine
    aide       cette aide

  Options : --racine <dossier>  --simulation  --sans <étapes>  --seulement <étapes>  --non-interactif  --json  --outils
  Étapes   : outils, github, depots, racine, npm, rust, vscode, skills
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$Ici = $PSScriptRoot
$ArgsOrigine = @($args)
$Manifeste = Get-Content -Raw -LiteralPath (Join-Path $Ici 'manifeste.json') | ConvertFrom-Json -AsHashtable
$Org = $Manifeste.org
$Etapes = @('outils', 'github', 'depots', 'racine', 'npm', 'rust', 'vscode', 'skills')

# ------------------------------------------------------------------ options
$Commande = 'aide'
$O = @{ racine = $null; simulation = $false; sans = @(); seulement = @(); nonInteractif = $false; json = $false; outils = $false; relance = $false }
$reste = [Collections.Generic.Queue[string]]::new([string[]]$args)
if ($reste.Count -gt 0 -and -not $reste.Peek().StartsWith('-')) { $Commande = $reste.Dequeue() }
while ($reste.Count -gt 0) {
  $a = $reste.Dequeue()
  switch ($a) {
    '--racine'         { $O.racine = $reste.Dequeue() }
    '--simulation'     { $O.simulation = $true }
    '--sans'           { $O.sans = $reste.Dequeue() -split ',' }
    '--seulement'      { $O.seulement = $reste.Dequeue() -split ',' }
    '--non-interactif' { $O.nonInteractif = $true }
    '--json'           { $O.json = $true }
    '--outils'         { $O.outils = $true }
    '--relance'        { $O.relance = $true }
    { $_ -in '-h', '--help', '--aide' } { $Commande = 'aide' }
    default            { throw "Option inconnue : $a (aegis.ps1 aide)" }
  }
}
foreach ($e in @($O.sans + $O.seulement)) { if ($e -and $e -notin $Etapes) { throw "Étape inconnue : $e (attendu : $($Etapes -join ', '))" } }

function Get-RacineDefaut {
  if ($env:AEGIS_RACINE) { return $env:AEGIS_RACINE }
  $depot = Split-Path -Parent $Ici
  if ((Split-Path -Leaf $depot) -eq '.github') { return (Split-Path -Parent $depot) }
  return (Join-Path $HOME $Manifeste.racine_defaut)
}
$Racine = [IO.Path]::GetFullPath(($O.racine ?? (Get-RacineDefaut)))
$Etat = Join-Path $Racine '.aegis'

# ------------------------------------------------------------------ sortie
$script:Bilan = [Collections.Generic.List[object]]::new()
function Titre($t) { if (-not $O.json) { Write-Host "`n▶ $t" -ForegroundColor Cyan } }
function Note([string]$statut, [string]$groupe, [string]$nom, [string]$detail = '', [string]$conseil = '') {
  $script:Bilan.Add([pscustomobject]@{ statut = $statut; groupe = $groupe; nom = $nom; detail = $detail; conseil = $conseil })
  if ($O.json) { return }
  $s = @{ ok = @('✔', 'Green'); avert = @('!', 'Yellow'); erreur = @('✖', 'Red'); info = @('·', 'DarkGray') }[$statut]
  Write-Host ("  {0} {1,-28} {2}" -f $s[0], $nom, $detail) -ForegroundColor $s[1]
  if ($conseil) { Write-Host "      → $conseil" -ForegroundColor DarkGray }
}
function Dire($t) { if (-not $O.json) { Write-Host "  $t" } }

function Faire([string]$quoi, [scriptblock]$action) {
  if ($O.simulation) { Dire "(simulation) $quoi"; return }
  Dire "… $quoi"
  & $action
}
function Exec([string]$exe, [string[]]$arguments, [switch]$Tolerer) {
  & $exe @arguments | Out-Host
  if ($LASTEXITCODE -ne 0 -and -not $Tolerer) { throw "« $exe $($arguments -join ' ') » a échoué (code $LASTEXITCODE)" }
  return $LASTEXITCODE
}
function Silence([string]$exe, [string[]]$arguments) {
  $sortie = & $exe @arguments 2>&1 | Out-String
  return [pscustomobject]@{ code = $LASTEXITCODE; texte = $sortie.Trim() }
}
function Etape-Active([string]$e) {
  if ($O.seulement.Count -gt 0 -and $e -notin $O.seulement) { return $false }
  return $e -notin $O.sans
}
function Update-Chemin {
  $m = [Environment]::GetEnvironmentVariable('Path', 'Machine'); $u = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = (@($m, $u, $env:Path) -join ';' -split ';' | Where-Object { $_ } | Select-Object -Unique) -join ';'
}

# ------------------------------------------------------------------ outils
function Get-Cmd($outil) { if ($outil.commande -is [string]) { $outil.commande } else { $outil.commande.windows } }
function Outils-Plateforme {
  $Manifeste.outils | Where-Object { $_.ContainsKey('windows') -and ((-not $_.ContainsKey('profil')) -or (Etape-Active $_.profil)) }
}
function Lire-Version([string]$cmd) {
  $c = Get-Command $cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $c) { return $null }
  if ($c.Source -like '*\WindowsApps\python*.exe') { try { if ((Get-Item -LiteralPath $c.Source -Force).Length -eq 0) { return 'alias-store' } } catch { return 'alias-store' } }
  $r = Silence $c.Source @('--version')
  if ($r.code -ne 0) { return $null }
  if ($r.texte -match '(\d+)\.(\d+)(?:\.(\d+))?') { return $Matches[0] }
  return '?'
}
function Etat-Outil($outil) {
  $v = Lire-Version (Get-Cmd $outil)
  if (-not $v) { return @{ ok = $false; version = $null; detail = 'absent' } }
  if ($v -eq 'alias-store') { return @{ ok = $false; version = $null; detail = "alias du Microsoft Store, pas un vrai Python" } }
  if ($outil.ContainsKey('majeur')) {
    $maj = [int]($v -split '\.')[0]
    return @{ ok = ($maj -eq $outil.majeur); version = $v; detail = "$v (exigé : $($outil.majeur).x)" }
  }
  if ($outil.ContainsKey('min') -and $v -ne '?' -and ([version]$v -lt [version]$outil.min)) {
    return @{ ok = $false; version = $v; detail = "$v (minimum $($outil.min))" }
  }
  return @{ ok = $true; version = $v; detail = $v }
}
function Winget-Installer([string]$id, [string[]]$plus = @()) {
  $base = @('--id', $id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
  $code = Exec winget (@('install') + $base + $plus) -Tolerer
  # 0x8A15002B : rien à mettre à jour ; 0x8A150061 : déjà installé. L'état réel est revérifié par l'appelant.
  if ($code -notin 0, -1978335189, -1978335135) { Dire "winget a rendu le code $code pour $id" }
  Update-Chemin
}
function Installer-Node($outil) {
  $etat = Etat-Outil $outil
  if ($etat.version) {
    throw "Node $($etat.version) est installé, AEGIS exige Node $($outil.majeur). Désinstallez-le (winget uninstall --id OpenJS.NodeJS) ou passez par un gestionnaire de versions, puis relancez install."
  }
  $versions = (Silence winget @('show', '--id', $outil.windows.winget, '--exact', '--versions', '--accept-source-agreements')).texte -split "`r?`n" |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -match "^$($outil.majeur)\.\d+\.\d+$" }
  if (-not $versions) { throw "winget ne propose aucune version $($outil.majeur).x de $($outil.windows.winget)" }
  $v = ($versions | Sort-Object { [version]$_ } -Descending)[0]
  Faire "Node $v (winget, épinglé en $($outil.majeur).*)" {
    Winget-Installer $outil.windows.winget @('--version', $v)
    $null = Exec winget @('pin', 'add', '--id', $outil.windows.winget, '--version', "$($outil.majeur).*", '--force') -Tolerer
  }
}
function Chemin-Vswhere { Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe' }
function Outils-Msvc {
  $vw = Chemin-Vswhere
  if (-not (Test-Path $vw)) { return $false }
  return [bool](& $vw -products * -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
}

function Install-Outils {
  Titre 'Outils (winget)'
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget est absent : installez « App Installer » depuis le Microsoft Store, puis relancez."
  }
  foreach ($outil in Outils-Plateforme) {
    $etat = Etat-Outil $outil
    if ($etat.ok) { Note ok outils $outil.nom $etat.detail; continue }
    if ($outil.id -eq 'node') { Installer-Node $outil }
    elseif ($etat.version) { Faire "mise à niveau de $($outil.nom) ($($etat.detail))" { $null = Exec winget @('upgrade', '--id', $outil.windows.winget, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements') -Tolerer; Update-Chemin } }
    else { Faire "installation de $($outil.nom) ($($outil.windows.winget))" { Winget-Installer $outil.windows.winget } }
    if ($O.simulation) { continue }
    $etat = Etat-Outil $outil
    if ($etat.ok) { Note ok outils $outil.nom $etat.detail }
    elseif ($outil.requis) { Note erreur outils $outil.nom $etat.detail 'ouvrez un nouveau terminal (PATH) puis relancez install' }
    else { Note avert outils $outil.nom $etat.detail }
  }
  if ((Etape-Active 'rust') -and -not (Outils-Msvc)) {
    $bt = $Manifeste.rust.windows_build_tools
    Faire "outils de compilation MSVC pour Rust ($($bt.winget), plusieurs Go)" { Winget-Installer $bt.winget @('--override', $bt.override) }
  }
}
function Update-Outils {
  Titre 'Mise à niveau des outils (winget)'
  foreach ($outil in Outils-Plateforme) {
    if ($outil.id -eq 'node') { Dire "Node reste en $($outil.majeur).x (épinglé)"; continue }
    Faire "winget upgrade $($outil.windows.winget)" { $null = Exec winget @('upgrade', '--id', $outil.windows.winget, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') -Tolerer }
  }
  Update-Chemin
  if (Get-Command rustup -ErrorAction SilentlyContinue) { Faire 'rustup update' { $null = Exec rustup @('update') -Tolerer } }
}

# ------------------------------------------------------------------ GitHub
function Install-Github {
  Titre 'GitHub'
  if ((Silence gh @('auth', 'status')).code -eq 0) { Note ok github 'gh connecté'; return }
  if ($O.nonInteractif) { Note erreur github 'gh non connecté' '' 'gh auth login --web'; throw 'gh non connecté (mode non interactif)' }
  Faire 'gh auth login (navigateur)' { $null = Exec gh @('auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web') }
  Faire 'gh auth setup-git' { $null = Exec gh @('auth', 'setup-git') }
  foreach ($cle in 'user.name', 'user.email') {
    if (-not (Silence git @('config', '--global', $cle)).texte) {
      if ($O.nonInteractif) { Note avert github "git $cle" 'absent'; continue }
      $val = Read-Host "  git $cle"
      if ($val) { Faire "git config --global $cle" { $null = Exec git @('config', '--global', $cle, $val) } }
    }
  }
}

# ------------------------------------------------------------------ dépôts
function Etat-Depot([string]$chemin) {
  $branche = (Silence git @('-C', $chemin, 'rev-parse', '--abbrev-ref', 'HEAD')).texte
  $sale = @((Silence git @('-C', $chemin, 'status', '--porcelain')).texte -split "`n" | Where-Object { $_ }).Count
  $compte = (Silence git @('-C', $chemin, 'rev-list', '--left-right', '--count', 'HEAD...origin/main'))
  $avance = 0; $retard = 0
  if ($compte.code -eq 0 -and $compte.texte -match '^(\d+)\s+(\d+)$') { $avance = [int]$Matches[1]; $retard = [int]$Matches[2] }
  $crlf = (Silence git @('-C', $chemin, 'config', 'core.autocrlf')).texte -eq 'true'
  return @{ branche = $branche; sale = $sale; avance = $avance; retard = $retard; crlf = $crlf }
}
function Install-Depots([switch]$MiseAJour) {
  Titre "Dépôts $Org dans $Racine"
  if (-not (Test-Path $Racine)) { Faire "création de $Racine" { $null = New-Item -ItemType Directory -Path $Racine } }
  $config = @($Manifeste.clone.config | ForEach-Object { '-c'; $_ })
  foreach ($d in $Manifeste.depots) {
    $c = Join-Path $Racine $d.nom
    if (Test-Path (Join-Path $c '.git')) {
      Faire "git fetch $($d.nom)" { $null = Exec git @('-C', $c, 'fetch', '--prune', '--quiet') -Tolerer }
      if ($O.simulation) { Note info depots $d.nom 'présent'; continue }
      $e = Etat-Depot $c
      if ($MiseAJour -and $e.branche -eq 'main' -and $e.sale -eq 0 -and $e.retard -gt 0) {
        $null = Exec git @('-C', $c, 'merge', '--ff-only', '--quiet', 'origin/main')
        Note ok depots $d.nom "main avancée de $($e.retard) commit(s)"
      } elseif ($e.branche -ne 'main') {
        Note info depots $d.nom "branche $($e.branche) (retard $($e.retard) sur origin/main), laissée telle quelle"
      } elseif ($e.sale -gt 0 -and $e.retard -gt 0) {
        Note avert depots $d.nom "main en retard de $($e.retard), $($e.sale) fichier(s) modifié(s) : pas d'avance automatique"
      } else { Note ok depots $d.nom "$($e.branche), à jour" }
    } elseif ((Test-Path $c) -and (Get-ChildItem -Force $c | Select-Object -First 1)) {
      Note avert depots $d.nom "$c existe et n'est pas un clone : ignoré"
    } else {
      Faire "clone de $Org/$($d.nom) (LF)" { $null = Exec gh (@('repo', 'clone', "$Org/$($d.nom)", $c, '--') + $config + @('--quiet')) }
      if (-not $O.simulation) { Note ok depots $d.nom 'cloné' }
    }
  }
}

# ------------------------------------------------------------------ racine (copies suivies par empreinte)
function Lire-Empreintes {
  $f = Join-Path $Etat 'empreintes'; $h = @{}
  if (Test-Path $f) { Get-Content $f | ForEach-Object { $p = $_ -split "`t"; if ($p.Count -eq 2) { $h[$p[0]] = $p[1] } } }
  return $h
}
function Ecrire-Empreintes($h) {
  if (-not (Test-Path $Etat)) { $null = New-Item -ItemType Directory -Path $Etat }
  $lignes = $h.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)`t$($_.Value)" }
  [IO.File]::WriteAllLines((Join-Path $Etat 'empreintes'), [string[]]$lignes)
}
function Empreinte($f) { (Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash.ToLowerInvariant() }
function Fichiers-Racine {
  foreach ($f in $Manifeste.racine.fichiers) { [pscustomobject]@{ src = (Join-Path $Ici $f.source); cible = $f.cible } }
  # Le kit détaillé vit dans hq (privé) : copié à la racine dès que hq est cloné.
  $kit = Join-Path $Racine $Manifeste.racine.kit_source
  if (Test-Path $kit) { [pscustomobject]@{ src = $kit; cible = $Manifeste.racine.kit } }
}
function Install-Racine {
  Titre 'Racine de l''atelier'
  $emp = Lire-Empreintes
  foreach ($f in Fichiers-Racine) {
    $src = $f.src; $dst = Join-Path $Racine $f.cible
    $hs = Empreinte $src
    if (Test-Path $dst) {
      $hd = Empreinte $dst
      if ($hd -eq $hs) { Note ok racine $f.cible 'à jour'; $emp[$f.cible] = $hs; continue }
      if ($emp.ContainsKey($f.cible) -and $emp[$f.cible] -ne $hd) {
        $bak = "$dst.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Faire "sauvegarde de $($f.cible) modifié à la main → $(Split-Path -Leaf $bak)" { Copy-Item -LiteralPath $dst $bak }
      } elseif (-not $emp.ContainsKey($f.cible)) {
        $bak = "$dst.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Faire "sauvegarde de $($f.cible) existant → $(Split-Path -Leaf $bak)" { Copy-Item -LiteralPath $dst $bak }
      }
    }
    Faire "pose de $($f.cible)" {
      $dir = Split-Path -Parent $dst; if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir }
      Copy-Item -LiteralPath $src $dst -Force
    }
    $emp[$f.cible] = $hs
    if (-not $O.simulation) { Note ok racine $f.cible 'posé' }
  }
  if (-not $O.simulation) { Ecrire-Empreintes $emp }
}

# ------------------------------------------------------------------ npm
function Install-Npm([switch]$MiseAJour) {
  Titre 'Atelier npm'
  $node = $Manifeste.outils | Where-Object id -eq 'node'
  if (-not (Etat-Outil $node).ok) { Note erreur npm 'Node' "Node $($node.majeur) absent : étape ignorée" 'aegis.ps1 install --seulement outils'; return }
  $kit = Join-Path $Racine 'heimdall/outils/kit.mjs'
  $pkg = Join-Path $Racine 'package.json'
  if (-not (Test-Path $pkg)) {
    if (-not (Test-Path $kit)) { Note avert npm 'atelier' 'heimdall absent : atelier non créé'; return }
    Faire 'package.json d''atelier (heimdall/outils/kit.mjs atelier)' { $null = Exec node @($kit, 'atelier', '--dossier', $Racine) }
  }
  Push-Location $Racine
  try {
    Faire 'npm install (atelier : syn + heimdall)' { $null = Exec npm @('install', '--no-audit', '--no-fund', '--loglevel=error') }
    foreach ($d in $Manifeste.npm.construire) {
      $c = Join-Path $Racine $d
      if (Test-Path (Join-Path $c 'package.json')) { Faire "npm run build ($d)" { Push-Location $c; try { $null = Exec npm @('run', 'build', '--silent') } finally { Pop-Location } } }
    }
    foreach ($d in $Manifeste.npm.ci) {
      $c = Join-Path $Racine $d; $lock = Join-Path $c 'package-lock.json'; $marque = Join-Path $c 'node_modules/.package-lock.json'
      if (-not (Test-Path $lock)) { continue }
      if ($MiseAJour -and (Test-Path $marque) -and ((Get-Item $marque).LastWriteTime -ge (Get-Item $lock).LastWriteTime)) { Note ok npm $d 'node_modules à jour'; continue }
      Faire "npm ci ($d)" { Push-Location $c; try { $null = Exec npm @('ci', '--no-audit', '--no-fund', '--loglevel=error') } finally { Pop-Location } }
    }
  } finally { Pop-Location }
  if (-not $O.simulation) { Note ok npm 'atelier' 'installé et construit' }
}

# ------------------------------------------------------------------ Rust
function Install-Rust {
  Titre 'Chaîne Rust'
  if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) { Note erreur rust 'rustup' 'absent' 'aegis.ps1 install --seulement outils'; return }
  if (-not (Silence rustup @('default')).texte -or (Silence rustup @('default')).texte -match 'no default') { Faire 'rustup default stable' { $null = Exec rustup @('default', 'stable') } }
  $cibles = (Silence rustup @('target', 'list', '--installed')).texte -split "`r?`n"
  foreach ($t in $Manifeste.rust.cibles) {
    if ($t -in $cibles) { Note ok rust "cible $t" 'installée' } else { Faire "rustup target add $t" { $null = Exec rustup @('target', 'add', $t) } }
  }
  $comps = (Silence rustup @('component', 'list', '--installed')).texte
  foreach ($k in $Manifeste.rust.composants) {
    if ($comps -match "(?m)^$k-") { Note ok rust $k 'installé' } else { Faire "rustup component add $k" { $null = Exec rustup @('component', 'add', $k) } }
  }
  foreach ($ci in $Manifeste.rust.cargo_install) {
    if (Get-Command $ci.commande -ErrorAction SilentlyContinue) { Note ok rust $ci.crate 'installé'; continue }
    Faire "cargo install $($ci.crate) --locked (quelques minutes)" { $null = Exec cargo @('install', $ci.crate, '--locked') }
  }
}

# ------------------------------------------------------------------ VS Code
function Code-Exe { (Get-Command code -ErrorAction SilentlyContinue | Select-Object -First 1)?.Source }
function Extensions-Manquantes {
  $code = Code-Exe; if (-not $code) { return $null }
  $presentes = (& $code --list-extensions 2>$null) | ForEach-Object { $_.ToLowerInvariant() }
  return @($Manifeste.vscode.extensions | Where-Object { $_.ToLowerInvariant() -notin $presentes })
}
function Install-Vscode {
  Titre 'VS Code'
  $code = Code-Exe
  if (-not $code) { Note avert vscode 'code' 'absent du PATH : extensions non installées' 'winget install Microsoft.VisualStudioCode'; return }
  $manq = Extensions-Manquantes
  if ($manq.Count -eq 0) { Note ok vscode 'extensions' "$($Manifeste.vscode.extensions.Count) présentes" }
  foreach ($x in $manq) { Faire "extension $x" { $null = Exec $code @('--install-extension', $x) -Tolerer } }
  Dire "Ouvrir : code `"$(Join-Path $Racine 'aegis.code-workspace')`""
}

# ------------------------------------------------------------------ skills de mimir (jonctions : pas de mode développeur requis)
function Dossier-Skills { $env:CLAUDE_SKILLS ?? (Join-Path $HOME '.claude/skills') }
function Install-Skills {
  Titre 'Skills de mimir (Claude Code)'
  $src = Join-Path $Racine 'mimir/skills'
  if (-not (Test-Path $src)) { Note avert skills 'mimir' 'absent : skills non liées'; return }
  $cible = Dossier-Skills
  if (-not (Test-Path $cible)) { Faire "création de $cible" { $null = New-Item -ItemType Directory -Path $cible -Force } }
  foreach ($s in Get-ChildItem -Directory $src) {
    $lien = Join-Path $cible $s.Name
    $item = Get-Item -LiteralPath $lien -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq 'Junction') {
      if ([IO.Path]::GetFullPath($item.Target) -eq $s.FullName) { Note ok skills $s.Name 'liée'; continue }
      Faire "jonction $($s.Name) repointée" { [IO.Directory]::Delete($lien, $false) }
    } elseif ($item) { Note avert skills $s.Name 'existe et n''est pas une jonction : laissé'; continue }
    Faire "jonction $($s.Name) → $($s.FullName)" { $null = New-Item -ItemType Junction -Path $lien -Target $s.FullName }
  }
}

# ------------------------------------------------------------------ guide
function Port-Ecoute([int]$p) { [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) }
function Ouvrir-Guide {
  $kit = Join-Path $Racine $Manifeste.racine.kit
  if (Test-Path $kit) {
    if (-not (Port-Ecoute 7480)) {
      $py = (Get-Command python -ErrorAction SilentlyContinue)?.Source ?? (Get-Command py -ErrorAction SilentlyContinue)?.Source
      Start-Process -FilePath $py -ArgumentList '-m', 'http.server', '7480', '--bind', '127.0.0.1' -WorkingDirectory $Racine -WindowStyle Hidden
      Start-Sleep -Milliseconds 800
    }
    $url = "http://127.0.0.1:7480/$($Manifeste.racine.kit)"
    Start-Process $url; Write-Host "Kit : $url (serveur en arrière-plan sur 127.0.0.1:7480)"
  } else {
    $readme = Join-Path $Racine 'README.md'
    if (-not (Test-Path $readme)) { $readme = Join-Path $Ici 'README.md' }
    if (Code-Exe) { & (Code-Exe) $readme } else { Invoke-Item $readme }
    Write-Host "Guide : $readme (pas de $($Manifeste.racine.kit) à la racine)"
  }
}

# ------------------------------------------------------------------ doctor
function Doctor {
  Titre "Système"
  Note info systeme 'Windows' ([Environment]::OSVersion.VersionString)
  Note info systeme 'racine' $Racine
  Note ($(if (Get-Command winget -ErrorAction SilentlyContinue) { 'ok' } else { 'avert' })) systeme 'winget' ''

  Titre 'Outils'
  foreach ($outil in Outils-Plateforme) {
    $e = Etat-Outil $outil
    $conseil = if ($outil.id -eq 'python' -and $e.detail -like '*Store*') { 'Paramètres › Applications › Alias d''exécution : désactiver python.exe, puis install' } else { 'aegis.ps1 install --seulement outils' }
    if ($e.ok) { Note ok outils $outil.nom $e.detail } elseif ($outil.requis) { Note erreur outils $outil.nom $e.detail $conseil } else { Note avert outils $outil.nom $e.detail $conseil }
  }
  if (Etape-Active 'rust') {
    if (Outils-Msvc) { Note ok outils 'MSVC (éditeur de liens)' 'présent' } else { Note erreur outils 'MSVC (éditeur de liens)' 'absent' 'aegis.ps1 install --seulement outils' }
    if (Get-Command rustup -ErrorAction SilentlyContinue) {
      $cibles = (Silence rustup @('target', 'list', '--installed')).texte -split "`r?`n"
      foreach ($t in $Manifeste.rust.cibles) { if ($t -in $cibles) { Note ok rust "cible $t" '' } else { Note avert rust "cible $t" 'absente' 'aegis.ps1 install --seulement rust' } }
      foreach ($ci in $Manifeste.rust.cargo_install) { if (Get-Command $ci.commande -ErrorAction SilentlyContinue) { Note ok rust $ci.crate '' } else { Note avert rust $ci.crate 'absent' 'aegis.ps1 install --seulement rust' } }
    }
  }

  Titre 'GitHub'
  $auth = Silence gh @('auth', 'status')
  if ($auth.code -eq 0) {
    $compte = if ($auth.texte -match 'account (\S+)') { $Matches[1] } else { '' }
    Note ok github 'gh connecté' $compte
    if ($auth.texte -notmatch 'read:packages') { Note info github 'scope read:packages' 'absent (inutile avec l''atelier npm)' 'gh auth refresh -s read:packages' }
  } else { Note erreur github 'gh connecté' 'non' 'gh auth login --web' }
  foreach ($cle in 'user.name', 'user.email') {
    if ((Silence git @('config', '--global', $cle)).texte) { Note ok github "git $cle" '' } else { Note avert github "git $cle" 'absent' "git config --global $cle …" }
  }

  Titre 'Clones'
  foreach ($d in $Manifeste.depots) {
    $c = Join-Path $Racine $d.nom
    if (-not (Test-Path (Join-Path $c '.git'))) { Note erreur depots $d.nom 'absent' 'aegis.ps1 install --seulement depots'; continue }
    $e = Etat-Depot $c
    $txt = "$($e.branche)" + $(if ($e.retard) { ", retard $($e.retard) sur origin/main" } else { '' }) + $(if ($e.sale) { ", $($e.sale) modifié(s)" } else { '' })
    Note ($(if ($e.branche -eq 'main' -and $e.retard -eq 0) { 'ok' } else { 'info' })) depots $d.nom $txt
    if ($e.crlf) { Note avert depots "$($d.nom) : fins de ligne" 'clone CRLF (core.autocrlf=true)' 'nocturne et synchro-contrats exigent un clone LF : reclonez via aegis install' }
  }

  Titre 'Racine'
  foreach ($f in Fichiers-Racine) {
    $dst = Join-Path $Racine $f.cible
    if (-not (Test-Path $dst)) { Note avert racine $f.cible 'absent' 'aegis.ps1 update'; continue }
    if ((Empreinte $dst) -eq (Empreinte $f.src)) { Note ok racine $f.cible 'à jour' } else { Note avert racine $f.cible 'diffère du modèle' 'aegis.ps1 update (sauvegarde .bak si modifié à la main)' }
  }
  Note ($(if (Test-Path (Join-Path $Racine 'package.json')) { 'ok' } else { 'avert' })) npm 'package.json d''atelier' ''
  Note ($(if (Test-Path (Join-Path $Racine 'node_modules')) { 'ok' } else { 'avert' })) npm 'node_modules d''atelier' ''
  foreach ($d in $Manifeste.npm.construire) {
    $dist = @(Get-ChildItem -Directory -Path (Join-Path $Racine "$d/packages/*/dist") -ErrorAction SilentlyContinue).Count
    Note ($(if ($dist) { 'ok' } else { 'avert' })) npm "$d construit" "$dist paquet(s) avec dist/" $(if (-not $dist) { 'aegis.ps1 install --seulement npm' } else { '' })
  }
  foreach ($d in $Manifeste.npm.ci) { Note ($(if (Test-Path (Join-Path $Racine "$d/node_modules")) { 'ok' } else { 'avert' })) npm "$d node_modules" '' }
  Note ($(if (Test-Path (Join-Path $Racine $Manifeste.racine.kit)) { 'ok' } else { 'info' })) racine $Manifeste.racine.kit $(if (Test-Path (Join-Path $Racine $Manifeste.racine.kit)) { 'kit détaillé présent' } else { "absent : cloner hq ($($Manifeste.racine.kit_source)), sinon le guide ouvre README.md" })

  Titre 'VS Code et Claude Code'
  $manq = Extensions-Manquantes
  if ($null -eq $manq) { Note avert vscode 'code' 'absent du PATH' }
  elseif ($manq.Count -eq 0) { Note ok vscode 'extensions' "$($Manifeste.vscode.extensions.Count) présentes" }
  else { Note avert vscode 'extensions' "manquantes : $($manq -join ', ')" 'aegis.ps1 install --seulement vscode' }
  $src = Join-Path $Racine 'mimir/skills'
  if (Test-Path $src) {
    $attendues = @(Get-ChildItem -Directory $src).Name
    $liees = @($attendues | Where-Object { Test-Path (Join-Path (Dossier-Skills) $_) })
    Note ($(if ($liees.Count -eq $attendues.Count) { 'ok' } else { 'avert' })) skills 'skills de mimir' "$($liees.Count)/$($attendues.Count) liées" $(if ($liees.Count -ne $attendues.Count) { 'aegis.ps1 install --seulement skills' } else { '' })
  }
  foreach ($p in $Manifeste.ports) {
    $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) { Note info ports "port $p" "occupé par $((Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue).ProcessName)" } else { Note ok ports "port $p" 'libre' }
  }
}

function Afficher-Bilan {
  $err = @($script:Bilan | Where-Object statut -eq 'erreur').Count
  $av = @($script:Bilan | Where-Object statut -eq 'avert').Count
  if ($O.json) { [Console]::Out.WriteLine(($script:Bilan | ConvertTo-Json -Depth 3)); return $err }
  $couleur = if ($err) { 'Red' } elseif ($av) { 'Yellow' } else { 'Green' }
  Write-Host "`nBilan : $err erreur(s), $av avertissement(s)." -ForegroundColor $couleur
  return $err
}

# ------------------------------------------------------------------ entrée
function Relancer-Si-Change([string]$avant) {
  $c = Join-Path $Racine '.github'
  if ($O.relance -or -not (Test-Path (Join-Path $c '.git'))) { return }
  $apres = (Silence git @('-C', $c, 'rev-parse', 'HEAD')).texte
  if ($avant -and $apres -ne $avant -and [IO.Path]::GetFullPath($Ici).StartsWith([IO.Path]::GetFullPath($c))) {
    Dire 'Le bootstrap a changé : relance avec la nouvelle version.'
    & pwsh -NoProfile -File $PSCommandPath @ArgsOrigine --relance
    exit $LASTEXITCODE
  }
}

switch ($Commande) {
  'install' {
    Write-Host "AEGIS — installation du poste dans $Racine$(if ($O.simulation) { ' (simulation)' })" -ForegroundColor Cyan
    if (Etape-Active 'outils') { Install-Outils }
    if (Etape-Active 'github') { Install-Github }
    if (Etape-Active 'depots') { Install-Depots }
    if (Etape-Active 'racine') { Install-Racine }
    if (Etape-Active 'npm') { Install-Npm }
    if (Etape-Active 'rust') { Install-Rust }
    if (Etape-Active 'vscode') { Install-Vscode }
    if (Etape-Active 'skills') { Install-Skills }
    $script:Bilan.Clear(); Doctor; exit ([int]((Afficher-Bilan) -gt 0))
  }
  'update' {
    Write-Host "AEGIS — mise à jour du poste dans $Racine$(if ($O.simulation) { ' (simulation)' })" -ForegroundColor Cyan
    $tete = (Silence git @('-C', (Join-Path $Racine '.github'), 'rev-parse', 'HEAD')).texte
    if (Etape-Active 'depots') { Install-Depots -MiseAJour; Relancer-Si-Change $tete }
    if ($O.outils -and (Etape-Active 'outils')) { Update-Outils }
    if (Etape-Active 'racine') { Install-Racine }
    if (Etape-Active 'npm') { Install-Npm -MiseAJour }
    if (Etape-Active 'vscode') { Install-Vscode }
    if (Etape-Active 'skills') { Install-Skills }
    $script:Bilan.Clear(); Doctor; exit ([int]((Afficher-Bilan) -gt 0))
  }
  'doctor' { Doctor; exit ([int]((Afficher-Bilan) -gt 0)) }
  'guide'  { Ouvrir-Guide }
  default  { Get-Help $PSCommandPath -Detailed | Out-String | Write-Host; if ($Commande -notin 'aide') { exit 1 } }
}
