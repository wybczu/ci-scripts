#!/bin/bash
. "$(dirname $0)/variables.sh"

set -e

TARGET=${1:-profile.cov}
LOG=${2:-test.log}

rm $TARGET &>/dev/null || true
echo "mode: count" > $TARGET
echo "" > $LOG

DIRS=""
for DIR in $SRC;
do
  if ls $DIR/*_test.go &> /dev/null; then
    DIRS="$DIRS $DIR"
  fi
done

if [ "$NPROC" = "" ]; then
  NPROC=$(getconf _NPROCESSORS_ONLN)
fi

echo "test-cover begin: concurrency $NPROC"

PROFILE_REG="profile_reg.tmp"

TEST_FLAGS="-v -race -timeout 5m -covermode atomic"
go run .ci/gotestcover/gotestcover.go $TEST_FLAGS -coverprofile $PROFILE_REG -parallelpackages $NPROC $DIRS | tee $LOG
TEST_EXIT=${PIPESTATUS[0]}

cat $PROFILE_REG | grep -v "_mock.go" > $TARGET

find . -not -path '*/vendor/*' | grep \\.tmp$ | xargs -I{} rm {}
echo "test-cover result: $TEST_EXIT"

exit $TEST_EXIT
