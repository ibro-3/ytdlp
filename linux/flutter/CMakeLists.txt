# This file controls Flutter-level build steps. It should not be edited.
cmake_minimum_required(VERSION 3.10)

set(EPHEMERAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/ephemeral")

# Configuration provided via flutter tool.
include(${EPHEMERAL_DIR}/generated_config.cmake)

# TODO: Move the rest of this into files in ephemeral. See
# https://github.com/flutter/flutter/issues/57146.

# Serves the same purpose as list(TRANSFORM ... PREPEND ...),
# which isn't available in 3.10.
function(list_prepend LIST_NAME PREFIX)
    set(NEW_LIST "")
    foreach(element ${${LIST_NAME}})
        list(APPEND NEW_LIST "${PREFIX}${element}")
    endforeach(element)
    set(${LIST_NAME} "${NEW_LIST}" PARENT_SCOPE)
endfunction()

# === Flutter Library ===
# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(${FLUTTER_GTK_PKG_CONFIG_TARGET} REQUIRED IMPORTED_TARGET ${FLUTTER_GTK_PKG_CONFIG_MODULE})
pkg_check_modules(GLIB REQUIRED IMPORTED_TARGET glib-2.0)
pkg_check_modules(GIO REQUIRED IMPORTED_TARGET gio-2.0)

# Set by the parent scope from FLUTTER_TOOLKIT; see linux/CMakeLists.txt.
set(FLUTTER_LIBRARY "${EPHEMERAL_DIR}/${FLUTTER_EMBEDDER_LIBRARY_NAME}")

# Stages an embedder library into ephemeral/ under the name the toolkit expects,
# together with the headers a custom engine build ships beside it. The Flutter
# tool's `unpack_linux` target only ever copies the stable artifact, so anything
# else has to be staged here.
function(stage_embedder library)
  get_filename_component(_library_dir "${library}" DIRECTORY)
  configure_file("${library}" "${FLUTTER_LIBRARY}" COPYONLY)
  message(STATUS "Staged embedder: ${library}")

  # A custom engine build keeps its headers in `flutter_linux/` next to the
  # library; when they are there they are the ones this build has to compile
  # against, so they overwrite whatever the tool unpacked.
  if(EXISTS "${_library_dir}/flutter_linux")
    file(GLOB _embedder_headers "${_library_dir}/flutter_linux/*.h")
    foreach(_embedder_header IN LISTS _embedder_headers)
      configure_file("${_embedder_header}" "${EPHEMERAL_DIR}/flutter_linux/"
        COPYONLY)
    endforeach()
    list(LENGTH _embedder_headers _header_count)
    message(STATUS "Staged ${_header_count} embedder headers from ${_library_dir}")
  endif()
endfunction()

if(FLUTTER_EMBEDDER)
  if(NOT EXISTS "${FLUTTER_EMBEDDER}")
    message(FATAL_ERROR
      "FLUTTER_EMBEDDER points at a file that does not exist: ${FLUTTER_EMBEDDER}")
  endif()
  get_filename_component(_embedder_name "${FLUTTER_EMBEDDER}" NAME)
  if(NOT _embedder_name STREQUAL "${FLUTTER_EMBEDDER_LIBRARY_NAME}")
    message(STATUS "Staging ${_embedder_name} as ${FLUTTER_EMBEDDER_LIBRARY_NAME}")
  endif()
  stage_embedder("${FLUTTER_EMBEDDER}")
elseif(FLUTTER_TOOLKIT STREQUAL "gtk4" AND NOT EXISTS "${FLUTTER_LIBRARY}")
  # No embedder was named, so look for the toolkit's in the engine's artifact
  # cache, which is keyed by build mode exactly as the tool's unpack step is.
  string(TOLOWER "${CMAKE_BUILD_TYPE}" _build_mode)
  # FLUTTER_TARGET_PLATFORM is already `linux-x64`; the engine's artifact cache
  # names its directories after it, suffixed with the build mode when the build
  # is not a debug one.
  set(_engine_artifact_dirs
    "${FLUTTER_ROOT}/bin/cache/artifacts/engine/${FLUTTER_TARGET_PLATFORM}")
  if(NOT _build_mode STREQUAL "debug")
    list(APPEND _engine_artifact_dirs
      "${FLUTTER_ROOT}/bin/cache/artifacts/engine/${FLUTTER_TARGET_PLATFORM}-${_build_mode}")
  endif()

  foreach(_engine_artifact_dir IN LISTS _engine_artifact_dirs)
    if(EXISTS "${_engine_artifact_dir}/${FLUTTER_EMBEDDER_LIBRARY_NAME}")
      set(_embedder_source
        "${_engine_artifact_dir}/${FLUTTER_EMBEDDER_LIBRARY_NAME}")
      break()
    endif()
  endforeach()

  if(_embedder_source)
    stage_embedder("${_embedder_source}")
  else()
    list(JOIN _engine_artifact_dirs ", " _searched_dirs)
    message(FATAL_ERROR
      "A GTK4 Linux build needs the GTK4 embedder (${FLUTTER_EMBEDDER_LIBRARY_NAME}), "
      "which this Flutter SDK does not ship: stable builds "
      "libflutter_linux_gtk.so against GTK3 and has no GTK4 embedder at all.\n"
      "Searched: ${_searched_dirs}\n"
      "Build the default toolkit instead (FLUTTER_TOOLKIT=gtk3, or unset it), or "
      "point FLUTTER_EMBEDDER at a libflutter_linux_gtk4.so from an engine that "
      "ships one.")
  endif()
endif()

# Published to parent scope for install step.
set(FLUTTER_LIBRARY ${FLUTTER_LIBRARY} PARENT_SCOPE)
set(FLUTTER_ICU_DATA_FILE "${EPHEMERAL_DIR}/icudtl.dat" PARENT_SCOPE)
set(PROJECT_BUILD_DIR "${PROJECT_DIR}/build/" PARENT_SCOPE)
set(AOT_LIBRARY "${PROJECT_DIR}/build/lib/libapp.so" PARENT_SCOPE)

list(APPEND FLUTTER_LIBRARY_HEADERS
  "fl_basic_message_channel.h"
  "fl_binary_codec.h"
  "fl_binary_messenger.h"
  "fl_dart_project.h"
  "fl_engine.h"
  "fl_json_message_codec.h"
  "fl_json_method_codec.h"
  "fl_message_codec.h"
  "fl_method_call.h"
  "fl_method_channel.h"
  "fl_method_codec.h"
  "fl_method_response.h"
  "fl_plugin_registrar.h"
  "fl_plugin_registry.h"
  "fl_standard_message_codec.h"
  "fl_standard_method_codec.h"
  "fl_string_codec.h"
  "fl_value.h"
  "fl_view.h"
  "flutter_linux.h"
)
list_prepend(FLUTTER_LIBRARY_HEADERS "${EPHEMERAL_DIR}/flutter_linux/")
add_library(flutter INTERFACE)
target_include_directories(flutter INTERFACE
  "${EPHEMERAL_DIR}"
)
target_link_libraries(flutter INTERFACE "${FLUTTER_LIBRARY}")
target_link_libraries(flutter INTERFACE
  PkgConfig::${FLUTTER_GTK_PKG_CONFIG_TARGET}
  PkgConfig::GLIB
  PkgConfig::GIO
)
add_dependencies(flutter flutter_assemble)

# === Flutter tool backend ===
# _phony_ is a non-existent file to force this command to run every time,
# since currently there's no way to get a full input/output list from the
# flutter tool.
add_custom_command(
  OUTPUT ${FLUTTER_LIBRARY} ${FLUTTER_LIBRARY_HEADERS}
    ${CMAKE_CURRENT_BINARY_DIR}/_phony_
  COMMAND ${CMAKE_COMMAND} -E env
    ${FLUTTER_TOOL_ENVIRONMENT}
    "${FLUTTER_ROOT}/packages/flutter_tools/bin/tool_backend.sh"
      ${FLUTTER_TARGET_PLATFORM} ${CMAKE_BUILD_TYPE}
  VERBATIM
)
add_custom_target(flutter_assemble DEPENDS
  "${FLUTTER_LIBRARY}"
  ${FLUTTER_LIBRARY_HEADERS}
)
