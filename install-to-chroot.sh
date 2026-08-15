#!/bin/bash
#
# Ideas and some parts from the original dgl-create-chroot (by joshk@triplehelix.org, modifications by jilles@stack.nl)
# More by <paxed@alt.org>
# More by Michael Andrew Streib <dtype@dtype.org>
# Licensed under the MIT License
# https://opensource.org/licenses/MIT

# autonamed chroot directory. Can rename.
DATESTAMP=`date +%Y%m%d-%H%M%S`
NAO_CHROOT="/opt/nethack/nethack.alt.org"
NETHACK_GIT="/opt/build/nethack/NAO-5.x"
# the user & group from dgamelaunch config file.
USRGRP="games:games"
# COMPRESS from include/config.h; the compression binary to copy. leave blank to skip.
COMPRESSBIN="/bin/gzip"
# fixed data to copy (leave blank to skip)
NH_GIT="/opt/build/nethack/NAO-5.x"
# HACKDIR from include/config.h; aka nethack subdir inside chroot
NHSUBDIR="nh500"
# VAR_PLAYGROUND from include/unixconf.h
NH_VAR_PLAYGROUND="/nh500/var/"
# END OF CONFIG
##############################################################################

errorexit()
{
    echo "Error: $@" >&2
    exit 1
}

findlibs()
{
  for i in "$@"; do
      if [ -z "`ldd "$i" | grep 'not a dynamic executable'`" ]; then
         echo $(ldd "$i" | awk '{ print $3 }' | egrep -v ^'\(' | grep lib)
         echo $(ldd "$i" | grep 'ld-linux' | awk '{ print $1 }')
      fi
  done
}

# install_atomic SRC DEST MODE [OWNER]
#
# 🔴 NEVER `cp` over a file in a live chroot. `cp` opens the destination
# O_TRUNC, so an existing file is briefly zero-length WHILE games hold it open:
#   - every running nethack holds nh500/nhdat open (verified on e1, fd 3, all
#     live games) and reads level/lua data from it for the whole session, so a
#     truncating overwrite hands a live game a short read mid-play;
#   - for anything mmap'd, a demand fault past the shortened EOF is SIGBUS, and
#     nethack traps only SIGHUP and SIGXCPU -- so that is a LOST CHARACTER, not
#     a caught error. Measured on this box 2026-08-13 during the chroot lib
#     swap: `cp` over a mapped libc killed the probe in ~2s, rc=135.
#
# Stage alongside the target, then rename(2). A running process keeps its old
# inode as `(deleted)` and finishes on it; the next exec picks up the new file.
# Staging in the DESTINATION DIRECTORY is load-bearing -- rename is only atomic
# within a single filesystem, and a cross-device `mv` silently degrades to
# copy+unlink, which reintroduces exactly the window this exists to close.
# Mode and owner are set on the staged copy, so the file is never visible at
# the target path with the wrong permissions.
install_atomic()
{
  _src="$1"; _dst="$2"; _mode="$3"; _own="${4:-}"
  _tmp="$_dst.new.$$"
  cp "$_src" "$_tmp"    || errorexit "staging $_dst failed"
  chmod "$_mode" "$_tmp" || errorexit "chmod $_mode on staged $_dst failed"
  if [ -n "$_own" ]; then
    chown "$_own" "$_tmp" || errorexit "chown $_own on staged $_dst failed"
  fi
  # -T so a directory at $_dst can never turn this into a move INTO it.
  mv -T "$_tmp" "$_dst"  || errorexit "atomic rename into $_dst failed"
}

set -e

umask 022

echo "Creating inprogress and extrainfo directories"
mkdir -p "$NAO_CHROOT/dgldir/inprogress-nh500"
chown "$USRGRP" "$NAO_CHROOT/dgldir/inprogress-nh500"
mkdir -p "$NAO_CHROOT/dgldir/extrainfo-nh500"
chown "$USRGRP" "$NAO_CHROOT/dgldir/extrainfo-nh500"

echo "Making $NAO_CHROOT/$NHSUBDIR"
mkdir -p "$NAO_CHROOT/$NHSUBDIR"

NETHACKBIN="$NETHACK_GIT/src/nethack"
if [ -n "$NETHACKBIN" -a ! -e "$NETHACKBIN" ]; then
  errorexit "Cannot find NetHack binary $NETHACKBIN"
fi

if [ -n "$NETHACKBIN" -a -e "$NETHACKBIN" ]; then
  echo "Copying $NETHACKBIN"
  cd "$NAO_CHROOT/$NHSUBDIR"
  NHBINFILE="`basename $NETHACKBIN`-$DATESTAMP"
  # The binary itself is safe to plain-cp: $NHBINFILE is a NEW datestamped name,
  # so no inode a running game has mapped is touched. It is the SYMLINK swap
  # that has to be atomic -- `ln -fs` is unlink+symlink, and any login landing
  # in that window finds no `nethack` at all.
  cp "$NETHACKBIN" "$NHBINFILE"
  chown root:root "$NHBINFILE"
  chmod 755 "$NHBINFILE"
  ln -sfn "$NHBINFILE" "nethack.new.$$"
  mv -T "nethack.new.$$" nethack
  LIBS="$LIBS `findlibs $NETHACKBIN`"
  cd "$NAO_CHROOT"
fi

echo "Copying NetHack playground stuff"
# nhdat above all: every live game holds it open for the whole session.
install_atomic "$NETHACK_GIT/dat/nhdat"   "$NAO_CHROOT/$NHSUBDIR/nhdat"   644
install_atomic "$NETHACK_GIT/dat/symbols" "$NAO_CHROOT/$NHSUBDIR/symbols" 644
install_atomic "$NETHACK_GIT/dat/license" "$NAO_CHROOT/$NHSUBDIR/license" 644

echo "Copying sysconf file"
SYSCF="$NAO_CHROOT/$NHSUBDIR/sysconf"
install_atomic "$NETHACK_GIT/sys/unix/sysconf" "$SYSCF" 644

echo "Creating NetHack variable dir stuff."
mkdir -p "$NAO_CHROOT/$NHSUBDIR/var"
chown -R "$USRGRP" "$NAO_CHROOT/$NHSUBDIR/var"
mkdir -p "$NAO_CHROOT/$NHSUBDIR/var/save"
chown -R "$USRGRP" "$NAO_CHROOT/$NHSUBDIR/var/save"
mkdir -p "$NAO_CHROOT/$NHSUBDIR/var/save/backup"
chown -R "$USRGRP" "$NAO_CHROOT/$NHSUBDIR/var/save/backup"

touch "$NAO_CHROOT/$NHSUBDIR/var/logfile"
chown -R "$USRGRP" "$NAO_CHROOT/$NHSUBDIR/var/logfile"
touch "$NAO_CHROOT/$NHSUBDIR/var/perm"
chown -R "$USRGRP" "$NAO_CHROOT/$NHSUBDIR/var/perm"
touch "$NAO_CHROOT/$NHSUBDIR/var/record"
chown -R "$USRGRP" "$NAO_CHROOT/$NHSUBDIR/var/record"
touch "$NAO_CHROOT/$NHSUBDIR/var/xlogfile"
chown -R "$USRGRP" "$NAO_CHROOT/$NHSUBDIR/var/xlogfile"
touch "$NAO_CHROOT/$NHSUBDIR/var/livelog"
chown -R "$USRGRP" "$NAO_CHROOT/$NHSUBDIR/var/livelog"

RECOVER="$NETHACK_GIT/util/recover"

if [ -n "$RECOVER" -a -e "$RECOVER" ]; then
  echo "Copying $RECOVER"
  # recover is CODE, so it belongs next to the game binary, not in var/.
  # var/ is game DATA and is writable by the 'games' user the game drops to; an
  # executable in there can be replaced by a compromised game process and is then
  # run by an admin as root -- persistence + privesc. Same reason the game binary
  # itself is root:root 755. (nao-admin docs/chroot.md, K2's code-vs-data rule.)
  # Atomic too: an admin can be mid-`recover` on a crashed game while this runs.
  install_atomic "$RECOVER" "$NAO_CHROOT/$NHSUBDIR/recover" 755 root:root
  rm -f "$NAO_CHROOT/$NHSUBDIR/var/recover"   # clean up the old location
  LIBS="$LIBS `findlibs $RECOVER`"
  cd "$NAO_CHROOT"
fi

LIBS=`for lib in $LIBS; do echo $lib; done | sort | uniq`
echo "Copying libraries:" $LIBS
for lib in $LIBS; do
        # The chroot's curated lib layer -- and the etc/ld.so.conf that indexes it --
        # use /lib/... . On a merged-/usr host (Ubuntu 26.04 on e1) ldd reports
        # /usr/lib/x86_64-linux-gnu/..., and copying to that path verbatim builds a
        # duplicate lib tree inside the chroot instead of matching the real layout.
        # Strip a leading /usr so we land on the curated files; this is a no-op on a
        # non-merged host (e.g. e4's 16.04), where ldd already reports /lib/... .
        dest="${lib#/usr}"
        mkdir -p "$NAO_CHROOT`dirname $dest`"
        if [ -f "$NAO_CHROOT$dest" ]
        then
                echo "$NAO_CHROOT$dest already exists - skipping."
        else
                # Deliberately a plain cp, NOT install_atomic: this branch only
                # runs when the destination does not exist, so there is no inode
                # for a running game to have mapped and nothing to truncate.
                # Refreshing an EXISTING lib is a different job with a different
                # tool -- nao-admin scripts/refresh-chroot-libs.sh, which stages
                # and renames every file. Do not "fix" this into an overwrite.
                cp "$lib" "$NAO_CHROOT$dest"
                NEWLIBS=1
        fi
done

# Rebuild the chroot's ld.so.cache if we actually added a library. The cache is
# what makes the curated layer resolvable (the chroot has no ldconfig of its
# own), so a newly copied lib would otherwise be invisible to the loader.
if [ -n "$NEWLIBS" ]; then
        echo "New libraries copied - rebuilding chroot ld.so.cache"
        ldconfig -r "$NAO_CHROOT"
fi

echo "Finished."
