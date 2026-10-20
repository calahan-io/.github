# Atelier AEGIS

Racine de travail standard des dépôts `calahan-io`, posée par le bootstrap du poste
([`.github/poste`](.github/poste/README.md)). Ce fichier est régénéré par `aegis update` : ne l'éditez pas ici, proposez vos
changements par PR sur `.github` (`poste/modeles/LISEZMOI.md`).

## Ouvrir

- **VS Code** : ouvrez `aegis.code-workspace` (Fichier › Ouvrir l'espace de travail). Les tâches `AEGIS : doctor`,
  `AEGIS : update` et `AEGIS : guide` sont dans Terminal › Exécuter la tâche.
- **Claude Code** : ouvrez une session sur cette racine, ou sur `hq` pour les commandes du vault (`/triage`, `/adr`,
  `/journal`). `.claude/launch.json` lance la démo HEIMDALL (`heimdall-demo`, port 7400) et le kit (`kit-readme`, port 7480).

## Le CLI du poste

| Windows (PowerShell 7) | Linux, Bluefin (bash) | Rôle |
|---|---|---|
| `.github/poste/aegis.ps1 doctor` | `.github/poste/aegis.sh doctor` | diagnostic, sans rien modifier |
| `.github/poste/aegis.ps1 update` | `.github/poste/aegis.sh update` | met à jour le bootstrap, les clones sur `main`, l'atelier npm, VS Code |
| `.github/poste/aegis.ps1 install` | `.github/poste/aegis.sh install` | installe ou répare le poste (idempotent) |
| `.github/poste/aegis.ps1 guide` | `.github/poste/aegis.sh guide` | ouvre le kit de démarrage |

## Structure

```
AEGIS-CORP/
├── .github/  hq/  syn/  heimdall/  maurr/  maurr-node/  mimir/   # les sept clones (LF, comme la CI)
├── aegis.code-workspace                                        # espace de travail VS Code
├── package.json  node_modules/                                 # atelier npm : syn + heimdall sans registre
├── .claude/launch.json                                         # aperçus Claude Code
├── readme.html                                                 # kit de démarrage détaillé (hors Git, s'il existe)
└── README.md                                                   # ce fichier
```

| Dépôt | Rôle | Entrée |
|---|---|---|
| `hq` | le savoir : vision, conception, décisions (ADR), journal — **source de vérité** | [CLAUDE.md](hq/CLAUDE.md) · [README](hq/README.md) |
| `syn` | les contrats communs | [CLAUDE.md](syn/CLAUDE.md) |
| `heimdall` | le C2 | [README](heimdall/README.md) |
| `maurr` | le châssis : simulation, banc, STIGMA | [README](maurr/README.md) |
| `maurr-node` | le cerveau Rust, le firmware, BIFROST | [README](maurr-node/README.md) |
| `mimir` | le savoir des agents | [socle](mimir/regles/socle-claude.md) |
| `.github` | ce bootstrap, CI réutilisables, modèles | [README](.github/README.md) |

## Lire dans cet ordre

1. [Profil de l'organisation](.github/profile/README.md) : le rôle de chaque dépôt.
2. [`hq/CLAUDE.md`](hq/CLAUDE.md) et le [glossaire](hq/10-vision/glossary.md), dont le vocabulaire est obligatoire.
3. La conception système dans [`hq/30-design/system/`](hq/30-design/system/) : architecture, gouvernance d'ingénierie,
   feuille de route.
4. Le [socle des agents](mimir/regles/socle-claude.md) avant toute écriture.

## Premiers gestes

```sh
cd heimdall && npm run doctor && npm run demo     # cockpit sur http://127.0.0.1:7400
cd maurr && npm test                              # régression de référence : 63,0
cd maurr-node && cargo test
cd hq && python -X utf8 scripts/check_vault.py
```

Règles de contribution : branche `claude/<sujet>` ou personnelle, PR vers `main`, relue par l'autre humain. Ne pas ouvrir
`hq` dans Obsidian sur un clone de travail : Obsidian Git y commiterait seul.
