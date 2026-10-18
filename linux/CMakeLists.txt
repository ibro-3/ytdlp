# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "ytdlp")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.github.ytdlp")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# === Build knobs ===
#
# Three knobs shape the Linux build:
#
#   FLUTTER_TOOLKIT   gtk3 (default) or gtk4 — which GTK the shell, the plugins'
#                     imported target and the embedder library name are built
#                     against
#   FLUTTER_EMBEDDER  path to an embedder library to use instead of the SDK's,
#                     for a custom engine build
#
# Both are read from the environment, because `flutter build` forwards a fixed
# set of CMake arguments and offers no way to add more. An explicit `-DNAME=` on
# a manual CMake invocation wins over the environment; with neither, the value
# cached in the build directory is reused, so nothing can flip halfway through a
# build directory's life.

function(flutter_linux_option_value NAME VALUE OUT_VAR)
  set(_value "${VALUE}")
  foreach(_arg IN LISTS CMAKE_ARGV)
    if(_arg MATCHES "^-D${NAME}=(.*)$")
      set(_value "${CMAKE_MATCH_1}")
    endif()
  endforeach()
  set(${OUT_VAR} "${_value}" PARENT_SCOPE)
endfunction()

flutter_linux_option_value(FLUTTER_TOOLKIT "$ENV{FLUTTER_TOOLKIT}" _toolkit)
if(_toolkit STREQUAL "")
  set(_toolkit "gtk3")
endif()
set(FLUTTER_TOOLKIT "${_toolkit}" CACHE STRING
  "GTK toolkit to build the Linux shell against: gtk3 or gtk4" FORCE)
set_property(CACHE FLUTTER_TOOLKIT PROPERTY STRINGS gtk3 gtk4)
string(TOLOWER "${FLUTTER_TOOLKIT}" FLUTTER_TOOLKIT)

flutter_linux_option_value(FLUTTER_EMBEDDER "$ENV{FLUTTER_EMBEDDER}" _embedder)
set(FLUTTER_EMBEDDER "${_embedder}" CACHE FILEPATH
  "Embedder library to use instead of the SDK's (a custom engine build)" FORCE)

# Each toolkit differs in its pkg-config module, the imported target plugins
# link against, and the name the embedder library is staged under.
if(FLUTTER_TOOLKIT STREQUAL "gtk3")
  set(FLUTTER_GTK_PKG_CONFIG_MODULE "gtk+-3.0")
  set(FLUTTER_GTK_PKG_CONFIG_TARGET "GTK")
  set(FLUTTER_EMBEDDER_LIBRARY_NAME "libflutter_linux_gtk.so")
  add_compile_definitions(FLUTTER_TOOLKIT_GTK3=1)
elseif(FLUTTER_TOOLKIT STREQUAL "gtk4")
  set(FLUTTER_GTK_PKG_CONFIG_MODULE "gtk4")
  set(FLUTTER_GTK_PKG_CONFIG_TARGET "GTK4")
  set(FLUTTER_EMBEDDER_LIBRARY_NAME "libflutter_linux_gtk4.so")
  add_compile_definitions(FLUTTER_TOOLKIT_GTK4=1)
else()
  message(FATAL_ERROR
    "FLUTTER_TOOLKIT must be 'gtk3' or 'gtk4', got '${FLUTTER_TOOLKIT}'.")
endif()

message(STATUS "Linux GTK toolkit: ${FLUTTER_TOOLKIT} "
               "(${FLUTTER_GTK_PKG_CONFIG_MODULE})")

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(${FLUTTER_GTK_PKG_CONFIG_TARGET} REQUIRED IMPORTED_TARGET ${FLUTTER_GTK_PKG_CONFIG_MODULE})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# === GTK3-only plugins ===
#
# Plugins carry their own CMakeLists and some still name GTK3 themselves
# (`url_launcher_linux` today). Linking one into a GTK4 shell is worse than it
# sounds: it would be handed the GTK4 `FlView` and call GTK3 functions on it, so
# the failure shows up as a crash at runtime rather than at build time. A GTK4
# build therefore refuses to start until the plugin set is GTK3-free.
#
# The list is derived from the plugin symlinks rather than hard-coded, so this
# check stops firing by itself once those plugins port.
if(NOT FLUTTER_TOOLKIT STREQUAL "gtk3")
  set(_gtk3_plugins "")
  file(GLOB _plugin_cmakelists
    "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/*/linux/CMakeLists.txt")
  foreach(_plugin_cmakelist IN LISTS _plugin_cmakelists)
    file(READ "${_plugin_cmakelist}" _plugin_cmakelist_contents)
    if(_plugin_cmakelist_contents MATCHES "gtk\\+-3\\.0|PkgConfig::GTK")
      get_filename_component(_plugin_platform_dir "${_plugin_cmakelist}" DIRECTORY)
      get_filename_component(_plugin_name "${_plugin_platform_dir}" DIRECTORY)
      get_filename_component(_plugin_name "${_plugin_name}" NAME)
      list(APPEND _gtk3_plugins "${_plugin_name}")
    endif()
  endforeach()

  if(_gtk3_plugins)
    list(JOIN _gtk3_plugins ", " _gtk3_plugin_list)
    # There is deliberately no override here. A GTK3 plugin inherits GTK4's
    # include path through the `flutter` interface target, so it cannot even be
    # compiled against a GTK4 embedder, let alone run against one.
    message(FATAL_ERROR
      "A GTK4 Linux build needs a GTK3-free plugin set, but these plugins still "
      "build against GTK3: ${_gtk3_plugin_list}. Use the default toolkit "
      "(FLUTTER_TOOLKIT=gtk3), or drop the offending plugins from the "
      "dependency graph.")
  endif()
endif()

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
