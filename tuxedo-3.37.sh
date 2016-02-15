#!/bin/bash
#
# Author: Tuxedo Computers GmbH <tux@tuxedocomputers.com>

APT_CACHE_HOSTS="192.168.178.107 192.168.23.231"
APT_CACHE_PORT=3142
# additional packages that should be installed
PACKAGES="cheese pavucontrol gparted pidgin vim"


error=0
trap 'error=$(($? > $error ? $? : $error))' ERR
set errtrace

lsb_dist_id="$(lsb_release -si)"   # e.g. 'Ubuntu', 'LinuxMint', 'openSUSE project'
lsb_release="$(lsb_release -sr)"   # e.g. '13.04', '15', '12.3'
lsb_codename="$(lsb_release -sc)"  # e.g. 'raring', 'olivia', 'Dartmouth'
product="$(sed -e 's/^\s*//g' -e 's/\s*$//g' "/sys/devices/virtual/dmi/id/product_name" | tr ' ,/-' '_')" # e.g. 'U931'

cd $(dirname $0)

if [ "$(id -u)" -ne 0 ]; then
	echo "You aren't 'root', but '$(whoami)'. Aren't you?!"
	exec sudo su -c "bash '$(basename $0)'"
fi

exec 3>&1 &>tuxedo.log

if hash xterm 2>/dev/null; then
exec xterm -geometry 150x50 -e tail -f tuxedo.log &
fi

echo $(basename $0)
lsb_release -a

apt_opts='-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew --fix-missing'
zypper_opts='-n'

case "$lsb_dist_id" in
	Ubuntu|LinuxMint|elementary*)
		install_cmd="apt-get $apt_opts install"
		upgrade_cmd="apt-get $apt_opts dist-upgrade"
		refresh_cmd="apt-get $apt_opts update"
		clean_cmd="apt-get -y clean"		
		;;
	openSUSE*|SUSE*)
		install_cmd="zypper $zypper_opts install -l"
		upgrade_cmd="zypper $zypper_opts update -l"
		refresh_cmd="zypper $zypper_opts refresh"
		clean_cmd="zypper $zypper_opts clean --all"
		;;
	*)
		echo "Unknown Distribution: '$lsb_dist_id'"
		;;
esac

is_oem() {
	id oem && [ $(id -u oem) -eq 29999 ]
} >/dev/null 2>&1

has_nvidia_gpu() {
	# 10de ... NVIDIA Corporation
	# 0300 ... VGA compatible controller
	# 0302 ... 3D controller
	lspci -nd 10de: | grep -q '030[02]:'
}

has_skylake_cpu() {
	lspci -nd 8086: | grep -q '19[01][048cf]'
}

has_fingerprint_reader() {
	[ -x "$(which lsusb)" ] || $install_cmd usbutils
	# 0483 ... UPEK
	# 147e ... UPEK (?), Matsushita Graphic Communication Systems, Inc.
	lsusb -d 0483: || lsusb -d 147e: || lsusb -d 12d1: || lsusb -d 1c7a:0603
}

has_threeg() {
	[ -x "$(which lsusb)" ] || $install_cmd usbutils
	lsusb -d 12d1:1404
}

add_apt_repository() {
		add-apt-repository -y $1
}


pkg_is_installed() {
	case "$lsb_dist_id" in
		Ubuntu|LinuxMint)
			[ "$(dpkg-query -W -f='${Status}' $1 2>/dev/null)" = "install ok installed" ]
			;;
		openSUSE*|SUSE*)
			rpm -q $1 >/dev/null
			;;
	esac
}


task_grub() {
	case "$lsb_dist_id" in
		Ubuntu|LinuxMint|elementary*)
			local default_grub=/etc/default/grub
			if [ ! $product == "U931" ]; then
			if ! grep -q 'acpi_os_name=Linux acpi_osi= acpi_backlight=vendor' "$default_grub"; then
			sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/"\(.*\)"/"\1 acpi_os_name=Linux acpi_osi= acpi_backlight=vendor"/' $default_grub
			fi
			fi
			if has_nvidia_gpu; then
				sed -i '/^GRUB_CMDLINE_LINUX=/ s/nomodeset//' $default_grub
			fi
			update-grub
			;;
		openSUSE*|SUSE*)
			local default_grub=/etc/default/grub
                        if ! grep -q 'acpi_os_name=Linux acpi_osi= acpi_backlight=vendor' "$default_grub"; then
                        sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/"\(.*\)"/"\1 acpi_os_name=Linux acpi_osi= acpi_backlight=vendor"/' $default_grub
                        fi
			grub2-mkconfig -o /boot/grub2/grub.cfg
			;;
	esac
}
task_grub_test() {
	true
}

task_saucy_kernel() {

	if ! apt-get $apt_opts --no-install-recommends install linux-generic-lts-saucy; then
		apt_sources_list=/etc/apt/sources.list.d/saucy.list
		cat <<-__EOF__ >"$apt_sources_list"
			deb http://archive.ubuntu.com/ubuntu/ saucy main
			deb http://security.ubuntu.com/ubuntu/ saucy-security main
			deb http://archive.ubuntu.com/ubuntu/ saucy-updates main
		__EOF__

		$refresh_cmd
		apt-get $apt_opts --no-install-recommends -o "APT::Default-Release=$lsb_codename" -t saucy \
			install linux-firmware libnl-route-3-200 libnl-genl-3-200

		rm -f $apt_sources_list
		$refresh_cmd
	fi
}
task_saucy_kernel_test() {
	pkg_is_installed linux-generic-lts-saucy || dpkg --compare-versions "$(dpkg-query -W -f='${Version}' linux-image-generic 2>/dev/null)" ge 3.11
}

task_nvidia() {

	case "$lsb_dist_id" in
		Ubuntu|LinuxMint)
			if [ $lsb_release == "14.04" ]; then
				if has_skylake_cpu; then
				$install_cmd nvidia-352 mesa-utils
				else
				$install_cmd bumblebee bumblebee-nvidia nvidia-349 primus mesa-utils
				fi
                        elif [ $lsb_release == "15.04" ]; then
                                $install_cmd bumblebee bumblebee-nvidia nvidia-349 mesa-utils
				sed -i -e '/^Driver=/ s/=.*$/=nvidia/' "/etc/bumblebee/bumblebee.conf"
			        sed -i -e '/^KernelDriver=/ s/nvidia-current/nvidia-349/' "/etc/bumblebee/bumblebee.conf"
			        sed -i -e '/^LibraryPath=/ s/nvidia-current/nvidia-349/g' "/etc/bumblebee/bumblebee.conf"
			        sed -i -e '/^XorgModulePath=/ s/nvidia-current/nvidia-349/' "/etc/bumblebee/bumblebee.conf"
			elif [ $lsb_release == "15.10" ]; then
				$install_cmd nvidia-352 mesa-utils
			elif [ $lsb_release == "17.2" ]; then
                                if ! has_skylake_cpu; then
                                $install_cmd bumblebee bumblebee-nvidia nvidia-349 primus mesa-utils
                                fi
			elif [ $lsb_release == "17.3" ]; then
                                if ! has_skylake_cpu; then
                                $install_cmd bumblebee bumblebee-nvidia nvidia-349 primus mesa-utils
                                fi
			else	
			$install_cmd bumblebee bumblebee-nvidia nvidia-349 primus mesa-utils
			fi
			if ! has_skylake_cpu; then
			[ "$lsb_dist_id" = "LinuxMint" ] && sed -i     \
				-e '/^start on/ s/(.*)/(runlevel [2345])/' \
				-e '/^stop on/ s/(.*)/(runlevel [016])/'   \
				/etc/init/bumblebeed.conf

			local adduser_conf=$target/etc/adduser.conf

			if is_oem && [ -w "$adduser_conf" ]; then
				if grep -q '^EXTRA_GROUPS=' "$adduser_conf"; then
					sed -i -e 's/^EXTRA_GROUPS="\(.*\)"/EXTRA_GROUPS="\1 bumblebee"/' \
						   -e 's/^ADD_EXTRA_GROUPS=.*/ADD_EXTRA_GROUPS=1/' "$adduser_conf"
				else
					cat <<-__EOF__ >>"$adduser_conf"
						EXTRA_GROUPS="bumblebee"
						ADD_EXTRA_GROUPS=1
					__EOF__
				fi
			fi
			fi
			;;
		openSUSE*)
			local uid=1000
			local user_name=$(getent passwd | awk -v uid=$uid 'BEGIN { FS=":" } { if ($3 == uid) print $1 }')
			$install_cmd nvidia-bumblebee-32bit nvidia-bumblebee primus dkms-bbswitch
			echo "blacklist nouveau" >>/etc/modprobe.d/50-blacklist.conf
			usermod -a -G video,bumblebee "$user_name"
			systemctl enable bumblebeed
			case "$lsb_release" in
			13.2) mkinitrd;;
			*) echo "nichts" >/dev/null;;
			esac
			;;
		SUSE*)
			echo "nichts" >/dev/null
			;;
	esac
}
task_nvidia_test() {
	case "$lsb_dist_id" in
		Ubuntu|LinuxMint)


			if [ $lsb_release == "17.2" ]; then
                                if has_skylake_cpu; then
				true
                                fi
			elif [ $lsb_release == "17.3" ]; then
                                if has_skylake_cpu; then
                                true
                                fi
			else
			pkg_is_installed nvidia-349 || pkg_is_installed nvidia-352
			#if [ $lsb_release == "15.04" ]; then
                        #pkg_is_installed nvidia-349
			#elif [ $lsb_release == "15.10" ]; then
			#pkg_is_installed nvidia-352
                        #else
			#pkg_is_installed nvidia-349
			fi
			;;
		openSUSE*)
			pkg_is_installed nvidia-bumblebee && pkg_is_installed primus && pkg_is_installed dkms-bbswitch
			;;
		SUSE*)
			echo "nichts" >/dev/null
                        ;;
	esac
}

task_fingerprint() {

	case "$lsb_dist_id" in
		Ubuntu|LinuxMint|elementary*)
			if [ $lsb_release == "14.04" ]; then
                        $install_cmd libfprint0 libpam-fprintd fprint-demo gksu-polkit
                        else
			$install_cmd libfprint0 libpam-fprintd fprint-demo
			fi
			;;
		openSUSE*)
			$install_cmd libfprint0 pam_fprint
			;;
		SUSE*)
                        $install_cmd libfprint0 fprintd fprintd-lang fprintd-pam
                        ;;
	esac
}
task_fingerprint_test() {
        case "$lsb_dist_id" in
                Ubuntu|LinuxMint|elementary*)
                        pkg_is_installed fprint-demo && pkg_is_installed libfprint0
                        ;;
                SUSE*)
                        pkg_is_installed libfprint0
                        ;;
        esac
}

task_tuxedo_wmi() {

	case "$lsb_dist_id" in
		Ubuntu|LinuxMint|elementary*)
			if [ ! $product == "U931" ]; then
			$install_cmd tuxedo-wmi-dkms
			fi
			;;
		openSUSE*)
			$install_cmd tuxedo-wmi
			systemctl enable dkms
			;;
		SUSE*)
                        $install_cmd tuxedo-wmi
                        systemctl enable dkms
                        ;;
	esac

	local rfkill=
	has_threeg && rfkill=" rfkill" || rfkill=
	cat <<-__EOF__ >/etc/modprobe.d/tuxedo_wmi.conf
		options tuxedo-wmi kb_color=white kb_brightness=10 led_invert$rfkill
	__EOF__
}
task_tuxedo_wmi_test() {
	pkg_is_installed tuxedo-wmi-dkms || pkg_is_installed tuxedo-wmi
}

task_wallpaper() {
	$install_cmd tuxedo-wallpapers

	if   pkg_is_installed ubuntu-desktop; then
		cat <<-__EOF__ >/usr/share/glib-2.0/schemas/30_tuxedo-settings.gschema.override
[org.gnome.desktop.background]
picture-uri='file:///usr/share/tuxedo-wallpapers/tuxedo-background_10.jpg'
		__EOF__
		glib-compile-schemas /usr/share/glib-2.0/schemas
	elif pkg_is_installed elementary-desktop; then
		cat <<-__EOF__ >/usr/share/glib-2.0/schemas/30_tuxedo-settings.gschema.override
[org.gnome.desktop.background]
picture-uri='file:///usr/share/tuxedo-wallpapers/tuxedo-background_10.jpg'
		__EOF__
		glib-compile-schemas /usr/share/glib-2.0/schemas
	elif pkg_is_installed kubuntu-desktop || pkg_is_installed patterns-openSUSE-kde4; then
		cat <<-__EOF__ >/usr/share/kde4/apps/plasma-desktop/init/80-tuxedo.js
a = activities()

for (i in a) {
	a[i].wallpaperPlugin    = 'image'
	a[i].wallpaperMode      = 'SingleImage'
	a[i].currentConfigGroup = Array('Wallpaper', 'image')
	a[i].writeConfig('wallpaper', '/usr/share/wallpapers/Tuxedo_10/contents/images/1920x1080.jpg')
	a[i].writeConfig('wallpaperposition', '0')
}
		__EOF__
	elif pkg_is_installed lubuntu-desktop; then
		WALLPAPER="/usr/share/lubuntu/wallpapers/tuxedo-background_10.jpg"
		sed -i "s#\(^wallpaper=\).*#\1$WALLPAPER#" /usr/share/lubuntu/pcmanfm/main.lubuntu
		sed -i "s#\(^wallpaper=\).*#\1$WALLPAPER#" /etc/xdg/pcmanfm/lubuntu/pcmanfm.conf
	elif pkg_is_installed xubuntu-desktop; then
		cat <<-__EOF__ >/etc/xdg/xdg-xubuntu/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-desktop" version="1.0">
	<property name="desktop-icons" type="empty">
		<property name="style" type="int" value="2"/>
		<property name="file-icons" type="empty">
			<property name="show-home" type="bool" value="true"/>
			<property name="show-filesystem" type="bool" value="true"/>
			<property name="show-removable" type="bool" value="true"/>
			<property name="show-trash" type="bool" value="true"/>
		</property>
	</property>
	<property name="backdrop" type="empty">
		<property name="screen0" type="empty">
			<property name="monitor0" type="empty">
				<property name="image-path" type="string" value="/usr/share/xfce4/backdrops/tuxedo-background_10.jpg"/>
				<property name="image-show" type="bool" value="true"/>
			</property>
			<property name="monitor1" type="empty">
				<property name="image-path" type="string" value="/usr/share/xfce4/backdrops/tuxedo-background_10.jpg"/>
				<property name="image-show" type="bool" value="true"/>
			</property>
		</property>
	</property>
</channel>
		__EOF__
	elif pkg_is_installed mint-info-cinnamon; then
		cat <<-__EOF__ >/usr/share/glib-2.0/schemas/tuxedo-artwork.gschema.override
[org.gnome.desktop.background]
picture-uri='file:///usr/share/tuxedo-wallpapers/tuxedo-background_10.jpg'

[org.cinnamon.desktop.background]
picture-uri='file:///usr/share/tuxedo-wallpapers/tuxedo-background_10.jpg'

[org.cinnamon.theme]
name='Cinnamon'
		__EOF__
		glib-compile-schemas /usr/share/glib-2.0/schemas
	elif pkg_is_installed mint-info-mate; then
		cat <<-__EOF__ >/usr/share/glib-2.0/schemas/tuxedo-artwork.gschema.override
[org.gnome.desktop.background]
picture-uri='file:///usr/share/tuxedo-wallpapers/tuxedo-background_10.jpg'

[org.mate.background]
picture-filename='/usr/share/tuxedo-wallpapers/tuxedo-background_10.jpg'
		__EOF__
		glib-compile-schemas /usr/share/glib-2.0/schemas
	elif pkg_is_installed patterns-openSUSE-gnome; then
		cat <<-__EOF__ >/usr/share/glib-2.0/schemas/tuxedo-artwork.gschema.override
[org.gnome.desktop.background]
picture-uri='file:///usr/share/tuxedo-wallpapers/tuxedo-background_10.jpg'
		__EOF__
	fi
}
task_wallpaper_test() {
	pkg_is_installed tuxedo-wallpapers
}

task_files() {
	local uid=1000
	local user_name="$(getent passwd | awk -v uid=$uid 'BEGIN { FS=":" } { if ($3 == uid) print $1 }')"
	local user_home="$(getent passwd | awk -v uid=$uid 'BEGIN { FS=":" } { if ($3 == uid) print $6 }')"

	if is_oem; then
		user_home=/etc/skel
		install -d $user_home/Desktop $user_home/Downloads
	fi

	for dc in helligkeit.sh.desktop; do
                file2="$user_home/.config/autostart/helligkeit.sh.desktop"
		file1="$user_home/.config/autostart"  
		mkdir $file1 && chown -R $user_name:$(id -ng $user_name) "$file1"
	        cat >"$file2" <<-__EOF__
			[Desktop Entry]
			Type=Application
			Exec=xbacklight -set 100
			Hidden=false
			NoDisplay=false
			X-GNOME-Autostart-enabled=true
			Name[de_DE]=Helligkeit
			Name=Helligkeit
			Comment[de_DE]=Helligkeitseinstellung
			Comment=Helligkeitseinstellung
			__EOF__
                is_oem || chown $user_name:$(id -ng $user_name) "$file2" 
		chmod 0664 "$file2"
        done

}
task_files_test() {
	true
}

task_misc() {

	case "$lsb_dist_id" in
		Ubuntu|LinuxMint)
			local schema="com.canonical.Unity.Lenses"
			local key="disabled-scopes"
			local val="['more_suggestions-amazon.scope', 'more_suggestions-u1ms.scope', 'more_suggestions-populartracks.scope', 'music-musicstore.scope', 'more_suggestions-ebay.scope', 'more_suggestions-ubuntushop.scope', 'more_suggestions-skimlinks.scope']"

			local schema_dir=/usr/share/glib-2.0/schemas

			if is_oem && [ -d "$schema_dir" ]; then

				echo -e "[$schema]\n$key=$val" >>"$schema_dir/30_tuxedo-settings.gschema.override"
				glib-compile-schemas "$schema_dir"
			else
				local uid=1000
				local user_name=$(getent passwd | awk -v uid=$uid 'BEGIN { FS=":" } { if ($3 == uid) print $1 }')

				if [ -x $(which gsettings) ] && su -c"gsettings writable $schema $key" $user_name; then
					su -c"gsettings set $schema $key \"$val\"" $user_name
				fi
				#AH
				if [ -x $(which gsettings) ] && su -c"gsettings writable $schema remote-content-search" $user_name; then
                                        su -c"gsettings set $schema remote-content-search none" $user_name
                                fi

			fi
			;;
	esac

	local file=
	case "$lsb_dist_id" in
		Ubuntu|LinuxMint|elementary*) file=/etc/rc.local ;;
		openSUSE*)        file=/etc/init.d/boot.local ;;
		SUSE*)        file=/etc/init.d/boot.local ;;
	esac

	sed -i '/^#!.*/,1 a\
trigger_src="phy0radio"\
trigger_led="/sys/class/leds/tuxedo\:\:airplane/trigger"\
if which rfkill >/dev/null 2>&1; then\
	if rfkill list | grep -wA2 phy0: | grep -wq "blocked: yes"; then\
        echo 0 >"/sys/class/leds/tuxedo\:\:airplane/brightness"\
	else\
        echo 1 >"/sys/class/leds/tuxedo\:\:airplane/brightness"\
	fi\
fi\
\[ -w "$trigger_led" \] && grep -wq "$trigger_src" "$trigger_led" && echo "$trigger_src" >"$trigger_led"
' "$file"
}
task_misc_test() {
	true
}

task_repository() {

	case "$lsb_dist_id" in
		LinuxMint)
			local ubuntu_release=
			case "$lsb_codename" in
				qiana) ubuntu_release=trusty ;;
				rebecca) ubuntu_release=trusty ;;
				rafaela) ubuntu_release=trusty ;;
				rosa) ubuntu_release=trusty ;;
				*) return 1 ;;
			esac
			cat <<-__EOF__ >"/etc/apt/sources.list.d/tuxedo-computers.list"
deb http://deb.tuxedocomputers.com/ubuntu $ubuntu_release main
deb http://deb.tuxedocomputers.com/linuxmint $lsb_codename main
			__EOF__
			;;
		elementary*)
			local ubuntu_release=
                        case "$lsb_codename" in
				freya) ubuntu_release=trusty ;;
				*) return 1 ;;
                        esac
			if ! [ -f /etc/apt/sources.list.d/tuxedo-computers.list ] ; then
			cat <<-__EOF__ >"/etc/apt/sources.list.d/tuxedo-computers.list"
deb http://deb.tuxedocomputers.com/ubuntu $ubuntu_release main
deb http://intel.tuxedocomputers.com/ubuntu $ubuntu_release main
			__EOF__
                        fi
                        ;;
		Ubuntu)
			if ! [ -f /etc/apt/sources.list.d/tuxedo-computers.list ] ; then
			cat <<-__EOF__ >"/etc/apt/sources.list.d/tuxedo-computers.list"
deb http://deb.tuxedocomputers.com/ubuntu $lsb_codename main
deb http://intel.tuxedocomputers.com/ubuntu $lsb_codename main
deb http://graphics.tuxedocomputers.com/ubuntu $lsb_codename main
			__EOF__
			fi
			;;
		openSUSE*)
			cat <<-__EOF__ >"/etc/zypp/repos.d/repo-tuxedo-computers.repo"
[repo-tuxedo-computers]
name=TUXEDO Computers - openSUSE $lsb_release
baseurl=http://rpm.tuxedocomputers.com/opensuse/$lsb_release
path=/
gpgkey=http://rpm.tuxedocomputers.com/opensuse/$lsb_release/repodata/repomd.xml.key
gpgcheck=1
enabled=1
autorefresh=1
			__EOF__

			if has_nvidia_gpu; then
				[ "$lsb_release" = "13.1" ] && cat <<-__EOF__ >"/etc/zypp/repos.d/home_tiwai_kernel.repo"
[home_tiwai_kernel_3.13]
name=home:tiwai:kernel:3.13 (openSUSE_13.1)
type=rpm-md
baseurl=http://download.opensuse.org/repositories/home:/tiwai:/kernel:/3.13/openSUSE_13.1/
gpgcheck=1
gpgkey=http://download.opensuse.org/repositories/home:/tiwai:/kernel:/3.13/openSUSE_13.1/repodata/repomd.xml.key
enabled=1
autorefresh=1
				__EOF__
				[ "$lsb_release" = "13.1" ] && cat <<-__EOF__ >"/etc/zypp/repos.d/home_Bumblebee-Project_nVidia_331-49.repo"
[home_Bumblebee-Project_nVidia_331-49]
name=Downloader and installer for the nVidia driver package (331.49) (openSUSE_$lsb_release)
type=rpm-md
baseurl=http://download.opensuse.org/repositories/home:/Bumblebee-Project:/nVidia:/331.49/openSUSE_$lsb_release/
gpgcheck=1
gpgkey=http://download.opensuse.org/repositories/home:/Bumblebee-Project:/nVidia:/331.49/openSUSE_$lsb_release/repodata/repomd.xml.key
enabled=1
autorefresh=1
				__EOF__
				cat <<-__EOF__ >"/etc/zypp/repos.d/X11_Bumblebee.repo"
[X11_Bumblebee]
name=Bumblebee project (openSUSE_$lsb_release)
type=rpm-md
baseurl=http://download.opensuse.org/repositories/X11:/Bumblebee/openSUSE_$lsb_release/
gpgcheck=1
gpgkey=http://download.opensuse.org/repositories/X11:/Bumblebee/openSUSE_$lsb_release/repodata/repomd.xml.key
enabled=1
autorefresh=1
				__EOF__

				local tmp="$(mktemp)"
				cat <<-__EOF__ >"$tmp"
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1.4.5 (GNU/Linux)

mQENBFHmiiABCADf2Kdt+nTcJPdO60/9FXFCStgoAnOTaWYvBG73eKR6I5C1NeFE
KQTCBXQeyv9sPpSYN3huMAeamgDaTeQhIgqsfmCns9pRDBaydmTLlI4doXofn0N4
S/PDVUgO1xjjy5j6m3jwG41gggb7ECU6dof254UHYB/wvYVNBmBsJUBS9pwXVrCs
1wwMzmHdQlX4g6q+7a0Ar94S46KOYNuyu4YJCjjo41xKOwlqPBJb3aYuNJzmE9sB
zC+AlhVSeiehhEmJw80z6DKgbIhFZRt/IEXOV9Kjarx8NqRgYLfCA5eTK/IuHGpP
LyvrUtge4PH/vbPRUindSa6rITwvB/2A9QlJABEBAAG0NmhvbWU6dGl3YWkgT0JT
IFByb2plY3QgPGhvbWU6dGl3YWlAYnVpbGQub3BlbnN1c2Uub3JnPokBPAQTAQIA
JgUCUeaKIAIbAwUJBB6wAAYLCQgHAwIEFQIIAwQWAgMBAh4BAheAAAoJEEvwX0b2
50v1yC8H/0em1FlxiMzWl6JqYJgRB+SJN7e/lTH97zfpNslxQUWnWzdgiExzSveI
EJF418hE02LDp7M4UIslP/Z/2pfSGov7FqUBRh+i0/gXsn39nT2zftWTNwQ7+ybi
TcYO004LVUxfqMeCId70+BE4NLBOoPHBlg+4YliCf8k10BMD6e1R8fx1WlKGqMJ0
7p4DuiFfLgoxhNA2xmh24o0miEFqGyXMK3Q/LNzUBMfDgKQd5EK/JFYDwrBjGXaW
v7/qa/G4WIFg0NGdC1PLwf5A1BfvjV4OYAajnMmXfw+/+SswgMRjSoHEoW9haxN4
1S8QpuEDu2feG9LmahHnuSkK/vp+Z62IRgQTEQIABgUCUeaKIAAKCRA7MBG3a51l
I1G9AJ47imjsCFtCy8gqM82NpM0S+NFLcQCglY1q7TlhbKZBw+94OhxdewBDbsM=
=ozrn
-----END PGP PUBLIC KEY BLOCK-----
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1.4.5 (GNU/Linux)

mQGiBE5JDxQRBAC0OAaFuDbylbviZ7ZenfCHkU4cjIan9BhBxZKxVuF49waRj5P9
VEWh9S1a7xnZmY9zmvu8E94KQslbLDT+B3eFUtYzfW97VVqmce/BRVcNZXcOCN77
0SVEpfoHOQw3kXQLpBVVKQVqnOvPYN54QzwZm99xUSk9rLx3F9eMkVx4cwCg0852
5JZ18xtdhznANTh6RiBTQdUEALDTLL2TcHnq3Ee/zyasyi/uxDLClrZC0VtBZ2L3
3UTIDEFETtRtJKcww3AoHcBvDjbs11sgCEi91eMgwJhx3Hx7KZIxl9ifRYfd+g5C
Fo6lhwySFP1yohuQDWal+cmUSUjYU1lG8oN9daAczWGO3blH6e8PNOB/VUq8qpD8
gk79A/9FWrHWN4swDAokXo1I80sjOudoYKegV9Jwiq617sB+qzTu9axZPVGjysMB
LJmmKAoYqhFnNrqfFj73+DGK19KI/AIjZUyKiHb8H7aPX4XmsW2mbbnKfM4q/FDS
32LOi6DKMid5uA2KYTdp3C4tqIHDwaAe6snycG472gTPaZxW8rROaG9tZTpCdW1i
bGViZWUtUHJvamVjdCBPQlMgUHJvamVjdCA8aG9tZTpCdW1ibGViZWUtUHJvamVj
dEBidWlsZC5vcGVuc3VzZS5vcmc+iGYEExECACYFAlJmytYCGwMFCQg8a8IGCwkI
BwMCBBUCCAMEFgIDAQIeAQIXgAAKCRAmKsdPFvRVLAX/AKCeVl1KiXRgOFb7WR5H
+WSMlu2MagCfQwp2WGV+j8JnSvTcrLnrv2l/dw6IRQQTEQIABgUCTkkPFAAKCRA7
MBG3a51lIyesAJY72Cn1HlsQssd9zds0xn0zBpPjAJwPcI43GBPScOG4A3a6mEY7
V0AFbg==
=gxqk
-----END PGP PUBLIC KEY BLOCK-----
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v2.0.15 (GNU/Linux)

mQENBFOJxRIBCADkeFHKPS2YvJ6wujXtcC70NlX4qJDfFx2CdMtpxHs+AjV8QxPN
KizKOyn1F3r5dCOOPn+wJttZ0XZH41aMQzZgiQy6Ei7jy7mriwGwyKP7TzhEtfG5
Z/r3NoPivI3zN8MmGklnh16CHOVAJnQqTpgjv3d471UHy65KjWLFR/Emf3JrK+Je
6a+pRv6Gj81YOJqE/MilyqlvgvQzMm716xC8X4xRj2TJJDIi2JBOx84oWNxI9/PH
9wxNN2Qh1SQMPwkNfLp0OgohtZMV5xB71o98XPFOHTiSRQQjED7MJxmzi0C+k6CF
J0geL1llyz61Bdkd5UtBE9dPZCygZDEdX2dvABEBAAG0PFgxMTpCdW1ibGViZWUg
T0JTIFByb2plY3QgPFgxMTpCdW1ibGViZWVAYnVpbGQub3BlbnN1c2Uub3JnPokB
PgQTAQIAKAUCU4nFEgIbAwUJBB6wAAYLCQgHAwIGFQgCCQoLBBYCAwECHgECF4AA
CgkQZ0huTN0Vr0oyVgf8D8yf1lczjK/BTJGgKO/JvGNwxm6I9AyTtuCbTTkxLv2m
3F1YybAh57QKWH9a8JBmacqwxF4A1GU4gQE6Us/h6KEkmLE01bLslXd8r1C9SgcQ
cESYjfVzjkimgHaEoZ8YhfZxkD2chQ8PPqV9hChjLFxEdpfJhI/CefHgu2GteK/p
rwoShDZZyUzgsi0Zrr1OEuxuZMilC6qT1/Fzz/5/3v5IKak9DZiNcBtRgKLzMJug
OcgZG7EWZNau2Gm5qA/1r7ynv6P8z3TgU6aLR1ZJxonUNlEdSQXZvjwU7oik4PI1
4+Ym5KYjOCKp2hCctscYqhgc1ZsDk1KcnH/VTJTtt4hGBBMRAgAGBQJTicUSAAoJ
EDswEbdrnWUjrwYAoIwibcFl8rb5y7yJeZU9AKCmjAxRAKCT88m7PzSQ/rMwuul9
XkcXbSp+vQ==
=LcMp
-----END PGP PUBLIC KEY BLOCK-----
				__EOF__
				rpmkeys --import "$tmp" && rm "$tmp"

			else
				 [ "$lsb_release" = "13.1" ] && cat <<-__EOF__ >"/etc/zypp/repos.d/kernel_stable.repo"
[Kernel_stable]
name=Kernel builds for branch stable (standard)
type=rpm-md
baseurl=http://download.opensuse.org/repositories/Kernel:/stable/standard/
gpgcheck=1
gpgkey=http://download.opensuse.org/repositories/Kernel:/stable/standard/repodata/repomd.xml.key
enabled=1
autorefresh=1
				__EOF__
				local tmp="$(mktemp)"
				cat <<-__EOF__ >"$tmp"
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1.4.5 (GNU/Linux)

mQENBFEaM/IBCADo3+2CX4/tZoGIooy7QF8+J94rwr7Tov3kXFADlXr+aG7zHMrz
r398QiSCmLsE7kJ8DcapHH+TaYrpy5yuS06RV4euhlJjo2+SHEcSzTGDIjrPTDvM
8KZE3CWZgyRTVZnTq7bRPtVhSIzkTPNyJe1AMMDZH8YYgDgo0zleZWR3w3VA75dC
fGUYjFTjymAM2QtzK3WAgywqZK0F21MKOCUWrz8ZFbCmdcZh/mAYDhmNlFcN6mZS
E/yD5E6pqGEF1Pr4dfwP0NbPBpsYq8wP3T5TIdaD5wr38u2QJNORxCKi8fuCqpf7
HQx5v3x2EVz4VhRzzc31TPVz1LX5MPby8ypBABEBAAG0Lktlcm5lbCBPQlMgUHJv
amVjdCA8S2VybmVsQGJ1aWxkLm9wZW5zdXNlLm9yZz6JATwEEwECACYFAlEaM/IC
GwMFCQQesAAGCwkIBwMCBBUCCAMEFgIDAQIeAQIXgAAKCRDs7vIQA1ecHb9HB/sH
mYq0tanqpguShoQhUbL+Cf7KIe/hcWdufelBLAUktpwXORu4vFluBnuHfVm+NI0w
9gMB/oSx19Xw3sBmJql0Q5SRtIgk/z5DmFdtEf7p/tz+XG7LQap/wfoLoPcFtJoM
RVvHWJX0dqGqaRAkhEcvL3c9+YAF6nP2/Qg3SHhlixYrwoSDQavO54iwS4XeeTm9
foib8ZiJsiC3EUORVwVkHz2gFQsliNElxJd30PSoELJ8Ci2VkfccgvqfzweyuVcY
qYptLo7eg87fUwcE+PS8d4aBul2ovIApZ2TFWX+iooMFLbgTK//Q+2gkjtyUTpsL
o8lxO2iPZ3TDN3nqNP/BiEYEExECAAYFAlEaM/IACgkQOzARt2udZSOyewCguDRQ
jsRPwMa3DqdijMtrGaWTtdcAn20WA8ufB0LM8evtkMiv4PmlYfEz
=u6wR
-----END PGP PUBLIC KEY BLOCK-----
				__EOF__
				rpmkeys --import "$tmp" && rm "$tmp"
			fi
			;;
                SUSE*)
                        cat <<-__EOF__ >"/etc/zypp/repos.d/repo-tuxedo-computers.repo"
[repo-tuxedo-computers]
name=TUXEDO Computers - openSUSE $lsb_release
baseurl=http://rpm.tuxedocomputers.com/opensuse/leap
path=/
gpgkey=http://rpm.tuxedocomputers.com/opensuse/leap/repodata/repomd.xml.key
gpgcheck=1
enabled=1
autorefresh=1
				__EOF__
                        ;;
                esac

	case "$lsb_dist_id" in
		Ubuntu|LinuxMint|elementary*)
			# pub   2048R/B45D479D 2014-11-24
			# uid		       TUXEDO Computers GmbH (www.tuxedocomputers.com) <tux@tuxedocomputers.com>
			# sub   2048R/7B189DC4 2014-11-24
			cat <<-__EOF__ | apt-key add -
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1.4.14 (GNU/Linux)
Comment: deb.tuxedocomputers.com 2048R/B45D479D 2048R/7B189DC4

mQENBFRzM9QBCADmOVF/naLtGvBA40iBtRfdi1JdKVEkTmvNHKPD0qV5QyG78/PR
nwGd1/HraNjNZ1yjFv79a9juLpuhqriGndZVUYDi+qVl/s0IhAWO4RiThAd+hRUB
svW+iLisL9pWkihNYQIllmyEHQ5X8mL+EkHr1jDBQKuhni0iL8qZ90j/EzyYPodC
G/BN0nq10FNr32jdHh3hSjoEWlsybADfI6oca2xi6b9vc882o+mSkESQAHgBGA9i
FfjfUvmUhMJ2vNUSHpzoRVvzT5goHrif8NbVw2vbFW15ATBzJzdtuFCeQzAWUOqF
hJk/7/huFVA+vtuhz1thTN6Ntmm4tnjQWCkrABEBAAG0SVRVWEVETyBDb21wdXRl
cnMgR21iSCAod3d3LnR1eGVkb2NvbXB1dGVycy5jb20pIDx0dXhAdHV4ZWRvY29t
cHV0ZXJzLmNvbT6JATgEEwECACIFAlRzM9QCGwMGCwkIBwMCBhUIAgkKCwQWAgMB
Ah4BAheAAAoJEAtKjQy0XUedfdEH/0ICwcc191cjDS1kLg9vTaynfs0Etd4fec+z
zUQ5QSpi/Bqidu1Y3PJVdFjLiuzFOtCXFMMJCXTsgGHRgKiDAoSPl7M31cqp5qjP
RE+4SMwyVLgHqnOmWZqJqb9n/AV9E9UYMLLsVbHQamskMiIKbewNzqwMSG4NtXoV
jhpf8TYU0tAAWAgslWhphcTxE1JLVd8oV0inQiXZ198PiFg83NdQ18tmg3SinZfu
AY9L+L9wspNcX+F1iWBNFCruOhClgzgFjsjqd89hZrYbJAFz9spDMOkBadpZgsXd
u1lmp6OVK3R2Cb+/bDiqo2PA8/MecY/7dmj/M/Mjkmuf3XqcBO65AQ0EVHMz1AEI
ALW1WQhKTCcGxN9tw9sqGCXRLYUqMDJzs5FESW5ZJxbWGyGlc0ZOLkBJMaQF9KE7
M9mNw63KbLar8Jd7vdRRZvEZ4P+uxcwySvv3QMP708o4q3l7fAXl3dQWomKrK6xz
pN7bDswhUoBvP7djErpc5ilWipAb6VHEiW1SJOzJx7Bg1FjjRhCy4JNW4F/YVHGD
3EAIQBY/OtPTG7jHJDec/Xj5hgXkRSsr+/ku8fSeHPZ6xfMMTKfZZ22vSkBOa/8+
Egt42b1LpnStjhjJuQP0mjuX0FogoFOrX00WhSjMJBE73Ogik9mg9N62hDNdJnAI
f5z0aYxPVtrwS76RRZD0llsAEQEAAYkBHwQYAQIACQUCVHMz1AIbDAAKCRALSo0M
tF1HnSJyB/0ZSvDSI/u34rsKKtKkEYAW1Ebx3NzcGacGMoT72LqXhY1DSqu0osDS
ChwLERhqR6KMIPpALR5S8KTwTkTei1IgLpq5gk0tb+KR4T7Y3A/F5IqtQmXQ6Vtq
RHAHLLKdM3IhL62mx85vMi2dN8g1Wzw/3QZD+omlsHVa382LWcUkR4MNatrn72O2
eJI8pD1FfSZ8Qx2EEFsIDp4rKAj8wWOXpts1K8Jlk3AMAZbjvwOe62j+xMhKUCTZ
P54AVNZHIfcFmkkTtKlc2Tkg4b9O3oII7iz3PV0E76wdgVt4nvL/MpRkJVnShG+Y
3sAteW2HIF2OgNxmZppIY60OszOnX21d
=+Wgc
-----END PGP PUBLIC KEY BLOCK-----
			__EOF__
			;;
		openSUSE*|SUSE*)
			local tmp="$(mktemp)"
			# pub   2048R/45E3D129 2014-06-27 [expires: 2017-06-26]
			# uid                  Andreas Hemmrich (TUXEDO Computers GmbH) <ah@tuxedocomputers.com>
			# uid                  Christoph Jaeger (TUXEDO Computers GmbH) <cj@tuxedocomputers.com>
			cat <<-__EOF__ >"$tmp"
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1.4.14 (GNU/Linux)
Comment: 2048R/45E3D129

mQENBFOtQaYBCACbkQDjjxYQUkb7BbJPXraqXZxKRyfGBSdSVlSRRIeGUlwkO/8q
e+uyDOD8Q1KJg7WZd9wa3lGhSYQLVoO0YL0UBIdYtxIuskE6MWIVlfadZdlQuvSI
pxciSIfISTD6Zqk8GqdP7JnSLjPOra3smlQguKQlrDkxWJtkF2CIfdC2p24FsC/R
GiSOEHaOXQNqPPpBiWD3L/BZFHeT7zkl2eBqZ8DsgMu3Cuz0CieOr/hcNfUV/n8B
XNUdpuJT1Cu4q9FVCHdOrlsgu0Z5bM5Wt1XB4WPDh5jGoPREHIT8gtDhtP6nDz7R
ERHd8RedrVvL1DPQLZwiCoKreO4g3jpGB0ClABEBAAG0QUFuZHJlYXMgSGVtbXJp
Y2ggKFRVWEVETyBDb21wdXRlcnMgR21iSCkgPGFoQHR1eGVkb2NvbXB1dGVycy5j
b20+iQFBBBMBAgArAhsDBQkFo5qABgsJCAcDAgYVCAIJCgsEFgIDAQIeAQIXgAUC
VBa9sgIZAQAKCRDe47N+RePRKXxjB/93QTyEAGmz5lQ0/IOXqDq5fBYR9CELUPQI
8zeqD7xrostP0GLjMujRjHyy8O7CAqTOEs7GZOCJ8VkWgQ6txV8oAbQt3gAMNDiN
qeekyecRA2FXA8u1pINv8satddiZEPe9+Q+9RdkAmZGXbsqRz1wKAfvlKY+Wt0fN
CRliEYIIcGH19fmOaW7t0QxDYCsoNqIIJT+KhZCIrqNXn4xz74ZPSKHOonfVGYw6
T6qls0ktIbUn9JXdP9P2JcZywpxpE8IgqGN0Fps71URbt+xtQw8TU9zw7eWR7+Oo
AOrvOsEggiD0FqvtSDBXZyGBk7qry6ODG9/hkMYSroZmEesrFbYGtEFDaHJpc3Rv
cGggSmFlZ2VyIChUVVhFRE8gQ29tcHV0ZXJzIEdtYkgpIDxjakB0dXhlZG9jb21w
dXRlcnMuY29tPokBPgQTAQIAKAUCU61BpgIbAwUJBaOagAYLCQgHAwIGFQgCCQoL
BBYCAwECHgECF4AACgkQ3uOzfkXj0Skmiwf9FnaEvDONaEY0DjYP6g69RjnPHQ1r
VftMc9Rj8GX1wmZvYEjKICLPT95MUExbks0vN554rRbr4ZjjYn9DDPqYLjz4CFnm
zsUoNWQZHjIJqpR2KABBvpWXSESEo/SJ1Xd8Kvz4aDFfQKHh1WBDea6NDgNwz6n/
6c9QYNGKrHNywxyzxvBpxN0IN9T2USCTIFzyTeGbRBW75FqT/iKd444BZiqLV3nx
F/+P9/IaJp+/C0OroCf06KzgJqIvQ4jWqav9riPSO1mYjszCmXF5to9TySzXMOX5
WzcaWWHZQT2K6lG3kFGr0XRLi6EdVsGeJDFwJ/MYBHxR3tdTohw0o7WLUA==
=XwJ1
-----END PGP PUBLIC KEY BLOCK-----
			__EOF__
			rpmkeys --import "$tmp"
			rm -f "$tmp"
			;;
	esac
}
task_repository_test() {
	true
}

task_update() {
	$refresh_cmd
	$upgrade_cmd
}
task_update_test() {
	true
}

task_install_kernel() {
	$refresh_cmd
	$upgrade_cmd
	case "$lsb_dist_id" in
		Ubuntu|LinuxMint)
			#$install_cmd linux-generic
			case "$lsb_codename" in
				precise|maya) $install_cmd linux-generic-lts-raring ;;
				qiana) $install_cmd linux-generic-lts-vivid ;;
				trusty|rafaela|rosa) $install_cmd linux-generic-lts-wily ;;
				*) $install_cmd linux-generic ;;
			esac
			;;
		elementary*)
			case "$lsb_codename" in
                                freya) $install_cmd linux-generic-lts-wily ;;
                                *) $install_cmd linux-generic ;;
                        esac
                        ;;
		openSUSE*)
			case "$lsb_release" in
				13.1) $install_cmd -f --from home_tiwai_kernel_3.13 kernel-desktop kernel-desktop-devel || $install_cmd -f kernel-desktop kernel-desktop-devel;;
				13.2) $install_cmd -f kernel-desktop kernel-desktop-devel;;
				*) echo "nichts" >/dev/null;;
			esac
			;;
	esac
}
task_install_kernel_test() {
	case "$lsb_dist_id" in
		Ubuntu|LinuxMint)
			case "$lsb_codename" in
                                precise|maya) pkg_is_installed linux-generic-lts-raring || return 1 ;;
                                qiana) pkg_is_installed linux-generic-lts-vivid || return 1 ;;
				trusty|rafaela|rosa) pkg_is_installed linux-generic-lts-wily || return 1;;
                                *) pkg_is_installed linux-generic || return 1 ;;
                        esac
			;;
		elementary*)
			case "$lsb_codename" in
                                freya) pkg_is_installed linux-generic-lts-wily || return 1 ;;
                                *) pkg_is_installed linux-generic || return 1 ;;
                        esac
                        ;;
		openSUSE*)
			pkg_is_installed kernel-desktop || return 1
			;;
	esac

	true
}

task_trim() {
	while read device mountpoint fstype _; do
		[ -x "$(which hdparm)" ] || $install_cmd hdparm
		if [ $fstype = "ext4" ] && hdparm -I $device | grep -qiw 'trim'; then
			fstrim -v $mountpoint
			tune2fs -o discard $device
		fi
	done </proc/mounts
}
task_trim_test() {
	true
}

task_software() {

	case "$lsb_dist_id" in
		Ubuntu|LinuxMint|elementary*)
			mkdir -p /etc/laptop-mode/conf.d && touch /etc/laptop-mode/conf.d/ethernet.conf
			echo "CONTROL_ETHERNET=0" > /etc/laptop-mode/conf.d/ethernet.conf
                        $install_cmd laptop-mode-tools xbacklight exfat-fuse exfat-utils
			if [ $lsb_release == "15.10" ]; then
                        sed -i "s#\(^AUTOSUSPEND_RUNTIME_DEVTYPE_BLACKLIST=\).*#\1usbhid#" /etc/laptop-mode/conf.d/runtime-pm.conf
                        fi
			apt-get -y remove unity-webapps-common app-install-data-partner
			wget https://www.tuxedocomputers.com/support/iwlwifi-4.2.tar.gz
			tar xvzf iwlwifi-4.2.tar.gz
			cd iwlwifi-4.2
			cp iwlwifi*.ucode /lib/firmware
			cd ..
			rm -rf iwlwifi-4.2*
			if [ -e "/sys/class/backlight/intel_backlight/max_brightness"]; then
			cat /sys/class/backlight/intel_backlight/max_brightness > /sys/class/backlight/intel_backlight/brightness
			fi
			;;
		SUSE*)
			$install_cmd  exfat-utils fuse-exfat
			;;
	esac

	$install_cmd $PACKAGES
}
task_software_test() {

	case "$lsb_dist_id" in
		Ubuntu|LinuxMint|elementary*)
                        pkg_is_installed laptop-mode-tools || return 1
			;;
	esac

	for p in $PACKAGES; do
		pkg_is_installed $p || return 1
	done

	true
}

task_clean() {
	$clean_cmd
	find /var/lib/apt/lists -type f -exec rm -fv {} \; 2>/dev/null
}
task_clean_test() {
	true
}


do_task() {
	error=0
	printf "%-16s " "$1" >&3
	echo "Calling task $1"
	task_$1
	if [ $error -eq 0 ] && task_${1}_test; then
		echo -e "\e[1;32mOK\e[0m" >&3
		echo "Task $1 OK"
	else
		echo -e "\e[1;31mFAILED\e[0m" >&3
		echo "Task $1 FAILED"
	fi
}


trap "rm -f $apt_conf_proxy $apt_sources_list; exit" ABRT EXIT HUP INT QUIT

[ -x $(which nc) ] || $install_cmd netcat-openbsd

proxy=
for host in $APT_CACHE_HOSTS; do
	echo "Trying to reach proxy $host ..."
	if ping -w 2 $host && nc -zv $host $APT_CACHE_PORT 2>&1 | grep -q 'Connection.*succeeded!'; then
		proxy=$host
		break
	fi
done

if [ "$proxy" ]; then
	apt_conf_proxy=/etc/apt/apt.conf.d/00proxy
	echo "Using apt-cache $proxy:$APT_CACHE_PORT" >&3
	case "$lsb_dist_id" in
		Ubuntu|LinuxMint|elementary*)
			cat >"$apt_conf_proxy" <<-__EOF__
Acquire::http { Proxy "http://$proxy:$APT_CACHE_PORT"; };
			__EOF__
			;;
		openSUSE*|SUSE*)
			export http_proxy=http://$proxy:$APT_CACHE_PORT
			;;
	esac
else
	echo "apt-cache NOT available" >&3
fi

do_task clean
do_task update
do_task repository
do_task install_kernel
#do_task trim
do_task grub

case "$lsb_dist_id" in
	Ubuntu|LinuxMint|elementary*)
		[ "$lsb_codename" = "quantal" -o "$lsb_codename" = "raring" -o "$lsb_codename" = "nadia" -o "$lsb_codename" = "olivia" ] && do_task saucy_kernel
		has_fingerprint_reader && do_task fingerprint
		;;
	openSUSE*)
		;;
	SUSE*)
		has_fingerprint_reader && do_task fingerprint
                ;;
esac

has_nvidia_gpu && do_task nvidia
[ "$(sed 's/^\s*//;s/\s*$//' /sys/devices/virtual/dmi/id/product_name)" != "MS-1758" ] && do_task tuxedo_wmi
do_task wallpaper
do_task software
do_task misc
do_task files
do_task clean
do_task update

rm -f $apt_conf_proxy $apt_sources_list
read -p "Press <ENTER> to reboot" >&3 2>&1
exec reboot
