cmake_minimum_required(VERSION 3.18...3.31)
project(OrangeApp LANGUAGES CXX CUDA)

# Default build type; override with -DCMAKE_BUILD_TYPE=...
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# Default CUDA arch: A100/A6000-class (80). The Nix flake passes a wider
# list. Override with -DCMAKE_CUDA_ARCHITECTURES=...
if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
    set(CMAKE_CUDA_ARCHITECTURES 80)
endif()

# Find system / Nix-store packages. The Nix flake passes -DOpenCV_DIR=...
# to point find_package(OpenCV) at the Nix-built OpenCV.
find_package(CUDAToolkit REQUIRED)
find_package(OpenCV REQUIRED)
find_package(Threads REQUIRED)
find_package(OpenGL REQUIRED)

# Directories
set(SRC_DIR ${CMAKE_SOURCE_DIR}/src)
set(THIRD_PARTY_DIR ${CMAKE_SOURCE_DIR}/third_party)
set(DIR_IMGUI ${THIRD_PARTY_DIR}/imgui)
set(DIR_IMGUI_BACKEND ${THIRD_PARTY_DIR}/imgui/backends)
set(DIR_IMPLOT ${THIRD_PARTY_DIR}/implot)
set(DIR_FILEBROWSER ${THIRD_PARTY_DIR}/ImGuiFileDialog)
set(DIR_ICONFONT ${THIRD_PARTY_DIR}/IconFontCppHeaders)
set(DIR_NVENCODER ${SRC_DIR}/NvEncoder)
set(DIR_NVENC_API ${CMAKE_SOURCE_DIR}/nvenc_api)

# Dependency prefixes. These are CACHE PATH so the Nix flake (or a user)
# can override them with -DDIR_FFMPEG=... etc.; the defaults preserve the
# legacy developer layout.
set(DIR_ESDK     "/opt/EVT/eSDK"                  CACHE PATH "Emergent eSDK install prefix")
set(DIR_FFMPEG   "$ENV{HOME}/nvidia/ffmpeg/build" CACHE PATH "FFmpeg install prefix")
set(DIR_TENSORRT "$ENV{HOME}/nvidia/TensorRT"     CACHE PATH "TensorRT install prefix")

# Add the source files
file(GLOB ORANGE_SOURCES
    ${SRC_DIR}/*.cpp
    ${DIR_NVENCODER}/*.cpp
)

list(REMOVE_ITEM ORANGE_SOURCES ${SRC_DIR}/orange_headless_client.cpp ${SRC_DIR}/yolo_offline.cpp)

file(GLOB NVENCODER_SOURCES ${PROJECT_SOURCE_DIR}/src/NvEncoder/*.cpp)
# Add sourc files for orange_client
file(GLOB ORANGE_CLIENT_SOURCES
    ${SRC_DIR}/*.cpp
    ${DIR_NVENCODER}/*.cpp
)
list(REMOVE_ITEM ORANGE_CLIENT_SOURCES ${SRC_DIR}/orange.cpp ${SRC_DIR}/yolo_offline.cpp ${SRC_DIR}/yolov8_det.cpp ${SRC_DIR}/opengldisplay.cpp ${SRC_DIR}/FrameDetector.cpp ${SRC_DIR}/realtime_tool.cpp ${SRC_DIR}/detect3d.cpp)

set(YOLO_OFFLINE_SOURCES
    src/yolo_offline.cpp
    src/yolov8_det.cpp
)

# ImGui Sources
set(IMGUI_SOURCES
    ${DIR_IMGUI}/imgui.cpp
    ${DIR_IMGUI}/imgui_demo.cpp
    ${DIR_IMGUI}/imgui_draw.cpp
    ${DIR_IMGUI}/imgui_tables.cpp
    ${DIR_IMGUI}/imgui_widgets.cpp
    ${DIR_IMGUI_BACKEND}/imgui_impl_glfw.cpp
    ${DIR_IMGUI_BACKEND}/imgui_impl_opengl3.cpp
)

# ImPlot Sources
set(IMPLOT_SOURCES
    ${DIR_IMPLOT}/implot.cpp
    ${DIR_IMPLOT}/implot_items.cpp
    ${DIR_IMPLOT}/implot_demo.cpp
)

# FileDialog Source
set(FILEDIALOG_SOURCES
    ${DIR_FILEBROWSER}/ImGuiFileDialog.cpp
)

# Add CUDA sources
set(CUDA_SOURCES
    ${SRC_DIR}/kernel.cu
)

# Add include directories
include_directories(
    ${SRC_DIR}
    ${DIR_IMGUI}
    ${DIR_IMGUI_BACKEND}
    ${DIR_IMPLOT}
    ${DIR_FILEBROWSER}
    ${DIR_ICONFONT}
    ${DIR_NVENCODER}
    ${DIR_NVENC_API}/include
    ${DIR_ESDK}/include
    ${CUDAToolkit_INCLUDE_DIRS}
    ${DIR_FFMPEG}/include
    ${OpenCV_INCLUDE_DIRS}
    ${THIRD_PARTY_DIR}/flatbuffers/include/
    ${DIR_TENSORRT}/include
)

# Add link directories
link_directories(
    ${DIR_ESDK}/lib
    ${CUDAToolkit_LIBRARY_DIR}
    ${DIR_FFMPEG}/lib
    ${DIR_TENSORRT}/lib
)

# Define target
add_executable(orange
    ${ORANGE_SOURCES}
    ${IMGUI_SOURCES}
    ${IMPLOT_SOURCES}
    ${FILEDIALOG_SOURCES}
    ${CUDA_SOURCES}
)

add_executable(orange_client
    ${ORANGE_CLIENT_SOURCES}
    ${CUDA_SOURCES}
)

add_executable(yolo_offline
    ${YOLO_OFFLINE_SOURCES}
    ${CUDA_SOURCES}
)

# Link libraries
# nvidia-encode is a GPU driver library: on Nix it is stubbed at build time
# and injected at runtime via autoAddDriverRunpath; elsewhere it resolves
# from the CUDA toolkit / driver lib dir.
target_link_libraries(orange
    Threads::Threads
    m
    enet
    GLEW
    OpenGL::GL
    CUDA::cudart
    CUDA::cuda_driver
    nppicc
    nppidei
    nvidia-encode
    nppc
    nppig
    nppial
    EmergentCamera
    EmergentGenICam
    EmergentGigEVision
    avformat
    swscale
    swresample
    avutil
    avcodec
    opencv_sfm
    opencv_core
    opencv_imgcodecs
    opencv_imgproc
    opencv_calib3d
    nvinfer
    nvinfer_plugin
    nvToolsExt
    glfw
)

# Link libraries
target_link_libraries(orange_client
    EmergentCamera
    EmergentGenICam
    EmergentGigEVision
    Threads::Threads
    enet
    CUDA::cudart
    CUDA::cuda_driver
    nppicc
    nppidei
    nvidia-encode
    nppc
    avformat
    swscale
    swresample
    avutil
    avcodec
    m
    opencv_sfm
    opencv_core
    opencv_imgcodecs
    opencv_imgproc
)
target_compile_definitions(orange_client PRIVATE HEADLESS)

target_link_libraries(yolo_offline
    opencv_sfm
    opencv_core
    opencv_imgproc
    opencv_videoio
    opencv_highgui
    opencv_video
    nvinfer
    nvinfer_plugin
    CUDA::cudart
    CUDA::cuda_driver
    nppicc
    nppidei
    nvidia-encode
    nppc
    nppig
    nppial
)

# Link pkg-config libraries
find_package(PkgConfig REQUIRED)
pkg_check_modules(GLFW3 REQUIRED glfw3)
target_include_directories(orange PRIVATE ${GLFW3_INCLUDE_DIRS})
target_link_libraries(orange ${GLFW3_LIBRARIES})

# Bake dependency lib dirs into the binaries so they resolve at runtime
# without LD_LIBRARY_PATH.
set_target_properties(orange orange_client PROPERTIES
    BUILD_RPATH   "${DIR_ESDK}/lib;${DIR_TENSORRT}/lib;${DIR_FFMPEG}/lib"
    INSTALL_RPATH "${DIR_ESDK}/lib;${DIR_TENSORRT}/lib;${DIR_FFMPEG}/lib"
)
set_target_properties(yolo_offline PROPERTIES
    BUILD_RPATH   "${DIR_TENSORRT}/lib"
    INSTALL_RPATH "${DIR_TENSORRT}/lib"
)
