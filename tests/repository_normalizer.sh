# /bin/sh
set -e

PROJECT="$1"
REPOSITORY="$2"

LOWER_PROJECT=$(echo -e "$PROJECT" | tr '[:upper:]' '[:lower:]')
LOWER_REPOSITORY=$(echo -e "$REPOSITORY" | tr '[:upper:]' '[:lower:]')
if [ "${LOWER_REPOSITORY#"$LOWER_PROJECT"}" != "$LOWER_REPOSITORY" ]; then
  PREFIX_LENGTH=${#LOWER_PROJECT}
  REPOSITORY="${REPOSITORY:$PREFIX_LENGTH}"
  REPOSITORY="${REPOSITORY#[-_]}"
fi
echo -e "${PROJECT}/${REPOSITORY}"
