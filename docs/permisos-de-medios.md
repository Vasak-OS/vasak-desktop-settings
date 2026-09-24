# Cámara, micrófono y pantalla: por dónde va el control

Registro de diseño de cómo VasakOS hace cumplir las decisiones de permisos sobre
cámara, micrófono y captura de pantalla. Está escrito porque cada pieza costó
descubrirla y varias conclusiones intermedias fueron **equivocadas**; sin esto,
el próximo intento las repite.

Tres de esas equivocaciones estuvieron escritas acá como si fueran hechos, y
las tres decían que algo era imposible cuando no lo era. Quedan en el texto,
marcadas, en vez de borrarse: saber qué se creyó y por qué era falso vale más
que un documento que parezca que siempre tuvo razón.

La tercera es la más cara de las tres, porque sobre ella se decidió **esperar**:
este documento dijo durante un mes que el gestor de permisos de WirePlumber no
aplicaba nada. Sí aplicaba. Ver «Dónde se corta», más abajo.

## El problema

`vasak-permissions` modela cámara, micrófono y pantalla, y deja decidir sobre
ellos en Configuración, pero esas decisiones **no se hacían cumplir**: su propio
`is_enforceable()` sólo devuelve verdadero para las cuentas online. Quien reparte
esos recursos es PipeWire, y no consulta la política.

Desde entonces se cubrieron las dos: la del portal, y la de PipeWire con la
etapa 2. De lo que trata el resto de este documento es de cómo, de qué sigue
sin cubrir —el micrófono, y quien elija el socket privilegiado— y de las
conclusiones equivocadas que hubo en el medio.

## Lo que ya está hecho

### La vía directa, cerrada con AppArmor

`etc/apparmor.d/vasak-appimage` niega `/dev/video*` y los dispositivos ALSA de
captura a los AppImage. Cierra la vía de atrás —la aplicación que se saltea
PipeWire y abre el dispositivo— pero no la principal, porque en este sistema
**PipeWire es quien abre la cámara** y la expone como nodo suyo.

### La vía del portal, cerrada en el backend

Lo que una aplicación pide por `xdg-desktop-portal` —la cámara de las
videollamadas del navegador, compartir la pantalla— lo pregunta el backend de
VasakOS, que desde `vasak-permissions#56` **consulta lo guardado antes de abrir
el diálogo**: lo concedido no se vuelve a preguntar, lo rechazado se rechaza sin
diálogo, y las dos cosas aparecen en Privacidad y seguridad para retirarlas.

Esto era lo que la sección «Por qué el diálogo del portal no reemplaza a esto»
daba por imposible. Ver ahí por qué dejó de serlo, y qué de aquel razonamiento
sigue en pie.

Cubre **lo que pasa por el portal**, que no es todo. Ver abajo: la pantalla
tiene su propia puerta de atrás, y es más ancha de lo que parecía.

### El socket privilegiado (etapa 1)

Hacen falta dos piezas, y ninguna sola alcanza:

- `usr/lib/systemd/user/pipewire.socket.d/` — los sockets los crea **systemd**,
  no PipeWire, y se los pasa por activación por socket.
- `usr/lib/vasak/generar-pipewire-conf` — el daemon reconoce los sockets
  activados **por nombre** contra su lista, así que también tiene que estar en
  `pipewire.conf`.

El objetivo de todo eso es `pipewire.sec.socket`: lo fija el servidor desde las
credenciales de la conexión, así que **el cliente no puede mentir** sobre por
dónde entró. Es el único discriminador confiable que ofrece PipeWire.

## Lo que NO funciona, medido

- **Emparejar por el binario del cliente.** `application.process.binary` lo
  declara el propio cliente: es falsificable. No sirve como frontera.
- **Resolver el binario desde el pid en un script de WirePlumber.**
  `pipewire.sec.pid` sí es confiable, pero el Lua de WirePlumber **no tiene
  `io`**: no puede leer `/proc` en absoluto.
- **El nivel de acceso «restricted» a secas.** Probado sobre un cliente real:
  ve **exactamente los mismos nodos** que uno sin restricción, cámara incluida.
  `find-default-access.lua` le da `Perm.RX`, o sea que sólo pierde el permiso de
  escritura. No bloquea nada de lo que nos importa.
- **Un drop-in de PipeWire para cambiar los argumentos de un módulo.** Los
  drop-in sólo *añaden* a `context.modules`, y el módulo de protocolo no se
  puede cargar dos veces: el daemon aborta y el equipo se queda sin audio.

## La etapa 2, escrita

Está en el paquete, en dos archivos que **no sirven de a uno**:

- `usr/share/wireplumber/wireplumber.conf.d/50-vasak-camara.conf` — la cámara
  deja de ofrecerse a quien entra por `pipewire-0`.
- `usr/lib/systemd/user/xdg-desktop-portal.service.d/50-vasak-pipewire-priv.conf`
  — manda el portal por `pipewire-0-priv`, para que pueda conceder.

Sin el segundo, el primero deja la cámara cerrada **también para el portal** y
el permiso queda bloqueado sin forma de desbloquearlo. Medido quitando el
drop-in: el portal cae en `pipewire-0`, se restringe con todos los demás y
`IsCameraPresent` pasa a `false`. Lo comprueba
`pruebas/camara-solo-por-el-portal.sh`, que exige los dos y mira los dos lados.

Lo que hay debajo es un **gestor de permisos propio**:
`access.permission-managers` con reglas por objeto, más `access.rules` que se lo
asigne a los clientes según su `pipewire.sec.socket`. La forma se ve en
`find-config-access.lua`:

    access.permission-managers = [
      { name = "...", default_permissions = "...", rules = <reglas> }
    ]
    access.rules = [ ... ]   -- fija access, default_permissions o
                             -- permission_manager_name sobre el cliente

### El esquema, encontrado

No hizo falta buscar upstream: está en la biblioteca y en un encabezado
instalado.

- `libwireplumber-0.5.so` nombra la acción de las reglas: **`set-permissions`**,
  junto a `matches` y `actions`, y valida la cadena de permisos
  («Permissions '%s' are not valid»).
- `/usr/include/pipewire-0.3/pipewire/permission.h` da las banderas: **R** (ver
  el objeto), **W** (modificarlo), **X** (llamarle métodos), **M** (ponerle
  metadatos) y **L** (enlazar). Son cinco, que coincide con el `%c%c%c%c%c` del
  registro de WirePlumber.

Con eso la forma queda:

    access.permission-managers = [
      {
        name = "vasak-sin-video"
        default_permissions = "rwxml"
        rules = [
          { matches = [ { media.class = "~Video.*" } ]
            actions = { set-permissions = "-----" } }
        ]
      }
    ]

    access.rules = [
      { matches = [ { pipewire.sec.socket = "pipewire-0" } ]
        actions = { update-props = { permission_manager_name = "vasak-sin-video" } } }
    ]

### La sintaxis, confirmada contra el código

Leído `lib/wp/permission-manager.c` de WirePlumber (el del tag 0.5.17 es
**idéntico** a master, así que no hay diferencia de versión):

- La acción de las reglas es **`set-permissions`**; cualquier otro nombre da
  «Action name '%s' is not valid».
- La cadena de permisos acepta los caracteres `r w x m l`, el `-` se **ignora**,
  y existe la palabra especial `"all"`. O sea que `"-----"` es válida y equivale
  a permisos **cero**.
- `get_rules_matched_object_permissions` empareja las reglas contra las
  propiedades **globales** del objeto y, si es un objeto PipeWire, también
  contra las suyas.
- Si varias reglas emparejan, los permisos se acumulan con OR.

O sea que la configuración escrita más arriba es sintácticamente correcta.

### Dónde se corta

#### La conclusión vieja, que era falsa

Este documento decía que

> no se aplica igual, y el punto está identificado. `update_client_permissions`
> —la única función que empuja los permisos al cliente— **no se llega a
> ejecutar**: su mensaje de registro («Updating permissions on client %u: any=…
> len=…») no aparece nunca, ni con el registro de WirePlumber en nivel info.

Y de ahí salían dos hipótesis —que el gestor no se activaba de verdad, o que
`Json.Raw` no reconstruía las reglas—, el reporte a upstream, y la decisión de
esperar.

**Las tres cosas se apoyaban en una medición mal hecha.** El mecanismo funciona
desde 0.5.17, sin ningún parche.

#### Lo que pasaba de verdad

La sonda era `pw-dump`, y `pw-dump` **no entra por donde entra una aplicación**:
pone `remote.intention=manager`, así que el servidor le fija
`pipewire.sec.socket = pipewire-0-manager`. Una regla escrita contra
`pipewire-0` no lo toca nunca. El registro lo dice, pero bajito —«Found default
PM» donde tendría que decir «Found config '…' PM»—, y es fácil leerlo como que
el gestor se asignó y no se aplicó.

Con una sonda que sí entre por `pipewire-0` —`pw-cli`, o `gst-launch-1.0` con
`pipewiresrc`— la cadena entera se cumple y `Updating permissions on client …`
aparece en cada conexión.

⚠ Y **nunca** escribir una regla restrictiva contra `pipewire-0-manager`: por ahí
entra WirePlumber. Se restringe a sí mismo, pierde los dispositivos y se lleva
puesta la pila. Probado sin querer; el equipo se queda sin audio hasta reiniciar
`pipewire pipewire-pulse wireplumber`.

#### Lo medido

El 21/09/2026, sobre wireplumber 0.5.17 y pipewire 1.6.8, con el socket
privilegiado de la etapa 1 ya instalado y la configuración de más arriba
emparejando por `pipewire.sec.socket = "pipewire-0"`:

| | resultado |
|---|---|
| video oculto a un cliente por `pipewire-0` | 92 de 100, y ver el aviso de abajo |
| ídem para el gestor, por `pipewire-0-manager` | los ve todos, como corresponde |
| **capturar de verdad, restringido** | **0 de 100 intentos** |
| capturar sin la regla | 5 de 5 |

Queda una carrera: el cliente alcanza a ver los objetos en el registro antes de
que le lleguen los permisos. **Se los retiran enseguida** —medido con
`pw-dump -m`: de 25 corridas, 9 los vieron y las 9 los perdieron después— y la
ventana nunca alcanzó para negociar un flujo.

⚠ **Cuánto pasa depende de la carga del equipo, y mucho.** La primera medición
dio 8 de cada 100 y quedó escrita acá como si fuera una constante; medida otra
vez con el equipo más ocupado dio 45 de cada 100. No es una propiedad de la
regla —dos reglas distintas, la precisa y la amplia, miden igual alternadas—:
es la carrera, que se ensancha cuando el equipo tiene que hacer otras cosas.
Cualquier cifra sola de acá es del momento en que se tomó.

Capturar, en cambio, no funcionó **ni una vez en 100 intentos**, repartidos
entre las tres configuraciones probadas y con el equipo cargado a propósito en
40 de ellos. Que no haya alcanzado en 100 no prueba que no pueda alcanzar
nunca: es un fallo de upstream que conviene que se arregle, no un agujero por el
que hoy se pase.

### Reportado upstream, y cómo terminó

https://gitlab.freedesktop.org/pipewire/wireplumber/-/work_items/1006

El reporte llevaba el caso mínimo, la evidencia del registro y la lista de lo
descartado. La respuesta de Julian Bouzas fue que él reproducía el problema
**sólo en el primer `pw-dump`** y que a partir del segundo los objetos ya no
aparecían, con un arreglo en
[!900](https://gitlab.freedesktop.org/pipewire/wireplumber/-/merge_requests/900)
que preactiva los gestores al cargar los scripts de acceso.

Ese «sólo la primera vez» es lo que destapó todo: si a la segunda funcionaba,
entonces el mecanismo aplicaba y lo que estaba mal era la medición.

**El parche no hace falta para esto**, porque el mecanismo ya aplica sin él.
Son seis scripts Lua y las APIs que usa (`Script.async_activation`,
`finish_activation`) ya existen en 0.5.17, así que se prueba copiándolos a
`~/.local/share/wireplumber/scripts/client/` sin recompilar nada.

#### Y la medición de que además empeoraba, que era del banco de pruebas

Acá decía que el parche **empeoraba** la carrera —8 fugas por 100 sin él contra
25 con él, en un experimento alternado por bloques— y se le reportó a upstream.
Es falso, y el error vale más que el número.

El banco sondeaba **apenas los dispositivos terminaban de enumerarse**, y esa
espera se medía por el socket del gestor, que no está restringido y no sabe
nada del subsistema de acceso. Con !900 los scripts `find-*-access` registran
su hook **recién cuando terminan de activar los gestores de permisos**, o sea
que hay una ventana después de cada reinicio de WirePlumber que **existe sólo
con el parche** — y la sonda caía justo ahí.

Remedido en el mismo equipo, alternando por bloques, separando las dos
ventanas:

| cuándo se sondea | 0.5.17 de fábrica | con !900 |
|---|---|---|
| apenas enumerados los dispositivos | 10 / 50 | **27 / 50** |
| 30 s después del reinicio | 22 / 50 | **20 / 50** |

En estado estable **no hay diferencia**. Lo único real que muestra el número
viejo es esa ventana de arranque, y la carrera que importa es por conexión de
cliente, no por arranque del daemon.

Se retiró ante upstream. La lección de método está abajo, en «Cómo medir esto
sin engañarse», y es la misma de siempre: la sonda no vio nada no es lo mismo
que no hay nada.

#### Cuánto dura la ventana

Medida con `pw-dump -m` en estado estable, cronometrando el `added` y el
`removed` del mismo objeto: **2 y 4 ms** en las dos corridas de diez que
fugaron. Eso explica que capturar no funcionara nunca: negociar un flujo pide
más vueltas de las que dura la ventana.

Y cuánto se nota depende del cliente: `pw-cli ls Node` fuga en torno al 40% de
las corridas en este equipo, `pw-dump -m` en 2 de 10.

### El techo de este diseño, que conviene saber antes de confiar en él

Tres cosas que la etapa 2 **no** cierra. Ninguna es un descuido; las tres son el
límite de lo que se puede hacer con configuración.

**1. No impide elegir la otra puerta.** Los sockets de PipeWire son
`srw-rw-rw-`, los tres. Un proceso del usuario que ponga
`PIPEWIRE_REMOTE=pipewire-0-priv` entra por el privilegiado y ve la cámara.
`pipewire.sec.socket` dice de forma confiable **por dónde entró** un cliente —lo
fija el servidor desde las credenciales de la conexión— pero no le impide
**elegir por dónde entrar**, y eso es lo que haría falta.

Para los AppImage esa puerta la cierra `etc/apparmor.d/vasak-appimage`, que
niega `pipewire-0-priv` y `pipewire-0-manager` y deja el normal, por donde va
también el sonido. Para lo que no tiene perfil, no hay con qué cerrarla.

Cerrarla de verdad pide el único discriminador que el cliente no puede ni
falsear ni elegir: `pipewire.sec.pid`, resuelto contra `/proc/<pid>/exe` y
consultado contra `vasak-permissions`. El Lua de WirePlumber no tiene `io`, así
que eso es un módulo en C. Es la misma forma que terminó tomando el control de
la pantalla —`permisos-globales` saca el pid del `wl_client` por esta misma
razón—, y es la etapa 3.

**2. No cubre el micrófono**, y no por falta de ganas. No existe portal de
micrófono: ocultar `Audio/Source` dejaría sin micrófono a todo el escritorio sin
ningún camino para concederlo, que es exactamente lo que la regla del escritorio
—todo lo que se bloquea se tiene que poder desbloquear— prohíbe. Va con el
módulo del punto 1, que sí puede conceder por aplicación.

**3. No cierra `/dev/video0`.** Quien abra el dispositivo a mano no pasa por
PipeWire. Sigue siendo cosa de AppArmor, y sigue alcanzando sólo a los AppImage
de la carpeta del usuario.

Lo que sí cierra: que la cámara **no esté disponible por omisión** para ninguna
aplicación, y que el camino que queda —el portal— pregunte, anote y se pueda
revocar después sin relanzar nada. Hasta ayer cualquier programa la tomaba sin
pedir nada.

## La decisión de esperar, y por qué ya no corre

El issue [vasak-desktop-settings#3][3] planteaba dos caminos y una condición
para elegir: **medir cuántos programas de los que la gente usa abren el
dispositivo directo**. Si eran pocos, sacar el acceso directo era un permiso
real hoy; si eran muchos, convenía esperar.

Lo que sigue es ese razonamiento como se escribió. Se sostiene entero salvo en
su conclusión, porque la espera que elegía **ya terminó**: ver «Entonces», al
final.

[3]: https://github.com/Vasak-OS/vasak-desktop-settings/issues/3

### La medición

Sobre un escritorio con 1271 paquetes instalados, buscando qué binarios y
bibliotecas nombran `/dev/video`:

| paquete | qué es |
|---|---|
| `google-chrome` | el navegador |
| `electron40`, `electron42` | **toda** aplicación de Electron |
| `qt6-webengine` | toda aplicación Qt que muestre web |
| `webkit2gtk-4.1`, `webkitgtk-6.0` | ídem con GTK, y nuestros propios diálogos |
| `telegram-desktop` | mensajería con videollamada |
| `obs-studio` | transmisión y grabación |
| `vlc-plugin-*`, `ffmpeg`, `sdl3` | reproducción y captura |
| `gst-plugins-good` | `v4l2src`, que usan muchas aplicaciones GTK |
| `zbar` | lector de códigos desde la cámara |

Más las herramientas de diagnóstico de `v4l-utils`, que no cuentan: nadie
videollama con `v4l2-ctl`.

**Son muchos, y son los que importan.** Es la superficie entera de navegadores
y videollamadas.

### El matiz que no cambia la decisión

Los binarios basados en Chromium traen `WebRtcPipeWireCamera`, o sea que
**saben** pedir la cámara por PipeWire. Está detrás de una bandera, apagada de
fábrica, y no hay forma de encenderla en todo el sistema: Chrome lee
`/etc/chromium-flags.conf`, pero una aplicación de Electron no lee nada
parecido. Encenderla aplicación por aplicación no es una política, es una lista
que se desactualiza.

### Por qué el diálogo del portal no reemplaza a esto

Las mismas aplicaciones nombran también `org.freedesktop.portal.Camera`, y ese
camino **sí** muestra un diálogo: el portal se lo pide a nuestro backend de
`org.freedesktop.impl.portal.Access`, que es el mismo que atiende la captura de
pantalla.

#### La razón vieja, que era falsa

Este documento decía que ese diálogo no podía gobernar nada porque

> lo único que le pasa al backend es un `app_id` que **está vacío fuera de un
> sandbox**. Sin sandbox no hay a quién atribuirle la decisión, así que no puede
> ser por aplicación ni aparecer en Privacidad y seguridad para revocarla.
>
> VasakOS no distribuye Flatpak, así que fuera de un sandbox son todas.

Era cierto cuando se escribió y dejó de serlo. `xdg-desktop-portal` 1.22 expone
`org.freedesktop.host.portal.Registry`, donde una aplicación **sin sandbox**
declara su identificador, y las basadas en Chromium la usan. Medido el
2026-09-15, en el diario del agente, con Chrome pidiendo compartir la pantalla y
ningún sandbox de por medio:

```
16:26:34  el portal pide '¿Le permitís compartir tu pantalla?' (app_id 'com.google.Chrome')
```

Lo que llega vacío es sólo lo que no se registra, y eso se sigue preguntando
cada vez.

Sobre esa premisa se guarda ahora la decisión, contra `portal:<app_id>` y
marcada como no verificada — el `app_id` lo declara la propia aplicación y no lo
comprueba nadie. El porqué de aceptar esa identidad imperfecta está en
`portal_key`, en el crate del protocolo de `vasak-permissions`; el resumen es
que la alternativa medida era un diálogo idéntico cuatro veces en veinte
segundos, que enseña a conceder sin leer.

#### La razón que sigue en pie

Para **la cámara**, el camino del portal no cubre a todas las aplicaciones, y por
eso no reemplaza al de PipeWire. Pedirla por ahí es lo que hace
`WebRtcPipeWireCamera` en los binarios basados en Chromium, y esa bandera está
apagada de fábrica —el matiz de más arriba—: lo normal sigue siendo que abran
`/dev/video0`. Y nada obliga a una aplicación a usar el portal; la que no
quiera, no lo usa.

O sea que el portal cierra la puerta de las aplicaciones que se comportan, y la
que no se comporta la tiene abierta igual. Eso es exactamente lo que un control
por debajo —PipeWire, o AppArmor— sí puede impedir.

#### La pantalla tenía la misma puerta de atrás, y está cerrada

El razonamiento que parecía cerrarla desde el principio era que en Wayland un
cliente no puede leer la pantalla por su cuenta, así que todo lo que capture
tiene que pasar por el portal. Es falso en un compositor wlroots, y se midió el
2026-09-15 en una sesión de VasakOS con el escritorio andando:

```
$ grim prueba.png
$ ls -la prueba.png
-rw-r--r-- 1 pato pato 337496 sep 15 22:17 prueba.png
```

La pantalla entera, sin portal, sin diálogo y sin que nada quedara anotado.
`zwlr_screencopy_manager_v1` le alcanza a cualquier cliente que sepa pedirlo, y
es el mismo protocolo del que depende `xdg-desktop-portal-wlr` para capturar.

**Lo que la cerró no fue `security-context-v1`.** Ese protocolo está expuesto
—es el pensado para esto— pero sólo alcanza a los clientes que entran por un
socket «en caja», y hoy no entra nadie por ahí. Lo que la cerró es el filtro de
globals de Wayfire: `permisos-globales`, en `vasak-wayfire-plugins`, decide
**qué se le anuncia a cada cliente** según el ejecutable que hay del otro lado
del socket, y lo que no se anuncia no se puede pedir. Mismo comando, 2026-09-23:

```
$ grim prueba.png
compositor doesn't support the screen capture protocol
```

**Y hubo un segundo capítulo, que es el que enseña algo.** Con el filtro puesto,
esto todavía capturaba:

```
$ cat programa-cualquiera.sh
#!/usr/bin/env bash
grim "$1" 2>&1

$ ./programa-cualquiera.sh porlacara.png   # 290 950 bytes
```

Porque `grim` estaba en la lista de permitidos —`vasak-shot` no tomaba los
píxeles, lo llamaba a él— y `grim` lo puede ejecutar cualquiera. Una lista por
ejecutable no cierra nada si adentro hay una herramienta de uso general: no hace
falta hablar el protocolo, alcanza con pedírselo a quien sí puede. Desde
`vasak-shot` 0.7.0 la captura la hace él mismo y `grim` salió de la lista; el
mismo script hoy no consigue nada.

Queda dicho lo que esto **no** es: la lista mira el ejecutable, así que sigue
sin distinguir dos instancias del mismo programa, y no hay diálogo — es una
lista fija del escritorio, no un permiso por aplicación. Para una aplicación de
terceros el camino sigue siendo el portal, que pregunta.

La medición se rehace con `pruebas/captura-sin-permiso.sh`, que pide las dos
formas —directa y por intermediario— y comprueba además que la herramienta que
sí captura siga en la lista: con la lista vacía las dos negaciones pasan en
verde y el escritorio se queda sin capturas.

### Entonces

Se toma el **camino 1**: no sacar el acceso directo, porque rompería los
navegadores, las videollamadas y OBS, y cerrar la vía de PipeWire con el gestor
de permisos por cliente.

Eso era «esperar a que WirePlumber aplique los permisos». **Ya los aplica** —
nunca dejó de hacerlo—, así que del camino 1 no quedó espera ni queda trabajo:
la etapa 2 está escrita y en el paquete. Lo que queda es la etapa 3, el módulo
que resuelve `pipewire.sec.pid`, y está acotada en «El techo de este diseño».

La corrección del `app_id` **no cambia esta decisión**, y conviene decirlo
porque invita a pensar lo contrario: que el portal ahora recuerde y revoque no
alcanza a la aplicación que no lo usa, que es justo la que preocupa.

De la pantalla ya no queda espera: lo de arriba está hecho y empaquetado. Lo que
sostiene la de la cámara es que la pantalla de Privacidad no promete de más. El texto de
alcance de Privacidad y seguridad nombra que una aplicación que se los pida a
PipeWire todavía no se detiene, y desde `vasak-settings#83` nombra también hasta
dónde llega el perfil de AppArmor: **sólo a los AppImage de la carpeta del
usuario**. Decía «lo que no instaló el sistema», que es más ancho — un binario
suelto descargado ahí tampoco tiene perfil.

### Cómo rehacer la medición

```
grep -rlsa "/dev/video" /usr/bin /usr/lib /opt | while read -r f; do
    pacman -Qoq "$f" 2>/dev/null
done | sort -u
```

Y para ver si algo de eso además sabe el camino de PipeWire:

```
grep -lsa "PipeWireCamera" /opt/google/chrome/chrome /usr/lib/electron*/electron
```

La decisión se vuelve a mirar cuando cambie una de dos cosas: que WirePlumber
conteste, o que los navegadores enciendan `WebRtcPipeWireCamera` de fábrica. La
segunda haría al camino 2 mucho más barato.

## Cómo medir esto sin engañarse

WirePlumber tarda en volver a enumerar los dispositivos después de reiniciarse.
Si se mide enseguida, se ve un conjunto reducido de nodos **que no tiene nada
que ver con los permisos aplicados**.

Pasó: una prueba mostró que el cliente restringido pasaba de ver cinco clases de
objetos a una sola, y parecía un éxito rotundo. La línea base sin ninguna
configuración daba exactamente lo mismo.

Toda medición tiene que esperar a que el conjunto de dispositivos esté completo
—los de audio **y** los de video— antes de contar nada, y compararse contra una
línea base tomada con la misma espera.

Y hay una segunda trampa, que costó un mes: **la sonda tiene que entrar por el
socket que se está probando**. `pw-dump` y `wpctl` entran por
`pipewire-0-manager`, no por `pipewire-0`, así que una regla sobre el socket de
las aplicaciones no los alcanza y el resultado parece «no se aplica». Para
probar `pipewire-0` va `pw-cli ls Device`, y para probar el permiso de verdad
—que es otra cosa que la visibilidad— va un intento de capturar:

```
gst-launch-1.0 -q pipewiresrc target-object=<serial> num-buffers=1 \
    ! videoconvert ! fakesink
```

El `videoconvert` no es decorativo: sin él la tubería no negocia formato y falla
con «target not found» aunque el permiso esté concedido, que es un falso
positivo de bloqueo.

La tercera es la carrera: la fuga depende de la carga del equipo y va de 8 a 45
de cada 100. Una tanda de veinte no distingue nada. Para comparar dos
configuraciones hay que **alternarlas por bloques**, o la que se midió con el
equipo más ocupado sale peor por eso y no por lo que se está probando.

Y la cuarta, que se llevó puesto un reporte a upstream: **esperar a que los
dispositivos aparezcan no es esperar a que el subsistema de acceso esté listo**.
Se enumeran antes, y encima esa espera se suele mirar por el socket del gestor,
que no está restringido y no sabe nada de los permisos. Hay configuraciones
—!900 es una— que registran sus hooks recién al terminar de activarse, así que
sondear temprano les inventa una regresión que en estado estable no existe.
Reiniciar, esperar **30 s**, y recién entonces medir. Si se quiere medir la
ventana de arranque, que sea a propósito y dicho.
