# FilzaSlop

FilzaSlop is a modified FilzaJailedDS build for testing iOS container access.
It combines the original kernel sandbox path with the MobileHouseArrest and
MobileContainerManager path.

## Tested kernel path

The kernel path has an exact runtime gate for:

- iPhone 16 Pro Max (`iPhone17,2`)
- iOS 18.5
- build `22F76`

On this target, the app runs `kexploit_opa334`, patches its own sandbox, and
then adds real filesystem aliases to the Filza interface. Runtime testing
confirmed out-of-bounds physical read/write, `sandbox_escape()` returning zero,
and directory access through the aliases.

The kernel exploit can panic the device. The exact target check prevents this
path from running on other devices or builds.

## Paths shown in Filza

The iOS 18.5 kernel path adds aliases for these container roots:

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

Other targets use the retained MobileHouseArrest and MobileContainerManager
implementation. It requests container classes 2, 4, 6, 7, 10, 12, 13, and 15.
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
runtime. The iOS 18.5 kernel path does not need `MCMIdentifiers.plist`.

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
