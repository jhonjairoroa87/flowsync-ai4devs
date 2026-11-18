#!/usr/bin/env bash
# Guardarraíl PreToolUse (matcher Bash): impide que un `git commit` saque del
# proyecto claves reconocibles, correos reales o un fichero .env, y deja una
# línea en docs/seguridad/registro-de-bloqueos.md cada vez que bloquea.
# La regla de proceso que lo acompaña está en CLAUDE.md ("Reglas de proceso").
#
# Ojo: los patrones están escritos de forma que este fichero no se bloquee a sí
# mismo (cada prefijo va seguido de una clase de caracteres, no del literal).
set -uo pipefail

entrada=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$entrada")

# Solo actúa ante un commit. Cualquier otro comando: 0 y en silencio.
grep -qE 'git[[:space:]]+commit' <<<"$cmd" || exit 0

dir=${CLAUDE_PROJECT_DIR:-$(jq -r '.cwd // empty' <<<"$entrada")}
raiz=$(git -C "${dir:-.}" rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$raiz" || exit 0

# ¿El mismo comando prepara cambios que aún no están en el índice?
con_add=0
con_a=0
grep -qE 'git[[:space:]]+add' <<<"$cmd" && con_add=1
grep -qE 'git[[:space:]]+commit[^;&|]*[[:space:]](-[a-zA-Z]*a[a-zA-Z]*|--all)([[:space:]]|$)' <<<"$cmd" && con_a=1

g() { git -c core.quotePath=false "$@"; }
TAB=$'\t'

# Convierte un diff -U0 en líneas "ruta<TAB>contenido añadido".
anadidas_de_diff() {
  awk '/^\+\+\+ /{ f = $0; sub(/^\+\+\+ (b\/)?/, "", f); next }
       /^\+/     { print f "\t" substr($0, 2) }'
}

anadido=$(
  g diff --cached -U0 --no-color --no-ext-diff --diff-filter=ACMR | anadidas_de_diff
  if [ "$con_add" = 1 ] || [ "$con_a" = 1 ]; then
    g diff -U0 --no-color --no-ext-diff --diff-filter=ACMR | anadidas_de_diff
  fi
  if [ "$con_add" = 1 ]; then
    g ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
      grep -Iq . "$f" 2>/dev/null || continue # binario o vacío
      while IFS= read -r l || [ -n "$l" ]; do printf '%s\t%s\n' "$f" "$l"; done <"$f"
    done
  fi
)

nombres=$(
  g diff --cached --name-only --diff-filter=ACMR
  if [ "$con_add" = 1 ] || [ "$con_a" = 1 ]; then g diff --name-only --diff-filter=ACMR; fi
  if [ "$con_add" = 1 ]; then
    g ls-files --others --exclude-standard
    # Lo que se fuerza con `git add -f` en el mismo comando (un .env está ignorado).
    grep -oE 'git[[:space:]]+add[^;&|]*' <<<"$cmd" | grep -oE "[^[:space:]\"';&|]+"
  fi
)

hallazgos=()
anotar() { # $1 = regla; stdin = rutas
  local r
  while IFS= read -r r; do [ -n "$r" ] && hallazgos+=("$1: $r"); done
}

# Regla 1: clave con forma reconocible.
CLAVE='(AKIA[0-9A-Z]{16}|sk-ant-[A-Za-z0-9_-]{8,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z_-]{35}|xox[bpa]-[A-Za-z0-9-]{8,}|-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----)'
APPKEY="^[^${TAB}]*${TAB}[[:space:]]*(export[[:space:]]+)?APP_KEY[[:space:]]*=[[:space:]]*[\"']?[^[:space:]\"'#]"
anotar "regla 1 (clave reconocible)" < <(
  { grep -E "^[^${TAB}]*${TAB}.*${CLAVE}" <<<"$anadido"; grep -E "$APPKEY" <<<"$anadido"; } | cut -f1 | sort -u
)

# Regla 2: correo cuyo dominio no es de ejemplo.
CORREO='[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}'
anotar "regla 2 (correo real)" < <(
  grep -E "$CORREO" <<<"$anadido" | while IFS="$TAB" read -r ruta resto; do
    reales=$(grep -oE "$CORREO" <<<"$resto" | sed 's/.*@//' | tr '[:upper:]' '[:lower:]' |
      grep -vxE 'example\.(com|org|net)|github\.com')
    [ -n "$reales" ] && printf '%s\n' "$ruta"
  done | sort -u
)

# Regla 3: un fichero llamado exactamente .env entre lo que entra.
anotar "regla 3 (fichero .env)" < <(awk -F/ '$NF == ".env"' <<<"$nombres" | sort -u)

[ "${#hallazgos[@]}" -eq 0 ] && exit 0

{
  echo "BLOQUEADO por .claude/hooks/datos-que-no-salen.sh: este commit sacaría del proyecto un dato que no debe salir."
  printf '  - %s\n' "${hallazgos[@]}"
  echo "Sustituye el dato por uno inventado (correo @example.com, clave falsa sin prefijo real, nada de .env) y vuelve a intentarlo."
  echo "No desactives ni te saltes este hook."
} >&2

registro="docs/seguridad/registro-de-bloqueos.md"
mkdir -p "$(dirname "$registro")"
[ -f "$registro" ] || echo "# Registro de bloqueos del hook datos-que-no-salen (fecha UTC · BLOQUEADO · regla · archivo; nunca el valor)" >"$registro"
linea="- $(date -u +%Y-%m-%dT%H:%M:%SZ) BLOQUEADO"
for h in "${hallazgos[@]}"; do linea+=" ${h};"; done
echo "${linea%;}" >>"$registro"

exit 2
