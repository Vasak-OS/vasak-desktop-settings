# Perfiles de AppArmor — los que no se pudieron poner

Estos cuatro perfiles **no se instalan**. El quinto, el del llavero, sí: es el
único que no levanta una ventana WebKit y corrió confinado sin una sola caída,
así que volvió a `etc/apparmor.d/`. Están acá porque el trabajo sirve y
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

Eso llevó a sospechar de WebKit, que se aísla a sí mismo con bubblewrap y
espacios de nombres. **`diagnostico2.sh` descartó esa hipótesis**: con el perfil
mínimo puesto y el binario lanzado a mano desde una terminal, aguanta los 20
segundos sin caerse, con el sandbox de WebKit encendido *y* apagado.

## La causa real: los dos aislamientos juntos

Poniendo las tres mediciones una al lado de la otra:

| | ¿Se cae? |
|---|---|
| sin perfil de AppArmor, lanzado por systemd con su sandbox | no |
| con perfil de AppArmor, lanzado a mano sin sandbox | no |
| **con perfil de AppArmor, lanzado por systemd con su sandbox** | **sí, en bucle** |

Ninguno de los dos aislamientos rompe solo. Rompen **juntos**. Y eso explica por
qué el llavero se salvó: su unidad tiene sandbox de systemd, pero es el único
sin ventana… y también por qué el agente de permisos, que sí tiene ventana, no
se cayó — no abre ninguna hasta que le piden un permiso.

Y no es una directiva suelta. Bisecando el sandbox de systemd con el perfil
puesto:

| Sandbox de systemd | ¿Se cae? |
|---|---|
| ninguno | **no** |
| completo | sí |
| sin `SystemCall*` | sí |
| sin `PrivateDevices`/`BindPaths` | sí |
| sin `RestrictAddressFamilies` | sí |
| sin `NoNewPrivileges` | sí |

Sacar cualquier grupo por separado no alcanza. Sólo desaparecen las caídas
cuando no hay sandbox de systemd en absoluto.

## Conclusión

Para nuestros demonios con ventana, **AppArmor y el sandbox de systemd son
excluyentes**, y de los dos conviene quedarse con el de systemd: está probado,
es medible —`systemd-analyze security` bajó de 9.2 a 2.4 en cada uno— y no
depende de que AppArmor esté activo.

Eso **no** invalida AppArmor para lo que se lo quería. Las aplicaciones de
terceros no se lanzan desde unidades de systemd: las abre el dock, el menú, otra
aplicación o una terminal, sin ningún sandbox de systemd encima. Ahí AppArmor
actúa solo, que es el caso que sí funciona —se comprobó lanzando el binario a
mano con el perfil puesto: veinte segundos sin caerse—. Y era justamente el
motivo por el que se lo eligió: es lo único que confina sin importar quién lanzó
el programa.

Así queda el reparto, y tiene sentido:

| | Cómo se protege |
|---|---|
| Nuestros demonios con ventana | sandbox de systemd |
| Nuestros demonios sin ventana (el llavero) | sandbox de systemd **y** AppArmor |
| Aplicaciones de terceros | AppArmor |

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
