# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(PolyFlixPlayer LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "PolyFlixPlayer")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# 部分第三方插件（典型是 media_kit_libs_windows_video）仍在使用
# add_custom_command(TARGET ...) 而不带 PRE_BUILD/PRE_LINK/POST_BUILD 的旧写法。
# CMake 4.x 的 CMP0175 政策把这种调用视为"参数不合法"，在政策未设置时每次配置
# 都会打印一段 dev 警告。这里显式声明接受旧语义（等价于插件本意的 POST_BUILD），
# 目的只是让日志干净，不改变任何构建行为。
#
# 注意：这里只能设 OLD。设成 NEW 会让 CMake 直接拒绝该调用、配置阶段就失败。
# 用 if(POLICY ...) 守卫，以便兼容还不认识该政策的老版本 CMake（< 3.31）。
if(POLICY CMP0175)
  cmake_policy(SET CMP0175 OLD)
endif()

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# ── 离线构建：优先使用本地预置的 FFmpegKit Windows bundle ────────────────────
# ffmpeg_kit_flutter_new_min 默认在构建时从 GitHub 下载 Windows 预编译库。
# 为了让构建无需外网，仓库约定把解压好的 bundle（含 bin/libffmpegkit.dll）
# 放在 _temp/prebuilt/ffmpeg_kit/bundle 下，构建时自动探测并优先使用；
# 目录不存在时静默回退到插件默认的联网下载，不影响其他机器/CI。
# 也可用 -DFFMPEGKIT_LOCAL_DIR=<path> 或环境变量显式指定，优先级更高。
set(PFLX_FFMPEGKIT_LOCAL_BUNDLE
  "${CMAKE_CURRENT_SOURCE_DIR}/../_temp/prebuilt/ffmpeg_kit/bundle"
  CACHE PATH "本地预置的 FFmpegKit Windows bundle（缺失则联网下载）")

if(NOT FFMPEGKIT_LOCAL_DIR
   AND NOT DEFINED ENV{FFMPEGKIT_LOCAL_DIR}
   AND EXISTS "${PFLX_FFMPEGKIT_LOCAL_BUNDLE}/bin/libffmpegkit.dll")
  set(FFMPEGKIT_LOCAL_DIR "${PFLX_FFMPEGKIT_LOCAL_BUNDLE}" CACHE PATH "" FORCE)
  message(STATUS "PolyFlixPlayer: 使用本地 FFmpegKit bundle -> ${FFMPEGKIT_LOCAL_DIR}")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# ── 离线构建：复用本地预置的 media_kit 归档（libmpv / ANGLE） ───────────────
# media_kit_libs_windows_video 的 CMake 会在配置阶段从 GitHub 下载这两个归档并
# 逐个校验 MD5，任一失败即 FATAL_ERROR 中断构建。仓库约定把归档放在
# _temp/prebuilt/media_kit/ 下，这里在插件配置之前拷进 CMAKE_BINARY_DIR
# （即 build/windows/x64/，插件读取的位置），插件命中后就不会再联网下载。
# 目录或文件缺失时静默跳过，不影响其他机器/CI 的原有下载行为。
set(PFLX_MEDIA_KIT_PREBUILT_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../_temp/prebuilt/media_kit")

foreach(_pflx_archive
    "mpv-dev-x86_64-20230924-git-652a1dd.7z"
    "ANGLE.7z")
  if(EXISTS "${PFLX_MEDIA_KIT_PREBUILT_DIR}/${_pflx_archive}")
    # 覆盖而非"不存在才拷"：上一次构建若下载了损坏文件，插件会因 MD5 不符而中止；
    # 这里直接覆盖成已知正确的归档，插件校验通过后就不会再联网。
    file(COPY "${PFLX_MEDIA_KIT_PREBUILT_DIR}/${_pflx_archive}"
      DESTINATION "${CMAKE_BINARY_DIR}")
    message(STATUS "PolyFlixPlayer: 复用本地 ${_pflx_archive}")
  endif()
endforeach()

# ── 增强播放内核：带图形字幕（PGS / VobSub）解码能力的 libmpv ────────────────
# media_kit_libs_windows_video 自带的是 media-kit 自己裁剪过的 libmpv（28 MB）：
# 它既没有 sup 解复用器、也没有 hdmv_pgs_subtitle 解码器，于是外挂 `.sup` 与视频
# 内置的 PGS 字幕都会"静默不显示"（实测 mpv 日志：Can not open external file /
# Could not find subtitle decoder for format 'hdmv_pgs_subtitle'）。
#
# 这里换成 zhongfly 的 LGPL 全量构建（mpv v0.41 + 完整 ffmpeg，libass /
# libplacebo / d3d11 渲染链齐全），并在安装阶段替换掉 media_kit 那一份，
# 让 media_kit 按默认名字（libmpv-2.dll）直接加载到它，Dart 侧零改动。
# 代价是 DLL 从 28 MB 变成约 96 MB（安装包/安装目录相应变大）。
#
# 想要小体积、不要图形字幕时：cmake 时传 -DPFLX_LIBMPV_ENHANCED=OFF 即可退回
# media_kit 自带的裁剪版内核。
#
# 离线构建：把归档放到 _temp/prebuilt/libmpv_pgs/ 下即可跳过联网（见 README）。
option(PFLX_LIBMPV_ENHANCED
  "使用支持 PGS/VobSub 图形字幕的增强 libmpv（关闭则用 media_kit 自带裁剪版）" ON)

set(PFLX_LIBMPV_ARCHIVE_NAME "mpv-dev-lgpl-x86_64-20260930-git-3186d369f9.7z")
set(PFLX_LIBMPV_URL
  "https://github.com/zhongfly/mpv-winbuild/releases/download/2026-09-30-3186d369f9/${PFLX_LIBMPV_ARCHIVE_NAME}")
set(PFLX_LIBMPV_MD5 "aa37a7093a33fcbdab33c8d0bd00ab34")
set(PFLX_LIBMPV_PREBUILT_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../_temp/prebuilt/libmpv_pgs")
set(PFLX_LIBMPV_SRC_DIR "${CMAKE_BINARY_DIR}/libmpv_pgs")
set(PFLX_LIBMPV_DLL "${PFLX_LIBMPV_SRC_DIR}/libmpv-2.dll")

if(PFLX_LIBMPV_ENHANCED AND NOT EXISTS "${PFLX_LIBMPV_DLL}")
  set(_pflx_libmpv_archive "${CMAKE_BINARY_DIR}/${PFLX_LIBMPV_ARCHIVE_NAME}")

  if(EXISTS "${PFLX_LIBMPV_PREBUILT_DIR}/${PFLX_LIBMPV_ARCHIVE_NAME}")
    message(STATUS "PolyFlixPlayer: 复用本地 ${PFLX_LIBMPV_ARCHIVE_NAME}")
    file(COPY "${PFLX_LIBMPV_PREBUILT_DIR}/${PFLX_LIBMPV_ARCHIVE_NAME}"
      DESTINATION "${CMAKE_BINARY_DIR}")
  elseif(NOT EXISTS "${_pflx_libmpv_archive}")
    message(STATUS "PolyFlixPlayer: 下载增强 libmpv（支持 PGS 图形字幕）...")
    file(DOWNLOAD "${PFLX_LIBMPV_URL}" "${_pflx_libmpv_archive}" STATUS _pflx_dl_status)
    list(GET _pflx_dl_status 0 _pflx_dl_code)
    if(NOT _pflx_dl_code EQUAL 0)
      message(FATAL_ERROR
        "下载增强 libmpv 失败（错误码 ${_pflx_dl_code}）。\n"
        "可手动下载 ${PFLX_LIBMPV_URL}\n"
        "放到 ${PFLX_LIBMPV_PREBUILT_DIR}/ 后重新构建。")
    endif()
  endif()

  file(MD5 "${_pflx_libmpv_archive}" _pflx_libmpv_archive_md5)
  if(NOT _pflx_libmpv_archive_md5 STREQUAL PFLX_LIBMPV_MD5)
    file(REMOVE "${_pflx_libmpv_archive}")
    message(FATAL_ERROR
      "增强 libmpv 归档校验失败（MD5 ${_pflx_libmpv_archive_md5}），已删除，请重新构建。")
  endif()

  # 下载成功的归档回填到离线预置目录：这样 flutter clean 之后不必再下一次
  if(NOT EXISTS "${PFLX_LIBMPV_PREBUILT_DIR}/${PFLX_LIBMPV_ARCHIVE_NAME}")
    file(MAKE_DIRECTORY "${PFLX_LIBMPV_PREBUILT_DIR}")
    file(COPY "${_pflx_libmpv_archive}" DESTINATION "${PFLX_LIBMPV_PREBUILT_DIR}")
    message(STATUS "PolyFlixPlayer: 已回填离线预置 -> ${PFLX_LIBMPV_PREBUILT_DIR}")
  endif()

  file(MAKE_DIRECTORY "${PFLX_LIBMPV_SRC_DIR}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E tar xzf "${_pflx_libmpv_archive}"
    WORKING_DIRECTORY "${PFLX_LIBMPV_SRC_DIR}"
    RESULT_VARIABLE _pflx_libmpv_extract_code)
  if(NOT _pflx_libmpv_extract_code EQUAL 0 OR NOT EXISTS "${PFLX_LIBMPV_DLL}")
    message(FATAL_ERROR "解压增强 libmpv 失败（${_pflx_libmpv_extract_code}）。")
  endif()
  message(STATUS "PolyFlixPlayer: 增强 libmpv 就绪 -> ${PFLX_LIBMPV_DLL}")
endif()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
# CMake >= 4 no longer sets CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT in
# project(), so the original "if (...INITIALIZED_TO_DEFAULT)" guard never
# fires and the prefix falls back to C:/Program Files/<project>, making the
# INSTALL step fail without admin rights. Force it unconditionally instead;
# BUILD_BUNDLE_DIR is a generator expression, evaluated per-build.
set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  if(PFLX_LIBMPV_ENHANCED)
    # media_kit 自带的那份裁剪版 libmpv 不安装：由下面 PFLX_LIBMPV_DLL（增强内核，
    # 支持 PGS / VobSub 图形字幕）接替，避免两份同名 DLL 打架、也省掉 28 MB 冗余。
    list(FILTER PLUGIN_BUNDLED_LIBRARIES EXCLUDE REGEX "libmpv-2\\.dll$")
  endif()
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# 增强播放内核（替换 media_kit 裁剪版 libmpv，见文件开头说明）
if(PFLX_LIBMPV_ENHANCED)
  install(FILES "${PFLX_LIBMPV_DLL}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
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
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
