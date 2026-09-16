#!/bin/bash
# Que el vigilante de instantáneas no arranque cuando no hay instantáneas.
#
# El `.install` de este paquete hace `systemctl enable grub-btrfsd.service`, y
# esa unidad se queda mirando `/.snapshots` con inotify y se cae si el
# directorio no existe. En un sistema recién instalado no existe hasta la
# primera instantánea, así que la unidad quedaba en `systemctl --failed` desde
# el primer arranque.
#
# No rompe nada, y por eso importa: `systemctl --failed` es lo primero que se
# mira cuando algo anda mal, y un fallo que está desde siempre deja de leerse.
# Ya pasó diagnosticando la pantalla negra del medio en vivo —Vasak-OS/archiso#3—,
# donde hubo que descartarlo a mano antes de poder mirar lo demás.
#
# Uso: pruebas/grub-btrfsd-sin-instantaneas.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fallos=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal() { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }

DROPIN=usr/lib/systemd/system/grub-btrfsd.service.d/50-vasak-sin-instantaneas.conf
INSTALL=${VSK_INSTALL:-"../PKGBUILDS/vasak-desktop-settings-git/vasak-desktop-settings.install"}

printf '\n\033[1mgrub-btrfsd no falla sin instantáneas\033[0m\n'

if [ -f "$DROPIN" ]; then
    ok 'el drop-in está'
else
    mal "falta $DROPIN"
fi

# El directorio tiene que ser exactamente el que la unidad de upstream vigila.
# Si `grub-btrfsd` cambiara de directorio, la condición pasaría a proteger algo
# que no es, y el fallo volvería sin que nada avise.
if grep -q '^ConditionPathExists=/\.snapshots$' "$DROPIN" 2>/dev/null; then
    ok 'condiciona el arranque a que exista /.snapshots'
else
    mal 'la condición no está o no apunta a /.snapshots'
fi

# Una condición fuera de [Unit] la ignora systemd sin decir nada.
seccion=$(grep -E '^\[' "$DROPIN" 2>/dev/null | tail -1)
if [ "$seccion" = '[Unit]' ]; then
    ok 'y está en [Unit], que es donde systemd la lee'
else
    mal "la condición quedó bajo «${seccion:-ninguna sección}»"
fi

# Si el paquete dejara de habilitar la unidad, el drop-in sobra; y si la
# habilita, sin el drop-in vuelve el fallo. Van juntos o no van.
if grep -q 'systemctl enable grub-btrfsd.service' "$INSTALL" 2>/dev/null; then
    ok 'y el paquete sigue habilitando la unidad, que es a lo que esto responde'
else
    mal 'el paquete ya no habilita grub-btrfsd: revisar si el drop-in sigue teniendo sentido'
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo bien.\033[0m\n'
else
    printf '\033[31m%s comprobación(es) fallaron.\033[0m\n' "$fallos"
fi
exit "$((fallos > 0 ? 1 : 0))"
