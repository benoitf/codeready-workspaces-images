#!/bin/bash
set -e
set -o pipefail

help() {
    echo "Usage: build.sh [options]"   
    echo "--help: display this help"
    echo "--all-images: rebuild all images"
    echo "--folders=path1,path2: rebuild only those paths"
}

# initialize global variables
init() {
  BUILD_ALL_IMAGES=false
  SPECIFIC_FOLDERS=""
  FILTERED_ARGS=""
}

# parse arguments
# FILTERED_ARGS are the arguments that are passed to the script minus the one being handled
parse() {
  while [ $# -gt 0 ]; do
    case $1 in
      --all-images)
        BUILD_ALL_IMAGES=true
        shift;;
      --folders=*)
        SPECIFIC_FOLDERS="${1#*=}"
        shift ;;
      --help)
        help
        exit 0;;
      *)
        FILTERED_ARGS="${FILTERED_ARGS} $1"
      shift;;
    esac
  done
}

# grab current version
get_current_version() {
  # fixme
  echo "2.11"
} 

# get github release for the current version
# param: $1 - version
get_github_release() {
    # need to call github API
    # https://docs.github.com/en/rest/reference/repos#get-a-release-by-tag-name
    curl -s -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/redhat-developer/codeready-workspaces-images/releases/tags/${1}"
}

# extract assets from a github release object
# param: content of github release JSON
extract_github_release_assets() {
    jq -r '.assets[]' <<< "${1}"
}

# find the matching asset from a given filename and a given sha512
# param: $1 / assetJsonContent - array of assets from a github release
# param: $2 / expectedFilename - the filename to match
# param: $3 / expectedSha512 - the sha512 to match
find_matching_asset_for_filename_and_sha512() {
    local -r assetJsonContent=$1
    local -r expectedFilename=$2
    local -r expectedSha512=$3

    # the format of the file is:
    # filename@SHa512.extension so we need to rebuild this
    local -r regexpValue=$(echo "${expectedFilename}" | sed -rn 's/([^\.]*)([^.]*)/\1|\2/p')

    IFS="|" read -r filenameWithoutExtension fileExtension  <<< "${regexpValue}"

    # compute the link
    search_filename=${filenameWithoutExtension}@${expectedSha512}${fileExtension}

    # find the matching asset
    jq --arg SEARCH_FILENAME "${search_filename}" -r '. | select(.name==$SEARCH_FILENAME) | .browser_download_url' <<< "${assetJsonContent}"
}

# Get folder names of the images to build from the current git branch
# no param
get_folder_images_to_build() {
    
    # if variables BUILD_ALL_IMAGES is true then we build all folders
    if [ "${BUILD_ALL_IMAGES}" = true ]; then
        # get all folders
        find . -type d -maxdepth 1 | grep codeready- | sed 's/^\.\///g' | sort -u
    elif [ -n "${SPECIFIC_FOLDERS}" ]; then
        # use folders that are specified
        IFS=',' read -r -a tmpFoldersArray <<< "${SPECIFIC_FOLDERS}"
        # wrap to a multi-line string
        IFS=$'\n'; echo "${tmpFoldersArray[*]}"
    else
      # need to check which folders have been updated by this commit
      # grab all modified files then, get the folder and then only report unique folders
      git diff --name-only --diff-filter=d -r HEAD HEAD^1 |  cut -d "/" -f1 | uniq
    fi
}

# Download assets for a given folder
# param: $1 is the path to the folder to build
# param: $2 is the name of the image
download_build_assets() {
    local -r folder=${1}
    local -r imageName=${2}
    
    echo "Downloading assets for image ${imageName}..."
    # iterate on each sources
    while IFS=' ' read -r -a sourceContent; do

        # strip any () around (filename)
        local  filename=${sourceContent[1]//[()]/}

         # get sha512 value
        local  sha512="${sourceContent[3]}"

        # fixme: check if we have the file already there and with the right sha512

        # get the download URL of the asset from a name and sha512
        local downloadURL
        downloadURL=$(find_matching_asset_for_filename_and_sha512 "${assets}" "${filename}" "${sha512}")

        # check download URL is there else throw an error
        if [ -z "${downloadURL}" ]; then
            echo "Unable to find download URL for ${filename} with sha512 ${sha512} required for image ${imageName} in folder ${folder}"    
            exit 1
        fi

        # Download the file with curl
        echo " - ${filename}..."
        curl -s -L -o "${folder}/${filename}" "${downloadURL}"
    done <<< "$(cat ./"${folder}"/sources)"
}

# Patch dockerfile content by adding registry prefix
# param: $1 is the path of the dockerfile to patch
patch_dockerfile_content() {
    local -r dockerfilePath=${1}

    # Patch Dockerfile to add redhat registry
    sed "s/FROM rhel8/FROM registry.redhat.io\/rhel8/" "${dockerfilePath}" | \
    sed "s/FROM ubi8/FROM registry.redhat.io\/ubi8/"

}

# Build the image for the given folder
# param: $1 is the path to the folder to build
# param: $2 is the name of the image
# param: $3 are the assets available
build_image() {
    local -r folder=${1}
    local -r imageName=${2}
    local -r assets=${3}

    # grab assets if any
    download_build_assets "${folder}" "${imageName}"

    # patch dockerfile content
    patchedDockerfilePath="./${folder}/.Dockerfile"
    patch_dockerfile_content "${folder}/Dockerfile" > "${patchedDockerfilePath}"

    # build the image
    docker build -f "${patchedDockerfilePath}" -t "${imageName}" "${folder}"
}

build_images() {

  # grab the version of this repository
  local -r currentVersion=$(get_current_version)

  # the asset tag is the name of the version for now
  local -r assetVersion="${currentVersion}-assets"

  # get content of the github release for the given asset
  echo "Fetching github metadata for release ${assetVersion}..."
  local -r content=$(get_github_release "${assetVersion}")

  # Get all assets for the given release
  echo "Extracting available assets..."
  local -r availableAssets=$(extract_github_release_assets "${content}")

  # Get list of folders where we need to run the build
  echo "Computing list of folders to build..."
  local -r foldersToBuild=$(get_folder_images_to_build)
  
  # if foldersToBuild is empty
  if [ -z "${foldersToBuild}" ]; then
    echo " => No image to build, skipping"
    exit 0
  fi

  local -r numberOfImages=$(echo "${foldersToBuild}" | wc -l | bc)
  echo " => Found ${numberOfImages} images to build "

  echo ""
  local imageBuildCount=1
  while IFS= read -r folderToBuild ; do
    local imageName="quay.io/fbenoit/${folderToBuild}:gh-${currentVersion}"
    echo "${imageBuildCount} - Building image ${imageName} in the folder ${folderToBuild}..."
    build_image "${folderToBuild}" "${imageName}" "${availableAssets}"
    echo "Image ${imageName} successfully build."
  
    # increment the counter
    imageBuildCount=$((imageBuildCount+1))

  done <<< "${foldersToBuild}"

}

# initialize
init

# analyze args
parse "$@"

# build images, with either:
# - all images if `--all-images` flag is given
# - only images that are modified
# - a list of specific folders if `--folders=path1,path2,path3` is given
build_images
