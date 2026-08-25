#!/bin/sh
set -eu

ack=USBIP_LINUX_CLIENT_PRODUCT_V1
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
manifest="$root/SHA256SUMS"
payload="$root/payload"
metadata="$root/BUILD-METADATA.v1"
package_root=/usr/libexec/usbip-client
client_path=$package_root/usbip-linux-client
helper_path=$package_root/usbip-linux-vhci-helper
source_helper_path=$package_root/usbip-linux-client-source-helper
source_provision_path=$package_root/usbip-linux-client-source-provision
source_worker_path=$package_root/usbip-linux-master-usb-worker
authority_tool_path=$package_root/usbip-linux-authority
pairing_tool_path=$package_root/usbip-linux-pairing
entry_path=/usr/bin/usbip-client
service_path=/etc/systemd/system/usbip-linux-client-vhci.service
agent_service_path=/etc/systemd/system/usbip-linux-client.service
source_service_path=/etc/systemd/system/usbip-linux-client-source-helper.service
source_peer_policy=/etc/usbip/client-source-helper-peer.v1
source_public_key=/etc/usbip/client-source-helper-public-key.ed25519
source_digest=/etc/usbip/client-source-helper-executable.sha256.bin
source_signing_key=/var/lib/usbip/client-source-helper/broker-signing-key.pk8
authority_path=/etc/usbip-vhci-helper/authority.v1
modules_path=/etc/modules-load.d/usbip-linux-client.conf
tmpfiles_path=/etc/tmpfiles.d/usbip-vhci.conf
tmpfiles_rule='d /run/vhci_hcd 0755 root root -'
state_root=/var/lib/usbip/client
legacy_state_root=/var/lib/usbip-client
package_state=/var/lib/usbip-client-package
install_record=$package_state/install.v1
upgrade_record=$package_state/upgrade.v1
upgrade_backup=$package_state/upgrade-backup
remove_record=$package_state/remove.v1
remove_backup=$package_state/remove-backup
install_transaction=/var/lib/usbip-client-install-transaction.v1
prepared_stage=$package_state/prepared-stage

usage() {
  echo "Usage: $0 --check | --host-check | --install $ack CLIENT_USER | --recover-install $ack | --upgrade $ack | --recover-upgrade $ack | --remove $ack | --recover-remove $ack" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is unavailable: $1" >&2
    exit 1
  }
}

metadata_value() {
  key=$1
  value=$(sed -n "s/^$key=//p" "$metadata")
  [ "$(grep -c "^$key=" "$metadata")" -eq 1 ] || return 1
  printf '%s\n' "$value"
}

valid_hash() {
  case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 64 ]
}

verify_elf() {
  binary=$1
  label=$2
  expected_machine=$3
  [ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] || {
    echo "$label is not a regular executable." >&2
    exit 1
  }
  header=$(readelf -hW -- "$binary")
  printf '%s\n' "$header" | grep -Eq 'Class:[[:space:]]+ELF64' || {
    echo "$label is not ELF64." >&2
    exit 1
  }
  case "$expected_machine" in
    x86_64) pattern='Advanced Micro Devices X86-64' ;;
    aarch64) pattern='AArch64' ;;
    *) echo "Invalid ELF machine metadata." >&2; exit 1 ;;
  esac
  printf '%s\n' "$header" | grep -Fq "Machine:                           $pattern" || {
    echo "$label has the wrong ELF machine." >&2
    exit 1
  }
  if readelf -lW -- "$binary" | grep -Fq 'Requesting program interpreter'; then
    echo "$label contains a dynamic program interpreter." >&2
    exit 1
  fi
  if readelf -dW -- "$binary" 2>/dev/null | grep -Fq '(NEEDED)'; then
    echo "$label contains a dynamic dependency." >&2
    exit 1
  fi
  file -b -- "$binary" | grep -Fq 'statically linked' || {
    echo "$label is not reported as statically linked." >&2
    exit 1
  }
}

verify_bundle() {
  [ "$(uname -s 2>/dev/null || true)" = Linux ] || {
    echo "Linux host required." >&2
    exit 1
  }
  for command in awk file grep readelf sed sha256sum stat; do require_command "$command"; done
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || { echo "Bundle manifest missing." >&2; exit 1; }
expected='BUILD-METADATA.v1
README.md
SOURCE-MANIFEST.v1
install-usbip-linux-client.sh
payload/usbip-linux-authority
payload/usbip-linux-client
payload/usbip-linux-client.service
payload/usbip-linux-client-source-helper
payload/usbip-linux-client-source-helper.service
payload/usbip-linux-client-source-provision
payload/usbip-linux-client-vhci.service
payload/usbip-linux-master-usb-worker
payload/usbip-linux-pairing
payload/usbip-linux-vhci-helper'
  actual=$(awk '{print $2}' "$manifest")
  [ "$actual" = "$expected" ] || { echo "Unexpected bundle manifest." >&2; exit 1; }
  actual_files=$(cd "$root" && find . -type f -printf '%P\n' | LC_ALL=C sort)
  expected_files=$(printf '%s\nSHA256SUMS\n' "$expected" | LC_ALL=C sort)
  [ "$actual_files" = "$expected_files" ] || { echo "Bundle contains an unexpected file." >&2; exit 1; }
  [ -z "$(find "$root" \( -type l -o \( -type f -links +1 \) \) -print -quit)" ] || {
    echo "Bundle contains an unsafe link." >&2
    exit 1
  }
  [ -z "$(find "$root" -type f \( -iname '*tailscale*' -o -iname '*cloudflared*' \) -print -quit)" ] || {
    echo "Overlay executables must not be bundled." >&2
    exit 1
  }
  (cd "$root" && sha256sum -c SHA256SUMS >/dev/null)
  [ "$(wc -l < "$metadata")" -eq 21 ] || { echo "Invalid build metadata." >&2; exit 1; }
  [ "$(sed -n '1p' "$metadata")" = USBIP_LINUX_CLIENT_PRODUCT_BUILD_V1 ] || {
    echo "Invalid product build metadata." >&2
    exit 1
  }
  target=$(metadata_value target) || exit 1
  machine=$(metadata_value elf_machine) || exit 1
  case "$target:$machine:$(uname -m)" in
    x86_64-unknown-linux-musl:x86_64:x86_64) ;;
    aarch64-unknown-linux-musl:aarch64:aarch64|aarch64-unknown-linux-musl:aarch64:arm64) ;;
    *) echo "Bundle target does not match this Linux host." >&2; exit 1 ;;
  esac
  for name in client helper authority pairing service agent_service source_helper source_provision source_worker source_service installer source_manifest cargo_lock; do
    value=$(metadata_value "${name}_sha256") || exit 1
    valid_hash "$value" || { echo "Invalid bundle hash metadata." >&2; exit 1; }
  done
  [ "$(sha256sum "$payload/usbip-linux-client" | awk '{print $1}')" = "$(metadata_value client_sha256)" ] || exit 1
  [ "$(sha256sum "$payload/usbip-linux-vhci-helper" | awk '{print $1}')" = "$(metadata_value helper_sha256)" ] || exit 1
  [ "$(sha256sum "$payload/usbip-linux-authority" | awk '{print $1}')" = "$(metadata_value authority_sha256)" ] || exit 1
  [ "$(sha256sum "$payload/usbip-linux-pairing" | awk '{print $1}')" = "$(metadata_value pairing_sha256)" ] || exit 1
  [ "$(sha256sum "$payload/usbip-linux-client-vhci.service" | awk '{print $1}')" = "$(metadata_value service_sha256)" ] || exit 1
  [ "$(sha256sum "$payload/usbip-linux-client.service" | awk '{print $1}')" = "$(metadata_value agent_service_sha256)" ] || exit 1
  [ "$(sha256sum "$payload/usbip-linux-client-source-helper" | awk '{print $1}')" = "$(metadata_value source_helper_sha256)" ] || exit 1
  [ "$(sha256sum "$payload/usbip-linux-client-source-provision" | awk '{print $1}')" = "$(metadata_value source_provision_sha256)" ] || exit 1
  [ "$(sha256sum "$payload/usbip-linux-master-usb-worker" | awk '{print $1}')" = "$(metadata_value source_worker_sha256)" ] || exit 1
  [ "$(sha256sum "$payload/usbip-linux-client-source-helper.service" | awk '{print $1}')" = "$(metadata_value source_service_sha256)" ] || exit 1
  [ "$(sha256sum "$root/install-usbip-linux-client.sh" | awk '{print $1}')" = "$(metadata_value installer_sha256)" ] || exit 1
  [ "$(sha256sum "$root/SOURCE-MANIFEST.v1" | awk '{print $1}')" = "$(metadata_value source_manifest_sha256)" ] || exit 1
  [ "$(metadata_value rustflags)" = '-C_relocation-model=static' ] || exit 1
  [ "$(metadata_value dependency_provenance)" = 'Cargo.lock--locked--offline' ] || exit 1
  for binary in usbip-linux-client usbip-linux-vhci-helper usbip-linux-authority usbip-linux-pairing usbip-linux-client-source-helper usbip-linux-client-source-provision usbip-linux-master-usb-worker; do
    verify_elf "$payload/$binary" "$binary" "$machine"
  done
  for binary in "$payload"/usbip-linux-client "$payload"/usbip-linux-vhci-helper "$payload"/usbip-linux-authority "$payload"/usbip-linux-pairing "$payload"/usbip-linux-client-source-helper "$payload"/usbip-linux-client-source-provision "$payload"/usbip-linux-master-usb-worker; do
    if grep -aEq -- '--run-(hardware-free|vhci|v2-vhci)-prototype|LINUX_(HARDWARE_FREE|VHCI|V2_VHCI)_PROTOTYPE|UVHCIIPC|usbip-rtl2838' "$binary"; then
      echo "Product payload contains a prototype or legacy fixed-fixture entry point." >&2
      exit 1
    fi
  done
}

peer_pidfd_gate() {
  "$payload/usbip-linux-vhci-helper" --check-peer-pidfd >/dev/null 2>&1 || {
    echo "Unsupported Linux Client kernel: SO_PEERPIDFD is required and there is no numeric-PID fallback." >&2
    exit 1
  }
}

package_manager_kind() {
  if command -v dpkg-query >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
    printf '%s\n' dpkg
  elif command -v rpm >/dev/null 2>&1; then
    printf '%s\n' rpm
  else
    return 1
  fi
}

package_file_is_owned() {
  package_path=$1
  if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -S "$package_path" >/dev/null 2>&1; then
    return 0
  fi
  if command -v rpm >/dev/null 2>&1 && rpm -qf -- "$package_path" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

package_version() {
  package_name=$1
  case "$(package_manager_kind 2>/dev/null || true)" in
    dpkg) dpkg-query -W -f='${Version}' "$package_name" 2>/dev/null ;;
    rpm) rpm -q --qf '%{EPOCHNUM}:%{VERSION}-%{RELEASE}' "$package_name" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

package_database_healthy() {
  case "$(package_manager_kind 2>/dev/null || true)" in
    dpkg)
      package_audit=$(dpkg --audit 2>&1) || return 1
      [ -z "$package_audit" ]
      ;;
    rpm) rpm -qa --qf '%{NAME}\n' >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

find_package_owned_usbip() {
  candidates="/usr/sbin/usbip /usr/lib/linux-tools/$(uname -r)/usbip"
  discovered=$(command -v usbip 2>/dev/null || true)
  case "$discovered" in /*) candidates="$candidates $discovered" ;; esac
  for candidate in $candidates; do
    resolved=$(readlink -f -- "$candidate" 2>/dev/null || true)
    [ -n "$resolved" ] && [ -f "$resolved" ] && [ ! -L "$resolved" ] && [ -x "$resolved" ] || continue
    [ "$(stat -c '%a:%u:%g' "$resolved" 2>/dev/null || true)" = 755:0:0 ] || continue
    package_file_is_owned "$resolved" || continue
    printf '%s\n' "$resolved"
    return 0
  done
  return 1
}

unified_cgroup_v2_gate() {
  [ -r /sys/fs/cgroup/cgroup.controllers ] || {
    echo "Unified cgroup v2 is required for safe USB worker restart recovery." >&2
    return 1
  }
  membership=$(sed -n 's/^0:://p' /proc/self/cgroup 2>/dev/null || true)
  [ "$(printf '%s\n' "$membership" | sed '/^$/d' | wc -l)" -eq 1 ] || {
    echo "A single unified cgroup v2 membership is required." >&2
    return 1
  }
  case "$membership" in /*) ;; *) return 1 ;; esac
  [ -r "/sys/fs/cgroup$membership/cgroup.procs" ] || {
    echo "The active cgroup v2 process list must be readable." >&2
    return 1
  }
}

host_gate() {
  [ "$(uname -s 2>/dev/null || true)" = Linux ] || { echo "Linux host required." >&2; exit 1; }
  [ -d /run/systemd/system ] || { echo "systemd must be enabled for the Linux Client helper." >&2; exit 1; }
  command -v systemctl >/dev/null 2>&1 || { echo "systemctl is required for the Linux Client helper." >&2; exit 1; }
  unified_cgroup_v2_gate || exit 1
  if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    grep -qi microsoft-standard-WSL2 /proc/sys/kernel/osrelease || {
      echo "WSL1 cannot present kernel USB devices." >&2
      exit 1
    }
  fi
  [ -d /sys/module/usbip_core ] && [ -d /sys/module/vhci_hcd ] || {
    echo "Preloaded USB/IP Client modules are required; installer will not mutate kernel state." >&2
    exit 1
  }
  package_manager_kind >/dev/null || {
    echo "A supported package database (dpkg or rpm) is required to verify dependency provenance." >&2
    exit 1
  }
  find_package_owned_usbip >/dev/null || {
    echo "A root-owned, package-owned usbip tool is required; installer will not mutate packages." >&2
    exit 1
  }
  peer_pidfd_gate
}

record_value() {
  key=$1
  value=$(sed -n "s/^$key=//p" "$install_record")
  [ "$(grep -c "^$key=" "$install_record")" -eq 1 ] || return 1
  printf '%s\n' "$value"
}

verify_regular() {
  path=$1 expected_hash=$2 expected_mode=$3 expected_uid=$4 expected_gid=$5
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(sha256sum "$path" | awk '{print $1}')" = "$expected_hash" ] || return 1
  [ "$(stat -c '%a:%u:%g' "$path")" = "$expected_mode:$expected_uid:$expected_gid" ]
}

client_group_name() {
  group_id=$1
  name=$(getent group "$group_id" | awk -F: '{print $1}')
  case "$name" in ''|-*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  printf '%s\n' "$name"
}

render_agent_service() {
  source_unit=$1
  destination_unit=$2
  service_user=$3
  service_gid=$4
  service_group=$(client_group_name "$service_gid") || return 1
  [ "$(grep -c '@USBIP_CLIENT_USER@' "$source_unit")" -eq 1 ] || return 1
  [ "$(grep -c '@USBIP_CLIENT_GROUP@' "$source_unit")" -eq 1 ] || return 1
  temporary=$destination_unit.new
  sed -e "s/@USBIP_CLIENT_USER@/$service_user/" \
    -e "s/@USBIP_CLIENT_GROUP@/$service_group/" "$source_unit" > "$temporary"
  chown root:root "$temporary"
  chmod 0644 "$temporary"
  mv -T -- "$temporary" "$destination_unit"
}

# The privileged VHCI helper unit pins ReadOnlyPaths=/run/vhci_hcd. When that
# directory is absent the unit fails with status=226/NAMESPACE, so the product
# owns a tmpfiles.d rule that recreates it at every boot, and materialises the
# directory immediately so the first start succeeds without a reboot.
install_vhci_tmpfiles() {
  tmpfiles_temp=$(mktemp /etc/tmpfiles.d/.usbip-vhci.XXXXXX) || return 1
  printf '%s\n' "$tmpfiles_rule" > "$tmpfiles_temp"
  chown root:root "$tmpfiles_temp"
  chmod 0644 "$tmpfiles_temp"
  mv -T -- "$tmpfiles_temp" "$tmpfiles_path"
  systemd-tmpfiles --create "$tmpfiles_path"
}

# Only the exact product-owned rule is ever deleted; a foreign file with the
# same name is left untouched.
remove_vhci_tmpfiles() {
  [ "$(cat "$tmpfiles_path" 2>/dev/null)" != "$tmpfiles_rule" ] || rm -f -- "$tmpfiles_path"
}

validate_state_tree() {
  candidate=$1
  expected_uid=$2
  expected_gid=$3
  [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
  [ "$(stat -c '%a:%u:%g' "$candidate")" = "700:$expected_uid:$expected_gid" ] || return 1
  [ -z "$(find "$candidate" -xdev -type l -print -quit)" ] || return 1
  [ -z "$(find "$candidate" -xdev ! -type d ! -type f -print -quit)" ] || return 1
  [ -z "$(find "$candidate" -xdev -type f -links +1 -print -quit)" ] || return 1
  [ -z "$(find "$candidate" -xdev -type d ! -perm 0700 -print -quit)" ] || return 1
  [ -z "$(find "$candidate" -xdev -type f ! -perm 0600 -print -quit)" ] || return 1
  [ -z "$(find "$candidate" -xdev \( ! -uid "$expected_uid" -o ! -gid "$expected_gid" \) -print -quit)" ]
}

migrate_legacy_state() {
  expected_uid=$1
  expected_gid=$2
  if [ -e "$legacy_state_root" ] || [ -L "$legacy_state_root" ]; then
    [ ! -e "$state_root" ] && [ ! -L "$state_root" ] || return 1
    validate_state_tree "$legacy_state_root" "$expected_uid" "$expected_gid" || return 1
    if [ ! -d /var/lib/usbip ]; then
      install -d -o root -g root -m 0711 /var/lib/usbip
      sync -f /var/lib
    else
      [ ! -L /var/lib/usbip ] && [ "$(stat -c '%a:%u:%g' /var/lib/usbip)" = 711:0:0 ] || return 1
    fi
    mv -T -- "$legacy_state_root" "$state_root"
    sync -f /var/lib/usbip
    sync -f /var/lib
  fi
  validate_state_tree "$state_root" "$expected_uid" "$expected_gid"
}

stage_upgrade_payload() {
  service_user=$1
  service_gid=$2
  [ ! -e "$prepared_stage" ] && [ ! -L "$prepared_stage" ] || return 1
  install -d -o root -g root -m 0700 "$prepared_stage"
  for name in usbip-linux-client usbip-linux-vhci-helper usbip-linux-authority usbip-linux-pairing \
    usbip-linux-client-source-helper usbip-linux-client-source-provision usbip-linux-master-usb-worker; do
    install -o root -g root -m 0755 "$payload/$name" "$prepared_stage/$name"
  done
  install -o root -g root -m 0644 "$payload/usbip-linux-client-vhci.service" \
    "$prepared_stage/usbip-linux-client-vhci.service"
  install -o root -g root -m 0644 "$payload/usbip-linux-client-source-helper.service" \
    "$prepared_stage/usbip-linux-client-source-helper.service"
  render_agent_service "$payload/usbip-linux-client.service" \
    "$prepared_stage/usbip-linux-client.service" "$service_user" "$service_gid"
  (cd "$prepared_stage" && sha256sum -- * > STAGED.sha256)
  chown root:root "$prepared_stage/STAGED.sha256"
  chmod 0600 "$prepared_stage/STAGED.sha256"
  for staged_file in "$prepared_stage"/*; do
    sync -f "$staged_file"
  done
  sync -f "$prepared_stage"
  (cd "$prepared_stage" && sha256sum -c STAGED.sha256 >/dev/null)
}

discard_prepared_stage() {
  [ ! -e "$prepared_stage" ] && return 0
  [ -d "$prepared_stage" ] && [ ! -L "$prepared_stage" ] || return 1
  for name in STAGED.sha256 usbip-linux-client usbip-linux-vhci-helper \
    usbip-linux-authority usbip-linux-pairing usbip-linux-client-source-helper \
    usbip-linux-client-source-provision usbip-linux-master-usb-worker \
    usbip-linux-client-source-helper.service usbip-linux-client-vhci.service \
    usbip-linux-client.service; do
    rm -f -- "$prepared_stage/$name"
  done
  [ -z "$(find "$prepared_stage" -mindepth 1 -maxdepth 1 -print -quit)" ] || return 1
  rmdir "$prepared_stage"
  sync -f "$package_state"
}

load_install_record() {
  [ -f "$install_record" ] && [ ! -L "$install_record" ] || { echo "Install ownership journal missing." >&2; exit 1; }
  [ "$(stat -c '%a:%u:%g' "$install_record")" = 600:0:0 ] || { echo "Install ownership journal mode or owner changed." >&2; exit 1; }
  install_schema=$(sed -n '1p' "$install_record")
  case "$install_schema:$(wc -l < "$install_record")" in
    USBIP_LINUX_CLIENT_INSTALL_V1:23)
      installed_state_root=$legacy_state_root
      agent_service_recorded=0
      source_helper_recorded=0
      ;;
    USBIP_LINUX_CLIENT_INSTALL_V2:25)
      installed_state_root=$(record_value state_root) || exit 1
      [ "$installed_state_root" = "$state_root" ] || exit 1
      agent_service_recorded=1
      source_helper_recorded=0
      ;;
    USBIP_LINUX_CLIENT_INSTALL_V3:33)
      installed_state_root=$(record_value state_root) || exit 1
      [ "$installed_state_root" = "$state_root" ] || exit 1
      agent_service_recorded=1
      source_helper_recorded=1
      ;;
    *) echo "Install ownership journal version or shape changed." >&2; exit 1 ;;
  esac
  installed_target=$(record_value target) || exit 1
  installed_user=$(record_value client_user) || exit 1
  installed_uid=$(record_value client_uid) || exit 1
  installed_gid=$(record_value client_gid) || exit 1
  helper_gid=$(record_value helper_gid) || exit 1
  group_created=$(record_value group_created) || exit 1
  membership_added=$(record_value membership_added) || exit 1
  usbip_core_was_loaded=$(record_value usbip_core_was_loaded) || exit 1
  vhci_hcd_was_loaded=$(record_value vhci_hcd_was_loaded) || exit 1
  usbip_copy_created=$(record_value usbip_copy_created) || exit 1
  owned_packages=$(record_value owned_packages | tr ',' ' ') || exit 1
  owned_package_versions=$(record_value owned_package_versions | tr ',' ' ') || exit 1
  case "$installed_target" in x86_64-unknown-linux-musl|aarch64-unknown-linux-musl) ;; *) exit 1 ;; esac
  case "$installed_user" in ''|root|-*|*[!A-Za-z0-9_.-]*) exit 1 ;; esac
  case "$installed_uid:$installed_gid:$helper_gid" in *[!0-9:]*) exit 1 ;; esac
  case "$group_created:$membership_added:$usbip_core_was_loaded:$vhci_hcd_was_loaded:$usbip_copy_created" in [01]:[01]:[01]:[01]:[01]) ;; *) exit 1 ;; esac
  case "$owned_packages" in *[!A-Za-z0-9.+_\ -]*) exit 1 ;; esac
  case "$owned_package_versions" in *[!A-Za-z0-9.+_:~=,\ -]*) exit 1 ;; esac
  version_package_names=
  for package_spec in $owned_package_versions; do
    package_name=${package_spec%%=*}
    recorded_package_version=${package_spec#*=}
    [ -n "$package_name" ] && [ -n "$recorded_package_version" ] && [ "$package_name" != "$recorded_package_version" ] || exit 1
    version_package_names="$version_package_names $package_name"
  done
  version_package_names=$(printf '%s\n' "$version_package_names" | awk '{$1=$1; print}')
  [ "$version_package_names" = "$owned_packages" ] || exit 1
  [ "$(record_value entry_target)" = "$client_path" ] || exit 1
  [ "$(record_value journal_schema)" = closed-fixed-paths ] || exit 1
}

verify_installed() {
  load_install_record
  verify_regular "$client_path" "$(record_value client_sha256)" 755 0 0 || exit 1
  verify_regular "$helper_path" "$(record_value helper_sha256)" 755 0 0 || exit 1
  verify_regular "$authority_tool_path" "$(record_value authority_sha256)" 755 0 0 || exit 1
  verify_regular "$pairing_tool_path" "$(record_value pairing_sha256)" 755 0 0 || exit 1
  verify_regular "$service_path" "$(record_value service_sha256)" 644 0 0 || exit 1
  if [ "$agent_service_recorded" -eq 1 ]; then
    verify_regular "$agent_service_path" "$(record_value agent_service_sha256)" 644 0 0 || exit 1
  else
    [ ! -e "$agent_service_path" ] && [ ! -L "$agent_service_path" ] || exit 1
  fi
  if [ "$source_helper_recorded" -eq 1 ]; then
    verify_regular "$source_helper_path" "$(record_value source_helper_sha256)" 755 0 0 || exit 1
    verify_regular "$source_provision_path" "$(record_value source_provision_sha256)" 755 0 0 || exit 1
    verify_regular "$source_worker_path" "$(record_value source_worker_sha256)" 755 0 0 || exit 1
    verify_regular "$source_service_path" "$(record_value source_service_sha256)" 644 0 0 || exit 1
    verify_regular "$source_peer_policy" "$(record_value source_peer_policy_sha256)" 600 0 0 || exit 1
    verify_regular "$source_public_key" "$(record_value source_public_key_sha256)" 644 0 0 || exit 1
    verify_regular "$source_digest" "$(record_value source_digest_sha256)" 644 0 0 || exit 1
    verify_regular "$source_signing_key" "$(record_value source_signing_key_sha256)" 600 0 0 || exit 1
  fi
  verify_regular "$authority_path" "$(record_value authority_record_sha256)" 640 0 0 || exit 1
  verify_regular "$modules_path" "$(record_value modules_sha256)" 644 0 0 || exit 1
  verify_regular /usr/sbin/usbip "$(record_value usbip_sha256)" 755 0 0 || exit 1
  [ -L "$entry_path" ] && [ "$(readlink "$entry_path")" = "$client_path" ] || exit 1
  [ "$(stat -c '%u:%g' "$entry_path")" = 0:0 ] || exit 1
  [ "$(stat -c '%a:%u:%g' "$package_root")" = 755:0:0 ] || exit 1
  [ "$(stat -c '%a:%u:%g' "$package_state")" = 700:0:0 ] || exit 1
  [ "$(getent passwd "$installed_user" | awk -F: '{print $3 ":" $4}')" = "$installed_uid:$installed_gid" ] || exit 1
  [ "$(getent group usbip | awk -F: '{print $3}')" = "$helper_gid" ] || exit 1
  [ "$(stat -c '%a:%u:%g' "$installed_state_root")" = "700:$installed_uid:$installed_gid" ] || exit 1
  for directory in identity pairing authority offers; do
    [ "$(stat -c '%a:%u:%g' "$installed_state_root/$directory")" = "700:$installed_uid:$installed_gid" ] || exit 1
  done
  case "$installed_target" in
    x86_64-unknown-linux-musl) installed_machine=x86_64 ;;
    aarch64-unknown-linux-musl) installed_machine=aarch64 ;;
    *) exit 1 ;;
  esac
  source_binaries=
  if [ "${source_helper_recorded:-0}" -eq 1 ]; then
    source_binaries="$source_helper_path $source_provision_path $source_worker_path"
  fi
  for binary in "$client_path" "$helper_path" "$authority_tool_path" "$pairing_tool_path" $source_binaries; do
    verify_elf "$binary" "installed $(basename -- "$binary")" "$installed_machine"
  done
  for package_spec in $owned_package_versions; do
    package_name=${package_spec%%=*}
    recorded_package_version=${package_spec#*=}
    [ "$(package_version "$package_name")" = "$recorded_package_version" ] || {
      echo "Owned dependency version changed: $package_name." >&2
      exit 1
    }
  done
  [ ! -e "$upgrade_record" ] && [ ! -e "$upgrade_backup" ] || {
    echo "An unfinished upgrade journal is present; use --recover-upgrade." >&2
    exit 1
  }
  [ ! -e "$remove_record" ] && [ ! -e "$remove_backup" ] || {
    echo "An unfinished removal journal is present; use --recover-remove." >&2
    exit 1
  }
}

write_install_record() {
  destination=$1 target_value=$2 user=$3 uid=$4 gid=$5 group_id=$6
  group_flag=$7 membership_flag=$8 core_flag=$9
  shift 9
  vhci_flag=$1 usbip_flag=$2 packages=$3 package_versions=$4
  temporary=$(mktemp "$package_state/.install.v1.XXXXXX")
  printf '%s\n' \
    USBIP_LINUX_CLIENT_INSTALL_V3 \
    "target=$target_value" \
    "client_user=$user" \
    "client_uid=$uid" \
    "client_gid=$gid" \
    "helper_gid=$group_id" \
    "group_created=$group_flag" \
    "membership_added=$membership_flag" \
    "usbip_core_was_loaded=$core_flag" \
    "vhci_hcd_was_loaded=$vhci_flag" \
    "usbip_copy_created=$usbip_flag" \
    "owned_packages=$packages" \
    "owned_package_versions=$package_versions" \
    "client_sha256=$(sha256sum "$client_path" | awk '{print $1}')" \
    "helper_sha256=$(sha256sum "$helper_path" | awk '{print $1}')" \
    "authority_sha256=$(sha256sum "$authority_tool_path" | awk '{print $1}')" \
    "pairing_sha256=$(sha256sum "$pairing_tool_path" | awk '{print $1}')" \
    "service_sha256=$(sha256sum "$service_path" | awk '{print $1}')" \
    "agent_service_sha256=$(sha256sum "$agent_service_path" | awk '{print $1}')" \
    "source_helper_sha256=$(sha256sum "$source_helper_path" | awk '{print $1}')" \
    "source_provision_sha256=$(sha256sum "$source_provision_path" | awk '{print $1}')" \
    "source_worker_sha256=$(sha256sum "$source_worker_path" | awk '{print $1}')" \
    "source_service_sha256=$(sha256sum "$source_service_path" | awk '{print $1}')" \
    "source_peer_policy_sha256=$(sha256sum "$source_peer_policy" | awk '{print $1}')" \
    "source_public_key_sha256=$(sha256sum "$source_public_key" | awk '{print $1}')" \
    "source_digest_sha256=$(sha256sum "$source_digest" | awk '{print $1}')" \
    "source_signing_key_sha256=$(sha256sum "$source_signing_key" | awk '{print $1}')" \
    "authority_record_sha256=$(sha256sum "$authority_path" | awk '{print $1}')" \
    "modules_sha256=$(sha256sum "$modules_path" | awk '{print $1}')" \
    "usbip_sha256=$(sha256sum /usr/sbin/usbip | awk '{print $1}')" \
    "entry_target=$client_path" \
    "state_root=$state_root" \
    "journal_schema=closed-fixed-paths" > "$temporary"
  chown root:root "$temporary"
  chmod 0600 "$temporary"
  mv -T -- "$temporary" "$destination"
  sync -f "$destination"
  sync -f "$package_state"
}

stop_and_quiesce() {
  if systemctl is-active --quiet usbip-linux-client.service; then
    record_lifecycle_phase agent-draining
    runuser -u "$installed_user" -- "$client_path" --fabric-maintenance-drain || return 1
    record_lifecycle_phase agent-stopping
    systemctl stop usbip-linux-client.service || return 1
  fi
  [ "$(systemctl is-active usbip-linux-client.service 2>/dev/null || true)" != active ] || return 1
  if [ "${source_helper_recorded:-0}" -eq 1 ]; then
    record_lifecycle_phase source-helper-stopping
    systemctl stop usbip-linux-client-source-helper.service || return 1
    [ "$(systemctl is-active usbip-linux-client-source-helper.service 2>/dev/null || true)" = inactive ] || return 1
    [ ! -e /run/usbip-source-helper/control.sock ] || return 1
  fi
  # The unprivileged agent must release every helper-owned attachment before
  # the privileged helper can be stopped.
  [ ! -e /var/lib/usbip-vhci-helper/ownership.v1 ] || return 1
  [ ! -e /var/lib/usbip-vhci-helper/ownership.v2 ] || return 1
  record_lifecycle_phase helper-stopping
  systemctl stop usbip-linux-client-vhci.service || return 1
  [ "$(systemctl is-active usbip-linux-client-vhci.service 2>/dev/null || true)" = inactive ] || return 1
  [ ! -e /run/usbip-vhci-helper/control.sock ] || return 1
  # `/run/vhci_hcd` is upstream global state and is inspected read-only.
  [ ! -e /var/lib/usbip-vhci-helper/ownership.v1 ] || return 1
  [ ! -e /var/lib/usbip-vhci-helper/ownership.v2 ] || return 1
}

start_service_set() {
  record_lifecycle_phase helper-starting
  systemctl start usbip-linux-client-vhci.service
  wait_helper_ready || return 1
  if [ "${source_helper_recorded:-1}" -eq 1 ]; then
    record_lifecycle_phase source-helper-starting
    systemctl start usbip-linux-client-source-helper.service
    wait_source_helper_ready || return 1
  fi
  if [ -n "$(find "$state_root/identity" -mindepth 1 -maxdepth 1 -type f -print -quit)" ]; then
    record_lifecycle_phase agent-starting
    systemctl start usbip-linux-client.service
    systemctl is-active --quiet usbip-linux-client.service || return 1
    record_lifecycle_phase agent-health-checking
    runuser -u "$installed_user" -- "$client_path" --fabric-health-probe
  fi
}

wait_source_helper_ready() {
  attempts=0
  while [ "$attempts" -lt 50 ]; do
    if systemctl is-active --quiet usbip-linux-client-source-helper.service \
      && [ -S /run/usbip-source-helper/control.sock ]; then
      return 0
    fi
    systemctl is-active --quiet usbip-linux-client-source-helper.service || return 1
    sleep 0.1
    attempts=$((attempts + 1))
  done
  return 1
}

wait_helper_ready() {
  attempts=0
  while [ "$attempts" -lt 50 ]; do
    if systemctl is-active --quiet usbip-linux-client-vhci.service \
      && [ -S /run/usbip-vhci-helper/control.sock ]; then
      return 0
    fi
    systemctl is-active --quiet usbip-linux-client-vhci.service || return 1
    sleep 0.1
    attempts=$((attempts + 1))
  done
  return 1
}

write_durable_record() {
  destination=$1
  shift
  parent=$(dirname -- "$destination")
  temporary=$(mktemp "$parent/.usbip-client-transaction.XXXXXX")
  printf '%s\n' "$@" > "$temporary"
  chown root:root "$temporary"
  chmod 0600 "$temporary"
  sync -f "$temporary"
  mv -T -- "$temporary" "$destination"
  sync -f "$parent"
}

write_install_transaction() {
  phase=$1 user=$2 uid=$3 gid=$4
  write_durable_record "$install_transaction" \
    USBIP_LINUX_CLIENT_INSTALL_TRANSACTION_V1 \
    operation=install "phase=$phase" "client_user=$user" "client_uid=$uid" "client_gid=$gid"
}

write_upgrade_record() {
  write_durable_record "$upgrade_record" USBIP_LINUX_CLIENT_UPGRADE_V1 "stage=$1"
}

append_client_backup_entry() {
  original=$1
  backup_name=$(basename -- "$original")
  printf '%s|%s|%s|%s|%s|%s\n' "$original" "$backup_name" \
    "$(stat -c '%a' "$original")" "$(stat -c '%u' "$original")" \
    "$(stat -c '%g' "$original")" "$(sha256sum "$original" | awk '{print $1}')" \
    >> "$upgrade_backup/OWNERSHIP.v1"
}

backup_client_database() {
  database=$installed_state_root/fabric.db
  [ ! -e "$database" ] && [ ! -L "$database" ] && return 0
  install -d -o root -g root -m 0700 "$upgrade_backup/database"
  for suffix in '' -wal -shm; do
    source_file=$database$suffix
    if [ -e "$source_file" ] || [ -L "$source_file" ]; then
      [ -f "$source_file" ] && [ ! -L "$source_file" ] || return 1
      [ "$(stat -c '%u:%g:%a:%h' "$source_file")" = "$installed_uid:$installed_gid:600:1" ] || return 1
      cp -p -- "$source_file" "$upgrade_backup/database/fabric.db$suffix"
      sync -f "$upgrade_backup/database/fabric.db$suffix"
    fi
  done
  (cd "$upgrade_backup/database" && find . -type f -name 'fabric.db*' -print | \
    LC_ALL=C sort | xargs sha256sum -- > MANIFEST.sha256)
  chown root:root "$upgrade_backup/database/MANIFEST.sha256"
  chmod 0600 "$upgrade_backup/database/MANIFEST.sha256"
  sync -f "$upgrade_backup/database/MANIFEST.sha256"
  sync -f "$upgrade_backup/database"
}

create_client_upgrade_backup() {
  [ ! -e "$upgrade_backup" ] && [ ! -L "$upgrade_backup" ] || return 1
  install -d -o root -g root -m 0700 "$upgrade_backup"
  (umask 077; printf '%s\n' USBIP_LINUX_CLIENT_OWNERSHIP_V1 > "$upgrade_backup/OWNERSHIP.v1")
  for original in "$install_record" "$client_path" "$helper_path" \
    "$authority_tool_path" "$pairing_tool_path" "$service_path"; do
    [ -f "$original" ] && [ ! -L "$original" ] || return 1
    cp -p -- "$original" "$upgrade_backup/$(basename -- "$original")"
    append_client_backup_entry "$original"
  done
  if [ "${source_helper_recorded:-0}" -eq 1 ]; then
    for original in "$source_helper_path" "$source_provision_path" "$source_worker_path" \
      "$source_service_path" "$source_peer_policy" "$source_public_key" "$source_digest" \
      "$source_signing_key"; do
      [ -f "$original" ] && [ ! -L "$original" ] || return 1
      cp -p -- "$original" "$upgrade_backup/$(basename -- "$original")"
      append_client_backup_entry "$original"
    done
  fi
  if [ "$agent_service_recorded" -eq 1 ]; then
    cp -p -- "$agent_service_path" "$upgrade_backup/usbip-linux-client.service"
    append_client_backup_entry "$agent_service_path"
  fi
  printf 'agent_service_present=%s\nsource_helper_present=%s\nstate_root=%s\n' "$agent_service_recorded" \
    "${source_helper_recorded:-0}" "$installed_state_root" >> "$upgrade_backup/OWNERSHIP.v1"
  chown root:root "$upgrade_backup/OWNERSHIP.v1"
  chmod 0600 "$upgrade_backup/OWNERSHIP.v1"
  backup_client_database
  for backup_file in "$upgrade_backup"/*; do
    [ -f "$backup_file" ] && sync -f "$backup_file"
  done
  sync -f "$upgrade_backup"
  sync -f "$package_state"
}

validate_client_upgrade_backup() {
  [ -d "$upgrade_backup" ] && [ ! -L "$upgrade_backup" ] || return 1
  [ "$(stat -c '%a:%u:%g' "$upgrade_backup")" = 700:0:0 ] || return 1
  verify_regular "$upgrade_backup/OWNERSHIP.v1" \
    "$(sha256sum "$upgrade_backup/OWNERSHIP.v1" | awk '{print $1}')" 600 0 0 || return 1
  [ "$(sed -n '1p' "$upgrade_backup/OWNERSHIP.v1")" = USBIP_LINUX_CLIENT_OWNERSHIP_V1 ] || return 1
  tail -n +2 "$upgrade_backup/OWNERSHIP.v1" | while IFS='|' read -r original name mode uid gid hash; do
    case "$original" in agent_service_present=*|source_helper_present=*|state_root=*) continue ;; esac
    [ "$(basename -- "$original")" = "$name" ] || exit 1
    verify_regular "$upgrade_backup/$name" "$hash" "$mode" "$uid" "$gid" || exit 1
  done
  if [ -d "$upgrade_backup/database" ]; then
    [ ! -L "$upgrade_backup/database" ] && [ "$(stat -c '%a:%u:%g' "$upgrade_backup/database")" = 700:0:0 ] || return 1
    verify_regular "$upgrade_backup/database/MANIFEST.sha256" \
      "$(sha256sum "$upgrade_backup/database/MANIFEST.sha256" | awk '{print $1}')" 600 0 0 || return 1
    (cd "$upgrade_backup/database" && sha256sum -c MANIFEST.sha256 >/dev/null) || return 1
  fi
}

validate_client_restored_files() {
  tail -n +2 "$upgrade_backup/OWNERSHIP.v1" | while IFS='|' read -r original name mode uid gid hash; do
    case "$original" in agent_service_present=*|source_helper_present=*|state_root=*) continue ;; esac
    [ -f "$original" ] && [ ! -L "$original" ] || exit 1
    [ "$(stat -c '%a:%u:%g:%h' "$original")" = "$mode:$uid:$gid:1" ] || exit 1
    [ "$(sha256sum "$original" | awk '{print $1}')" = "$hash" ] || exit 1
  done
}

restore_client_database() {
  old_state_root=$(sed -n 's/^state_root=//p' "$upgrade_backup/OWNERSHIP.v1")
  case "$old_state_root" in "$state_root"|"$legacy_state_root") ;; *) return 1 ;; esac
  if [ "$old_state_root" = "$legacy_state_root" ] && [ -d "$state_root" ]; then
    [ ! -e "$legacy_state_root" ] && [ ! -L "$legacy_state_root" ] || return 1
    mv -T -- "$state_root" "$legacy_state_root"
    sync -f /var/lib
  fi
  [ ! -d "$upgrade_backup/database" ] && return 0
  rm -f -- "$old_state_root/fabric.db" "$old_state_root/fabric.db-wal" "$old_state_root/fabric.db-shm"
  for source_file in "$upgrade_backup"/database/fabric.db*; do
    [ -e "$source_file" ] || continue
    cp -p -- "$source_file" "$old_state_root/"
  done
  sync -f "$old_state_root"
}

restore_client_upgrade_backup() {
  validate_client_upgrade_backup || return 1
  install -o root -g root -m 0755 "$upgrade_backup/usbip-linux-client" "$client_path"
  install -o root -g root -m 0755 "$upgrade_backup/usbip-linux-vhci-helper" "$helper_path"
  install -o root -g root -m 0755 "$upgrade_backup/usbip-linux-authority" "$authority_tool_path"
  install -o root -g root -m 0755 "$upgrade_backup/usbip-linux-pairing" "$pairing_tool_path"
  install -o root -g root -m 0644 "$upgrade_backup/usbip-linux-client-vhci.service" "$service_path"
  old_agent=$(sed -n 's/^agent_service_present=//p' "$upgrade_backup/OWNERSHIP.v1")
  case "$old_agent" in
    1) install -o root -g root -m 0644 "$upgrade_backup/usbip-linux-client.service" "$agent_service_path" ;;
    0) rm -f -- "$agent_service_path" ;;
    *) return 1 ;;
  esac
  old_source=$(sed -n 's/^source_helper_present=//p' "$upgrade_backup/OWNERSHIP.v1")
  case "$old_source" in
    1)
      install -o root -g root -m 0755 "$upgrade_backup/usbip-linux-client-source-helper" "$source_helper_path"
      install -o root -g root -m 0755 "$upgrade_backup/usbip-linux-client-source-provision" "$source_provision_path"
      install -o root -g root -m 0755 "$upgrade_backup/usbip-linux-master-usb-worker" "$source_worker_path"
      install -o root -g root -m 0644 "$upgrade_backup/usbip-linux-client-source-helper.service" "$source_service_path"
      install -o root -g root -m 0600 "$upgrade_backup/client-source-helper-peer.v1" "$source_peer_policy"
      install -o root -g root -m 0644 "$upgrade_backup/client-source-helper-public-key.ed25519" "$source_public_key"
      install -o root -g root -m 0644 "$upgrade_backup/client-source-helper-executable.sha256.bin" "$source_digest"
      install -o root -g root -m 0600 "$upgrade_backup/broker-signing-key.pk8" "$source_signing_key"
      ;;
    0)
      rm -f -- "$source_service_path" "$source_helper_path" "$source_provision_path" \
        "$source_worker_path" "$source_peer_policy" "$source_public_key" "$source_digest" \
        "$source_signing_key"
      ;;
    *) return 1 ;;
  esac
  install -o root -g root -m 0600 "$upgrade_backup/install.v1" "$install_record"
  restore_client_database
  validate_client_restored_files
}

clear_upgrade_transaction() {
  for name in usbip-linux-client usbip-linux-vhci-helper usbip-linux-authority usbip-linux-pairing \
    usbip-linux-client-source-helper usbip-linux-client-source-provision usbip-linux-master-usb-worker \
    usbip-linux-client-source-helper.service client-source-helper-peer.v1 \
    client-source-helper-public-key.ed25519 client-source-helper-executable.sha256.bin \
    broker-signing-key.pk8 usbip-linux-client-vhci.service usbip-linux-client.service install.v1 OWNERSHIP.v1; do
    rm -f -- "$upgrade_backup/$name"
  done
  if [ -d "$upgrade_backup/database" ] && [ ! -L "$upgrade_backup/database" ]; then
    rm -f -- "$upgrade_backup/database/fabric.db" "$upgrade_backup/database/fabric.db-wal" \
      "$upgrade_backup/database/fabric.db-shm" "$upgrade_backup/database/MANIFEST.sha256"
    rmdir -- "$upgrade_backup/database"
  fi
  [ ! -d "$upgrade_backup" ] || rmdir -- "$upgrade_backup"
  discard_prepared_stage
  rm -f -- "$upgrade_record"
  sync -f "$package_state"
}

validate_partial_upgrade_backup() {
  [ ! -e "$upgrade_backup" ] && return 0
  [ -d "$upgrade_backup" ] && [ ! -L "$upgrade_backup" ] && [ "$(stat -c '%a:%u:%g' "$upgrade_backup")" = 700:0:0 ] || return 1
  for path in "$upgrade_backup"/*; do
    [ -e "$path" ] || continue
    name=${path##*/}
    case "$name" in
      install.v1) cmp -s "$path" "$install_record" || return 1 ;;
      usbip-linux-client) verify_regular "$path" "$(record_value client_sha256)" 755 0 0 || return 1 ;;
      usbip-linux-vhci-helper) verify_regular "$path" "$(record_value helper_sha256)" 755 0 0 || return 1 ;;
      usbip-linux-authority) verify_regular "$path" "$(record_value authority_sha256)" 755 0 0 || return 1 ;;
      usbip-linux-pairing) verify_regular "$path" "$(record_value pairing_sha256)" 755 0 0 || return 1 ;;
      usbip-linux-client-source-helper) verify_regular "$path" "$(record_value source_helper_sha256)" 755 0 0 || return 1 ;;
      usbip-linux-client-source-provision) verify_regular "$path" "$(record_value source_provision_sha256)" 755 0 0 || return 1 ;;
      usbip-linux-master-usb-worker) verify_regular "$path" "$(record_value source_worker_sha256)" 755 0 0 || return 1 ;;
      usbip-linux-client-source-helper.service) verify_regular "$path" "$(record_value source_service_sha256)" 644 0 0 || return 1 ;;
      client-source-helper-peer.v1) verify_regular "$path" "$(record_value source_peer_policy_sha256)" 600 0 0 || return 1 ;;
      client-source-helper-public-key.ed25519) verify_regular "$path" "$(record_value source_public_key_sha256)" 644 0 0 || return 1 ;;
      client-source-helper-executable.sha256.bin) verify_regular "$path" "$(record_value source_digest_sha256)" 644 0 0 || return 1 ;;
      broker-signing-key.pk8) verify_regular "$path" "$(record_value source_signing_key_sha256)" 600 0 0 || return 1 ;;
      usbip-linux-client-vhci.service) verify_regular "$path" "$(record_value service_sha256)" 644 0 0 || return 1 ;;
      usbip-linux-client.service)
        [ "$agent_service_recorded" -eq 1 ] || return 1
        verify_regular "$path" "$(record_value agent_service_sha256)" 644 0 0 || return 1
        ;;
      OWNERSHIP.v1) [ -f "$path" ] && [ ! -L "$path" ] && [ "$(stat -c '%a:%u:%g' "$path")" = 600:0:0 ] || return 1 ;;
      database) [ -d "$path" ] && [ ! -L "$path" ] && [ "$(stat -c '%a:%u:%g' "$path")" = 700:0:0 ] || return 1 ;;
      *) return 1 ;;
    esac
  done
}

clear_install_transaction() {
  rm -f -- "$install_transaction"
  sync -f /var/lib
}

write_remove_record() {
  stage=$1
  write_durable_record "$remove_record" USBIP_LINUX_CLIENT_REMOVE_V1 "stage=$stage"
}

record_lifecycle_phase() {
  phase=$1
  case "${lifecycle_operation:-}" in
    install) write_install_transaction "$phase" "$installed_user" "$installed_uid" "$installed_gid" ;;
    upgrade) write_upgrade_record "$phase" ;;
    remove) write_remove_record "$phase" ;;
    rollback) write_upgrade_record "rollback-$phase" ;;
    *) return 1 ;;
  esac
}

remove_backup_value() {
  key=$1
  value=$(sed -n "s/^$key=//p" "$remove_backup/install.v1")
  [ "$(grep -c "^$key=" "$remove_backup/install.v1")" -eq 1 ] || return 1
  printf '%s\n' "$value"
}

validate_remove_backup() {
  [ -d "$remove_backup" ] && [ ! -L "$remove_backup" ] || { echo "Removal backup is missing." >&2; return 1; }
  [ "$(stat -c '%a:%u:%g' "$remove_backup")" = 700:0:0 ] || { echo "Removal backup mode or owner changed." >&2; return 1; }
expected='authority.v1
broker-signing-key.pk8
client-source-helper-executable.sha256.bin
client-source-helper-peer.v1
client-source-helper-public-key.ed25519
install.v1
usbip
usbip-linux-authority
usbip-linux-client
usbip-linux-client.service
usbip-linux-client-source-helper
usbip-linux-client-source-helper.service
usbip-linux-client-source-provision
usbip-linux-client-vhci.service
usbip-linux-client.conf
usbip-linux-master-usb-worker
usbip-linux-pairing
usbip-linux-vhci-helper'
  actual=$(find "$remove_backup" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
  [ "$actual" = "$expected" ] || { echo "Removal backup inventory changed." >&2; return 1; }
  [ "$(stat -c '%a:%u:%g' "$remove_backup/install.v1")" = 600:0:0 ] || return 1
  [ "$(wc -l < "$remove_backup/install.v1")" -eq 33 ] || return 1
  [ "$(sed -n '1p' "$remove_backup/install.v1")" = USBIP_LINUX_CLIENT_INSTALL_V3 ] || return 1
  installed_target=$(remove_backup_value target) || return 1
  installed_user=$(remove_backup_value client_user) || return 1
  installed_uid=$(remove_backup_value client_uid) || return 1
  installed_gid=$(remove_backup_value client_gid) || return 1
  helper_gid=$(remove_backup_value helper_gid) || return 1
  group_created=$(remove_backup_value group_created) || return 1
  membership_added=$(remove_backup_value membership_added) || return 1
  usbip_core_was_loaded=$(remove_backup_value usbip_core_was_loaded) || return 1
  vhci_hcd_was_loaded=$(remove_backup_value vhci_hcd_was_loaded) || return 1
  usbip_copy_created=$(remove_backup_value usbip_copy_created) || return 1
  owned_packages=$(remove_backup_value owned_packages | tr ',' ' ') || return 1
  owned_package_versions=$(remove_backup_value owned_package_versions | tr ',' ' ') || return 1
  case "$installed_target" in x86_64-unknown-linux-musl|aarch64-unknown-linux-musl) ;; *) return 1 ;; esac
  case "$installed_user" in ''|root|-*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  case "$installed_uid:$installed_gid:$helper_gid" in *[!0-9:]*) return 1 ;; esac
  case "$group_created:$membership_added:$usbip_core_was_loaded:$vhci_hcd_was_loaded:$usbip_copy_created" in [01]:[01]:[01]:[01]:[01]) ;; *) return 1 ;; esac
  case "$owned_packages" in *[!A-Za-z0-9.+_\ -]*) return 1 ;; esac
  case "$owned_package_versions" in *[!A-Za-z0-9.+_:~=,\ -]*) return 1 ;; esac
  version_package_names=
  for package_spec in $owned_package_versions; do
    package_name=${package_spec%%=*}
    recorded_package_version=${package_spec#*=}
    [ -n "$package_name" ] && [ -n "$recorded_package_version" ] && [ "$package_name" != "$recorded_package_version" ] || return 1
    version_package_names="$version_package_names $package_name"
  done
  version_package_names=$(printf '%s\n' "$version_package_names" | awk '{$1=$1; print}')
  [ "$version_package_names" = "$owned_packages" ] || return 1
  verify_regular "$remove_backup/usbip-linux-client" "$(remove_backup_value client_sha256)" 755 0 0 || return 1
  verify_regular "$remove_backup/usbip-linux-vhci-helper" "$(remove_backup_value helper_sha256)" 755 0 0 || return 1
  verify_regular "$remove_backup/usbip-linux-authority" "$(remove_backup_value authority_sha256)" 755 0 0 || return 1
  verify_regular "$remove_backup/usbip-linux-pairing" "$(remove_backup_value pairing_sha256)" 755 0 0 || return 1
  verify_regular "$remove_backup/usbip-linux-client-vhci.service" "$(remove_backup_value service_sha256)" 644 0 0 || return 1
  verify_regular "$remove_backup/usbip-linux-client.service" "$(remove_backup_value agent_service_sha256)" 644 0 0 || return 1
  verify_regular "$remove_backup/usbip-linux-client-source-helper" "$(remove_backup_value source_helper_sha256)" 755 0 0 || return 1
  verify_regular "$remove_backup/usbip-linux-client-source-provision" "$(remove_backup_value source_provision_sha256)" 755 0 0 || return 1
  verify_regular "$remove_backup/usbip-linux-master-usb-worker" "$(remove_backup_value source_worker_sha256)" 755 0 0 || return 1
  verify_regular "$remove_backup/usbip-linux-client-source-helper.service" "$(remove_backup_value source_service_sha256)" 644 0 0 || return 1
  verify_regular "$remove_backup/client-source-helper-peer.v1" "$(remove_backup_value source_peer_policy_sha256)" 600 0 0 || return 1
  verify_regular "$remove_backup/client-source-helper-public-key.ed25519" "$(remove_backup_value source_public_key_sha256)" 644 0 0 || return 1
  verify_regular "$remove_backup/client-source-helper-executable.sha256.bin" "$(remove_backup_value source_digest_sha256)" 644 0 0 || return 1
  verify_regular "$remove_backup/broker-signing-key.pk8" "$(remove_backup_value source_signing_key_sha256)" 600 0 0 || return 1
  verify_regular "$remove_backup/authority.v1" "$(remove_backup_value authority_record_sha256)" 640 0 0 || return 1
  verify_regular "$remove_backup/usbip-linux-client.conf" "$(remove_backup_value modules_sha256)" 644 0 0 || return 1
  verify_regular "$remove_backup/usbip" "$(remove_backup_value usbip_sha256)" 755 0 0 || return 1
}

validate_partial_remove_backup() {
  [ ! -e "$remove_backup" ] && return 0
  [ -d "$remove_backup" ] && [ ! -L "$remove_backup" ] && [ "$(stat -c '%a:%u:%g' "$remove_backup")" = 700:0:0 ] || return 1
  for path in "$remove_backup"/*; do
    [ -e "$path" ] || continue
    name=${path##*/}
    case "$name" in
      install.v1) cmp -s "$path" "$install_record" || return 1 ;;
      usbip-linux-client) verify_regular "$path" "$(record_value client_sha256)" 755 0 0 || return 1 ;;
      usbip-linux-vhci-helper) verify_regular "$path" "$(record_value helper_sha256)" 755 0 0 || return 1 ;;
      usbip-linux-authority) verify_regular "$path" "$(record_value authority_sha256)" 755 0 0 || return 1 ;;
      usbip-linux-pairing) verify_regular "$path" "$(record_value pairing_sha256)" 755 0 0 || return 1 ;;
      usbip-linux-client-vhci.service) verify_regular "$path" "$(record_value service_sha256)" 644 0 0 || return 1 ;;
      usbip-linux-client.service) verify_regular "$path" "$(record_value agent_service_sha256)" 644 0 0 || return 1 ;;
      usbip-linux-client-source-helper) verify_regular "$path" "$(record_value source_helper_sha256)" 755 0 0 || return 1 ;;
      usbip-linux-client-source-provision) verify_regular "$path" "$(record_value source_provision_sha256)" 755 0 0 || return 1 ;;
      usbip-linux-master-usb-worker) verify_regular "$path" "$(record_value source_worker_sha256)" 755 0 0 || return 1 ;;
      usbip-linux-client-source-helper.service) verify_regular "$path" "$(record_value source_service_sha256)" 644 0 0 || return 1 ;;
      client-source-helper-peer.v1) verify_regular "$path" "$(record_value source_peer_policy_sha256)" 600 0 0 || return 1 ;;
      client-source-helper-public-key.ed25519) verify_regular "$path" "$(record_value source_public_key_sha256)" 644 0 0 || return 1 ;;
      client-source-helper-executable.sha256.bin) verify_regular "$path" "$(record_value source_digest_sha256)" 644 0 0 || return 1 ;;
      broker-signing-key.pk8) verify_regular "$path" "$(record_value source_signing_key_sha256)" 600 0 0 || return 1 ;;
      authority.v1) verify_regular "$path" "$(record_value authority_record_sha256)" 640 0 0 || return 1 ;;
      usbip-linux-client.conf) verify_regular "$path" "$(record_value modules_sha256)" 644 0 0 || return 1 ;;
      usbip) verify_regular "$path" "$(record_value usbip_sha256)" 755 0 0 || return 1 ;;
      *) return 1 ;;
    esac
  done
}

clear_remove_transaction() {
  disposition=${1:-finish-removal}
  rm -f -- \
    "$remove_backup/authority.v1" \
    "$remove_backup/install.v1" \
    "$remove_backup/usbip" \
    "$remove_backup/usbip-linux-authority" \
    "$remove_backup/usbip-linux-client" \
    "$remove_backup/usbip-linux-client.service" \
    "$remove_backup/usbip-linux-client-source-helper" \
    "$remove_backup/usbip-linux-client-source-helper.service" \
    "$remove_backup/usbip-linux-client-source-provision" \
    "$remove_backup/usbip-linux-client-vhci.service" \
    "$remove_backup/usbip-linux-client.conf" \
    "$remove_backup/usbip-linux-pairing" \
    "$remove_backup/usbip-linux-master-usb-worker" \
    "$remove_backup/client-source-helper-peer.v1" \
    "$remove_backup/client-source-helper-public-key.ed25519" \
    "$remove_backup/client-source-helper-executable.sha256.bin" \
    "$remove_backup/broker-signing-key.pk8" \
    "$remove_backup/usbip-linux-vhci-helper"
  [ ! -d "$remove_backup" ] || rmdir -- "$remove_backup"
  rm -f -- "$remove_record"
  if [ "$disposition" = finish-removal ]; then
    rm -f -- "$install_record"
    rmdir "$package_root" "$package_state" /var/lib/usbip-vhci-helper 2>/dev/null || true
  fi
}

mode=${1:-}
case "$mode" in
  --check)
    [ "$#" -eq 1 ] || usage
    verify_bundle
    echo "LINUX_CLIENT_PRODUCT_BUNDLE_VALID"
    ;;
  --host-check)
    [ "$#" -eq 1 ] || usage
    verify_bundle
    host_gate
    echo "LINUX_CLIENT_PRODUCT_HOST_SUPPORTED"
    ;;
  --install)
    [ "$#" -eq 3 ] && [ "$2" = "$ack" ] || usage
    [ "$(id -u)" -eq 0 ] || { echo "Installation requires root." >&2; exit 1; }
    user=$3
    case "$user" in ''|root|-*|*[!A-Za-z0-9_.-]*) echo "Unsafe Client user name." >&2; exit 1 ;; esac
    verify_bundle
    host_gate
    for command in find getent id install ln modinfo readlink systemctl systemd-tmpfiles; do require_command "$command"; done
    user_record=$(getent passwd "$user")
    [ -n "$user_record" ] || { echo "Client user does not exist." >&2; exit 1; }
    client_uid=$(printf '%s\n' "$user_record" | awk -F: '{print $3}')
    client_gid=$(printf '%s\n' "$user_record" | awk -F: '{print $4}')
    [ "$client_uid" -gt 0 ] || { echo "Root cannot be the Client user." >&2; exit 1; }
    for path in "$package_root" "$entry_path" "$service_path" "$agent_service_path" "$source_service_path" \
      "$source_peer_policy" "$source_public_key" "$source_digest" "$source_signing_key" \
      "$legacy_state_root" "$package_state"; do
      [ ! -e "$path" ] && [ ! -L "$path" ] || { echo "Refusing to overwrite an existing path: $path" >&2; exit 1; }
    done
    [ ! -e /etc/systemd/system/usbip-vhci-helper.service ] || { echo "Prototype helper installation must be removed first." >&2; exit 1; }

    group_created=0 membership_added=0 usbip_core_was_loaded=1 vhci_hcd_was_loaded=1 usbip_copy_created=0 install_complete=0
    state_preexisting=0 authority_preexisting=0 modules_preexisting=0 tmpfiles_preexisting=0
    newly_installed_packages=
    [ -d /sys/module/usbip_core ] && [ -d /sys/module/vhci_hcd ] || { echo "Preloaded USB/IP Client modules are required; installer will not mutate kernel state." >&2; exit 1; }
    # The helper deliberately executes one fixed path. Resolve any safe,
    # package-owned distro location and create a tracked copy only when that
    # fixed path is unoccupied.
    usbip_copy_source=$(find_package_owned_usbip) || {
      echo "A root-owned, package-owned usbip tool is required; installer will not mutate packages." >&2
      exit 1
    }
    if [ "$usbip_copy_source" != /usr/sbin/usbip ]; then
      # A tracked copy is only ever created on an unoccupied path, so rollback
      # and removal can delete it without destroying foreign state.
      [ ! -e /usr/sbin/usbip ] && [ ! -L /usr/sbin/usbip ] || { echo "Refusing to overwrite an existing path: /usr/sbin/usbip" >&2; exit 1; }
      usbip_copy_created=1
    fi
    getent group usbip >/dev/null || { echo "Pre-existing usbip group is required; installer will not mutate accounts." >&2; exit 1; }
    id -nG "$user" | tr ' ' '\n' | grep -Fxq usbip || { echo "Client user must already belong to usbip; installer will not mutate accounts." >&2; exit 1; }
    rollback_install() {
      status=$?
      trap - EXIT HUP INT TERM
      if [ "$install_complete" -eq 0 ]; then
        systemctl disable --now usbip-linux-client.service usbip-linux-client-vhci.service \
          usbip-linux-client-source-helper.service >/dev/null 2>&1 || true
        rm -f -- "$entry_path" "$service_path" "$agent_service_path" "$client_path" \
          "$source_service_path" "$helper_path" "$authority_tool_path" "$pairing_tool_path" \
          "$source_helper_path" "$source_provision_path" "$source_worker_path" \
          "$source_peer_policy" "$source_public_key" "$source_digest" "$source_signing_key" \
          "$install_record"
        [ "$authority_preexisting" -eq 1 ] || rm -f -- "$authority_path"
        [ "$modules_preexisting" -eq 1 ] || rm -f -- "$modules_path"
        [ "$tmpfiles_preexisting" -eq 1 ] || remove_vhci_tmpfiles
        [ "$usbip_copy_created" -ne 1 ] || rm -f -- /usr/sbin/usbip
        systemctl daemon-reload >/dev/null 2>&1 || true
        if [ "$state_preexisting" -eq 0 ]; then
          rmdir "$state_root/identity" "$state_root/pairing" "$state_root/authority" \
            "$state_root/offers" "$state_root" 2>/dev/null || true
        fi
        rmdir "$package_root" "$package_state" /etc/usbip-vhci-helper \
          /var/lib/usbip-vhci-helper 2>/dev/null || true
        clear_install_transaction
      fi
      exit "$status"
    }
    trap rollback_install EXIT
    trap 'exit 1' HUP INT TERM

    modinfo usbip_core >/dev/null && modinfo vhci_hcd >/dev/null || { echo "Running kernel lacks USB/IP Client modules." >&2; exit 1; }
    helper_gid=$(getent group usbip | awk -F: '{print $3}')
    [ "$helper_gid" -gt 0 ] || exit 1
    if [ -e "$state_root" ] || [ -L "$state_root" ]; then
      validate_state_tree "$state_root" "$client_uid" "$client_gid" || { echo "Preserved Client state is unsafe." >&2; exit 1; }
      state_preexisting=1
    fi
    if [ -e "$authority_path" ] || [ -L "$authority_path" ]; then
      [ -f "$authority_path" ] && [ ! -L "$authority_path" ] && [ "$(stat -c '%a:%u:%g:%h' "$authority_path")" = 640:0:0:1 ] || exit 1
      authority_preexisting=1
    fi
    if [ -e "$modules_path" ] || [ -L "$modules_path" ]; then
      [ -f "$modules_path" ] && [ ! -L "$modules_path" ] && [ "$(stat -c '%a:%u:%g:%h' "$modules_path")" = 644:0:0:1 ] || exit 1
      modules_preexisting=1
    fi
    if [ -e "$tmpfiles_path" ] || [ -L "$tmpfiles_path" ]; then
      [ -f "$tmpfiles_path" ] && [ ! -L "$tmpfiles_path" ] && [ "$(stat -c '%a:%u:%g:%h' "$tmpfiles_path")" = 644:0:0:1 ] || exit 1
      tmpfiles_preexisting=1
    fi
    [ ! -e "$install_transaction" ] || { echo "Install recovery journal exists; use --recover-install." >&2; exit 1; }
    write_install_transaction pre-mutation "$user" "$client_uid" "$client_gid"
    install -d -o root -g root -m 0755 "$package_root" /etc/usbip-vhci-helper
    install -d -o root -g root -m 0700 "$package_state"
    install -d -o root -g root -m 0711 /var/lib/usbip
    install -d -o "$client_uid" -g "$client_gid" -m 0700 "$state_root" "$state_root/identity" "$state_root/pairing" "$state_root/authority" "$state_root/offers"
    if [ "$usbip_copy_created" -eq 1 ]; then
      install -o root -g root -m 0755 -- "$usbip_copy_source" /usr/sbin/usbip
    fi
    [ "$(stat -c '%a:%u:%g' /usr/sbin/usbip)" = 755:0:0 ] || { echo "usbip dependency ownership or mode is unsafe." >&2; exit 1; }
    install -o root -g root -m 0755 "$payload/usbip-linux-client" "$client_path"
    install -o root -g root -m 0755 "$payload/usbip-linux-vhci-helper" "$helper_path"
    install -o root -g root -m 0755 "$payload/usbip-linux-authority" "$authority_tool_path"
    install -o root -g root -m 0755 "$payload/usbip-linux-pairing" "$pairing_tool_path"
    install -o root -g root -m 0755 "$payload/usbip-linux-client-source-helper" "$source_helper_path"
    install -o root -g root -m 0755 "$payload/usbip-linux-client-source-provision" "$source_provision_path"
    install -o root -g root -m 0755 "$payload/usbip-linux-master-usb-worker" "$source_worker_path"
    ln -s -- "$client_path" "$entry_path"
    install -o root -g root -m 0644 "$payload/usbip-linux-client-vhci.service" "$service_path"
    install -o root -g root -m 0644 "$payload/usbip-linux-client-source-helper.service" "$source_service_path"
    render_agent_service "$payload/usbip-linux-client.service" "$agent_service_path" "$user" "$client_gid"
    "$source_provision_path" --client-uid "$client_uid" --client-gid "$client_gid"
    authority_temp=$(mktemp /etc/usbip-vhci-helper/.authority.v1.XXXXXX)
    printf '%s\n' USBIP_VHCI_AUTHORITY_V1 "client_uid=$client_uid" "helper_gid=$helper_gid" "client_executable=$client_path" > "$authority_temp"
    chown root:root "$authority_temp"; chmod 0640 "$authority_temp"; mv -T -- "$authority_temp" "$authority_path"
    modules_temp=$(mktemp /etc/modules-load.d/.usbip-linux-client.XXXXXX)
    printf '%s\n' usbip_core vhci_hcd > "$modules_temp"
    chown root:root "$modules_temp"; chmod 0644 "$modules_temp"; mv -T -- "$modules_temp" "$modules_path"
    install_vhci_tmpfiles
    [ -d /run/vhci_hcd ] || { echo "The privileged helper's read-only VHCI path could not be created." >&2; exit 1; }
    write_install_transaction files-installed "$user" "$client_uid" "$client_gid"
    packages_csv=$(printf '%s\n' "$newly_installed_packages" | awk '{$1=$1; gsub(/ /,","); print}')
    package_versions_csv=
    for installed_package in $newly_installed_packages; do
      installed_version=$(package_version "$installed_package")
      [ -n "$installed_version" ] || { echo "Installed dependency has no version: $installed_package." >&2; exit 1; }
      [ -z "$package_versions_csv" ] || package_versions_csv=$package_versions_csv,
      package_versions_csv=$package_versions_csv$installed_package=$installed_version
    done
    write_install_record "$install_record" "$(metadata_value target)" "$user" "$client_uid" "$client_gid" "$helper_gid" "$group_created" "$membership_added" "$usbip_core_was_loaded" "$vhci_hcd_was_loaded" "$usbip_copy_created" "$packages_csv" "$package_versions_csv"
    /usr/sbin/usbip port >/dev/null 2>&1 || { echo "usbip cannot inspect VHCI." >&2; exit 1; }
    verify_regular "$service_path" "$(metadata_value service_sha256)" 644 0 0 || exit 1
    [ -f "$agent_service_path" ] && [ ! -L "$agent_service_path" ] && \
      [ "$(stat -c '%a:%u:%g:%h' "$agent_service_path")" = 644:0:0:1 ] || exit 1
    write_install_transaction daemon-reloading "$user" "$client_uid" "$client_gid"
    systemctl daemon-reload
    write_install_transaction services-enabling "$user" "$client_uid" "$client_gid"
    systemctl enable usbip-linux-client-vhci.service usbip-linux-client-source-helper.service usbip-linux-client.service
    write_install_transaction helper-starting "$user" "$client_uid" "$client_gid"
    installed_user=$user
    installed_uid=$client_uid
    installed_gid=$client_gid
    source_helper_recorded=1
    lifecycle_operation=install
    start_service_set
    "$helper_path" --check-peer-pidfd >/dev/null
    wait_helper_ready || { echo "VHCI helper did not become ready within five seconds." >&2; exit 1; }
    [ ! -e /var/lib/usbip-vhci-helper/ownership.v1 ] && [ ! -e /var/lib/usbip-vhci-helper/ownership.v2 ]
    write_install_transaction committing "$user" "$client_uid" "$client_gid"
    install_complete=1
    clear_install_transaction
    trap - EXIT HUP INT TERM
    echo "LINUX_CLIENT_PRODUCT_INSTALLED user=$user"
    echo "No identity, pairing, connection, or USB attachment was created. Start a new login session before using the Client."
    ;;
  --recover-install)
    [ "$#" -eq 2 ] && [ "$2" = "$ack" ] || usage
    [ "$(id -u)" -eq 0 ] || { echo "Install recovery requires root." >&2; exit 1; }
    verify_bundle
    [ -f "$install_transaction" ] && [ ! -L "$install_transaction" ] || { echo "No exact recoverable install journal." >&2; exit 1; }
    [ "$(stat -c '%a:%u:%g' "$install_transaction")" = 600:0:0 ] || exit 1
    [ "$(wc -l < "$install_transaction")" -eq 6 ] || exit 1
    [ "$(sed -n '1p' "$install_transaction")" = USBIP_LINUX_CLIENT_INSTALL_TRANSACTION_V1 ] || exit 1
    [ "$(sed -n '2p' "$install_transaction")" = operation=install ] || exit 1
    recovery_phase=$(sed -n '3s/^phase=//p' "$install_transaction")
    case "$recovery_phase" in pre-mutation|files-installed|daemon-reloading|services-enabling|helper-starting|committing) ;; *) exit 1 ;; esac
    recovery_user=$(sed -n '4s/^client_user=//p' "$install_transaction")
    recovery_uid=$(sed -n '5s/^client_uid=//p' "$install_transaction")
    recovery_gid=$(sed -n '6s/^client_gid=//p' "$install_transaction")
    [ "$(getent passwd "$recovery_user" | awk -F: '{print $3 ":" $4}')" = "$recovery_uid:$recovery_gid" ] || exit 1
    [ ! -e /var/lib/usbip-vhci-helper/ownership.v1 ] && [ ! -e /var/lib/usbip-vhci-helper/ownership.v2 ] || { echo "Helper ownership exists; install recovery refuses mutation." >&2; exit 1; }
    if [ -e "$service_path" ]; then
      verify_regular "$service_path" "$(sha256sum "$payload/usbip-linux-client-vhci.service" | awk '{print $1}')" 644 0 0 || exit 1
      systemctl disable --now usbip-linux-client-vhci.service >/dev/null 2>&1 || true
    fi
    if [ -e "$agent_service_path" ]; then
      [ -f "$agent_service_path" ] && [ ! -L "$agent_service_path" ] && \
        [ "$(stat -c '%a:%u:%g:%h' "$agent_service_path")" = 644:0:0:1 ] || exit 1
      systemctl disable --now usbip-linux-client.service >/dev/null 2>&1 || true
    fi
    if [ -e "$source_service_path" ]; then
      verify_regular "$source_service_path" "$(sha256sum "$payload/usbip-linux-client-source-helper.service" | awk '{print $1}')" 644 0 0 || exit 1
      systemctl disable --now usbip-linux-client-source-helper.service >/dev/null 2>&1 || true
    fi
    for pair in \
      "$client_path:$payload/usbip-linux-client" \
      "$helper_path:$payload/usbip-linux-vhci-helper" \
      "$authority_tool_path:$payload/usbip-linux-authority" \
      "$pairing_tool_path:$payload/usbip-linux-pairing" \
      "$source_helper_path:$payload/usbip-linux-client-source-helper" \
      "$source_provision_path:$payload/usbip-linux-client-source-provision" \
      "$source_worker_path:$payload/usbip-linux-master-usb-worker"; do
      installed=${pair%%:*}; bundled=${pair#*:}
      if [ -e "$installed" ]; then
        verify_regular "$installed" "$(sha256sum "$bundled" | awk '{print $1}')" 755 0 0 || exit 1
      fi
    done
    if [ -e "$entry_path" ] || [ -L "$entry_path" ]; then
      [ -L "$entry_path" ] && [ "$(readlink "$entry_path")" = "$client_path" ] || exit 1
    fi
    if [ -e "$authority_path" ]; then
      [ "$(stat -c '%a:%u:%g' "$authority_path")" = 640:0:0 ] || exit 1
      [ "$(cat "$authority_path")" = "USBIP_VHCI_AUTHORITY_V1
client_uid=$recovery_uid
helper_gid=$(getent group usbip | awk -F: '{print $3}')
client_executable=$client_path" ] || exit 1
    fi
    if [ -e "$modules_path" ]; then
      [ "$(stat -c '%a:%u:%g' "$modules_path")" = 644:0:0 ] && [ "$(cat "$modules_path")" = 'usbip_core
vhci_hcd' ] || exit 1
    fi
    if [ -e "$state_root" ] || [ -L "$state_root" ]; then
      validate_state_tree "$state_root" "$recovery_uid" "$recovery_gid" || exit 1
    fi
    rm -f -- "$entry_path" "$service_path" "$agent_service_path" "$client_path" \
      "$source_service_path" "$helper_path" "$authority_tool_path" "$pairing_tool_path" \
      "$source_helper_path" "$source_provision_path" "$source_worker_path" \
      "$source_peer_policy" "$source_public_key" "$source_digest" "$source_signing_key" \
      "$install_record"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rmdir "$package_root" "$package_state" /var/lib/usbip-vhci-helper 2>/dev/null || true
    clear_install_transaction
    echo "LINUX_CLIENT_PRODUCT_INSTALL_RECOVERED"
    ;;
  --upgrade)
    [ "$#" -eq 2 ] && [ "$2" = "$ack" ] || usage
    [ "$(id -u)" -eq 0 ] || { echo "Upgrade requires root." >&2; exit 1; }
    verify_bundle
    host_gate
    verify_installed
    [ "$(metadata_value target)" = "$installed_target" ] || { echo "Upgrade target differs from installed architecture." >&2; exit 1; }
    write_upgrade_record stage-creating
    stage_upgrade_payload "$installed_user" "$installed_gid"
    write_upgrade_record staged
    lifecycle_operation=upgrade
    stop_and_quiesce || { lifecycle_operation=rollback; start_service_set >/dev/null 2>&1 || true; echo "Service set could not be quiesced; upgrade refused." >&2; exit 1; }
    write_upgrade_record stopped
    write_upgrade_record backup-creating
    create_client_upgrade_backup
    write_upgrade_record backup-complete
    upgrade_complete=0
    rollback_upgrade() {
      status=$?
      trap - EXIT HUP INT TERM
      if [ "$upgrade_complete" -eq 0 ] && [ -d "$upgrade_backup" ]; then
        write_upgrade_record rollback-payload-restoring >/dev/null 2>&1 || true
        restore_client_upgrade_backup >/dev/null 2>&1 || true
        write_upgrade_record rollback-daemon-reloading >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        load_install_record >/dev/null 2>&1 || true
        lifecycle_operation=rollback
        start_service_set >/dev/null 2>&1 || true
      fi
      exit "$status"
    }
    trap rollback_upgrade EXIT
    trap 'exit 1' HUP INT TERM
    write_upgrade_record state-migrating
    migrate_legacy_state "$installed_uid" "$installed_gid"
    write_upgrade_record payload-replacing
    install -o root -g root -m 0755 "$prepared_stage/usbip-linux-client" "$client_path"
    install -o root -g root -m 0755 "$prepared_stage/usbip-linux-vhci-helper" "$helper_path"
    install -o root -g root -m 0755 "$prepared_stage/usbip-linux-authority" "$authority_tool_path"
    install -o root -g root -m 0755 "$prepared_stage/usbip-linux-pairing" "$pairing_tool_path"
    install -o root -g root -m 0755 "$prepared_stage/usbip-linux-client-source-helper" "$source_helper_path"
    install -o root -g root -m 0755 "$prepared_stage/usbip-linux-client-source-provision" "$source_provision_path"
    install -o root -g root -m 0755 "$prepared_stage/usbip-linux-master-usb-worker" "$source_worker_path"
    install -o root -g root -m 0644 "$prepared_stage/usbip-linux-client-vhci.service" "$service_path"
    install -o root -g root -m 0644 "$prepared_stage/usbip-linux-client.service" "$agent_service_path"
    install -o root -g root -m 0644 "$prepared_stage/usbip-linux-client-source-helper.service" "$source_service_path"
    if [ "$source_helper_recorded" -eq 1 ]; then
      "$source_provision_path" --refresh --client-uid "$installed_uid" --client-gid "$installed_gid"
    else
      "$source_provision_path" --client-uid "$installed_uid" --client-gid "$installed_gid"
    fi
    source_helper_recorded=1
    write_install_record "$install_record" "$installed_target" "$installed_user" "$installed_uid" "$installed_gid" "$helper_gid" "$group_created" "$membership_added" "$usbip_core_was_loaded" "$vhci_hcd_was_loaded" "$usbip_copy_created" "$(printf '%s' "$owned_packages" | tr ' ' ',')" "$(printf '%s' "$owned_package_versions" | tr ' ' ',')"
    write_upgrade_record payload-replaced
    verify_regular "$service_path" "$(metadata_value service_sha256)" 644 0 0 || exit 1
    verify_regular "$agent_service_path" "$(sha256sum "$prepared_stage/usbip-linux-client.service" | awk '{print $1}')" 644 0 0 || exit 1
    write_upgrade_record daemon-reloading
    systemctl daemon-reload
    lifecycle_operation=upgrade
    start_service_set
    write_upgrade_record committing
    clear_upgrade_transaction
    upgrade_complete=1
    trap - EXIT HUP INT TERM
    echo "LINUX_CLIENT_PRODUCT_UPGRADED"
    ;;
  --recover-upgrade)
    [ "$#" -eq 2 ] && [ "$2" = "$ack" ] || usage
    [ "$(id -u)" -eq 0 ] || { echo "Recovery requires root." >&2; exit 1; }
    [ -f "$upgrade_record" ] && [ ! -L "$upgrade_record" ] || { echo "No exact recoverable upgrade journal." >&2; exit 1; }
    [ "$(stat -c '%a:%u:%g' "$upgrade_record")" = 600:0:0 ] || exit 1
    [ "$(wc -l < "$upgrade_record")" -eq 2 ] && [ "$(sed -n '1p' "$upgrade_record")" = USBIP_LINUX_CLIENT_UPGRADE_V1 ] || exit 1
    upgrade_stage=$(sed -n '2s/^stage=//p' "$upgrade_record")
    case "$upgrade_stage" in
      stage-creating|staged|agent-draining|agent-stopping|source-helper-stopping|helper-stopping|stopped|backup-creating|backup-complete|state-migrating|payload-replacing|payload-replaced|daemon-reloading|helper-starting|source-helper-starting|agent-starting|agent-health-checking|committing|rollback-*) ;;
      *) exit 1 ;;
    esac
    case "$upgrade_stage" in
      stage-creating|staged|agent-draining|agent-stopping|source-helper-stopping|helper-stopping|stopped|backup-creating)
        load_install_record
        validate_partial_upgrade_backup || { echo "Partial upgrade backup changed; recovery refused." >&2; exit 1; }
        lifecycle_operation=rollback
        start_service_set
        clear_upgrade_transaction
        ;;
      *)
        if [ -d "$upgrade_backup" ]; then
          validate_client_upgrade_backup
          write_upgrade_record rollback-agent-stopping
          systemctl stop usbip-linux-client.service >/dev/null 2>&1 || true
          write_upgrade_record rollback-helper-stopping
          systemctl stop usbip-linux-client-vhci.service >/dev/null 2>&1 || true
          systemctl stop usbip-linux-client-source-helper.service >/dev/null 2>&1 || true
          write_upgrade_record rollback-payload-restoring
          restore_client_upgrade_backup
          write_upgrade_record rollback-daemon-reloading
          systemctl daemon-reload
          load_install_record
          installed_state_root=$(sed -n 's/^state_root=//p' "$upgrade_backup/OWNERSHIP.v1")
          lifecycle_operation=rollback
          if [ "$installed_state_root" = "$legacy_state_root" ]; then
            # The legacy binary cannot run the new persistent agent unit; the
            # helper is still restored and verified in the correct order.
            systemctl start usbip-linux-client-vhci.service
            wait_helper_ready
          else
            start_service_set
          fi
        else
          verify_installed
          lifecycle_operation=rollback
          start_service_set
        fi
        clear_upgrade_transaction
        ;;
    esac
    echo "LINUX_CLIENT_PRODUCT_UPGRADE_RECOVERED"
    ;;
  --remove)
    [ "$#" -eq 2 ] && [ "$2" = "$ack" ] || usage
    [ "$(id -u)" -eq 0 ] || { echo "Removal requires root." >&2; exit 1; }
    for command in cp find getent id readlink sha256sum sort stat systemctl; do require_command "$command"; done
    verify_installed
    [ "$agent_service_recorded" -eq 1 ] || { echo "Upgrade the legacy Client service set before removal." >&2; exit 1; }
    package_database_healthy || { echo "Package manager requires repair or cannot prove database integrity before removal." >&2; exit 1; }
    write_remove_record intent
    lifecycle_operation=remove
    stop_and_quiesce || { lifecycle_operation=remove; start_service_set >/dev/null 2>&1 || true; echo "Service set could not be quiesced; removal refused and restart requested." >&2; exit 1; }
    write_remove_record stopped
    write_remove_record services-disabling
    systemctl disable usbip-linux-client.service usbip-linux-client-source-helper.service usbip-linux-client-vhci.service || { lifecycle_operation=remove; start_service_set >/dev/null 2>&1 || true; exit 1; }
    write_remove_record backup-creating
    mkdir -m 0700 "$remove_backup"
    cp -p -- "$install_record" "$remove_backup/install.v1"
    cp -p -- "$client_path" "$helper_path" "$authority_tool_path" "$pairing_tool_path" \
      "$source_helper_path" "$source_provision_path" "$source_worker_path" \
      "$service_path" "$agent_service_path" "$source_service_path" "$authority_path" \
      "$source_peer_policy" "$source_public_key" "$source_digest" "$source_signing_key" \
      "$modules_path" /usr/sbin/usbip "$remove_backup/"
    for backup_file in "$remove_backup"/*; do sync -f "$backup_file"; done
    sync -f "$remove_backup"
    validate_remove_backup
    write_remove_record backup-complete
    remove_complete=0
    removal_interrupted() {
      status=$?
      trap - EXIT HUP INT TERM
      if [ "$remove_complete" -eq 0 ]; then
        echo "Removal stopped with a protected recovery journal; run --recover-remove $ack." >&2
      fi
      exit "$status"
    }
    trap removal_interrupted EXIT
    trap 'exit 1' HUP INT TERM
    [ -z "$owned_packages" ] && [ -z "$owned_package_versions" ] || { echo "Product installs never own packages." >&2; exit 1; }
    write_remove_record deleting
    rm -f -- "$entry_path" "$service_path" "$agent_service_path" "$source_service_path" \
      "$client_path" "$helper_path" "$authority_tool_path" "$pairing_tool_path" \
      "$source_helper_path" "$source_provision_path" "$source_worker_path" \
      "$source_peer_policy" "$source_public_key" "$source_digest" "$source_signing_key"
    remove_vhci_tmpfiles
    [ "$usbip_copy_created" -ne 1 ] || rm -f -- /usr/sbin/usbip
    write_remove_record daemon-reloading
    systemctl daemon-reload
    write_remove_record committing
    clear_remove_transaction
    remove_complete=1
    trap - EXIT HUP INT TERM
    echo "LINUX_CLIENT_PRODUCT_REMOVED"
    ;;
  --recover-remove)
    [ "$#" -eq 2 ] && [ "$2" = "$ack" ] || usage
    [ "$(id -u)" -eq 0 ] || { echo "Removal recovery requires root." >&2; exit 1; }
    for command in find getent id install ln sha256sum sort stat systemctl systemd-tmpfiles; do require_command "$command"; done
    [ -f "$remove_record" ] && [ ! -L "$remove_record" ] || { echo "No exact recoverable removal journal." >&2; exit 1; }
    [ "$(stat -c '%a:%u:%g' "$remove_record")" = 600:0:0 ] || { echo "Removal journal mode or owner changed." >&2; exit 1; }
    remove_stage=$(sed -n '2s/^stage=//p' "$remove_record")
    [ "$(wc -l < "$remove_record")" -eq 2 ] && [ "$(sed -n '1p' "$remove_record")" = USBIP_LINUX_CLIENT_REMOVE_V1 ] || {
      echo "Removal journal shape changed." >&2
      exit 1
    }
    case "$remove_stage" in intent|agent-draining|agent-stopping|source-helper-stopping|helper-stopping|stopped|services-disabling|backup-creating|backup-complete|deleting|daemon-reloading|committing|rollback-*) ;; *) echo "Removal journal stage changed." >&2; exit 1 ;; esac
    case "$remove_stage" in
      intent|agent-draining|agent-stopping|source-helper-stopping|helper-stopping|stopped|services-disabling|backup-creating)
        load_install_record
        validate_partial_remove_backup || { echo "Partial removal backup changed; recovery refused." >&2; exit 1; }
        install_vhci_tmpfiles
        systemctl enable usbip-linux-client.service usbip-linux-client-source-helper.service usbip-linux-client-vhci.service
        lifecycle_operation=remove
        start_service_set
        clear_remove_transaction keep-install
        echo "LINUX_CLIENT_PRODUCT_REMOVAL_RECOVERED"
        ;;
      committing)
        rm -f -- "$entry_path" "$service_path" "$agent_service_path" "$source_service_path" \
          "$client_path" "$helper_path" "$authority_tool_path" "$pairing_tool_path" \
          "$source_helper_path" "$source_provision_path" "$source_worker_path" \
          "$source_peer_policy" "$source_public_key" "$source_digest" "$source_signing_key"
        remove_vhci_tmpfiles
        if [ -f "$remove_backup/install.v1" ] && grep -qx 'usbip_copy_created=1' "$remove_backup/install.v1"; then
          rm -f -- /usr/sbin/usbip
        fi
        clear_remove_transaction
        echo "LINUX_CLIENT_PRODUCT_REMOVAL_COMPLETED"
        ;;
      backup-complete|deleting|daemon-reloading|rollback-*)
        validate_remove_backup
        [ "$(getent passwd "$installed_user" | awk -F: '{print $3 ":" $4}')" = "$installed_uid:$installed_gid" ] || {
          echo "Client user identity changed; removal recovery refused." >&2
          exit 1
        }
        [ -z "$owned_packages" ] && [ -z "$owned_package_versions" ] || { echo "Product installs never own packages." >&2; exit 1; }
        if [ "$usbip_copy_created" -eq 1 ] && [ ! -e /usr/sbin/usbip ]; then
          install -o root -g root -m 0755 -- "$remove_backup/usbip" /usr/sbin/usbip
        fi
        verify_regular /usr/sbin/usbip "$(remove_backup_value usbip_sha256)" 755 0 0 || { echo "Pre-existing usbip dependency changed; recovery refused." >&2; exit 1; }
        if getent group usbip >/dev/null; then
          [ "$(getent group usbip | awk -F: '{print $3}')" = "$helper_gid" ] || { echo "usbip group GID changed." >&2; exit 1; }
        else
          [ "$group_created" -eq 1 ] || { echo "Pre-existing usbip group disappeared." >&2; exit 1; }
          echo "Pre-existing usbip group disappeared; recovery refused." >&2
          exit 1
        fi
        if ! id -nG "$installed_user" | tr ' ' '\n' | grep -Fxq usbip; then
          echo "Pre-existing usbip membership disappeared; recovery refused." >&2
          exit 1
        fi
        write_remove_record rollback-payload-restoring
        install -d -o root -g root -m 0755 "$package_root" /etc/usbip-vhci-helper
        install -d -o root -g root -m 0700 "$package_state"
        install -d -o "$installed_uid" -g "$installed_gid" -m 0700 "$state_root" "$state_root/identity" "$state_root/pairing" "$state_root/authority" "$state_root/offers"
        install -o root -g root -m 0755 "$remove_backup/usbip-linux-client" "$client_path"
        install -o root -g root -m 0755 "$remove_backup/usbip-linux-vhci-helper" "$helper_path"
        install -o root -g root -m 0755 "$remove_backup/usbip-linux-authority" "$authority_tool_path"
        install -o root -g root -m 0755 "$remove_backup/usbip-linux-pairing" "$pairing_tool_path"
        install -o root -g root -m 0755 "$remove_backup/usbip-linux-client-source-helper" "$source_helper_path"
        install -o root -g root -m 0755 "$remove_backup/usbip-linux-client-source-provision" "$source_provision_path"
        install -o root -g root -m 0755 "$remove_backup/usbip-linux-master-usb-worker" "$source_worker_path"
        install -o root -g root -m 0644 "$remove_backup/usbip-linux-client-vhci.service" "$service_path"
        install -o root -g root -m 0644 "$remove_backup/usbip-linux-client.service" "$agent_service_path"
        install -o root -g root -m 0644 "$remove_backup/usbip-linux-client-source-helper.service" "$source_service_path"
        install -o root -g root -m 0600 "$remove_backup/client-source-helper-peer.v1" "$source_peer_policy"
        install -o root -g root -m 0644 "$remove_backup/client-source-helper-public-key.ed25519" "$source_public_key"
        install -o root -g root -m 0644 "$remove_backup/client-source-helper-executable.sha256.bin" "$source_digest"
        install -o root -g root -m 0600 "$remove_backup/broker-signing-key.pk8" "$source_signing_key"
        install -o root -g root -m 0640 "$remove_backup/authority.v1" "$authority_path"
        install -o root -g root -m 0644 "$remove_backup/usbip-linux-client.conf" "$modules_path"
        install_vhci_tmpfiles
        install -o root -g root -m 0600 "$remove_backup/install.v1" "$install_record"
        rm -f -- "$entry_path"
        ln -s -- "$client_path" "$entry_path"
        write_remove_record rollback-daemon-reloading
        systemctl daemon-reload
        systemctl enable usbip-linux-client.service usbip-linux-client-source-helper.service usbip-linux-client-vhci.service
        lifecycle_operation=remove
        start_service_set || { echo "Client service set did not become ready during removal recovery." >&2; exit 1; }
        clear_remove_transaction keep-install
        echo "LINUX_CLIENT_PRODUCT_REMOVAL_RECOVERED"
        ;;
    esac
    ;;
  *) usage ;;
esac
