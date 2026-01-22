# Desktop Settings

Settings for the vasak desktop. These configurations and tools allow the correct functioning of the desktop

## Build

Generate packages for diferents *distros*

### Arch Based

For Arch based distros you can use oficial VasakOS repository or oficial [PKGBUILDS]()

### Debian Base

```bash
dpkg-deb --root-owner-group -b ./ vasak-desktop-settings.deb
```