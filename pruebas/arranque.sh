#!/bin/bash
# Que la copia del arranque y su restauración hagan lo que dicen.
#
# Se ejercitan contra directorios temporales, no contra /boot: los dos scripts
# aceptan origen y destino por argumento justamente para esto.
#
# Lo que se comprueba es lo que rompe callado. Un kernel que no se copia, o uno
# viejo que no se borra, no da ningún error: da un menú de arranque con una
# entrada que arranca mal, y eso se descubre reiniciando.
set -uo pipefail

AQUI=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COPIAR="$AQUI/../usr/lib/vasak/copiar-arranque"
RESTAURAR="$AQUI/../usr/lib/vasak/restaurar-arranque"

fallos=0
mal() { echo "  FALLA: $*" >&2; fallos=$((fallos + 1)); }
bien() { echo "  ok: $*"; }

# Un /boot como el que deja el instalador: dos kernels no, uno solo, con sus dos
# initramfs y el microcódigo.
armar_boot() {
    local dir=$1
    mkdir -p "$dir"
    echo "kernel 6.1" > "$dir/vmlinuz-linux"
    echo "initramfs 6.1" > "$dir/initramfs-linux.img"
    echo "fallback 6.1" > "$dir/initramfs-linux-fallback.img"
    echo "ucode" > "$dir/intel-ucode.img"
    # Lo que también vive en el ESP y no tiene que copiarse: son 8 MiB de
    # cargador que la instantánea no necesita y que restaurar pisaría.
    mkdir -p "$dir/EFI/GRUB"
    echo "cargador" > "$dir/EFI/GRUB/grubx64.efi"
    echo "config" > "$dir/grub.cfg"
}

echo "== se copia el kernel, su initramfs y el microcódigo =="
tmp=$(mktemp -d); boot="$tmp/boot"; copia="$tmp/copia"
armar_boot "$boot"
"$COPIAR" "$boot" "$copia" || mal "el copiador salió con error"
for esperado in vmlinuz-linux initramfs-linux.img initramfs-linux-fallback.img intel-ucode.img; do
    [ -f "$copia/$esperado" ] || mal "no se copió $esperado"
done
[ $fallos -eq 0 ] && bien "los cuatro archivos están en la copia"

echo "== no se copia lo que no es del arranque =="
antes=$fallos
[ -e "$copia/grub.cfg" ] && mal "se copió grub.cfg, que es del cargador"
[ -e "$copia/EFI" ] && mal "se copió el directorio EFI"
[ $fallos -eq $antes ] && bien "el cargador y su configuración se quedan en el ESP"

echo "== una segunda pasada sin cambios no reescribe nada =="
# Importa por el disco: reescribir en btrfs crea extensiones nuevas, así que
# copiar de más cuesta 150 MiB en la próxima instantánea aunque nada haya
# cambiado. Se mira la fecha de modificación del inodo.
antes=$fallos
marca=$(stat -c %Y.%i "$copia/vmlinuz-linux")
sleep 1.1
"$COPIAR" "$boot" "$copia" || mal "la segunda pasada salió con error"
[ "$(stat -c %Y.%i "$copia/vmlinuz-linux")" = "$marca" ] || mal "reescribió un archivo idéntico"
[ $fallos -eq $antes ] && bien "un archivo que no cambió se deja como está"

echo "== una actualización de kernel se propaga =="
antes=$fallos
echo "kernel 6.2" > "$boot/vmlinuz-linux"
echo "initramfs 6.2" > "$boot/initramfs-linux.img"
"$COPIAR" "$boot" "$copia" || mal "salió con error"
[ "$(cat "$copia/vmlinuz-linux")" = "kernel 6.2" ] || mal "la copia quedó con el kernel viejo"
[ $fallos -eq $antes ] && bien "la copia sigue al kernel nuevo"

echo "== desinstalar un kernel lo saca de la copia =="
antes=$fallos
echo "kernel lts" > "$boot/vmlinuz-linux-lts"
"$COPIAR" "$boot" "$copia"
[ -f "$copia/vmlinuz-linux-lts" ] || mal "no se copió el kernel agregado"
rm "$boot/vmlinuz-linux-lts"
"$COPIAR" "$boot" "$copia"
[ -e "$copia/vmlinuz-linux-lts" ] && mal "el kernel desinstalado sigue en la copia"
[ $fallos -eq $antes ] && bien "la copia no acumula kernels que ya no están"

echo "== restaurar devuelve el kernel de la instantánea =="
# El escenario entero: se toma la copia con el kernel 6.2, después el sistema
# actualiza a 6.3, y después se vuelve a la instantánea.
antes=$fallos
tmp2=$(mktemp -d); boot2="$tmp2/boot"; copia2="$tmp2/copia"
armar_boot "$boot2"
"$COPIAR" "$boot2" "$copia2"                      # instantánea con 6.1
echo "kernel 6.3" > "$boot2/vmlinuz-linux"        # el sistema actualiza
echo "initramfs 6.3" > "$boot2/initramfs-linux.img"
"$RESTAURAR" "$copia2" "$boot2" >/dev/null || mal "restaurar salió con error"
[ "$(cat "$boot2/vmlinuz-linux")" = "kernel 6.1" ] || \
    mal "después de restaurar, /boot sigue con el kernel nuevo"
[ "$(cat "$boot2/initramfs-linux.img")" = "initramfs 6.1" ] || \
    mal "después de restaurar, el initramfs es el nuevo"
[ $fallos -eq $antes ] && bien "/boot vuelve al kernel que trae la instantánea"

echo "== restaurar no toca el cargador =="
antes=$fallos
[ -f "$boot2/EFI/GRUB/grubx64.efi" ] || mal "se borró el cargador del ESP"
[ -f "$boot2/grub.cfg" ] || mal "se borró grub.cfg"
[ $fallos -eq $antes ] && bien "el cargador queda en su lugar"

echo "== restaurar saca el kernel que la instantánea no conoce =="
# Un kernel instalado después de la instantánea no tiene módulos en ella: si
# queda en /boot, el menú ofrece arrancarlo y no levanta ni la red.
antes=$fallos
echo "kernel zen" > "$boot2/vmlinuz-linux-zen"
"$RESTAURAR" "$copia2" "$boot2" >/dev/null
[ -e "$boot2/vmlinuz-linux-zen" ] && mal "quedó un kernel que la instantánea no trae"
[ $fallos -eq $antes ] && bien "los kernels de más se eliminan"

echo "== sin copia, restaurar falla y lo dice =="
antes=$fallos
tmp3=$(mktemp -d)
if "$RESTAURAR" "$tmp3/no-existe" "$tmp3" >/dev/null 2>&1; then
    mal "restaurar dijo que salió bien sin tener nada que restaurar"
fi
[ $fallos -eq $antes ] && bien "una instantánea vieja da un error claro, no un silencio"

echo "== un /boot vacío no rompe nada =="
antes=$fallos
tmp4=$(mktemp -d)
mkdir -p "$tmp4/boot" "$tmp4/copia"
"$COPIAR" "$tmp4/boot" "$tmp4/copia" || mal "el copiador falló con /boot vacío"
[ $fallos -eq $antes ] && bien "sin kernels no hace nada y no falla"

rm -rf "$tmp" "$tmp2" "$tmp3" "$tmp4"

if [ $fallos -gt 0 ]; then
    echo "FALLARON $fallos comprobaciones" >&2
    exit 1
fi
echo "Todo bien."
