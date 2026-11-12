#!/usr/bin/env bash
#
# Que un AppImage no pueda redirigir ni secuestrar a Lince (vasak-assistant).
#
# Tres rutas, tres negaciones en `etc/apparmor.d/vasak-appimage`:
#
# - `~/.config/vasak/**`: en `vasak.conf` vive la sección `assistant`
#   (`allow_remote`, URL, modelo). Reescribirla manda las conversaciones a otro
#   lado. Se niega escribir y enlazar (`wl`), NO leer: un AppImage puede querer
#   el esquema de color para integrarse al tema.
# - `~/.config/systemd/user/**`: con un drop-in `override.conf` y su
#   `ExecStart=`, un AppImage secuestra `vasak-assistant.service` y burla el
#   owner-check por cgroup (vasak-assistant#5).
# - `~/.local/state/vasak-assistant/**`: la memoria cifrada de Lince; sin la
#   regla, un AppImage la borra o la reemplaza.
#
# La regla vive sólo en un archivo de texto, así que la prueba mira el cuerpo
# del perfil sin comentarios y dentro de las llaves (una regla comentada o fuera
# de ellas se lee con `grep` y no hace nada), y además compila el perfil.
#
# Sin parte «en vivo»: probar una escritura confinada ensuciaría el HOME real y
# el perfil cargado en el núcleo es el instalado, no el de este árbol.
#
# ⚠ Nada de `… | grep -q` con `pipefail`: ver llavero-fuera-del-appimage.sh.
#
# Uso: pruebas/appimage-no-redirige-a-lince.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PERFIL=etc/apparmor.d/vasak-appimage

fallos=0
ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal()   { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }
aviso() { printf '  \033[33m·\033[0m %s\n' "$1"; }
tema()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

if [ ! -f "$PERFIL" ]; then
    mal "falta $PERFIL"
    printf '\n\033[31m1 fallo(s).\033[0m\n'
    exit 1
fi

cuerpo=$(awk '
    /^profile vasak-appimage / { dentro = 1; next }
    dentro && /^}/             { dentro = 0 }
    dentro                     { sub(/#.*/, ""); print }
' "$PERFIL")

# tiene <ruta-regex> <flag>: hay un `audit deny <ruta> <flags>,` con ese flag.
tiene() {
    grep -qE "^\s*audit deny $1 [rwkl]*$2[rwkl]*,\s*\$" <<<"$cuerpo"
}

tema '== la config de VasakOS: se niega escribir, no leer =='

CONF='@\{HOME\}/\.config/vasak/\*\*'
if tiene "$CONF" w; then
    ok "el perfil niega escribir ~/.config/vasak/** (la sección assistant de vasak.conf)"
else
    mal "el perfil no niega escribir ~/.config/vasak/**: un AppImage reescribe allow_remote/URL de Lince"
fi
if tiene "$CONF" l; then
    ok "y niega los enlaces duros, que escribirían por afuera del directorio"
else
    mal "la negación de ~/.config/vasak/** no incluye l: queda el enlace duro"
fi
if grep -qE "^\s*audit deny $CONF [rwkl]*r[rwkl]*,\s*\$" <<<"$cuerpo"; then
    mal "~/.config/vasak/** niega también la lectura: un AppImage no puede leer el esquema de color"
else
    ok "y no niega leer: el AppImage sigue pudiendo leer el esquema para el tema"
fi

tema '== las unidades de usuario de systemd =='

SYSD='@\{HOME\}/\.config/systemd/user/\*\*'
for f in r w k l; do
    if tiene "$SYSD" "$f"; then
        ok "el perfil niega ~/.config/systemd/user/** con '$f'"
    else
        mal "~/.config/systemd/user/** sin '$f': un AppImage deja un override.conf y secuestra vasak-assistant.service"
    fi
done

tema '== la memoria cifrada de Lince =='

MEM='@\{HOME\}/\.local/state/vasak-assistant/\*\*'
for f in r w k l; do
    if tiene "$MEM" "$f"; then
        ok "el perfil niega ~/.local/state/vasak-assistant/** con '$f'"
    else
        mal "~/.local/state/vasak-assistant/** sin '$f': un AppImage borra o reemplaza la memoria de Lince"
    fi
done

tema '== el nodo del directorio, no sólo su contenido =='

# `<ruta>/**` niega el contenido pero no el directorio mismo: un AppImage podía
# hacer rename() + symlink() del nodo y leer o redirigir por el nombre nuevo.
# Por eso conviven dos reglas por ruta: la del contenido (`/**`) y la del nodo
# (`<ruta> wl`). La del nodo termina en la ruta + flags, sin `/` ni `**`.
for nodo in '@\{HOME\}/\.config/vasak' '@\{HOME\}/\.config/systemd/user' \
            '@\{HOME\}/\.local/state/vasak-assistant'; do
    for f in w l; do
        if tiene "$nodo" "$f"; then
            ok "el perfil niega el nodo $nodo con '$f'"
        else
            mal "falta 'audit deny $nodo …$f,': un AppImage renombra el directorio y lo redirige"
        fi
    done
    if tiene "$nodo/\\*\\*" w; then
        ok "y la regla de contenido $nodo/** sigue ahí"
    else
        mal "se perdió la regla de contenido $nodo/**: el nodo solo no niega lo de adentro"
    fi
    if grep -qE "^\s*deny $nodo [rwkl]*,\s*\$" <<<"$cuerpo"; then
        mal "el nodo $nodo se niega sin audit: el intento no queda anotado"
    fi
done

tema '== y sin negaciones mudas =='

# Sin `audit` no queda nada en el diario de «esta aplicación quiso tocar a Lince».
if grep -qE '^\s*deny @\{HOME\}/(\.config/(vasak|systemd/user)/|\.local/state/vasak-assistant/)' <<<"$cuerpo"; then
    mal "hay una negación sin audit sobre las rutas de Lince: los intentos no quedan anotados"
else
    ok "ninguna negación muda sobre esas rutas"
fi

tema '== el perfil compila =='

if ! command -v apparmor_parser >/dev/null 2>&1; then
    aviso "SIN COMPROBAR: falta apparmor_parser (paquete apparmor)"
elif salida=$(apparmor_parser --skip-kernel-load --skip-cache -Q \
                  -I etc/apparmor.d "$PERFIL" 2>&1); then
    ok "apparmor_parser lo compila"
else
    mal "apparmor_parser no lo compila: el perfil no se carga y no niega nada"
    printf '%s\n' "$salida" | sed 's/^/      /'
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mSin fallos.\033[0m\n'
else
    printf '\033[31m%s fallo(s).\033[0m\n' "$fallos"
fi
exit $(( fallos > 0 ? 1 : 0 ))
