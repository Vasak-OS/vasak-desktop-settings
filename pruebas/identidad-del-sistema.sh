#!/bin/bash
# Que el sistema sepa decir quién es, y que lo diga un paquete.
#
# Un VasakOS instalado decía «Arch Linux». No por un archivo mal escrito: el
# archivo estaba bien y **nadie lo instalaba**. `/etc/os-release` no lo poseía
# ningún paquete —`filesystem` trae `/usr/lib/os-release` y nada más—, el destino
# se arma con `pacstrap` y no copiando el squashfs de la ISO, así que lo único
# que llegaba al equipo instalado era el de `filesystem`. Lo mismo con
# `/etc/vasakos/vasakos-release`, que es el archivo que los documentos de reporte
# de bugs le piden a la gente: existe en el repositorio desde 2023 y `cat` sobre
# él contestaba «No existe el fichero o el directorio».
#
# Por eso lo que más importa comprobar acá es que el paquete los **instale**.
# Este repositorio ya tuvo dos veces un archivo escrito y sin empaquetar —el
# drop-in de GRUB, que dejó el menú de arranque diciendo «Arch» durante meses, y
# la lista de perfiles de AppArmor—, porque `package()` copia archivo por archivo
# y nadie lo nota hasta que alguien mira el equipo instalado.
#
# La otra mitad es la toma de la ruta. En un equipo donde `/etc/os-release` ya
# existe sin dueño, pacman corta la transacción entera con «exists in filesystem»
# y ningún scriptlet lo puede evitar: el conflicto se mira **antes** de correr
# ninguno. Declarar el archivo en `backup=()` es lo único que deja tomar la ruta,
# y el precio es un `.pacnew` que el `.install` resuelve una sola vez.
#
# Uso: pruebas/identidad-del-sistema.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fallos=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal() { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }
nota(){ printf '  \033[33m·\033[0m %s\n' "$1"; }

OSRELEASE=etc/os-release
RELEASE=etc/vasakos/vasakos-release
# Los dos viven en el repositorio PKGBUILDS, que no siempre está al lado. Desde
# el `check()` llegan por variable, porque ahí este repo está en `$srcdir`.
PKGBUILD=${VSK_PKGBUILD:-"../PKGBUILDS/vasak-desktop-settings-git/PKGBUILD"}
INSTALL=${VSK_INSTALL:-"../PKGBUILDS/vasak-desktop-settings-git/vasak-desktop-settings.install"}

printf '\n\033[1mLa identidad del sistema\033[0m\n'

# ── El archivo que contesta «quién sos» ──────────────────────────────────────
printf '\n  \033[1m/etc/os-release\033[0m\n'

if [ ! -f $OSRELEASE ]; then
    mal "no está $OSRELEASE"
else
    # Lo leen programas que lo interpretan como shell (systemd, fastfetch,
    # `. /etc/os-release`). Una comilla sin cerrar no rompe el archivo: rompe al
    # que lo lee, y de una manera que no se parece en nada a la causa.
    if ( set -e; . ./$OSRELEASE ) 2>/dev/null; then
        ok "se puede leer como shell"
    else
        mal "$OSRELEASE no se puede interpretar: hay una comilla o un = suelto"
    fi

    # shellcheck disable=SC1090
    . ./$OSRELEASE 2>/dev/null

    antes=$fallos
    for clave in NAME PRETTY_NAME ID ID_LIKE VERSION VERSION_ID BUILD_ID \
                 HOME_URL BUG_REPORT_URL LOGO; do
        [ -n "${!clave:-}" ] || mal "falta $clave"
    done
    [ $fallos -eq $antes ] && ok "están las diez claves que alguien lee"

    # El par que estuvo al revés una vez: «ID=arch, ID_LIKE=vasakos» dice «soy
    # Arch y me parezco a VasakOS», que es lo contrario de lo que se quiere.
    if [ "${ID:-}" = vasakos ] && [ "${ID_LIKE:-}" = arch ]; then
        ok "ID=vasakos, ID_LIKE=arch (y no al revés)"
    else
        mal "el par ID/ID_LIKE es «${ID:-}»/«${ID_LIKE:-}» y tiene que ser vasakos/arch"
    fi

    # `VERSION_ID` lo comparan programas. La especificación lo limita a
    # [A-Za-z0-9._-]: un espacio ahí es lo que hace que una comparación conteste
    # que no en vez de fallar.
    if [[ ${VERSION_ID:-} =~ ^[A-Za-z0-9._-]+$ ]]; then
        ok "VERSION_ID=$VERSION_ID no tiene nada que no se pueda comparar"
    else
        mal "VERSION_ID=«${VERSION_ID:-}» tiene caracteres fuera de [A-Za-z0-9._-]"
    fi
fi

# ── Que la versión sea una sola ──────────────────────────────────────────────
printf '\n  \033[1mLa versión, en los dos lugares que la dicen\033[0m\n'

# Son dos archivos con el mismo dato: el que leen las personas
# (`/etc/vasakos/vasakos-release`, que es lo que piden los documentos de reporte
# de bugs) y el que leen los programas (`VERSION=` de os-release, que es de donde
# lo saca vasak-settings). Nada obliga a que coincidan, y eso ya pasó con las
# fuentes de este mismo paquete: tres archivos y tres respuestas distintas.
if [ ! -f $RELEASE ]; then
    mal "no está $RELEASE"
else
    publicada=$(tr -d '[:space:]' < $RELEASE)   # v0.6.2-Beta
    numero=${publicada#v}                        # 0.6.2-Beta
    numero=${numero%%-*}                         # 0.6.2
    etapa=${publicada#*-}                        # Beta
    [ "$etapa" = "$publicada" ] && etapa=""

    if [ "${VERSION_ID:-}" = "$numero" ]; then
        ok "VERSION_ID y $RELEASE dicen los dos $numero"
    else
        mal "VERSION_ID=«${VERSION_ID:-}» y $RELEASE dice «$publicada» (esperaba $numero)"
    fi

    esperada=$numero${etapa:+ $etapa}
    if [ "${VERSION:-}" = "$esperada" ]; then
        ok "VERSION=«$esperada»"
    else
        mal "VERSION=«${VERSION:-}» y por $RELEASE tendría que ser «$esperada»"
    fi
fi

# ── Que el paquete los instale ───────────────────────────────────────────────
printf '\n  \033[1mEl PKGBUILD\033[0m\n'

if [ ! -f "$PKGBUILD" ]; then
    nota "no está $PKGBUILD: se saltea (vive en el repositorio PKGBUILDS)"
else
    antes=$fallos
    for archivo in $OSRELEASE $RELEASE; do
        # `package()` copia archivo por archivo. Se busca el destino, que es lo
        # que decide si el archivo llega al equipo.
        if ! grep -qF "\$pkgdir/$archivo" "$PKGBUILD"; then
            mal "package() no instala $archivo"
        fi
    done
    [ $fallos -eq $antes ] && ok "package() instala los dos archivos"

    # Sin esto, actualizar en un equipo que ya tiene /etc/os-release sin dueño
    # corta la transacción entera. Medido: pacman contesta «exists in
    # filesystem» y no instala nada, ni siquiera el resto del paquete.
    if grep -qE "^backup=\(.*'etc/os-release'.*\)" "$PKGBUILD"; then
        ok "etc/os-release está declarado en backup=()"
    else
        mal "falta backup=('etc/os-release') en el PKGBUILD: la actualización va a"
        mal "  fallar con «exists in filesystem» donde el archivo ya exista sin dueño"
    fi
fi

# ── Y que el .pacnew se resuelva ─────────────────────────────────────────────
printf '\n  \033[1mLa toma de la ruta\033[0m\n'

if [ ! -f "$INSTALL" ]; then
    nota "no está $INSTALL: se saltea (vive en el repositorio PKGBUILDS)"
else
    # Copia de lo que hace el `post_install`, con el camino como argumento: el de
    # verdad trabaja sobre /etc y además prende servicios, así que no se puede
    # correr. Más abajo se comprueba que la copia siga siendo la del `.install`.
    resolver() {
        if [ -f "$1.pacnew" ]; then
            if grep -q '^ID=vasakos$' "$1" 2>/dev/null; then
                echo "se deja"
            else
                mv "$1.pacnew" "$1"
                echo "reemplazado"
            fi
        else
            echo "nada"
        fi
    }

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    # 1. El equipo que venía de otra distribución: el archivo de abajo es ajeno.
    printf 'NAME="CachyOS"\nID=cachyos\n' > "$tmp/ajeno"
    cp $OSRELEASE "$tmp/ajeno.pacnew"
    if [ "$(resolver "$tmp/ajeno")" = reemplazado ] && \
       grep -q '^ID=vasakos$' "$tmp/ajeno" && [ ! -e "$tmp/ajeno.pacnew" ]; then
        ok "un /etc/os-release de otra distribución se reemplaza por el nuestro"
    else
        mal "el /etc/os-release ajeno no se reemplazó: el equipo sigue diciendo que es otro"
    fi

    # 2. El que ya se identifica como VasakOS: lo editó alguien y se respeta.
    printf 'NAME="VasakOS Linux"\nID=vasakos\nPRETTY_NAME="El mío"\n' > "$tmp/propio"
    cp $OSRELEASE "$tmp/propio.pacnew"
    if [ "$(resolver "$tmp/propio")" = "se deja" ] && \
       grep -q 'El mío' "$tmp/propio" && [ -e "$tmp/propio.pacnew" ]; then
        ok "un /etc/os-release que ya dice VasakOS no se pisa"
    else
        mal "se pisó un /etc/os-release que ya identificaba a VasakOS"
    fi

    # 3. La instalación limpia, que es la que no tiene que hacer nada.
    cp $OSRELEASE "$tmp/limpio"
    if [ "$(resolver "$tmp/limpio")" = nada ]; then
        ok "sin .pacnew no se toca nada"
    else
        mal "se hizo algo sin .pacnew"
    fi

    # Que lo de arriba sea el código que corre de verdad. Sin esto la copia
    # aprueba una lógica que el `.install` podría ya no tener — que es justo el
    # día en que el test serviría.
    antes=$fallos
    esperadas=(
        'if [ -f /etc/os-release.pacnew ]; then'
        "grep -q '^ID=vasakos\$' /etc/os-release"
        'mv /etc/os-release.pacnew /etc/os-release'
    )
    for linea in "${esperadas[@]}"; do
        grep -qF -- "$linea" "$INSTALL" || mal "el .install ya no tiene: $linea"
    done
    [ $fallos -eq $antes ] && ok "las tres líneas copiadas siguen siendo las del .install"
fi

printf '\n'
if [ $fallos -gt 0 ]; then
    printf '\033[31mFallaron %d comprobaciones\033[0m\n' "$fallos" >&2
    exit 1
fi
printf '\033[32mTodo bien: el sistema dice que es VasakOS, y lo dice un paquete.\033[0m\n'
