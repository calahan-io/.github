#!/usr/bin/env bash
# aegis — installe, met à jour et diagnostique le poste de développement AEGIS (Linux, Bluefin).
#
# Réplique l'atelier AEGIS-CORP : outils (Homebrew, rustup), sept clones calahan-io côte à côte (LF, comme la CI),
# espace de travail VS Code, atelier npm, chaîne Rust, extensions VS Code, skills de mimir. Tout est décrit dans
# manifeste.json. Idempotent : relancer « install » répare, il ne casse rien. Le pendant Windows est aegis.ps1.
# Bluefin (Fedora Atomic) : rien n'est installé dans le système ; Homebrew et ~/.cargo suffisent.
#
#   aegis.sh <commande> [options]
#     install    installe ou répare le poste
#     update     met à jour le bootstrap, les clones sur main, la racine, l'atelier npm, VS Code (--outils : brew aussi)
#     doctor     diagnostic, sans rien modifier (--json pour une sortie machine)
#     guide      ouvre le kit de démarrage (readme.html servi sur 127.0.0.1:7480) ou le README de la racine
#     aide       cette aide
#
#   Options : --racine <dossier>  --simulation  --sans <étapes>  --seulement <étapes>  --non-interactif  --json  --outils
#   Étapes   : outils, github, depots, racine, npm, rust, vscode, skills
set -Eeuo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo "aegis.sh exige bash ≥ 4" >&2; exit 2; }

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTE="$ICI/manifeste.json"
ARGS_ORIGINE=("$@")
ETAPES=(outils github depots racine npm rust vscode skills)

case "$(uname -s)" in
  Linux) PLATEFORME=linux; OSKEY=linux ;;
  MINGW*|MSYS*|CYGWIN*) PLATEFORME=msys; OSKEY=windows ;;   # Git Bash : doctor et update seulement (install → aegis.ps1)
  *) echo "Système non pris en charge : $(uname -s)" >&2; exit 2 ;;
esac
BLUEFIN=0
if [[ -f /usr/share/ublue-os/image-info.json ]] || grep -qi bluefin /etc/os-release 2>/dev/null; then BLUEFIN=1; fi

# ------------------------------------------------------------------ options
COMMANDE=aide; RACINE=""; SIMULATION=0; NON_INTERACTIF=0; JSON=0; OUTILS=0; RELANCE=0; SANS=(); SEULEMENT=()
if [[ $# -gt 0 && "$1" != -* ]]; then COMMANDE="$1"; shift; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --racine) RACINE="$2"; shift ;;
    --simulation) SIMULATION=1 ;;
    --sans) IFS=, read -ra SANS <<<"$2"; shift ;;
    --seulement) IFS=, read -ra SEULEMENT <<<"$2"; shift ;;
    --non-interactif) NON_INTERACTIF=1 ;;
    --json) JSON=1 ;;
    --outils) OUTILS=1 ;;
    --relance) RELANCE=1 ;;
    -h|--help|--aide) COMMANDE=aide ;;
    *) echo "Option inconnue : $1 (aegis.sh aide)" >&2; exit 2 ;;
  esac
  shift
done
for e in ${SANS[@]+"${SANS[@]}"} ${SEULEMENT[@]+"${SEULEMENT[@]}"}; do
  [[ " ${ETAPES[*]} " == *" $e "* ]] || { echo "Étape inconnue : $e (attendu : ${ETAPES[*]})" >&2; exit 2; }
done
[[ -t 0 ]] || NON_INTERACTIF=1

aide() { sed -n '2,/^set -E/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

# ------------------------------------------------------------------ sortie
if [[ -t 1 && $JSON -eq 0 ]]; then C_T=$'\e[36m'; C_OK=$'\e[32m'; C_AV=$'\e[33m'; C_ER=$'\e[31m'; C_GR=$'\e[90m'; C_0=$'\e[0m'
else C_T=""; C_OK=""; C_AV=""; C_ER=""; C_GR=""; C_0=""; fi
BILAN=()
titre() { (( JSON )) || printf '\n%s▶ %s%s\n' "$C_T" "$1" "$C_0"; }
dire() { (( JSON )) || printf '  %s\n' "$*"; }
note() { # statut groupe nom [détail] [conseil]
  local statut="$1" groupe="$2" nom="$3" detail="${4:-}" conseil="${5:-}" sym couleur
  BILAN+=("$statut"$'\t'"$groupe"$'\t'"$nom"$'\t'"$detail"$'\t'"$conseil")
  (( JSON )) && return 0
  case "$statut" in ok) sym='✔'; couleur=$C_OK ;; avert) sym='!'; couleur=$C_AV ;; erreur) sym='✖'; couleur=$C_ER ;; *) sym='·'; couleur=$C_GR ;; esac
  printf '  %s%s %-28s %s%s\n' "$couleur" "$sym" "$nom" "$detail" "$C_0"
  [[ -z "$conseil" ]] || printf '      %s→ %s%s\n' "$C_GR" "$conseil" "$C_0"
}
faire() { # description commande…
  local quoi="$1"; shift
  if (( SIMULATION )); then dire "(simulation) $quoi"; return 0; fi
  dire "… $quoi"
  "$@"
}
a() { command -v "$1" >/dev/null 2>&1; }
etape_active() {
  local e="$1"
  if (( ${#SEULEMENT[@]} )) && [[ " ${SEULEMENT[*]} " != *" $e "* ]]; then return 1; fi
  [[ " ${SANS[*]-} " != *" $e "* ]]
}
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

# ------------------------------------------------------------------ manifeste
# jq pour Windows (Git Bash) écrit des fins de ligne CRLF : on les retire partout.
jq() { command jq "$@" | tr -d '\r'; }
a_jq() { command -v jq >/dev/null 2>&1; }
if ! a_jq; then
  if [[ "$COMMANDE" == install && "$PLATEFORME" == linux ]] && a brew && etape_active outils; then
    faire "installation de jq (brew), nécessaire pour lire le manifeste" brew install jq
  fi
  a_jq || { echo "jq est absent : brew install jq (ou aegis.sh install sur un poste avec Homebrew)" >&2; exit 2; }
fi
m() { jq -r "$@" "$MANIFESTE"; }
ORG="$(m .org)"
racine_defaut() {
  if [[ -n "${AEGIS_RACINE:-}" ]]; then echo "$AEGIS_RACINE"; return; fi
  local depot; depot="$(dirname "$ICI")"
  if [[ "$(basename "$depot")" == .github ]]; then dirname "$depot"; else echo "$HOME/$(m .racine_defaut)"; fi
}
RACINE="${RACINE:-$(racine_defaut)}"
(( SIMULATION )) || mkdir -p "$RACINE" 2>/dev/null || true
RACINE="$(cd "$RACINE" 2>/dev/null && pwd || echo "$RACINE")"
ETAT="$RACINE/.aegis"
[[ -d "$HOME/.cargo/bin" && ":$PATH:" != *":$HOME/.cargo/bin:"* ]] && PATH="$HOME/.cargo/bin:$PATH"

# ------------------------------------------------------------------ outils
outils_plateforme() { # une ligne JSON par outil applicable
  local o profil
  while IFS= read -r o; do
    profil="$(jq -r '.profil // ""' <<<"$o")"
    if [[ -n "$profil" ]] && ! etape_active "$profil"; then continue; fi
    printf '%s\n' "$o"
  done < <(jq -c --arg p "$OSKEY" '.outils[] | select(has($p))' "$MANIFESTE")
}
cmd_outil() { jq -r --arg p "$OSKEY" 'if (.commande|type)=="string" then .commande else .commande[$p] end' <<<"$1"; }
lire_version() {
  a "$1" || return 0
  "$1" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true
}
etat_outil() { # → "ok|ko<TAB>version<TAB>détail"
  local o="$1" cmd v majeur min
  cmd="$(cmd_outil "$o")"; v="$(lire_version "$cmd")"
  if [[ -z "$v" ]]; then
    if a "$cmd"; then printf 'ok\t?\tprésent\n'; else printf 'ko\t\tabsent\n'; fi
    return
  fi
  majeur="$(jq -r '.majeur // ""' <<<"$o")"; min="$(jq -r '.min // ""' <<<"$o")"
  if [[ -n "$majeur" ]]; then
    if [[ "${v%%.*}" == "$majeur" ]]; then printf 'ok\t%s\t%s (exigé : %s.x)\n' "$v" "$v" "$majeur"
    else printf 'ko\t%s\t%s (exigé : %s.x)\n' "$v" "$v" "$majeur"; fi
  elif [[ -n "$min" ]] && ! ver_ge "$v" "$min"; then printf 'ko\t%s\t%s (minimum %s)\n' "$v" "$v" "$min"
  else printf 'ok\t%s\t%s\n' "$v" "$v"; fi
}
installer_outil() {
  local o="$1" nom formule rustup conseil version
  nom="$(jq -r .nom <<<"$o")"; formule="$(jq -r '.linux.brew // ""' <<<"$o")"
  rustup="$(jq -r '.linux.rustup // false' <<<"$o")"; conseil="$(jq -r '.linux.conseil // ""' <<<"$o")"
  version="$(etat_outil "$o" | cut -f2)"
  if [[ "$(jq -r .id <<<"$o")" == node && -n "$version" ]] && ! brew list --versions "$formule" >/dev/null 2>&1; then
    note erreur outils "$nom" "Node $version installé hors Homebrew, Node $(jq -r .majeur <<<"$o") exigé" "désinstallez-le ou mettez $(brew --prefix 2>/dev/null)/opt/$formule/bin en tête du PATH"
    return
  fi
  if [[ "$rustup" == true ]]; then
    faire "rustup (sh.rustup.rs, dans ~/.cargo)" bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable"
    PATH="$HOME/.cargo/bin:$PATH"
  elif [[ -n "$formule" ]]; then
    a brew || { note erreur outils "$nom" 'Homebrew absent' 'https://brew.sh (préinstallé sur Bluefin)'; return; }
    if brew list --versions "$formule" >/dev/null 2>&1; then faire "brew upgrade $formule" brew upgrade "$formule" || true
    else faire "brew install $formule" brew install "$formule"; fi
    if [[ "$formule" == node@* ]]; then
      brew list --versions node >/dev/null 2>&1 && faire 'brew unlink node' brew unlink node
      faire "brew link $formule" brew link --overwrite --force "$formule"
    fi
    hash -r
  else
    note avert outils "$nom" 'à installer à la main' "$conseil"
  fi
}

install_outils() {
  titre 'Outils (Homebrew, rustup)'
  if [[ "$PLATEFORME" != linux ]]; then note erreur outils 'plateforme' 'Git Bash détecté' 'sous Windows : pwsh .github/poste/aegis.ps1 install'; return; fi
  (( BLUEFIN )) && dire "Bluefin détecté : outils dans Homebrew et ~/.cargo, rien dans l'image système."
  local o e nom requis
  while IFS= read -r o; do
    nom="$(jq -r .nom <<<"$o")"; requis="$(jq -r .requis <<<"$o")"
    e="$(etat_outil "$o")"
    if [[ "${e%%$'\t'*}" == ok ]]; then note ok outils "$nom" "$(cut -f3 <<<"$e")"; continue; fi
    installer_outil "$o"
    (( SIMULATION )) && continue
    e="$(etat_outil "$o")"
    if [[ "${e%%$'\t'*}" == ok ]]; then note ok outils "$nom" "$(cut -f3 <<<"$e")"
    elif [[ "$requis" == true ]]; then note erreur outils "$nom" "$(cut -f3 <<<"$e")" "$(jq -r '.linux.conseil // "ouvrez un nouveau terminal puis relancez install"' <<<"$o")"
    else note avert outils "$nom" "$(cut -f3 <<<"$e")" "$(jq -r '.linux.conseil // ""' <<<"$o")"; fi
  done < <(outils_plateforme)
}
update_outils() {
  titre 'Mise à niveau des outils (brew, rustup)'
  [[ "$PLATEFORME" == linux ]] || { dire 'Git Bash : passez par aegis.ps1 update --outils'; return; }
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    brew list --versions "$f" >/dev/null 2>&1 && faire "brew upgrade $f" brew upgrade "$f" || true
  done < <(outils_plateforme | jq -r '.linux.brew // empty')
  a rustup && { faire 'rustup update' rustup update || true; }
}

# ------------------------------------------------------------------ GitHub
install_github() {
  titre 'GitHub'
  if gh auth status >/dev/null 2>&1; then note ok github 'gh connecté'; return; fi
  if (( NON_INTERACTIF )); then note erreur github 'gh non connecté' '' 'gh auth login --web'; return 1; fi
  faire 'gh auth login (navigateur)' gh auth login --hostname github.com --git-protocol https --web
  faire 'gh auth setup-git' gh auth setup-git
  local cle val
  for cle in user.name user.email; do
    [[ -n "$(git config --global "$cle" || true)" ]] && continue
    read -rp "  git $cle : " val
    [[ -z "$val" ]] || faire "git config --global $cle" git config --global "$cle" "$val"
  done
}

# ------------------------------------------------------------------ dépôts
etat_depot() { # → branche<TAB>modifiés<TAB>avance<TAB>retard<TAB>autocrlf
  local c="$1" br sale av=0 re=0 compte
  br="$(git -C "$c" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  sale="$(git -C "$c" status --porcelain 2>/dev/null | grep -c . || true)"
  if compte="$(git -C "$c" rev-list --left-right --count HEAD...origin/main 2>/dev/null)"; then read -r av re <<<"$compte"; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$br" "${sale:-0}" "$av" "$re" "$(git -C "$c" config core.autocrlf || echo '')"
}
install_depots() { # [maj]
  local maj="${1:-}" nom c e br sale re config=()
  titre "Dépôts $ORG dans $RACINE"
  while IFS= read -r e; do config+=(-c "$e"); done < <(m '.clone.config[]')
  while IFS= read -r nom; do
    c="$RACINE/$nom"
    if [[ -d "$c/.git" ]]; then
      faire "git fetch $nom" git -C "$c" fetch --prune --quiet || true
      if (( SIMULATION )); then note info depots "$nom" présent; continue; fi
      IFS=$'\t' read -r br sale _ re _ < <(etat_depot "$c")
      if [[ -n "$maj" && "$br" == main && "$sale" == 0 && "$re" -gt 0 ]]; then
        git -C "$c" merge --ff-only --quiet origin/main
        note ok depots "$nom" "main avancée de $re commit(s)"
      elif [[ "$br" != main ]]; then note info depots "$nom" "branche $br (retard $re sur origin/main), laissée telle quelle"
      elif [[ "$sale" != 0 && "$re" -gt 0 ]]; then note avert depots "$nom" "main en retard de $re, $sale fichier(s) modifié(s) : pas d'avance automatique"
      else note ok depots "$nom" "$br, à jour"; fi
    elif [[ -d "$c" && -n "$(ls -A "$c" 2>/dev/null)" ]]; then
      note avert depots "$nom" "$c existe et n'est pas un clone : ignoré"
    else
      faire "clone de $ORG/$nom (LF)" gh repo clone "$ORG/$nom" "$c" -- "${config[@]}" --quiet
      (( SIMULATION )) || note ok depots "$nom" cloné
    fi
  done < <(m '.depots[].nom')
}

# ------------------------------------------------------------------ racine (copies suivies par empreinte)
empreinte() { sha256sum "$1" | cut -d' ' -f1; }
empreinte_connue() { [[ -f "$ETAT/empreintes" ]] && awk -F'\t' -v k="$1" '$1==k {print $2}' "$ETAT/empreintes" || true; }
retenir_empreinte() {
  mkdir -p "$ETAT"; touch "$ETAT/empreintes"
  { awk -F'\t' -v k="$1" '$1!=k' "$ETAT/empreintes"; printf '%s\t%s\n' "$1" "$2"; } | sort > "$ETAT/empreintes.tmp"
  mv "$ETAT/empreintes.tmp" "$ETAT/empreintes"
}
fichiers_racine() { # → source absolue<TAB>cible, modèles puis kit de hq s'il est cloné
  m '.racine.fichiers[] | [.source, .cible] | @tsv' | while IFS=$'\t' read -r src cible; do printf '%s\t%s\n' "$ICI/$src" "$cible"; done
  local kit; kit="$RACINE/$(m .racine.kit_source)"
  [[ ! -f "$kit" ]] || printf '%s\t%s\n' "$kit" "$(m .racine.kit)"
}
install_racine() {
  titre "Racine de l'atelier"
  local src dst cible hs hd connue bak
  while IFS=$'\t' read -r src cible; do
    dst="$RACINE/$cible"; hs="$(empreinte "$src")"
    if [[ -f "$dst" ]]; then
      hd="$(empreinte "$dst")"; connue="$(empreinte_connue "$cible")"
      if [[ "$hd" == "$hs" ]]; then note ok racine "$cible" 'à jour'; (( SIMULATION )) || retenir_empreinte "$cible" "$hs"; continue; fi
      if [[ "$connue" != "$hd" ]]; then
        bak="$dst.bak-$(date +%Y%m%d-%H%M%S)"
        faire "sauvegarde de $cible (modifié à la main ou antérieur) → $(basename "$bak")" cp -p "$dst" "$bak"
      fi
    fi
    faire "pose de $cible" install -D -m 0644 "$src" "$dst"
    (( SIMULATION )) || { retenir_empreinte "$cible" "$hs"; note ok racine "$cible" posé; }
  done < <(fichiers_racine)
}

# ------------------------------------------------------------------ npm
install_npm() { # [maj]
  local maj="${1:-}" d c lock marque o
  titre 'Atelier npm'
  o="$(jq -c '.outils[] | select(.id=="node")' "$MANIFESTE")"
  if [[ "$(etat_outil "$o" | cut -f1)" != ok ]]; then note erreur npm Node "Node $(jq -r .majeur <<<"$o") absent : étape ignorée" 'aegis.sh install --seulement outils'; return; fi
  if [[ ! -f "$RACINE/package.json" ]]; then
    [[ -f "$RACINE/heimdall/outils/kit.mjs" ]] || { note avert npm atelier 'heimdall absent : atelier non créé'; return; }
    faire "package.json d'atelier (heimdall/outils/kit.mjs atelier)" node "$RACINE/heimdall/outils/kit.mjs" atelier --dossier "$RACINE"
  fi
  faire 'npm install (atelier : syn + heimdall)' npm --prefix "$RACINE" install --no-audit --no-fund --loglevel=error
  while IFS= read -r d; do
    [[ -f "$RACINE/$d/package.json" ]] && faire "npm run build ($d)" bash -c "cd '$RACINE/$d' && npm run build --silent"
  done < <(m '.npm.construire[]')
  while IFS= read -r d; do
    c="$RACINE/$d"; lock="$c/package-lock.json"; marque="$c/node_modules/.package-lock.json"
    [[ -f "$lock" ]] || continue
    if [[ -n "$maj" && -f "$marque" && ! "$lock" -nt "$marque" ]]; then note ok npm "$d" 'node_modules à jour'; continue; fi
    faire "npm ci ($d)" bash -c "cd '$c' && npm ci --no-audit --no-fund --loglevel=error"
  done < <(m '.npm.ci[]')
  (( SIMULATION )) || note ok npm atelier 'installé et construit'
}

# ------------------------------------------------------------------ Rust
install_rust() {
  titre 'Chaîne Rust'
  a rustup || { note erreur rust rustup absent 'aegis.sh install --seulement outils'; return; }
  rustup default 2>/dev/null | grep -qv 'no default' || faire 'rustup default stable' rustup default stable
  local t k crate cmd installees comps
  installees="$(rustup target list --installed 2>/dev/null || true)"
  while IFS= read -r t; do
    if grep -qx "$t" <<<"$installees"; then note ok rust "cible $t" installée; else faire "rustup target add $t" rustup target add "$t"; fi
  done < <(m '.rust.cibles[]')
  comps="$(rustup component list --installed 2>/dev/null || true)"
  while IFS= read -r k; do
    if grep -q "^$k-" <<<"$comps"; then note ok rust "$k" installé; else faire "rustup component add $k" rustup component add "$k"; fi
  done < <(m '.rust.composants[]')
  while IFS=$'\t' read -r crate cmd; do
    if a "$cmd"; then note ok rust "$crate" installé; else faire "cargo install $crate --locked (quelques minutes)" cargo install "$crate" --locked; fi
  done < <(m '.rust.cargo_install[] | [.crate, .commande] | @tsv')
}

# ------------------------------------------------------------------ VS Code
CODE=()
if a code; then CODE=(code); elif a code-insiders; then CODE=(code-insiders)
elif a flatpak && flatpak info com.visualstudio.code >/dev/null 2>&1; then CODE=(flatpak run com.visualstudio.code); fi
extensions_manquantes() {
  local presentes
  presentes="$("${CODE[@]}" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  m '.vscode.extensions[]' | while IFS= read -r x; do grep -qx "${x,,}" <<<"$presentes" || echo "$x"; done
}
conseil_code() { if (( BLUEFIN )); then echo 'ujust devmode (VS Code et conteneurs de dev), ou flatpak install flathub com.visualstudio.code'; else echo 'https://code.visualstudio.com'; fi; }
install_vscode() {
  titre 'VS Code'
  if (( ${#CODE[@]} == 0 )); then note avert vscode code 'absent : extensions non installées' "$(conseil_code)"; return; fi
  local manq x; manq="$(extensions_manquantes)"
  [[ -z "$manq" ]] && note ok vscode extensions "$(m '.vscode.extensions | length') présentes"
  while IFS= read -r x; do [[ -z "$x" ]] || faire "extension $x" "${CODE[@]}" --install-extension "$x" || true; done <<<"$manq"
  dire "Ouvrir : ${CODE[*]} \"$RACINE/aegis.code-workspace\""
}

# ------------------------------------------------------------------ skills de mimir
dossier_skills() { echo "${CLAUDE_SKILLS:-$HOME/.claude/skills}"; }
install_skills() {
  titre 'Skills de mimir (Claude Code)'
  if [[ "$PLATEFORME" != linux ]]; then dire 'Git Bash : les jonctions sont posées par aegis.ps1'; return; fi
  [[ -x "$RACINE/mimir/outils/installer.sh" || -f "$RACINE/mimir/outils/installer.sh" ]] || { note avert skills mimir 'absent : skills non liées'; return; }
  faire 'mimir/outils/installer.sh' bash "$RACINE/mimir/outils/installer.sh"
}

# ------------------------------------------------------------------ guide
port_ecoute() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
ouvrir() { if [[ "$PLATEFORME" == msys ]]; then start "" "$1"; elif a xdg-open; then xdg-open "$1" >/dev/null 2>&1 & else echo "$1"; fi; }
ouvrir_guide() {
  local kit; kit="$(m .racine.kit)"
  if [[ -f "$RACINE/$kit" ]]; then
    if ! port_ecoute 7480; then
      local py=python3; a python3 || py=python
      (cd "$RACINE" && nohup "$py" -m http.server 7480 --bind 127.0.0.1 >/dev/null 2>&1 &)
      sleep 1
    fi
    ouvrir "http://127.0.0.1:7480/$kit"; echo "Kit : http://127.0.0.1:7480/$kit (serveur en arrière-plan sur 127.0.0.1:7480)"
  else
    local readme="$RACINE/README.md"; [[ -f "$readme" ]] || readme="$ICI/README.md"
    if (( ${#CODE[@]} )); then "${CODE[@]}" "$readme"; else ouvrir "$readme"; fi
    echo "Guide : $readme (pas de $kit à la racine)"
  fi
}

# ------------------------------------------------------------------ doctor
doctor() {
  local o e nom requis conseil c br sale re crlf f src cible n x
  titre Système
  note info systeme "$PLATEFORME" "$( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}") || uname -sr)$( (( BLUEFIN )) && echo ' (Bluefin)')"
  note info systeme racine "$RACINE"
  [[ "$PLATEFORME" != linux ]] || { if a brew; then note ok systeme Homebrew "$(brew --version | head -1)"; else note erreur systeme Homebrew absent 'https://brew.sh'; fi; }

  titre Outils
  while IFS= read -r o; do
    nom="$(jq -r .nom <<<"$o")"; requis="$(jq -r .requis <<<"$o")"; e="$(etat_outil "$o")"
    conseil="$(jq -r '.linux.conseil // "aegis.sh install --seulement outils"' <<<"$o")"
    if [[ "${e%%$'\t'*}" == ok ]]; then note ok outils "$nom" "$(cut -f3 <<<"$e")"
    elif [[ "$requis" == true ]]; then note erreur outils "$nom" "$(cut -f3 <<<"$e")" "$conseil"
    else note avert outils "$nom" "$(cut -f3 <<<"$e")" "$( [[ "$(jq -r .id <<<"$o")" == code ]] && conseil_code || echo "$conseil")"; fi
  done < <(outils_plateforme)
  if etape_active rust && a rustup; then
    local installees; installees="$(rustup target list --installed 2>/dev/null || true)"
    while IFS= read -r x; do
      if grep -qx "$x" <<<"$installees"; then note ok rust "cible $x"; else note avert rust "cible $x" absente 'aegis.sh install --seulement rust'; fi
    done < <(m '.rust.cibles[]')
    while IFS=$'\t' read -r x c; do
      if a "$c"; then note ok rust "$x"; else note avert rust "$x" absent 'aegis.sh install --seulement rust'; fi
    done < <(m '.rust.cargo_install[] | [.crate, .commande] | @tsv')
  fi

  titre GitHub
  local auth; if auth="$(gh auth status 2>&1)"; then
    note ok github 'gh connecté' "$(grep -oE 'account [^ ]+' <<<"$auth" | head -1 | cut -d' ' -f2)"
    grep -q 'read:packages' <<<"$auth" || note info github 'scope read:packages' "absent (inutile avec l'atelier npm)" 'gh auth refresh -s read:packages'
  else note erreur github 'gh connecté' non 'gh auth login --web'; fi
  for x in user.name user.email; do
    if [[ -n "$(git config --global "$x" || true)" ]]; then note ok github "git $x"; else note avert github "git $x" absent "git config --global $x …"; fi
  done

  titre Clones
  while IFS= read -r nom; do
    c="$RACINE/$nom"
    if [[ ! -d "$c/.git" ]]; then note erreur depots "$nom" absent 'aegis.sh install --seulement depots'; continue; fi
    IFS=$'\t' read -r br sale _ re crlf < <(etat_depot "$c")
    local txt="$br"; [[ "$re" == 0 ]] || txt+=", retard $re sur origin/main"; [[ "$sale" == 0 ]] || txt+=", $sale modifié(s)"
    if [[ "$br" == main && "$re" == 0 ]]; then note ok depots "$nom" "$txt"; else note info depots "$nom" "$txt"; fi
    [[ "$crlf" != true ]] || note avert depots "$nom : fins de ligne" 'clone CRLF (core.autocrlf=true)' 'nocturne et synchro-contrats exigent un clone LF : reclonez via aegis install'
  done < <(m '.depots[].nom')

  titre Racine
  while IFS=$'\t' read -r src cible; do
    f="$RACINE/$cible"
    if [[ ! -f "$f" ]]; then note avert racine "$cible" absent 'aegis.sh update'
    elif [[ "$(empreinte "$f")" == "$(empreinte "$src")" ]]; then note ok racine "$cible" 'à jour'
    else note avert racine "$cible" 'diffère du modèle' 'aegis.sh update (sauvegarde .bak si modifié à la main)'; fi
  done < <(fichiers_racine)
  if [[ -f "$RACINE/package.json" ]]; then note ok npm "package.json d'atelier"; else note avert npm "package.json d'atelier" absent; fi
  if [[ -d "$RACINE/node_modules" ]]; then note ok npm "node_modules d'atelier"; else note avert npm "node_modules d'atelier" absent; fi
  while IFS= read -r x; do
    n="$( { find "$RACINE/$x/packages" -mindepth 2 -maxdepth 2 -type d -name dist 2>/dev/null || true; } | wc -l | tr -d ' ')"
    if [[ "$n" -gt 0 ]]; then note ok npm "$x construit" "$n paquet(s) avec dist/"; else note avert npm "$x construit" '0 paquet avec dist/' 'aegis.sh install --seulement npm'; fi
  done < <(m '.npm.construire[]')
  while IFS= read -r x; do
    if [[ -d "$RACINE/$x/node_modules" ]]; then note ok npm "$x node_modules"; else note avert npm "$x node_modules" absent; fi
  done < <(m '.npm.ci[]')
  x="$(m .racine.kit)"
  if [[ -f "$RACINE/$x" ]]; then note ok racine "$x" 'kit détaillé présent'; else note info racine "$x" "absent : cloner hq ($(m .racine.kit_source)), sinon le guide ouvre README.md"; fi

  titre 'VS Code et Claude Code'
  if (( ${#CODE[@]} == 0 )); then note avert vscode code absent "$(conseil_code)"
  else
    local manq; manq="$(extensions_manquantes | paste -sd, - | sed 's/,/, /g')"
    if [[ -z "$manq" ]]; then note ok vscode extensions "$(m '.vscode.extensions | length') présentes"
    else note avert vscode extensions "manquantes : $manq" 'aegis.sh install --seulement vscode'; fi
  fi
  if [[ -d "$RACINE/mimir/skills" ]]; then
    local att=0 lie=0 s
    for s in "$RACINE"/mimir/skills/*/; do att=$((att + 1)); [[ -e "$(dossier_skills)/$(basename "$s")" ]] && lie=$((lie + 1)); done
    if [[ $att == "$lie" ]]; then note ok skills 'skills de mimir' "$lie/$att liées"; else note avert skills 'skills de mimir' "$lie/$att liées" 'aegis.sh install --seulement skills'; fi
  fi
  while IFS= read -r x; do
    if port_ecoute "$x"; then note info ports "port $x" occupé; else note ok ports "port $x" libre; fi
  done < <(m '.ports[]')
}

afficher_bilan() { # → code de sortie
  local err=0 av=0
  err="$(printf '%s\n' ${BILAN[@]+"${BILAN[@]}"} | grep -c '^erreur' || true)"
  av="$(printf '%s\n' ${BILAN[@]+"${BILAN[@]}"} | grep -c '^avert' || true)"
  if (( JSON )); then
    printf '%s\n' ${BILAN[@]+"${BILAN[@]}"} | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {statut: .[0], groupe: .[1], nom: .[2], detail: (.[3] // ""), conseil: (.[4] // "")})'
  else
    local couleur=$C_OK; (( av )) && couleur=$C_AV; (( err )) && couleur=$C_ER
    printf '\n%sBilan : %s erreur(s), %s avertissement(s).%s\n' "$couleur" "$err" "$av" "$C_0"
  fi
  (( err == 0 ))
}

# ------------------------------------------------------------------ entrée
relancer_si_change() { # tête avant
  local c="$RACINE/.github" apres
  (( RELANCE )) || [[ ! -d "$c/.git" ]] && return 0
  apres="$(git -C "$c" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$1" && "$apres" != "$1" && "$ICI" == "$c"/* ]]; then
    dire 'Le bootstrap a changé : relance avec la nouvelle version.'
    exec bash "$ICI/aegis.sh" "${ARGS_ORIGINE[@]}" --relance
  fi
}

case "$COMMANDE" in
  install)
    printf '%sAEGIS — installation du poste dans %s%s%s\n' "$C_T" "$RACINE" "$( (( SIMULATION )) && echo ' (simulation)')" "$C_0"
    if etape_active outils; then install_outils; fi
    if etape_active github; then install_github; fi
    if etape_active depots; then install_depots; fi
    if etape_active racine; then install_racine; fi
    if etape_active npm; then install_npm; fi
    if etape_active rust; then install_rust; fi
    if etape_active vscode; then install_vscode; fi
    if etape_active skills; then install_skills; fi
    BILAN=(); doctor; afficher_bilan ;;
  update)
    printf '%sAEGIS — mise à jour du poste dans %s%s%s\n' "$C_T" "$RACINE" "$( (( SIMULATION )) && echo ' (simulation)')" "$C_0"
    tete="$(git -C "$RACINE/.github" rev-parse HEAD 2>/dev/null || true)"
    if etape_active depots; then install_depots maj; relancer_si_change "$tete"; fi
    if (( OUTILS )) && etape_active outils; then update_outils; fi
    if etape_active racine; then install_racine; fi
    if etape_active npm; then install_npm maj; fi
    if etape_active vscode; then install_vscode; fi
    if etape_active skills; then install_skills; fi
    BILAN=(); doctor; afficher_bilan ;;
  doctor) doctor; afficher_bilan ;;
  guide) ouvrir_guide ;;
  aide) aide ;;
  *) aide; exit 2 ;;
esac
