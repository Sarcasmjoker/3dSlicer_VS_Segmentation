cmake_minimum_required(VERSION 3.16.3...3.19.7 FATAL_ERROR)

project(SlicerVSSegmentation)

#-----------------------------------------------------------------------------
# Extension meta-information
set(EXTENSION_HOMEPAGE "https://github.com/your-org/SlicerVSSegmentation")
set(EXTENSION_CATEGORY "Segmentation")
set(EXTENSION_CONTRIBUTORS "VS Segmentation Project")
set(EXTENSION_DESCRIPTION "Automatic vestibular schwannoma (VS) segmentation from ceT1 MRI using nnU-Net v2. Includes intensity normalization and tumor segmentation with Dataset501 (250ep) and Dataset502 (1000ep, mixed cystic) models.")
set(EXTENSION_ICONURL "https://raw.githubusercontent.com/your-org/SlicerVSSegmentation/main/VSSegmentation/Resources/Icons/VSSegmentation.png")
set(EXTENSION_SCREENSHOTURLS "")
set(EXTENSION_DEPENDS "NA")

#-----------------------------------------------------------------------------
# Extension dependencies
find_package(Slicer REQUIRED)
include(${Slicer_USE_FILE})

#-----------------------------------------------------------------------------
# Extension modules
add_subdirectory(VSSegmentation)

#-----------------------------------------------------------------------------
include(${Slicer_EXTENSION_GENERATE_CONFIG})
include(${Slicer_EXTENSION_CPACK})
