#!/bin/bash

# This script creates builds according to our custom build policy, which is:
# - "master" will always point to the most recent build on master
# - "latest" will refer to the latest tagged release
# - Each release "foo" will have a tag "foo"
#
# This script is a noop if HEAD is not origin/master OR tagged.

set -exo pipefail

CONFIG=${1:-"docker/images.json"}

function cleanup() {
  docker system prune -f
  find /tmp -name '*m3-docker' -print0 | xargs -0 rm -fv
}

trap cleanup EXIT

# The logs for builds have a ton of output from set -x, Docker builds, etc. Need
# an easy way to find our own messages in the logs.
function log_info() {
  echo "[INFO] $1"
}

function push_image() {
  if [[ -z "$DRYRUN" ]]; then
    log_info "pushing $1"
    docker push "$1"
  else
    echo "would push $1"
  fi
}

if [[ ! -f "$CONFIG" ]]; then
  echo "could not find docker images config $CONFIG"
  exit 1
fi

if [[ -z "$M3_DOCKER_REPO" ]]; then
  echo "must set M3_DOCKER_REPO to repository base (i.e quay.io/m3)"
  exit 1
fi

IMAGES="$(<"$CONFIG" jq -er '.images | to_entries | map(.key)[]')"
REPO=$M3_DOCKER_REPO
TAGS_TO_PUSH=""

# If this commit matches an exact tag, push a tagged build and "latest".
if git describe --tags --exact-match; then
  TAG=$(git describe --tags --exact-match)
  TAGS_TO_PUSH="${TAGS_TO_PUSH} ${TAG} latest"
fi

# If this commit says to do a docker build, push a tag with the branch name.
if [[ "$BUILDKITE_MESSAGE" =~ /build-docker ]]; then
  # Sanitize the branch name (any non-alphanum char gets turned into a '_').
  TAG=$(<<<"$BUILDKITE_BRANCH" sed 's/[^a-z|0-9]/_/g')
  TAGS_TO_PUSH="${TAGS_TO_PUSH} ${TAG}"
fi

CURRENT_SHA=$(git rev-parse HEAD)
MASTER_SHA=$(git rev-parse origin/master)

# If the current commit is exactly origin/master, push a tag for "master".
if [[ "$CURRENT_SHA" == "$MASTER_SHA" ]]; then
  TAGS_TO_PUSH="${TAGS_TO_PUSH} master"
fi

if [[ -z "$TAGS_TO_PUSH" ]]; then
  exit 0
fi

log_info "will push [$TAGS_TO_PUSH]"

for IMAGE in $IMAGES; do
  # Do one build, then push all the necessary tags.
  SHA_TMP=$(mktemp --suffix m3-docker)
  log_info "building $IMAGE"
  docker build --iidfile "$SHA_TMP" -f "$(<"$CONFIG" jq -er ".images[\"${IMAGE}\"].dockerfile")" .
  IMAGE_SHA=$(cat "$SHA_TMP")
  for TAG in $TAGS_TO_PUSH; do
    FULL_TAG="${REPO}/${IMAGE}:${TAG}"
    docker tag "$IMAGE_SHA" "$FULL_TAG"
    push_image "$FULL_TAG"

    # If the image has aliases, tag them too.
    ALIASES="$(<"$CONFIG" jq -r "(.images[\"${IMAGE}\"].aliases | if . == null then [] else . end)[]")"
    for ALIAS in $ALIASES; do
      DUAL_TAG="${REPO}/${ALIAS}:${TAG}"
      docker tag "$IMAGE_SHA" "$DUAL_TAG"
      push_image "$DUAL_TAG"
    done
  done
done

# Clean up
CLEANUP_IMAGES=$(docker images | grep "$REPO" | awk '{print $3}' | sort | uniq)
for IMG in $CLEANUP_IMAGES; do
  log_info "removing $IMG"
  docker rmi -f "$IMG"
done