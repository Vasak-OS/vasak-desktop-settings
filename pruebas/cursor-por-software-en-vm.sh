#!/usr/bin/env bash
#
# Que en una máquina virtual la sesión pida el cursor por software.
#
# En una VM el cursor por hardware de wlroots sale invertido, duplicado o
# desfasado (vasak-desktop-settings#15). El arreglo manual era arrancar con
# `WLR_NO_HARDWARE_CURSORS=1`; `vasak-session` lo exporta sola, pero únicamente
# si `systemd-detect-virt --vm` dice que es una VM, y sin pisar un valor que
# quien usa el sistema ya haya elegido.
#
# Se ejercita una copia de `vasak-session` con las rutas absolutas apuntadas a
# un directorio de dobles (ver `nombres-del-escritorio.sh`): el script real
# llama a `uwsm` y a `systemctl --user`, y no se corre de verdad para leer una
# variable. `systemd-detect-virt` se llama por nombre y se resuelve por PATH, así
# que el doble decide si «estamos» en una VM.
#
# Uso: pruebas/cursor-por-software-en-vm.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

SESION=usr/bin/vasak-session
fallos=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }
tema() { printf '\n\033[1m%s\033[0m\n' "$1"; }

taller=$(mktemp -d)
trap 'rm -rf "$taller"' EXIT
mkdir -p "$taller/dobles"

# `uwsm` no arranca nada: escribe si la variable le llegó y con qué valor.
cat > "$taller/dobles/uwsm" <<'DOBLE'
#!/usr/bin/env bash
echo "WLR_NO_HARDWARE_CURSORS=${WLR_NO_HARDWARE_CURSORS-SIN_DEFINIR}" > "$SALIDA_DEL_DOBLE"
DOBLE
cat > "$taller/dobles/systemctl" <<'DOBLE'
#!/usr/bin/env bash
exit 0
DOBLE
# Sale 0 en una VM y 1 en hardware real, según `ES_VM`.
cat > "$taller/dobles/systemd-detect-virt" <<'DOBLE'
#!/usr/bin/env bash
[ "$ES_VM" = 1 ]
DOBLE
chmod +x "$taller/dobles/"*

sed "s#/usr/bin/#$taller/dobles/#g" "$SESION" > "$taller/sesion"
chmod +x "$taller/sesion"

# Valor con el que `uwsm` vio la variable; el primer argumento dice si es VM.
correr() {
    local salida="$taller/salida" es_vm=$1
    shift
    rm -f "$salida"
    env -i \
        PATH="$taller/dobles:/usr/bin:/bin" \
        HOME="$taller" \
        XDG_RUNTIME_DIR="$taller" \
        SALIDA_DEL_DOBLE="$salida" \
        ES_VM="$es_vm" \
        "$@" \
        bash "$taller/sesion" >/dev/null 2>&1
    grep '^WLR_NO_HARDWARE_CURSORS=' "$salida" 2>/dev/null | cut -d= -f2-
}

tema '== en una máquina virtual =='
valor=$(correr 1)
if [ "$valor" = "1" ]; then
    ok "uwsm recibe WLR_NO_HARDWARE_CURSORS=1"
else
    mal "esperaba WLR_NO_HARDWARE_CURSORS=1 y llegó '$valor'"
fi

tema '== en hardware real =='
valor=$(correr 0)
if [ "$valor" = "SIN_DEFINIR" ]; then
    ok "la variable no se exporta"
else
    mal "esperaba la variable sin definir y llegó '$valor'"
fi

tema '== un valor ya elegido se respeta =='
valor=$(correr 1 WLR_NO_HARDWARE_CURSORS=0)
if [ "$valor" = "0" ]; then
    ok "en una VM, con 0 puesto, queda 0"
else
    mal "esperaba 0 y llegó '$valor'"
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo en orden.\033[0m\n'
else
    printf '\033[31m%d comprobación(es) fallaron.\033[0m\n' "$fallos"
fi
exit $(( fallos > 0 ? 1 : 0 ))
