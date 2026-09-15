#!/bin/bash
# Que la compuerta del escritorio haga lo que dice, y sobre todo que **no** se
# convierta en un modo nuevo de quedarse sin sesión.
#
# Nace de un fallo que no daba ningún error: el inicio automático salía apenas
# el compositor estaba listo, y el escritorio —que arranca fuera de systemd, por
# el `[autostart]` de wayfire.ini— competía con Electron y compañía justo
# mientras inicializaba. Medido: 467 ms con el sistema tranquilo contra 16.700 ms
# al iniciar sesión. En un equipo con Steam en el inicio automático, Steam se
# dibujaba antes que el fondo.
#
# Nada de esto lo ve un `systemd-analyze verify`: las dos piezas son válidas por
# separado.
set -uo pipefail

AQUI=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RAIZ="$AQUI/.."
GUION="$RAIZ/usr/bin/vasak-esperar-escritorio"
UNIDAD="$RAIZ/usr/lib/systemd/user/vasak-esperar-escritorio.service"
ENLACE="$RAIZ/usr/lib/systemd/user/graphical-session.target.wants/vasak-esperar-escritorio.service"

fallos=0
mal()  { echo "  FALLA: $*" >&2; fallos=$((fallos + 1)); }
bien() { echo "  ok: $*"; }

# --- Las piezas están -------------------------------------------------------

[ -x "$GUION" ] && bien 'el guion está y es ejecutable' \
                || mal 'falta el guion o no es ejecutable'

[ -f "$UNIDAD" ] && bien 'la unidad está' || mal 'falta la unidad'

# Sin el enlace la unidad no corre nunca: `[Install]` sólo hace efecto al
# habilitarla, y a un paquete nadie le corre `systemctl enable`.
[ -L "$ENLACE" ] && bien 'la unidad viene habilitada por el paquete' \
                 || mal 'falta el enlace en graphical-session.target.wants: la unidad no correría nunca'

# --- El orden, que es todo el punto -----------------------------------------

grep -q '^Before=xdg-desktop-autostart.target' "$UNIDAD" \
    && bien 'el inicio automático queda detrás del escritorio' \
    || mal 'sin Before=xdg-desktop-autostart.target la compuerta no ordena nada'

grep -q '^WantedBy=graphical-session.target' "$UNIDAD" \
    && bien 'la sesión gráfica la arrastra' \
    || mal 'sin WantedBy=graphical-session.target la unidad queda fuera de la transacción y el Before= no aplica'

# --- Que no pueda dejar la sesión colgada ------------------------------------

# Un escritorio que no arranca no puede dejar el inicio automático esperando
# para siempre: sería cambiar «el fondo tarda» por «no abre nada».
grep -qE '^TOPE=[0-9]+' "$GUION" \
    && bien 'la espera tiene tope' \
    || mal 'la espera no tiene tope: un escritorio que no arranca colgaría todo el inicio automático'

salida_al_vencer=$(sed 's/^NOMBRE=.*/NOMBRE=ar.net.vasak.NoExisteJamas/; s/^TOPE=[0-9]*/TOPE=1/' "$GUION" \
    | bash >/dev/null 2>&1; echo $?)
[ "$salida_al_vencer" = 0 ] \
    && bien 'al vencerse el tope sale bien y deja seguir' \
    || mal "al vencerse el tope salió $salida_al_vencer: systemd lo tomaría como fallo"

# --- Y que sí espere cuando corresponde -------------------------------------

# Con el nombre puesto contesta en el acto; el caso contrario ya se probó arriba.
if busctl --user list --no-legend 2>/dev/null | grep -q '^org.vasak.os.Desktop[[:space:]]'; then
    if timeout 5 "$GUION" >/dev/null 2>&1; then
        bien 'con el escritorio arriba no espera nada'
    else
        mal 'con el escritorio arriba igual se quedó esperando'
    fi
else
    echo "  (salteado: no hay escritorio corriendo para probar el caso bueno)"
fi

echo
if [ "$fallos" -eq 0 ]; then
    echo "Todo bien."
else
    echo "$fallos comprobación(es) fallaron."
fi
exit "$((fallos > 0 ? 1 : 0))"
