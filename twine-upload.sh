#! /bin/bash

if [[ -n "${DEBUG}" ]]
then
    set -x
fi

set -Eeuo pipefail


# NOTE: These variables are needed to combat GitHub passing broken env vars
# NOTE: from the runner VM host runtime.
# Ref: https://github.com/pypa/gh-action-pypi-publish/issues/112
export HOME="/root"  # So that `python -m site` doesn't get confused
export PATH="/usr/bin:${PATH}"  # To find `id`
. /etc/profile  # Makes python and other executables findable
export PATH="$(python -m site --user-base)/bin:${PATH}"
export PYTHONPATH="$(python -m site --user-site):${PYTHONPATH}"


function get-normalized-input() {
  local var_name=${1}
  python -c \
    '
from os import getenv
from sys import argv
envvar_name = f"INPUT_{argv[1].upper()}"
print(
  getenv(envvar_name) or getenv(envvar_name.replace("-", "_")) or "",
  end="",
)
    ' \
    "${var_name}"
}


INPUT_REPOSITORY_URL="$(get-normalized-input 'repository-url')"
INPUT_PACKAGES_DIR="$(get-normalized-input 'packages-dir')"
INPUT_VERIFY_METADATA="$(get-normalized-input 'verify-metadata')"
INPUT_SKIP_EXISTING="$(get-normalized-input 'skip-existing')"
INPUT_PRINT_HASH="$(get-normalized-input 'print-hash')"

if [[ "${INPUT_USER}" == "__token__" && -z "${INPUT_PASSWORD}" ]] ; then
    # No password supplied by the user implies that we're in the OIDC flow;
    # retrieve the OIDC credential and exchange it for a PyPI API token.
    echo \
        '::notice::Attempting to perform trusted publishing exchange' \
        'to retrieve a temporary short-lived API token for authentication' \
        "against ${INPUT_REPOSITORY_URL} due to __token__ username with no" \
        'supplied password field'
    INPUT_PASSWORD="$(python /app/oidc-exchange.py)"
elif [[ "${INPUT_USER}" == '__token__' ]]; then
    echo \
        '::notice::Using a user-provided API token for authentication' \
        "against ${INPUT_REPOSITORY_URL}"
else
    echo \
        '::notice::Using a username + password pair for authentication' \
        "against ${INPUT_REPOSITORY_URL}"
fi

if [[
    "$INPUT_USER" == "__token__" &&
    ! "$INPUT_PASSWORD" =~ ^pypi-
  ]]
then
    if [[ -z "$INPUT_PASSWORD" ]]; then
        echo \
            ::warning file='# >>' PyPA publish to PyPI GHA'%3A' \
            EMPTY TOKEN \
            '<< ':: \
            It looks like you have not passed a password or it \
            is otherwise empty. Please verify that you have passed it \
            directly or, preferably, through a secret.
    else
        echo \
            ::warning file='# >>' PyPA publish to PyPI GHA'%3A' \
            POTENTIALLY INVALID TOKEN \
            '<< ':: \
            It looks like you are trying to use an API token to \
            authenticate in the package index and your token value does \
            not start with '"pypi-"' as it typically should. This may \
            cause an authentication error. Please verify that you have \
            copied your token properly if such an error occurs.
    fi
fi

if ( ! ls -A ${INPUT_PACKAGES_DIR%%/}/*.tar.gz &> /dev/null && \
     ! ls -A ${INPUT_PACKAGES_DIR%%/}/*.whl &> /dev/null )
then
    echo \
        ::warning file='# >>' PyPA publish to PyPI GHA'%3A' \
        MISSING DISTS \
        '<< ':: \
        It looks like there are no Python distribution packages to \
        publish in the directory "'${INPUT_PACKAGES_DIR%%/}/'". \
        Please verify that they are in place should you face this \
        problem.
fi

if [[ ${INPUT_VERIFY_METADATA,,} != "false" ]] ; then
    twine check ${INPUT_PACKAGES_DIR%%/}/*
fi

TWINE_EXTRA_ARGS=
if [[ ${INPUT_SKIP_EXISTING,,} != "false" ]] ; then
    TWINE_EXTRA_ARGS=--skip-existing
fi

if [[ ${INPUT_VERBOSE,,} != "false" ]] ; then
    TWINE_EXTRA_ARGS="--verbose $TWINE_EXTRA_ARGS"
fi

if [[ ${INPUT_PRINT_HASH,,} != "false" || ${INPUT_VERBOSE,,} != "false" ]] ; then
    python /app/print-hash.py ${INPUT_PACKAGES_DIR%%/}
fi

TWINE_USERNAME="$INPUT_USER" \
TWINE_PASSWORD="$INPUT_PASSWORD" \
TWINE_REPOSITORY_URL="$INPUT_REPOSITORY_URL" \
  exec twine upload ${TWINE_EXTRA_ARGS} ${INPUT_PACKAGES_DIR%%/}/*
