#!/usr/bin/env bash
#
# Que la sesión deje puestos los dos nombres del escritorio.
#
# `wayland-sessions/vasak.desktop` declara `DesktopNames=Vasak;wlroots`, y de
# ese valor dependen el archivo de configuración del portal, el filtrado de
# `OnlyShowIn`/`NotShowIn` de los `.desktop` y la detección del tema en GTK y
# Qt. `vasak-session` tenía un `export XDG_CURRENT_DESKTOP=Vasak` que pisaba lo
# que el gestor de sesión ya había armado y se llevaba puesto `wlroots`.
#
# Es el modo de falla que no se ve: no hay error ni registro. Una entrada con
# `OnlyShowIn=wlroots;` simplemente no aparece en el menú, y quien la busca
# concluye que el paquete no la instaló.
#
# # Por qué se ejercita una copia y no el archivo tal cual
#
# `vasak-session` termina en `exec uwsm start …` y por el camino llama a
# `systemctl --user` y a `/usr/bin/vasak-config-migrate`, que escribe en la
# configuración de quien lo corre. Correrlo de verdad para leer una variable
# dejaría el equipo de quien prueba distinto de como estaba. Así que se copia a
# un temporal con las rutas absolutas apuntadas a un directorio de dobles, y se
# corre eso: el camino de la variable —que es lo que se está probando— es el
# mismo, línea por línea.
#
# Uso: pruebas/nombres-del-escritorio.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

SESION=usr/bin/vasak-session
fallos=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }
tema() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# El taller: una copia del script con `/usr/bin/` y `systemctl` redirigidos a
# dobles, y un `uwsm` que en vez de arrancar nada escribe lo que le llegó.
taller=$(mktemp -d)
trap 'rm -rf "$taller"' EXIT
mkdir -p "$taller/dobles"

cat > "$taller/dobles/uwsm" <<'DOBLE'
#!/usr/bin/env bash
# Escribe lo que la sesión le pasó y con qué entorno, y no arranca nada.
{
    echo "XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP"
    echo "ARGUMENTOS=$*"
} > "$SALIDA_DEL_DOBLE"
DOBLE
cat > "$taller/dobles/systemctl" <<'DOBLE'
#!/usr/bin/env bash
exit 0
DOBLE
chmod +x "$taller/dobles/uwsm" "$taller/dobles/systemctl"

# La copia: `/usr/bin/algo` pasa a `$taller/dobles/algo`, así que lo que el
# script invoca por ruta absoluta tampoco sale del temporal.
sed "s#/usr/bin/#$taller/dobles/#g" "$SESION" > "$taller/sesion"
chmod +x "$taller/sesion"

# Lo que la copia deja escrito, corrida con el entorno que se le pase.
correr() {
    local salida="$taller/salida"
    rm -f "$salida"
    env -i \
        PATH="$taller/dobles:/usr/bin:/bin" \
        HOME="$taller" \
        XDG_RUNTIME_DIR="$taller" \
        SALIDA_DEL_DOBLE="$salida" \
        "$@" \
        bash "$taller/sesion" >/dev/null 2>&1
    cat "$salida" 2>/dev/null
}

tema '== el gestor de sesión ya puso los dos nombres =='
# Es el caso de verdad: vasak-session-manager arma `Vasak:wlroots` a partir de
# los `DesktopNames` de la entrada, y la sesión no tiene nada que corregir.
resultado=$(correr XDG_CURRENT_DESKTOP=Vasak:wlroots)
valor=$(grep '^XDG_CURRENT_DESKTOP=' <<<"$resultado" | cut -d= -f2-)
if [ "$valor" = "Vasak:wlroots" ]; then
    ok "no lo pisa: queda $valor"
else
    mal "esperaba Vasak:wlroots y quedó '$valor'"
fi

tema '== y si no viene nada, los pone la sesión =='
# Arrancada a mano, o por un gestor que no mire `DesktopNames`. Sin esto queda
# la mitad de lo que declara la entrada de sesión.
resultado=$(correr)
valor=$(grep '^XDG_CURRENT_DESKTOP=' <<<"$resultado" | cut -d= -f2-)
if [ "$valor" = "Vasak:wlroots" ]; then
    ok "quedan los dos: $valor"
else
    mal "esperaba Vasak:wlroots y quedó '$valor'"
fi

tema '== wlroots sobrevive hasta el compositor =='
# El nombre tiene que seguir puesto en el entorno con el que arranca uwsm, que
# es quien se lo pasa al resto de la sesión. Que el `export` esté bien y se
# pierda después no sirve de nada.
resultado=$(correr XDG_CURRENT_DESKTOP=Vasak:wlroots)
if grep -q 'wlroots' <<<"$(grep '^XDG_CURRENT_DESKTOP=' <<<"$resultado")"; then
    ok "uwsm lo recibe en el entorno"
else
    mal "uwsm arrancó sin wlroots en XDG_CURRENT_DESKTOP"
fi

tema '== y los dos nombres se le pasan también por argumento =='
# `-D` por omisión suma a lo que ya haya, así que `-D Vasak` no borraba nada
# con la variable bien puesta; pero el archivo decía dos cosas distintas en dos
# líneas y cuál ganaba dependía de un valor por omisión de uwsm que ninguna de
# las dos nombra.
argumentos=$(grep '^ARGUMENTOS=' <<<"$resultado" | cut -d= -f2-)
if grep -q -- '-D Vasak:wlroots' <<<"$argumentos"; then
    ok "uwsm recibe -D Vasak:wlroots"
else
    mal "esperaba -D Vasak:wlroots en los argumentos y llegó '$argumentos'"
fi

tema '== la entrada de sesión sigue declarando los dos =='
# Es de donde sale todo lo anterior: si la entrada dejara de nombrarlos, el
# gestor de sesión no tendría qué armar y el arreglo de arriba quedaría
# sosteniendo solo algo que ya nadie declara.
if grep -q '^DesktopNames=Vasak;wlroots' usr/share/wayland-sessions/vasak.desktop; then
    ok "vasak.desktop declara Vasak;wlroots"
else
    mal "vasak.desktop ya no declara los dos nombres"
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo en orden.\033[0m\n'
else
    printf '\033[31m%d comprobación(es) fallaron.\033[0m\n' "$fallos"
fi
exit $(( fallos > 0 ? 1 : 0 ))
