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
Sign it with your own certificate before installation.

### What is user-specific

The app does not contain a hardcoded container UUID. iOS assigns container
UUIDs during installation, and FilzaSlop resolves them at runtime.

The user-specific value is the signing profile. An iOS development profile
contains the target iPhone's device UDID. The final signature also contains the
user's Apple Developer Team ID.

The signer must preserve these values:

```text
CFBundleIdentifier:       com.apple.mobile.MobileHouseArrest
CodeDirectory identifier: com.apple.mobile.MobileHouseArrest
application-identifier:   <YOUR_TEAM_ID>.com.apple.mobile.MobileHouseArrest
```

Do not let AltStore, Sideloadly, or another signer replace the bundle
identifier. A changed identifier prevents the MobileHouseArrest path from
using the required host identity.

The iOS 18.5 kernel path does not depend on a device catalog. The optional
`MCMIdentifiers.plist` contains installed bundle identifiers, not container
UUIDs. Generate that catalog separately for MCM testing on another device.

## Sign with GitHub Actions

Use the workflow only in your own fork. Do not send a certificate, private key,
profile, or password to this repository.

1. Fork this repository to your GitHub account.
2. Create a wildcard iOS development provisioning profile.
3. Include your target iPhone in that profile.
4. Export the matching certificate and private key as a `.p12` file.
5. Add the four secrets below to your fork under **Settings > Secrets and
   variables > Actions**.

| Secret | Value |
| --- | --- |
| `IOS_CERTIFICATE_BASE64` | Base64 form of the `.p12` file |
| `IOS_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` file |
| `IOS_PROVISIONING_PROFILE_BASE64` | Base64 form of the `.mobileprovision` file |
| `OUTPUT_PASSWORD` | A new password used to encrypt the signed IPA artifact |

Create the two Base64 values on macOS:

```sh
/usr/bin/base64 < certificate.p12 | pbcopy
/usr/bin/base64 < profile.mobileprovision | pbcopy
```

Open the **Actions** tab in your fork. Select **Sign IPA for your device** and
choose **Run workflow**.

The workflow checks the following items before signing:

- The profile is not expired.
- The profile permits `com.apple.mobile.MobileHouseArrest`.
- The P12 certificate belongs to the profile.
- The profile authorizes at least one device.
- The final bundle, CodeDirectory, and application identifiers are correct.

The workflow uploads only an encrypted `.ipa.enc` file. This prevents the
public workflow artifact from exposing the provisioning profile's device
UDIDs. The artifact expires after one day.

Decrypt the downloaded artifact on your Mac:

```sh
read -s OUTPUT_PASSWORD
export OUTPUT_PASSWORD
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in FilzaSlop-v1.0.0-signed.ipa.enc \
  -out FilzaSlop-v1.0.0-signed.ipa \
  -pass env:OUTPUT_PASSWORD
unset OUTPUT_PASSWORD
```

You can then install `FilzaSlop-v1.0.0-signed.ipa` on an iPhone listed in the
profile.

## Sign locally on macOS

Download the unsigned IPA from the release. Then run:

```sh
read -s P12_PASSWORD
export P12_PASSWORD
scripts/sign_ipa.sh \
  FilzaSlop-v1.0.0-unsigned.ipa \
  certificate.p12 \
  profile.mobileprovision \
  FilzaSlop-v1.0.0-signed.ipa
unset P12_PASSWORD
```

The script creates a temporary keychain. It signs nested code first and signs
the app last. It also verifies the final identifiers and complete code
signature before it writes the output IPA.

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
