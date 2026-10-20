# .github — calahan-io

Fichiers communs à tous les dépôts de l'organisation : modèles d'issues et de PR.
Un dépôt qui a son propre dossier `.github/ISSUE_TEMPLATE/` remplace ces valeurs par défaut.

## Poste de développement (dépôt d'entrée)

Ce dépôt, public, sert d'entrée à un nouveau poste. [`poste/`](poste/README.md) installe l'atelier standard `AEGIS-CORP` :
- outils ;
- sept clones côte à côte ;
- espace de travail VS Code ;
- atelier npm ;
- chaîne Rust ;
- skills de `mimir`.

Le CLI `aegis` (`install`, `update`, `doctor`, `guide`) tourne sous Windows 11 et sous Bluefin. Sa source de vérité est
ici, pas dans les gabarits de `hq`.

```powershell
irm https://raw.githubusercontent.com/calahan-io/.github/main/poste/amorcer.ps1 | iex    # Windows
```
```bash
curl -fsSL https://raw.githubusercontent.com/calahan-io/.github/main/poste/amorcer.sh | bash   # Bluefin / Linux
```

## Workflows réutilisables

Les sept workflows du kit d'ossature AEGIS vivent ici, dans `.github/workflows/`, et sont appelés par `syn`, `heimdall`,
`maurr` et `maurr-node` avec `uses: calahan-io/.github/.github/workflows/<nom>.yml@main`. Leur source de vérité reste
le gabarit `hq/scripts/amorce/gabarits/org-github/` : on modifie là-bas, puis on recopie ici par PR.
`maurr-node` appelle `rust-ci.yml` et `contrats-a-jour.yml` depuis maurr-node#9 (en relecture le 18 octobre 2026) ; avant, son `ci.yml` en reprenait les étapes en ligne.

| Nom | Rôle | Entrées (défaut) |
|---|---|---|
| `node-ci.yml` | `npm ci` (paquets `@calahan-io` lus sur GitHub Packages) puis tests, durée bornée | `node-version` (`22`), `commande-test` (`npm test`), `executeur` (`"ubuntu-latest"`), `duree-max` (`10`) |
| `rust-ci.yml` | `cargo fmt`, `clippy`, `test`, `cargo deny` ; compile les crates embarqués pour leurs cibles | `cibles` (`thumbv7em-none-eabihf`), `crates-embarques` (`-p maurr-codec`), `executeur` (`"ubuntu-latest"`), `duree-max` (`15`) |
| `regles-dependances.yml` | `npm ci` (paquets `@calahan-io` lus sur GitHub Packages) puis règles de dépendance (dependency-cruiser, `.dependency-cruiser.cjs`) ; un import interdit fait échouer la CI | `node-version` (`22`) |
| `types-a-jour.yml` | (`syn`) régénère types et vecteurs, échoue au moindre écart | `node-version` (`22`) |
| `contrats-a-jour.yml` | (consommateurs Rust) la copie `contrats/syn` égale le paquet `@calahan-io/syn-contrats` épinglé dans `contrats/syn/VERSION` | `node-version` (`22`) |
| `publier-npm.yml` | publie les paquets d'un espace de travail npm sur GitHub Packages, sur étiquette `v*` (la version doit égaler l'étiquette) ; `npm test` tourne sous le Node passé | `node-version` (`22`) |
| `choisir-executeur.yml` | choisit une tour (`self-hosted`) si une est en ligne, sinon se replie sur un exécuteur hébergé ; sortie `executeur` (JSON pour `runs-on`) | `etiquette` (`aegis-lourd`), `repli` (`"ubuntu-latest"`) ; secrets `AEGIS_CI_APP_ID`, `AEGIS_CI_CLE_PRIVEE` (passer `secrets: inherit`) |

Exemple d'appel, dans le `.github/workflows/ci.yml` d'un dépôt Node :

```yaml
name: ci
on:
  pull_request:
  push: { branches: [main] }
jobs:
  node:
    uses: calahan-io/.github/.github/workflows/node-ci.yml@main
    with: { node-version: '24', duree-max: 10 }
  regles:
    uses: calahan-io/.github/.github/workflows/regles-dependances.yml@main
    with: { node-version: '24' }
```

Un dépôt qui exige Node 24 (rejeu au bit près des vecteurs, hq#42 : `heimdall`, `maurr`) passe `node-version: '24'` à chaque
workflow qu'il appelle, `publier-npm.yml` compris ; sans cela, l'étiquette `v*` lance `npm test` sous Node 22.

Le dossier `profile/` porte le README public de l'organisation.
