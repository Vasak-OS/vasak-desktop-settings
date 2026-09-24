#!/usr/bin/env bash
#
# Que un programa cualquiera no pueda capturar la pantalla.
#
# Ésta es la mitad del problema que `security-context-v1` no cubre: ese
# protocolo sólo alcanza a los clientes que entran por un socket «en caja», y
# hoy no entra nadie por ahí. Un cliente normal le pide los protocolos
# privilegiados al compositor y el compositor se los da — medido: un proceso sin
# ningún privilegio sacó una captura entera con `grim`. Quien cierra esa vía es
# el plugin `permisos-globales`, que ofrece esos protocolos **sólo** a los
# programas del escritorio que los usan.
#
# Lo que se comprueba es que siga cerrada. Hoy `wayfire-ini.sh` mira que el
# plugin esté nombrado en `plugins =`, que es necesario y no alcanza: con
# `solo_anotar = true` el plugin está cargado, anota en el diario y no niega
# nada, y la sesión se ve exactamente igual.
#
# # Lo que se comprueba en vivo, y por qué no alcanza con leer archivos
#
# El filtro corre en el compositor. Que la configuración diga lo correcto no
# dice que Wayfire la esté aplicando: puede estar el plugin sin instalar, puede
# haber una configuración vieja en `~/.config`, puede haberse ido la lista en
# una actualización. La única comprobación que vale es pedir el protocolo desde
# un programa que no está en la lista y ver que no llega.
#
# Se piden las dos formas que se saltearon esto alguna vez:
#
#   1. `grim` a secas. Estuvo en la lista de permitidos hasta que `vasak-shot`
#      aprendió a tomar los píxeles por su cuenta, y mientras estuvo, la lista
#      no cerraba nada: un script de dos líneas que lo llamara capturaba la
#      pantalla entera.
#   2. Un programa cualquiera que le pide a `grim` que capture por él. Es el
#      caso que reabrió Vasak-OS/vasak-desktop-settings#7 después de darlo por
#      cerrado, y el que dice si la lista mira algo más que el nombre del
#      ejecutable que pide.
#
# Y se comprueba también la otra mitad, la que ninguna negación demuestra: que
# la herramienta que **sí** captura siga en la lista. Sin eso, una lista vacía
# pasaría estas pruebas en verde con el escritorio sin capturas.
#
# Uso: pruebas/captura-sin-permiso.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

INI=etc/skel/.config/wayfire.ini
fallos=0
ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal()   { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }
aviso() { printf '  \033[33m·\033[0m %s\n' "$1"; }
tema()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

tema '== el plugin está cargado y negando =='

if grep -qE '^\s*permisos-globales\s*\\?\s*$' "$INI"; then
    ok "permisos-globales está en la lista de plugins"
else
    mal "permisos-globales no figura en plugins de $INI"
fi

# `solo_anotar = true` es la salida de emergencia que documenta el propio
# archivo: deja el plugin cargado y no niega nada. Es lo correcto para
# depurar en el equipo de alguien y lo que no puede viajar en el paquete.
if grep -qE '^\s*solo_anotar\s*=\s*true' "$INI"; then
    mal "solo_anotar = true viaja en el paquete: el plugin anota pero no niega"
else
    ok "no viaja con solo_anotar = true"
fi

tema '== y la captura sigue negada a quien no está en la lista =='

if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    aviso "SIN COMPROBAR: no hay sesión Wayland (WAYLAND_DISPLAY vacío)"
    aviso "esta parte sólo se puede comprobar dentro del escritorio andando"
elif ! command -v grim >/dev/null 2>&1; then
    aviso "SIN COMPROBAR: grim no está instalado"
else
    taller=$(mktemp -d)
    trap 'rm -rf "$taller"' EXIT

    # `grim` ya no está en la lista: `vasak-shot` toma los píxeles por su cuenta
    # desde 0.7.0, así que la herramienta que capturaba en nombre de todos dejó
    # de existir. Si esto volviera a capturar, la lista tendría otra vez adentro
    # un programa que cualquiera puede correr.
    salida=$(grim "$taller/negada.png" 2>&1)
    if [ -s "$taller/negada.png" ]; then
        mal "grim capturó $(stat -c%s "$taller/negada.png") bytes: volvió a la lista de permitidos"
    else
        ok "grim no captura (dice: ${salida:-sin salida})"
    fi

    # El caso que reabrió el issue: no hace falta hablar el protocolo, alcanza
    # con pedirle a una herramienta permitida que lo hable. Mientras `grim`
    # estuvo en la lista, esto capturaba.
    printf '#!/usr/bin/env bash\ngrim "$1" 2>&1\n' > "$taller/porlacara.sh"
    chmod +x "$taller/porlacara.sh"
    salida=$("$taller/porlacara.sh" "$taller/porlacara.png" 2>&1)
    if [ -s "$taller/porlacara.png" ]; then
        mal "un programa cualquiera capturó $(stat -c%s "$taller/porlacara.png") bytes pidiéndoselo a grim"
    else
        ok "un programa que le pide la captura a grim tampoco la consigue"
    fi

    # Y que el protocolo directamente no se le anuncie, que es cómo funciona
    # esto: lo que no se ofrece no se puede pedir.
    if command -v wayland-info >/dev/null 2>&1; then
        globales=$(wayland-info 2>/dev/null | grep -c "zwlr_screencopy_manager_v1\|ext_image_copy_capture_manager_v1")
        if [ "$globales" -eq 0 ]; then
            ok "los protocolos de captura no se le anuncian a un cliente cualquiera"
        else
            mal "el compositor sigue anunciando los protocolos de captura a cualquiera"
        fi
    else
        aviso "wayland-info no está: no se comprobó qué globals se anuncian"
    fi

    # La otra mitad, que ninguna negación demuestra: que alguien siga pudiendo
    # capturar. Con la lista vacía todo lo de arriba pasa en verde y el
    # escritorio se queda sin capturas de pantalla, que es el modo de fallar
    # que no se ve. Se mira la lista dentro del plugin instalado y no se corre
    # `vasak-shot`, que abre una ventana a pantalla completa y pide una persona
    # del otro lado.
    plugin=/usr/lib/wayfire/libpermisos-globales.so
    if [ ! -f "$plugin" ]; then
        aviso "SIN COMPROBAR: no está $plugin"
    elif ! command -v strings >/dev/null 2>&1; then
        aviso "SIN COMPROBAR: strings no está instalado"
    elif strings "$plugin" | grep -qx "/usr/bin/vasak-shot"; then
        ok "la herramienta de captura del escritorio sigue en la lista"
    else
        mal "ninguna herramienta de captura quedó en la lista: nadie puede capturar"
    fi
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo en orden.\033[0m\n'
else
    printf '\033[31m%d comprobación(es) fallaron.\033[0m\n' "$fallos"
fi
exit $(( fallos > 0 ? 1 : 0 ))
