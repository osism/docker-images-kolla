#!/usr/bin/env bash

set -x

# Available environment variables
#
# BUILD_ID
# DOCKER_NAMESPACE
# OPENSTACK_VERSION
# VERSION

# Set default values

BUILD_ID=${BUILD_ID:-$(date +%Y%m%d)}
DOCKER_NAMESPACE=${DOCKER_NAMESPACE:-osism}
OPENSTACK_VERSION=${OPENSTACK_VERSION:-latest}
VERSION=${VERSION:-latest}

PROJECT_REPOSITORY=https://github.com/openstack/kolla
PROJECT_REPOSITORY_PATH=kolla
KOLLA_TYPE=ubuntu-source
SOURCE_DOCKER_TAG=build-$BUILD_ID

# NOTE: For builds for a specific release, the OpenStack version is taken from the release repository.
if [[ $VERSION != "latest" ]]; then
    filename=$(curl -L https://raw.githubusercontent.com/osism/release/master/$VERSION/openstack.yml)
    OPENSTACK_VERSION=$(curl -L https://raw.githubusercontent.com/osism/release/master/$VERSION/$filename | grep "openstack_version:" | awk -F': ' '{ print $2 }')
fi

. defaults/$OPENSTACK_VERSION.sh

export VERSION
export OPENSTACK_VERSION

git submodule update --remote

if [[ ! -e release/$VERSION/base.yml ]]; then
    echo "release $VERSION does not exist"
    exit 1
fi

# Clone repository

if [[ ! -e $PROJECT_REPOSITORY_PATH ]]; then
    git clone $PROJECT_REPOSITORY $PROJECT_REPOSITORY_PATH
fi

# Use required kolla release for dockerfiles

pushd $PROJECT_REPOSITORY_PATH > /dev/null
if [[ "$OPENSTACK_VERSION" != "latest" ]]; then
    git checkout origin/stable/$OPENSTACK_VERSION
fi
export HASH_KOLLA=$(git rev-parse --short HEAD)
popd > /dev/null

# Apply patches

for patch in $(find patches/kolla-build/$OPENSTACK_VERSION -type f -name '*.patch'); do
    pushd $PROJECT_REPOSITORY_PATH > /dev/null
    echo "APPLY PATCH $patch"
    patch --forward --batch -p1 --dry-run < ../$patch || exit 1
    patch --forward --batch -p1 < ../$patch
    popd > /dev/null
done

# Prepare repos.yaml

if [[ "OPENSTACK_VERSION" == "victoria" || "$OPENSTACK_VERSION" == "wallaby" || "$OPENSTACK_VERSION" == "latest" ]]; then
    cp templates/$OPENSTACK_VERSION/repos.yaml $PROJECT_REPOSITORY_PATH/kolla/template/repos.yaml
fi

# Prepare template-overrides.j2

export HASH_DOCKER_IMAGES_KOLLA=$(git rev-parse --short HEAD)
export HASH_RELEASE=$(cd release; git rev-parse --short HEAD)
python3 src/generate-template-overrides-file.py > templates/$OPENSTACK_VERSION/template-overrides.j2

echo DEBUG template-overrides.j2
cat templates/$OPENSTACK_VERSION/template-overrides.j2

# Prepare apt_preferences.ubuntu

python3 src/generate-apt-preferences-files.py > overlays/$OPENSTACK_VERSION/base/apt_preferences.ubuntu

echo DEBUG apt_preferences.ubuntu
cat overlays/$OPENSTACK_VERSION/base/apt_preferences.ubuntu

# Copy overlay files

for image in $(find overlays/$OPENSTACK_VERSION -maxdepth 1 -mindepth 1 -type d); do
    image_name=$(basename $image)
    cp -r overlays/$OPENSTACK_VERSION/$image_name/* $PROJECT_REPOSITORY_PATH/docker/$image_name
done

# Apply patches

find patches/$OPENSTACK_VERSION -mindepth 1 -type d
for project in $(find patches/$OPENSTACK_VERSION -mindepth 1 -type d | grep kolla | grep -v kolla-build); do
    project=$(basename $project)
    for patch in $(find patches/$OPENSTACK_VERSION/$project -type f -name '*.patch'); do
        pushd $project > /dev/null
        echo "APPLY PATCH $patch"
        patch --forward --batch -p1 --dry-run < ../$patch || exit 1
        patch --forward --batch -p1 < ../$patch
        popd > /dev/null
    done
done

# Install kolla

pip3 install -r $PROJECT_REPOSITORY_PATH/requirements.txt
pip3 install $PROJECT_REPOSITORY_PATH/
