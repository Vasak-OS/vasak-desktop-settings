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

## Lo que dijo la bisección (diagnostico.sh)

| Perfil sobre `vasak-polkit-agent` | Caídas en 25 s |
|---|---|
| sin perfil | 0 |
| `flags=(unconfined)` — etiqueta sin mediar | **0** |
| mínimo en complain (sólo `abstractions/base`) | **5** |
| perfil completo | 5 |

O sea: **no es ninguna regla nuestra**. Etiquetar el proceso no rompe nada;
rompe el momento en que AppArmor empieza a mediar, con el perfil más vacío
posible.

Y los volcados de ese arranque acotan más todavía:

| Proceso | Caídas | ¿Levanta el proceso web de WebKit? |
|---|---|---|
| `vasak-polkit-agent` | 500 | sí |
| `vasak-press-and-hold` | 262 | sí |
| `vasak-flare-daemon` | 250 | sí |
| `vasak-permissions-agent` | 0 | es WebKit, pero no abre ventana hasta que le piden un permiso |
| `vasak-keyring` | 0 | no tiene interfaz |

Los que se caen son exactamente los que arrancan el proceso web. WebKit se
aísla a sí mismo con bubblewrap y espacios de nombres, y la hipótesis es que ese
aislamiento no sobrevive a estar confinado por AppArmor. `diagnostico2.sh` la
pone a prueba.

Si se confirma, la conclusión de fondo es incómoda pero clara: para nuestras
ventanas Tauri, AppArmor **saca** un aislamiento (el de WebKit) para poner otro,
y no es un buen negocio. Tendría sentido reservarlo para los binarios sin
interfaz —`vasak-keyring` corrió confinado sin una sola caída— y para las
aplicaciones de terceros.

## Cómo retomarlo

Antes de recompilar nada con símbolos, conviene correr `diagnostico.sh`, que
sale más barato y puede ahorrar todo lo demás. Bisecta por contenido del perfil
—sin perfil, sólo etiqueta, mínimo en complain, y el completo— sobre el agente
de polkit, que es el más simple de los que se caían y el único que no toma el
teclado. Según dónde empiece a caerse:

| Falla desde | Entonces la causa es | Y el próximo paso |
|---|---|---|
| «sólo etiqueta» | estar confinado, no ninguna regla | mirar WebKit y sus procesos auxiliares; probar `flags=(unconfined)` como hacen los perfiles de Brave y Vivaldi que trae el paquete |
| «mínimo complain» | la mediación en complain | probar sin `include <abstractions/base>`, y con `abi <abi/3.0>` |
| «perfil completo» | alguna regla nuestra | seguir bisecando ese archivo, empezando por `userns,` y las reglas de `/usr/lib/webkit*` |

Recién si eso no alcanza, una build con símbolos del agente de polkit para poder
leer la traza. Y en una máquina donde se pueda dejar el bucle corriendo sin
quedarse sin teclado.

Lo que sí quedó puesto en el sistema es AppArmor activo por la línea de
arranque, con el paquete y sin ningún perfil nuestro: eso no confina nada, no
rompe nada, y es la base sobre la que se puede volver a intentar.
