#!/usr/bin/env bash
#
# Que la salida de audio HDMI se pueda elegir apenas se conecta el monitor.
#
# # Por qué existe
#
# La tarjeta de audio HDMI de la GPU arranca en el perfil `off` y WirePlumber no
# la conmuta sola al enchufar el monitor: el sink HDMI nunca se crea y en el
# panel de sonido no hay nada que seleccionar (vasak-desktop#230). El drop-in
# `51-vasak-audio-hdmi.conf` declara una preferencia de perfiles HDMI para las
# tarjetas ALSA, que `find-preferred-profile.lua` de WirePlumber 0.5 sólo aplica
# cuando el perfil está disponible —es decir, cuando hay monitor—.
#
# El sink HDMI que no aparece no falla ni avisa: el síntoma es «no está la
# opción», que es de las cosas que se reportan como «no anda» sin más. Por eso la
# prueba comprueba el archivo, que sea SPA-JSON válido, y que diga exactamente lo
# que tiene que decir —preferir HDMI en ALSA y no tocar Bluetooth—.
#
# Uso: pruebas/salida-hdmi.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

CONF=usr/share/wireplumber/wireplumber.conf.d/51-vasak-audio-hdmi.conf

fallos=0
ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal()   { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }
aviso() { printf '  \033[33m·\033[0m %s\n' "$1"; }
tema()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

tema '== el drop-in está, y se empaqueta =='

if [ -f "$CONF" ]; then
    ok "$CONF existe"
else
    mal "falta $CONF: sin él, el sink HDMI no se crea al conectar el monitor"
fi

# Va bajo usr/, que es lo que el package() de la receta instala con `cp -r usr`
# —igual que 50-vasak-camara.conf, su vecino—. Un .conf fuera de ese árbol no
# llegaría al equipo.
case "$CONF" in
    usr/*) ok "está bajo usr/, donde el package() lo toma solo" ;;
    *)     mal "no está bajo usr/: la receta no lo instalaría" ;;
esac

tema '== es SPA-JSON válido =='

# Un drop-in de WirePlumber mal formado no corta el arranque: WirePlumber lo
# saltea y sigue con el resto, así que un error de sintaxis se vería como «la
# preferencia no tiene efecto» y no como un fallo. Lo validamos acá.
if command -v spa-json-dump >/dev/null 2>&1; then
    if [ -f "$CONF" ] && spa-json-dump "$CONF" >/dev/null 2>&1; then
        ok "spa-json-dump lo parsea sin error"
    else
        mal "spa-json-dump no lo parsea: WirePlumber lo saltearía en silencio"
    fi
else
    aviso "SIN COMPROBAR: no hay spa-json-dump (lo trae pipewire)"
fi

tema '== dice lo que tiene que decir =='

if [ -f "$CONF" ] && command -v spa-json-dump >/dev/null 2>&1 \
    && json=$(spa-json-dump "$CONF" 2>/dev/null); then

    # La sección que lee find-preferred-profile.lua. Sin esta clave exacta, el
    # hook no encuentra nada y el archivo es decorativo.
    if grep -q '"device.profile.priority.rules"' <<<"$json"; then
        ok "declara device.profile.priority.rules, que es la clave de 0.5"
    else
        mal "no declara device.profile.priority.rules: el hook no lee nada"
    fi

    # Casa ALSA. Es donde vive la salida HDMI de la GPU.
    if grep -q '"device.api": "alsa"' <<<"$json"; then
        ok "casa dispositivos ALSA"
    else
        mal "no casa device.api=alsa: no alcanzaría a la tarjeta HDMI"
    fi

    # Prefiere al menos una salida HDMI. El estéreo es la que suena en cualquier
    # monitor, así que como mínimo tiene que estar.
    if grep -q '"output:hdmi-stereo"' <<<"$json"; then
        ok "prefiere output:hdmi-stereo"
    else
        mal "no prefiere ninguna salida HDMI estéreo: no se crearía el sink"
    fi

    # Y NO toca el Bluetooth: esos perfiles los decide bluetooth.profile-preference
    # y pisarlos acá rompería los auriculares. El match no debe nombrar bluez.
    if grep -q 'bluez' <<<"$json"; then
        mal "nombra bluez: estaría pisando la política de Bluetooth"
    else
        ok "no toca Bluetooth (sin bluez en el match)"
    fi
else
    aviso "SIN COMPROBAR: no se pudo volcar el JSON del drop-in"
fi

tema '== en vivo: con el monitor HDMI conectado =='

if ! command -v pactl >/dev/null 2>&1 || ! pgrep -x pipewire >/dev/null 2>&1; then
    aviso "SIN COMPROBAR: no hay PipeWire/pactl andando"
elif ! pactl list cards 2>/dev/null | grep -q 'output:hdmi'; then
    aviso "SIN COMPROBAR: ninguna tarjeta ofrece salida HDMI (¿sin monitor?)"
else
    # Si hay una ruta HDMI disponible, el perfil activo de esa tarjeta debería
    # nombrarla y el sink HDMI debería existir.
    if pactl list cards 2>/dev/null | grep -A3 'Active Profile' | grep -q 'hdmi'; then
        ok "hay una tarjeta con perfil HDMI activo"
    else
        aviso "ninguna tarjeta tiene perfil HDMI activo (¿monitor sin audio en EDID?)"
    fi
    if pactl list sinks short 2>/dev/null | grep -q 'hdmi'; then
        ok "el sink HDMI existe y se puede elegir"
    else
        aviso "no hay sink HDMI (puede tardar unos segundos tras conectar)"
    fi
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mSin fallos.\033[0m\n'
else
    printf '\033[31m%s fallo(s).\033[0m\n' "$fallos"
fi
exit $(( fallos > 0 ? 1 : 0 ))
