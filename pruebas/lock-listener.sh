#!/usr/bin/env bash
#
# Que pedir el bloqueo bloquee.
#
# `loginctl lock-session` (o `Session.Lock` por D-Bus, que es lo que usa el botón
# Bloquear del centro de control) sólo hace que logind emita la señal `Lock`:
# bloquea quien la escuche. Hasta vasak-desktop#190 no la escuchaba nadie, y el
# pedido se perdía sin error. Lo escucha vasak-lock-listener.service.
#
# Dos partes:
#
#   1. La forma de la unidad: el evento `lock` con -d y en su propio ámbito, sin
#      ningún `timeout`, habilitada por el enlace que trae el paquete, y un solo
#      oyente (vasak-idle.service sigue sin `lock`).
#   2. De punta a punta, contra un logind **de mentira** en un bus privado: el
#      swayidle de verdad, con el ExecStart de la unidad, recibe la señal cuando
#      alguien llama `Session.Lock` en `/org/freedesktop/login1/session/auto`.
#      `systemd-run` es un doble que anota con qué lo llamaron: nunca se bloquea
#      la sesión de quien corre la prueba. Y como sabotaje, lo mismo con lo que
#      escucha vasak-idle.service: la señal se pierde.
#
# La segunda parte necesita dbus-daemon, swayidle, python3 con GObject y una
# sesión Wayland (swayidle se conecta al compositor aunque no mire la
# inactividad). Sin eso lo dice y la saltea.
#
# Uso: pruebas/lock-listener.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

UNIDAD=usr/lib/systemd/user/vasak-lock-listener.service
ENLACE=usr/lib/systemd/user/graphical-session.target.wants/vasak-lock-listener.service
IDLE=usr/lib/systemd/user/vasak-idle.service
fallos=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal() { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }
tema(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# El ExecStart entero, con las líneas partidas por `\` ya unidas.
exec_start() {
    sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$1" | sed -n 's/^ExecStart=//p' | tr -s ' '
}

tema '== la unidad =='

comando=$(exec_start "$UNIDAD")
if grep -qE "(^| )lock 'systemd-run --user --scope --collect --quiet /usr/bin/vasak-lock-screen -d'" <<<"$comando"; then
    ok "escucha «lock» y lanza vasak-lock-screen -d en su propio ámbito"
else
    mal "el evento lock no es el esperado: $comando"
fi

if grep -qw timeout <<<"$comando"; then
    mal "tiene un timeout: la inactividad es de vasak-idle.service, no de esta"
else
    ok "no mira la inactividad"
fi

if grep -qE '^(NoNewPrivileges|SystemCallFilter|RestrictAddressFamilies|PrivateDevices|CapabilityBoundingSet)=' "$UNIDAD"; then
    mal "está endurecida: el bloqueo lo hereda y PAM deja de aceptar la contraseña"
else
    ok "sin endurecer (el bloqueo hereda sus privilegios)"
fi

if [ -L "$ENLACE" ] && [ "$(readlink "$ENLACE")" = "/usr/lib/systemd/user/vasak-lock-listener.service" ]; then
    ok "viene habilitada: el enlace en graphical-session.target.wants/ apunta a la unidad"
else
    mal "falta el enlace que la habilita, o apunta a otro lado"
fi

if grep -qE "(^| )lock '" <<<"$(exec_start "$IDLE")"; then
    mal "vasak-idle.service también escucha lock: serían dos bloqueos por pedido"
else
    ok "un solo oyente: vasak-idle.service sigue sin lock"
fi

if command -v systemd-analyze >/dev/null; then
    if salida=$(systemd-analyze --user verify "$UNIDAD" 2>&1); then
        ok "systemd-analyze no tiene nada que decir"
    else
        mal "systemd-analyze: $salida"
    fi
fi

tema '== de punta a punta, con un logind de mentira =='

faltan=()
for programa in dbus-daemon swayidle python3 gdbus; do
    command -v "$programa" >/dev/null || faltan+=("$programa")
done
python3 -c 'from gi.repository import Gio' 2>/dev/null || faltan+=("python-gobject")
[ -n "${WAYLAND_DISPLAY:-}" ] || faltan+=("una sesión Wayland")

if [ ${#faltan[@]} -gt 0 ]; then
    printf '  - salteada: falta %s\n' "${faltan[*]}"
else
    taller=$(mktemp -d)
    pids=()
    trap 'kill "${pids[@]}" 2>/dev/null; rm -rf "$taller"' EXIT

    # El doble de systemd-run: anota los argumentos y no lanza nada.
    mkdir -p "$taller/bin"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/pedidos"\n' "$taller" > "$taller/bin/systemd-run"
    chmod +x "$taller/bin/systemd-run"

    cat > "$taller/logind.py" <<'PY'
from gi.repository import Gio, GLib
REAL = "/org/freedesktop/login1/session/_33"
XML = """<node>
 <interface name="org.freedesktop.login1.Manager">
  <method name="GetSession"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
  <method name="GetSessionByPID"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>
 </interface>
 <interface name="org.freedesktop.login1.Session">
  <method name="Lock"/><signal name="Lock"/><signal name="Unlock"/>
 </interface></node>"""
info = Gio.DBusNodeInfo.new_for_xml(XML)
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
def call(c, sender, path, iface, method, params, inv):
    if method in ("GetSession", "GetSessionByPID"):
        inv.return_value(GLib.Variant("(o)", (REAL,)))
        return
    # Como logind: el pedido llega por /session/auto y la señal sale en la ruta
    # de verdad de la sesión.
    c.emit_signal(None, REAL, "org.freedesktop.login1.Session", "Lock", None)
    inv.return_value(None)
bus.register_object("/org/freedesktop/login1", info.interfaces[0], call, None, None)
for p in (REAL, "/org/freedesktop/login1/session/auto"):
    bus.register_object(p, info.interfaces[1], call, None, None)
Gio.bus_own_name_on_connection(bus, "org.freedesktop.login1", 0, None, None)
GLib.MainLoop().run()
PY

    dbus-daemon --session --nofork --print-address=1 \
        --address="unix:abstract=vasak-lock-listener-$$" > "$taller/direccion" 2>/dev/null &
    pids+=($!)
    for _ in $(seq 50); do [ -s "$taller/direccion" ] && break; sleep 0.1; done
    bus=$(head -1 "$taller/direccion")

    DBUS_SESSION_BUS_ADDRESS=$bus python3 "$taller/logind.py" 2>/dev/null &
    pids+=($!)
    for _ in $(seq 50); do
        DBUS_SESSION_BUS_ADDRESS=$bus gdbus call --session --dest org.freedesktop.DBus \
            --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner \
            org.freedesktop.login1 2>/dev/null | grep -q true && break
        sleep 0.1
    done

    # Corre `swayidle <argumentos>` contra el logind de mentira, pide el bloqueo
    # y dice qué le llegó al doble de systemd-run. Todo lo que hable D-Bus va al
    # bus privado: la sesión de verdad no se entera.
    pedir_bloqueo() {
        rm -f "$taller/pedidos"
        eval "set -- $1"
        env -u XDG_SESSION_ID PATH="$taller/bin:$PATH" \
            DBUS_SYSTEM_BUS_ADDRESS="$bus" DBUS_SESSION_BUS_ADDRESS="$bus" \
            swayidle "$@" >/dev/null 2>&1 &
        local swayidle=$!
        sleep 1
        DBUS_SESSION_BUS_ADDRESS=$bus gdbus call --session --dest org.freedesktop.login1 \
            --object-path /org/freedesktop/login1/session/auto \
            --method org.freedesktop.login1.Session.Lock >/dev/null
        for _ in $(seq 30); do [ -s "$taller/pedidos" ] && break; sleep 0.1; done
        kill "$swayidle" 2>/dev/null
        wait "$swayidle" 2>/dev/null
        cat "$taller/pedidos" 2>/dev/null
    }

    argumentos=${comando#/usr/bin/swayidle }
    pedido=$(pedir_bloqueo "$argumentos")
    if [ "$pedido" = "--user --scope --collect --quiet /usr/bin/vasak-lock-screen -d" ]; then
        ok "Session.Lock en session/auto lanza vasak-lock-screen -d"
    else
        mal "el pedido de bloqueo no lanzó el bloqueo (llegó: «$pedido»)"
    fi

    # Sabotaje: lo que escucha vasak-idle.service, sin sus timeout (no se mira
    # la inactividad de la sesión de quien corre esto). Sin `lock`, nadie
    # atiende la señal: era el estado antes de esta unidad.
    sin_timeouts="-w before-sleep 'systemd-run --user --scope --collect --quiet /usr/bin/vasak-lock-screen -d'"
    pedido=$(pedir_bloqueo "$sin_timeouts")
    if [ -z "$pedido" ]; then
        ok "sabotaje: con sólo vasak-idle.service el pedido se pierde (la prueba lo ve)"
    else
        mal "sabotaje: sin lock igual se bloqueó, la prueba no distingue nada ($pedido)"
    fi
fi

echo
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mtodo bien\033[0m\n'
else
    printf '\033[31m%d fallas\033[0m\n' "$fallos"
    exit 1
fi
