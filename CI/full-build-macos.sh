#!/usr/bin/env bash

##############################################################################
# macOS full build script
##############################################################################
#
# This script contains all steps necessary to:
#
#   * Build OBS with all default plugins and dependencies
#   * Create a macOS application bundle
#   * Code-sign the macOS application-bundle
#   * Package a macOS installation image
#   * Notarize macOS application-bundle and/or installation image
#
# Parameters:
#   -b: Create macOS bundle
#   -d: Skip dependency checks
#   -p: Create macOS distribution image
#   -n: Notarize macOS app and disk image (implies bundling)
#   -s: Skip the build process (useful for bundling/packaging only)
#   -h: Print usage help
#
# Environment Variables (optional):
#   MACOS_DEPS_VERSION  : Pre-compiled macOS dependencies version
#   CEF_BUILD_VERSION   : Chromium Embedded Framework version
#   VLC_VERISON         : VLC version
#   SPARKLE_VERSION     : Sparke Framework version
#   BUILD_DIR           : Alternative directory to build OBS in
#
##############################################################################

# Halt on errors
set -eE

## SET UP ENVIRONMENT ##
PRODUCT_NAME="RPAN Studio"

CHECKOUT_DIR="$(git rev-parse --show-toplevel)"
DEPS_BUILD_DIR="${CHECKOUT_DIR}/../obs-build-dependencies"
BUILD_DIR="${BUILD_DIR:-build}"
CI_SCRIPTS="${CHECKOUT_DIR}/CI/scripts/macos"
CI_WORKFLOW="${CHECKOUT_DIR}/.github/workflows/main.yml"
CI_CEF_VERSION=$(cat ${CI_WORKFLOW} | sed -En "s/[ ]+CEF_BUILD_VERSION: '([0-9]+)'/\1/p")
CI_DEPS_VERSION=$(cat ${CI_WORKFLOW} | sed -En "s/[ ]+MACOS_DEPS_VERSION: '([0-9\-]+)'/\1/p")
CI_VLC_VERSION=$(cat ${CI_WORKFLOW} | sed -En "s/[ ]+VLC_VERSION: '([0-9\.]+)'/\1/p")
CI_SPARKLE_VERSION=$(cat ${CI_WORKFLOW} | sed -En "s/[ ]+SPARKLE_VERSION: '([0-9\.]+)'/\1/p")
CI_QT_VERSION=$(cat ${CI_WORKFLOW} | sed -En "s/[ ]+QT_VERSION: '([0-9\.]+)'/\1/p" | head -1)

BUILD_DEPS=(
    "obs-deps ${MACOS_DEPS_VERSION:-${CI_DEPS_VERSION}}"
    "qt-deps ${QT_VERSION:-${CI_QT_VERSION}} ${MACOS_DEPS_VERSION:-${CI_DEPS_VERSION}}"
    "cef ${CEF_BUILD_VERSION:-${CI_CEF_VERSION}}"
    "vlc ${VLC_VERSION:-${CI_VLC_VERSION}}"
    "sparkle ${SPARKLE_VERSION:-${CI_SPARKLE_VERSION}}"
)

if [ -n "${TERM-}" ]; then
    COLOR_RED=$(tput setaf 1)
    COLOR_GREEN=$(tput setaf 2)
    COLOR_BLUE=$(tput setaf 4)
    COLOR_ORANGE=$(tput setaf 3)
    COLOR_RESET=$(tput sgr0)
else
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_BLUE=""
    COLOR_ORANGE=""
    COLOR_RESET=""
fi


MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="$(echo ${MACOS_VERSION} | cut -d '.' -f 1)"
MACOS_MINOR="$(echo ${MACOS_VERSION} | cut -d '.' -f 2)"

## DEFINE UTILITIES ##

hr() {
    echo -e "${COLOR_BLUE}[${PRODUCT_NAME}] ${1}${COLOR_RESET}"
}

step() {
    echo -e "${COLOR_GREEN}  + ${1}${COLOR_RESET}"
}

info() {
    echo -e "${COLOR_ORANGE} + ${1}${COLOR_RESET}"
}

error() {
    echo -e "${COLOR_RED}  + ${1}${COLOR_RESET}"
}

exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_dir() {
    [[ -n ${1} ]] && mkdir -p ${1} && builtin cd ${1}
}

cleanup() {
    rm -rf "${CHECKOUT_DIR}/${BUILD_DIR}/settings.json"
    unset CODESIGN_IDENT
    unset CODESIGN_IDENT_USER
    unset CODESIGN_IDENT_PASS
}

caught_error() {
    error "ERROR during build step: ${1}"
    cleanup
    exit 1
}

## CHECK AND INSTALL DEPENDENCIES ##
install_homebrew_deps() {
    if ! exists brew; then
        error "Homebrew not found - please install homebrew (https://brew.sh)"
        exit 1
    fi

    brew update
    brew bundle --file ${CI_SCRIPTS}/Brewfile

    check_curl
}

check_curl() {
    if [ "${MACOS_MAJOR}" -lt "11" ] && [ "${MACOS_MINOR}" -lt "15" ]; then
        if [ ! -d /usr/local/opt/curl ]; then
            step "Installing Homebrew curl.."
            brew install curl
        fi
        export CURLCMD="/usr/local/opt/curl/bin/curl"
    else
        export CURLCMD="curl"
    fi
}

check_ccache() {
    export PATH=/usr/local/opt/ccache/libexec:${PATH}
    CCACHE_STATUS=$(ccache -s >/dev/null 2>&1 && echo "CCache available." || echo "CCache is not available.")
    info "${CCACHE_STATUS}"
}

## OBS BUILD FROM SOURCE ##
configure_obs_build() {
    ensure_dir "${CHECKOUT_DIR}/${BUILD_DIR}"

    CUR_DATE=$(date +"%Y-%m-%d@%H%M%S")
    NIGHTLY_DIR="${CHECKOUT_DIR}/nightly-${CUR_DATE}"
    PACKAGE_NAME=$(find . -name "*.dmg")

    if [ -d ./RPANStudio.app ]; then
        ensure_dir "${NIGHTLY_DIR}"
        mv ../${BUILD_DIR}/RPANStudio.app .
        info "You can find RPANStudio.app in ${NIGHTLY_DIR}"
    fi
    ensure_dir "${CHECKOUT_DIR}/${BUILD_DIR}"
    if ([ -n "${PACKAGE_NAME}" ] && [ -f ${PACKAGE_NAME} ]); then
        ensure_dir "${NIGHTLY_DIR}"
        mv ../${BUILD_DIR}/$(basename "${PACKAGE_NAME}") .
        info "You can find ${PACKAGE_NAME} in ${NIGHTLY_DIR}"
    fi

    ensure_dir "${CHECKOUT_DIR}/${BUILD_DIR}"

    hr "Run CMAKE for OBS..."
    cmake -DENABLE_SPARKLE_UPDATER=ON \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=10.13 \
        -DDISABLE_PYTHON=ON  \
        -DQTDIR="/usr/local/Cellar/qt/5.14.1" \
        -DSWIGDIR="/tmp/obsdeps" \
        -DDepsPath="/tmp/obsdeps" \
        -DVLCPath="${DEPS_BUILD_DIR}/vlc-${VLC_VERSION:-${CI_VLC_VERSION}}" \
        -DBUILD_BROWSER=ON \
        -DBROWSER_DEPLOY=ON \
        -DBUILD_CAPTIONS=ON \
        -DWITH_RTMPS=ON \
        -DCEF_ROOT_DIR="${DEPS_BUILD_DIR}/cef_binary_${CEF_BUILD_VERSION:-${CI_CEF_VERSION}}_macosx64" \
        -DOBS_VERSION_OVERRIDE="${OBS_VERSION_OVERRIDE}" \
        -DREDDIT_CLIENTID=${REDDIT_CLIENTID} \
        -DREDDIT_HASH=${REDDIT_HASH} \
        -DREDDIT_HMAC_GLOBAL_VERSION=${REDDIT_HMAC_GLOBAL_VERSION} \
        -DREDDIT_HMAC_PLATFORM=${REDDIT_HMAC_PLATFORM} \
        -DREDDIT_HMAC_TOKEN_VERSION=${REDDIT_HMAC_TOKEN_VERSION} \
        -DREDDIT_SECRET=${REDDIT_SECRET} \
        ..

}

run_obs_build() {
    ensure_dir "${CHECKOUT_DIR}/${BUILD_DIR}"
    hr "Build RPAN Studio..."
    make -j4
}

## OBS BUNDLE AS MACOS APPLICATION ##
bundle_dylibs() {
    ensure_dir "${CHECKOUT_DIR}/${BUILD_DIR}"

    if [ ! -d ./RPANStudio.app ]; then
        error "No RPANStudio.app bundle found"
        exit 1
    fi

    hr "Bundle dylibs for macOS application"

    step "Run dylibBundler.."
    ${CI_SCRIPTS}/app/dylibbundler -cd -of -a ./RPANStudio.app -q -f \
        -s ./RPANStudio.app/Contents/MacOS \
        -s "${DEPS_BUILD_DIR}/sparkle/Sparkle.framework" \
        -s ./rundir/RelWithDebInfo/bin/ \
        -x ./RPANStudio.app/Contents/PlugIns/coreaudio-encoder.so \
        -x ./RPANStudio.app/Contents/PlugIns/decklink-ouput-ui.so \
        -x ./RPANStudio.app/Contents/PlugIns/frontend-tools.so \
        -x ./RPANStudio.app/Contents/PlugIns/image-source.so \
        -x ./RPANStudio.app/Contents/PlugIns/linux-jack.so \
        -x ./RPANStudio.app/Contents/PlugIns/mac-avcapture.so \
        -x ./RPANStudio.app/Contents/PlugIns/mac-capture.so \
        -x ./RPANStudio.app/Contents/PlugIns/mac-decklink.so \
        -x ./RPANStudio.app/Contents/PlugIns/mac-syphon.so \
        -x ./RPANStudio.app/Contents/PlugIns/mac-vth264.so \
        -x ./RPANStudio.app/Contents/PlugIns/obs-browser.so \
        -x ./RPANStudio.app/Contents/PlugIns/obs-browser-page \
        -x ./RPANStudio.app/Contents/PlugIns/obs-ffmpeg.so \
        -x ./RPANStudio.app/Contents/PlugIns/obs-filters.so \
        -x ./RPANStudio.app/Contents/PlugIns/obs-transitions.so \
        -x ./RPANStudio.app/Contents/PlugIns/obs-vst.so \
        -x ./RPANStudio.app/Contents/PlugIns/rtmp-services.so \
        -x ./RPANStudio.app/Contents/MacOS/obs-ffmpeg-mux \
        -x ./RPANStudio.app/Contents/MacOS/obslua.so \
        -x ./RPANStudio.app/Contents/PlugIns/obs-x264.so \
        -x ./RPANStudio.app/Contents/PlugIns/text-freetype2.so \
        -x ./RPANStudio.app/Contents/PlugIns/obs-libfdk.so \
        -x ./RPANStudio.app/Contents/PlugIns/obs-outputs.so
    step "Move libobs-opengl to final destination"
    cp ./libobs-opengl/libobs-opengl.so ./RPANStudio.app/Contents/Frameworks

    #step "Copy QtNetwork for plugin support"
    #cp -R /tmp/obsdeps/lib/QtNetwork.framework ./RPANStudio.app/Contents/Frameworks
    #chmod -R +w ./RPANStudio.app/Contents/Frameworks/QtNetwork.framework
    #rm -r ./RPANStudio.app/Contents/Frameworks/QtNetwork.framework/Headers
    #rm -r ./RPANStudio.app/Contents/Frameworks/QtNetwork.framework/Versions/5/Headers/
    #chmod 644 ./RPANStudio.app/Contents/Frameworks/QtNetwork.framework/Versions/5/Resources/Info.plist
    #install_name_tool -id @executable_path/../Frameworks/QtNetwork.framework/Versions/5/QtNetwork ./RPANStudio.app/Contents/Frameworks/QtNetwork.framework/Versions/5/QtNetwork
    #install_name_tool -change /tmp/obsdeps/lib/QtCore.framework/Versions/5/QtCore @executable_path/../Frameworks/QtCore.framework/Versions/5/QtCore ./RPANStudio.app/Contents/Frameworks/QtNetwork.framework/Versions/5/QtNetwork
}

install_frameworks() {
    ensure_dir "${CHECKOUT_DIR}/${BUILD_DIR}"

    if [ ! -d ./RPANStudio.app ]; then
        error "No RPANStudio.app bundle found"
        exit 1
    fi

    hr "Adding Chromium Embedded Framework"
    step "Copy Framework..."
    sudo cp -R "${DEPS_BUILD_DIR}/cef_binary_${CEF_BUILD_VERSION:-${CI_CEF_VERSION}}_macosx64/Release/Chromium Embedded Framework.framework" ./RPANStudio.app/Contents/Frameworks/
    sudo chown -R $(whoami) ./RPANStudio.app/Contents/Frameworks/
}

prepare_macos_bundle() {
    ensure_dir "${CHECKOUT_DIR}/${BUILD_DIR}"

    if [ ! -d ./rundir/RelWithDebInfo/bin ]; then
        error "No OBS build found"
        return
    fi

    if [ -d ./RPANStudio.app ]; then rm -rf ./RPANStudio.app; fi

    hr "Preparing RPANStudio.app bundle"
    step "Copy binary and plugins..."
    mkdir -p RPANStudio.app/Contents/MacOS
    mkdir RPANStudio.app/Contents/PlugIns
    mkdir RPANStudio.app/Contents/Resources

    cp rundir/RelWithDebInfo/bin/obs ./RPANStudio.app/Contents/MacOS
    cp rundir/RelWithDebInfo/bin/obs-ffmpeg-mux ./RPANStudio.app/Contents/MacOS
    cp rundir/RelWithDebInfo/bin/libobsglad.0.dylib ./RPANStudio.app/Contents/MacOS
    cp -R rundir/RelWithDebInfo/data ./RPANStudio.app/Contents/Resources
    cp ${CI_SCRIPTS}/app/rpan-studio.icns ./RPANStudio.app/Contents/Resources
    cp -R rundir/RelWithDebInfo/obs-plugins/ ./RPANStudio.app/Contents/PlugIns
    cp ${CI_SCRIPTS}/app/Info.plist ./RPANStudio.app/Contents
    # Scripting plugins are required to be placed in same directory as binary
    if [ -d ./RPANStudio.app/Contents/Resources/data/obs-scripting ]; then
        mv ./RPANStudio.app/Contents/Resources/data/obs-scripting/obslua.so ./RPANStudio.app/Contents/MacOS/
        # mv ./RPANStudio.app/Contents/Resources/data/obs-scripting/_obspython.so ./RPANStudio.app/Contents/MacOS/
        # mv ./RPANStudio.app/Contents/Resources/data/obs-scripting/obspython.py ./RPANStudio.app/Contents/MacOS/
        rm -rf ./RPANStudio.app/Contents/Resources/data/obs-scripting/
    fi

    bundle_dylibs
    install_frameworks

    cp ${CI_SCRIPTS}/app/OBSPublicDSAKey.pem ./RPANStudio.app/Contents/Resources

    step "Set bundle meta information..."
    plutil -insert CFBundleVersion -string ${GIT_TAG}-${GIT_HASH} ./RPANStudio.app/Contents/Info.plist
    plutil -insert CFBundleShortVersionString -string ${GIT_TAG}-${GIT_HASH} ./RPANStudio.app/Contents/Info.plist
    plutil -insert OBSFeedsURL -string https://obsproject.com/osx_update/feeds.xml ./RPANStudio.app/Contents/Info.plist
    plutil -insert SUFeedURL -string https://obsproject.com/osx_update/stable/updates.xml ./RPANStudio.app/Contents/Info.plist
    plutil -insert SUPublicDSAKeyFile -string OBSPublicDSAKey.pem ./RPANStudio.app/Contents/Info.plist
}

## CREATE MACOS DISTRIBUTION AND INSTALLER IMAGE ##
prepare_macos_image() {
    ensure_dir "${CHECKOUT_DIR}/${BUILD_DIR}"

    if [ ! -d ./RPANStudio.app ]; then
        error "No RPANStudio.app bundle found"
        return
    fi

    hr "Preparing macOS installation image"

    if [ -f "${FILE_NAME}" ]; then
        rm "${FILE_NAME}"
    fi

    step "Run dmgbuild..."
    cp -R RPANStudio.app RPAN\ Studio.app
    cp "${CI_SCRIPTS}/package/settings.json.template" ./settings.json
    sed -i '' 's#\$\$VERSION\$\$#'"${OBS_VERSION_OVERRIDE}"'#g' ./settings.json
    sed -i '' 's#\$\$CI_PATH\$\$#'"${CI_SCRIPTS}"'#g' ./settings.json
    sed -i '' 's#\$\$BUNDLE_PATH\$\$#'"${CHECKOUT_DIR}"'/build#g' ./settings.json
    echo -n "${COLOR_ORANGE}"
    dmgbuild "RPAN Studio" "${FILE_NAME}" -s ./settings.json
    rm -rf RPAN\ Studio.app
    echo -n "${COLOR_RESET}"

    if [ -n "${CODESIGN_OBS}" ]; then
        codesign_image
    fi
}

## SET UP CODE SIGNING AND NOTARIZATION CREDENTIALS ##
##############################################################################
# Apple Developer Identity needed:
#
#    + Signing the code requires a developer identity in the system's keychain
#    + codesign will look up and find the identity automatically
#
##############################################################################
read_codesign_ident() {
    if [ ! -n "${CODESIGN_IDENT}" ]; then
        step "Code-signing Setup"
        read -p "${COLOR_ORANGE}  + Apple developer identity: ${COLOR_RESET}" CODESIGN_IDENT
    fi
}

##############################################################################
# Apple Developer credentials necessary:
#
#   + Signing for distribution and notarization require an active Apple
#     Developer membership
#   + An Apple Development identity is needed for code signing
#     (i.e. 'Apple Development: YOUR APPLE ID (PROVIDER)')
#   + Your Apple developer ID is needed for notarization
#   + An app-specific password is necessary for notarization from CLI
#   + This password will be stored in your macOS keychain under the identifier
#     'OBS-Codesign-Password'with access Apple's 'altool' only.
##############################################################################

read_codesign_pass() {
    if [ ! -n "${CODESIGN_IDENT_PASS}" ]; then
        step "Notarization Setup"
        read -p "${COLOR_ORANGE}  + Apple account id: ${COLOR_RESET}" CODESIGN_IDENT_USER
        CODESIGN_IDENT_PASS=$(stty -echo; read -p "${COLOR_ORANGE}  + Apple developer password: ${COLOR_RESET}" pwd; stty echo; echo $pwd)
        echo -n "${COLOR_ORANGE}"
        xcrun altool --store-password-in-keychain-item "OBS-Codesign-Password" -u "${CODESIGN_IDENT_USER}" -p "${CODESIGN_IDENT_PASS}"
        echo -n "${COLOR_RESET}"
        CODESIGN_IDENT_SHORT=$(echo "${CODESIGN_IDENT}" | sed -En "s/.+\((.+)\)/\1/p")
    fi
}

codesign_bundle() {
    if [ ! -n "${CODESIGN_OBS}" ]; then step "Skipping application bundle code signing"; return; fi

    ensure_dir "${CHECKOUT_DIR}/${BUILD_DIR}"
    trap "caught_error 'code-signing app'" ERR

    if [ ! -d ./RPANStudio.app ]; then
        error "No RPANStudio.app bundle found"
        return
    fi

    hr "Code-signing application bundle"

    xattr -crs ./RPANStudio.app

    read_codesign_ident
    step "Code-sign Sparkle framework..."
    echo -n "${COLOR_ORANGE}"
    codesign --force --options runtime --sign "${CODESIGN_IDENT}" "./RPANStudio.app/Contents/Frameworks/Sparkle.framework/Versions/A/Resources/Autoupdate.app/Contents/MacOS/fileop"
    codesign --force --options runtime --sign "${CODESIGN_IDENT}" "./RPANStudio.app/Contents/Frameworks/Sparkle.framework/Versions/A/Resources/Autoupdate.app/Contents/MacOS/Autoupdate"
    codesign --force --options runtime --sign "${CODESIGN_IDENT}" --deep ./RPANStudio.app/Contents/Frameworks/Sparkle.framework
    echo -n "${COLOR_RESET}"

    step "Code-sign CEF framework..."
    echo -n "${COLOR_ORANGE}"
    codesign --force --options runtime --sign "${CODESIGN_IDENT}" "./RPANStudio.app/Contents/Frameworks/Chromium Embedded Framework.framework/Libraries/libEGL.dylib"
    codesign --force --options runtime --sign "${CODESIGN_IDENT}" "./RPANStudio.app/Contents/Frameworks/Chromium Embedded Framework.framework/Libraries/libswiftshader_libEGL.dylib"
    codesign --force --options runtime --sign "${CODESIGN_IDENT}" "./RPANStudio.app/Contents/Frameworks/Chromium Embedded Framework.framework/Libraries/libGLESv2.dylib"
    codesign --force --options runtime --sign "${CODESIGN_IDENT}" "./RPANStudio.app/Contents/Frameworks/Chromium Embedded Framework.framework/Libraries/libswiftshader_libGLESv2.dylib"
    codesign --force --options runtime --sign "${CODESIGN_IDENT}" --deep "./RPANStudio.app/Contents/Frameworks/Chromium Embedded Framework.framework"
    echo -n "${COLOR_RESET}"

    step "Code-sign OBS code..."
    echo -n "${COLOR_ORANGE}"
    codesign --force --options runtime --entitlements "${CI_SCRIPTS}/app/entitlements.plist" --sign "${CODESIGN_IDENT}" --deep ./RPANStudio.app
    echo -n "${COLOR_RESET}"
    step "Check code-sign result..."
    codesign -dvv ./RPANStudio.app
}

codesign_image() {
    if [ ! -n "${CODESIGN_OBS}" ]; then step "Skipping installer image code signing"; return; fi

    ensure_dir "${CHECKOUT_DIR}/${BUILD_DIR}"
    trap "caught_error 'code-signing image'" ERR

    if [ ! -f "${FILE_NAME}" ]; then
        error "No RPAN Studio disk image found"
        return
    fi

    hr "Code-signing installation image"

    read_codesign_ident

    step "Code-sign OBS installer image..."
    echo -n "${COLOR_ORANGE}";
    codesign --force --sign "${CODESIGN_IDENT}" "${FILE_NAME}"
    echo -n "${COLOR_RESET}"
    step "Check code-sign result..."
    codesign -dvv "${FILE_NAME}"
}

## BUILD FROM SOURCE META FUNCTION ##
full-build-macos() {
    if [ -n "${SKIP_BUILD}" ]; then step "Skipping full build"; return; fi

    if [ ! -n "${SKIP_DEPS}" ]; then

        hr "Installing Homebrew dependencies"
        install_homebrew_deps

        for DEPENDENCY in "${BUILD_DEPS[@]}"; do
            set -- ${DEPENDENCY}
            trap "caught_error ${DEPENDENCY}" ERR
            FUNC_NAME="install_${1}"
            ${FUNC_NAME} ${2} ${3}
        done

        check_ccache
        trap "caught_error 'cmake'" ERR
    fi

    configure_obs_build
    run_obs_build
}

## BUNDLE MACOS APPLICATION META FUNCTION ##
bundle_macos() {
    if [ ! -n "${BUNDLE_OBS}" ]; then step "Skipping application bundle creation"; return; fi

    hr "Creating macOS app bundle"
    trap "caught_error 'bundle app'" ERR
    ensure_dir ${CHECKOUT_DIR}
    prepare_macos_bundle
}

## PACKAGE MACOS DISTRIBUTION IMAGE META FUNCTION ##
package_macos() {
    if [ ! -n "${PACKAGE_OBS}" ]; then step "Skipping installer image creation"; return; fi

    hr "Creating macOS .dmg image"
    trap "caught_error 'package app'" ERR

    prepare_macos_image
}

## NOTARIZATION META FUNCTION ##
notarize_macos() {
    if [ ! -n "${NOTARIZE_OBS}" ]; then step "Skipping macOS notarization"; return; fi;

    hr "Notarizing OBS for macOS"
    trap "caught_error 'notarizing app'" ERR

    ensure_dir "${CHECKOUT_DIR}/${BUILD_DIR}"

    if [ -f "${FILE_NAME}" ]; then
        NOTARIZE_TARGET="${FILE_NAME}"
        xcnotary precheck "./RPANStudio.app"
    elif [ -d "RPANStudio.app" ]; then
        NOTARIZE_TARGET="./RPANStudio.app"
    else
        error "No notarization app bundle ('RPANStudio.app') or disk image ('${FILE_NAME}') found"
        return
    fi

    if [ "$?" -eq 0 ]; then
        read_codesign_ident
        read_codesign_pass

        step "Run xcnotary with ${NOTARIZE_TARGET}..."
        echo xcnotary notarize "${NOTARIZE_TARGET}" --developer-account "${CODESIGN_IDENT_USER}" --developer-password-keychain-item "OBS-Codesign-Password" --provider "${CODESIGN_IDENT_SHORT}"
    fi
}

## MAIN SCRIPT FUNCTIONS ##
print_usage() {
    echo -e "full-build-macos.sh - Build helper script for RPAN Studio\n"
    echo -e "Usage: ${0}\n" \
        "-d: Skip dependency checks\n" \
        "-b: Create macOS app bundle\n" \
        "-c: Codesign macOS app bundle\n" \
        "-p: Package macOS app into disk image\n" \
        "-n: Notarize macOS app and disk image (implies -b)\n" \
        "-s: Skip build process (useful for bundling/packaging only)\n" \
        "-h: Print this help"
    exit 0
}

obs-build-main() {
    ensure_dir ${CHECKOUT_DIR}
    step "Fetching tags..."
    git fetch origin --tags
    GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    GIT_HASH=$(git rev-parse --short HEAD)
    GIT_TAG=$(git describe --tags --abbrev=0)
    FILE_NAME="rpan-studio-${OBS_VERSION_OVERRIDE}-macOS.dmg"

    ##########################################################################
    # IMPORTANT:
    #
    # Be careful when choosing to notarize and code-sign. The script will try
    # to sign any pre-existing bundle but also pre-existing images.
    #
    # This could lead to a package containing a non-signed bundle, which
    # will then fail notarization.
    #
    # To avoid this, run this script with -b -c first, then -p -c or -p -n
    # after to make sure that a code-signed bundle will be packaged.
    #
    ##########################################################################

    while getopts ":hdsbnpc" OPTION; do
        case ${OPTION} in
            h) print_usage ;;
            d) SKIP_DEPS=1 ;;
            s) SKIP_BUILD=1 ;;
            b) BUNDLE_OBS=1 ;;
            n) CODESIGN_OBS=1; NOTARIZE_OBS=1 ;;
            p) PACKAGE_OBS=1 ;;
            c) CODESIGN_OBS=1 ;;
            \?) ;;
        esac
    done

    full-build-macos
    bundle_macos
    codesign_bundle
    package_macos
    codesign_image
    notarize_macos

    cleanup
}

obs-build-main $*
