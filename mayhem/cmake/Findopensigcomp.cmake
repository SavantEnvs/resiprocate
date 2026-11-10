# Resolves find_package(opensigcomp) to the library mayhem/build.sh builds from contrib/opensigcomp.
set(_osc_dir "${CMAKE_SOURCE_DIR}/mayhem/_sigcomp")
add_library(opensigcomp STATIC IMPORTED)
set_target_properties(opensigcomp PROPERTIES
  IMPORTED_LOCATION "${_osc_dir}/libopensigcomp.a"
  INTERFACE_INCLUDE_DIRECTORIES "${_osc_dir}/include")
set(opensigcomp_FOUND TRUE)
