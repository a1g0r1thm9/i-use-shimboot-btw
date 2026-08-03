#!/bin/bash

#setup the arch rootfs
#this is meant to be run within the chroot created by pacstrap

DEBUG="$1"
set -e
if [ "$DEBUG" ]; then
  set -x
fi

trap "echo 'FAILED at line $LINENO: $BASH_COMMAND'" ERR

release_name="$2"
packages="$3"

hostname="$4"
root_passwd="$5"
username="$6"
user_passwd="$7"
enable_root="$8"
disable_base_pkgs="$9"
arch="${10}"

#enable shimboot services
systemctl enable kill-frecon.service
if ! grep -q '^DisableSandbox' /etc/pacman.conf; then
  sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
fi
pacman-key --init
if [ "$arch" == "arm64" ]; then
  echo 'Server = http://mirror.archlinuxarm.org/$arch/$repo' > /etc/pacman.d/mirrorlist
  pacman-key --populate archlinuxarm
else
  echo 'Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch' > /etc/pacman.d/mirrorlist
  pacman-key --populate archlinux
fi
if [ ! "$disable_base_pkgs" ]; then
  pacman -Syu --needed --noconfirm --disable-sandbox meson ninja cloud-utils zram-generator sudo base-devel bash-completion btop firefox mpv gparted fastfetch git 7zip unrar tree net-tools pacman-contrib

  systemd_pkg_dir=/opt/systemd-cros/systemd-pkg
  rm -rf "$systemd_pkg_dir"

  if [ "$arch" == "arm64" ]; then
    git clone --filter=blob:none --no-checkout --depth 1 \
      https://github.com/archlinuxarm/PKGBUILDs.git "$systemd_pkg_dir"
    (
      cd "$systemd_pkg_dir"
      git sparse-checkout init --cone
      git sparse-checkout set core/systemd
      git checkout master
    )
    pkgbuild_dir="$systemd_pkg_dir/core/systemd"
  else
    git clone --depth 1 --branch main \
      https://gitlab.archlinux.org/archlinux/packaging/packages/systemd.git \
      "$systemd_pkg_dir"
    pkgbuild_dir="$systemd_pkg_dir"
  fi

  if grep -qE '^prepare[[:space:]]*\(\)[[:space:]]*\{' "$pkgbuild_dir/PKGBUILD"; then
    sed -i -E 's/^prepare[[:space:]]*\(\)[[:space:]]*\{/_orig_prepare() {/' \
      "$pkgbuild_dir/PKGBUILD"
  else
    echo '_orig_prepare() { :; }' >> "$pkgbuild_dir/PKGBUILD"
  fi

  cat >> "$pkgbuild_dir/PKGBUILD" <<'PKGEOF'

prepare() {
  _orig_prepare
  local mp src_root
  mp="$(find "$srcdir" -type f -path '*/src/basic/mountpoint-util.c' | head -n1)"
  if [ -z "$mp" ]; then
    echo "shimboot: could not locate mountpoint-util.c under \$srcdir" >&2
    exit 1
  fi
  src_root="$(dirname "$(dirname "$(dirname "$mp")")")"
  patch -d "$src_root" -Np1 < /opt/systemd-cros/shimboot.patch
}
PKGEOF

  useradd -m builder 2>/dev/null || true
  chown -R builder:builder /opt/systemd-cros
  makedepends_list="$(bash -c "source '$pkgbuild_dir/PKGBUILD'; printf '%s\n' \"\${makedepends[@]}\"")"
  if [ -n "$makedepends_list" ]; then
    # shellcheck disable=SC2086
    pacman -S --needed --noconfirm $makedepends_list
  fi

  cd "$pkgbuild_dir"
  sudo -u builder makepkg -s --noconfirm --skippgpcheck --ignorearch
  pacman -U --noconfirm "$pkgbuild_dir"/systemd-*.pkg.tar.zst
fi

#set up hostname and username
if [ ! "$hostname" ]; then
  read -p "Enter the hostname for the system: " hostname
fi
echo "${hostname}" > /etc/hostname
tee -a /etc/hosts << END
127.0.0.1 localhost
127.0.1.1 ${hostname}

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
END


#disable selinux to prevent a harmless error from showing up during the boot
#i dont think this is needed on arch?
#echo "SELINUX=disabled" >> /etc/selinux/config

if [ ! "$username" ]; then
  read -p "Enter the username for the user account: " username
fi
useradd -m -s /bin/bash -G wheel "$username"

set_password() {
  local user="$1"
  local password="$2"
  if [ ! "$password" ]; then
    while ! passwd "$user"; do
      echo "Failed to set password for $user, please try again."
    done
  else
    yes "$password" | passwd "$user"
  fi
}

if [ "$enable_root" ]; then 
  echo "Enter a root password:"
  set_password root "$root_passwd"
else
  usermod -a -G wheel "$username"
  #best way to disable root lmao
  set_password root "$(openssl rand -hex 20)"
fi

echo "Enter a user password:"
set_password "$username" "$user_passwd"

#clean pacman cache
pacman -Scc --noconfirm <<< "y
y"
#enable bash greeter
echo "/usr/local/bin/shimboot_greeter" >> "/home/$username/.bashrc" 
exit 0
