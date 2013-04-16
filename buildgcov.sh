#! /bin/sh

basedir="$HOME/Test-Smoke"
mydir="$basedir/CoreSmokeCoverage"
builddir="$basedir/perl-current-gcov"

# Set vars for all the steps
GCB_DBG=0
GCB_RSYNC=1
GCB_BUILD=1
GCB_MAKE=1
GCB_TEST=1
GCB_GATHER=1
GCB_COVER=1
GCB_ARCHIVE=1
GCB_PUSH=0
DBG_SYM=""
for argv
    do case $argv in
        -dbg)         GCB_DBG=1     ;;
        -nosync)      GCB_RSYNC=0   ;;
        -nobuild)     GCB_BUILD=0   ;;
        -nomake)      GCB_MAKE=0    ;;
        -notest)      GCB_TEST=0    ;;
        -nogather)    GCB_GATHER=0  ;;
        -nocover)     GCB_COVER=0   ;;
        -noarchive)   GCB_ARCHIVE=0 ;GCB_PUSH=0 ;;
        -push)        GCB_PUSH=1    ;;
        -archiveonly) GCB_RSYNC=0; GCB_BUILD=0; GCB_MAKE=0; GCB_TEST=0;
                      GCB_COVER=0; GCB_GATHER=0 ;;
        -debug)       DBG_SYM="GCB_RSYNC GCB_BUILD GCB_MAKE GCB_TEST"
                      DBG_SYM="$DBG_SYM GCB_GATHER GCB_COVER GCB_ARCHIVE"
                      DBG_SYM="$DBG_SYM GCB_PUSH" ;;
        -*)           if [ "$argv" == "--help" -o "$argv" == "-h" ] ; then
                          echo ""
                      else
                          echo "Unknown argument '$argv'"
                      fi
                      cat <<EOF && exit ;;
Usage: $0 [options]
  -dbg        Add the -DDEBUGGING=both switch to Configure

  -nosync     Don't sync the source-tree
  -nobuild    Don't call 'make perl.gcov'
  -nomake     Don't call 'make'
  -notest     Don't call 'make test'
  -nogather   Don't gather all the gcov information
  -nocover    Don't run Devel::Cover's cover
  -noarchive  Don't create the tarball (implies -nopush)
  -push       push the tarball to ztreet
EOF
    esac
done


# Debug info
for sym in $DBG_SYM ; do
    val='$'$sym
    val=`eval echo $val`
    echo "\$$sym=$val"
done

if [ "$GCB_DBG" = "1" ] ; then builddir="${builddir}-DBG" ; fi
echo "Running gcov from '$builddir'"

if [ ! -d $builddir ] ; then
    echo "Create '$builddir'"
    mkdir -p "$builddir"
fi
# set the flags needed for a gcov build
gcovldflags="-fprofile-arcs"
gcovccflags="-fprofile-arcs -ftest-coverage"

cd $builddir

if [ "$GCB_RSYNC" = "1" ] ; then
  echo "rsync with bleadperl"
  rsync -azq --delete perl5.git.perl.org::perl-current .

  echo "patching MakeMaker"
  perl -pi -e 's/(my \$header_dir = )(\$self->\{PERL_SRC\})/$1\$ENV{PERL_SRC} || $2/' cpan/ExtUtils-MakeMaker/lib/ExtUtils/MM_Any.pm
fi

export PERL_SRC=$builddir

logf="$mydir/log_buildgcov.log"
echo "gcov run for `cat $builddir/.patch`" > "$logf"
if [ "$GCB_BUILD" = "1" ] ; then
    if [ "$GCB_DBG" = "1" ] ; then
        opt="-DDEBUGGING=both"
    else
        opt=""
    fi

    my_lddlflags="$gcovldflags -shared"
    echo "#name=configure ./Configure $opt" >> "$logf"
    sh ./Configure -des -Dusedevel $opt                 \
                   -A prepend:ccflags="$gcovccflags"    \
                   -A prepend:ldflags="$gcovldflags"    \
                   -A prepend:lddlflags="$my_lddlflags" \
                   -Dsiteprefix="$builddir"             \
                   -Dsitelib="$builddir/lib"            \
                   -Dvendorprefix="$builddir"           \
                   -Dvendorlib="$builddir/lib"          \
                   -Dprefix="$builddir"                 \
                   -Dextras='Devel::Cover'              >> "$logf" 2>&1

# build the special binary and copy it to the default
    echo "#name=makeperlgcov make perl.gcov" >> "$logf"
    make perl.gcov >> "$logf" 2>&1
    cp -v perl.gcov perl
fi

# To help Devel::Cover install, we skip the tests completely
echo "Fixing Makefile -Dextras (do not run tests)"
perl -i.withextrastest -pe "s/'\@ARGV&&make\(\@ARGV\)'/'\@ARGV&&notest(install => \@ARGV)'/" Makefile
perl -i.withextrastest -pe "s/'\@ARGV&&test\(\@ARGV\)'/'1'/" Makefile
perl -i.withextrastest -pe "s/'\@ARGV&&install\(\@ARGV\)'/'1'/" Makefile

# Copy a pre-cooked CPAN config to help 'Dextras='
# make will build all modules and invoke CPAN to build Devel::Cover
if [ "$GCB_MAKE" = "1" ] ; then
    echo "#name=make make" >> "$logf"
    cpanos=`uname -s`
    cp -v "$mydir/CPAN-Config-$cpanos.pm" lib/CPAN/Config.pm
    if [ "$GCB_DBG" = "1" ] ; then
        perl -i.bak -pe '/build_dir/ && s!(/perl-current-gcov)/!$1-DBG/!' \
                        lib/CPAN/Config.pm
    fi
    DEVEL_COVER_NO_COVERAGE=1 make >> "$logf" 2>&1
fi

coverdir=`ls "$builddir/ext" | grep Devel-Cover`
incbase="$builddir/ext/$coverdir/blib"
usecover=-MDevel::Cover=-ignore,\\.t$,-inc,/does/not/exist
#inccover="-I$incbase/lib -I$incbase/arch"
inccover=""

if [ "$GCB_TEST" = "1" ] ; then
    echo "make test_prep"
    make test_prep
    echo "cd t; ./perl $inccover $usecover harness"
    echo "#name=maketestharness make test_harness" >> "$logf"
    export LD_LIBRARY_PATH=`pwd`; cd t; ./perl $inccover $usecover harness >> "$logf" 2>&1
#   HARNESS_PERL_SWITCHES="$inccover $usecover" make test_harness >> "$logf" 2>&1
fi

# here we gather the coverage data
if [ "$GCB_GATHER" = "1" ] ; then
    cd "$builddir"
    echo "Start gathering from `pwd`"
    execindir="$mydir/exec-in-dir"

    find "$builddir" -type f -name "*.c"    -exec "$execindir" {} gcov {} \;

    #PERL5LIB="$incbase/lib:$incbase/arch" \
        find "$builddir" -type f -name "*.gcov" \
             -exec ./perl -Ilib "$incbase/script/gcov2perl" \
                          -db "$builddir/t/cover_db" {} \;
fi

if [ "$GCB_COVER" = "1" ] ; then
    if [ -d "$mydir/perlcover" ] ; then rm -rf "$mydir/perlcover" ; fi
    mkdir "$mydir/perlcover"
    echo "PERL5LIB='$incbase/lib:$incbase/arch' ../perl -I../lib $inccover $incbase/script/cover"
    cd "$builddir/t"
    #PERL5LIB="$incbase/lib:$incbase/arch" \
        ../perl -I../lib ../bin/cover" \
               -outputdir "$mydir/perlcover" cover_db >> "$logf" 2>&1
fi

if [ "$GCB_ARCHIVE" = "1" ] ; then
    cd "$mydir"
    "$builddir/perl" "-I$builddir/lib" -V > "$mydir/perlcover/dashV.txt"
    perl -MHTML::Entities -i.0 -pe 'encode_entities($_)' $logf
    perl -i.1 -pe 's!^#name=(\S+) (.+)!<a name="$1"></a><h3>$2</h3>!' $logf
    cp -v $logf perlcover/
    cp -v index.shtml perlcover/

    cd perlcover/
    perl -ne '/>(?:Total|file)\b/ and print' coverage.html > covtotal.inc
    cd ..

    my_ver=perlcover`cat "$builddir/.patch" | perl -ane 'print $F[-1]'`
    if [ "$GCB_DBG" = "1" ] ; then my_ver="${my_ver}DBG" ; fi
    my_arch="$my_ver.tbz"
    mv perlcover $my_ver
    echo "Create '$my_arch'"
    tar -cjf "$my_arch" "$my_ver/"

    if [ -d "$my_ver" ] ; then rm -rf "$my_ver" ; fi

    if [ "$GCB_PUSH" = "1" ] ; then
        phost=ztreet.xs4all.nl
        pdir=/data/apache/test-smoke/htdocs/pcarchive/
        scp "$my_arch" "$phost:$pdir"
        my_script="cd $pdir.. ;tar -xjf pcarchive/$my_arch"
        my_script="$my_script ;rm -rf perlcover ;ln -s $my_ver perlcover"
        echo "ssh $phost '$my_script'"
        ssh "$phost" "$my_script"
    fi
fi
