# Perfiles de AppArmor — intento fallido, guardado para el próximo

Estos cinco perfiles **no se instalan**. Están acá porque el trabajo sirve y
las conclusiones más todavía, pero puestos en `/etc/apparmor.d/` tumban el
escritorio.

## Qué pasó

Se cargaron los perfiles, todos en `flags=(complain)`, que en teoría registra
lo que bloquearía sin bloquear nada. El resultado, en un solo arranque:

| Proceso | Volcados con AppArmor | Volcados en los dos arranques previos |
|---|---|---|
| `vasak-polkit-agent` | 472 | 0 |
| `vasak-press-and-hold` | 262 | 0 |
| `vasak-flare-daemon` | 248 | 0 |

Casi mil volcados en una hora, 2,2 GB en `/var/lib/systemd/coredump`. Todos
`SIGSEGV`, a los pocos segundos de arrancar, en bucle de reinicio. El de teclado
toma el teclado en exclusiva, así que su bucle dejaba el equipo tecleando mal:
así fue como se descubrió.

El control es limpio: los dos arranques anteriores, con el mismo binario y sin
AppArmor activo, no tuvieron una sola caída.

## Lo que sí quedó aprendido

1. **Las reglas `deny` se aplican también en modo complain**, y son
   silenciosas: no se auditan salvo que se escriba `audit deny`. Un
   `deny network,` —que además alcanza a AF_UNIX— impedía el socketpair que
   tokio crea para las señales y el socket de Wayland, y los procesos morían
   con «failed to create UnixStream: Permission denied» sin una sola línea de
   AppArmor en el diario. Ese error ya está corregido en estos archivos: no
   queda ninguna regla `deny`.

2. **Y aun sin `deny`, siguen cayéndose.** Ésta es la parte sin resolver.
   Complain no debería bloquear nada, y el registro sólo muestra accesos
   permitidos y normales (xkeyboard-config, dconf, EGL). Los volcados salen sin
   símbolos, así que la traza no dice nada.

   La sospecha, sin confirmar, es la interacción con WebKit: todos los que se
   caen son ventanas Tauri, y WebKit levanta sus procesos auxiliares con
   espacios de nombres y su propio aislamiento. Los perfiles llevan `userns,` y
   `/usr/lib/webkit2gtk-4.1/** ix,`, que quizá no alcancen.

3. **Un `systemd-run` sin restricciones no sirve de control** cuando hay
   AppArmor: el perfil se pega por la ruta del binario, así que da igual quién
   lo lance. Los controles que sí funcionaron fueron copiar el binario a otra
   ruta y comparar contra un arranque anterior.

4. **Borrar el archivo del perfil no lo descarga del kernel.** Hay que
   `apparmor_parser -R` o reiniciar.

## Cómo retomarlo

Con una build con símbolos de uno de los que se caen —el de polkit es el más
simple— para poder leer la traza. Y en una máquina donde se pueda dejar el
bucle corriendo sin quedarse sin teclado.

Lo que sí quedó puesto en el sistema es AppArmor activo por la línea de
arranque, con el paquete y sin ningún perfil nuestro: eso no confina nada, no
rompe nada, y es la base sobre la que se puede volver a intentar.
