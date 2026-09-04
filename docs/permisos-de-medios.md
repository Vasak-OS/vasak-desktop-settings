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

El hueco es el esquema de las reglas de adentro del gestor —las que deciden qué
permiso va sobre qué objeto—. `WpPermissionManager` es API nueva de WirePlumber
0.5.17; el `NEWS.rst` la anuncia pero no documenta la configuración, y no hay
ejemplos instalados. Hay que buscarlo upstream antes de escribir nada: adivinar
el esquema y probarlo contra la pila de audio del equipo es exactamente cómo se
llega a un sistema mudo.
