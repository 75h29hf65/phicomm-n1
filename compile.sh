#!/bin/bash
#
# Copyright (c) 2015 Igor Pecovnik, igor.pecovnik@gma**.com
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.
#
# This file is a part of the Armbian build script
# https://github.com/armbian/build/

# DO NOT EDIT THIS FILE
# use configuration files like config-default.conf to set the build configuration
# check Armbian documentation for more info

SRC="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

# check for whitespace in ${SRC} and exit for safety reasons
grep -q "[[:space:]]" <<<"${SRC}" && { echo "\"${SRC}\" contains whitespace. Not supported. Aborting." >&2 ; exit 1 ; }

cd "${SRC}" || exit

if [[ -f "${SRC}"/lib/general.sh ]]; then
	# shellcheck source=lib/general.sh
	source "${SRC}"/lib/general.sh
else
	echo "Error: missing build directory structure"
	echo "Please clone the full repository https://github.com/armbian/build/"
	exit 255
fi

#  Add the variables needed at the beginning of the path
check_args ()
{
  for p in "$@"; do

	case "${p%=*}" in
		LIB_TAG)
			# Take a variable if the branch exists locally
			if [ "${p#*=}" == "$(git branch | \
				gawk -v b="${p#*=}" '{if ( $NF == b ) {print $NF}}')" ]; then
				echo "Setting $p"
				eval "$p"
			else
				echo "Skip $p Set as LIB_TAG=\"\""
				eval LIB_TAG=""
			fi
			;;
	esac

  done
}

check_args "$@"

update_src() {
	cd "${SRC}" || exit
	if [[ ! -f "${SRC}"/.ignore_changes ]]; then
		echo -e "[\e[0;32m o.k. \x1B[0m] This script will try to update"

		CHANGED_FILES=$(git diff --name-only)
		if [[ -n "${CHANGED_FILES}" ]]; then
			echo -e "[\e[0;35m warn \x1B[0m] Can't update since you made changes to: \e[0;32m\n${CHANGED_FILES}\x1B[0m"
			while true; do
				echo -e "Press \e[0;33m<Ctrl-C>\x1B[0m or \e[0;33mexit\x1B[0m to abort compilation, \e[0;33m<Enter>\x1B[0m to ignore and continue, \e[0;33mdiff\x1B[0m to display changes"
				read -r
				if [[ "${REPLY}" == "diff" ]]; then
					git diff
				elif [[ "${REPLY}" == "exit" ]]; then
					exit 1
				elif [[ "${REPLY}" == "" ]]; then
					break
				else
					echo "Unknown command!"
				fi
			done
		else
			git checkout "${LIB_TAG:-master}"
			git pull
		fi
	fi
}

TMPFILE=$(mktemp)
chmod 644 "${TMPFILE}"
{
	echo SRC="$SRC"
	echo LIB_TAG="$LIB_TAG"
	declare -f update_src
	echo "update_src"

}  > "$TMPFILE"

#do not update/checkout git with root privileges to messup files onwership.
#due to in docker/VM, we can't su to a normal user, so do not update/checkout git.
if [[ $(systemd-detect-virt) == 'none' ]]; then
	if [[ "${EUID}" == "0" ]]; then
		su "$(stat --format=%U "${SRC}"/.git)" -c "bash ${TMPFILE}"
	else
		bash "${TMPFILE}"
	fi
fi

rm "${TMPFILE}"

if [[ "${EUID}" == "0" ]] || [[ "${1}" == "vagrant" ]]; then
	:
elif [[ "${1}" == docker || "${1}" == dockerpurge || "${1}" == docker-shell ]] && grep -q "$(whoami)" <(getent group docker); then
	:
else
	display_alert "This script requires root privileges, trying to use sudo" "" "wrn"
	sudo "${SRC}/compile.sh" "$@"
	exit $?
fi

# Check for required packages for compiling
if [[ -z "$(command -v dialog)" ]]; then
	sudo apt-get update
	sudo apt-get install -y dialog
fi
if [[ -z "$(command -v fuser)" ]]; then
	sudo apt-get update
	sudo apt-get install -y psmisc
fi
if [[ -z "$(command -v getfacl)" ]]; then
	sudo apt-get update
	sudo apt-get install -y acl
fi
if [[ -z "$(command -v uuidgen)" ]]; then
	sudo apt-get update
	sudo apt-get install -y uuid-runtime
fi

# Check for Vagrant
if [[ "${1}" == vagrant && -z "$(command -v vagrant)" ]]; then
	display_alert "Vagrant not installed." "Installing"
	sudo apt-get update
	sudo apt-get install -y vagrant virtualbox
fi

if [[ "${1}" == dockerpurge && -f /etc/debian_version ]]; then
	display_alert "Purging Armbian Docker containers" "" "wrn"
	docker container ls -a | grep armbian | awk '{print $1}' | xargs docker container rm &> /dev/null
	docker image ls | grep armbian | awk '{print $3}' | xargs docker image rm &> /dev/null
	shift
	set -- "docker" "$@"
fi

if [[ "${1}" == docker-shell ]]; then
	shift
	#shellcheck disable=SC2034
	SHELL_ONLY=yes
	set -- "docker" "$@"
fi

# Install Docker if not there but wanted. We cover only Debian based distro install. Else, manual Docker install is needed
if [[ "${1}" == docker && -f /etc/debian_version && -z "$(command -v docker)" ]]; then

	# add exception for Ubuntu Focal until Docker provides dedicated binary
	codename=$(lsb_release -sc)
	codeid=$(lsb_release -is | awk '{print tolower($0)}')
	[[ "${codeid}" == "linuxmint" && "${codename}" == "debbie" ]] && codename="buster" && codeid="debian"
	[[ "${codename}" == "focal" || "${codename}" == "ulyana" ]] && codename="bionic" && codeid="ubuntu"

	display_alert "Docker not installed." "Installing" "Info"
	echo "deb [arch=amd64] https://download.docker.com/linux/${codeid} ${codename} edge" > /etc/apt/sources.list.d/docker.list

	# minimal set of utilities that are needed for prep
	packages=("curl" "gnupg" "apt-transport-https")
	for i in "${packages[@]}"
	do
	[[ ! $(command -v "${i}") ]] && install_packages+=${i}" "
	done
	[[ -z "${install_packages}" ]] && apt-get update;apt-get install -y -qq --no-install-recommends "${install_packages}"

	curl -fsSL "https://download.docker.com/linux/${codeid}/gpg" | apt-key add -qq - > /dev/null 2>&1
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get install -y -qq --no-install-recommends docker-ce
	display_alert "Add yourself to docker group to avoid root privileges" "" "wrn"
	"${SRC}/compile.sh" "$@"
	exit $?
fi

# Create userpatches directory if not exists
mkdir -p "${SRC}"/userpatches

# Create example configs if none found in userpatches
if ! ls "${SRC}"/userpatches/{config-example.conf,config-docker.conf,config-vagrant.conf} 1> /dev/null 2>&1; then

	# Migrate old configs
	if ls "${SRC}"/*.conf 1> /dev/null 2>&1; then
		display_alert "Migrate config files to userpatches directory" "all *.conf" "info"
                cp "${SRC}"/*.conf "${SRC}"/userpatches  || exit 1
		rm "${SRC}"/*.conf
		[[ ! -L "${SRC}"/userpatches/config-example.conf ]] && ln -fs config-example.conf "${SRC}"/userpatches/config-default.conf || exit 1
	fi

	display_alert "Create example config file using template" "config-default.conf" "info"

	# Create example config
	if [[ ! -f "${SRC}"/userpatches/config-example.conf ]]; then
		cp "${SRC}"/config/templates/config-example.conf "${SRC}"/userpatches/config-example.conf || exit 1
                ln -fs config-example.conf "${SRC}"/userpatches/config-default.conf || exit 1
	fi

	# Create Docker config
	if [[ ! -f "${SRC}"/userpatches/config-docker.conf ]]; then
		cp "${SRC}"/config/templates/config-docker.conf "${SRC}"/userpatches/config-docker.conf || exit 1
	fi

	# Create Docker file
	if [[ ! -f "${SRC}"/userpatches/Dockerfile ]]; then
		cp "${SRC}"/config/templates/Dockerfile "${SRC}"/userpatches/Dockerfile || exit 1
	fi

	# Create Vagrant config
	if [[ ! -f "${SRC}"/userpatches/config-vagrant.conf ]]; then
		cp "${SRC}"/config/templates/config-vagrant.conf "${SRC}"/userpatches/config-vagrant.conf || exit 1
	fi

	# Create Vagrant file
	if [[ ! -f "${SRC}"/userpatches/Vagrantfile ]]; then
		cp "${SRC}"/config/templates/Vagrantfile "${SRC}"/userpatches/Vagrantfile || exit 1
	fi

fi

if [[ -z "${CONFIG}" && -n "$1" && -f "${SRC}/userpatches/config-$1.conf" ]]; then
	CONFIG="userpatches/config-$1.conf"
	shift
fi

# usind default if custom not found
if [[ -z "${CONFIG}" && -f "${SRC}/userpatches/config-default.conf" ]]; then
	CONFIG="userpatches/config-default.conf"
fi

# source build configuration file
CONFIG_FILE="$(realpath "${CONFIG}")"

if [[ ! -f "${CONFIG_FILE}" ]]; then
	display_alert "Config file does not exist" "${CONFIG}" "error"
	exit 254
fi

CONFIG_PATH=$(dirname "${CONFIG_FILE}")

display_alert "Using config file" "${CONFIG_FILE}" "info"
pushd "${CONFIG_PATH}" > /dev/null || exit
# shellcheck source=/dev/null
source "${CONFIG_FILE}"
popd > /dev/null || exit

[[ -z "${USERPATCHES_PATH}" ]] && USERPATCHES_PATH="${CONFIG_PATH}"

# Script parameters handling
while [[ "${1}" == *=* ]]; do
    parameter=${1%%=*}
    value=${1##*=}
    shift
    display_alert "Command line: setting $parameter to" "${value:-(empty)}" "info"
    eval "$parameter=\"$value\""
done

if [[ "${BUILD_ALL}" == "yes" || "${BUILD_ALL}" == "demo" ]]; then
	# shellcheck source=lib/build-all-ng.sh
	source "${SRC}"/lib/build-all-ng.sh
else
	# shellcheck source=lib/main.sh
	source "${SRC}"/lib/main.sh
fi
