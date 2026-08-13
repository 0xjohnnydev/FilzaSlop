# FilzaSlop

FilzaJailedDS fork with:

- A sandbox escape for iOS 18, iOS 26, and iOS 27 beta 1–4.
- App container access.
- Other less interesting directories listed below.
- A PosterBoard Wallpaper Lab.

> **Not every feature currently works on iOS 18 or iOS 26.**
> [Open an issue](https://github.com/0xjohnnydev/FilzaSlop/issues) if you find a problem.

**The unsigned IPA is available on the
[Releases page](https://github.com/0xjohnnydev/FilzaSlop/releases).**

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

### Archive

The **Archive** action moves selected items to the app's own archive folder:

```text
Documents/FilzaSlop Archive/
```

Open the **Archive** alias on the Device Storage landing page to restore or
delete archived items.

## Signing

Keep this bundle and CodeDirectory identifier:

```text
com.apple.mobile.MobileHouseArrest
```

Changing it disables the MobileHouseArrest path.

### Free Apple Accounts

A free Apple Account, also called a Personal Team, cannot currently sign the
standalone IPA while keeping the identity required by the MobileHouseArrest
path.

The app needs the same value for both identifiers:

```text
CFBundleIdentifier:       com.apple.mobile.MobileHouseArrest
CodeDirectory identifier: com.apple.mobile.MobileHouseArrest
```

Free-account sideloading tools normally register a new App ID. Apple rejects
the identifier above with error `9400` or `9401`. Allowing the signer to create
a unique bundle ID can make the app install, but it disables MobileHouseArrest
container access. Giving the app a normal bundle ID while keeping the
MobileHouseArrest CodeDirectory identifier also does not work. iOS rejects that
combination with `MismatchedBundleIDSigningIdentifier` before launch.

Do not use **automatic bundle ID** if you expect standalone MobileHouseArrest
access. A successful install with a changed identifier is not a working
sandbox escape.

#### Paid certificate providers

Some users buy device-bound certificate and provisioning files from providers
such as [ArcticSign](https://arcticsign.app/). These providers are independent
of this project, and Apple can revoke their certificates. For more reputable
and current sources, ask in the
[r/Jailbreak Discord](https://discord.com/invite/jb) or check
[r/sideloaded](https://www.reddit.com/r/sideloaded/) before paying.

#### LiveContainer fallback

Free-account users can run the unsigned IPA as a guest in
[LiveContainer](https://github.com/LiveContainer/LiveContainer):

> [!WARNING]
> LiveContainer mode does **not** provide MobileHouseArrest access. FilzaSlop
> cannot browse or edit containers for App Store apps or other apps installed
> by iOS. It can access only guest apps and data stored inside LiveContainer.
> Use this mode only to manage LiveContainer content.

1. Install LiveContainer with SideStore or AltStore using its normal automatic
   bundle ID.
2. Download the unsigned FilzaSlop IPA from the Releases page.
3. Open LiveContainer, tap the plus button, and select the IPA.
4. On iOS 26 or later, configure LiveContainer's JIT-less mode by importing the
   certificate from SideStore or AltStore.
5. Refresh LiveContainer before its seven-day Personal Team profile expires.

Apple limits a Personal Team to three installed apps per device, ten registered
App IDs, and seven-day provisioning profiles. LiveContainer uses one installed
app and one App ID for its guest apps. See Apple's
[developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account),
the [Sideloadly FAQ](https://sideloadly.io/faq.html), and the
[LiveContainer documentation](https://github.com/LiveContainer/LiveContainer)
for current setup and refresh details.

## iOS 26 app discovery

iOS 26 can hide third-party apps from the normal ContainerManager and
LaunchServices enumeration APIs. FilzaSlop now reads the device-local
LaunchServices store through the accessible `com.apple.lsd` service container.
It extracts bundle identifier candidates and confirms each candidate with a
direct class-2 ContainerManager lookup. The release IPA does not need a device
catalog.

`MCMIdentifiers.plist` remains an optional manual fallback. You can generate
one with `scripts/refresh_device_catalog.sh` and pass it as the third release
build argument.

## Build

```sh
export THEOS="$HOME/theos"
make clean
make package FINALPACKAGE=1
```

Inject `FilzaApplySandboxExt.dylib` into Filza and sign the app.

To build the unsigned release IPA:

```sh
./scripts/build_release_ipa.sh \
  FilzaSlop-v1.0.0-unsigned.ipa \
  FilzaSlop-v1.0.1-unsigned.ipa
```

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
