#!/usr/bin/env bash
# Hook PreToolUse (matcher Bash): impide que un `git commit` meta en el
# repositorio claves, correos de personas reales o un fichero `.env`.
#
# Lee el JSON del harness por la entrada estándar. Solo actúa si el comando
# contiene `git commit`. Mira las líneas AÑADIDAS del diff preparado y, si el
# mismo comando hace también `git add`, las de los cambios sin preparar y los
# ficheros nuevos sin seguimiento.
#
# Si algo salta: sale con 2 (el harness bloquea el comando), explica por la
# salida de error qué regla y en qué archivo, y deja UNA línea en
# docs/seguridad/registro-de-bloqueos.md. Nunca escribe el valor encontrado.
set -uo pipefail

entrada=$(cat)
comando=$(printf '%s' "$entrada" | jq -r '.tool_input.command // empty')

[[ "$comando" == *"git commit"* ]] || exit 0

dir=$(printf '%s' "$entrada" | jq -r '.cwd // empty')
cd "${dir:-${CLAUDE_PROJECT_DIR:-.}}" 2>/dev/null || exit 0
raiz=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$raiz" || exit 0

con_add=0
[[ "$comando" == *"git add"* ]] && con_add=1

# --- Qué entra: "archivo<TAB>línea añadida" y la lista de archivos ---------

lineas_de_diff() {
  # $@: argumentos extra de git diff (--cached o nada)
  git -c core.quotepath=off diff "$@" --unified=0 --no-color --no-ext-diff --diff-filter=d |
    awk '/^\+\+\+ /{ f = substr($0, 7); next } /^\+/{ print f "\t" substr($0, 2) }'
}

archivos_nuevos() {
  git -c core.quotepath=off ls-files --others --exclude-standard
}

anadidas=$(
  lineas_de_diff --cached
  if ((con_add)); then
    lineas_de_diff
    archivos_nuevos | while IFS= read -r f; do
      [[ -f "$f" ]] && grep -Iq . "$f" 2>/dev/null || continue
      awk -v f="$f" '{ print f "\t" $0 }' "$f"
    done
  fi
)

archivos=$(
  git -c core.quotepath=off diff --cached --name-only --diff-filter=d
  if ((con_add)); then
    git -c core.quotepath=off diff --name-only --diff-filter=d
    archivos_nuevos
  fi
)

# --- Reglas -----------------------------------------------------------------

hallazgos=() # "regla<TAB>archivo", sin el valor

anota() {
  local regla=$1 archivo=$2 h
  for h in "${hallazgos[@]+"${hallazgos[@]}"}"; do
    [[ "$h" == "$regla"$'\t'"$archivo" ]] && return
  done
  hallazgos+=("$regla"$'\t'"$archivo")
}

# Cada línea de $anadidas es "archivo<TAB>contenido": los patrones se anclan
# detrás del primer tabulador para no mirar el nombre del archivo, y se pasa
# un solo grep sobre todo el diff (uno por línea sería lento en un lockfile).
tab=$'\t'

# Regla 1: claves con forma reconocible.
clave='AKIA[0-9A-Z]{16}|sk-ant-[A-Za-z0-9_-]+|ghp_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|AIza[0-9A-Za-z_-]{35}|xox[bpa]-[A-Za-z0-9-]+|-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----'
app_key="[[:space:]]*(export[[:space:]]+)?APP_KEY[[:space:]]*=[[:space:]]*([\"'][^\"']+|[^\"'[:space:]#])"

while IFS= read -r archivo; do
  [[ -n "$archivo" ]] && anota "1-clave" "$archivo"
done < <(printf '%s\n' "$anadidas" |
  grep -E -- "^[^$tab]*$tab(.*($clave)|$app_key)" | cut -f1 | sort -u)

# Regla 2: correos cuyo dominio no es de ejemplo.
correo='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
while IFS=$'\t' read -r archivo linea; do
  [[ -n "$archivo" ]] || continue
  while IFS= read -r direccion; do
    [[ -n "$direccion" ]] || continue
    dominio=$(printf '%s' "${direccion##*@}" | tr '[:upper:]' '[:lower:]')
    case "$dominio" in
      example.com | example.org | example.net | github.com) ;;
      *) anota "2-correo" "$archivo" ;;
    esac
  done < <(printf '%s\n' "$linea" | grep -Eo -- "$correo")
done < <(printf '%s\n' "$anadidas" | grep -E -- "^[^$tab]*$tab.*$correo")

# Regla 3: un fichero llamado exactamente `.env`.
while IFS= read -r archivo; do
  [[ -n "$archivo" ]] || continue
  [[ "$(basename -- "$archivo")" == ".env" ]] && anota "3-env" "$archivo"
done <<<"$archivos"
# Un `.env` ignorado que se fuerza con `git add -f` en el mismo comando no
# sale en estas listas. No se intenta adivinar leyendo el texto del comando:
# ese texto incluye el mensaje del commit, y una mención a ".env" en el
# mensaje bloqueaba commits limpios. Se cubre con el siguiente commit: el
# .env ya estará en el índice.

# --- Resultado --------------------------------------------------------------

((${#hallazgos[@]})) || exit 0

explica() {
  case "$1" in
    1-clave) echo "una clave o token con forma reconocible (o APP_KEY con valor)" ;;
    2-correo) echo "una dirección de correo con un dominio que no es de ejemplo" ;;
    3-env) echo "un fichero .env" ;;
  esac
}

{
  echo "BLOQUEADO por .claude/hooks/datos-que-no-salen.sh: este commit metería en el repositorio:"
  for h in "${hallazgos[@]}"; do
    IFS=$'\t' read -r regla archivo <<<"$h"
    echo "  - regla $regla, $(explica "$regla"), en $archivo"
  done
  echo "Sustituye el dato por uno inventado (correos con @example.com, claves de mentira"
  echo "sin la forma real, nada de .env: usa .env.example) y vuelve a intentarlo."
  echo "No desactives ni te saltes este hook."
} >&2

registro="docs/seguridad/registro-de-bloqueos.md"
mkdir -p "$(dirname "$registro")"
if [[ ! -f "$registro" ]]; then
  echo "# Registro de bloqueos del hook datos-que-no-salen (UTC · regla · archivo; nunca el valor)" >"$registro"
fi
detalle=""
for h in "${hallazgos[@]}"; do
  IFS=$'\t' read -r regla archivo <<<"$h"
  detalle+="${detalle:+; }regla $regla en \`$archivo\`"
done
printf -- '- %s BLOQUEADO %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$detalle" >>"$registro"

exit 2
