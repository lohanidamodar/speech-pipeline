# Shared library exposing a C ABI over the engine, for FFI consumers.
add_library(audiocpp_c SHARED audiocpp_c.cpp)

target_include_directories(audiocpp_c
    PUBLIC  ${CMAKE_CURRENT_SOURCE_DIR}
    PRIVATE ${CMAKE_SOURCE_DIR}/include)

target_compile_definitions(audiocpp_c PRIVATE AC_BUILD_SHARED)
target_compile_features(audiocpp_c PRIVATE cxx_std_20)

# engine_runtime is static, so everything it needs must resolve into this .so.
find_package(OpenMP QUIET)
target_link_libraries(audiocpp_c PRIVATE engine_runtime)
if(OpenMP_CXX_FOUND)
    target_link_libraries(audiocpp_c PRIVATE OpenMP::OpenMP_CXX)
endif()

set_target_properties(audiocpp_c PROPERTIES
    C_VISIBILITY_PRESET hidden
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON)
