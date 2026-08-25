# USB HOP Linux Client product bundle

This is the role-restricted Linux Client package. It contains no Master
service, physical-device backend, hardware-free simulator, or prototype run
mode. The same sources produce separate x86-64 and ARM64 bundles; the installer
rejects a bundle whose recorded ELF architecture differs from the host.

The installed unprivileged entry point is `/usr/bin/usbip-client`. Its
production `--run` path requires all of these caller-supplied values:

- the paired Master's IP endpoint and canonical paired DNS identity;
- a protected per-installation Client identity bundle;
- a durably committed bilateral pairing directory; and
- a one-use protected Client-consent authority directory.

The Client receives the selected device descriptor offer over the authenticated
pre-USBC channel and checks it against the consumed consent authority before it
accepts setup or asks the root VHCI helper to attach. There is no fixed device,
session, grant, capability, endpoint, identity, or prototype fallback in this
build. The pairing and consent utilities persist already-confirmed facts; they
do not turn discovery or an unconfirmed short code into trust.

The installer provisions the root helpers, protected Client state directories,
and exact removal ownership. It requires preloaded USB/IP kernel modules, a
pre-existing `usbip` group and membership, and a root-owned `usbip` tool whose
origin is verified through either the dpkg or RPM database. It does not install
packages, mutate accounts or kernel state, generate identity material, pair
installations, start a Client network session, or attach a USB device.
`SO_PEERPIDFD` is a mandatory host capability and has no numeric-PID fallback.
Product admission is capability-based rather than a distro whitelist: systemd
on unified cgroup v2 with a readable process list,
the recorded x86-64 or ARM64 architecture, `usbip_core`, `vhci_hcd`, live
`SO_PEERPIDFD`, and package provenance must all pass.

Run `./install-usbip-linux-client.sh --check` without privilege to validate
the closed bundle. On the intended host, an administrator can separately run
`--host-check`. Installation, upgrade, recovery, and removal require the exact
acknowledgement printed by the command usage. Review the script before use.

The current product surface is a persistent CLI plus a privileged systemd
helper. A graphical Tauri Client remains a separate Phase-3 application task.
Compatibility is established only for dated device/distro/kernel evidence;
transport support does not supply a missing Client operating-system driver.

## Client-local USB source helper

Client-local devices now derive their route scope from a fresh local libusb
observation and can request a worker only through the fixed
`/run/usbip-source-helper/control.sock` root-helper boundary. The request is
the existing 188-byte authority-bound device-lease codec and the only success
response is one close-on-exec worker descriptor over `SCM_RIGHTS`; the Client
service never opens usbfs and cannot name a device path or execute a command.

The package installs the root-owned source-helper service, its pinned
executable and public-key material, and includes them in the closed manifest
and upgrade/recovery/remove transactions. Socket access is limited to the
dedicated Client service identity. The helper validates the exact
`DeviceLeaseIdentity`, pairing selector, consumed route authority, descriptor
commitments, and one-use nonce before opening usbfs. It returns a worker
endpoint rather than a raw usbfs descriptor and releases it on control loss.

The owning Master provides the authenticated Client-source destination data
session before this route direction can acknowledge commit. Missing or stale
authority, helper, device, or data-plane state fails closed rather than
reporting an active route.
