#!/bin/bash

#build the rootfs

. ./common.sh

print_help() {
  echo "Usage: ./build_rootfs.sh rootfs_path release_name"
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  custom_packages - The packages that will be installed in place of task-xfce-desktop."
  echo "  hostname        - The hostname for the new rootfs."
  echo "  enable_root     - Enable the root user."
  echo "  root_passwd     - The root password. This only has an effect if enable_root is set."
  echo "  username        - The unprivileged user name for the new rootfs."
  echo "  user_passwd     - The password for the unprivileged user."
  echo "  disable_base    - Disable the base packages such as zram, cloud-utils, and command-not-found."
  echo "  arch            - The CPU architecture to build the rootfs for."
  echo "  distro          - The Linux distro to use. This should be either 'debian', 'arch' or 'alpine'."
  echo "If you do not specify the hostname and credentials, you will be prompted for them later."
}

assert_root
assert_args "$2"
parse_args "$@"

rootfs_dir=$(realpath -m "${1}")
release_name="${2}"
arch="${args['arch']-amd64}"
distro="${args['distro']-debian}"
indicator_file="$rootfs_dir/etc/shimboot-root-clean"

if [ -f "$indicator_file" ]; then
  print_info "rootfs appears to be already built"
  exit 0
else
  rm -fr "$rootfs_dir"
  mkdir -p "$rootfs_dir"
fi

if [ "$distro" == "arch" ]; then
  packages="${args['custom_packages']-xfce4}"
  assert_deps "realpath pacstrap findmnt wget pcregrep bsdtar"
else
  packages="${args['custom_packages']-task-xfce-desktop}"
  assert_deps "realpath debootstrap findmnt wget pcregrep tar"
fi

if [ "$distro" = "debian" ]; then
  print_info "bootstrapping debian chroot"
  debootstrap --arch $arch --components=main,contrib,non-free,non-free-firmware "$release_name" "$rootfs_dir" http://deb.debian.org/debian/
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "ubuntu" ]; then
  print_info "bootstrapping ubuntu chroot"
  repo_url="http://archive.ubuntu.com/ubuntu"
  if [ "$arch" = "amd64" ]; then
    repo_url="http://archive.ubuntu.com/ubuntu"
  else
    repo_url="http://ports.ubuntu.com"
  fi
  debootstrap --arch $arch "$release_name" "$rootfs_dir" "$repo_url"
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "alpine" ]; then
  print_info "downloading alpine package list"
  pkg_list_url="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/"
  pkg_data="$(wget -qO- --show-progress "$pkg_list_url" | grep "apk-tools-static")"
  pkg_url="$pkg_list_url$(echo "$pkg_data" | pcregrep -o1 '"(.+?.apk)"')"

  print_info "downloading and extracting apk-tools-static"
  pkg_extract_dir="/tmp/apk-tools-static"
  pkg_dl_path="$pkg_extract_dir/pkg.apk"
  apk_static="$pkg_extract_dir/sbin/apk.static"
  mkdir -p "$pkg_extract_dir"
  wget -q --show-progress "$pkg_url" -O "$pkg_dl_path"
  tar --warning=no-unknown-keyword -xzf "$pkg_dl_path" -C "$pkg_extract_dir"

  print_info "bootstrapping alpine chroot"
  real_arch="x86_64"
  if [ "$arch" = "arm64" ]; then
    real_arch="aarch64"
  fi
  $apk_static \
    --arch $real_arch \
    -X http://dl-cdn.alpinelinux.org/alpine/$release_name/main/ \
    -U --allow-untrusted \
    --root "$rootfs_dir" \
    --initdb add alpine-base
  chroot_script="/opt/setup_rootfs_alpine.sh"
elif [ "$distro" = "arch" ]; then
  if [ "$arch" == "x86_64" -o "amd64" ]; then
    arch_mirror="https://mirror.rackspace.com/archlinux"
    tarfile="$(realpath .)/rootfs-x86_64.tar.gz"
    if [ ! -f "$tarfile" ]; then
      latest_tarball="$(wget -qO- "$arch_mirror/iso/latest/" | grep -oE 'archlinux-bootstrap-[0-9.]+-x86_64\.tar\.zst' | head -n1)"
      wget -q --show-progress "$arch_mirror/iso/latest/$latest_tarball" -O "$tarfile"
    fi
    mkdir -p "$rootfs_dir/etc/pacman.d/"
    echo 'Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch' > "$rootfs_dir/etc/pacman.d/mirrorlist"
  else
    alarm_mirror="http://ca.us.mirror.archlinuxarm.org"
    tarfile="$(realpath .)/rootfs.tar.gz"
    if [ ! -f "$tarfile" ]; then
      latest_tarball="$(wget -qO- "$alarm_mirror/os/" | grep -oE 'ArchLinuxARM-aarch64-latest\.tar\.gz' | head -n1)"
      wget -q --show-progress "$alarm_mirror/os/$latest_tarball" -O "$tarfile"
    fi
  fi
  #alarm image has file attributes that dont play nice with gnu tar
  bsdtar -xpf "$tarfile" --numeric-owner -C "$rootfs_dir" --strip-components=1

  chown root:root "$rootfs_dir/etc"
  rm -f "$rootfs_dir/etc/resolv.conf"
  touch "$rootfs_dir/etc/resolv.conf"
  chroot_script="/opt/setup_rootfs_arch.sh"

else
  print_error "'$distro' is an invalid distro choice."
  exit 1
fi

print_info "copying rootfs setup scripts"
cp -arv rootfs/* "$rootfs_dir"


hostname="${args['hostname']}"
root_passwd="${args['root_passwd']}"
enable_root="${args['enable_root']}"
username="${args['username']}"
user_passwd="${args['user_passwd']}"
disable_base="${args['disable_base']}"

chroot_command="$chroot_script \
  '$DEBUG' '$release_name' '$packages' \
  '$hostname' '$root_passwd' '$username' \
  '$user_passwd' '$enable_root' '$disable_base' \
  '$arch'"

#share pacman cache w/ build host
mkdir -p "/var/cache/pacman/pkg"

#youtube.com/watch?v=02kGt4DEW30&t=30s
systemd-nspawn -D "$rootfs_dir" --console=pipe \
  --bind=/var/cache/pacman/pkg \
  /bin/bash -c "${chroot_command}"

echo clean > "$indicator_file"
print_info "rootfs has been created"
