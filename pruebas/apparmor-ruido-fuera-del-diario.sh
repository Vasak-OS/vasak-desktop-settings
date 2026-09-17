#!/bin/bash
# Que el ruido de AppArmor no se coma el diario.
#
# Medido sobre un arranque de 15,5 h de uso normal: 78% de las líneas y **87%
# de los bytes** del diario eran AppArmor, y 38.247 de esas 38.249 líneas decían
# «ALLOWED» — perfiles en modo aviso anotando cosas que se permitieron. Cuatro
# perfiles ponían el 80%: git (41,6%), dockerd (18,8%), containerd/runc (18,3%)
# y gitstatusd (1%).
#
# Con eso y el tope de 50 MB que hereda de `cachyos-settings`, un equipo de una
# semana de uso guardaba **un solo arranque**. Y la semana de diario de la que
# depende el plan de `apparmor/flags.d/50-vasakos.conf` para pasar perfiles a
# enforce no se podía juntar. Ver Vasak-OS/vasak-desktop-settings#8.
#
# Lo que más importa comprobar acá es que el paquete los **instale**: este repo
# ya tuvo un archivo escrito y sin empaquetar durante meses —el drop-in de GRUB,
# que hacía que el menú de arranque siguiera diciendo «Arch»— porque `package()`
# copia archivo por archivo y nadie lo notó.
#
# Uso: pruebas/apparmor-ruido-fuera-del-diario.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fallos=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal() { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }
nota(){ printf '  \033[33m·\033[0m %s\n' "$1"; }

IGNORE=etc/apparmor/ignore.d/50-vasakos-ruido.conf
DIARIO=etc/systemd/journald.conf.d/50-vasakos-diario.conf
PKGBUILD=${VSK_PKGBUILD:-"../PKGBUILDS/vasak-desktop-settings-git/PKGBUILD"}

# Los cuatro que ponían el 80% del diario.
RUIDOSOS=(git gitstatusd dockerd containerd-shim-runc-v2)

printf '\n\033[1mEl ruido de AppArmor fuera del diario\033[0m\n'

# ── La lista de perfiles que no se instalan ──────────────────────────────────

if [ -f "$IGNORE" ]; then
    ok 'la lista de perfiles a ignorar está'
else
    mal "falta $IGNORE"
fi

faltan=()
for perfil in "${RUIDOSOS[@]}"; do
    grep -qx "$perfil" "$IGNORE" 2>/dev/null || faltan+=("$perfil")
done
if [ ${#faltan[@]} -eq 0 ]; then
    ok "nombra los cuatro ruidosos: ${RUIDOSOS[*]}"
else
    mal "no nombra: ${faltan[*]}"
fi

# El formato es «un perfil por línea», sin comas ni espacios: una línea mal
# escrita no falla, se ignora, y el perfil vuelve a instalarse en silencio.
sucias=$(grep -vE '^\s*(#.*)?$' "$IGNORE" 2>/dev/null | grep -cE '[[:space:],]' || true)
if [ "${sucias:-0}" -eq 0 ]; then
    ok 'y una línea por perfil, que es el formato que lee aa-install'
else
    mal "$sucias línea(s) con espacios o comas: aa-install las ignora sin avisar"
fi

# ── El tope del diario ───────────────────────────────────────────────────────

if [ -f "$DIARIO" ]; then
    ok 'el fragmento de journald está'
else
    mal "falta $DIARIO"
fi

if grep -qE '^SystemMaxUse=[0-9]+[MG]$' "$DIARIO" 2>/dev/null; then
    ok "sube el tope a $(grep -oP '(?<=^SystemMaxUse=).*' "$DIARIO")"
else
    mal 'no fija SystemMaxUse, o no con un tamaño que systemd entienda'
fi

# systemd ordena **todos** los fragmentos por nombre, vengan de donde vengan, y
# gana el último. El de `cachyos-settings` es `00-journal-size.conf`, así que
# cualquier nombre que empiece con un número mayor le gana. Si alguien renombra
# éste a algo que ordene antes, el tope vuelve a 50 MB sin que nada falle.
nuestro=$(basename "$DIARIO")
if [[ "$nuestro" > "00-journal-size.conf" ]]; then
    ok "y «$nuestro» ordena después de «00-journal-size.conf», así que gana"
else
    mal "«$nuestro» ordena antes que el de cachyos-settings: no tendría efecto"
fi

# Una clave fuera de [Journal] systemd la ignora sin decir nada.
if [ "$(grep -E '^\[' "$DIARIO" 2>/dev/null | tail -1)" = '[Journal]' ]; then
    ok 'y las claves están bajo [Journal]'
else
    mal 'las claves no quedaron bajo [Journal]'
fi

# ── Que el paquete los instale ───────────────────────────────────────────────

if [ -f "$PKGBUILD" ]; then
    for archivo in "$IGNORE" "$DIARIO"; do
        if grep -q "$archivo" "$PKGBUILD"; then
            ok "el paquete instala $(basename "$archivo")"
        else
            mal "$archivo está en el repo pero package() no lo copia"
        fi
    done
    # El descargador y su hook viajan en el `cp -r usr` entero, no archivo por
    # archivo. Si alguien pasara ese árbol a copiarse pieza por pieza —que es lo
    # que ya pasó con `etc/`— habría que nombrarlos, y esto lo avisa.
    if grep -qE 'cp -r .*\$pkgname/usr ' "$PKGBUILD"; then
        ok 'y el árbol usr/ entero, donde viajan el descargador y su hook'
    else
        mal 'usr/ ya no se copia entero: hay que nombrar el descargador y su hook'
    fi
else
    nota "sin $PKGBUILD a mano, no se comprueba que el paquete los instale"
fi

# ── Que lo que se deja de instalar se descargue del kernel ───────────────────
#
# Borrar el archivo de /etc/apparmor.d no descarga el perfil: sigue cargado y
# sigue anotando hasta el siguiente reinicio. Medido: `aa-install` dijo «Removed
# 4 stale files» y dos minutos después `git` había escrito 1597 líneas más.

DESCARGAR=usr/lib/vasak/descargar-perfiles-ignorados
HOOK=usr/share/libalpm/hooks/zz-vasak-apparmor-ignorados.hook

if [ -x "$DESCARGAR" ]; then
    ok 'el descargador está y es ejecutable'
else
    mal "falta $DESCARGAR, o no tiene permiso de ejecución"
fi

# Pacman ordena los hooks por nombre de archivo. `apparmor.hook` —el que borra
# los archivos— tiene que correr antes que éste, o no habría nada que descargar.
if [ -f "$HOOK" ]; then
    if [ "$(printf '%s\napparmor.hook\n' "$(basename "$HOOK")" | LC_ALL=C sort | tail -1)" = "$(basename "$HOOK")" ]; then
        ok 'y su hook corre después de apparmor.hook, que es el que borra los archivos'
    else
        mal 'el hook ordena antes que apparmor.hook: correría sin nada que descargar'
    fi
else
    mal "falta $HOOK"
fi

# Lo que de verdad importa: que saque los que están en la lista, que no toque
# nada más —`docker-default` se carga solo en marcha y sacarlo dejaría a los
# contenedores sin confinar— y que `git` no se lleve puesto a `gitstatusd`.
banco=$(mktemp -d)
mkdir -p "$banco/ignore.d"
cp "$IGNORE" "$banco/ignore.d/"
cat > "$banco/perfiles" <<'FIN'
git (complain)
gitstatusd (complain)
dockerd (complain)
containerd-shim-runc-v2 (complain)
containerd-shim-runc-v2//null-/usr/bin/runc (complain)
docker-default (enforce)
plocate (enforce)
vasak-keyring (complain)
FIN
: > "$banco/removidos"

VSK_PERFILES_CARGADOS="$banco/perfiles" \
VSK_PERFILES_REMOVER="$banco/removidos" \
VSK_IGNORE_D="$banco/ignore.d" \
    ./"$DESCARGAR"

# El archivo `.remove` del kernel recibe un nombre por escritura, sin salto de
# línea; acá se concatenan, así que se comprueba por contenido.
removidos=$(cat "$banco/removidos")
faltaron=()
for perfil in "${RUIDOSOS[@]}"; do
    case "$removidos" in *"$perfil"*) ;; *) faltaron+=("$perfil") ;; esac
done
if [ ${#faltaron[@]} -eq 0 ]; then
    ok 'descarga los cuatro que están en la lista'
else
    mal "no descargó: ${faltaron[*]}"
fi

intocables=()
for perfil in docker-default plocate vasak-keyring; do
    case "$removidos" in *"$perfil"*) intocables+=("$perfil") ;; esac
done
if [ ${#intocables[@]} -eq 0 ]; then
    ok 'y no toca los que no están en la lista, ni los que se cargan solos'
else
    mal "descargó de más: ${intocables[*]}"
fi

rm -rf "$banco"

# ── Contra el sistema, si está ───────────────────────────────────────────────
#
# Sólo lectura: `--status` no toca nada. Comprueba que aa-install lea de verdad
# el archivo, que es lo único que no se puede saber leyéndolo.

if command -v aa-install >/dev/null 2>&1 && [ -f "/etc/apparmor/ignore.d/$(basename "$IGNORE")" ]; then
    # Dos cosas: `aa-install` escribe el estado en **stderr**, y se guarda antes
    # de mirarlo porque con `pipefail` un `grep -q` le cierra el pipe en la
    # primera coincidencia y `aa-install` muere con SIGPIPE — o sea que la
    # comprobación fallaba justo cuando encontraba lo que buscaba.
    estado=$(aa-install --status 2>&1)
    if printf '%s\n' "$estado" | grep -q "$(basename "$IGNORE")"; then
        ok 'y aa-install en este equipo lo está leyendo'
    else
        mal 'aa-install no lo lista entre sus ignore.d'
    fi
else
    nota 'la lista todavía no está instalada en este equipo; se comprueba sola cuando lo esté'
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo bien.\033[0m\n'
else
    printf '\033[31m%s comprobación(es) fallaron.\033[0m\n' "$fallos"
fi
exit "$((fallos > 0 ? 1 : 0))"
