# FilzaSlop

FilzaSlop is a FilzaJailedDS fork with two access paths:

- A sandbox escape.
- MobileContainerManager access through the MobileHouseArrest identity bug.

Successful container paths appear under `Documents/Device Storage`. FilzaSlop
does not grant root access.

## Status

Some features may not work correctly yet on every supported iOS version. If
you find a problem, please [open an issue](https://github.com/0xjohnnydev/FilzaSlop/issues).

## Paths

The sandbox escape adds these aliases:

```text
/private/var/mobile/Containers/Data/Application
/private/var/mobile/Containers/Shared/AppGroup
/private/var/mobile/Containers/Data/PluginKitPlugin
/private/var/mobile/Containers/Data/VPNPlugin
/private/var/mobile/Containers/Data/InternalDaemon
/private/var/mobile/Containers/Data/System
/private/var/mobile/Containers/Shared/SystemGroup
/private/var/mobile/Containers/Data/Protected
```

The Notes database is inside the `group.com.apple.notes` app group. Unix file
permissions and Data Protection still apply.

## Requirements

- The sandbox escape can panic the device.
- The MobileContainerManager path requires this signed CodeDirectory identifier:

```text
com.apple.mobile.MobileHouseArrest
```

The MobileHouseArrest path fails if the signing tool changes that identifier.

## Build

```sh
export THEOS="$HOME/theos"
make clean
make package FINALPACKAGE=1
```

Inject `FilzaApplySandboxExt.dylib` into Filza. Keep the required bundle and
CodeDirectory identifier when you sign the app.

An optional device identifier catalog can be generated with:

```sh
scripts/refresh_device_catalog.sh <device-udid> /tmp/MCMIdentifiers.plist
```

## PoCs

- [MobileHouseArrest-PoC](https://github.com/0xjohnnydev/MobileHouseArrest-PoC)
- [Geod-MCM-PoC](https://github.com/0xjohnnydev/Geod-MCM-PoC)
- [InstallCoordination-PoC](https://github.com/0xjohnnydev/InstallCoordination-PoC)
- [CFPrefsZeroFile-PoC](https://github.com/0xjohnnydev/CFPrefsZeroFile-PoC)

## Credits

- [34306/FilzaJailedDS](https://github.com/34306/FilzaJailedDS)
- CrazyMind90
- XPF and ChOma contributors
- `SerStars/nugget-wallpapers`
- mightycooldude12

Filza is developed by TIGI Software. This project is not affiliated with TIGI
Software or Apple.
