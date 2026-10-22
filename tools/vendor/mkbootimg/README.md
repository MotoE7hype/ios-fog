Vendored AOSP `mkbootimg`, unmodified.

- Upstream: https://android.googlesource.com/platform/system/tools/mkbootimg
- Tag: `android-13.0.0_r1`
- License: Apache License 2.0 (headers retained in each file)

`mkbootimg.py --header_version 3` is what `shim/build.sh` uses. It is vendored
because the CI image job hit intermittent 503s on the googlesource archive
endpoint, and a boot image must be reproducible offline. `gki/` is only needed
for the import; GKI signing is not used.
