#!/usr/bin/env bash
#
# Que se sepa cuándo se está parado en una instantánea.
#
# Desde que el menú de GRUB ofrece arrancar una versión anterior, el escritorio
# se ve **exactamente igual** dentro de una instantánea que en el sistema de
# todos los días. Las dos diferencias aparecen tarde: la raíz está de sólo
# lectura, así que lo que se instale o configure se pierde al reiniciar; y
# `/home` no lo está —es otro subvolumen— así que se puede trabajar una tarde
# entera sin notarlo.
#
# Lo que se prueba es la parte que decide, con los datos inyectados: qué
# subvolumen está montado, con qué opciones, y qué dice el registro de pacman de
# esa raíz. Montar una instantánea de verdad pide root y un disco btrfs, y lo
# que puede salir mal no es el montaje: es el reconocimiento.
#
# Uso: pruebas/aviso-del-arranque.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

ESTADO=usr/lib/vasak/boot-state
AVISO=usr/lib/vasak/boot-notice
UNIDAD=usr/lib/systemd/user/vasak-boot-notice.service
fallos=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal() { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }
tema(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

taller=$(mktemp -d)
trap 'rm -rf "$taller"' EXIT
printf '[2026-09-17T09:12:33-0300] [PACMAN] Running...\n[2026-09-18T20:01:02-0300] [ALPM] upgraded linux (1-1 -> 2-1)\n' > "$taller/pacman.log"

campo() { sed -n "s/^$2=//p" <<<"$1"; }

tema '== reconocer dónde está montada la raíz =='

salida=$("$ESTADO" "/@" "$taller/pacman.log" "rw,relatime,subvol=/@")
if [ "$(campo "$salida" instantanea)" = "no" ]; then
    ok "un arranque normal no es una instantánea"
else
    mal "un arranque normal se tomó por instantánea: $salida"
fi

# Las dos formas en las que aparece, según cómo esté armado el disco.
for subvol in "/@/.snapshots/42/snapshot" "/.snapshots/42/snapshot"; do
    salida=$("$ESTADO" "$subvol" "$taller/pacman.log" "ro,relatime,subvol=$subvol")
    if [ "$(campo "$salida" instantanea)" = "42" ]; then
        ok "reconoce «$subvol» y dice el número"
    else
        mal "no reconoció «$subvol»: $salida"
    fi
done

# Una carpeta que se llame parecido no es una instantánea. Sin esto, cualquiera
# que monte su raíz en un subvolumen con ese nombre recibiría el aviso para
# siempre.
salida=$("$ESTADO" "/@/.snapshots-viejas/42/snapshot" "$taller/pacman.log" "rw")
if [ "$(campo "$salida" instantanea)" = "no" ]; then
    ok "y no confunde un nombre parecido"
else
    mal "tomó por instantánea un subvolumen que no lo es: $salida"
fi

tema '== sólo lectura, que es lo que se pierde sin saber =='

salida=$("$ESTADO" "/@/.snapshots/42/snapshot" "$taller/pacman.log" "ro,relatime")
[ "$(campo "$salida" solo_lectura)" = "si" ] \
    && ok "una raíz montada ro se anuncia como tal" \
    || mal "no vio el ro: $salida"

# `snapper rollback` deja la instantánea **escribible** como raíz. Ahí no se
# pierde nada y el aviso tiene que decir otra cosa.
salida=$("$ESTADO" "/@/.snapshots/42/snapshot" "$taller/pacman.log" "rw,relatime")
[ "$(campo "$salida" solo_lectura)" = "no" ] \
    && ok "y una escribible también, que es otro caso" \
    || mal "dijo sólo lectura sobre una raíz rw: $salida"

# `rw` no puede leerse como `ro` por estar adentro de otra palabra.
salida=$("$ESTADO" "/@" "$taller/pacman.log" "rw,errors=remount-ro")
[ "$(campo "$salida" solo_lectura)" = "no" ] \
    && ok "y «remount-ro» no la vuelve de sólo lectura" \
    || mal "una opción que contiene «ro» la dio por sólo lectura: $salida"

tema '== de cuándo es el sistema en el que uno está parado =='

salida=$("$ESTADO" "/@" "$taller/pacman.log" "rw")
[ "$(campo "$salida" fecha)" = "2026-09-18" ] \
    && ok "la fecha sale de la última transacción de esa raíz" \
    || mal "fecha equivocada: $salida"

salida=$("$ESTADO" "/@" "$taller/no-existe.log" "rw")
[ "$(campo "$salida" fecha)" = "desconocida" ] \
    && ok "y sin registro lo dice en vez de inventar una" \
    || mal "sin registro no dijo «desconocida»: $salida"

tema '== el aviso =='

# Un `gdbus` de mentira, para no mandarle una notificación a nadie por correr
# las pruebas —y para poder mirar qué diría—.
mkdir -p "$taller/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/aviso.txt"\n' "$taller" > "$taller/bin/gdbus"
chmod +x "$taller/bin/gdbus"

rm -f "$taller/aviso.txt"
PATH="$taller/bin:$PATH" "$AVISO" "$(printf 'instantanea=no\nsolo_lectura=no\nfecha=2026-09-18\n')" >/dev/null 2>&1
if [ ! -f "$taller/aviso.txt" ]; then
    ok "un arranque normal no avisa nada"
else
    mal "avisó en un arranque normal: $(tr '\n' ' ' < "$taller/aviso.txt")"
fi

rm -f "$taller/aviso.txt"
PATH="$taller/bin:$PATH" "$AVISO" "$(printf 'instantanea=42\nsolo_lectura=si\nfecha=2026-09-18\n')" >/dev/null 2>&1
if [ -f "$taller/aviso.txt" ]; then
    ok "y una instantánea sí"
    cuerpo=$(cat "$taller/aviso.txt")
    for dato in "42" "2026-09-18" "sólo lectura" "carpeta personal"; do
        grep -qF "$dato" <<<"$cuerpo" \
            && ok "  el aviso dice «$dato»" \
            || mal "  al aviso le falta «$dato»"
    done
else
    mal "no avisó estando en una instantánea"
fi

tema '== y la unidad que lo dispara =='

if [ -f "$UNIDAD" ]; then
    ok "la unidad existe"
    grep -qE '^WantedBy=graphical-session\.target' "$UNIDAD" \
        && ok "y se engancha a la sesión gráfica" \
        || mal "la unidad no se engancha a graphical-session.target: no la arranca nadie"
    grep -qE '^ExecStart=/usr/lib/vasak/boot-notice' "$UNIDAD" \
        && ok "y corre el aviso" \
        || mal "la unidad no corre /usr/lib/vasak/boot-notice"
else
    mal "falta $UNIDAD"
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo en orden.\033[0m\n'
else
    printf '\033[31m%d comprobación(es) fallaron.\033[0m\n' "$fallos"
fi
exit $(( fallos > 0 ? 1 : 0 ))
