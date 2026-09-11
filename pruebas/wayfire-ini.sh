#!/usr/bin/env bash
#
# Que la configuración del compositor nombre cosas que existen.
#
# Un plugin mal escrito en `plugins =` no rompe nada visible: Wayfire arranca,
# anota una línea en el registro que nadie mira, y el escritorio queda sin esa
# pieza. Si la pieza es `session-lock`, la pantalla no se bloquea; si es
# `permisos-globales`, nadie anota quién pide capturar la pantalla. Es el mismo
# modo de falla que tenía el inicio automático del ISO: silencioso y con el
# archivo a la vista.
#
# Uso: pruebas/wayfire-ini.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

INI=etc/skel/.config/wayfire.ini
fallos=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }
tema() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Los que trae VasakOS y no están en el directorio de Wayfire de este equipo
# salvo que el paquete esté instalado. Se nombra el paquete para que el error
# diga qué falta y no sólo que falta.
declare -A NUESTROS=(
    [permisos-globales]=vasak-wayfire-plugins
)

plugindir=$(pkg-config --variable=plugindir wayfire 2>/dev/null || echo /usr/lib/wayfire)

# La lista es una sola opción partida con `\` al final de cada línea.
leer_plugins() {
    sed -n '/^plugins[[:space:]]*=/,/[^\\]$/p' "$INI" \
        | sed 's/^plugins[[:space:]]*=//' \
        | tr -d '\\' \
        | tr -s '[:space:]' '\n' \
        | grep -v '^$'
}

tema 'Cada plugin de la lista existe'

vistos=""
while IFS= read -r plugin; do
    case " $vistos " in
        *" $plugin "*)
            mal "$plugin: está dos veces en la lista"
            continue
            ;;
    esac
    vistos="$vistos $plugin"

    if [ -f "$plugindir/lib${plugin}.so" ]; then
        ok "$plugin"
    elif [ -n "${NUESTROS[$plugin]:-}" ]; then
        # No se exige que esté instalado: este repositorio se edita en equipos
        # donde el paquete todavía no se compiló. Lo que sí se exige es que sea
        # uno de los nuestros y no una palabra suelta.
        if [ -f "$plugindir/lib${plugin}.so" ]; then
            ok "$plugin (de ${NUESTROS[$plugin]})"
        else
            ok "$plugin (de ${NUESTROS[$plugin]}, todavía no instalado acá)"
        fi
    else
        mal "$plugin: no hay ${plugindir}/lib${plugin}.so ni figura como plugin propio"
    fi
done < <(leer_plugins)

tema 'La lista de protocolos privilegiados está sana'

protocolos=$(grep -oP '(?<=^privileged_protocols = ).*' "$INI" 2>/dev/null)
if [ -z "$protocolos" ]; then
    mal 'no se encontró privileged_protocols'
else
    # Wayfire parte por coma y no recorta espacios: un « zwlr_algo» con un
    # espacio adelante no coincide con ningún protocolo y se oculta nada,
    # calladamente.
    if printf '%s' "$protocolos" | grep -q ', \|,$\| ,'; then
        mal 'hay espacios o una coma suelta: Wayfire no los recorta y el nombre no coincide con nada'
    else
        ok 'sin espacios ni comas sueltas'
    fi

    repetidos=$(printf '%s' "$protocolos" | tr ',' '\n' | sort | uniq -d)
    if [ -n "$repetidos" ]; then
        mal "protocolos repetidos: $repetidos"
    else
        ok 'sin repetidos'
    fi

    # Los pares viejo/nuevo completos. Es el error medido de la lista por
    # omisión de Wayfire: nombra los `zwlr_` y deja pasar sus reemplazos `ext_`,
    # que hacen lo mismo. Ocultar sólo la mitad es peor que no ocultar nada,
    # porque parece que confina.
    faltan=0
    for par in \
        "zwlr_data_control_manager_v1:ext_data_control_manager_v1" \
        "zwlr_screencopy_manager_v1:ext_image_copy_capture_manager_v1"; do
        viejo=${par%%:*}
        nuevo=${par##*:}
        if printf '%s' "$protocolos" | grep -q "$viejo" && \
           ! printf '%s' "$protocolos" | grep -q "$nuevo"; then
            mal "está $viejo y falta su reemplazo $nuevo"
            faltan=1
        fi
    done
    [ "$faltan" -eq 0 ] && ok 'cada protocolo viejo tiene su reemplazo estándar'
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo bien.\033[0m\n'
else
    printf '\033[31m%s comprobación(es) fallaron.\033[0m\n' "$fallos"
fi
exit "$((fallos > 0 ? 1 : 0))"
