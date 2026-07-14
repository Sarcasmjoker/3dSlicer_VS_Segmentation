cmake_minimum_required(VERSION 3.16.3...3.19.7 FATAL_ERROR)

project(SlicerVS)

#-----------------------------------------------------------------------------
# Extension meta-information
set(EXTENSION_HOMEPAGE "https://github.com/Sarcasmjoker/3dSlicer_VS_Segmentation")
set(EXTENSION_CATEGORY "Segmentation")
set(EXTENSION_CONTRIBUTORS "SlicerVS Project")
set(EXTENSION_DESCRIPTION "Vestibular schwannoma segmentation from ceT1 MRI.")

#-----------------------------------------------------------------------------
# Module files
set(MODULE_PYTHON_SCRIPTS
  SlicerVS.py
  )

set(MODULE_PYTHON_RESOURCES
  Resources/UI/SlicerVS.ui
  Resources/Scripts/normalize_and_predict.py
  )

#-----------------------------------------------------------------------------
ctkMacroCompilePythonScript(
  TARGET_NAME SlicerVS
  SCRIPTS "${MODULE_PYTHON_SCRIPTS}"
  RESOURCES "${MODULE_PYTHON_RESOURCES}"
  DESTINATION_DIR ${CMAKE_BINARY_DIR}/${Slicer_QTSCRIPTEDMODULES_LIB_DIR}
  INSTALL_DIR ${Slicer_INSTALL_QTSCRIPTEDMODULES_LIB_DIR}
  )
