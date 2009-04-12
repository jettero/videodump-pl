#!/bin/bash

VERSION=`grep our..VERSION videodump.pl | cut '-d"' -f2`

if ! grep $VERSION- debian/changelog >/dev/null; then
    echo debian/changelog does not seem to contain the videodump.pl version: $VERSION
    exit 1
fi

bdir=tmp/videodump-pl-$VERSION
odir=$bdir.orig
tdir=`basename $odir`

set -e

## echo $bdir $odir $tdir; exit

rm -rf tmp
mkdir -vp $odir
cp -va videodump.pl README LICENSE gpl-3.0.txt.gz $odir
(cd tmp; tar -zcvvf videodump-pl_$VERSION.orig.tar.gz $tdir)
cp -va $odir $bdir
cp -va debian $bdir
#(cd $bdir; debuild)
