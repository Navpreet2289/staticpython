#! /bin/bash --
#
# build.sh -- compile StaticPython from sources
# by pts@fazekas.hu at Wed Aug 11 16:49:32 CEST 2010
#
# Example invocation: ./build.sh
# Example invocation: ./compie.sh stackless
# This script has been tested on Ubuntu Hardy, should work on any Linux system.
#
# TODO(pts): document: ar cr ../stackless2.7-static.build/cross-compiler-i686/lib/libevent_evhttp.a http.o listener.o bufferevent_sock.o

if true; then  # Make the shell script editable while it's executing.

test "${0%/*}" != "$0" && cd "${0%/*}"

# Make sure we fail unless weuse ./busybox for all non-built-in commands.
export PATH=/dev/null

if test "$BASH_VERSION"; then
  unset BASH_VERSION
  exec ./busybox sh -- "$0" "$@"
fi

set -e  # Abort on error.

test -d busybox.bin || ./busybox mkdir busybox.bin
for F in cp mv rm sleep touch mkdir tar expr sed awk ls pwd test cmp diff \
         sort cat head tail chmod chown uname basename tr find grep; do
  ./busybox rm -f busybox.bin/"$F"
  ./busybox ln -s ../busybox busybox.bin/"$F"
done
# Good grep for configure.
./busybox rm -f busybox.bin/make; ./busybox ln -s ../make busybox.bin/make
./busybox rm -f busybox.bin/perl; ./busybox ln -s ../perl busybox.bin/perl
export PATH="$PWD/busybox.bin"
export SHELL="$PWD/busybox.bin/sh"

# ---

INSTS_BASE="bzip2-1.0.5.inst.tbz2 ncurses-5.6.inst.tbz2 readline-5.2.inst.tbz2 sqlite-3.7.0.1.inst.tbz2 zlib-1.2.3.3.inst.tbz2"

if test "$1" = stackless; then
  TARGET=stackless2.7-static
  PYTHONTBZ2=stackless-271-export.tar.bz2
  IS_CO=
  shift
elif test "$1" = stacklessco; then
  TARGET=stacklessco2.7-static
  PYTHONTBZ2=stackless-271-export.tar.bz2
  IS_CO=1
  shift
else
  TARGET=python2.7-static
  PYTHONTBZ2=Python-2.7.tar.bz2
  IS_CO=
fi

if test $# = 0; then
  # Don't include betry here.
  STEPS="initbuilddir extractinst configure patchsetup patchimport patchgetpath patchsqlite makeminipython patchsyncless patchgevent patchgeventmysql patchconcurrence makepython buildlibzip buildtarget"
else
  STEPS="$*"
fi

if test "$IS_CO"; then
  INSTS="$INSTS_BASE libevent2-2.0.10.inst.tbz2"
else
  INSTS="$INSTS_BASE"
fi

BUILDDIR="$TARGET.build"
PBUILDDIR="$PWD/$BUILDDIR"
# ./configure uses $CC, $AR and $RANLIB to generate the Makefile
export CC="$PBUILDDIR/cross-compiler-i686/bin/i686-gcc -static -fno-stack-protector"
export AR="$PBUILDDIR/cross-compiler-i686/bin/i686-ar"
export RANLIB="$PWD/$BUILDDIR/cross-compiler-i686/bin/i686-ranlib"

echo "Running in directory: $PWD"
echo "Building target: $TARGET"
echo "Building in directory: $BUILDDIR"
echo "Using Python source distribution: $PYTHONTBZ2"
echo "Will run steps: $STEPS"
echo "Is adding coroutine libraries: $IS_CO"
echo

initbuilddir() {
  rm -rf "$BUILDDIR"
  mkdir "$BUILDDIR"
  ( cd "$BUILDDIR" || exit "$?"
    tar xjvf ../"$PYTHONTBZ2" || exit "$?"
  ) || exit "$?"
  ( cd "$BUILDDIR" || exit "$?"
    mv */* . || exit "$?"
  ) || exit "$?"
  ( cd "$BUILDDIR" || exit "$?"
    mkdir cross-compiler-i686
    cd cross-compiler-i686
    tar xjvf ../../gcxbase.inst.tbz2 || exit "$?"
    tar xjvf ../../gcc.inst.tbz2 || exit "$?"
    tar xjvf ../../gcxtool.inst.tbz2 || exit "$?"
  ) || exit "$?"
  ( cd "$BUILDDIR/Modules" || exit "$?"
    tar xzvf ../../greenlet-0.3.1.tar.gz
  ) || exit "$?"
}

extractinst() {
  for INSTTBZ2 in $INSTS; do
    ( cd "$BUILDDIR/cross-compiler-i686" || exit "$?"
      tar xjvf ../../"$INSTTBZ2" || exit "$?"
    ) || exit "$?"
  done
}

# Remove dependeny on ASDLGEN
#remove_asdlgen() {
#}

configure() {
  ( cd "$BUILDDIR" || exit "$?"
    # TODO(pts): Make sure x86 is detected (not x86_64).
    # This removal makes Python-ast.c not autogenerated. Autogeneration would
    # need a working Python binary, which we don't have yet.
    perl -pi -e '$_="" if /ASDLGEN/' Makefile.pre.in
    ./configure --disable-shared --disable-ipv6 || exit "$?"
    #remove_asdlgen
  ) || exit "$?"
}

patchsetup() {
  # This must be run after the configure step, because configure overwrites
  # Modules/Setup
  cp Modules.Setup.2.7.static "$BUILDDIR/Modules/Setup"
  sleep 2  # Wait 2 seconds after the configure script creating Makefile.
  touch "$BUILDDIR/Modules/Setup"
  # We need to run `make Makefile' to rebuild it using our Modules/Setup
  ( cd "$BUILDDIR" || exit "$?"
    make Makefile || exit "$?"
    #remove_asdlgen || exit "$?"
  ) || exit "$"
}

patchimport() {
  # This patch is idempotent.
  perl -pi~ -e 's@#ifdef HAVE_DYNAMIC_LOADING(?!_NOT)@#ifdef HAVE_DYNAMIC_LOADING_NOT  /* StaticPython */@g' "$BUILDDIR"/Python/import.c "$BUILDDIR"/Python/importdl.c
}

patchgetpath() {
  # This patch is idempotent.
  # TODO(pts): Make sure that the source string is there for patching.
  perl -pi~ -0777 -e 's@\s+static\s+void\s+calculate_path(?!   )\s*\(\s*void\s*\)\s*{@\n\nstatic void calculate_path(void);  /* StaticPython */\nstatic void calculate_path_not(void) {@g' "$BUILDDIR"/Modules/getpath.c
  if ! grep -q StaticPython-appended "$BUILDDIR/Modules/getpath.c"; then
    cat calculate_path.static.c >>"$BUILDDIR/Modules/getpath.c"
  fi
}

patchsqlite() {
  # This patch is idempotent.
  if ! grep '^#define MODULE_NAME ' "$BUILDDIR/Modules/_sqlite/util.h"; then
    perl -pi~ -0777 -e 's@\n#define PYSQLITE_UTIL_H\n@\n#define PYSQLITE_UTIL_H\n#define MODULE_NAME "_sqlite3"  /* StaticPython */\n@' "$BUILDDIR/Modules/_sqlite/util.h"
  fi    
  for F in "$BUILDDIR/Modules/_sqlite/"*.c; do
    if ! grep -q '^#include "util.h"' "$F"; then
      perl -pi~ -0777 -e 's@\A@#include "util.h"  /* StaticPython */\n@' "$F"
    fi    
  done
}

generate_loader_py() {
  local CEXT_MODNAME="$1"
  local PY_MODNAME="$2"
  local PY_FILENAME="Lib/${PY_MODNAME//.//}.py"
  : Generating loader "$PY_FILENAME"
  echo "import sys; import $CEXT_MODNAME; sys.modules[__name__] = $CEXT_MODNAME" >"$PY_FILENAME" || return "$?"
}

patch_and_copy_cext() {
  local SOURCE_C="$1"
  local TARGET_C="$2"
  local CEXT_MODNAME="${TARGET_C%.c}"
  export CEXT_MODNAME="${CEXT_MODNAME##*/}"
  export CEXT_MODNAME="${CEXT_MODNAME//._/_}"
  export CEXT_MODNAME="${CEXT_MODNAME//./_}"
  export CEXT_MODNAME=_"${CEXT_MODNAME#_}"
  : Copying and patching "$SOURCE_C" to "$TARGET_C"
  <"$SOURCE_C" >"$TARGET_C" perl -0777 -pe '
    s@^(PyMODINIT_FUNC) +\w+\(@$1 init$ENV{CEXT_MODNAME}(@mg;
    s@( Py_InitModule\d*)\("\w[\w.]*",@$1("$ENV{CEXT_MODNAME}",@g;
    # Cython version of the one below.
    s@( Py_InitModule\d*\(__Pyx_NAMESTR\()"\w[\w.]*"\),@$1"$ENV{CEXT_MODNAME}"),@g;
  ' || return "$?"
}

enable_module() {
  local CEXT_MODNAME="$1"
  export CEXT_MODNAME
  : Enabling module: "$CEXT_MODNAME"
  grep -qE "^#?$CEXT_MODNAME " Modules/Setup || return "$?"
  perl -0777 -pi -e 's@^#$ENV{CEXT_MODNAME} @$ENV{CEXT_MODNAME} @mg' Modules/Setup || return "$?"
}

patchsyncless() {
  test "$IS_CO" || return 0
  ( cd "$BUILDDIR" || return "$?"
    rm -rf syncless-* syncless.dir Lib/syncless Modules/syncless || return "$?"
    tar xzvf ../syncless-0.20.tar.gz || return "$?"
    mv syncless-0.20 syncless.dir || return "$?"
    mkdir Lib/syncless Modules/syncless || return "$?"
    cp syncless.dir/syncless/*.py Lib/syncless/ || return "$?"
    generate_loader_py _syncless_coio syncless.coio || return "$?"
    patch_and_copy_cext syncless.dir/coio_src/coio.c Modules/syncless/_syncless_coio.c || return "$?"
    cp syncless.dir/coio_src/coio_minihdns.c \
       syncless.dir/coio_src/coio_minihdns.h \
       syncless.dir/coio_src/coio_c_*.h \
       Modules/syncless/ || return "$?"
    enable_module _syncless_coio || return "$?"
  ) || return "$?"
}

patchgevent() {
  test "$IS_CO" || return 0
  ( cd "$BUILDDIR" || return "$?"
    rm -rf gevent-* gevent.dir Lib/gevent Modules/gevent || return "$?"
    tar xzvf ../gevent-0.13.2.tar.gz || return "$?"
    mv gevent-0.13.2 gevent.dir || return "$?"
    mkdir Lib/gevent Modules/gevent || return "$?"
    cp gevent.dir/gevent/*.py Lib/gevent/ || return "$?"
    rm -f gevent.dir/gevent/win32util.py || return "$?"
    generate_loader_py _gevent_core gevent.core || return "$?"
    patch_and_copy_cext gevent.dir/gevent/core.c Modules/gevent/_gevent_core.c || return "$?"
    cat >Modules/gevent/libevent.h <<'END'
/**** pts ****/
#include "sys/queue.h"
#define LIBEVENT_HTTP_MODERN
#include "event2/event.h"
#include "event2/event_struct.h"
#include "event2/event_compat.h"
#include "event2/http.h"
#include "event2/http_compat.h"
#include "event2/http_struct.h"
#include "event2/buffer.h"
#include "event2/buffer_compat.h"
#include "event2/dns.h"
#include "event2/dns_compat.h"
#define EVBUFFER_DRAIN evbuffer_drain
#define EVHTTP_SET_CB  evhttp_set_cb
#define EVBUFFER_PULLUP(BUF, SIZE) evbuffer_pullup(BUF, SIZE)
#define current_base event_global_current_base_
#define TAILQ_GET_NEXT(X) TAILQ_NEXT((X), next)
extern void *current_base;
END
    enable_module _gevent_core || return "$?"
  ) || return "$?"
}

patchgeventmysql() {
  test "$IS_CO" || return 0
  ( cd "$BUILDDIR" || return "$?"
    rm -rf geventmysql-* geventmysql.dir Lib/geventmysql Modules/geventmysql || return "$?"
    tar xjvf ../geventmysql-20110201.tbz2 || return "$?"
    mv gevent-MySQL geventmysql.dir || return "$?"
    mkdir Lib/geventmysql Modules/geventmysql || return "$?"
    cp geventmysql.dir/lib/geventmysql/*.py Lib/geventmysql/ || return "$?"
    generate_loader_py _geventmysql_mysql geventmysql._mysql || return "$?"
    patch_and_copy_cext geventmysql.dir/lib/geventmysql/geventmysql._mysql.c Modules/geventmysql/geventmysql._mysql.c || return "$?"
    enable_module _geventmysql_mysql || return "$?"
  ) || return "$?"
}

run_pyrexc() {
  PYTHONPATH="$PWD/Lib:$PWD/pyrex.dir" "$PBUILDDIR"/minipython -S -W ignore::DeprecationWarning -c "from Pyrex.Compiler.Main import main; main(command_line=1)" "$@"
}

#** Equivalent to zip -9r "$@"
#** Usage: run_mkzip filename.zip file_or_dir ...
run_mkzip() {
  local PYTHON="$PBUILDDIR"/python
  test -f "$PBUILDDIR"/minipython && PYTHON="$PBUILDDIR"/minipython
  PYTHONPATH="$PWD/Lib" "$PYTHON" -S -c 'if 1:
  import os
  import os.path
  import stat
  import sys
  import zipfile
  def All(filename):
    s = os.lstat(filename)
    assert not stat.S_ISLNK(s.st_mode), filename
    if stat.S_ISDIR(s.st_mode):
      for entry in os.listdir(filename):
        for filename2 in All(os.path.join(filename, entry)):
          yield filename2
    else:
      yield filename
  zip_filename = sys.argv[1]
  zipfile.zlib.Z_DEFAULT_COMPRESSION = 9  # Maximum effort.
  z = zipfile.ZipFile(zip_filename, "w", compression=zipfile.ZIP_DEFLATED)
  for filename in sys.argv[2:]:
    for filename2 in All(filename):
      z.write(filename2)
  z.close()' "$@"
}

patchconcurrence() {
  test "$IS_CO" || return 0
  ( cd "$BUILDDIR" || return "$?"
    rm -rf concurrence-* concurrence.dir pyrex.dir Lib/concurrence Modules/concurrence || return "$?"
    tar xzvf ../concurrence-0.3.1.tar.gz || return "$?"
    mv concurrence-0.3.1 concurrence.dir || return "$?"
    tar xzvf ../Pyrex-0.9.9.tar.gz || return "$?"
    mv Pyrex-0.9.9 pyrex.dir || return "$?"
    mkdir Lib/concurrence Modules/concurrence || return "$?"
    # TODO(pts): Fail if any of the pipe commands fail.
    (cd concurrence.dir/lib && tar c $(find concurrence -type f -iname '*.py')) |
        (cd Lib && tar x) || return "$?"

    generate_loader_py _concurrence_event concurrence._event || return "$?"
    cat >Modules/concurrence/event.h <<'END'
/**** pts ****/
#include <event2/event.h>
#include <event2/event_struct.h>
#include <event2/event_compat.h>
END
    run_pyrexc concurrence.dir/lib/concurrence/concurrence._event.pyx || return "$?"
    patch_and_copy_cext concurrence.dir/lib/concurrence/concurrence._event.c Modules/concurrence/concurrence._event.c || return "$?"
    enable_module _concurrence_event || return "$?"

    generate_loader_py _concurrence_io_io concurrence.io._io || return "$?"
    run_pyrexc concurrence.dir/lib/concurrence/io/concurrence.io._io.pyx || return "$?"
    patch_and_copy_cext concurrence.dir/lib/concurrence/io/concurrence.io._io.c Modules/concurrence/concurrence.io._io.c || return "$?"
    cp concurrence.dir/lib/concurrence/io/io_base.c \
       concurrence.dir/lib/concurrence/io/io_base.h \
       Modules/concurrence/ || return "$?"
    enable_module _concurrence_io_io || return "$?"

    generate_loader_py _concurrence_database_mysql_mysql concurrence.database.mysql._mysql || return "$?"
    run_pyrexc -I concurrence.dir/lib/concurrence/io concurrence.dir/lib/concurrence/database/mysql/concurrence.database.mysql._mysql.pyx || return "$?"
    patch_and_copy_cext concurrence.dir/lib/concurrence/database/mysql/concurrence.database.mysql._mysql.c Modules/concurrence/concurrence.database.mysql._mysql.c || return "$?"
    enable_module _concurrence_database_mysql_mysql || return "$?"

  ) || return "$?"
}

makeminipython() {
  test "$IS_CO" || return 0
  ( cd "$BUILDDIR" || return "$?"
    # TODO(pts): Disable co modules in Modules/Setup
    make python || return "$?"
    mv -f python minipython
    cross-compiler-i686/bin/i686-strip -s minipython
  ) || return "$?"
}

makepython() {
  ( cd "$BUILDDIR" || return "$?"
    make python || return "$?"
  ) || return "$?"
}

buildlibzip() {
  # This step doesn't depend on makepython.
  ( set -ex
    IFS='
'
    cd "$BUILDDIR" ||
    (test -f xlib.zip && mv xlib.zip xlib.zip.old) || exit "$?"
    rm -rf xlib || exit "$?"
    cp -a Lib xlib || exit "$?"
    rm -f $(find xlib -iname '*.pyc') || exit "$?"
    rm -f xlib/plat-*/regen
    rm -rf xlib/email/test xlib/bdddb xlib/ctypes xlib/distutils \
           xlib/idlelib xlib/lib-tk xlib/lib2to3 xlib/msilib \
           xlib/plat-aix* xlib/plat-atheos xlib/plat-beos* \
           xlib/plat-darwin xlib/plat-freebsd* xlib/plat-irix* \
           xlib/plat-mac xlib/plat-netbsd* xlib/plat-next* \
           xlib/plat-os2* xlib/plat-riscos xlib/plat-sunos* \
           xlib/plat-unixware xlib/test xlib/*.egg-info || exit "$?"
    cp ../site.static.py xlib/site.py || exit "$?"
    cd xlib || exit "$?"
    rm -f *~ */*~ || exit "$?"
    rm -f ../xlib.zip
    run_mkzip ../xlib.zip * || exit "$?"
  ) || exit "$?"
}

buildtarget() {
  cp "$BUILDDIR"/python "$BUILDDIR/$TARGET"
  "$BUILDDIR"/cross-compiler-i686/bin/i686-strip -s "$BUILDDIR/$TARGET"
  cat "$BUILDDIR"/xlib.zip >>"$BUILDDIR/$TARGET"
  cp "$BUILDDIR/$TARGET" "$TARGET"
  ls -l "$TARGET"
}

betry() {
  # This step is optional. It tries the freshly built binary.
  mkdir -p bch be/bardir
  echo "print 'FOO'" >be/foo.py
  echo "print 'BAR'" >be/bardir/bar.py
  cp "$TARGET" be/sp
  cp "$TARGET" bch/sp
  export PYTHONPATH=bardir
  unset PYTHONHOME
  #unset PYTHONPATH
  (cd be && ./sp) || exit "$?"
}

for STEP in $STEPS; do
  echo "Running step: $STEP"
  set -ex
  $STEP
  set +ex
done
echo "OK running steps: $STEPS"

exit 0

fi
