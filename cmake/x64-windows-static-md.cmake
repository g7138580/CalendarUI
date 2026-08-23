set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_PROVIDED_FORTRAN ON)

# Pin the MSVC toolset used to build dependencies.
#
# The manifest baseline pins fmt 9.1.0, which uses stdext::checked_array_iterator.
# That type was removed from the MSVC STL in toolset 14.5x (VS 2026), so building
# fmt with the newest installed toolset fails outright. 14.44 still provides it.
#
# vcpkg auto-selects the newest installed toolset and ignores the ambient
# vcvars environment, so the version has to be set here rather than in the shell.
set(VCPKG_PLATFORM_TOOLSET_VERSION "14.44")
