# FilzaSlop

FilzaSlop is a FilzaJailedDS fork with two access paths:

- An exact-target iOS 18.5 kernel sandbox escape.
- MobileContainerManager access through the MobileHouseArrest identity bug.

Successful container paths appear under `Documents/Device Storage`. FilzaSlop
does not grant root access.

## iOS 18 and iOS 26 status

`Confirmed` means a physical-device test proved file access. A returned path or
sandbox token is not enough.

| Feature | iOS 18 | iOS 26 |
| --- | --- | --- |
| FilzaJailedDS kernel sandbox removal | ✅ Confirmed on iPhone 16 Pro Max with iOS 18.5. | ❌ The exact-target gate skips this path. The bundled offsets reject iOS 26.1 and later. |
| MobileHouseArrest class 2 app container | ❌ Path returned, but no usable sandbox extension. | ✅ Marker write, readback, restoration, and post-release denial confirmed. |
| MobileHouseArrest class 7 app group, including Notes | ❌ Not confirmed through MobileContainerManager. The kernel path exposes the alias on the confirmed iOS 18.5 target. | ⚠️ Implemented, but the current iOS 26 test only confirmed class 2. |
| Class 13 MobileGestalt cache | ❌ Group root only. No token, `part` API, or `O_RDWR` access. | ❌ Cache path returned, but no request granted directory or `O_RDWR` access. |
| `geod` class 12 traversal to MobileGestalt | ❌ The required `part` and `partDomain` APIs are unavailable. | ❌ Target path returned without a token or `O_RDWR` access. |
| InstallCoordination state directories | ❌ The current entry request needs the newer scoped-part APIs. | ⚠️ The standalone PoC activated the directory extensions. The final daemon write is not confirmed. |
| `cfprefsd` missing-file creation | ➖ Not included. | ➖ Not included. |

## Paths

The confirmed iOS 18.5 kernel path adds these aliases:

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

- The kernel path is gated to `iPhone17,2`, iOS 18.5, build `22F76`.
- The kernel path can panic the device.
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
