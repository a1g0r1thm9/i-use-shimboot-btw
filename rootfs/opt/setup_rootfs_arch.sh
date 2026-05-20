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

if [ "$arch" == "arm64" ]; then
  pacman-key --init
  pacman-key --populate archlinuxarm
fi

#install base packages
if [ ! "$disable_base_pkgs" ]; then
  pacman -Syu --needed --noconfirm --disable-sandbox cloud-utils zram-generator sudo base-devel bash-completion btop firefox mpv gparted fastfetch git 7zip unrar tree net-tools pacman-contrib

  #set up zram
  #echo "ALGO=lzo" >> /etc/default/zramswap
  #echo "PERCENT=100" >> /etc/default/zramswap

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
