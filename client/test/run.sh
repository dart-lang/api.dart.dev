#!/bin/bash
# Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

# Usage: call directly in the commandline as test/run.sh ensuring that you have
# both 'dart' and 'DumpRenderTree' in your path. Filter tests by passing a
# pattern as an argument to this script.

# TODO(jacobr): replace with a real test runner

# bail on error
set -e

# print commands executed by this script
# set -x

DIR=$( cd $( dirname "${BASH_SOURCE[0]}" ) && pwd )
DART_FLAGS="--checked"
TEST_PATTERN=$1

function fail {
  return 1
}

function show_diff {
  diff -u $1 $2 | \
    sed -e "s/^\(+.*\)/[32m\1[0m/" |\
    sed -e "s/^\(-.*\)/[31m\1[0m/"
  return 1
}

function update {
  read -p "Would you like to update the expectations? [y/N]: " answer
  if [[ $answer == 'y' || $answer == 'Y' ]]; then
    cp $2 $1
    return 0
  fi
  return 1
}

function pass {
  echo -e "[32mOK[0m"
}

function compare {
  # use a standard diff, if they are not identical, format the diff nicely to
  # see what's the error and prompt to see if they wish to update it. If they
  # do, continue running more tests.
  diff -q $1 $2 && pass || show_diff $1 $2 || update $1 $2
}

# First clear the output folder. Otherwise we can miss bugs when we fail to
# generate a file.
if [[ -d $DIR/data/output ]]; then
  rm -rf $DIR/data/output/*
  ln -s $DIR/packages $DIR/data/output/packages
else
  mkdir $DIR/data/output
fi

# Create a reference to the example directory, so that the output is generated
# relative to the input directory (reaching out with ../../../ works, but
# generates the output in the source tree).
if [[ ! -e $DIR/data/input/example ]]; then
  ln -s `dirname $DIR`/example/ $DIR/data/input/example
fi


function compare_all {
# TODO(jmesserly): bash and dart regexp might not be 100% the same. Ideally we
# could do all the heavy lifting in Dart code, and keep this script as a thin
# wrapper that sets `--enable-type-checks --enable-asserts`
  for input in $DIR/data/input/*_test.html; do
    if [[ ($TEST_PATTERN == "") || ($input =~ $TEST_PATTERN) ]]; then
      FILENAME=`basename $input`
      echo -e -n "Checking diff for $FILENAME "
      DUMP="$DIR/data/output/$FILENAME.txt"
      ERR="$DIR/data/output/_errors.$FILENAME.txt"
      EXPECTATION="$DIR/data/expected/$FILENAME.txt"

      compare $EXPECTATION $DUMP || \
        (echo "Errors printed by DumpRenderTree:"; cat $ERR; fail)
    fi
  done
}

pushd $DIR
dart $DART_FLAGS run_all.dart $TEST_PATTERN || compare_all
popd



# Run Dart analyzer to check that we're generating warning clean code.
OUT_PATTERN="$DIR/data/output/*$TEST_PATTERN*_bootstrap.dart"
if [[ `ls $OUT_PATTERN 2>/dev/null` != "" ]]; then
  echo -e "\n Analyzing generated code for warnings or type errors."
  # TODO(jmesserly): batch mode does not return the right exit code.
  ls $OUT_PATTERN | dart_analyzer --fatal-warnings --fatal-type-errors \
    --work $DIR/data/output/analyzer/ -batch
  rm -r $DIR/data/output/analyzer/
fi

echo -e "[32mAll tests pass[0m"
