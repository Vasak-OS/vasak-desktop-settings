#!/usr/bin/env bash
#
# Que el endurecimiento del sistema base esté entero y llegue al equipo: red y
# core dumps (sysctl), SSH del servidor, y `/tmp`.
#
# # Por qué existe
#
# Son defaults del kernel y de systemd que en un escritorio sólo abren
# superficie, y que en los equipos que vienen de CachyOS dependían de
# `cachyos-settings`, que VasakOS no exige. Si el archivo falta o pierde una
# línea no falla nada y no avisa: el equipo queda aceptando ICMP redirects,
# sin filtro de ruta inversa o con `/tmp` sin `nodev,nosuid`, y se ve idéntico
# a uno endurecido hasta que alguien lo ataca.
#
# Lo contrario también rompe callado, y por eso hay negativos:
#   - `PasswordAuthentication` no se fija: apagarlo deja afuera a quien entra
#     por SSH con contraseña; es decisión de quien usa el equipo.
#   - `noexec` en `/tmp` no va: VasakOS corre AppImages e instaladores desde ahí.
#
# Y que el paquete los instale. `50-vasakos-ptrace.conf` estaba en el repo y el
# `package()` nunca lo copiaba: un sysctl de seguridad que no llegaba al equipo.
#
# Uso: [RECETA=ruta/al/PKGBUILD] pruebas/endurecimiento-del-sistema-base.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

SYSCTL=etc/sysctl.d/50-vasakos-red.conf
SSHD=etc/ssh/sshd_config.d/50-vasakos-hardening.conf
TMPMOUNT=etc/systemd/system/tmp.mount.d/50-vasakos.conf
RECETA=${RECETA:-../PKGBUILDS/vasak-desktop-settings-git/PKGBUILD}

fallos=0
ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal()   { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }
aviso() { printf '  \033[33m·\033[0m %s\n' "$1"; }
tema()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Valor efectivo de `clave = valor` (sysctl) o `Clave valor` (sshd): ignora
# comentarios y se queda con el último, como hace el kernel al cargar.
valor_de() { # archivo clave
    sed -E 's/#.*//' "$1" 2>/dev/null \
        | sed -nE "s/^[[:space:]]*$2[[:space:]]*=?[[:space:]]*([^[:space:]]+).*/\1/p" \
        | tail -1
}

exige() { # archivo clave esperado
    local v
    v=$(valor_de "$1" "$2")
    if [ "$v" = "$3" ]; then
        ok "$2 = $3"
    else
        mal "$2 debería valer $3 y vale '${v:-<sin fijar>}'"
    fi
}

tema '== sysctl de red y core dumps =='

if [ ! -f "$SYSCTL" ]; then
    mal "falta $SYSCTL"
else
    for ambito in all default; do
        exige "$SYSCTL" "net.ipv4.conf.$ambito.accept_redirects" 0
        exige "$SYSCTL" "net.ipv6.conf.$ambito.accept_redirects" 0
        exige "$SYSCTL" "net.ipv4.conf.$ambito.send_redirects" 0
        exige "$SYSCTL" "net.ipv4.conf.$ambito.secure_redirects" 0
        exige "$SYSCTL" "net.ipv4.conf.$ambito.rp_filter" 1
        exige "$SYSCTL" "net.ipv4.conf.$ambito.log_martians" 1
    done
    exige "$SYSCTL" fs.suid_dumpable 0
fi

tema '== sshd: endurecido, sin tocar la autenticación por contraseña =='

if [ ! -f "$SSHD" ]; then
    mal "falta $SSHD"
else
    exige "$SSHD" PermitRootLogin no
    exige "$SSHD" LoginGraceTime 30
    exige "$SSHD" ClientAliveInterval 300
    exige "$SSHD" ClientAliveCountMax 2

    if grep -qiE '^\s*PasswordAuthentication\b' "$SSHD"; then
        mal "fija PasswordAuthentication: es decisión de quien usa el equipo, no de la distribución"
    else
        ok "no fija PasswordAuthentication"
    fi

    # Sintaxis: `sshd -T` exige una clave de host, así que se genera una
    # descartable y se mide la config efectiva, no sólo que el archivo parsee.
    if command -v sshd >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; then
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        ssh-keygen -q -t ed25519 -N '' -f "$tmp/clave" >/dev/null 2>&1
        printf 'HostKey %s\nInclude %s\n' "$tmp/clave" "$PWD/$SSHD" >"$tmp/sshd_config"
        if efectiva=$(sshd -T -f "$tmp/sshd_config" 2>&1); then
            ok "sshd acepta el drop-in (sshd -T)"
            grep -qix 'permitrootlogin no' <<<"$efectiva" \
                && ok "y sshd lo toma: permitrootlogin no" \
                || mal "sshd parsea el drop-in pero no toma permitrootlogin no"
        else
            mal "sshd rechaza el drop-in: $efectiva"
        fi
    else
        aviso "SIN COMPROBAR: sintaxis con sshd; no hay sshd o ssh-keygen"
    fi
fi

tema '== /tmp: nodev y nosuid, sin noexec =='

if [ ! -f "$TMPMOUNT" ]; then
    mal "falta $TMPMOUNT"
else
    opciones=$(sed -E 's/#.*//' "$TMPMOUNT" | sed -nE 's/^[[:space:]]*Options=(.*)/\1/p' | tail -1)
    if [ -z "$opciones" ]; then
        mal "no fija Options= en [Mount]"
    else
        for o in nodev nosuid; do
            if tr ',' '\n' <<<"$opciones" | grep -qx "$o"; then
                ok "Options incluye $o"
            else
                mal "Options no incluye $o: /tmp quedaría sin esa protección"
            fi
        done
        if tr ',' '\n' <<<"$opciones" | grep -qx noexec; then
            mal "Options incluye noexec: rompe los AppImages y los instaladores que corren desde /tmp"
        else
            ok "y sin noexec"
        fi
    fi
fi

tema '== y el paquete los instala =='

if [ ! -f "$RECETA" ]; then
    aviso "SIN COMPROBAR: la receta vive en PKGBUILDS y no está al lado"
else
    # Dentro de package(): una mención en un comentario no instala nada.
    cuerpo=$(sed -n '/^package()/,/^}/p' "$RECETA" | grep -v '^\s*#')
    for f in etc/sysctl.d/50-vasakos-ptrace.conf \
             "$SYSCTL" "$SSHD" "$TMPMOUNT"; do
        if grep -q "install .*\$srcdir/\$pkgname/$f" <<<"$cuerpo" \
            && grep -q "\$pkgdir/$f" <<<"$cuerpo"; then
            ok "la receta instala $f"
        else
            mal "la receta no instala $f: quedaría escrito y sin empaquetar"
        fi
    done
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mSin fallos.\033[0m\n'
else
    printf '\033[31m%s fallo(s).\033[0m\n' "$fallos"
fi
exit $(( fallos > 0 ? 1 : 0 ))
