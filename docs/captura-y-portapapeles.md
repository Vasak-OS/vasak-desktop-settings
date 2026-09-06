# Captura de pantalla, portapapeles y lo demás que un cliente Wayland puede hacer

Registro de lo medido sobre qué puede hacer una aplicación cualquiera contra el
compositor, y de qué cierra el protocolo `security-context-v1`. Está escrito
porque la parte importante —que el ajuste por defecto **no alcanza**— sólo se
ve midiendo, y sin esto el próximo intento lo da por bueno.

## El punto de partida

Medido en una sesión de Wayfire de verdad. Cualquier cliente, sin permiso ni
foco, tiene disponibles:

| Protocolo | Qué permite |
|---|---|
| `zwlr_screencopy_manager_v1` | capturar la pantalla |
| `ext_image_copy_capture_manager_v1` | capturar la pantalla (el reemplazo estándar) |
| `zwlr_export_dmabuf_manager_v1` | exportar el framebuffer |
| `zwlr_data_control_manager_v1` | leer el portapapeles, en continuo y sin foco |
| `ext_data_control_manager_v1` | ídem (el reemplazo estándar) |
| `zwp_virtual_keyboard_manager_v1` | **escribir teclas en cualquier ventana** |
| `zwlr_virtual_pointer_manager_v1` | mover y hacer clic |
| `ext_session_lock_manager_v1` | **ser la pantalla de bloqueo** |
| `zwlr_layer_shell_v1` | dibujar por encima de todo |
| `zwlr_foreign_toplevel_manager_v1` | enumerar ventanas y sus títulos |

Comprobado, no deducido: un proceso lanzado sin ningún privilegio leyó 84 822
bytes del portapapeles de la sesión.

Los dos peores no son la captura. Con `zwp_virtual_keyboard_manager_v1` un
cliente escribe en la terminal de al lado; con `ext_session_lock_manager_v1` se
convierte en la pantalla de bloqueo y recibe la contraseña.

## Lo que cierra `security-context-v1`

El protocolo deja que un motor de sandbox pida un socket aparte. Los clientes
que entran por ahí quedan marcados y el compositor no les expone los protocolos
que estén en `privileged_protocols`.

Wayfire trae el plugin. **No estaba activado.**

## El default no alcanza, y eso es lo que hay que saber

El valor por omisión de `privileged_protocols` nombra cuatro protocolos:

    zwlr_foreign_toplevel_manager_v1, zwlr_screencopy_manager_v1,
    zwlr_data_control_manager_v1, zwp_keyboard_shortcuts_inhibit_manager_v1

Son los cuatro `zwlr_` originales. **No están sus reemplazos `ext_`**, que hacen
exactamente lo mismo y son los que usan las herramientas actuales.

Medido con un cliente entrando por un socket en caja y el default puesto:

- `grim` sacó una captura de **313 899 bytes**, usando `ext_image_copy_capture`.
- `wl-paste` leyó **84 822 bytes** del portapapeles, usando `ext_data_control`.

O sea que el default protege de lo viejo y deja pasar lo nuevo. Es peor que no
tener nada, porque parece que confina.

Tampoco cubre la inyección de entrada ni el bloqueo de pantalla, que están más
arriba en la lista de lo que hace daño.

## Con la lista completa

Los mismos comandos, con los 17 protocolos declarados en `wayfire.ini`:

    $ WAYLAND_DISPLAY=wayland-encajado grim x.png
    compositor doesn't support the screen capture protocol

    $ WAYLAND_DISPLAY=wayland-encajado wl-paste --watch cat
    Watch mode requires a compositor that supports the data-control protocol

De 50 objetos globales en la sesión normal a 33 en la caja.

### El portapapeles con foco sigue funcionando, y está bien

Sin `data_control`, `wl-paste` cae en `wl_data_device_manager`: crea una ventana
y espera que se la active. Sigue leyendo el portapapeles, pero **sólo con foco**,
que es el modelo normal de Wayland y es visible para quien está mirando.

Lo que se cierra es la lectura continua en segundo plano. La distinción importa
y no hay que confundirla con una falla.

## Lo que falta, y es la mitad del trabajo

⚠ **Nada de esto confina a nadie todavía.** La lista se aplica a los clientes que
entran por un socket en caja, y hoy no hay ninguno: todo entra por el socket
normal de la sesión.

Hace falta que algo cree ese socket. Dos caminos:

1. **Un socket restringido por defecto para toda la sesión**, con las piezas
   propias —el panel, `vasak-shot`, `vasak-monitor`— usando el normal por
   `WAYLAND_DISPLAY` explícito en sus unidades de systemd. No necesita envolver
   cada aplicación, que es lo que se quería evitar.

   El costo: toda aplicación de terceros pierde la captura directa y la
   enumeración de ventanas. La captura legítima tiene que pasar por el portal,
   que es como la piden Firefox, Chromium y OBS.

2. **Un lanzador por aplicación**, que da control fino a cambio de que sólo
   valga para lo que se lance con él. Un dock distinto o una terminal lo
   saltean, que es exactamente el problema que llevó a elegir AppArmor.

El (1) es el que sigue la misma lógica que el resto: lo aplica el sistema y no
depende de quién abrió el programa.

## Lo que no cubre ninguno de los dos

El portal. Una aplicación que pida capturar por
`org.freedesktop.portal.ScreenCast` la recibe sin que se le pregunte a nadie:
`xdg-desktop-portal-wlr` no muestra un diálogo de permiso. Eso es un frente
aparte, y es el que usan las aplicaciones que uno **sí** quiere que puedan
compartir pantalla.

## Cómo medir esto sin engañarse

Mirar la lista de globales no alcanza: `grim` capturó igual estando
`zwlr_screencopy` ausente, porque usó otro protocolo. **Hay que correr la
herramienta**, no leer el anuncio.

Y hay que comparar contra la sesión normal en la misma máquina y el mismo
momento: la lista de globales depende del hardware y de qué plugins estén
cargados.
