# FilzaSlop

FilzaSlop is a modified FilzaJailedDS build for testing iOS container access.
It combines the original FilzaJailedDS exploit with the MobileHouseArrest and
MobileContainerManager bugs.

FilzaSlop has two separate access paths:

1. The original FilzaJailedDS kernel path on one exact iOS 18 target.
2. MobileContainerManager requests for other targets.

The complete feature set does not work on every listed iOS version.

It adds tappable folders in Filza for app data, app groups, extensions, VPN
data, service and system containers, system groups, protected data,
MobileGestalt, and InstallCoordination. Filza can read and modify files where
the selected bug grants access.

## iOS 18 and iOS 26 checklist

`Confirmed` means a physical-device test proved the stated file access. A
returned path or sandbox token is not enough by itself.

| Feature | iOS 18 | iOS 26 |
| --- | --- | --- |
| FilzaJailedDS kernel sandbox removal | ✅ Confirmed only on iPhone 16 Pro Max with iOS 18.5. | ❌ Not supported. FilzaSlop skips this path, and the bundled offsets reject iOS 26.1 and later. |
| MobileHouseArrest class 2 app container | ❌ The current PoC returned a path but no usable sandbox extension. | ✅ Confirmed. The PoC wrote and restored a marker in one selected app container. |
| MobileHouseArrest class 7 app group, including Notes | ❌ Not confirmed through MobileContainerManager. The exact iOS 18.5 kernel path exposes these aliases separately. | ⚠️ Implemented in FilzaSlop, but the current iOS 26 run only confirmed class 2. |
| Class 13 MobileGestalt cache | ❌ The query returned the system-group root without a token. iOS 18 also lacks the newer `part` API. | ❌ The query returned the cache path, but no tested request granted directory access or `O_RDWR` access to the plist. |
| `geod` class 12 traversal to MobileGestalt | ❌ The current implementation requires the missing `part` and `partDomain` APIs. | ❌ The query returned the lexical target path without a token or `O_RDWR` access. |
| InstallCoordination state directories | ❌ Not confirmed. The current entry request requires the newer scoped-part APIs. | ⚠️ The standalone PoC activated extensions for the state directories. The daemon stopped because its state was not idle, so the final symlink write is not confirmed. |
| `cfprefsd` missing-file creation | ➖ Not included in FilzaSlop. | ➖ Not included in FilzaSlop. |

The matching PoCs are:

- [MobileHouseArrest-PoC](https://github.com/0xjohnnydev/MobileHouseArrest-PoC)
- [Geod-MCM-PoC](https://github.com/0xjohnnydev/Geod-MCM-PoC)
- [InstallCoordination-PoC](https://github.com/0xjohnnydev/InstallCoordination-PoC)
- [CFPrefsZeroFile-PoC](https://github.com/0xjohnnydev/CFPrefsZeroFile-PoC)

## Confirmed iOS 18 device

The original FilzaJailedDS exploit has an exact runtime gate for:

- iPhone 16 Pro Max (`iPhone17,2`)
- iOS 18.5
- build `22F76`

On this target, the app runs `kexploit_opa334`, removes Filza's sandbox
restrictions, and adds real filesystem aliases to the Filza interface. Testing
confirmed out-of-bounds physical read/write, `sandbox_escape()` returning zero,
and directory access through the aliases.

The exploit can panic the device. The exact target check prevents this
path from running on other devices or builds.

## Paths shown in Filza

On the tested device, FilzaSlop adds aliases for these container roots:

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

This includes third-party app containers and app groups. A notable sensitive
target is the Notes database in `group.com.apple.notes` when file permissions
and Data Protection permit access.

This process does not become root. Normal Unix permissions and Data Protection
still apply.

## MobileContainerManager path

FilzaSlop also includes the MobileHouseArrest and MobileContainerManager bugs.
It requests container classes 2, 4, 6, 7, 10, 12, 13, and 15.
Successful paths appear under `Documents/Device Storage`.

The final app identity must be:

```text
com.apple.mobile.MobileHouseArrest
```

The bundle identifier and signed CodeDirectory identifier must match.

## Release IPA

The release IPA is unsigned. It contains no provisioning profile, development
certificate signature, device identifier list, or generated device catalog.
Sign it with your normal sideloading tool before installation. No container
UUID or device-specific FilzaSlop build is required.

Keep the bundle identifier as `com.apple.mobile.MobileHouseArrest`. The
MobileHouseArrest path will not work if the signing tool changes that value.

Container UUIDs are assigned by iOS during installation and resolved at
runtime. The iOS 18.5 implementation does not need `MCMIdentifiers.plist`.

## Build the tweak

```sh
export THEOS="$HOME/theos"
make clean
make package FINALPACKAGE=1
```

The tweak output is `FilzaApplySandboxExt.dylib`. Inject it into Filza, set the
bundle identifier shown above, and apply the final signature.

## Optional identifier catalog

The MCM path can use a device-specific identifier catalog:

```sh
scripts/refresh_device_catalog.sh <device-udid> /tmp/MCMIdentifiers.plist
```

Place the result in the app bundle before the final signature. Do not publish
the generated file because it lists apps installed on the source device.

## Credits

- [34306/FilzaJailedDS](https://github.com/34306/FilzaJailedDS)
- CrazyMind90 for the sandbox patching reference
- XPF and ChOma contributors
- `SerStars/nugget-wallpapers` and mightycooldude12 for the bundled Cipher sample

Filza is developed by TIGI Software. This project is not affiliated with TIGI
Software or Apple.
