# Araso for Linux (docs/linux-port.md): the fcitx5 addon (araso.so, loaded into the fcitx5 daemon,
# which loads the Swift libArasoBridge.so at run time) and the settings window (araso-settings, Qt 6).
# linux/scripts/build.sh builds the bridge and this, and stages a package; install.sh puts it in place.
cmake_minimum_required(VERSION 3.20)
project(Araso LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(ARASO_VERSION "0.0.0" CACHE STRING "Version written into the binaries")
set(ARASO_BRIDGE "" CACHE FILEPATH "libArasoBridge.so to install (swift build --product ArasoBridge)")
set(ARASO_RUNTIME "" CACHE PATH "The Swift runtime libraries the bridge needs, installed beside it")
option(ARASO_SETTINGS "Build the settings window (Qt 6 Widgets)" ON)
option(ARASO_TESTS "Build the addon's tests" ON)

find_package(Fcitx5Core 5.0 REQUIRED)
find_package(Fcitx5Utils REQUIRED)

# fcitx5 finds addons only in its own folder (which differs by distribution: install.sh finds it);
# Araso's own files go to fixed places under fcitx5's prefix.
set(ARASO_LIBDIR "${FCITX_INSTALL_PREFIX}/lib/araso")
set(ARASO_DATADIR "${FCITX_INSTALL_DATADIR}/araso")
set(ARASO_BINDIR "${FCITX_INSTALL_BINDIR}")
configure_file(araso_config.h.in "${CMAKE_CURRENT_BINARY_DIR}/araso_config.h" @ONLY)

set(COMMON ../windows/common/Json.cpp addon/Bridge.cpp)
set(ADDON_CORE addon/Document.cpp addon/Keys.cpp)
add_compile_options(-Wall -Wextra -Wno-unused-parameter)

add_library(araso_core STATIC ${COMMON} ${ADDON_CORE})
target_include_directories(araso_core PUBLIC ../windows/common addon "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(araso_core PUBLIC Fcitx5::Utils ${CMAKE_DL_LIBS})

add_library(araso MODULE addon/Engine.cpp)
target_link_libraries(araso PRIVATE araso_core Fcitx5::Core)
set_target_properties(araso PROPERTIES PREFIX "")

configure_file(data/araso-addon.conf.in "${CMAKE_CURRENT_BINARY_DIR}/araso-addon.conf" @ONLY)
install(TARGETS araso DESTINATION "${FCITX_INSTALL_ADDONDIR}")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/araso-addon.conf" RENAME araso.conf DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")
install(FILES data/araso.conf DESTINATION "${FCITX_INSTALL_PKGDATADIR}/inputmethod")
foreach(size 16 22 24 32 48 64 128 256)
  foreach(icon araso araso-paused)
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/data/icons/${size}/${icon}.png")
      install(FILES "data/icons/${size}/${icon}.png" DESTINATION "${FCITX_INSTALL_DATADIR}/icons/hicolor/${size}x${size}/apps")
    endif()
  endforeach()
endforeach()
install(FILES data/araso-settings.desktop DESTINATION "${FCITX_INSTALL_DATADIR}/applications")

# The data files ArasoCore reads (Resources.swift), the kanji dictionary, and the UI text.
file(GLOB DATA_FILES ../Sources/ArasoCore/Data/*.txt)
install(FILES ${DATA_FILES} DESTINATION "${ARASO_DATADIR}")
install(DIRECTORY ../Resources/ko.lproj Resources/ko.lproj DESTINATION "${ARASO_DATADIR}")
set(DICTIONARY "${CMAKE_CURRENT_SOURCE_DIR}/../.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/Dictionary"
    CACHE PATH "AzooKey's dictionary (in the Swift package's checkout)")
if(EXISTS "${DICTIONARY}")
  install(DIRECTORY "${DICTIONARY}" DESTINATION "${ARASO_DATADIR}")
endif()
if(ARASO_BRIDGE)
  install(FILES "${ARASO_BRIDGE}" DESTINATION "${ARASO_LIBDIR}")
endif()
if(ARASO_RUNTIME)
  install(DIRECTORY "${ARASO_RUNTIME}/" DESTINATION "${ARASO_LIBDIR}" FILES_MATCHING PATTERN "*.so*")
endif()
install(PROGRAMS scripts/uninstall.sh DESTINATION "${ARASO_LIBDIR}")


if(ARASO_SETTINGS)
  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/settings/CMakeLists.txt")
    add_subdirectory(settings)
  endif()
endif()

if(ARASO_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
