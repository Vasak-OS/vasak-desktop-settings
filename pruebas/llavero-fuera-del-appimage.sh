#!/usr/bin/env bash
#
# Que un AppImage no llegue al llavero: ni a la base ni al socket de desbloqueo.
#
# El llavero tiene dos puertas. Una es la base, `~/.local/share/vasak-keyring/`,
# donde están todas las contraseñas de la sesión; el perfil la negaba desde
# antes. La otra es `/run/user/<uid>/vasak-keyring/unlock.sock`, el socket por
# donde el módulo PAM le entrega al demonio la contraseña al iniciar sesión, y
# ésa estaba abierta: el directorio y el socket son del usuario, así que un
# AppImage —que corre con la cuenta del usuario— podía conectarse sin más.
#
# # Por qué negarlo acá si el demonio ya lo rechaza
#
# Desde vasak-keyring#42 el demonio sólo le acepta el desbloqueo a root, y mira
# quién es el del otro lado con SO_PEERCRED. Eso alcanza mientras ese chequeo
# esté bien escrito y nadie lo toque. El perfil es la segunda valla: que un
# AppImage ni siquiera llegue a conectarse no puede depender de una sola línea
# de Rust en otro repositorio. Es defensa en profundidad, y la prueba existe
# para que una de las dos vallas no se caiga sin que nadie se entere.
#
# # Por qué hace falta la `w`
#
# Conectarse a un socket unix con nombre, para AppArmor, es **escribir** en esa
# ruta. Una regla que negara sólo `r` dejaría conectar igual. Por eso se exige
# que la negación del socket incluya `w`.
#
# # Por qué no alcanza con leer el archivo
#
# Que la línea esté no dice que AppArmor la entienda: un perfil que no compila
# no se carga, y un perfil que no se carga no niega nada —el AppImage corre sin
# confinar y desde afuera no se nota—. Por eso se compila con `apparmor_parser`.
# Y que compile tampoco dice que el núcleo la aplique; eso sólo lo dice un
# proceso confinado que intenta conectarse y es rechazado, que es la última
# parte, y sólo corre si el sistema tiene con qué.
#
# ⚠ Nada de `… | grep -q` con `pipefail`: `grep -q` cierra la tubería en cuanto
# encuentra, el productor muere con SIGPIPE y la condición da falso aunque haya
# encontrado. Va la salida a una variable y `grep` sobre una here-string.
#
# Uso: pruebas/llavero-fuera-del-appimage.sh
#      VSK_KEYRING=<checkout de vasak-keyring> para cruzar la ruta del socket
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PERFIL=etc/apparmor.d/vasak-appimage
KEYRING=${VSK_KEYRING:-../vasak-keyring}

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

# Sólo el cuerpo del perfil y sin comentarios. Una regla comentada, o escrita
# fuera de las llaves, se lee igual con `grep` y no hace nada: el parser la
# ignora o la rechaza, y el AppImage queda con la puerta abierta.
cuerpo=$(awk '
    /^profile vasak-appimage / { dentro = 1; next }
    dentro && /^}/             { dentro = 0 }
    dentro                     { sub(/#.*/, ""); print }
' "$PERFIL")

tema '== el perfil niega las dos puertas del llavero =='

# La base. `l` incluida: sin ella se crea un enlace duro desde afuera del
# directorio negado y se lee por ahí.
if grep -qE '^\s*audit deny @\{HOME\}/\.local/share/vasak-keyring/\*\* [rwkl]*r[rwkl]*,\s*$' <<<"$cuerpo" &&
   grep -qE '^\s*audit deny @\{HOME\}/\.local/share/vasak-keyring/\*\* [rwkl]*l[rwkl]*,\s*$' <<<"$cuerpo"; then
    ok "el perfil niega la base (~/.local/share/vasak-keyring), enlaces incluidos"
else
    mal "el perfil no niega la base del llavero: un AppImage lee todas las contraseñas"
fi

# El socket. Con `w`, que es lo que AppArmor pide para conectarse.
if grep -qE '^\s*audit deny /run/user/\*/vasak-keyring/\*\* [rwkl]*w[rwkl]*,\s*$' <<<"$cuerpo"; then
    ok "el perfil niega el socket de desbloqueo (/run/user/*/vasak-keyring/**)"
else
    mal "el perfil no niega /run/user/*/vasak-keyring/**: un AppImage se conecta a unlock.sock"
fi

# Y con `audit`: cada intento queda en el diario. Un `deny` sin `audit` no
# anota nada, y entonces no hay de dónde sacar «esta aplicación quiso entrar al
# llavero».
if grep -qE '^\s*deny /run/user/\*/vasak-keyring/' <<<"$cuerpo"; then
    mal "la negación del socket no lleva audit: los intentos no quedan en el diario"
else
    ok "y sin negaciones mudas: los intentos quedan anotados"
fi

tema '== la ruta que se niega es la que usa el demonio =='

# Si el demonio mueve el socket, la regla queda negando un directorio vacío y
# la prueba de arriba sigue en verde. Esto lo cruza contra el código, cuando
# hay un checkout de vasak-keyring a mano.
fuente="$KEYRING/src/unlock_socket.rs"
if [ -f "$fuente" ]; then
    codigo=$(cat "$fuente")
    if grep -qF '/run/user/{uid}/vasak-keyring' <<<"$codigo"; then
        ok "vasak-keyring escucha bajo /run/user/{uid}/vasak-keyring/, lo que el perfil niega"
    else
        mal "$fuente ya no pone el socket en /run/user/{uid}/vasak-keyring: la regla no lo alcanza"
    fi
else
    aviso "SIN COMPROBAR: no hay checkout de vasak-keyring en $KEYRING (VSK_KEYRING=…)"
fi

tema '== el perfil compila =='

if ! command -v apparmor_parser >/dev/null 2>&1; then
    aviso "SIN COMPROBAR: falta apparmor_parser (paquete apparmor)"
else
    # `--skip-kernel-load` compila sin cargar nada, así que no hace falta root
    # ni que AppArmor esté activo en el núcleo. `-I etc/apparmor.d` para que los
    # include salgan del repo y no de lo instalado.
    if salida=$(apparmor_parser --skip-kernel-load --skip-cache -Q \
                    -I etc/apparmor.d "$PERFIL" 2>&1); then
        ok "apparmor_parser lo compila"
    else
        mal "apparmor_parser no lo compila: el perfil no se carga y no niega nada"
        printf '%s\n' "$salida" | sed 's/^/      /'
    fi
fi

tema '== y en vivo: un proceso confinado no se conecta al socket =='

uid=$(id -u)
SOCKET=/run/user/$uid/vasak-keyring/unlock.sock

# Lo que se conecta. Sólo `connect` y cerrar: no manda nada, así que el demonio
# ve una conexión que se va sin hablar. Imprime «conectado» o el nombre del
# error, para distinguir «AppArmor lo negó» (EACCES) de «no hay nadie
# escuchando» (ECONNREFUSED), que también es un fallo de conexión pero no
# prueba nada.
sonda='
import errno, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect(sys.argv[1])
    print("conectado")
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)))
finally:
    s.close()
'

if ! command -v aa-enabled >/dev/null 2>&1 || ! aa-enabled -q 2>/dev/null; then
    aviso "SIN COMPROBAR: AppArmor no está activo en este núcleo"
    aviso "esta parte sólo se puede comprobar en un arranque con lsm=…,apparmor"
elif ! command -v aa-exec >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    aviso "SIN COMPROBAR: falta aa-exec (paquete apparmor) o python3"
elif ! cmp -s "$PERFIL" "/etc/apparmor.d/vasak-appimage"; then
    # Lo que está cargado en el núcleo es lo instalado, no lo de este árbol, y
    # cargar éste pide root. Probar contra otra versión daría un resultado que
    # no habla de este cambio, en ninguna dirección.
    aviso "SIN COMPROBAR: el perfil instalado no es el de este árbol"
    aviso "cargarlo pide root; se comprueba solo cuando este perfil esté instalado"
elif ! aa-exec -p vasak-appimage -- true 2>/dev/null; then
    aviso "SIN COMPROBAR: el perfil vasak-appimage no está cargado en el núcleo"
elif [ ! -S "$SOCKET" ]; then
    aviso "SIN COMPROBAR: no hay $SOCKET (¿no corre vasak-keyring en esta sesión?)"
else
    # El testigo: sin confinar, la misma sonda tiene que conectarse. Si no, el
    # rechazo de abajo podría ser de permisos o del demonio y no del perfil.
    libre=$(timeout 5 python3 -c "$sonda" "$SOCKET" 2>&1)
    confinado=$(timeout 5 aa-exec -p vasak-appimage -- python3 -c "$sonda" "$SOCKET" 2>&1)

    if [ "$libre" != "conectado" ]; then
        aviso "SIN COMPROBAR: ni sin confinar se conecta ($libre); el testigo no sirve"
    elif [ "$confinado" = "EACCES" ]; then
        ok "sin confinar se conecta; confinado, AppArmor lo rechaza (EACCES)"
    elif [ "$confinado" = "conectado" ]; then
        mal "un proceso con el perfil vasak-appimage se conectó a $SOCKET"
    else
        mal "confinado falló, pero no por AppArmor: «$confinado»"
    fi
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mSin fallos.\033[0m\n'
else
    printf '\033[31m%s fallo(s).\033[0m\n' "$fallos"
fi
exit $(( fallos > 0 ? 1 : 0 ))
