# Poste de développement AEGIS

Bootstrap du poste standard (« dev-env ») de `calahan-io`. Une commande reproduit, sur un PC neuf, l'atelier
`AEGIS-CORP` tel qu'il tourne aujourd'hui :
- les outils ;
- les sept dépôts clonés côte à côte ;
- l'espace de travail VS Code ;
- l'atelier npm ;
- la chaîne Rust ;
- les skills des agents ;
- l'accès au guide.

Ensuite, un CLI `aegis` (`install`, `update`, `doctor`, `guide`) le garde à jour et le diagnostique. Il est pris en charge sur
**Windows 11** et sur **Bluefin** (Fedora Atomic), et devrait marcher sur tout Linux doté de Homebrew.

> Ce dépôt est **public** : rien de confidentiel ici. Les dépôts clonés sont privés : il faut un compte GitHub membre de
> `calahan-io`. Le kit détaillé (état de la CI, pièges du poste, parcours guidés) vit donc dans `hq`, privé :
> `hq/scripts/poste/readme.html`. `install` et `update` le copient à la racine en `readme.html` dès que `hq` est cloné.
> On le modifie dans `hq`, par PR.

## Démarrer sur un PC neuf

**Windows 11** — dans PowerShell, sans droits administrateur (winget demandera l'élévation au besoin) :

```powershell
irm https://raw.githubusercontent.com/calahan-io/.github/main/poste/amorcer.ps1 | iex
```

**Bluefin / Linux** — dans un terminal :

```bash
curl -fsSL https://raw.githubusercontent.com/calahan-io/.github/main/poste/amorcer.sh | bash
```

L'amorce installe `git` et `gh` (et PowerShell 7 sous Windows, `jq` sous Linux), puis clone ce dépôt dans
`~/AEGIS-CORP/.github` et lance `aegis install`. Un navigateur s'ouvre une fois pour `gh auth login`. Racine différente :
`AEGIS_RACINE=/chemin` avant la commande (`$env:AEGIS_RACINE = 'D:\aegis'` sous PowerShell). Options d'installation :
`$env:AEGIS_ARGS = '--sans rust'` (Windows) ou `| bash -s -- --sans rust` (Linux).

Puis ouvrez `~/AEGIS-CORP/aegis.code-workspace` dans VS Code.

## Le CLI `aegis`

| Windows (PowerShell 7) | Linux, Bluefin |
|---|---|
| `.github/poste/aegis.ps1 <commande>` | `.github/poste/aegis.sh <commande>` |

| Commande | Effet |
|---|---|
| `install` | installe ou répare tout, étape par étape, puis lance `doctor`. Idempotent. |
| `update` | avance les clones posés sur `main` sans modification locale. Les autres branches sont laissées telles quelles et signalées. Repose ensuite les fichiers de la racine, refait l'atelier npm et complète les extensions. Si le bootstrap lui-même a changé, il se relance dans sa nouvelle version. `--outils` met aussi à niveau winget / brew / rustup, Node restant en 24.x. |
| `doctor` | diagnostic sans modification : outils et versions, `gh`, clones (branche, retard, fins de ligne), racine, atelier, extensions, skills, ports 7400 et 7480. Code de sortie 1 en cas d'erreur ; `--json` pour une sortie machine. |
| `guide` | sert le kit `readme.html` (copié depuis `hq/scripts/poste/`) sur `127.0.0.1:7480`, sinon ouvre le `README.md` de la racine. |

Options communes :
- `--racine <dossier>` ;
- `--simulation` : affiche sans agir ;
- `--sans <étapes>` et `--seulement <étapes>`, étapes séparées par des virgules ;
- `--non-interactif` : CI, aucune question.

Étapes : `outils`, `github`, `depots`, `racine`, `npm`, `rust`, `vscode`, `skills`.

Dans VS Code, les mêmes commandes sont des tâches : Terminal › Exécuter la tâche › `AEGIS : doctor`, `AEGIS : update`,
`AEGIS : guide`, plus `heimdall : demo`, `maurr : régression`, `maurr-node : cargo test` et `hq : valider le vault`.

## Ce qui est installé

Tout est décrit dans [`manifeste.json`](manifeste.json), lu par les deux scripts : on modifie le manifeste, jamais les
scripts.

| Élément | Windows | Bluefin / Linux |
|---|---|---|
| Git, GitHub CLI, jq | winget | Homebrew |
| Node **24.x exactement** (rejeu au bit près, hq#42) | winget, dernière 24.x, épinglée (`winget pin`) | `brew install node@24` + `brew link` |
| Python ≥ 3.12 | winget `Python.Python.3.12` | `python3` du système |
| PowerShell 7 | winget | — |
| Rust stable, cible `thumbv7em-none-eabihf`, clippy, rustfmt, cargo-deny | winget `Rustlang.Rustup` + Build Tools MSVC | `rustup` dans `~/.cargo` ; `cc` par `brew install gcc` |
| VS Code + 12 extensions | winget | `ujust devmode` (image DX) ou Flatpak, à faire soi-même |
| Sept clones `calahan-io` | **LF** (`core.autocrlf=false`), comme la CI | idem |
| Atelier npm | `heimdall/outils/kit.mjs atelier`, `npm install`, build de `syn` et `heimdall`, `npm ci` de `maurr` | idem |
| Skills de `mimir` | jonctions dans `~/.claude/skills` (sans mode développeur) | `mimir/outils/installer.sh` (liens) |

Pourquoi des clones en LF sous Windows ? Le nocturne (`integration.sh`) et `synchro-contrats.sh --verifier` échouent sur un
clone CRLF. Un clone ancien en CRLF est signalé par `doctor` ; le reclonner suffit.

Bluefin est immuable : le bootstrap n'appelle jamais `rpm-ostree` ni `dnf`. Il utilise Homebrew (préinstallé) et
`~/.cargo`. Pour une chaîne lourde (firmware ESP32-S3), préférez une distrobox ou un conteneur de dev.

## La racine produite

```
AEGIS-CORP/
├── .github/  hq/  syn/  heimdall/  maurr/  maurr-node/  mimir/   # clones
├── aegis.code-workspace      # ← modeles/aegis.code-workspace
├── README.md                 # ← modeles/LISEZMOI.md
├── .claude/launch.json       # ← modeles/launch.json (aperçus Claude Code : heimdall-demo, kit-readme)
├── package.json  node_modules/   # atelier npm (kit.mjs atelier)
└── .aegis/empreintes         # empreintes des fichiers posés (détecte les modifications locales)
```

Les fichiers de la racine sont des copies des modèles. `update` remplace sans bruit une copie intacte. Une copie modifiée
à la main est d'abord sauvegardée en `<fichier>.bak-<date>`. Une modification utile se propose par PR ici.

## Faire évoluer le poste

- **Ajouter un outil, une extension ou un dépôt** : `manifeste.json`. Les extensions sont listées aussi dans
  `modeles/aegis.code-workspace`, et la CI `poste` vérifie que les deux listes concordent.
- **Changer l'espace de travail, le README de la racine ou les aperçus** : `modeles/`.
- **CI** : `.github/workflows/poste.yml`. Elle passe shellcheck, vérifie le manifeste, fait un vrai `install` des outils
  sous Linux avec Homebrew seul (le chemin de Bluefin) et analyse les scripts PowerShell. Le clonage des dépôts privés se
  vérifie sur un poste.

Les scripts de tour (WSL2, exécuteur auto-hébergé, banc HIL) restent dans `hq/scripts/amorce/infra/`. Ce bootstrap couvre
le poste de développement, pas l'infrastructure.
