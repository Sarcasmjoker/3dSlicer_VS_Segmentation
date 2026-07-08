cmake_minimum_required(VERSION 3.16.3...3.19.7 FATAL_ERROR)

project(VSSegmentation)

#-----------------------------------------------------------------------------
# Extension meta-information
set(EXTENSION_HOMEPAGE "https://github.com/your-org/SlicerVSSegmentation")
set(EXTENSION_CATEGORY "Segmentation")
set(EXTENSION_CONTRIBUTORS "VS Segmentation Project")
set(EXTENSION_DESCRIPTION "Vestibular schwannoma segmentation from ceT1 MRI.")

#-----------------------------------------------------------------------------
# Module files
set(MODULE_PYTHON_SCRIPTS
  VSSegmentation.py
  )

set(MODULE_PYTHON_RESOURCES
  Resources/Icons/VSSegmentation.png
  Resources/UI/VSSegmentation.ui
  )

#-----------------------------------------------------------------------------
ctkMacroCompilePythonScript(
  TARGET_NAME VSSegmentation
  SCRIPTS "${MODULE_PYTHON_SCRIPTS}"
  RESOURCES "${MODULE_PYTHON_RESOURCES}"
  DESTINATION_DIR ${CMAKE_BINARY_DIR}/${Slicer_QTSCRIPTEDMODULES_LIB_DIR}
  INSTALL_DIR ${Slicer_INSTALL_QTSCRIPTEDMODULES_LIB_DIR}
  )
