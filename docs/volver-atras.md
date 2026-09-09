# Volver a un estado anterior

VasakOS toma una instantánea del sistema **antes y después de cada transacción
de `pacman`**. Si una actualización deja el equipo peor de lo que estaba, se
vuelve al estado anterior sin reinstalar nada y sin medio de instalación.

Sólo funciona con btrfs, que es lo que el instalador elige por omisión. En ext4
o en xfs no hay instantáneas: nada de esto está activo y tampoco molesta.

## Ver qué hay

```
snapper -c root list
```

Cada transacción deja dos: una `pre` y una `post`, con el comando de `pacman`
que las causó en la descripción. Se conservan las diez últimas.

## Volver

### Desde el menú de arranque

En el menú de GRUB hay una entrada **VasakOS snapshots**. Adentro está cada
instantánea, con su fecha y lo que la causó. Elegir una arranca el sistema **tal
como estaba en ese momento**, en modo sólo lectura.

Eso alcanza para mirar, para copiar un archivo o para comprobar que el problema
efectivamente no estaba. No es todavía volver: al reiniciar, el sistema arranca
de nuevo el estado actual.

### Volver de verdad

Desde la instantánea arrancada, o desde el sistema normal si todavía arranca:

```
snapper -c root rollback <número>
```

y reiniciar.

## El paso que no hay que saltear

Después de reiniciar, si la instantánea es **anterior a una actualización de
kernel**:

```
sudo /usr/lib/vasak/restaurar-arranque
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

### Por qué hace falta

El kernel no vive en btrfs. La partición EFI se monta en `/boot` y es FAT, así
que una instantánea del sistema se lleva los **módulos** —están en
`/usr/lib/modules`— y no se lleva el **kernel** que los carga.

Volver atrás cruzando una actualización de kernel deja entonces el kernel nuevo
con los módulos viejos. Eso arranca. Arranca sin red y sin gráficos, que es la
peor forma de fallar: parece que funcionó.

Por eso VasakOS guarda además una copia del kernel y de sus dos initramfs en
`/var/lib/vasak/arranque`, que sí está adentro del subvolumen raíz y sí entra en
cada instantánea. `restaurar-arranque` es lo que la devuelve a `/boot`.

Esa misma copia es la que hace que las entradas del menú de arranque sean
correctas: cada instantánea arranca con **su** kernel y no con el de hoy.

## Cuánto ocupa

Un kernel y sus dos initramfs son unos 150 MiB. btrfs comparte las extensiones
entre instantáneas, así que no son 150 MiB por instantánea: son 150 MiB por
versión de kernel que siga viva en alguna de ellas.

Las instantáneas se limpian solas. Se conservan las diez últimas, no se toman
por hora —sólo por transacción de `pacman`, que es cuando el sistema cambia— y
`snapper` deja de acumular al llegar al 20% del disco.

## Si nada arranca

Con el medio de instalación de VasakOS:

1. Abrir la terminal.
2. Montar el disco y elegir la instantánea con `snapper --root /mnt`.
3. Restaurar el kernel a mano:
   `cp /mnt/var/lib/vasak/arranque/* /mnt/boot/`
