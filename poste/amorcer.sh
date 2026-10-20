#!/usr/bin/env bash
# Amorce d'un poste Linux AEGIS (Bluefin en premier lieu), sur une machine neuve.
#   curl -fsSL https://raw.githubusercontent.com/calahan-io/.github/main/poste/amorcer.sh | bash
#   curl -fsSL …/amorcer.sh | bash -s -- --sans rust        # options passées à « aegis.sh install »
# Variable facultative : AEGIS_RACINE (défaut : ~/AEGIS-CORP).
# Installe git, gh et jq par Homebrew s'ils manquent, clone calahan-io/.github (public), puis passe la main à
# poste/aegis.sh install. Rien n'est installé dans l'image système (Bluefin est immuable). Relancer est sans danger.
set -Eeuo pipefail
racine="${AEGIS_RACINE:-$HOME/AEGIS-CORP}"
entree="$racine/.github"

echo "AEGIS — amorce du poste dans $racine"
if ! command -v brew >/dev/null 2>&1; then
  for b in /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do [[ -x "$b" ]] && eval "$("$b" shellenv)" && break; done
fi
command -v brew >/dev/null 2>&1 || { echo "Homebrew est absent (préinstallé sur Bluefin) : https://brew.sh, puis relancez." >&2; exit 1; }
for o in git gh jq; do
  if command -v "$o" >/dev/null 2>&1; then echo "  ✔ $o"; else echo "  … brew install $o"; brew install "$o"; fi
done

if [[ -d "$entree/.git" ]]; then
  echo "  … mise à jour de $entree"; git -C "$entree" pull --ff-only --quiet
else
  mkdir -p "$racine"
  echo "  … clone de calahan-io/.github (LF)"
  git clone -c core.autocrlf=false -c core.eol=lf --quiet https://github.com/calahan-io/.github.git "$entree"
fi

# Lancé par « curl | bash », l'entrée standard est le tube : on rend le terminal à aegis.sh (gh auth login).
if [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; then
  exec bash "$entree/poste/aegis.sh" install --racine "$racine" "$@" </dev/tty
fi
exec bash "$entree/poste/aegis.sh" install --racine "$racine" "$@"
