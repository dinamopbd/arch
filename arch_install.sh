#!/usr/bin/env bash

# UEFI + ENCRYPTION

clear  # Cleaning the tty
set -e # The script will stop running if we CTRL + C, or in case of an error
set -u # Treat unset variables as an error when substituting

# Cosmetics (colours for text)
BOLD='\e[1m'
BRED='\e[91m'
BBLUE='\e[34m'
BGREEN='\e[92m'
BYELLOW='\e[93m'
RESET='\e[0m'

# Functions
info_print() {
  echo -e "${BOLD}${BGREEN}[ ${BYELLOW}•${BGREEN} ] $1${RESET}"
}

input_print() {
  echo -ne "${BOLD}${BYELLOW}[ ${BGREEN}•${BYELLOW} ] $1${RESET}"
}

error_print() {
  echo -e "${BOLD}${BRED}[ ${BBLUE}•${BRED} ] $1${RESET}"
}

hostname_selector() {
  input_print "Enter the hostname: "
  read -r HOSTNAME
  if [[ -z "$HOSTNAME" ]]; then
    error_print "You need to enter a hostname in order to continue"
    return 1
  fi
  return 0
}

userpass_selector() {
  input_print "Enter the non-root account username (enter empty to not create one): "
  read -r USERNAME
  if [[ -z "$USERNAME" ]]; then
    return 0
  fi
  input_print "Enter a password for $USERNAME: "
  read -r -s USERPASS
  if [[ -z "$USERPASS" ]]; then
    echo
    error_print "You need to enter a password for $USERNAME, please try again"
    return 1
  fi
  echo
  input_print "Enter the password again: "
  read -r -s USERPASS2
  echo
  if [[ "$USERPASS" != "$USERPASS2" ]]; then
    echo
    error_print "Passwords don't match, please try again"
    return 1
  fi
  return 0
}

rootpass_selector() {
  input_print "Enter a password for the root user: "
  read -r -s ROOTPASS
  if [[ -z "$ROOTPASS" ]]; then
    echo
    error_print "You need to enter a password for the root user, please try again"
    return 1
  fi
  echo
  input_print "Enter the password again: "
  read -r -s ROOTPASS2
  echo
  if [[ "$ROOTPASS" != "$ROOTPASS2" ]]; then
    error_print "Passwords don't match, please try again"
    return 1
  fi
  return 0
}

lukspass_selector() {
  input_print "Enter a password for the LUKS container: "
  read -r -s LUKSPASS
  if [[ -z "$LUKSPASS" ]]; then
    echo
    error_print "You need to enter a password for the LUKS Container, please try again"
    return 1
  fi
  echo
  input_print "Enter the password for the LUKS container again: "
  read -r -s LUKSPASS2
  echo
  if [[ "$LUKSPASS" != "$LUKSPASS2" ]]; then
    error_print "Passwords don't match, please try again"
    return 1
  fi
  return 0
}

echo -ne "${BOLD}${BYELLOW}
 █████╗ ██████╗  ██████╗██╗  ██╗    ██╗███╗   ██╗███████╗████████╗ █████╗ ██╗     ██╗
██╔══██╗██╔══██╗██╔════╝██║  ██║    ██║████╗  ██║██╔════╝╚══██╔══╝██╔══██╗██║     ██║
███████║██████╔╝██║     ███████║    ██║██╔██╗ ██║███████╗   ██║   ███████║██║     ██║
██╔══██║██╔══██╗██║     ██╔══██║    ██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║     ██║
██║  ██║██║  ██║╚██████╗██║  ██║    ██║██║ ╚████║███████║   ██║   ██║  ██║███████╗███████╗
╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝    ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚══════╝
${RESET}"
info_print "The process of installing Arch Linux is starting..."
echo

# Time and date
timedatectl set-ntp true

# Choosing the target drive for the installation
info_print "Available disks for the installation: "
PS3="Please select the number of the corresponding disk (e.g. 1): "
select ENTRY in $(lsblk -dpnoNAME | grep -P "/dev/sd|nvme|vd"); do
  DRIVE="$ENTRY"
  info_print "Arch Linux will be installed on the following disk: $DRIVE"
  break
done

# Setting up LUKS password
until lukspass_selector; do :; done

# Setting up hostname
until hostname_selector; do :; done

# Setting up the user and root passwords
until userpass_selector; do :; done
until rootpass_selector; do :; done

# Warn the user about deletion of old partition scheme
input_print "The drive $DRIVE will be wiped out. Do you want to continue agree [y/N]?: "
read -r DISK_RESPONSE
if ! [[ "${DISK_RESPONSE,,}" =~ ^(yes|y)$ ]]; then
  error_print "Quitting..."
  exit
fi
info_print "Wiping $DRIVE..."
wipefs -af "$DRIVE"
sgdisk -Zo "$DRIVE"

# Creating a new partition scheme.
info_print "Creating the partitions on $DRIVE"
parted -s "$DRIVE" \
  mklabel gpt \
  mkpart ESP fat32 1MiB 513MiB \
  set 1 esp on \
  mkpart CRYPTROOT 513MiB 100%

ESP="/dev/disk/by-partlabel/ESP"
CRYPTROOT="/dev/disk/by-partlabel/CRYPTROOT"

# Informing the Kernel of the changes
info_print "Informing the Kernel about the disk changes..."
partprobe "$DRIVE"

# Creating a LUKS Container for the root partition
info_print "Creating LUKS container for the root partition..."
echo -n "$LUKSPASS" | cryptsetup -y -v luksFormat "$CRYPTROOT" -d -
echo -n "$LUKSPASS" | cryptsetup open "$CRYPTROOT" cryptroot -d -
MAPPER="/dev/mapper/cryptroot"

# Formatting the ESP as FAT32
info_print "Formatting the EFI Partition as FAT32..."
mkfs.vfat -F 32 "$ESP"

# Formatting the LUKS Container as EXT4.
info_print "Formatting the LUKS container as EXT4..."
mkfs.ext4 $MAPPER

# Mount the partitions
info_print "Mounting the partitions..."
mount $MAPPER /mnt
mkdir /mnt/boot
mount $ESP /mnt/boot

# Checking the microcode to install
if lscpu | grep -q 'GenuineIntel'; then
  info_print "An Intel CPU has been detected, the Intel microcode will be installed.."
  MICROCODE="intel-ucode"
else
  info_print "An AMD CPU has been detected, the AMD microcode will be installed.."
  MICROCODE="amd-ucode"
fi

# Install the base system and kernel
info_print "Installing the base system (it may take a while)..."
pacman -Sy archlinux-keyring --noconfirm
pacstrap /mnt \
  base \
  base-devel \
  linux \
  linux-headers \
  linux-firmware \
  networkmanager \
  $MICROCODE \
  sudo \
  efibootmgr \
  grub

# Generating the filesystem table
info_print "Generating a new fstab..."
genfstab -U /mnt >>/mnt/etc/fstab

# Setting up the hostname
info_print "Setting hostname..."
echo "$HOSTNAME" >/mnt/etc/hostname

# Configure selected locale and console keymap
sed -i "s/#en_US/en_US/g" /mnt/etc/locale.gen
echo "LANG=en_US.UTF-8" >/mnt/etc/locale.conf

# Setting hosts file.
info_print "Setting hosts file..."
cat >/mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
EOF

# Setting up the network
info_print "Enabling NetworkManager..."
systemctl enable NetworkManager --root=/mnt

# Configuring /etc/mkinitcpio.conf.
info_print "Configuring /etc/mkinitcpio.conf."
INIT_HOOKS="HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt filesystems fsck)"
sed -i "s|^HOOKS=.*|$INIT_HOOKS|" /mnt/etc/mkinitcpio.conf

# Setting up LUKS2 encryption in grub.
info_print "Setting up grub config."
UUID=$(blkid -s UUID -o value $CRYPTROOT)
#UUID=$(blkid "${PART_ROOT}" | sed -n 's/.* UUID=\"\([^\"]*\)\".*/\1/p')
GRUB_CMD="GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$UUID:cryptroot root=$MAPPER\""
sed -i "s|^GRUB_CMDLINE_LINUX=.*|$GRUB_CMD|" /mnt/etc/default/grub
sed -i "s|^#GRUB_ENABLE_CRYPTODISK=.*|GRUB_ENABLE_CRYPTODISK=y|" /mnt/etc/default/grub

# Configuring the system.
info_print "Configuring the system (timezone, system clock, initramfs, Snapper, GRUB)..."
arch-chroot /mnt /bin/bash -e <<EOF

# Setting up timezone
ln -sf /usr/share/zoneinfo/$(curl -s http://ip-api.com/line?fields=timezone) /etc/localtime

# Setting up clock
hwclock --systohc

# Generating locale
locale-gen

# Generating a new initramfs
mkinitcpio -p linux # for the linux kernel

# Installing GRUB and creating its config file
grub-install --target=x86_64-efi --bootloader-id=GRUB --recheck --efi-directory=/boot
grub-mkconfig -o /boot/grub/grub.cfg

EOF

# Setting root password
info_print "Setting root password..."
echo "root:$ROOTPASS" | arch-chroot /mnt chpasswd

# Setting user password
if [[ -n "$USERNAME" ]]; then
  sed -i "s/#%wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/g" /mnt/etc/sudoers
  info_print "Adding the user $USERNAME to the system with root privilege..."
  arch-chroot /mnt useradd -m -G wheel "$USERNAME"
  info_print "Setting user password for $USERNAME."
  echo "$USERNAME:$USERPASS" | arch-chroot /mnt chpasswd
fi

# Finishing up
info_print "Done!"
exit
input_print "Do you want tyo reboot now? (y/n): "
read -r REBOOT
echo
if [[ $REBOOT =~ ^[Yy]$ ]]; then reboot; fi
