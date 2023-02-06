#!/bin/sh

# This is copy-and-pasted from parallel-exec, removing:
# - use of SB-APROF, SB-SPROF
# - vop usage counts, GC stop-the-world timing
# - shell tests
# - anything else extraneous to running the tests.
# Obviously it would be better if some of this
# logic could be shared, especially the
# CHOOSE-ORDER function.

if [ $# -ne 1 ]
then
    echo $0: Need arg
    exit 1
fi

logdir=${SBCL_PAREXEC_TMP:-$HOME}/sbcl-test-logs-$$
echo ==== Writing logs to $logdir ====
junkdir=${SBCL_PAREXEC_TMP:-/tmp}/junk
mkdir -p $junkdir $logdir

case `uname` in
    CYGWIN* | WindowsNT | MINGW* | MSYS*)
        echo ";; Using -j$1"
        echo "LOGDIR=$logdir" >$logdir/Makefile
        ../run-sbcl.sh --script genmakefile.lisp >>$logdir/Makefile
        exec $GNUMAKE -k -j $1 -f $logdir/Makefile
        ;;
esac

export TEST_DIRECTORY SBCL_HOME
TEST_DIRECTORY=$junkdir SBCL_HOME=../obj/sbcl-home exec ../src/runtime/sbcl \
  --noinform --core ../output/sbcl.core \
  --no-userinit --no-sysinit --noprint --disable-debugger $logdir $* \
  < benchmark.lisp
