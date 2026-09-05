# Cámara y micrófono: por dónde va el control

Registro de diseño de cómo VasakOS hace cumplir las decisiones de permisos sobre
cámara y micrófono. Está escrito porque cada pieza costó descubrirla y varias
conclusiones intermedias fueron **equivocadas**; sin esto, el próximo intento
las repite.

## El problema

`vasak-permissions` modela cámara, micrófono y pantalla, y deja decidir sobre
ellos en Configuración, pero esas decisiones **no se hacían cumplir**: su propio
`is_enforceable()` sólo devuelve verdadero para las cuentas online. Quien reparte
esos recursos es PipeWire, y no consulta la política.

## Lo que ya está hecho

### La vía directa, cerrada con AppArmor

`etc/apparmor.d/vasak-appimage` niega `/dev/video*` y los dispositivos ALSA de
captura a los AppImage. Cierra la vía de atrás —la aplicación que se saltea
PipeWire y abre el dispositivo— pero no la principal, porque en este sistema
**PipeWire es quien abre la cámara** y la expone como nodo suyo.

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

## Lo que falta (etapa 2)

Un **gestor de permisos propio**: `access.permission-managers` con reglas por
objeto, más `access.rules` que se lo asigne a los clientes según su
`pipewire.sec.socket`. La forma se ve en `find-config-access.lua`:

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

No se aplica igual, y el punto está identificado. `update_client_permissions`
—la única función que empuja los permisos al cliente— **no se llega a ejecutar**:
su mensaje de registro («Updating permissions on client %u: any=… len=…») no
aparece nunca, ni con el registro de WirePlumber en nivel info.

Esa función tiene dos guardas al principio: que el gestor tenga activa la
característica `WP_PERMISSION_MANAGER_LOADED`, y que el proxy del cliente siga
siendo válido. Y sin embargo el registro del subsistema de acceso sí dice
«Attached newly activated permission manager to client», o sea que desde el otro
lado el gestor figura como activado.

Hipótesis pendientes, en orden de probabilidad:

1. El gestor creado desde configuración no llega a activarse de verdad, pese al
   mensaje. Sería un fallo de WirePlumber y correspondería reportarlo.
2. `config.permission_managers:parse(2)` de `find-config-access.lua` deja el
   campo `rules` en una forma que `Json.Raw` no reconstruye igual, y las reglas
   llegan vacías al gestor.

Lo que **no** es: ni la sintaxis de la acción, ni la cadena de permisos, ni el
nombre de las propiedades — todo eso está verificado contra el código.

### Reportado upstream

https://gitlab.freedesktop.org/pipewire/wireplumber/-/work_items/1006

Con el caso mínimo, la evidencia del registro y la lista de lo ya descartado,
que es la mitad del valor del reporte: le ahorra al mantenedor el camino que ya
recorrimos.

Mientras no haya respuesta, la vía de PipeWire sigue sin control, y la pantalla
de Privacidad y seguridad de la configuración lo dice explícitamente en vez de
callarlo.

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
