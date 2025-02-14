# Copyright (C) 2023 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

tar_container() {
    test -z "$1" && {
        echo "Usage: tar_container CONTAINER [DIR]..." >&2
        return 1
    }

    test -t 1 && {
        echo "tar_container: refusing to write TAR archive to terminal" >&2
        return 2
    }

    local readonly CONTAINER=$1
    shift

    test -z "$1" && set -- .
    echo $@ >&2

    local readonly CID=$(docker create $CONTAINER)
    test -n "$CID" && {
        for p in "$@"; do
            docker cp -q $CID:$p -
        done
        docker rm $CID
    } || return 3
}

cat_file() {
    test -z "$F" || rm -fv $1
    test -f $1 && {
        echo "skipped existing '$1'" >&2
        return 0
    } || {
        mkdir -p $(dirname $1)
        cat > $1 && chmod $2 $1 && echo "generated '$1'" >&2
    }
}

_gen_init__() {
    test $# -ne 1 && {
        echo "Usage: gen_init INITRD_TREE" >&2
        return 1
    }

    for f in sh awk blockdev cat dd dmsetup hexdump mkdir mount setsid; do
        find $1 -executable -name $f -print -quit | grep -qw $f\$ || {
            echo "gen_init: missing '$f', init may not run" >&2
        }
    done

    set -- $(realpath -s $1)
    local readonly _sh__=/bin/sh
    local readonly _bs__=4096
    local readonly _ss__=512
    local readonly _ec__=384
    cat_file $1/init 0540 << END || return 3
#!$_sh__

set_path() {
    test \$# -eq 0 && set -- /bin /sbin /usr/bin /usr/sbin /usr/lcoal/bin /usr/local/sbin
    unset PATH
    for p; do
        test -d \$p && PATH=\$p\${PATH:+:\$PATH}
    done
    test -n "\$PATH" && export PATH
}

load_modules() {
    test \$# -eq 0 && set -- /etc/modules
    local f && for f; do
        test -e \$f && local m && for m in \$(awk '\$1!~/^#/ { print \$0 }' \$f); do
            modprobe \$m
        done
    done
}

mount_fstab() {
    test \$# -eq 0 && set -- /etc/fstab
    local f && for f; do
        test -e \$f && local m && for m in \$(awk '\$1!~/^#/ && \$2~/^\// { print \$2 }' \$f); do
            mkdir -p \$m
            mount \$m && echo mount_fstab: Mounted \$m
        done
    done
}

dm_integrity() {
    test \$# -lt 4 &&
    echo usage: dm_integrity NAME DEV [SIZE] TAGSIZE [ARG]... >&2 &&
    return 1

    local readonly dm=\$1
    local readonly db=\$2
    local readonly sz=\${3:-$(($_bs__/$_ss__))}
    local readonly ts=\$4
    shift 4

    local action=create
    test -b /dev/mapper/\$dm && action=load

    dmsetup \$action \$dm --table "0 \$sz integrity \\
        \$db 0 \$ts D \$((\$#+1)) block_size:$_bs__ \$*" &&
    case \$action in
        load) dmsetup resume \$dm;;
    esac
}

dm_integrity_js0() {
    dm_integrity "\$@" journal_sectors:0
}

dm_crypt() {
    test \$# -lt 5 &&
    echo usage: dm_crypt NAME DEV [SIZE] ALGO KEY [ARG]... >&2 &&
    return 1

    local readonly dm=\$1
    local readonly db=\$2
    local readonly sz=\${3:-\$(blockdev --getsz \$2)}
    local readonly alg=\$4
    local readonly key=\$5
    shift 5

    local action=create
    test -b /dev/mapper/\$dm && action=load

    dmsetup \$action \$dm --table "0 \$sz crypt \$alg \$key 0 \$db 0 \\
        \$((\$#+2)) sector_size:$_bs__ allow_discards \$*" &&
    case \$action in
        load) dmsetup resume \$dm;;
    esac
}

wipe_dev() {
    local readonly bc=\${2:-\$((\$(blockdev --getsize64 \$1)/$_bs__))}
    echo "\$1: wiping \$bc $_bs__-byte block(s) ..." >&2
    dd if=/dev/zero of=\$1 bs=$_bs__ oflag=direct status=none count=\$bc
}

_dm_alloc_ram__() {
    local rd=\$(find /sys/block/ram*/holders -empty -print -quit)
    if test -z "\$rd"; then
        echo _dm_alloc_ram__: No ramdisk device available >&2
    else
        rd=\${rd#/sys/block/}
        rd=/dev/\${rd%/holders}
        wipe_dev \$rd 1
        echo \$rd
    fi
}

_dm_size_ram__() {
    local readonly md=\$1
    shift

    dm_integrity_js0 "\$@" meta_device:\$md
}

_dm_alloc_zram__() {
    local js=\$(dmsetup table \$1 | awk '{
        for (i = 9; i < NF && !match(\$i, /^journal_sectors:/); i++);
        print(\$6, substr(\$i, 17));
    }')

    local ts=\${js%% *}
    js=\${js#\$ts }

    local readonly mdsz=\$((\$2*\$ts/$_bs__+\$js+2))
    local readonly md=zram\$(cat /sys/class/zram-control/hot_add)
    test -b /dev/\$md && echo \$((\$mdsz*$_ss__)) > /sys/block/\$md/disksize &&
        echo /dev/\$md ||
        echo _dm_metadev__: Not a block device -- \$md >&2
}

_dm_size_zram__() {
    local readonly md=\${1#/dev/}
    shift

    while ! dm_integrity_js0 "\$@" meta_device:/dev/\$md; do
        local mdsz=\$((\$(cat /sys/block/\$md/disksize)+$_bs__))
        echo 1 > /sys/block/\$md/reset &&
        echo \$mdsz > /sys/block/\$md/disksize ||
        return 1
    done
}

dm_alloc_metadev() {
    _dm_alloc_ram__ "\$@"
}

dm_size_metadev() {
    _dm_size_ram__ "\$@"
}

dm_load_key_ae() {
    test \$# -eq 2 && set -- \$* /dev/urandom
    test "\$1" = "@" && set -- @xts \$2 \$3

    local kl
    case \$2 in
        +)
            kl=32
            echo -n "16 capi:\${1#@}(aes)-random "
            ;;
        +cmac)
            kl=64
            echo -n "32 capi:authenc(\${2#+}(aes),\${1#@}(aes))-random "
            ;;
        +sha*)
            kl=\$((\${2##*[!0-9]}/8+32))
            echo -n "\$((\$kl-16)) capi:authenc(hmac(\${2#+}),\${1#@}(aes))-random "
            ;;
        *)
            echo dm_load_key_ae: Unsupported MAC -- \$2 >&2
            return 1
    esac
    hexdump -vn\$kl -e'/4 "%08x"' \$3
}

dm_authenc() {
    test \$# -lt 3 &&
        echo usage: dm_authenc DM_DEV DEV @CIPHER >&2 &&
        return 1

    test ! -b \$2 &&
        echo dm_authenc: Not a block device -- \$2 >&2 &&
        return 2

    local enc=\${3%+*}
    local mac=\${3#\$enc}
    local tl=\$(dm_load_key_ae \$enc \${mac:-+cmac})
    local k=\${tl#* }
    tl=\${tl% \$k}

    test "\$mac" = "+" && mac=none || mac=aead
    wipe_dev \$2 1 &&
    dm_integrity_js0 \$1-int \$2 "" \$tl &&
    local readonly sz=\$(blockdev --getsz \$2) &&
    local readonly md=\$(dm_alloc_metadev \$1-int \$sz) && test -n "\$md" &&
    dm_size_metadev \$md \$1-int \$2 \$sz \$tl &&
    dm_crypt \$1 /dev/mapper/\$1-int \$sz \$k integrity:\$tl:\$mac
}

dm_load_key() {
    test -z "\$2" && set -- \$1 /dev/urandom
    case \$1 in
        @) set -- @xts \$2;;
        +) set -- +sha384 \$2;;
    esac

    local kl=0
    case \$1 in
        @xts|@cbc)
            kl=32
            echo -n "capi:\${1#@}(aes)-plain64 "
            ;;
        +cmac)
            kl=16
            echo -n "\${1#+}(aes):"
            ;;
        +hmac_sha*)
            kl=\$((\${##*[!0-9]}/8))
            echo -n "hmac(\${1#+hmac_}):"
            ;;
        +crc32*|+sha*)
            echo "\${1#+}"
            ;;
        *)
            echo dm_load_key: Unsupported cipher spec -- \$1 >&2
            return 1
    esac &&
    test \$kl -gt 0 && hexdump -vn\$kl -e'/4 "%08x"' \$2
}

dm_encrypt_mac() {
    test \$# -lt 3 &&
        echo usage: dm_encrypt_mac DM_DEV DEV @CIPHER >&2 &&
        return 1

    test ! -b \$2 &&
        echo dm_encrypt_mac: Not a block device -- \$2 >&2 &&
        return 2

    local enc=\${3%+*}
    local mac=\${3#\$enc}
    test -z "\$mac" && mac=+sha384

    wipe_dev \$2 1 &&
    if test "\$mac" = "+"; then
        dm_crypt \$1 \$2 "" \$(dm_load_key \$enc)
    else
        dm_integrity_js0 \$1-int \$2 "" - internal_hash:\$(dm_load_key \$mac /dev/zero) &&
        local readonly sz=\$(blockdev --getsz \$2) &&
        local readonly md=\$(dm_alloc_metadev \$1-int \$sz) && test -n "\$md" &&
        dm_size_metadev \$md \$1-int \$2 \$sz - internal_hash:\$(dm_load_key \$mac) allow_discards
        dm_crypt \$1 /dev/mapper/\$1-int \$sz \$(dm_load_key \$enc)
    fi
}

dm_format() {
    which dmsetup > /dev/null || {
        echo dm_format: dmsetup not found -- \$1 >&2
        return 1
    }

    test \$# -lt 2 && {
        echo usage: dm_format DEV@[CIPHER] TYPE >&2
        return 2
    }

    local base=\${1%@*}
    local cipher=\${1#\$base}
    base=/dev/\$base
    test ! -b \$base && {
        echo dm_format: Not a block device -- \$base >&2
        return 3
    }

    case x\$cipher in
        x)      # no cipher specified
            echo dm_format: No cipher specified >&2
            return 4
            ;;
        x*+)    # encrypt only
            dm_crypt \$1 \$base "" \$(dm_load_key \${cipher%+})
            ;;
        x*+ae)  # autheticated-encrypt
            dm_authenc \$1 \$base \${cipher%+ae}
            ;;
        x*)     # encrypt then MAC
            dm_encrypt_mac \$1 \$base \${cipher:-@}
            ;;
    esac &&
    case \$2 in
        swap)
            wipe_dev /dev/mapper/\$1 1 &&
            mkswap /dev/mapper/\$1
            ;;
        ext2|ext3|ext4)
            blkdiscard /dev/mapper/\$1 ||
            wipe_dev /dev/mapper/\$1 &&
            mkfs.\$2 -Ediscard /dev/mapper/\$1
            ;;
    esac
}

dm_fstab() {
    test \$# -eq 0 && set -- /etc/fstab
    local f && for f; do
        test -e \$f && local m &&
        for m in \$(awk '\$1~/^\/dev\/mapper\// { printf "%s@%s\n",\$1,\$3 }' \$f); do
            local readonly d=\${m%@*}
            dm_format \${d#/dev/mapper/} \${m#\$d@}
        done
    done
}

dm_test() {
    test \$# -lt 2 && {
        echo dm_test: FILE SIZE [REPEAT_COUNT] [PROG ARG...] >&2
        return 1
    }

    local fn=\$1
    local sz=\$2
    local cnt=\${3:-100}
    shift \$((\$# > 3 ? 3 : \$#))

    while test \$cnt -gt 0; do
        echo \$((cnt--)) tests remaining -- file=\$fn bs=\${BS:-1M} count=\$sz
        time dd if=/dev/urandom of=\$fn bs=\${BS:-1M} count=\$sz
        "\$@"
    done
}

sshd_start() {
    local readonly sshd=\$(which sshd)
    test -n "\$sshd" || return 1

    local readonly logfname=\$1
    local readonly bitlen=\$2
    shift 2

    local k
    for k; do
        test -f /etc/ssh/ssh_host_\${k}_key && break
    done ||
    ssh-keygen -t \$1 -b \$bitlen -f /etc/ssh/ssh_host_\${1}_key -N '' ||
    return 2

    mkdir -p \${logfname%/*}
    \$sshd -E \$logfname
}

reclaim_zrams() {
    test -w /sys/class/zram-control/hot_remove &&
    for d in /dev/zram*; do
        echo \${d#/dev/zram} > /sys/class/zram-control/hot_remove
    done
}

_init_main__() {
    set_path
    load_modules
    mount_fstab

    reclaim_zrams
    dm_fstab
    mount -a
    swapon -ae

    export HOME=/root
    mkdir -p \$HOME

    test -e /etc/resolv.conf || ln -sv /proc/net/pnp /etc/resolv.conf
    sshd_start /run/log/sshd.log $_ec__ ecdsa rsa ed25519

    exec setsid -c "\$@"
}

test "\$0" = "/init" -a \$\$ -eq 1 && _init_main__ $_sh__ -il
END
}

_gen_udhcpc__() {
    local readonly _fn__=$(find $1 -name udhcpc -xtype f -exec '{}' --help ';' 2>&1 |
        awk '/^\s+-s PROG/ { gsub(/)+$/, "", $(NF)); print $(NF) }')
    test -n "$_fn__" && cat_file $1$_fn__ 0540 << END || return 3
#!/bin/sh

# script for udhcpc
# Copyright (c) 2008 Natanael Copa <natanael.copa@gmail.com>

UDHCPC="/etc/udhcpc"
UDHCPC_CONF="\$UDHCPC/udhcpc.conf"

RESOLV_CONF="/etc/resolv.conf"
[ -f \$UDHCPC_CONF ] && . \$UDHCPC_CONF

export broadcast
export dns
export domain
export interface
export ip
export mask
export metric
export staticroutes
export router
export subnet

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

run_scripts() {
    local dir=\$1
    if [ -d \$dir ]; then
        for i in \$dir/*; do
            [ -f \$i ] && \$i
        done
    fi
}

deconfig() {
    ip -4 addr flush dev \$interface
}

is_wifi() {
    test -e /sys/class/net/\$interface/phy80211
}

if_index() {
    if [ -e  /sys/class/net/\$interface/ifindex ]; then
        cat /sys/class/net/\$interface/ifindex
    else
        ip -4 link show dev \$interface | head -n1 | cut -d: -f1
    fi
}

calc_metric() {
    local base=
    if is_wifi; then
        base=300
    else
        base=200
    fi
    echo \$(( \$base + \$(if_index) ))
}

route_add() {
    local to=\$1 gw=\$2 num=\$3
    # special case for /32 subnets:
    # /32 instructs kernel to always use routing for all outgoing packets
    # (they can never be sent to local subnet - there is no local subnet for /32).
    # Used in datacenters, avoids the need for private ip-addresses between two hops.
    if [ "\$subnet" = "255.255.255.255" ]; then
        ip -4 route add \$gw dev \$interface
    fi
    ip -4 route add \$to via \$gw dev \$interface \\
        metric \$(( \$num + \${IF_METRIC:-\$(calc_metric)} ))
}

routes() {
    [ -z "\$router" ] && [ -z "\$staticroutes" ] && return
    for i in \$NO_GATEWAY; do
        [ "\$i" = "\$interface" ] && return
    done
    while ip -4 route del default via dev \$interface 2>/dev/null; do
        :
    done
    local num=0
    # RFC3442:
    # If the DHCP server returns both a Classless Static Routes option
    # and a Router option, the DHCP client MUST ignore the Router option.
    if [ -n "\$staticroutes" ]; then
        # static routes format: dest1/mask gw1 ... destn/mask gwn
        set -- \$staticroutes
        while [ -n "\$1" ] && [ -n "\$2" ]; do
            local dest="\$1" gw="\$2"
            if [ "\$gw" != "0.0.0.0" ]; then
                route_add \$dest \$gw \$num && num=\$(( \$num + 1))
            fi
            shift 2
        done
    else
        local gw=
        for gw in \$router; do
            route_add 0.0.0.0/0 \$gw \$num && num=\$(( \$num + 1 ))
        done
    fi
}

resolvconf() {
    local i
    [ -n "\$IF_PEER_DNS" ] && [ "\$IF_PEER_DNS" != "yes" ] && return
    if [ "\$RESOLV_CONF" = "no" ] || [ "\$RESOLV_CONF" = "NO" ] \\
            || [ -z "\$RESOLV_CONF" ] || [ -z "\$dns" ]; then
        return
    fi
    for i in \$NO_DNS; do
        [ "\$i" = "\$interface" ] && return
    done
    echo -n > "\$RESOLV_CONF.\$\$"
    if [ -n "\$search" ]; then
        echo "search \$search" >> "\$RESOLV_CONF.\$\$"
    elif [ -n "\$domain" ]; then
        echo "search \$domain" >> "\$RESOLV_CONF.\$\$"
    fi
    for i in \$dns; do
        echo "nameserver \$i" >> "\$RESOLV_CONF.\$\$"
    done
    chmod a+r "\$RESOLV_CONF.\$\$"
    mv "\$RESOLV_CONF.\$\$" "\$RESOLV_CONF"
}

bound() {
    ip -4 addr add \$ip/\$mask \${broadcast:+broadcast \$broadcast} dev \$interface
    ip -4 link set dev \$interface up
    routes
    resolvconf
}

renew() {
    if ! ip -4 addr show dev \$interface | grep \$ip/\$mask; then
        ip -4 addr flush dev \$interface
        ip -4 addr add \$ip/\$mask \${broadcast:+broadcast \$broadcast} dev \$interface
    fi

    local i
    for i in \$router; do
        if ! ip -4 route show | grep ^default | grep \$i; then
            routes
            break
        fi
    done

    if ! grep "^search \$domain"; then
        resolvconf
        return
    fi
    for i in \$dns; do
        if ! grep "^nameserver \$i"; then
            resolvconf
            return
        fi
    done
}

case "\$1" in
    deconfig|renew|bound)
        run_scripts \$UDHCPC/pre-\$1
        \$1
        run_scripts \$UDHCPC/post-\$1
        ;;
    leasefail)
        echo "udhcpc failed to get a DHCP lease" >&2
        ;;
    nak)
        echo "udhcpc received DHCP NAK" >&2
        ;;
    *)
        echo "Error: this script should be called from udhcpc" >&2
        exit 1
        ;;
esac
exit 0
END
    mkdir -p $1/var/lib
}

_gen_profile__() {
    cat_file $1/etc/profile 0444 << END || return 3
alias ll='ls -l'
export IGNOREEOF=3
export PS1='\\H:\\w\\$ '
END
}

_gen_fstab__() {
    cat_file $1/etc/fstab 0444 << END || return 3
none            /proc           proc            defaults                                0 0
none            /dev            devtmpfs        defaults                                0 0
none            /dev/pts        devpts          defaults                                0 0
none            /sys            sysfs           defaults                                0 0
none            /tmp            tmpfs           nodev,nosuid,noexec,size=500%           0 0
none            /run            tmpfs           nodev,nosuid,noexec,size=20%,mode=0755  0 0
none            /shared         tmpfs           nodev,nosuid,noexec,size=1m             0 0
# /dev/mapper/<name>@[CIPHER] uses /dev/<name> as the underlying block device
# - @CIPHER is of the form @CHAIN_MODE+MAC (e.g., @xts+hmac_sha384)
# - Append +ae to @CIPHER to select authenticated encryption
# - E.g.,   /dev/mapper/vda@                => xts(aes)-plain64 + sha384
#           /dev/mapper/vda@cbc             => cbc(aes)-plain64 + sha384
#           /dev/mapper/vda@+hmac_sha512    => xts(aes)-plain64 + hmac(sha512)
#           /dev/mapper/vda@xts+cmac        => xts(aes)-plain64 + cmac
#           /dev/mapper/vda@+ae             => authenc(cmac(aes),xts(aes))-random
#           /dev/mapper/vda@++ae            => xts(aes)-random
#           /dev/mapper/vda@+sha384+ae      => authenc(hmac(sha384),xts(aes))-random
#           /dev/mapper/vda@cbc+ae          => authenc(cmac(aes),cbc(aes))-random
/dev/mapper/vda@ none           swap            sw,discard                              0 0
# Instead of swap, filesystems are also supported on encrypted devices, e.g.,
# /dev/mapper/vda@ /run         ext4            discard                                 0 0
END
}

_gen_resolv.conf__() {
    test -z "$F" || rm -fv $1/etc/resolv.conf
}

# Generate /init and dependencies
gen_init() {
    test $# -lt 1 && {
        echo "Usage: gen_init INITRD_TREE [init|profile|fstab|resolv.conf|udhcpc]" >&2
        return 1
    }

    local readonly _tree__=$(realpath -es $1)
    test -z "$_tree__" && return 2
    shift

    local _force__=
    test $# -gt 0 && _force__=1 || set -- init profile fstab resolv.conf

    for f; do
        F=${F:-$_force__} _gen_${f}__ $_tree__ || return 3
    done
}

cpio_initrd() {
    test $# -ne 1 && {
        echo "Usage: cpio_initrd INITRD_TREE > INITRD_IMAGE" >&2
        return 1
    }

    test -t 1 && {
        echo "cpio_initrd: refusing to write CPIO archive to terminal" >&2
        return 2
    }

    for f in init sbin/init etc/init bin/init; do
        test -x $1/$f -a \! -d $1/$f && break
    done || {
        echo "cpio_initrd: init not found" >&2
        return 2
    }

    TZ=UTC find $1 ${T:+-exec touch -chmt ${T/#.*/0001010000} '{}' ';'} -printf '%P\n' -o -quit |
    sort -us |
    cpio --reproducible -oVH newc -R +0:+0 -D $1
}

create_initrd() {
    test -z "$1" -o $# -gt 2 && {
        echo "Usage: create_initrd INITRD_TREE [INITRD_IMAGE]" >&2
        return 1
    }

    set -- $(realpath -s $1) $2
    test -d $1 || {
        echo "create_initrd: $1 doesn't exist or isn't a directory" >&2
        return 2
    }

    set -- $1 ${2:-initrd-${1##*/}.cpio}
    test "${2##*/}" == "$2" && set -- $1 ${1%/*}/$2
    case x$C in
        x) cpio_initrd $1 > $2;;
        xgz|xbz2|xxz) cpio_initrd $1 | ${C}_initrd > $2.$C;;
        *) echo "create_initrd: unsupported compression program -- $C" >&2 && return 1;;
    esac && echo "Created $2${C:+.$C}"
}

abs2rellinks() {
    find $1 -type l -lname '/*' -exec sh -c "
        for source; do
            target=\$(readlink \$source)
            ln -srfn $1\$target \$source
        done" '{}' '+'
}

gen_initrd() {
    test -z "$2" && {
        echo "Usage: gen_initrd INITRD_TREE CONTAINER [SOURCE_DIR]..." >&2
        return 1
    }

    local readonly DIR=$(realpath -ms --relative-to=. $1)
    shift

    mkdir -p $DIR || return 2
    tar_container "$@" | tar -C $DIR -ix || return 2
    rm -rf $DIR/proc $DIR/dev $DIR/sys
    for d in $DIR/*; do
        test -d $d && rmdir --ignore-fail-on-non-empty $d
    done

    abs2rellinks $DIR && gen_init $DIR || return $?

    create_initrd $DIR
}

find_samefile() {
    test -z "$1" && {
        echo "Usage: find_samefile FILE [DIR] [FIND_ARG...]" >&2
        return 1
    }

    local readonly FILE=$(realpath -se $1)
    test -z "$FILE" && {
        echo "find_samefile: $1 doesn't exist" >&2
        return 2
    }
    shift

    local readonly DIR=$(realpath -se ${1:-${FILE%/*}})
    test -d $DIR || {
        echo "find_samefile: $DIR isn't a directory" >&2
        return 2
    }
    shift

    find $DIR -samefile $FILE \! -wholename $FILE "$@"
}

hard2symlinks() {
    test -z "$1" -o -n "$3" && {
        echo "Usage: hard2symlinks FILE [DIR]" >&2
        return 1
    }

    for f in $(find_samefile "$@"); do
        ln -srfv $1 $f
    done
}

xz_initrd() {
    xz --check=crc32 -9 "$@"
}

gz_initrd() {
    gzip -9 "$@"
}

bz2_initrd() {
    bzip2 -9 "$@"
}
