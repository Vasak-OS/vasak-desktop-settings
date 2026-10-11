#!/bin/bash
# Que el texto de cada esquema de color se pueda leer sobre lo que va debajo.
#
# El esquema de fábrica traía en la variante clara `text.muted` = `#6c6f85`
# sobre un fondo `#eff1f5`: 4,37:1. WCAG 1.4.3 pide 4,5:1 para texto normal, y
# el texto «apagado» es justamente el de las etiquetas, las descripciones y los
# subtítulos, que suelen ir en letra chica. No lo notaba nadie porque en el
# tema oscuro, que es el que se mira casi siempre, el mismo papel da 7,37:1.
# (Vasak-OS/tauri-plugin-config-manager#31)
#
# Se recorren **todos** los esquemas de `usr/share/schemes/` y no sólo el de
# fábrica: un esquema nuevo trae el mismo problema el día que lo escribe alguien
# que no lo midió, y lo que lo frena es esta prueba, no la memoria.
#
# # Qué se exige, y por qué todo es fallo y no aviso
#
#   - `text.main` y `text.muted` contra `background`: 4,5:1.
#   - `text.on-primary` contra `color.primary`: 4,5:1.
#   - `text.on-secondary` contra `color.secondary`, si el esquema lo trae: 4,5:1.
#
# `muted` y `main` no los corrige nadie: el config-manager escribe
# `--text-muted` tal cual viene del esquema. Si no llegan, quien usa el sistema
# lee texto gris sobre gris y no hay nada abajo que lo salve.
#
# Los `on-*` sí tienen red: `textOn()` del config-manager reemplaza el
# `on-primary` que no llega y calcula `--text-on-secondary` sin mirar el del
# esquema. Pero la red no cubre todo: el gestor de sesión
# (`vasak-session-manager/src/composables/useAppearance.ts`) escribe
# `--text-on-primary` **crudo**, sin corregir, y es la pantalla de inicio de
# sesión. Un `on-primary` ilegible en el archivo es un botón ilegible ahí. Por
# eso también es fallo. El `on-secondary` hoy no lo lee crudo nadie, pero un
# valor que miente en el archivo es el que copia el próximo que lo lea; se le
# exige lo mismo.
#
# La luminancia es la de WCAG 2.1 (sRGB linealizado, umbral 0,03928), la misma
# fórmula que `contrast.ts` del config-manager, para que la prueba y lo que
# corre en el escritorio no discrepen por un redondeo.
#
# ⚠ Python con `-I`: no lee `PYTHON*` del entorno ni importa nada del
# directorio actual. Sólo usa `json` y `sys`, de la biblioteca estándar.
#
# Uso: pruebas/esquemas-legibles.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fallos=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }

ESQUEMAS=usr/share/schemes

printf '\n\033[1mLos esquemas de color se pueden leer\033[0m\n'

if ! command -v python3 >/dev/null 2>&1; then
    mal "falta python3: sin él no se puede medir el contraste"
    printf '\033[31mFallaron %d comprobaciones\033[0m\n' "$fallos" >&2
    exit 1
fi

shopt -s nullglob
archivos=("$ESQUEMAS"/*.json)
shopt -u nullglob

if [ ${#archivos[@]} -eq 0 ]; then
    # Que no haya esquemas no es «todo bien»: es que el escritorio arranca sin
    # colores. Una prueba que pasa porque no encontró nada no prueba nada.
    mal "no hay ningún esquema en $ESQUEMAS"
fi

# El cálculo va en Python y la presentación en bash: Python devuelve una línea
# por comprobación, «ok|mal<TAB>mensaje», y acá se pinta. Así el conteo de
# fallos vive en un solo lugar.
medir() {
    python3 -I - "$1" <<'PY'
import json
import sys

MINIMO = 4.5
ruta = sys.argv[1]


def salir(estado, mensaje):
    print(f"{estado}\t{mensaje}")


def luminancia(hexa):
    h = hexa.strip().lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    if len(h) != 6:
        return None
    try:
        canales = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    except ValueError:
        return None
    lin = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in canales]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


def contraste(a, b):
    la, lb = luminancia(a), luminancia(b)
    if la is None or lb is None:
        return None
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def tomar(d, *claves):
    for c in claves:
        if not isinstance(d, dict) or c not in d:
            return None
        d = d[c]
    return d if isinstance(d, str) else None


try:
    with open(ruta, encoding="utf-8") as f:
        esquema = json.load(f)
except (OSError, ValueError) as e:
    salir("mal", f"{ruta}: no se puede leer como JSON ({e})")
    sys.exit(0)

nombre = esquema.get("id", ruta) if isinstance(esquema, dict) else ruta
colores = esquema.get("colors") if isinstance(esquema, dict) else None

for variante in ("light", "dark"):
    ui = colores.get(variante, {}).get("ui") if isinstance(colores, dict) else None
    if not isinstance(ui, dict):
        salir("mal", f"{nombre} [{variante}]: no tiene colors.{variante}.ui")
        continue

    # (texto, fondo, obligatorio)
    pares = [
        ("text.main", "background", True),
        ("text.muted", "background", True),
        ("text.on-primary", "color.primary", True),
        ("text.on-secondary", "color.secondary", False),
    ]
    for texto, fondo, obligatorio in pares:
        t = tomar(ui, *texto.split("."))
        b = tomar(ui, *fondo.split("."))
        if t is None:
            if obligatorio:
                salir("mal", f"{nombre} [{variante}]: falta {texto}")
            continue
        if b is None:
            salir("mal", f"{nombre} [{variante}]: hay {texto} pero falta {fondo}")
            continue
        r = contraste(t, b)
        if r is None:
            salir("mal", f"{nombre} [{variante}]: {texto} «{t}» o {fondo} «{b}» no es un color #rrggbb")
            continue
        detalle = f"{nombre} [{variante}]: {texto} {t} sobre {fondo} {b} da {r:.2f}:1"
        if r >= MINIMO:
            salir("ok", detalle)
        else:
            salir("mal", f"{detalle}, y el mínimo es {MINIMO}:1")
PY
}

for archivo in "${archivos[@]}"; do
    printf '\n  \033[1m%s\033[0m\n' "$(basename "$archivo")"
    salida=$(medir "$archivo")
    if [ -z "$salida" ]; then
        mal "$archivo: la medición no devolvió nada (¿falló python3?)"
        continue
    fi
    while IFS=$'\t' read -r estado mensaje; do
        case $estado in
            ok)  ok "$mensaje" ;;
            mal) mal "$mensaje" ;;
            *)   mal "salida inesperada de la medición: $estado $mensaje" ;;
        esac
    done <<< "$salida"
done

printf '\n'
if [ $fallos -gt 0 ]; then
    printf '\033[31mFallaron %d comprobaciones\033[0m\n' "$fallos" >&2
    exit 1
fi
printf '\033[32mTodo bien: el texto de cada esquema llega a 4,5:1 sobre su fondo.\033[0m\n'
