#!/usr/bin/env bash
#
# Que la cámara no se la lleve cualquiera por PipeWire.
#
# En este sistema la cámara la reparte PipeWire, y hasta ahora se la daba a
# quien la pidiera: cualquier programa con la cuenta del usuario veía el nodo
# v4l2 y capturaba, sin diálogo y sin dejar nada anotado. `50-vasak-camara.conf`
# deja de ofrecérsela a los clientes que entran por `pipewire-0`, que es por
# donde entra cualquier aplicación, y el que la quiera la pide por
# `xdg-desktop-portal`, que pregunta.
#
# # Las dos piezas, y por qué ninguna sola alcanza
#
# La regla sin el drop-in del portal deja la cámara cerrada **también para el
# portal**, o sea bloqueada sin forma de desbloquear. El drop-in sin la regla no
# bloquea nada. Por eso esta prueba exige las dos y, en vivo, comprueba los dos
# lados: que un cliente normal no capture y que el portal sí vea la cámara.
#
# # Por qué no alcanza con leer los archivos
#
# Que el archivo diga lo correcto no dice que WirePlumber lo esté aplicando.
# Puede no estar empaquetado —a este repo ya le pasó, con el drop-in de GRUB que
# dejó el menú diciendo «Arch» durante meses—, puede haber una configuración en
# `~/.config` que le gane, o puede que una versión de WirePlumber cambie la
# forma de las reglas sin avisar. La única comprobación que vale es pedir la
# cámara desde un cliente normal y ver que no llega.
#
# Y la sonda **tiene que entrar por el socket que se está probando**. `pw-dump`
# y `wpctl` no sirven: ponen `remote.intention=manager` y entran por
# `pipewire-0-manager`, así que una regla sobre `pipewire-0` no los alcanza y
# darían verde sin haber probado nada. Ese falso negativo nos costó un mes; va
# `pw-cli`, que entra como una aplicación.
#
# ⚠ Y nada de `… | grep -q` acá adentro. Con `pipefail`, `grep -q` cierra la
# tubería en cuanto encuentra, el productor muere con SIGPIPE y la condición da
# falso **aunque haya encontrado**. O sea: «la cámara no se ve», verde, sin
# haber mirado. Pasó al escribir esta prueba. Va la salida a una variable y el
# `grep` sobre una here-string, que no es tubería: `grep -q … <<<"$var"`.
#
# Uso: pruebas/camara-solo-por-el-portal.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

CONF=usr/share/wireplumber/wireplumber.conf.d/50-vasak-camara.conf
DROPIN=usr/lib/systemd/user/xdg-desktop-portal.service.d/50-vasak-pipewire-priv.conf
PERFIL=etc/apparmor.d/vasak-appimage

fallos=0
ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal()   { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }
aviso() { printf '  \033[33m·\033[0m %s\n' "$1"; }
tema()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

tema '== las dos piezas están, y son coherentes entre sí =='

if [ -f "$CONF" ]; then
    ok "$CONF existe"
else
    mal "falta $CONF"
fi

if [ -f "$DROPIN" ]; then
    ok "$DROPIN existe"
else
    mal "falta $DROPIN: sin esto el portal tampoco vería la cámara"
fi

# La regla y el drop-in tienen que nombrar el **mismo** socket privilegiado, y
# ese socket tiene que ser uno que PipeWire publique. Son tres archivos en tres
# formatos distintos diciendo «pipewire-0-priv»; si uno se mueve, el escritorio
# se queda sin cámara y nada falla a la vista.
if grep -q 'PIPEWIRE_REMOTE=pipewire-0-priv' "$DROPIN" 2>/dev/null; then
    ok "el portal se manda a pipewire-0-priv"
else
    mal "el drop-in no manda al portal a pipewire-0-priv"
fi

if grep -q 'pipewire-0-priv' usr/lib/vasak/generar-pipewire-conf 2>/dev/null; then
    ok "el generador publica pipewire-0-priv"
else
    mal "el generador no publica pipewire-0-priv, así que el portal no tiene por dónde entrar"
fi

if grep -q 'ListenStream=%t/pipewire-0-priv' usr/lib/systemd/user/pipewire.socket.d/*.conf 2>/dev/null; then
    ok "systemd crea el socket pipewire-0-priv"
else
    mal "ningún drop-in de pipewire.socket crea pipewire-0-priv"
fi

# La regla se le aplica a `pipewire-0` y **no** a `pipewire-0-manager`. Por el
# del gestor entra WirePlumber: restringirse a sí mismo le saca los
# dispositivos y voltea la pila de audio entera. Probado, sin querer.
if grep -qE 'pipewire\.sec\.socket\s*=\s*"pipewire-0"' "$CONF"; then
    ok "la regla empareja por pipewire.sec.socket, que el cliente no puede falsear"
else
    mal "la regla no empareja por pipewire.sec.socket"
fi

if grep -E '^[^#]*pipewire-0-manager' "$CONF" >/dev/null; then
    mal "la regla nombra pipewire-0-manager: eso restringe a WirePlumber y tumba el audio"
else
    ok "la regla no toca pipewire-0-manager"
fi

# Y que siga siendo SPA-JSON válido. Un archivo roto acá no rompe el audio
# —WirePlumber lo ignora— pero deja la cámara abierta en silencio.
if command -v spa-json-dump >/dev/null 2>&1; then
    if spa-json-dump "$CONF" >/dev/null 2>&1; then
        ok "el archivo es SPA-JSON válido"
    else
        mal "$CONF no es SPA-JSON válido: WirePlumber lo va a ignorar"
    fi
else
    aviso "SIN COMPROBAR: falta spa-json-dump (paquete pipewire)"
fi

tema '== la puerta de al lado, cerrada para lo confinado =='

# `pipewire-0-priv` y `-manager` son `srw-rw-rw-` como todos los sockets de
# PipeWire, así que alcanza con `PIPEWIRE_REMOTE=pipewire-0-priv` para entrar
# por donde no hay restricción. Contra eso no hay configuración que valga: lo
# cierra el perfil, y sólo para lo que el perfil alcanza.
for socket in pipewire-0-priv pipewire-0-manager; do
    if grep -qE "^\s*audit deny /run/user/\*/$socket rw,\s*$" "$PERFIL"; then
        ok "el perfil de AppImage niega $socket"
    else
        mal "el perfil no niega $socket: un AppImage entra por ahí y ve la cámara"
    fi
done

# Y que NO niegue el socket normal, por el que va también el sonido.
if grep -qE '^\s*audit deny /run/user/\*/pipewire-0 rw,' "$PERFIL"; then
    mal "el perfil niega pipewire-0: eso deja a la aplicación además sin sonido"
else
    ok "el perfil no niega pipewire-0, que es por donde va el audio"
fi

tema '== y en vivo: la cámara no llega a un cliente normal =='

if [ -z "${XDG_RUNTIME_DIR:-}" ] || ! pgrep -x pipewire >/dev/null 2>&1; then
    aviso "SIN COMPROBAR: no hay PipeWire andando"
    aviso "esta parte sólo se puede comprobar dentro de una sesión"
elif ! command -v pw-cli >/dev/null 2>&1; then
    aviso "SIN COMPROBAR: falta pw-cli (paquete pipewire)"
else
    # Primero: ¿hay cámara? Sin cámara esto no prueba nada, y decirlo importa
    # más que dar un verde vacío. Se mira por el socket del gestor, que no está
    # restringido, para no confundir «no hay cámara» con «está oculta».
    volcado=$(pw-dump 2>/dev/null || true)
    if command -v pw-dump >/dev/null 2>&1 &&
       grep -q '"media.role": "Camera"' <<<"$volcado"; then

        # La sonda. `pw-cli` entra por `pipewire-0`, como una aplicación.
        #
        # Se repite: queda una carrera en WirePlumber por la que el cliente
        # alcanza a ver los objetos antes de que le lleguen los permisos, y se
        # los retiran enseguida. Va de 8 a 45 de cada 100 según la carga del
        # equipo, así que una sola corrida no dice nada en ninguna dirección.
        # Lo que se exige es que la mayoría de las corridas no la vean; que
        # ninguna la vea es más de lo que hoy se puede prometer.
        vistas=0
        for _ in $(seq 1 20); do
            nodos=$(pw-cli ls Node 2>/dev/null || true)
            if grep -q 'media.role = "Camera"' <<<"$nodos"; then
                vistas=$((vistas + 1))
            fi
        done

        if [ "$vistas" -eq 20 ]; then
            mal "la cámara se ve en las 20 corridas: la regla no se está aplicando"
        elif [ "$vistas" -gt 10 ]; then
            mal "la cámara se ve en $vistas de 20: más carrera de la medida, algo cambió"
        else
            ok "la cámara queda oculta en $((20 - vistas)) de 20 corridas"
        fi

        # Lo anterior es visibilidad. Esto es el permiso: que no se pueda
        # capturar. Es lo único que en todas las mediciones dio cero —0 de 100
        # intentos, con el equipo cargado y descargado—, y es lo que se rompe
        # primero si la regla deja de aplicarse.
        if command -v gst-launch-1.0 >/dev/null 2>&1 &&
           gst-inspect-1.0 pipewiresrc >/dev/null 2>&1; then
            serial=$(python3 -c '
import json, sys
for o in json.load(sys.stdin):
    p = (o.get("info") or {}).get("props") or {}
    if p.get("media.role") == "Camera" and p.get("media.class") == "Video/Source":
        print(p.get("object.serial")); break
' <<<"$volcado" 2>/dev/null)
            if [ -n "$serial" ]; then
                capturas=0
                for _ in 1 2 3 4 5; do
                    # El `videoconvert` no es decorativo: sin él la tubería no
                    # negocia formato y falla con «target not found» aunque el
                    # permiso esté concedido — un falso verde.
                    if timeout 10 gst-launch-1.0 -q pipewiresrc "target-object=$serial" \
                           num-buffers=1 ! videoconvert ! fakesink >/dev/null 2>&1; then
                        capturas=$((capturas + 1))
                    fi
                done
                if [ "$capturas" -eq 0 ]; then
                    ok "un cliente normal no logró capturar en 5 intentos"
                else
                    mal "un cliente normal capturó $capturas de 5 veces: el permiso no se aplica"
                fi
            else
                aviso "SIN COMPROBAR: no se pudo resolver el serial del nodo de cámara"
            fi
        else
            aviso "SIN COMPROBAR: falta gst-launch-1.0 con pipewiresrc (gst-plugins-good)"
        fi
    else
        aviso "SIN COMPROBAR: este equipo no tiene cámara"
    fi
fi

tema '== y el portal sí la tiene, que es la otra mitad =='

if ! command -v busctl >/dev/null 2>&1 || [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    aviso "SIN COMPROBAR: no hay bus de sesión"
else
    presente=$(busctl --user get-property org.freedesktop.portal.Desktop \
        /org/freedesktop/portal/desktop \
        org.freedesktop.portal.Camera IsCameraPresent 2>/dev/null)
    case "$presente" in
        "b true")
            ok "el portal ve la cámara: el camino que pregunta sigue abierto" ;;
        "b false")
            # Esto es el modo de fallo que importa: la regla puesta y el portal
            # sin cámara es bloquear sin poder desbloquear.
            mal "el portal NO ve la cámara: quedó bloqueada sin forma de conceder" ;;
        *)
            aviso "SIN COMPROBAR: el portal no contestó IsCameraPresent" ;;
    esac
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mSin fallos.\033[0m\n'
else
    printf '\033[31m%s fallo(s).\033[0m\n' "$fallos"
fi
exit $(( fallos > 0 ? 1 : 0 ))
