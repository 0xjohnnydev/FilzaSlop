# FilzaSlop

FilzaJailedDS fork with:

- A sandbox escape for iOS 18, iOS 26, and iOS 27 beta 1–4.
- App container access.
- A PosterBoard Wallpaper Lab.

> **Not every feature currently works on iOS 18 or iOS 26.**
> [Open an issue](https://github.com/0xjohnnydev/FilzaSlop/issues) if you find a problem.

## Paths

### Container roots

```text
/private/var/mobile/Containers/Data/Application/
/private/var/mobile/Containers/Shared/AppGroup/
/private/var/mobile/Containers/Data/PluginKitPlugin/
/private/var/mobile/Containers/Data/VPNPlugin/
/private/var/mobile/Containers/Data/InternalDaemon/
/private/var/mobile/Containers/Data/System/
/private/var/mobile/Containers/Shared/SystemGroup/
/private/var/mobile/Containers/Data/Protected/
```

### Additional paths

```text
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.installcoordinationd/Library/InstallCoordination/
```

### Notable app data

```text
# Notes
/private/var/mobile/Containers/Shared/AppGroup/<Notes-group-UUID>/NoteStore.sqlite

# Safari app data
/private/var/mobile/Containers/Data/Application/<Safari-app-UUID>/

# Safari shared data: group.com.apple.safari
/private/var/mobile/Containers/Shared/AppGroup/<Safari-group-UUID>/
```

## PosterBoard

Wallpaper Lab can:

- Inspect the PosterBoard descriptor store.
- Import the bundled Cipher wallpaper.
- Import extracted `.tendies` wallpaper packages.
- Apply the PosterBoard refresh preferences.
- Roll back the latest import.

Place additional packages in:

```text
Documents/Device Storage/[MHA-C2] Wallpaper Lab/Imports/
```

Use the **Wallpaper** button at the Wallpaper Lab root. Imports add new
descriptor directories and keep a rollback backup. They do not overwrite the
PosterBoard database or existing descriptors.

## Signing

Keep this bundle and CodeDirectory identifier:

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
