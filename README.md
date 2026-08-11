# FilzaSlop

FilzaJailedDS fork with a sandbox escape and MobileHouseArrest container access.

It adds tappable aliases for app data, app groups, extensions, VPN data,
service and system containers, system groups, protected data, MobileGestalt,
and InstallCoordination. This includes the Notes app group when access is
granted.

Some features may not work correctly yet. Please
[open an issue](https://github.com/0xjohnnydev/FilzaSlop/issues) if you find a
problem.

The sandbox escape can panic the device.

## Signing

Keep this bundle and CodeDirectory identifier when signing:

```text
com.apple.mobile.MobileHouseArrest
```

Changing it disables the MobileHouseArrest path.

## Build

```sh
export THEOS="$HOME/theos"
make clean
make package FINALPACKAGE=1
```

Inject `FilzaApplySandboxExt.dylib` into Filza and sign the app.

## PoCs

- [MobileHouseArrest](https://github.com/0xjohnnydev/MobileHouseArrest-PoC)
- [Geod MCM](https://github.com/0xjohnnydev/Geod-MCM-PoC)
- [InstallCoordination](https://github.com/0xjohnnydev/InstallCoordination-PoC)
- [CFPrefs zero-file](https://github.com/0xjohnnydev/CFPrefsZeroFile-PoC)

## Credits

- [34306/FilzaJailedDS](https://github.com/34306/FilzaJailedDS)
- CrazyMind90
- XPF and ChOma contributors
- `SerStars/nugget-wallpapers`
- mightycooldude12
