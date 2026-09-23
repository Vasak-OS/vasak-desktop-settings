#!/usr/bin/env bash
#
# Que el audio tenga prioridad de tiempo real, y que la tenga **por el paquete**
# y no por herencia.
#
# # Por qué existe
#
# Los hilos de datos de PipeWire piden SCHED_FIFO 88. Sin el límite corren en
# SCHED_OTHER y el audio chasquea cuando la máquina está ocupada. No falla y no
# avisa: el síntoma no se parece a su causa, y el primero que lo note va a
# pensar que es el hardware.
#
# Hasta ahora el límite venía de `cachyos-settings`, que **no lo exige nadie**
# —no está en la ISO, no lo instala el instalador, ningún paquete nuestro
# depende de él—. En un equipo que viene de CachyOS está por herencia; en una
# instalación limpia no estaría. Medido: `DefaultLimitRTPRIO` de systemd es 0.
#
# Uso: pruebas/audio-en-tiempo-real.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

LIMITES=etc/security/limits.d/50-vasak-audio.conf
RECETA=../PKGBUILDS/vasak-desktop-settings-git/PKGBUILD

fallos=0
ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal()   { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }
aviso() { printf '  \033[33m·\033[0m %s\n' "$1"; }
tema()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

tema '== el archivo está, y concede lo que hace falta =='

if [ -f "$LIMITES" ]; then
    ok "$LIMITES existe"
else
    mal "falta $LIMITES"
fi

# El grupo tiene que ser uno que el instalador asigne de verdad. `realtime` no
# lo crea nadie acá, así que un archivo que concediera a ese grupo sería
# decorativo — y se vería igual de bien.
if grep -qE '^\s*@audio\s+-\s+rtprio\s+[0-9]+' "$LIMITES" 2>/dev/null; then
    ok "concede rtprio al grupo audio, que es el que pone el instalador"
else
    mal "no concede rtprio a @audio: el límite no va a llegar a nadie"
fi

# Que alcance para lo que la pila pide. PipeWire pide 88 y es el más alto.
concedido=$(sed -nE 's/^\s*@audio\s+-\s+rtprio\s+([0-9]+).*/\1/p' "$LIMITES" 2>/dev/null | head -1)
if [ -n "$concedido" ] && [ "$concedido" -ge 88 ]; then
    ok "con rtprio $concedido, que cubre el 88 que pide el hilo de datos"
elif [ -n "$concedido" ]; then
    mal "rtprio $concedido no alcanza: PipeWire pide 88 y se queda sin tiempo real"
fi

# Y que no reparta el techo. 99 es el máximo; conceder de más en un límite que
# gobierna la planificación es lo que este archivo trata de acotar.
if [ -n "$concedido" ] && [ "$concedido" -ge 99 ]; then
    mal "rtprio $concedido reparte el techo: con 95 alcanza y sobra margen"
elif [ -n "$concedido" ]; then
    ok "y sin repartir el techo"
fi

tema '== y el paquete lo instala =='

if [ -f "$RECETA" ]; then
    if grep -q "etc/security/limits.d/50-vasak-audio.conf" "$RECETA"; then
        ok "la receta lo instala"
    else
        mal "la receta no lo instala: quedaría escrito y sin empaquetar"
    fi
else
    aviso "SIN COMPROBAR: la receta vive en PKGBUILDS y no está al lado"
fi

tema '== y en vivo: los hilos de datos están en tiempo real =='

if ! pgrep -x pipewire >/dev/null 2>&1; then
    aviso "SIN COMPROBAR: no hay PipeWire andando"
else
    # El hilo que importa es `data-loop`, no el principal: el principal corre en
    # SCHED_OTHER siempre y mirarlo da un rojo que no significa nada. Costó una
    # vuelta descubrirlo.
    pid=$(pgrep -x pipewire | head -1)
    hilos=$(ps -Lo cls,rtprio,comm --no-headers -p "$pid" 2>/dev/null || true)
    datos=$(grep -c 'data-loop' <<<"$hilos")

    if [ "$datos" -eq 0 ]; then
        aviso "SIN COMPROBAR: PipeWire todavía no levantó su hilo de datos"
    elif grep 'data-loop' <<<"$hilos" | grep -qE '^\s*FF\s+[0-9]+'; then
        prio=$(grep 'data-loop' <<<"$hilos" | sed -nE 's/^\s*FF\s+([0-9]+).*/\1/p' | head -1)
        ok "el hilo de datos corre en SCHED_FIFO con prioridad $prio"
    else
        mal "el hilo de datos NO está en tiempo real: el audio va a chasquear bajo carga"
    fi

    # Y que el límite esté donde se hereda. Si esto falla estando el archivo,
    # es que la sesión se inició antes de instalarlo: hay que volver a entrar.
    techo=$(grep -E 'Max realtime priority' "/proc/$pid/limits" 2>/dev/null | awk '{print $4}')
    if [ -n "$techo" ] && [ "$techo" -ge 88 ]; then
        ok "y el proceso tiene el límite heredado de la sesión ($techo)"
    else
        mal "el proceso tiene rtprio máximo ${techo:-?}: el límite no llegó a la sesión"
    fi
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mSin fallos.\033[0m\n'
else
    printf '\033[31m%s fallo(s).\033[0m\n' "$fallos"
fi
exit $(( fallos > 0 ? 1 : 0 ))
