# Android signing key

Android only installs an update when it is signed with the **same key** as
the app already on the phone. Otherwise the update fails ("App not
installed") and the old version keeps running.

Release builds therefore use one fixed key, kept as GitHub repository
secrets. The release workflow refuses to publish without it.

## One-time setup

1. Create the key (needs Java's `keytool`, included with any JDK or Android
   Studio). Pick a strong password and keep it:

   ```sh
   keytool -genkeypair -v -keystore gundil-release.jks -alias gundil \
     -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=Gundil Intercom"
   ```

2. Turn it into text for GitHub:

   - Linux: `base64 -w0 gundil-release.jks > key.txt`
   - macOS: `base64 -i gundil-release.jks -o key.txt`
   - Windows (PowerShell):
     `[Convert]::ToBase64String([IO.File]::ReadAllBytes("gundil-release.jks")) | Set-Content key.txt`

3. In the repository on GitHub: **Settings → Secrets and variables →
   Actions → New repository secret**, add:

   | Name | Value |
   |---|---|
   | `ANDROID_KEYSTORE_BASE64` | the contents of `key.txt` |
   | `ANDROID_KEYSTORE_PASSWORD` | the password from step 1 |
   | `ANDROID_KEY_ALIAS` | `gundil` |

   Then delete `key.txt`.

4. **Back up `gundil-release.jks` and its password** somewhere safe and
   private. Never commit it. If it's lost, a new key means every phone has
   to uninstall the app once again.

## Phones that already have the app

Releases up to 1.5.2 were each signed with a different, throw-away key, so
the first release with the fixed key can't install over them. On each phone,
uninstall Gundil Intercom once, then install the new APK. Saved peers, the
device name and the password must be entered again. After that, every
update installs over the previous one.

## Local builds

Without the key, local `flutter build apk` uses the debug key (for testing
only). To sign locally with the release key, set `ANDROID_KEYSTORE_PATH`,
`ANDROID_KEYSTORE_PASSWORD` and `ANDROID_KEY_ALIAS` before building.
