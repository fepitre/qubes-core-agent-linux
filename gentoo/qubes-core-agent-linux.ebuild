# Maintainer: Frédéric Pierret <frederic.pierret@qubes-os.org>

EAPI=6

inherit git-r3 eutils multilib

MY_PV=${PV/_/-}
MY_P=${PN}-${MY_PV}

KEYWORDS="~amd64"
EGIT_REPO_URI="https://github.com/QubesOS/qubes-core-agent-linux.git"
EGIT_COMMIT="v${PV}"
DESCRIPTION="The Qubes core files for installation inside a Qubes VM"
HOMEPAGE="http://www.qubes-os.org"
LICENSE="GPLv2"

SLOT="0"
IUSE="networking"

DEPEND="app-emulation/qubes-libvchan-xen \
        app-emulation/qubes-db
        dev-lang/python
        net-misc/socat
        x11-misc/xdg-utils
        networking? (
            app-emulation/qubes-core-agent-linux
            sys-apps/ethtool
            sys-apps/net-tools
            net-firewall/iptables
            net-proxy/tinyproxy
        )
        "
RDEPEND="app-emulation/qubes-utils"
PDEPEND=""

src_prepare() {
    einfo "Apply patch set"
    EPATCH_SUFFIX="patch" \
    EPATCH_FORCE="yes" \
    EPATCH_OPTS="-p1" \
    epatch "${FILESDIR}"

    default
}

src_compile() { 
    # WIP: currently disable pandoc
    sed -i 's/pandoc -s -f rst -t man/touch/' doc/Makefile
    
    myopt="${myopt} DESTDIR="${D}" SYSTEMD=1 BACKEND_VMM=xen PYTHON=python3.7"
    for dir in qubes-rpc misc; do
        emake ${myopt} -C "$dir"
    done
}

src_install() {
    emake ${myopt} install-corevm
    emake ${myopt} -C qubes-rpc install

    if use networking; then
        emake ${myopt} install-networking
    fi

    # Remove things unwanted in Gentoo
    ${myopt} rm -r "$DESTDIR/etc/yum"*
    ${myopt} rm -r "$DESTDIR/etc/dnf"*
    ${myopt} rm -r "$DESTDIR/etc/init.d"
}

pkg_preinst() {
    update_default_user

    mkdir -p /var/lib/qubes

    if [ -e /etc/fstab ] ; then
        mv /etc/fstab /var/lib/qubes/fstab.orig
    fi

    usermod -L root
    usermod -L user
}

pkg_postinst() {
    update_qubesconfig

    if [ -e /etc/init/serial.conf ] && ! [ -f /var/lib/qubes/serial.orig ] ; then
        cp /etc/init/serial.conf /var/lib/qubes/serial.orig
    fi

    # Remove most of the udev scripts to speed up the VM boot time
    # Just leave the xen* scripts, that are needed if this VM was
    # ever used as a net backend (e.g. as a VPN domain in the future)
    #echo "--> Removing unnecessary udev scripts..."
    mkdir -p /var/lib/qubes/removed-udev-scripts
    for f in /etc/udev/rules.d/*
    do
        if [ "$(basename "$f")" == "xen-backend.rules" ] ; then
            continue
        fi

        if echo "$f" | grep -q qubes; then
            continue
        fi

        mv "$f" /var/lib/qubes/removed-udev-scripts/
    done

    chgrp user /var/lib/qubes/dom0-updates

    mkdir -p /rw

    configure_notification_daemon
    configure_selinux
    configure_systemd 1

    if use networking; then
        systemctl enable qubes-firewall.service
        systemctl enable qubes-iptables.service
        systemctl enable qubes-network.service
        systemctl enable qubes-updates-proxy.service
    fi
}

pkg_prerm() {
    if [ -e /var/lib/qubes/fstab.orig ] ; then
        mv /var/lib/qubes/fstab.orig /etc/fstab
    fi

    mv /var/lib/qubes/removed-udev-scripts/* /etc/udev/rules.d/

    if [ -e /var/lib/qubes/serial.orig ] ; then
        mv /var/lib/qubes/serial.orig /etc/init/serial.conf
    fi

    # Run this only during uninstall.
    # Save the preset file to later use it to re-preset services there
    # once the Qubes OS preset file is removed.
    mkdir -p /run/qubes-uninstall
    cp -f /usr/lib/systemd/system-preset/$qubes_preset_file /run/qubes-uninstall/

    if use networking; then
        systemctl disable qubes-firewall.service
        systemctl disable qubes-iptables.service
        systemctl disable qubes-network.service
        systemctl disable qubes-updates-proxy.service
    fi
}

pkg_postrm() { 
    changed=

    if [ -d /run/qubes-uninstall ]; then
        # We have a saved preset file (or more).
        # Re-preset the units mentioned there.
        restore_units /run/qubes-uninstall/$qubes_preset_file
        rm -rf /run/qubes-uninstall
        changed=true
    fi

    if [ -n "$changed" ]; then
        systemctl daemon-reload
    fi

    if [ -L /lib/firmware/updates ] ; then
      rm /lib/firmware/updates
    fi

    rm -rf /var/lib/qubes/xdg

    for srv in qubes-sysinit qubes-misc-post qubes-mount-dirs; do
        systemctl disable $srv.service
    done
}

###

qubes_preset_file="75-qubes-vm.preset"

update_default_user() {
    # Make sure there is a qubes group
    groupadd --force --system --gid 98 qubes

    id -u 'user' >/dev/null 2>&1 || {
        useradd --user-group --create-home --shell /bin/bash user
    }

    usermod -a --groups qubes user
}

configure_notification_daemon() {
    # Enable autostart of notification-daemon when installed
    if [ ! -L /etc/xdg/autostart/notification-daemon.desktop ]; then
        ln -s /usr/share/applications/notification-daemon.desktop /etc/xdg/autostart/
    fi
}

configure_selinux() {
    if [ -e /etc/selinux/config ]; then
        sed -e s/^SELINUX=.*$/SELINUX=disabled/ -i /etc/selinux/config
        setenforce 0 2>/dev/null
    fi
}

update_qubesconfig() {
    # Remove old firmware updates link
    if [ -L /lib/firmware/updates ]; then
      rm -f /lib/firmware/updates
    fi

    # convert /usr/local symlink to a mount point
    if [ -L /usr/local ]; then
        rm -f /usr/local
        mkdir /usr/local
        mount /usr/local || :
    fi

    if ! [ -r /etc/dconf/profile/user ]; then
        mkdir -p /etc/dconf/profile
        echo "user-db:user" >> /etc/dconf/profile/user
        echo "system-db:local" >> /etc/dconf/profile/user
    fi

    dconf update &> /dev/null || :

    # Location of files which contains list of protected files
    mkdir -p /etc/qubes/protected-files.d
    # shellcheck source=init/functions
    . /usr/lib/qubes/init/functions

    # qubes-core-vm has been broken for some time - it overrides /etc/hosts; restore original content
    if ! is_protected_file /etc/hosts ; then
        if ! grep -q localhost /etc/hosts; then

          cat <<EOF > /etc/hosts
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4 $(hostname)
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
EOF

        fi
    fi

    # ensure that hostname resolves to 127.0.0.1 resp. ::1 and that /etc/hosts is
    # in the form expected by qubes-sysinit.sh
    if ! is_protected_file /etc/hostname ; then
        for ip in '127\.0\.0\.1' '::1'; do
            if grep -q "^${ip}\(\s\|$\)" /etc/hosts; then
                sed -i "/^${ip}\s/,+0s/\(\s$(hostname)\)\+\(\s\|$\)/\2/g" /etc/hosts
                sed -i "s/^${ip}\(\s\|$\).*$/\0 $(hostname)/" /etc/hosts
            else
                echo "${ip} $(hostname)" >> /etc/hosts
            fi
        done
    fi

}

is_static() {
    [ -f "/usr/lib/systemd/system/$1" ] && ! grep -q '^[[].nstall]' "/usr/lib/systemd/system/$1"
}

is_masked() {
    if [ ! -L /etc/systemd/system/"$1" ]
    then
        return 1
    fi
    target=$(readlink /etc/systemd/system/"$1" 2>/dev/null) || :
    if [ "$target" = "/dev/null" ]
    then
        return 0
    fi
    return 1
}

mask() {
    ln -sf /dev/null /etc/systemd/system/"$1"
}

unmask() {
    if ! is_masked "$1"
    then
        return 0
    fi
    rm -f /etc/systemd/system/"$1"
}

preset_units() {
    local represet=
    while read -r action unit_name
    do
        if [ "$action" = "#" ] && [ "$unit_name" = "Units below this line will be re-preset on package upgrade" ]
        then
            represet=1
            continue
        fi
        echo "$action $unit_name" | grep -q '^[[:space:]]*[^#;]' || continue
        [[ -n "$action" && -n "$unit_name" ]] || continue
        if [ "$2" = "initial" ] || [ "$represet" = "1" ]
        then
            if [ "$action" = "disable" ] && is_static "$unit_name"
            then
                if ! is_masked "$unit_name"
                then
                    # We must effectively mask these units, even if they are static.
                    mask "$unit_name"
                fi
            elif [ "$action" = "enable" ] && is_static "$unit_name"
            then
                if is_masked "$unit_name"
                then
                    # We masked this static unit before, now we unmask it.
                    unmask "$unit_name"
                fi
                systemctl --no-reload preset "$unit_name" >/dev/null 2>&1 || :
            else
                systemctl --no-reload preset "$unit_name" >/dev/null 2>&1 || :
            fi
        fi
    done < "$1"
}

restore_units() {
    grep '^[[:space:]]*[^#;]' "$1" | while read -r action unit_name
    do
        if is_static "$unit_name" && is_masked "$unit_name"
        then
            # If the unit had been masked by us, we must unmask it here.
            # Otherwise systemctl preset will fail badly.
            unmask "$unit_name"
        fi
        systemctl --no-reload preset "$unit_name" >/dev/null 2>&1 || :
    done
}

configure_systemd() {
    if [ "$1" -eq 1 ]
    then
        preset_units /usr/lib/systemd/system-preset/$qubes_preset_file initial
        changed=true
    else
        preset_units /usr/lib/systemd/system-preset/$qubes_preset_file upgrade
        changed=true
        # Upgrade path - now qubes-iptables is used instead
        for svc in iptables ip6tables
        do
            if [ -f "$svc".service ]
            then
                systemctl --no-reload preset "$svc".service
                changed=true
            fi
        done
    fi

    if [ "$1" -eq 1 ]
    then
        # First install.
        # Set default "runlevel".
        # FIXME: this ought to be done via kernel command line.
        # The fewer deviations of the template from the seed
        # image, the better.
        rm -f /etc/systemd/system/default.target
        ln -s /lib/systemd/system/multi-user.target /etc/systemd/system/default.target
        changed=true
    fi

    # remove old symlinks
    if [ -L /etc/systemd/system/sysinit.target.wants/qubes-random-seed.service ]
    then
        rm -f /etc/systemd/system/sysinit.target.wants/qubes-random-seed.service
        changed=true
    fi
    if [ -L /etc/systemd/system/multi-user.target.wants/qubes-mount-home.service ]
    then
        rm -f /etc/systemd/system/multi-user.target.wants/qubes-mount-home.service
        changed=true
    fi

    if [ "x$changed" != "x" ]
    then
        systemctl daemon-reload
    fi
}