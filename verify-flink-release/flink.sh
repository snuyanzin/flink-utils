#!/bin/bash
################################################################################
#  Licensed to the Apache Software Foundation (ASF) under one
#  or more contributor license agreements.  See the NOTICE file
#  distributed with this work for additional information
#  regarding copyright ownership.  The ASF licenses this file
#  to you under the Apache License, Version 2.0 (the
#  "License"); you may not use this file except in compliance
#  with the License.  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
################################################################################

set -o errexit
set -o nounset
set -o pipefail

# source: https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# imports
source ${script_dir}/subtasks/common.sh
source ${script_dir}/subtasks/download_artifacts.sh
source ${script_dir}/subtasks/checks.sh
source ${script_dir}/subtasks/maven_build.sh
source ${script_dir}/subtasks/flink_test_run.sh

# defaults
maven_exec="mvn"
working_dir="$(pwd)"

print_usage() {
  echo "Usage: $0 [-h] [-d] -u <url> -g <gpg-public-key-ref> -b <base-git-tag> [-m <maven-exec>] [-w <working-directory>]"
  echo ""
  echo "  -h            Prints information about this script."
  echo "  -d            Enables debug logging."
  echo "  -u            URL that's used for downloaded the artifacts."
  echo "  -g            GPG public key reference that was used for signing the artifacts."
  echo "  -b            Base git tag to compare to excluding the 'release-' prefix (e.g. '1.15.2' for git tag 'release-1.15.2')."
  echo "  -m            Maven executable being used. Only Maven 3.2.5 is supported for now. (default: $maven_exec)"
  echo "  -w            Working directory used for downloading and processing the artifacts. The directory needs to exist beforehand. (default: $working_dir)"
}

tasks=(
  "Downloaded artifacts"
  "Built Flink from sources"
  "Verified SHA512 checksums GPG signatures"
  "Compared checkout with provided sources"
  "Verified pom file versions"
  "Went over NOTICE file/pom files changes without finding anything suspicious"
  "Deployed standalone session cluster and ran WordCount example in batch and streaming: Nothing suspicious in log files found"
)

print_info_and_exit() {
  echo "$0 verifies Flink releases. The following steps are executed:"
  echo "  - Download all resources"
  echo "  - Extracts sources and runs build"
  echo "  - Compares git tag checkout with downloaded sources"
  echo "  - Verifies SHA512 checksums"
  echo "  - Verifies GPG certification"
  echo "  - Checks that all POMs have the right expected version"
  echo "  - Generate diffs to compare pom file changes with NOTICE files"
  echo "  - Runs WordCount example in batch mode and streaming mode to verify the logs"
  echo ""
  echo "See usage info below for further details on how to use the script..."
  print_usage
  exit 0
}

print_error_with_usage_and_exit() {
  echo "Error: $1"
  print_usage
  exit 1
}

if [[ "$#" == 0 ]]; then
  print_info_and_exit
fi

while getopts "hdm:u:g:w:b:s:" o; do
  case "${o}" in
    d)
      set -x
      ;;
    h)
      print_info_and_exit
      ;;
    u)
      # remove any trailing slashes from url
      url=${OPTARG%/}
      ;;
    g)
      public_gpg_key=${OPTARG}
      ;;
    b)
      base_git_tag=${OPTARG}
      ;;
    m)
      maven_exec=${OPTARG}
      ;;
    w)
      working_dir=${OPTARG}
      if [[ ! -d ${working_dir} ]]; then
        print_error_with_usage_and_exit "Passed working directory ${working_dir} doesn't exist."
      fi
      ;;
    *)
      print_error_with_usage_and_exit "Invalid parameter passed: ${o}"
      ;;
  esac
done

# check required variables
if [[ -z "${url+x}"  ]]; then
  print_error_with_usage_and_exit "Missing URL"
elif [[ -z "${public_gpg_key+x}" ]]; then
  print_error_with_usage_and_exit "Missing GPG public key reference"
elif [[ -z "${base_git_tag+x}" ]]; then
  print_error_with_usage_and_exit "Missing base git tag"
fi

repository_name="flink"

# derive variables
flink_git_tag="$(echo $url | grep -o '[^/]*$' | sed 's/'${repository_name}'-\(.*\)$/\1/g')"
flink_version="$(echo $flink_git_tag | sed 's/\(.*\)-rc[0-9]\+/\1/g')"
source_directory="${working_dir}/src"
checkout_directory="${working_dir}/checkout"
download_dir_name="downloaded_artifacts"
download_dir=${working_dir}/${download_dir_name}

check_maven_version $maven_exec

download_artifacts ${working_dir} ${url} ${download_dir_name} ${repository_name}

clone_repo ${working_dir} ${repository_name} ${flink_git_tag} ${checkout_directory} ${base_git_tag}

extract_source_artifacts ${working_dir} ${download_dir} ${source_directory} ${repository_name} ${flink_version}

check_gpg ${working_dir} ${public_gpg_key} ${download_dir}
check_sha512 ${working_dir} ${download_dir}
compare_downloaded_source_with_repo_checkout ${working_dir} ${checkout_directory} ${source_directory}
check_version_in_poms ${working_dir} ${source_directory} ${flink_version}
compare_notice_with_pom_changes ${working_dir} ${checkout_directory} ${flink_git_tag} ${base_git_tag}

use_default_maven_params=""
target_maven_modules="flink-dist"
build_sources ${working_dir} ${source_directory} ${maven_exec} "${use_default_maven_params}" "${target_maven_modules}"

source_bin=${source_directory}/build-target
run_flink_session_cluster ${working_dir} session-wordcount-streaming ${source_bin} examples/streaming/WordCount.jar
run_flink_session_cluster ${working_dir} session-wordcount-batch ${source_bin} examples/batch/WordCount.jar

print_mailing_list_post ${working_dir} ${tasks[@]}
