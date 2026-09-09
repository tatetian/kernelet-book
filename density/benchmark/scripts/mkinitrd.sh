#!/bin/bash
# mkinitrd.sh <name> <command run inside the rootfs>: builds run/<name>.cpio whose init mounts the squashfs root and runs the command.
S=$(dirname "$(readlink -f "$0")"); NAME=$1; CMD=$2; D=$S/run/initrd-$NAME; rm -rf $D; mkdir -p $D/bin $D/dev $D/proc $D/sys $D/newroot
cp $S/busybox $D/bin/busybox; for a in sh mount chroot sleep cat; do ln -sf busybox $D/bin/$a; done
cat > $D/init <<'EOI'
#!/bin/sh
mount -t devtmpfs devtmpfs /dev
mount -t proc none /proc
mount -t sysfs none /sys
mount -t squashfs -o ro /dev/vda /newroot
mount --move /dev /newroot/dev
mount --move /proc /newroot/proc
mount --move /sys /newroot/sys
exec 0</newroot/dev/console 1>/newroot/dev/console 2>&1
cd /newroot
CMD="$(cat /cmd.sh)"
exec /bin/chroot /newroot /bin/sh -c "$CMD"
EOI
chmod +x $D/init
if [ -f "$CMD" ]; then cp "$CMD" $D/cmd.sh; else printf '%s\n' "$CMD" > $D/cmd.sh; fi
(cd $D && find . | cpio -o -H newc 2>/dev/null) > $S/run/$NAME.cpio
ls -la $S/run/$NAME.cpio | awk '{print $5, $9}'
