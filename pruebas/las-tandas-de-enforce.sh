#!/usr/bin/env bash
#
# Que cada perfil que la lista pasa a enforce **exista**.
#
# El nombre que va en este archivo es el del perfil, que no siempre es el del
# paquete —`power-profiles-daemon` el paquete, `power-profiles-daemon` el
# perfil; pero `reflector` el paquete y `reflector` el perfil sólo por
# casualidad—. Un nombre que no corresponde a ningún perfil no falla: la línea
# no hace nada, el perfil sigue en modo aviso, y desde afuera se ve exactamente
# igual que si estuviera haciendo cumplir. Es la clase de error que sólo
# aparece el día que alguien confía en que ese programa estaba confinado.
#
# La otra mitad es la forma: `aa-install` lee «<perfil> <modo>» y una línea con
# otra cosa se ignora en silencio.
#
# Uso: pruebas/las-tandas-de-enforce.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

FLAGS=etc/apparmor/flags.d/50-vasakos.conf
fallos=0
ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal()   { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }
aviso() { printf '  \033[33m·\033[0m %s\n' "$1"; }

if [ ! -f "$FLAGS" ]; then
    mal "falta $FLAGS"
    printf '\n\033[31m1 fallo.\033[0m\n'
    exit 1
fi

# Las líneas que no son comentario ni vacías.
mapfile -t lineas < <(grep -vE '^\s*(#|$)' "$FLAGS")

if [ ${#lineas[@]} -eq 0 ]; then
    mal "la lista no pasa ningún perfil a enforce: el archivo no hace nada"
fi

for linea in "${lineas[@]}"; do
    if [[ ! "$linea" =~ ^[a-zA-Z0-9_.-]+[[:space:]]+(enforce|complain)$ ]]; then
        mal "«$linea» no tiene la forma «<perfil> <modo>»: aa-install la ignora"
    fi
done

# Y que cada uno exista. Los perfiles los instala `apparmor.d`, así que sin ese
# paquete esto no se puede comprobar — y decirlo es mejor que pasar en verde.
DIR=/etc/apparmor.d
if [ ! -d "$DIR" ]; then
    aviso "SIN COMPROBAR: no está $DIR (falta el paquete apparmor.d)"
else
    faltan=0
    for linea in "${lineas[@]}"; do
        perfil=${linea%%[[:space:]]*}
        if [ ! -e "$DIR/$perfil" ]; then
            mal "el perfil «$perfil» no existe en $DIR: la línea no hace nada"
            faltan=$((faltan + 1))
        fi
    done
    if [ "$faltan" -eq 0 ]; then
        ok "los ${#lineas[@]} perfiles de la lista existen"
    fi
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo en orden.\033[0m\n'
else
    printf '\033[31m%d comprobación(es) fallaron.\033[0m\n' "$fallos"
fi
exit $(( fallos > 0 ? 1 : 0 ))
