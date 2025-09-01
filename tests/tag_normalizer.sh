# bin/sh
set -e

REVISION="$1"

if echo -e "$REVISION" | grep -Eq '^[0-9a-f]{7,40}$'; then
  TAG="${REVISION:0:7}"
elif echo -e "$REVISION" | grep -Eq '^v[0-9]'; then
  TAG="${REVISION#v}"
else
  echo -e "[🔴]: Invalid revision: '$REVISION'!\n"
  exit 1
fi

echo -e "$TAG"
