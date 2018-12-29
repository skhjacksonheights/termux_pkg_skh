#!/bin/bash
# shellcheck disable=SC1117

set -e -o pipefail -u

# Utility function to log an error message and exit with an error code.
termux_error_exit() {
	echo "ERROR: $*" 1>&2
	exit 1
}

if [ "$(uname -o)" = Android ]; then
	termux_error_exit "On-device builds are not supported - see README.md"
fi

# Utility function to download a resource with an expected checksum.
termux_download() {
	if [ $# != 3 ]; then
		termux_error_exit "termux_download(): Invalid arguments - expected \$URL \$DESTINATION \$CHECKSUM"
	fi
	local URL="$1"
	local DESTINATION="$2"
	local CHECKSUM="$3"

	if [ -f "$DESTINATION" ] && [ "$CHECKSUM" != "SKIP_CHECKSUM" ]; then
		# Keep existing file if checksum matches.
		local EXISTING_CHECKSUM
		EXISTING_CHECKSUM=$(sha256sum "$DESTINATION" | cut -f 1 -d ' ')
		if [ "$EXISTING_CHECKSUM" = "$CHECKSUM" ]; then return; fi
	fi

	local TMPFILE
	TMPFILE=$(mktemp "$TERMUX_PKG_TMPDIR/download.$TERMUX_PKG_NAME.XXXXXXXXX")
	echo "Downloading ${URL}"
	local TRYMAX=6
	for try in $(seq 1 $TRYMAX); do
		if curl -L --fail --retry 2 -o "$TMPFILE" "$URL"; then
			local ACTUAL_CHECKSUM
			ACTUAL_CHECKSUM=$(sha256sum "$TMPFILE" | cut -f 1 -d ' ')
			if [ "$CHECKSUM" != "SKIP_CHECKSUM" ]; then
				if [ "$CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
					>&2 printf "Wrong checksum for %s:\nExpected: %s\nActual:   %s\n" \
					           "$URL" "$CHECKSUM" "$ACTUAL_CHECKSUM"
					exit 1
				fi
			else
				printf "WARNING: No checksum check for %s:\nActual: %s\n" \
				       "$URL" "$ACTUAL_CHECKSUM"
			fi
			mv "$TMPFILE" "$DESTINATION"
			return
		else
			echo "Download of $URL failed (attempt $try/$TRYMAX)" 1>&2
			sleep 45
		fi
	done

	termux_error_exit "Failed to download $URL"
}

# Utility function for golang-using packages to setup a go toolchain.
termux_setup_golang() {
	export GOOS=android
	export CGO_ENABLED=1
	export GO_LDFLAGS="-extldflags=-pie"
	if [ "$TERMUX_ARCH" = "arm" ]; then
		export GOARCH=arm
		export GOARM=7
	elif [ "$TERMUX_ARCH" = "i686" ]; then
		export GOARCH=386
		export GO386=sse2
	elif [ "$TERMUX_ARCH" = "aarch64" ]; then
		export GOARCH=arm64
	elif [ "$TERMUX_ARCH" = "x86_64" ]; then
		export GOARCH=amd64
	else
		termux_error_exit "Unsupported arch: $TERMUX_ARCH"
	fi

	local TERMUX_GO_VERSION=go1.11.5
	local TERMUX_GO_PLATFORM=linux-amd64

	local TERMUX_BUILDGO_FOLDER=$TERMUX_COMMON_CACHEDIR/${TERMUX_GO_VERSION}
	export GOROOT=$TERMUX_BUILDGO_FOLDER
	export PATH=$GOROOT/bin:$PATH

	if [ -d "$TERMUX_BUILDGO_FOLDER" ]; then return; fi

	local TERMUX_BUILDGO_TAR=$TERMUX_COMMON_CACHEDIR/${TERMUX_GO_VERSION}.${TERMUX_GO_PLATFORM}.tar.gz
	rm -Rf "$TERMUX_COMMON_CACHEDIR/go" "$TERMUX_BUILDGO_FOLDER"
	termux_download https://storage.googleapis.com/golang/${TERMUX_GO_VERSION}.${TERMUX_GO_PLATFORM}.tar.gz \
		"$TERMUX_BUILDGO_TAR" \
		ff54aafedff961eb94792487e827515da683d61a5f9482f668008832631e5d25

	( cd "$TERMUX_COMMON_CACHEDIR"; tar xf "$TERMUX_BUILDGO_TAR"; mv go "$TERMUX_BUILDGO_FOLDER"; rm "$TERMUX_BUILDGO_TAR" )
}

# Utility function for rust-using packages to setup a rust toolchain.
termux_setup_rust() {
	if [ $TERMUX_ARCH = "arm" ]; then
		CARGO_TARGET_NAME=armv7-linux-androideabi
	else
		CARGO_TARGET_NAME=$TERMUX_ARCH-linux-android
	fi

	local ENV_NAME=CARGO_TARGET_${CARGO_TARGET_NAME^^}_LINKER
	ENV_NAME=${ENV_NAME//-/_}
	export $ENV_NAME=$CC

	curl https://sh.rustup.rs -sSf > $TERMUX_PKG_TMPDIR/rustup.sh
	sh $TERMUX_PKG_TMPDIR/rustup.sh -y
	export PATH=$HOME/.cargo/bin:$PATH

	rustup target add $CARGO_TARGET_NAME
}

# Utility function to setup a current ninja build system.
termux_setup_ninja() {
	local NINJA_VERSION=1.8.2
	local NINJA_FOLDER=$TERMUX_COMMON_CACHEDIR/ninja-$NINJA_VERSION
	if [ ! -x "$NINJA_FOLDER/ninja" ]; then
		mkdir -p "$NINJA_FOLDER"
		local NINJA_ZIP_FILE=$TERMUX_PKG_TMPDIR/ninja-$NINJA_VERSION.zip
		termux_download https://github.com/ninja-build/ninja/releases/download/v$NINJA_VERSION/ninja-linux.zip \
			"$NINJA_ZIP_FILE" \
			d2fea9ff33b3ef353161ed906f260d565ca55b8ca0568fa07b1d2cab90a84a07
		unzip "$NINJA_ZIP_FILE" -d "$NINJA_FOLDER"
	fi
	export PATH=$NINJA_FOLDER:$PATH
}

# Utility function to setup a current meson build system.
termux_setup_meson() {
	termux_setup_ninja
	local MESON_VERSION=0.49.0
	local MESON_FOLDER=$TERMUX_COMMON_CACHEDIR/meson-$MESON_VERSION-v1
	if [ ! -d "$MESON_FOLDER" ]; then
		local MESON_TAR_NAME=meson-$MESON_VERSION.tar.gz
		local MESON_TAR_FILE=$TERMUX_PKG_TMPDIR/$MESON_TAR_NAME
		local MESON_TMP_FOLDER=$TERMUX_PKG_TMPDIR/meson-$MESON_VERSION
		termux_download \
			"https://github.com/mesonbuild/meson/releases/download/$MESON_VERSION/meson-$MESON_VERSION.tar.gz" \
			"$MESON_TAR_FILE" \
			fb0395c4ac208eab381cd1a20571584bdbba176eb562a7efa9cb17cace0e1551
		tar xf "$MESON_TAR_FILE" -C "$TERMUX_PKG_TMPDIR"
		mv "$MESON_TMP_FOLDER" "$MESON_FOLDER"
	fi
	TERMUX_MESON="$MESON_FOLDER/meson.py"
	TERMUX_MESON_CROSSFILE=$TERMUX_PKG_TMPDIR/meson-crossfile-$TERMUX_ARCH.txt
	local MESON_CPU MESON_CPU_FAMILY
	if [ "$TERMUX_ARCH" = "arm" ]; then
		MESON_CPU_FAMILY="arm"
		MESON_CPU="armv7"
	elif [ "$TERMUX_ARCH" = "i686" ]; then
		MESON_CPU_FAMILY="x86"
		MESON_CPU="i686"
	elif [ "$TERMUX_ARCH" = "x86_64" ]; then
		MESON_CPU_FAMILY="x86_64"
		MESON_CPU="x86_64"
	elif [ "$TERMUX_ARCH" = "aarch64" ]; then
		MESON_CPU_FAMILY="arm"
		MESON_CPU="aarch64"
	else
		termux_error_exit "Unsupported arch: $TERMUX_ARCH"
	fi

	local CONTENT=""
	echo "[binaries]" > $TERMUX_MESON_CROSSFILE
	echo "ar = '$AR'" >> $TERMUX_MESON_CROSSFILE
	echo "c = '$CC'" >> $TERMUX_MESON_CROSSFILE
	echo "cpp = '$CXX'" >> $TERMUX_MESON_CROSSFILE
	echo "ld = '$LD'" >> $TERMUX_MESON_CROSSFILE
	echo "pkgconfig = '$PKG_CONFIG'" >> $TERMUX_MESON_CROSSFILE
	echo "strip = '$STRIP'" >> $TERMUX_MESON_CROSSFILE

	echo '' >> $TERMUX_MESON_CROSSFILE
	echo "[properties]" >> $TERMUX_MESON_CROSSFILE
	echo "needs_exe_wrapper = true" >> $TERMUX_MESON_CROSSFILE

	echo -n "c_args = [" >> $TERMUX_MESON_CROSSFILE
	local word first=true
	for word in $CFLAGS $CPPFLAGS; do
		if [ "$first" = "true" ]; then
			first=false
		else
			echo -n ", " >> $TERMUX_MESON_CROSSFILE
		fi
		echo -n "'$word'" >> $TERMUX_MESON_CROSSFILE
	done
	echo ']' >> $TERMUX_MESON_CROSSFILE

	echo -n "cpp_args = [" >> $TERMUX_MESON_CROSSFILE
	local word first=true
	for word in $CXXFLAGS $CPPFLAGS; do
		if [ "$first" = "true" ]; then
			first=false
		else
			echo -n ", " >> $TERMUX_MESON_CROSSFILE
		fi
		echo -n "'$word'" >> $TERMUX_MESON_CROSSFILE
	done
	echo ']' >> $TERMUX_MESON_CROSSFILE

	local property
	for property in c_link_args cpp_link_args; do
		echo -n "$property = [" >> $TERMUX_MESON_CROSSFILE
		first=true
		for word in $LDFLAGS; do
			if [ "$first" = "true" ]; then
				first=false
			else
				echo -n ", " >> $TERMUX_MESON_CROSSFILE
			fi
			echo -n "'$word'" >> $TERMUX_MESON_CROSSFILE
		done
		echo ']' >> $TERMUX_MESON_CROSSFILE
	done

	echo '' >> $TERMUX_MESON_CROSSFILE
	echo "[host_machine]" >> $TERMUX_MESON_CROSSFILE
	echo "cpu_family = '$MESON_CPU_FAMILY'" >> $TERMUX_MESON_CROSSFILE
	echo "cpu = '$MESON_CPU'" >> $TERMUX_MESON_CROSSFILE
	echo "endian = 'little'" >> $TERMUX_MESON_CROSSFILE
	echo "system = 'android'" >> $TERMUX_MESON_CROSSFILE
}

# Utility function to setup a current cmake build system
termux_setup_cmake() {
	local TERMUX_CMAKE_MAJORVESION=3.13
	local TERMUX_CMAKE_MINORVERSION=3
	local TERMUX_CMAKE_VERSION=$TERMUX_CMAKE_MAJORVESION.$TERMUX_CMAKE_MINORVERSION
	local TERMUX_CMAKE_TARNAME=cmake-${TERMUX_CMAKE_VERSION}-Linux-x86_64.tar.gz
	local TERMUX_CMAKE_TARFILE=$TERMUX_PKG_TMPDIR/$TERMUX_CMAKE_TARNAME
	local TERMUX_CMAKE_FOLDER=$TERMUX_COMMON_CACHEDIR/cmake-$TERMUX_CMAKE_VERSION
	if [ ! -d "$TERMUX_CMAKE_FOLDER" ]; then
		termux_download https://cmake.org/files/v$TERMUX_CMAKE_MAJORVESION/$TERMUX_CMAKE_TARNAME \
		                "$TERMUX_CMAKE_TARFILE" \
				78227de38d574d4d19093399fd4b40a4fb0a76cbfc4249783a969652ce515270
		rm -Rf "$TERMUX_PKG_TMPDIR/cmake-${TERMUX_CMAKE_VERSION}-Linux-x86_64"
		tar xf "$TERMUX_CMAKE_TARFILE" -C "$TERMUX_PKG_TMPDIR"
		mv "$TERMUX_PKG_TMPDIR/cmake-${TERMUX_CMAKE_VERSION}-Linux-x86_64" \
		   "$TERMUX_CMAKE_FOLDER"
	fi
	export PATH=$TERMUX_CMAKE_FOLDER/bin:$PATH
	export CMAKE_INSTALL_ALWAYS=1
}

# First step is to handle command-line arguments. Not to be overridden by packages.
termux_step_handle_arguments() {
	_show_usage () {
	    echo "Usage: ./build-package.sh [-a ARCH] [-d] [-D] [-f] [-i] [-q] [-s] [-o DIR] PACKAGE"
	    echo "Build a package by creating a .deb file in the debs/ folder."
	    echo "  -a The architecture to build for: aarch64(default), arm, i686, x86_64 or all."
	    echo "  -d Build with debug symbols."
	    echo "  -D Build a disabled package in disabled-packages/."
	    echo "  -f Force build even if package has already been built."
	    echo "  -i Build dependencies."
	    echo "  -q Quiet build."
	    echo "  -s Skip dependency check."
	    echo "  -o Specify deb directory. Default: debs/."
	    exit 1
	}
	while getopts :a:hdDfiqso: option; do
		case "$option" in
		a) TERMUX_ARCH="$OPTARG";;
		h) _show_usage;;
		d) export TERMUX_DEBUG=true;;
		D) local TERMUX_IS_DISABLED=true;;
		f) TERMUX_FORCE_BUILD=true;;
		i) export TERMUX_INSTALL_DEPS=true;;
		q) export TERMUX_QUIET_BUILD=true;;
		s) export TERMUX_SKIP_DEPCHECK=true;;
		o) TERMUX_DEBDIR="$(realpath -m $OPTARG)";;
		?) termux_error_exit "./build-package.sh: illegal option -$OPTARG";;
		esac
	done
	shift $((OPTIND-1))

	if [ "$#" -ne 1 ]; then _show_usage; fi
	unset -f _show_usage

	# Handle 'all' arch:
	if [ -n "${TERMUX_ARCH+x}" ] && [ "${TERMUX_ARCH}" = 'all' ]; then
		for arch in 'aarch64' 'arm' 'i686' 'x86_64'; do
			./build-package.sh ${TERMUX_FORCE_BUILD+-f} -a $arch \
				${TERMUX_DEBUG+-d} ${TERMUX_DEBDIR+-o $TERMUX_DEBDIR} "$1"
		done
		exit
	fi

	# Check the package to build:
	TERMUX_PKG_NAME=$(basename "$1")
	export TERMUX_SCRIPTDIR
	TERMUX_SCRIPTDIR=$(cd "$(dirname "$0")"; pwd)
	if [[ $1 == *"/"* ]]; then
		# Path to directory which may be outside this repo:
		if [ ! -d "$1" ]; then termux_error_exit "'$1' seems to be a path but is not a directory"; fi
		export TERMUX_PKG_BUILDER_DIR
		TERMUX_PKG_BUILDER_DIR=$(realpath "$1")
	else
		# Package name:
		if [ -n "${TERMUX_IS_DISABLED=""}" ]; then
			export TERMUX_PKG_BUILDER_DIR=$TERMUX_SCRIPTDIR/disabled-packages/$TERMUX_PKG_NAME
		else
			export TERMUX_PKG_BUILDER_DIR=$TERMUX_SCRIPTDIR/packages/$TERMUX_PKG_NAME
		fi
	fi
	TERMUX_PKG_BUILDER_SCRIPT=$TERMUX_PKG_BUILDER_DIR/build.sh
	if test ! -f "$TERMUX_PKG_BUILDER_SCRIPT"; then
		termux_error_exit "No build.sh script at package dir $TERMUX_PKG_BUILDER_DIR!"
	fi
}

# Setup variables used by the build. Not to be overridden by packages.
termux_step_setup_variables() {
	# shellcheck source=scripts/properties.sh
	. "$TERMUX_SCRIPTDIR/scripts/properties.sh"
	: "${TERMUX_MAKE_PROCESSES:="$(nproc)"}"
	: "${TERMUX_TOPDIR:="$HOME/.termux-build"}"
	: "${TERMUX_ARCH:="aarch64"}" # arm, aarch64, i686 or x86_64.
	: "${TERMUX_PREFIX:="/data/data/com.termux/files/usr"}"
	: "${TERMUX_ANDROID_HOME:="/data/data/com.termux/files/home"}"
	: "${TERMUX_DEBUG:=""}"
	: "${TERMUX_PKG_API_LEVEL:="21"}"
	: "${TERMUX_DEBDIR:="${TERMUX_SCRIPTDIR}/debs"}"
	: "${TERMUX_SKIP_DEPCHECK:="false"}"
	: "${TERMUX_INSTALL_DEPS:="false"}"
	: "${TERMUX_REPO_URL:="https://termux.net/dists/stable/main"}"

	if [ "x86_64" = "$TERMUX_ARCH" ] || [ "aarch64" = "$TERMUX_ARCH" ]; then
		TERMUX_ARCH_BITS=64
	else
		TERMUX_ARCH_BITS=32
	fi

	TERMUX_HOST_PLATFORM="${TERMUX_ARCH}-linux-android"
	if [ "$TERMUX_ARCH" = "arm" ]; then TERMUX_HOST_PLATFORM="${TERMUX_HOST_PLATFORM}eabi"; fi

	if [ ! -d "$NDK" ]; then
		termux_error_exit 'NDK not pointing at a directory!'
	fi
	if ! grep -s -q "Pkg.Revision = $TERMUX_NDK_VERSION" "$NDK/source.properties"; then
		termux_error_exit "Wrong NDK version - we need $TERMUX_NDK_VERSION"
	fi

	# The build tuple that may be given to --build configure flag:
	TERMUX_BUILD_TUPLE=$(sh "$TERMUX_SCRIPTDIR/scripts/config.guess")

	# We do not put all of build-tools/$TERMUX_ANDROID_BUILD_TOOLS_VERSION/ into PATH
	# to avoid stuff like arm-linux-androideabi-ld there to conflict with ones from
	# the standalone toolchain.
	TERMUX_D8=$ANDROID_HOME/build-tools/$TERMUX_ANDROID_BUILD_TOOLS_VERSION/d8

	TERMUX_COMMON_CACHEDIR="$TERMUX_TOPDIR/_cache"
	TERMUX_ELF_CLEANER=$TERMUX_COMMON_CACHEDIR/termux-elf-cleaner

	export prefix=${TERMUX_PREFIX}
	export PREFIX=${TERMUX_PREFIX}

	TERMUX_PKG_BUILDDIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/build
	TERMUX_PKG_CACHEDIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/cache
	TERMUX_PKG_MASSAGEDIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/massage
	TERMUX_PKG_PACKAGEDIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/package
	TERMUX_PKG_SRCDIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/src
	TERMUX_PKG_SHA256=""
	TERMUX_PKG_TMPDIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/tmp
	TERMUX_PKG_HOSTBUILD_DIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/host-build
	TERMUX_PKG_PLATFORM_INDEPENDENT=""
	TERMUX_PKG_NO_DEVELSPLIT=""
	TERMUX_PKG_REVISION="0" # http://www.debian.org/doc/debian-policy/ch-controlfields.html#s-f-Version
	TERMUX_PKG_EXTRA_CONFIGURE_ARGS=""
	TERMUX_PKG_EXTRA_HOSTBUILD_CONFIGURE_ARGS=""
	TERMUX_PKG_EXTRA_MAKE_ARGS=""
	TERMUX_PKG_BUILD_IN_SRC=""
	TERMUX_PKG_RM_AFTER_INSTALL=""
	TERMUX_PKG_BREAKS="" # https://www.debian.org/doc/debian-policy/ch-relationships.html#s-binarydeps
	TERMUX_PKG_DEPENDS=""
	TERMUX_PKG_BUILD_DEPENDS=""
	TERMUX_PKG_HOMEPAGE=""
	TERMUX_PKG_DESCRIPTION="FIXME:Add description"
	TERMUX_PKG_KEEP_STATIC_LIBRARIES="false"
	TERMUX_PKG_ESSENTIAL=""
	TERMUX_PKG_CONFLICTS="" # https://www.debian.org/doc/debian-policy/ch-relationships.html#s-conflicts
	TERMUX_PKG_RECOMMENDS="" # https://www.debian.org/doc/debian-policy/ch-relationships.html#s-binarydeps
	TERMUX_PKG_SUGGESTS=""
	TERMUX_PKG_REPLACES=""
	TERMUX_PKG_PROVIDES="" #https://www.debian.org/doc/debian-policy/#virtual-packages-provides
	TERMUX_PKG_CONFFILES=""
	TERMUX_PKG_INCLUDE_IN_DEVPACKAGE=""
	TERMUX_PKG_DEVPACKAGE_DEPENDS=""
	# Set if a host build should be done in TERMUX_PKG_HOSTBUILD_DIR:
	TERMUX_PKG_HOSTBUILD=""
	TERMUX_PKG_MAINTAINER="Fredrik Fornwall @fornwall"
	TERMUX_PKG_FORCE_CMAKE=no # if the package has autotools as well as cmake, then set this to prefer cmake
	TERMUX_CMAKE_BUILD=Ninja # Which cmake generator to use
	TERMUX_PKG_HAS_DEBUG=yes # set to no if debug build doesn't exist or doesn't work, for example for python based packages

	unset CFLAGS CPPFLAGS LDFLAGS CXXFLAGS
}

# Save away and restore build setups which may change between builds.
termux_step_handle_buildarch() {
	# If $TERMUX_PREFIX already exists, it may have been built for a different arch
	local TERMUX_ARCH_FILE=/data/TERMUX_ARCH
	if [ -f "${TERMUX_ARCH_FILE}" ]; then
		local TERMUX_PREVIOUS_ARCH
		TERMUX_PREVIOUS_ARCH=$(cat $TERMUX_ARCH_FILE)
		if [ "$TERMUX_PREVIOUS_ARCH" != "$TERMUX_ARCH" ]; then
 			local TERMUX_DATA_BACKUPDIRS=$TERMUX_TOPDIR/_databackups
			mkdir -p "$TERMUX_DATA_BACKUPDIRS"
			local TERMUX_DATA_PREVIOUS_BACKUPDIR=$TERMUX_DATA_BACKUPDIRS/$TERMUX_PREVIOUS_ARCH
			local TERMUX_DATA_CURRENT_BACKUPDIR=$TERMUX_DATA_BACKUPDIRS/$TERMUX_ARCH
			# Save current /data (removing old backup if any)
			if test -e "$TERMUX_DATA_PREVIOUS_BACKUPDIR"; then
				termux_error_exit "Directory already exists"
			fi
			if [ -d /data/data ]; then
				mv /data/data "$TERMUX_DATA_PREVIOUS_BACKUPDIR"
			fi
			# Restore new one (if any)
			if [ -d "$TERMUX_DATA_CURRENT_BACKUPDIR" ]; then
				mv "$TERMUX_DATA_CURRENT_BACKUPDIR" /data/data
			fi
		fi
	fi

	# Keep track of current arch we are building for.
	echo "$TERMUX_ARCH" > $TERMUX_ARCH_FILE
}

# Function to get TERMUX_PKG_VERSION from build.sh
termux_extract_dep_info() {
	package=$1
	(
		# Reset TERMUX_PKG_PLATFORM_INDEPENDENT and TERMUX_PKG_REVISION since these aren't
		# mandatory in a build.sh. Otherwise these will equal the main package's values for
		# deps that should have the default values
		TERMUX_PKG_PLATFORM_INDEPENDENT=""
		TERMUX_PKG_REVISION="0"

		source $package/build.sh
		if [ "$TERMUX_PKG_PLATFORM_INDEPENDENT" = yes ]; then
			TERMUX_ARCH=all
		fi
		if [ ! "$TERMUX_PKG_REVISION" = 0 ]; then
			TERMUX_PKG_VERSION+="-$TERMUX_PKG_REVISION"
		fi
		echo ${TERMUX_ARCH} ${TERMUX_PKG_VERSION}
	)
}

termux_install_dep_deb() {
	local package=$1
	local package_arch=$2
	local version=$3
	local deb_file=${package}_${version}_${package_arch}.deb
	# TODO: download InRelease, Packages files and check signature and hash
	(
		cd ${TERMUX_COMMON_CACHEDIR}-${package_arch}
		# TODO: allow for specifying several repos in TERMUX_REPO_URL
		curl --fail -LO $TERMUX_REPO_URL/binary-${package_arch}/${deb_file} 2>/dev/null \
		    && if [ ! "$TERMUX_QUIET_BUILD" = true ]; then echo "Extracting $package..."; fi \
		    && ar x ${deb_file} data.tar.xz && tar xf data.tar.xz --no-overwrite-dir -C /
		# TODO: this implementation is buggy if the `ar x` or `tar xf
	)
}

# Source the package build script and start building. No to be overridden by packages.
termux_step_start_build() {
	# shellcheck source=/dev/null
	source "$TERMUX_PKG_BUILDER_SCRIPT"

	TERMUX_STANDALONE_TOOLCHAIN="$TERMUX_COMMON_CACHEDIR/${TERMUX_NDK_VERSION}-${TERMUX_ARCH}-${TERMUX_PKG_API_LEVEL}"
	# Bump the below version if a change is made in toolchain setup to ensure
	# that everyone gets an updated toolchain:
	TERMUX_STANDALONE_TOOLCHAIN+="-v4"

	if [ -n "${TERMUX_PKG_BLACKLISTED_ARCHES:=""}" ] && [ "$TERMUX_PKG_BLACKLISTED_ARCHES" != "${TERMUX_PKG_BLACKLISTED_ARCHES/$TERMUX_ARCH/}" ]; then
		echo "Skipping building $TERMUX_PKG_NAME for arch $TERMUX_ARCH"
		exit 0
	fi

	local TERMUX_ALL_DEPS=$(./scripts/buildorder.py "$TERMUX_PKG_BUILDER_DIR")
	if [ "$TERMUX_SKIP_DEPCHECK" = false ] && [ "$TERMUX_INSTALL_DEPS" = true ]; then
		# Ensure folders present (but not $TERMUX_PKG_SRCDIR, it will be created in build)
		mkdir -p "$TERMUX_COMMON_CACHEDIR" \
			 "$TERMUX_COMMON_CACHEDIR-$TERMUX_ARCH" \
			 "$TERMUX_COMMON_CACHEDIR-all" \
			 "$TERMUX_DEBDIR" \
			 "$TERMUX_PKG_BUILDDIR" \
			 "$TERMUX_PKG_PACKAGEDIR" \
			 "$TERMUX_PKG_TMPDIR" \
			 "$TERMUX_PKG_CACHEDIR" \
			 "$TERMUX_PKG_MASSAGEDIR" \
			 $TERMUX_PREFIX/{bin,etc,lib,libexec,share,tmp,include}
		# Setup bootstrap
		termux_download https://termux.net/bootstrap/bootstrap-${TERMUX_ARCH}.zip \
				${TERMUX_COMMON_CACHEDIR}/bootstrap-${TERMUX_ARCH}.zip \
				9f43bfdd23fbc6ae02f1f5a44b8e064374db8291ffe32658e2724d3f3f419981
		unzip -qo ${TERMUX_COMMON_CACHEDIR}/bootstrap-${TERMUX_ARCH}.zip -d $TERMUX_PREFIX
		(
			cd $TERMUX_PREFIX
			while read link; do
				ln -sf ${link/←/ }
			done<SYMLINKS.txt
			rm SYMLINKS.txt
		)

		# Download dependencies
		local pkg dep_arch dep_version
		for pkg in $TERMUX_ALL_DEPS; do
			read dep_arch dep_version <<< $(termux_extract_dep_info "$pkg")
			if [ ! "$TERMUX_QUIET_BUILD" = true ]; then
				echo "Downloading dependency $(basename $pkg) $dep_version if necessary..."
			fi
			termux_install_dep_deb $(basename $pkg) $dep_arch $dep_version \
			    || ( echo "Download of $(basename $pkg) $dep_version from $TERMUX_REPO_URL failed, building instead" \
				     && ./build-package.sh -a $TERMUX_ARCH -s "$pkg" \
				     && continue )

			termux_install_dep_deb $(basename $pkg)-dev $dep_arch $dep_version || \
			    echo "Download of $(basename $pkg)-dev $dep_version from $TERMUX_REPO_URL failed"
		done
	elif [ "$TERMUX_SKIP_DEPCHECK" = false ] && [ "$TERMUX_INSTALL_DEPS" = false ]; then
		# Build dependencies
		local pkg
		for pkg in $TERMUX_ALL_DEPS; do
			echo "Building dependency $p if necessary..."
			# Built dependencies are put in the default TERMUX_DEBDIR instead of the specified one
			./build-package.sh -a $TERMUX_ARCH -s "$p"
		done
	else
		echo "Skipping dependency check"
	fi

	TERMUX_PKG_FULLVERSION=$TERMUX_PKG_VERSION
	if [ "$TERMUX_PKG_REVISION" != "0" ] || [ "$TERMUX_PKG_FULLVERSION" != "${TERMUX_PKG_FULLVERSION/-/}" ]; then
		# "0" is the default revision, so only include it if the upstream versions contains "-" itself
		TERMUX_PKG_FULLVERSION+="-$TERMUX_PKG_REVISION"
	fi

	if [ "$TERMUX_DEBUG" = true ]; then
		if [ "$TERMUX_PKG_HAS_DEBUG" == "yes" ]; then
			DEBUG="-dbg"
		else
			echo "Skipping building debug build for $TERMUX_PKG_NAME"
			exit 0
		fi
	else
		DEBUG=""
	fi

	if [ -z "$TERMUX_DEBUG" ] &&
	   [ -z "${TERMUX_FORCE_BUILD+x}" ] &&
	   [ -e "/data/data/.built-packages/$TERMUX_PKG_NAME" ]; then
		if [ "$(cat "/data/data/.built-packages/$TERMUX_PKG_NAME")" = "$TERMUX_PKG_FULLVERSION" ]; then
			echo "$TERMUX_PKG_NAME@$TERMUX_PKG_FULLVERSION built - skipping (rm /data/data/.built-packages/$TERMUX_PKG_NAME to force rebuild)"
			exit 0
		fi
	fi

	# Cleanup old state:
	rm -Rf "$TERMUX_PKG_BUILDDIR" \
		"$TERMUX_PKG_PACKAGEDIR" \
		"$TERMUX_PKG_SRCDIR" \
		"$TERMUX_PKG_TMPDIR" \
		"$TERMUX_PKG_MASSAGEDIR"

	# Ensure folders present (but not $TERMUX_PKG_SRCDIR, it will be created in build)
	mkdir -p "$TERMUX_COMMON_CACHEDIR" \
		"$TERMUX_DEBDIR" \
		 "$TERMUX_PKG_BUILDDIR" \
		 "$TERMUX_PKG_PACKAGEDIR" \
		 "$TERMUX_PKG_TMPDIR" \
		 "$TERMUX_PKG_CACHEDIR" \
		 "$TERMUX_PKG_MASSAGEDIR" \
		 $TERMUX_PREFIX/{bin,etc,lib,libexec,share,tmp,include}

	# Make $TERMUX_PREFIX/bin/sh executable on the builder, so that build
	# scripts can assume that it works on both builder and host later on:
	ln -f -s /bin/sh "$TERMUX_PREFIX/bin/sh"

	local TERMUX_ELF_CLEANER_SRC=$TERMUX_COMMON_CACHEDIR/termux-elf-cleaner.cpp
	local TERMUX_ELF_CLEANER_VERSION
	TERMUX_ELF_CLEANER_VERSION=$(bash -c ". $TERMUX_SCRIPTDIR/packages/termux-elf-cleaner/build.sh; echo \$TERMUX_PKG_VERSION")
	termux_download \
		"https://raw.githubusercontent.com/termux/termux-elf-cleaner/v$TERMUX_ELF_CLEANER_VERSION/termux-elf-cleaner.cpp" \
		"$TERMUX_ELF_CLEANER_SRC" \
		62c3cf9813756a1b262108fbc39684c5cfd3f9a69b376276bb1ac6af138f5fa2
	if [ "$TERMUX_ELF_CLEANER_SRC" -nt "$TERMUX_ELF_CLEANER" ]; then
		g++ -std=c++11 -Wall -Wextra -pedantic -Os "$TERMUX_ELF_CLEANER_SRC" -o "$TERMUX_ELF_CLEANER"
	fi

	if [ -n "$TERMUX_PKG_BUILD_IN_SRC" ]; then
		echo "Building in src due to TERMUX_PKG_BUILD_IN_SRC being set" > "$TERMUX_PKG_BUILDDIR/BUILDING_IN_SRC.txt"
		TERMUX_PKG_BUILDDIR=$TERMUX_PKG_SRCDIR
	fi

	echo "termux - building $TERMUX_PKG_NAME for arch $TERMUX_ARCH..."
	test -t 1 && printf "\033]0;%s...\007" "$TERMUX_PKG_NAME"

	# Avoid exporting PKG_CONFIG_LIBDIR until after termux_step_host_build.
	export TERMUX_PKG_CONFIG_LIBDIR=$TERMUX_PREFIX/lib/pkgconfig
	# Add a pkg-config file for the system zlib.
	mkdir -p "$TERMUX_PKG_CONFIG_LIBDIR"
	cat > "$TERMUX_PKG_CONFIG_LIBDIR/zlib.pc" <<-HERE
		Name: zlib
		Description: zlib compression library
		Version: 1.2.8
		Requires:
		Libs: -lz
	HERE

	# Keep track of when build started so we can see what files have been created.
	# We start by sleeping so that any generated files above (such as zlib.pc) get
	# an older timestamp than the TERMUX_BUILD_TS_FILE.
	sleep 1
	TERMUX_BUILD_TS_FILE=$TERMUX_PKG_TMPDIR/timestamp_$TERMUX_PKG_NAME
	touch "$TERMUX_BUILD_TS_FILE"
}

# Run just after sourcing $TERMUX_PKG_BUILDER_SCRIPT. May be overridden by packages.
termux_step_extract_package() {
	if [ -z "${TERMUX_PKG_SRCURL:=""}" ] || [ -n "${TERMUX_PKG_SKIP_SRC_EXTRACT:=""}" ]; then
		mkdir -p "$TERMUX_PKG_SRCDIR"
		return
	fi
	cd "$TERMUX_PKG_TMPDIR"
	local PKG_SRCURL=(${TERMUX_PKG_SRCURL[@]})
	local PKG_SHA256=(${TERMUX_PKG_SHA256[@]})
	if  [ ! ${#PKG_SRCURL[@]} == ${#PKG_SHA256[@]} ] && [ ! ${#PKG_SHA256[@]} == 0 ]; then
		termux_error_exit "Error: length of TERMUX_PKG_SRCURL isn't equal to length of TERMUX_PKG_SHA256."
	fi
	# STRIP=1 extracts archives straight into TERMUX_PKG_SRCDIR while STRIP=0 puts them in subfolders. zip has same behaviour per default
	# If this isn't desired then this can be fixed in termux_step_post_extract_package.
	local STRIP=1
	for i in $(seq 0 $(( ${#PKG_SRCURL[@]}-1 ))); do
		test "$i" -gt 0 && STRIP=0
		local filename
		filename=$(basename "${PKG_SRCURL[$i]}")
		local file="$TERMUX_PKG_CACHEDIR/$filename"
		# Allow TERMUX_PKG_SHA256 to be empty:
		set +u
		termux_download "${PKG_SRCURL[$i]}" "$file" "${PKG_SHA256[$i]}"
		set -u

		local folder
		set +o pipefail
		if [ "${file##*.}" = zip ]; then
			folder=`unzip -qql "$file" | head -n1 | tr -s ' ' | cut -d' ' -f5-`
			rm -Rf $folder
			unzip -q "$file"
			mv $folder "$TERMUX_PKG_SRCDIR"
		else
			mkdir -p "$TERMUX_PKG_SRCDIR"
			tar xf "$file" -C "$TERMUX_PKG_SRCDIR" --strip-components=$STRIP
		fi
		set -o pipefail
	done
}

# Hook for packages to act just after the package has been extracted.
# Invoked in $TERMUX_PKG_SRCDIR.
termux_step_post_extract_package() {
        return
}

# Optional host build. Not to be overridden by packages.
termux_step_handle_hostbuild() {
	if [ "x$TERMUX_PKG_HOSTBUILD" = "x" ]; then return; fi

	cd "$TERMUX_PKG_SRCDIR"
	for patch in $TERMUX_PKG_BUILDER_DIR/*.patch.beforehostbuild; do
		test -f "$patch" && sed "s%\@TERMUX_PREFIX\@%${TERMUX_PREFIX}%g" "$patch" | patch --silent -p1
	done

	local TERMUX_HOSTBUILD_MARKER="$TERMUX_PKG_HOSTBUILD_DIR/TERMUX_BUILT_FOR_$TERMUX_PKG_VERSION"
	if [ ! -f "$TERMUX_HOSTBUILD_MARKER" ]; then
		rm -Rf "$TERMUX_PKG_HOSTBUILD_DIR"
		mkdir -p "$TERMUX_PKG_HOSTBUILD_DIR"
		cd "$TERMUX_PKG_HOSTBUILD_DIR"
		termux_step_host_build
		touch "$TERMUX_HOSTBUILD_MARKER"
	fi
}

# Perform a host build. Will be called in $TERMUX_PKG_HOSTBUILD_DIR.
# After termux_step_post_extract_package() and before termux_step_patch_package()
termux_step_host_build() {
	"$TERMUX_PKG_SRCDIR/configure" ${TERMUX_PKG_EXTRA_HOSTBUILD_CONFIGURE_ARGS}
	make -j "$TERMUX_MAKE_PROCESSES"
}

# Setup a standalone Android NDK toolchain. Not to be overridden by packages.
termux_step_setup_toolchain() {
	# We put this after system PATH to avoid picking up toolchain stripped python
	export PATH=$PATH:$TERMUX_STANDALONE_TOOLCHAIN/bin

	export CFLAGS=""
	export LDFLAGS="-L${TERMUX_PREFIX}/lib"

	export AS=${TERMUX_HOST_PLATFORM}-clang
	export CC=$TERMUX_HOST_PLATFORM-clang
	export CXX=$TERMUX_HOST_PLATFORM-clang++

	export AR=$TERMUX_HOST_PLATFORM-ar
	export CPP=${TERMUX_HOST_PLATFORM}-cpp
	export CC_FOR_BUILD=gcc
	export LD=$TERMUX_HOST_PLATFORM-ld
	export OBJDUMP=$TERMUX_HOST_PLATFORM-objdump
	# Setup pkg-config for cross-compiling:
	export PKG_CONFIG=$TERMUX_STANDALONE_TOOLCHAIN/bin/${TERMUX_HOST_PLATFORM}-pkg-config
	export RANLIB=$TERMUX_HOST_PLATFORM-ranlib
	export READELF=$TERMUX_HOST_PLATFORM-readelf
	export STRIP=$TERMUX_HOST_PLATFORM-strip

	# Android 7 started to support DT_RUNPATH (but not DT_RPATH), so we may want
	# LDFLAGS+="-Wl,-rpath=$TERMUX_PREFIX/lib -Wl,--enable-new-dtags"
	# and no longer remove DT_RUNPATH in termux-elf-cleaner.

	if [ "$TERMUX_ARCH" = "arm" ]; then
		# https://developer.android.com/ndk/guides/standalone_toolchain.html#abi_compatibility:
		# "We recommend using the -mthumb compiler flag to force the generation of 16-bit Thumb-2 instructions".
		# With r13 of the ndk ruby 2.4.0 segfaults when built on arm with clang without -mthumb.
		CFLAGS+=" -march=armv7-a -mfpu=neon -mfloat-abi=softfp -mthumb"
		LDFLAGS+=" -march=armv7-a"
	elif [ "$TERMUX_ARCH" = "i686" ]; then
		# From $NDK/docs/CPU-ARCH-ABIS.html:
		CFLAGS+=" -march=i686 -msse3 -mstackrealign -mfpmath=sse"
	elif [ "$TERMUX_ARCH" = "aarch64" ]; then
		:
	elif [ "$TERMUX_ARCH" = "x86_64" ]; then
		:
	else
		termux_error_exit "Invalid arch '$TERMUX_ARCH' - support arches are 'arm', 'i686', 'aarch64', 'x86_64'"
	fi

	if [ -n "$TERMUX_DEBUG" ]; then
		CFLAGS+=" -g3 -O1 -fstack-protector --param ssp-buffer-size=4 -D_FORTIFY_SOURCE=2"
	else
		if [ $TERMUX_ARCH = arm ]; then
			CFLAGS+=" -Os"
		else
			CFLAGS+=" -Oz"
		fi
	fi

	export CXXFLAGS="$CFLAGS"
	export CPPFLAGS="-I${TERMUX_PREFIX}/include"

	# If libandroid-support is declared as a dependency, link to it explicitly:
	if [ "$TERMUX_PKG_DEPENDS" != "${TERMUX_PKG_DEPENDS/libandroid-support/}" ]; then
		LDFLAGS+=" -landroid-support"
	fi

	export ac_cv_func_getpwent=no
	export ac_cv_func_getpwnam=no
	export ac_cv_func_getpwuid=no
	export ac_cv_func_sigsetmask=no
	export ac_cv_c_bigendian=no

	if [ ! -d $TERMUX_STANDALONE_TOOLCHAIN ]; then
		# Do not put toolchain in place until we are done with setup, to avoid having a half setup
		# toolchain left in place if something goes wrong (or process is just aborted):
		local _TERMUX_TOOLCHAIN_TMPDIR=${TERMUX_STANDALONE_TOOLCHAIN}-tmp
		rm -Rf $_TERMUX_TOOLCHAIN_TMPDIR

		local _NDK_ARCHNAME=$TERMUX_ARCH
		if [ "$TERMUX_ARCH" = "aarch64" ]; then
			_NDK_ARCHNAME=arm64
		elif [ "$TERMUX_ARCH" = "i686" ]; then
			_NDK_ARCHNAME=x86
		fi

		"$NDK/build/tools/make_standalone_toolchain.py" \
			--api "$TERMUX_PKG_API_LEVEL" \
			--arch $_NDK_ARCHNAME \
			--stl=libc++ \
			--install-dir $_TERMUX_TOOLCHAIN_TMPDIR

		# Remove android-support header wrapping not needed on android-21:
		rm -Rf $_TERMUX_TOOLCHAIN_TMPDIR/sysroot/usr/local

		if [ "$TERMUX_ARCH" = "aarch64" ]; then
			# Use gold by default to work around https://github.com/android-ndk/ndk/issues/148
			cp $_TERMUX_TOOLCHAIN_TMPDIR/bin/aarch64-linux-android-ld.gold \
			    $_TERMUX_TOOLCHAIN_TMPDIR/bin/aarch64-linux-android-ld
			cp $_TERMUX_TOOLCHAIN_TMPDIR/aarch64-linux-android/bin/ld.gold \
			    $_TERMUX_TOOLCHAIN_TMPDIR/aarch64-linux-android/bin/ld
		fi

		if [ "$TERMUX_ARCH" = "arm" ]; then
			# Linker wrapper script to add '--exclude-libs libgcc.a', see
			# https://github.com/android-ndk/ndk/issues/379
			# https://android-review.googlesource.com/#/c/389852/
			local linker
			for linker in ld ld.bfd ld.gold; do
				local wrap_linker=$_TERMUX_TOOLCHAIN_TMPDIR/$TERMUX_HOST_PLATFORM/bin/$linker
				local real_linker=$_TERMUX_TOOLCHAIN_TMPDIR/$TERMUX_HOST_PLATFORM/bin/$linker.real
				cp $wrap_linker $real_linker
				echo '#!/bin/bash' > $wrap_linker
				echo -n '`dirname $0`/' >> $wrap_linker
				echo -n $linker.real >> $wrap_linker
				echo ' --exclude-libs libgcc.a "$@"' >> $wrap_linker
			done
		fi

		# Setup the cpp preprocessor:
		cp $_TERMUX_TOOLCHAIN_TMPDIR/bin/$TERMUX_HOST_PLATFORM-clang \
		   $_TERMUX_TOOLCHAIN_TMPDIR/bin/$TERMUX_HOST_PLATFORM-cpp
		sed -i 's/clang70/clang70 -E/' \
		   $_TERMUX_TOOLCHAIN_TMPDIR/bin/$TERMUX_HOST_PLATFORM-cpp

		cd $_TERMUX_TOOLCHAIN_TMPDIR/sysroot

		for f in $TERMUX_SCRIPTDIR/ndk-patches/*.patch; do
			sed "s%\@TERMUX_PREFIX\@%${TERMUX_PREFIX}%g" "$f" | \
				sed "s%\@TERMUX_HOME\@%${TERMUX_ANDROID_HOME}%g" | \
				patch --silent -p1;
		done
		# elf.h: Taken from glibc since the elf.h in the NDK is lacking.
		# ifaddrs.h: Added in android-24 unified headers, use a inline implementation for now.
		# langinfo.h: Inline implementation of nl_langinfo().
		# iconv.h: Header for iconv, implemented in libandroid-support.
		cp "$TERMUX_SCRIPTDIR"/ndk-patches/{ifaddrs.h,libintl.h,langinfo.h,iconv.h} usr/include

		# Remove <sys/shm.h> from the NDK in favour of that from the libandroid-shmem.
		# Remove <sys/sem.h> as it doesn't work for non-root.
		# Remove <glob.h> as we currently provide it from libandroid-glob.
		# Remove <spawn.h> as it's only for future (later than android-27).
		rm usr/include/sys/{shm.h,sem.h} usr/include/{glob.h,spawn.h}

		sed -i "s/define __ANDROID_API__ __ANDROID_API_FUTURE__/define __ANDROID_API__ $TERMUX_PKG_API_LEVEL/" \
			usr/include/android/api-level.h

		local _LIBDIR=usr/lib
		if [ $TERMUX_ARCH = x86_64 ]; then _LIBDIR+=64; fi
		$TERMUX_ELF_CLEANER $_LIBDIR/*.so

		# zlib is really version 1.2.8 in the Android platform (at least
		# starting from Android 5), not older as the NDK headers claim.
		for file in zconf.h zlib.h; do
			curl -o usr/include/$file \
			        https://raw.githubusercontent.com/madler/zlib/v1.2.8/$file
		done
		unset file
		cd $_TERMUX_TOOLCHAIN_TMPDIR/include/c++/4.9.x
                sed "s%\@TERMUX_HOST_PLATFORM\@%${TERMUX_HOST_PLATFORM}%g" $TERMUX_SCRIPTDIR/ndk-patches/*.cpppatch | patch -p1
		# Fix relative path in gcc/g++ script:
		sed -i "s%\`dirname \$0\`/../../../../%$NDK/toolchains/%g" $_TERMUX_TOOLCHAIN_TMPDIR/bin/${TERMUX_HOST_PLATFORM}-gcc
		sed -i "s%\`dirname \$0\`/../../../../%$NDK/toolchains/%g" $_TERMUX_TOOLCHAIN_TMPDIR/bin/${TERMUX_HOST_PLATFORM}-g++
		mv $_TERMUX_TOOLCHAIN_TMPDIR $TERMUX_STANDALONE_TOOLCHAIN
	fi

	local _STL_LIBFILE_NAME=libc++_shared.so
	if [ ! -f $TERMUX_PREFIX/lib/libstdc++.so ]; then
		# Setup libc++_shared.so in $PREFIX/lib and libstdc++.so as a link to it,
		# so that other C++ using packages links to it instead of the default android
		# C++ library which does not support exceptions or STL:
		# https://developer.android.com/ndk/guides/cpp-support.html
		# We do however want to avoid installing this, to avoid problems where e.g.
		# libm.so on some i686 devices links against libstdc++.so.
		# The libc++_shared.so library will be packaged in the libc++ package
		# which is part of the base Termux installation.
		mkdir -p "$TERMUX_PREFIX/lib"
		cd "$TERMUX_PREFIX/lib"

		local _STL_LIBFILE=
		if [ "$TERMUX_ARCH" = arm ]; then
			local _STL_LIBFILE=$TERMUX_STANDALONE_TOOLCHAIN/${TERMUX_HOST_PLATFORM}/lib/armv7-a/$_STL_LIBFILE_NAME
		elif [ "$TERMUX_ARCH" = x86_64 ]; then
			local _STL_LIBFILE=$TERMUX_STANDALONE_TOOLCHAIN/${TERMUX_HOST_PLATFORM}/lib64/$_STL_LIBFILE_NAME
		else
			local _STL_LIBFILE=$TERMUX_STANDALONE_TOOLCHAIN/${TERMUX_HOST_PLATFORM}/lib/$_STL_LIBFILE_NAME
		fi

		cp "$_STL_LIBFILE" .
		$STRIP --strip-unneeded $_STL_LIBFILE_NAME
		$TERMUX_ELF_CLEANER $_STL_LIBFILE_NAME
		if [ $TERMUX_ARCH = "arm" ]; then
			# Use a linker script to get libunwind.a.
			echo 'INPUT(-lunwind -lc++_shared)' > libstdc++.so
		else
			ln -f $_STL_LIBFILE_NAME libstdc++.so
		fi
	fi

	export PKG_CONFIG_LIBDIR="$TERMUX_PKG_CONFIG_LIBDIR"
	# Create a pkg-config wrapper. We use path to host pkg-config to
	# avoid picking up a cross-compiled pkg-config later on.
	local _HOST_PKGCONFIG
	_HOST_PKGCONFIG=$(which pkg-config)
	mkdir -p $TERMUX_STANDALONE_TOOLCHAIN/bin "$PKG_CONFIG_LIBDIR"
	cat > "$PKG_CONFIG" <<-HERE
		#!/bin/sh
		export PKG_CONFIG_DIR=
		export PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR
		exec $_HOST_PKGCONFIG "\$@"
	HERE
	chmod +x "$PKG_CONFIG"
}

# Apply all *.patch files for the package. Not to be overridden by packages.
termux_step_patch_package() {
	cd "$TERMUX_PKG_SRCDIR"
	local DEBUG_PATCHES=""
	if [ "$TERMUX_DEBUG" == "true" ] && [ -f $TERMUX_PKG_BUILDER_DIR/*.patch.debug ] ; then
		DEBUG_PATCHES="$(ls $TERMUX_PKG_BUILDER_DIR/*.patch.debug)"
	fi
	# Suffix patch with ".patch32" or ".patch64" to only apply for these bitnesses:
	shopt -s nullglob
	for patch in $TERMUX_PKG_BUILDER_DIR/*.patch{$TERMUX_ARCH_BITS,} $DEBUG_PATCHES; do
		test -f "$patch" && sed "s%\@TERMUX_PREFIX\@%${TERMUX_PREFIX}%g" "$patch" | \
			sed "s%\@TERMUX_HOME\@%${TERMUX_ANDROID_HOME}%g" | \
			patch --silent -p1
	done
	shopt -u nullglob
}

# Replace autotools build-aux/config.{sub,guess} with ours to add android targets.
termux_step_replace_guess_scripts () {
	cd "$TERMUX_PKG_SRCDIR"
	find . -name config.sub -exec chmod u+w '{}' \; -exec cp "$TERMUX_SCRIPTDIR/scripts/config.sub" '{}' \;
	find . -name config.guess -exec chmod u+w '{}' \; -exec cp "$TERMUX_SCRIPTDIR/scripts/config.guess" '{}' \;
}

# For package scripts to override. Called in $TERMUX_PKG_BUILDDIR.
termux_step_pre_configure() {
	return
}

termux_step_configure_autotools () {
	if [ ! -e "$TERMUX_PKG_SRCDIR/configure" ]; then return; fi

	local DISABLE_STATIC="--disable-static"
	if [ "$TERMUX_PKG_EXTRA_CONFIGURE_ARGS" != "${TERMUX_PKG_EXTRA_CONFIGURE_ARGS/--enable-static/}" ]; then
		# Do not --disable-static if package explicitly enables it (e.g. gdb needs enable-static to build)
		DISABLE_STATIC=""
	fi

	local DISABLE_NLS="--disable-nls"
	if [ "$TERMUX_PKG_EXTRA_CONFIGURE_ARGS" != "${TERMUX_PKG_EXTRA_CONFIGURE_ARGS/--enable-nls/}" ]; then
		# Do not --disable-nls if package explicitly enables it (for gettext itself)
		DISABLE_NLS=""
	fi

	local ENABLE_SHARED="--enable-shared"
	if [ "$TERMUX_PKG_EXTRA_CONFIGURE_ARGS" != "${TERMUX_PKG_EXTRA_CONFIGURE_ARGS/--disable-shared/}" ]; then
		ENABLE_SHARED=""
	fi

	local HOST_FLAG="--host=$TERMUX_HOST_PLATFORM"
	if [ "$TERMUX_PKG_EXTRA_CONFIGURE_ARGS" != "${TERMUX_PKG_EXTRA_CONFIGURE_ARGS/--host=/}" ]; then
		HOST_FLAG=""
	fi

	local LIBEXEC_FLAG="--libexecdir=$TERMUX_PREFIX/libexec"
	if [ "$TERMUX_PKG_EXTRA_CONFIGURE_ARGS" != "${TERMUX_PKG_EXTRA_CONFIGURE_ARGS/--libexecdir=/}" ]; then
		LIBEXEC_FLAG=""
	fi

	local QUIET_BUILD=
	if [ ! -z ${TERMUX_QUIET_BUILD+x} ]; then
		QUIET_BUILD="--enable-silent-rules --silent --quiet"
	fi

	# Some packages provides a $PKG-config script which some configure scripts pickup instead of pkg-config:
	mkdir "$TERMUX_PKG_TMPDIR/config-scripts"
	for f in $TERMUX_PREFIX/bin/*config; do
		test -f "$f" && cp "$f" "$TERMUX_PKG_TMPDIR/config-scripts"
	done
	export PATH=$TERMUX_PKG_TMPDIR/config-scripts:$PATH

	# Avoid gnulib wrapping of functions when cross compiling. See
	# http://wiki.osdev.org/Cross-Porting_Software#Gnulib
	# https://gitlab.com/sortix/sortix/wikis/Gnulib
	# https://github.com/termux/termux-packages/issues/76
	local AVOID_GNULIB=""
	AVOID_GNULIB+=" ac_cv_func_nl_langinfo=yes"
	AVOID_GNULIB+=" ac_cv_func_calloc_0_nonnull=yes"
	AVOID_GNULIB+=" ac_cv_func_chown_works=yes"
	AVOID_GNULIB+=" ac_cv_func_getgroups_works=yes"
	AVOID_GNULIB+=" ac_cv_func_malloc_0_nonnull=yes"
	AVOID_GNULIB+=" ac_cv_func_realloc_0_nonnull=yes"
	AVOID_GNULIB+=" am_cv_func_working_getline=yes"
	AVOID_GNULIB+=" gl_cv_func_dup2_works=yes"
	AVOID_GNULIB+=" gl_cv_func_fcntl_f_dupfd_cloexec=yes"
	AVOID_GNULIB+=" gl_cv_func_fcntl_f_dupfd_works=yes"
	AVOID_GNULIB+=" gl_cv_func_fnmatch_posix=yes"
	AVOID_GNULIB+=" gl_cv_func_getcwd_abort_bug=no"
	AVOID_GNULIB+=" gl_cv_func_getcwd_null=yes"
	AVOID_GNULIB+=" gl_cv_func_getcwd_path_max=yes"
	AVOID_GNULIB+=" gl_cv_func_getcwd_posix_signature=yes"
	AVOID_GNULIB+=" gl_cv_func_gettimeofday_clobber=no"
	AVOID_GNULIB+=" gl_cv_func_gettimeofday_posix_signature=yes"
	AVOID_GNULIB+=" gl_cv_func_link_works=yes"
	AVOID_GNULIB+=" gl_cv_func_lstat_dereferences_slashed_symlink=yes"
	AVOID_GNULIB+=" gl_cv_func_malloc_0_nonnull=yes"
	AVOID_GNULIB+=" gl_cv_func_memchr_works=yes"
	AVOID_GNULIB+=" gl_cv_func_mkdir_trailing_dot_works=yes"
	AVOID_GNULIB+=" gl_cv_func_mkdir_trailing_slash_works=yes"
	AVOID_GNULIB+=" gl_cv_func_mkfifo_works=yes"
	AVOID_GNULIB+=" gl_cv_func_mknod_works=yes"
	AVOID_GNULIB+=" gl_cv_func_realpath_works=yes"
	AVOID_GNULIB+=" gl_cv_func_select_detects_ebadf=yes"
	AVOID_GNULIB+=" gl_cv_func_snprintf_posix=yes"
	AVOID_GNULIB+=" gl_cv_func_snprintf_retval_c99=yes"
	AVOID_GNULIB+=" gl_cv_func_snprintf_truncation_c99=yes"
	AVOID_GNULIB+=" gl_cv_func_stat_dir_slash=yes"
	AVOID_GNULIB+=" gl_cv_func_stat_file_slash=yes"
	AVOID_GNULIB+=" gl_cv_func_strerror_0_works=yes"
	AVOID_GNULIB+=" gl_cv_func_symlink_works=yes"
	AVOID_GNULIB+=" gl_cv_func_tzset_clobber=no"
	AVOID_GNULIB+=" gl_cv_func_unlink_honors_slashes=yes"
	AVOID_GNULIB+=" gl_cv_func_unlink_honors_slashes=yes"
	AVOID_GNULIB+=" gl_cv_func_vsnprintf_posix=yes"
	AVOID_GNULIB+=" gl_cv_func_vsnprintf_zerosize_c99=yes"
	AVOID_GNULIB+=" gl_cv_func_wcwidth_works=yes"
	AVOID_GNULIB+=" gl_cv_func_working_getdelim=yes"
	AVOID_GNULIB+=" gl_cv_func_working_mkstemp=yes"
	AVOID_GNULIB+=" gl_cv_func_working_mktime=yes"
	AVOID_GNULIB+=" gl_cv_func_working_strerror=yes"
	AVOID_GNULIB+=" gl_cv_header_working_fcntl_h=yes"
	AVOID_GNULIB+=" gl_cv_C_locale_sans_EILSEQ=yes"

	# NOTE: We do not want to quote AVOID_GNULIB as we want word expansion.
	# shellcheck disable=SC2086
	env $AVOID_GNULIB "$TERMUX_PKG_SRCDIR/configure" \
		--disable-dependency-tracking \
		--prefix=$TERMUX_PREFIX \
		--libdir=$TERMUX_PREFIX/lib \
		--disable-rpath --disable-rpath-hack \
		$HOST_FLAG \
		$TERMUX_PKG_EXTRA_CONFIGURE_ARGS \
		$DISABLE_NLS \
		$ENABLE_SHARED \
		$DISABLE_STATIC \
		$LIBEXEC_FLAG \
		$QUIET_BUILD
}

termux_step_configure_cmake () {
	termux_setup_cmake

	local TOOLCHAIN_ARGS="-DCMAKE_ANDROID_STANDALONE_TOOLCHAIN=$TERMUX_STANDALONE_TOOLCHAIN"
	local BUILD_TYPE=MinSizeRel
	test -n "$TERMUX_DEBUG" && BUILD_TYPE=Debug

	local CMAKE_PROC=$TERMUX_ARCH
	test $CMAKE_PROC == "arm" && CMAKE_PROC='armv7-a'
	local MAKE_PROGRAM_PATH
	if [ $TERMUX_CMAKE_BUILD = Ninja ]; then
		termux_setup_ninja
		MAKE_PROGRAM_PATH=`which ninja`
	else
		MAKE_PROGRAM_PATH=`which make`
	fi

	# XXX: CMAKE_{AR,RANLIB} needed for at least jsoncpp build to not
	# pick up cross compiled binutils tool in $PREFIX/bin:
	cmake -G "$TERMUX_CMAKE_BUILD" "$TERMUX_PKG_SRCDIR" \
		-DCMAKE_AR="$(which $AR)" \
		-DCMAKE_UNAME="$(which uname)" \
		-DCMAKE_RANLIB="$(which $RANLIB)" \
		-DCMAKE_BUILD_TYPE=$BUILD_TYPE \
		-DCMAKE_CROSSCOMPILING=True \
		-DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
		-DCMAKE_CXX_FLAGS="$CXXFLAGS $CPPFLAGS" \
		-DCMAKE_LINKER="$TERMUX_STANDALONE_TOOLCHAIN/bin/$LD $LDFLAGS" \
		-DCMAKE_FIND_ROOT_PATH=$TERMUX_PREFIX \
		-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
		-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
		-DCMAKE_INSTALL_PREFIX=$TERMUX_PREFIX \
		-DCMAKE_MAKE_PROGRAM=$MAKE_PROGRAM_PATH \
		-DCMAKE_SYSTEM_PROCESSOR=$CMAKE_PROC \
		-DCMAKE_SYSTEM_NAME=Android \
		-DCMAKE_SYSTEM_VERSION=$TERMUX_PKG_API_LEVEL \
		-DCMAKE_SKIP_INSTALL_RPATH=ON \
		-DCMAKE_USE_SYSTEM_LIBRARIES=True \
		-DDOXYGEN_EXECUTABLE= \
		-DBUILD_TESTING=OFF \
		$TERMUX_PKG_EXTRA_CONFIGURE_ARGS $TOOLCHAIN_ARGS
}

termux_step_configure_meson () {
	termux_setup_meson
	CC=gcc CXX=g++ $TERMUX_MESON \
		$TERMUX_PKG_SRCDIR \
		$TERMUX_PKG_BUILDDIR \
		--cross-file $TERMUX_MESON_CROSSFILE \
		--prefix $TERMUX_PREFIX \
		--libdir lib \
		--buildtype minsize \
		--strip \
		$TERMUX_PKG_EXTRA_CONFIGURE_ARGS
}

termux_step_configure () {
	if [ "$TERMUX_PKG_FORCE_CMAKE" == 'no' ] && [ -f "$TERMUX_PKG_SRCDIR/configure" ]; then
		termux_step_configure_autotools
	elif [ -f "$TERMUX_PKG_SRCDIR/CMakeLists.txt" ]; then
		termux_step_configure_cmake
	elif [ -f "$TERMUX_PKG_SRCDIR/meson.build" ]; then
		termux_step_configure_meson
	fi
}

termux_step_post_configure () {
	return
}

termux_step_make() {
	local QUIET_BUILD=
	if [ ! -z ${TERMUX_QUIET_BUILD+x} ]; then
		QUIET_BUILD="-s"
	fi

	if test -f build.ninja; then
		ninja -j $TERMUX_MAKE_PROCESSES
	elif ls ./*akefile &> /dev/null || [ ! -z "$TERMUX_PKG_EXTRA_MAKE_ARGS" ]; then
		if [ -z "$TERMUX_PKG_EXTRA_MAKE_ARGS" ]; then
			make -j $TERMUX_MAKE_PROCESSES $QUIET_BUILD
		else
			make -j $TERMUX_MAKE_PROCESSES $QUIET_BUILD ${TERMUX_PKG_EXTRA_MAKE_ARGS}
		fi
	fi
}

termux_step_make_install() {
	if test -f build.ninja; then
		ninja -j $TERMUX_MAKE_PROCESSES install
	elif ls ./*akefile &> /dev/null || [ ! -z "$TERMUX_PKG_EXTRA_MAKE_ARGS" ]; then
		: "${TERMUX_PKG_MAKE_INSTALL_TARGET:="install"}"
		# Some packages have problem with parallell install, and it does not buy much, so use -j 1.
		if [ -z "$TERMUX_PKG_EXTRA_MAKE_ARGS" ]; then
			make -j 1 ${TERMUX_PKG_MAKE_INSTALL_TARGET}
		else
			make -j 1 ${TERMUX_PKG_EXTRA_MAKE_ARGS} ${TERMUX_PKG_MAKE_INSTALL_TARGET}
		fi
	elif test -f Cargo.toml; then
		termux_setup_rust
		cargo install --force \
			--target $CARGO_TARGET_NAME \
			--root $TERMUX_PREFIX \
			$TERMUX_PKG_EXTRA_CONFIGURE_ARGS
		# https://github.com/rust-lang/cargo/issues/3316:
		rm $TERMUX_PREFIX/.crates.toml
	fi
}

# Hook function for package scripts to override.
termux_step_post_make_install() {
	return
}

termux_step_extract_into_massagedir() {
	local TARBALL_ORIG=$TERMUX_PKG_PACKAGEDIR/${TERMUX_PKG_NAME}_orig.tar.gz

	# Build diff tar with what has changed during the build:
	cd $TERMUX_PREFIX
	tar -N "$TERMUX_BUILD_TS_FILE" \
		--exclude='lib/libc++_shared.so' --exclude='lib/libstdc++.so' \
		-czf "$TARBALL_ORIG" .

	# Extract tar in order to massage it
	mkdir -p "$TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX"
	cd "$TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX"
	tar xf "$TARBALL_ORIG"
	rm "$TARBALL_ORIG"
}

termux_step_massage() {
	cd "$TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX"

	# Remove lib/charset.alias which is installed by gettext-using packages:
	rm -f lib/charset.alias

	# Remove non-english man pages:
	test -d share/man && (cd share/man; for f in `ls | grep -v man`; do rm -Rf $f; done )

	if [ -z "${TERMUX_PKG_KEEP_INFOPAGES+x}" ]; then
		# Remove info pages:
		rm -Rf share/info
	fi

	# Remove locale files we're not interested in::
	rm -Rf share/locale
	if [ -z "${TERMUX_PKG_KEEP_SHARE_DOC+x}" ]; then
		# Remove info pages:
		rm -Rf share/doc
	fi

	# Remove old kept libraries (readline):
	find . -name '*.old' -delete

	# Remove static libraries:
	if [ $TERMUX_PKG_KEEP_STATIC_LIBRARIES = "false" ]; then
		find . -name '*.a' -delete
		find . -name '*.la' -delete
	fi

	# Move over sbin to bin:
	for file in sbin/*; do if test -f "$file"; then mv "$file" bin/; fi; done

	# Remove world permissions and add write permissions.
	# The -f flag is used to suppress warnings about dangling symlinks (such
	# as ones to /system/... which may not exist on the build machine):
        find . -exec chmod -f u+w,g-rwx,o-rwx \{\} \;

	if [ "$TERMUX_DEBUG" = "" ]; then
		# Strip binaries. file(1) may fail for certain unusual files, so disable pipefail.
		set +e +o pipefail
		find . -type f | xargs -r file | grep -E "(executable|shared object)" | grep ELF | cut -f 1 -d : | \
			xargs -r "$STRIP" --strip-unneeded --preserve-dates
		set -e -o pipefail
	fi
	# Remove DT_ entries which the android 5.1 linker warns about:
	find . -type f -print0 | xargs -r -0 "$TERMUX_ELF_CLEANER"

	# Fix shebang paths:
	while IFS= read -r -d '' file
	do
		head -c 100 "$file" | grep -E "^#\!.*\\/bin\\/.*" | grep -q -E -v "^#\! ?\\/system" && sed --follow-symlinks -i -E "1 s@^#\!(.*)/bin/(.*)@#\!$TERMUX_PREFIX/bin/\2@" "$file"
	done < <(find -L . -type f -print0)

	test ! -z "$TERMUX_PKG_RM_AFTER_INSTALL" && rm -Rf $TERMUX_PKG_RM_AFTER_INSTALL

	find . -type d -empty -delete # Remove empty directories

	# Sub packages:
	if [ -d include ] && [ -z "${TERMUX_PKG_NO_DEVELSPLIT}" ]; then
		# Add virtual -dev sub package if there are include files:
		local _DEVEL_SUBPACKAGE_FILE=$TERMUX_PKG_TMPDIR/${TERMUX_PKG_NAME}-dev.subpackage.sh
		echo TERMUX_SUBPKG_INCLUDE=\"include share/vala share/man/man3 lib/pkgconfig share/aclocal lib/cmake $TERMUX_PKG_INCLUDE_IN_DEVPACKAGE\" > "$_DEVEL_SUBPACKAGE_FILE"
		echo "TERMUX_SUBPKG_DESCRIPTION=\"Development files for ${TERMUX_PKG_NAME}\"" >> "$_DEVEL_SUBPACKAGE_FILE"
		if [ -n "$TERMUX_PKG_DEVPACKAGE_DEPENDS" ]; then
			echo "TERMUX_SUBPKG_DEPENDS=\"$TERMUX_PKG_NAME,$TERMUX_PKG_DEVPACKAGE_DEPENDS\"" >> "$_DEVEL_SUBPACKAGE_FILE"
		else
			echo "TERMUX_SUBPKG_DEPENDS=\"$TERMUX_PKG_NAME\"" >> "$_DEVEL_SUBPACKAGE_FILE"
		fi
	fi
	# Now build all sub packages
	rm -Rf "$TERMUX_TOPDIR/$TERMUX_PKG_NAME/subpackages"
	for subpackage in $TERMUX_PKG_BUILDER_DIR/*.subpackage.sh $TERMUX_PKG_TMPDIR/*subpackage.sh; do
		test ! -f "$subpackage" && continue
		local SUB_PKG_NAME
		SUB_PKG_NAME=$(basename "$subpackage" .subpackage.sh)
		# Default value is same as main package, but sub package may override:
		local TERMUX_SUBPKG_PLATFORM_INDEPENDENT=$TERMUX_PKG_PLATFORM_INDEPENDENT
		local SUB_PKG_DIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/subpackages/$SUB_PKG_NAME
		local TERMUX_SUBPKG_DEPENDS=""
		local TERMUX_SUBPKG_CONFLICTS=""
		local TERMUX_SUBPKG_REPLACES=""
		local TERMUX_SUBPKG_CONFFILES=""
		local SUB_PKG_MASSAGE_DIR=$SUB_PKG_DIR/massage/$TERMUX_PREFIX
		local SUB_PKG_PACKAGE_DIR=$SUB_PKG_DIR/package
		mkdir -p "$SUB_PKG_MASSAGE_DIR" "$SUB_PKG_PACKAGE_DIR"

		# shellcheck source=/dev/null
		source "$subpackage"

		for includeset in $TERMUX_SUBPKG_INCLUDE; do
			local _INCLUDE_DIRSET
			_INCLUDE_DIRSET=$(dirname "$includeset")
			test "$_INCLUDE_DIRSET" = "." && _INCLUDE_DIRSET=""
			if [ -e "$includeset" ] || [ -L "$includeset" ]; then
				# Add the -L clause to handle relative symbolic links:
				mkdir -p "$SUB_PKG_MASSAGE_DIR/$_INCLUDE_DIRSET"
				mv "$includeset" "$SUB_PKG_MASSAGE_DIR/$_INCLUDE_DIRSET"
			fi
		done

		local SUB_PKG_ARCH=$TERMUX_ARCH
		test -n "$TERMUX_SUBPKG_PLATFORM_INDEPENDENT" && SUB_PKG_ARCH=all

		cd "$SUB_PKG_DIR/massage"
		local SUB_PKG_INSTALLSIZE
		SUB_PKG_INSTALLSIZE=$(du -sk . | cut -f 1)
		tar -cJf "$SUB_PKG_PACKAGE_DIR/data.tar.xz" .

		mkdir -p DEBIAN
		cd DEBIAN
		cat > control <<-HERE
			Package: $SUB_PKG_NAME
			Architecture: ${SUB_PKG_ARCH}
			Installed-Size: ${SUB_PKG_INSTALLSIZE}
			Maintainer: $TERMUX_PKG_MAINTAINER
			Version: $TERMUX_PKG_FULLVERSION
			Homepage: $TERMUX_PKG_HOMEPAGE
		HERE
		test ! -z "$TERMUX_SUBPKG_DEPENDS" && echo "Depends: $TERMUX_SUBPKG_DEPENDS" >> control
		test ! -z "$TERMUX_SUBPKG_CONFLICTS" && echo "Conflicts: $TERMUX_SUBPKG_CONFLICTS" >> control
		test ! -z "$TERMUX_SUBPKG_REPLACES" && echo "Replaces: $TERMUX_SUBPKG_REPLACES" >> control
		echo "Description: $TERMUX_SUBPKG_DESCRIPTION" >> control
		tar -czf "$SUB_PKG_PACKAGE_DIR/control.tar.gz" .

		for f in $TERMUX_SUBPKG_CONFFILES; do echo "$TERMUX_PREFIX/$f" >> conffiles; done

		# Create the actual .deb file:
		TERMUX_SUBPKG_DEBFILE=$TERMUX_DEBDIR/${SUB_PKG_NAME}${DEBUG}_${TERMUX_PKG_FULLVERSION}_${SUB_PKG_ARCH}.deb
		test ! -f "$TERMUX_COMMON_CACHEDIR/debian-binary" && echo "2.0" > "$TERMUX_COMMON_CACHEDIR/debian-binary"
		ar cr "$TERMUX_SUBPKG_DEBFILE" \
				   "$TERMUX_COMMON_CACHEDIR/debian-binary" \
				   "$SUB_PKG_PACKAGE_DIR/control.tar.gz" \
				   "$SUB_PKG_PACKAGE_DIR/data.tar.xz"

		# Go back to main package:
		cd "$TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX"
	done

	# .. remove empty directories (NOTE: keep this last):
	find . -type d -empty -delete
	# Make sure user can read and write all files (problem with dpkg otherwise):
	chmod -R u+rw .
}

termux_step_post_massage() {
	return
}

# Create data.tar.gz with files to package. Not to be overridden by package scripts.
termux_step_create_datatar() {
	# Create data tarball containing files to package:
	cd "$TERMUX_PKG_MASSAGEDIR"

	local HARDLINKS
	HARDLINKS="$(find . -type f -links +1)"
	if [ -n "$HARDLINKS" ]; then
		termux_error_exit "Package contains hard links: $HARDLINKS"
	fi

	if [ -z "${TERMUX_PKG_METAPACKAGE+x}" ] && [ "$(find . -type f)" = "" ]; then
		termux_error_exit "No files in package"
	fi
	tar -cJf "$TERMUX_PKG_PACKAGEDIR/data.tar.xz" .
}

termux_step_create_debscripts() {
	return
}

# Create the build deb file. Not to be overridden by package scripts.
termux_step_create_debfile() {
	# Get install size. This will be written as the "Installed-Size" deb field so is measured in 1024-byte blocks:
	local TERMUX_PKG_INSTALLSIZE
	TERMUX_PKG_INSTALLSIZE=$(du -sk . | cut -f 1)

	# From here on TERMUX_ARCH is set to "all" if TERMUX_PKG_PLATFORM_INDEPENDENT is set by the package
	test -n "$TERMUX_PKG_PLATFORM_INDEPENDENT" && TERMUX_ARCH=all

	mkdir -p DEBIAN
	cat > DEBIAN/control <<-HERE
		Package: $TERMUX_PKG_NAME
		Architecture: ${TERMUX_ARCH}
		Installed-Size: ${TERMUX_PKG_INSTALLSIZE}
		Maintainer: $TERMUX_PKG_MAINTAINER
		Version: $TERMUX_PKG_FULLVERSION
		Homepage: $TERMUX_PKG_HOMEPAGE
	HERE
	test ! -z "$TERMUX_PKG_BREAKS" && echo "Breaks: $TERMUX_PKG_BREAKS" >> DEBIAN/control
	test ! -z "$TERMUX_PKG_DEPENDS" && echo "Depends: $TERMUX_PKG_DEPENDS" >> DEBIAN/control
	test ! -z "$TERMUX_PKG_ESSENTIAL" && echo "Essential: yes" >> DEBIAN/control
	test ! -z "$TERMUX_PKG_CONFLICTS" && echo "Conflicts: $TERMUX_PKG_CONFLICTS" >> DEBIAN/control
	test ! -z "$TERMUX_PKG_RECOMMENDS" && echo "Recommends: $TERMUX_PKG_RECOMMENDS" >> DEBIAN/control
	test ! -z "$TERMUX_PKG_REPLACES" && echo "Replaces: $TERMUX_PKG_REPLACES" >> DEBIAN/control
	test ! -z "$TERMUX_PKG_PROVIDES" && echo "Provides: $TERMUX_PKG_PROVIDES" >> DEBIAN/control
	test ! -z "$TERMUX_PKG_SUGGESTS" && echo "Suggests: $TERMUX_PKG_SUGGESTS" >> DEBIAN/control
	echo "Description: $TERMUX_PKG_DESCRIPTION" >> DEBIAN/control

	# Create DEBIAN/conffiles (see https://www.debian.org/doc/debian-policy/ap-pkg-conffiles.html):
	for f in $TERMUX_PKG_CONFFILES; do echo "$TERMUX_PREFIX/$f" >> DEBIAN/conffiles; done

	# Allow packages to create arbitrary control files.
	# XXX: Should be done in a better way without a function?
	cd DEBIAN
	termux_step_create_debscripts

	# Create control.tar.gz
	tar -czf "$TERMUX_PKG_PACKAGEDIR/control.tar.gz" .

	test ! -f "$TERMUX_COMMON_CACHEDIR/debian-binary" && echo "2.0" > "$TERMUX_COMMON_CACHEDIR/debian-binary"
	TERMUX_PKG_DEBFILE=$TERMUX_DEBDIR/${TERMUX_PKG_NAME}${DEBUG}_${TERMUX_PKG_FULLVERSION}_${TERMUX_ARCH}.deb
	# Create the actual .deb file:
	ar cr "$TERMUX_PKG_DEBFILE" \
	       "$TERMUX_COMMON_CACHEDIR/debian-binary" \
	       "$TERMUX_PKG_PACKAGEDIR/control.tar.gz" \
	       "$TERMUX_PKG_PACKAGEDIR/data.tar.xz"
}

termux_step_reverse_depends() {
	if [ "${TERMUX_INSTALL_DEPS}" = true ]; then
		local arch version
		echo "COMPARING PACKAGES"
		read arch version <<< $(termux_extract_dep_info "$TERMUX_PKG_BUILDER_DIR")
		termux_install_dep_deb $(basename $TERMUX_PKG_BUILDER_DIR) $arch $version
		deb_file=${TERMUX_PKG_NAME}_${version}_${arch}.deb

		(
			cd ${TERMUX_COMMON_CACHEDIR}-${arch}
			# TODO: allow for specifying several repos in TERMUX_REPO_URL
			curl --fail -LO $TERMUX_REPO_URL/binary-${arch}/${deb_file} \
			    && echo "Extracting ${TERMUX_PKG_NAME}..."
		)
		debdiff $TERMUX_DEBDIR/$deb_file $TERMUX_COMMON_CACHEDIR-$arch/$deb_file
		echo "DONE COMPARING PACKAGES"
	fi
}

# Finish the build. Not to be overridden by package scripts.
termux_step_finish_build() {
	echo "termux - build of '$TERMUX_PKG_NAME' done"
	test -t 1 && printf "\033]0;%s - DONE\007" "$TERMUX_PKG_NAME"
	mkdir -p /data/data/.built-packages
	echo "$TERMUX_PKG_FULLVERSION" > "/data/data/.built-packages/$TERMUX_PKG_NAME"
	exit 0
}

termux_step_handle_arguments "$@"
termux_step_setup_variables
termux_step_handle_buildarch
termux_step_start_build
termux_step_extract_package
cd "$TERMUX_PKG_SRCDIR"
termux_step_post_extract_package
termux_step_handle_hostbuild
termux_step_setup_toolchain
termux_step_patch_package
termux_step_replace_guess_scripts
cd "$TERMUX_PKG_SRCDIR"
termux_step_pre_configure
cd "$TERMUX_PKG_BUILDDIR"
termux_step_configure
cd "$TERMUX_PKG_BUILDDIR"
termux_step_post_configure
cd "$TERMUX_PKG_BUILDDIR"
termux_step_make
cd "$TERMUX_PKG_BUILDDIR"
termux_step_make_install
cd "$TERMUX_PKG_BUILDDIR"
termux_step_post_make_install
cd "$TERMUX_PKG_MASSAGEDIR"
termux_step_extract_into_massagedir
cd "$TERMUX_PKG_MASSAGEDIR"
termux_step_massage
cd "$TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX"
termux_step_post_massage
termux_step_create_datatar
termux_step_create_debfile
termux_step_reverse_depends
termux_step_finish_build
