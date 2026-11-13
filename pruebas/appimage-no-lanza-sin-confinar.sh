#!/usr/bin/env bash
#
# Que un AppImage no pueda lanzar un proceso sin confinar (desktop-settings#13).
#
# Un proceso lanzado sin perfil queda con etiqueta `unconfined` y esquiva todas
# las puertas que miran la etiqueta (la de Lince y las demás). `change_profile`
# y `~/.config/systemd/user` ya se niegan en otras pruebas; acá van los otros
# caminos, en `etc/apparmor.d/vasak-appimage`:
#
# - D-Bus a `org.freedesktop.systemd1` (`systemd-run --user`, StartTransientUnit)
#   y el socket privado del gestor de usuario (`/run/user/*/systemd/private`).
#   Conectarse a un socket es escribir, de ahí la `w`.
#   También por interfaz (`systemd1.Manager`) y `systemd/user.control`.
# - Persistencia que corre al iniciar la sesión o un shell: `~/.config/autostart`,
#   `~/.config/environment.d`, `~/.config/uwsm`, `~/.config/wayfire.ini`, los
#   archivos de sesión X y los de arranque de bash y zsh.
#
# La regla vive sólo en un archivo de texto, así que la prueba mira el cuerpo
# del perfil sin comentarios y dentro de las llaves (una regla comentada o fuera
# de ellas se lee con `grep` y no hace nada), y además compila el perfil.
#
# Sin parte «en vivo»: probar una escritura o un systemd-run confinados ensuciaría
# el HOME y la sesión reales, y el perfil cargado en el núcleo es el instalado,
# no el de este árbol.
#
# ⚠ Nada de `… | grep -q` con `pipefail`: ver llavero-fuera-del-appimage.sh.
#
# Uso: pruebas/appimage-no-lanza-sin-confinar.sh
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
# La ruta queda anclada entre `deny ` y los flags: el nodo `/x` no casa con
# `/x/private` ni con `/x/**`.
tiene() {
    grep -qE "^\s*audit deny $1 [rwkl]*$2[rwkl]*,\s*\$" <<<"$cuerpo"
}

tema '== systemd del usuario: D-Bus y socket privado =='

if grep -qE '^\s*audit deny dbus send bus=session peer=\(name=org\.freedesktop\.systemd1\),\s*$' <<<"$cuerpo"; then
    ok "el perfil niega (con audit) enviar a org.freedesktop.systemd1 por el bus de sesión"
else
    mal "falta 'audit deny dbus send bus=session peer=(name=org.freedesktop.systemd1),': systemd-run --user lanza sin confinar"
fi

PRIV='/run/user/\*/systemd/private'
if tiene "$PRIV" w; then
    ok "el perfil niega escribir (conectar) el socket $PRIV"
else
    mal "$PRIV sin 'w': systemctl --user habla con el gestor sin D-Bus y lanza sin confinar"
fi

# Y por interfaz: si el AppImage resuelve el nombre único del gestor y le manda
# al `:1.N`, la regla por nombre podría no alcanzarlo.
if grep -qE '^\s*audit deny dbus send bus=session interface=org\.freedesktop\.systemd1\.Manager,\s*$' <<<"$cuerpo"; then
    ok "el perfil niega (con audit) enviar a la interfaz org.freedesktop.systemd1.Manager"
else
    mal "falta 'audit deny dbus send bus=session interface=org.freedesktop.systemd1.Manager,': mandando al :1.N se esquiva la regla por nombre"
fi

tema '== directorios que corren al iniciar la sesión =='

# Cada uno lleva la regla del contenido (`/**`) y la del nodo (el directorio
# mismo, por el rename + symlink), las dos con `w` y `l`.
for nodo in '/run/user/\*/systemd' \
            '@\{HOME\}/\.config/autostart' '@\{HOME\}/\.config/environment\.d' \
            '@\{HOME\}/\.config/uwsm' '@\{HOME\}/\.config/systemd/user\.control'; do
    for f in w l; do
        if tiene "$nodo" "$f"; then
            ok "el perfil niega el nodo $nodo con '$f'"
        else
            mal "falta 'audit deny $nodo …$f,': un AppImage renombra el directorio y lo redirige"
        fi
    done
    case $nodo in
        /run/*) continue ;;  # el socket no tiene regla de contenido propia
    esac
    for f in w l; do
        if tiene "$nodo/\\*\\*" "$f"; then
            ok "y la regla de contenido $nodo/** con '$f'"
        else
            mal "falta la regla de contenido $nodo/** con '$f': un AppImage deja un archivo que corre sin perfil"
        fi
    done
done

tema '== archivos de arranque del shell =='

# Incluye `wayfire.ini` (autostart primario de VasakOS: Wayfire corre sin perfil y
# ejecuta sus entradas) y los archivos de sesión X.
for arch in .bashrc .bash_profile .bash_login .profile .zshrc .zprofile .zshenv .zlogin \
            .config/wayfire.ini .xprofile .xsession .xinitrc; do
    ruta="@\\{HOME\\}/${arch//./\\.}"
    for f in w l; do
        if tiene "$ruta" "$f"; then
            ok "el perfil niega ~/$arch con '$f'"
        else
            mal "~/$arch sin '$f': un AppImage deja ahí algo que corre sin perfil en el próximo shell"
        fi
    done
done

tema '== y sin negaciones mudas =='

# Sin `audit` no queda en el diario el intento de lanzar algo sin confinar.
if grep -qE '^\s*deny (/run/user/\*/systemd|@\{HOME\}/(\.config/(autostart|environment\.d|uwsm|wayfire\.ini|systemd/user\.control)|\.(bashrc|bash_profile|bash_login|profile|zshrc|zprofile|zshenv|zlogin|xprofile|xsession|xinitrc))([/ ]))' <<<"$cuerpo" \
   || grep -qE '^\s*deny dbus .*org\.freedesktop\.systemd1' <<<"$cuerpo"; then
    mal "hay una negación sin audit sobre esas rutas o systemd1: los intentos no quedan anotados"
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
