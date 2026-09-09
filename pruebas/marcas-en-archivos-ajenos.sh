#!/bin/bash
# Que lo que le agregamos a archivos de otros paquetes se pueda sacar entero.
#
# El paquete le escribe una línea a dos archivos que no son suyos:
#
#   /etc/apparmor/parser.conf        `write-cache`, que ahorra 23 s de arranque
#   /etc/default/grub-btrfs/config   dónde buscar el kernel de cada instantánea
#
# Dos paquetes no pueden ser dueños del mismo archivo, así que la única forma es
# agregar y después sacar. Eso tiene dos maneras de salir mal, y las dos son
# silenciosas: agregar de nuevo en cada actualización —el archivo crece sin que
# nadie mire— o sacar de más y dejar el archivo del otro paquete roto.
#
# Las funciones de acá son una **copia** de las dos mitades del `.install`, no
# las de él: el `post_install` de verdad también prende servicios y escribe en
# /etc, así que no se puede correr. Una copia que se desincroniza es un test que
# aprueba código que ya no existe, así que abajo se comprueba además que las
# líneas que se copiaron sigan estando ahí, palabra por palabra.
set -uo pipefail

AQUI=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Desde el `check()` del PKGBUILD llega por variable, porque ahí el repositorio
# está clonado en `$srcdir` y el `.install` queda en otro lado. Corriéndolo a
# mano desde el árbol de trabajo, el camino relativo alcanza.
INSTALL=${VSK_INSTALL:-"$AQUI/../../PKGBUILDS/vasak-desktop-settings-git/vasak-desktop-settings.install"}

if [ ! -f "$INSTALL" ]; then
    echo "No está $INSTALL: se saltea." >&2
    echo "(El .install vive en el repositorio PKGBUILDS, que no siempre está al lado.)" >&2
    exit 0
fi

fallos=0
mal() { echo "  FALLA: $*" >&2; fallos=$((fallos + 1)); }
bien() { echo "  ok: $*"; }

# Las marcas, leídas del propio .install. Si alguien cambia el texto de una, el
# test sigue probando la de verdad — y si además se olvida de cambiarla en el
# post_remove, la comprobación de reversibilidad se cae, que es el punto.
eval "$(grep -E "^VSK_MARCA_(CACHE|ARRANQUE)=" "$INSTALL")"

if [ -z "${VSK_MARCA_CACHE:-}" ] || [ -z "${VSK_MARCA_ARRANQUE:-}" ]; then
    echo "FALLA: no se pudieron leer las marcas del .install" >&2
    exit 1
fi

# Lo que hace el .install con cada archivo, copiado de sus dos lados.
agregar_cache() {
    if [ -f "$1" ] && ! grep -qE '^[[:space:]]*write-cache[[:space:]]*$' "$1"; then
        printf '%s\nwrite-cache\n' "$VSK_MARCA_CACHE" >> "$1"
    fi
}
sacar_cache() { sed -i "\\|^$VSK_MARCA_CACHE\$|,+1d" "$1"; }

agregar_arranque() {
    if [ -f "$1" ] && ! grep -q "^$VSK_MARCA_ARRANQUE\$" "$1"; then
        printf '%s\nGRUB_BTRFS_BOOT_DIRNAME="/var/lib/vasak/arranque"\n' \
            "$VSK_MARCA_ARRANQUE" >> "$1"
    fi
}
sacar_arranque() { sed -i "\\|^$VSK_MARCA_ARRANQUE\$|,+1d" "$1"; }

probar() {
    local nombre=$1 agregar=$2 sacar=$3 contenido=$4 clave=$5
    local d f
    d=$(mktemp -d); f="$d/archivo"
    printf '%s' "$contenido" > "$f"
    cp "$f" "$d/original"

    echo "== $nombre =="

    # Tres veces, que es lo que pasa con tres actualizaciones del paquete.
    "$agregar" "$f"; "$agregar" "$f"; "$agregar" "$f"
    local n
    n=$(grep -c "^$clave" "$f")
    if [ "$n" = 1 ]; then bien "tres post_install dejan una sola línea"
    else mal "quedaron $n líneas de $clave"; fi

    # Y que el archivo siga siendo legible para quien lo lee de verdad: los dos
    # se leen con `.` desde un shell.
    if ! (. "$f") 2>/dev/null && [ "$clave" = "GRUB_BTRFS_BOOT_DIRNAME" ]; then
        mal "el archivo dejó de poder leerse como shell"
    fi

    "$sacar" "$f"
    if diff -q "$f" "$d/original" >/dev/null; then
        bien "post_remove lo deja byte por byte como estaba"
    else
        mal "quedó distinto:"; diff "$d/original" "$f" >&2
    fi

    # Sacar cuando no habíamos agregado nada no puede tocar el archivo: pasa
    # cuando alguien desinstala el paquete dos veces, o cuando el otro paquete
    # se reinstaló en el medio y volvió a su archivo original.
    "$sacar" "$f"
    if diff -q "$f" "$d/original" >/dev/null; then
        bien "sacar de más no rompe el archivo del otro paquete"
    else
        mal "un post_remove sin nada que sacar mutiló el archivo"
    fi
    rm -rf "$d"
}

probar "parser.conf, de apparmor" agregar_cache sacar_cache \
    '## comentario de apparmor
Optimize=compress-fast
' 'write-cache'

probar "config, de grub-btrfs" agregar_arranque sacar_arranque \
    '#GRUB_BTRFS_LIMIT="50"
GRUB_BTRFS_IGNORE_SPECIFIC_PATH=("@")
' 'GRUB_BTRFS_BOOT_DIRNAME'

echo "== las dos marcas se sacan en post_remove =="
# El olvido clásico: agregar una marca nueva y no sacarla. El archivo del otro
# paquete se queda con nuestra línea para siempre.
antes=$fallos
for marca in VSK_MARCA_CACHE VSK_MARCA_ARRANQUE; do
    if ! grep -q "sed -i .*\$$marca" "$INSTALL"; then
        mal "$marca se agrega y no se saca en post_remove"
    fi
done
[ $fallos -eq $antes ] && bien "las dos marcas tienen su borrado"

echo "== lo que se prueba acá es lo que el .install hace =="
# Sin esto, todo lo de arriba prueba una copia. El día que el `.install` cambie
# la forma de agregar —y ese es el día en que un test sirve— la copia seguiría
# en verde probando código que ya no existe.
#
# Se comparan las líneas que deciden, no el archivo entero: la guarda que evita
# duplicar y el `printf` que escribe.
antes=$fallos
esperadas=(
    '! grep -qE '"'"'^[[:space:]]*write-cache[[:space:]]*$'"'"' /etc/apparmor/parser.conf'
    "printf '%s\\nwrite-cache\\n' \"\$VSK_MARCA_CACHE\""
    '! grep -q "^$VSK_MARCA_ARRANQUE\$" /etc/default/grub-btrfs/config'
    'GRUB_BTRFS_BOOT_DIRNAME="/var/lib/vasak/arranque"'
)
for linea in "${esperadas[@]}"; do
    if ! grep -qF -- "$linea" "$INSTALL"; then
        mal "el .install ya no tiene: $linea"
    fi
done
[ $fallos -eq $antes ] && bien "las cuatro líneas copiadas siguen siendo las del .install"

if [ $fallos -gt 0 ]; then
    echo "FALLARON $fallos comprobaciones" >&2
    exit 1
fi
echo "Todo bien."
