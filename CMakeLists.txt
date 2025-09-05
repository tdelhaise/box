cmake_minimum_required(VERSION 3.16)
project(Box VERSION 0.1.0 LANGUAGES C)

# Options
option(BUILD_SHARED_LIBS "Build shared libraries" OFF)
option(BOX_ENABLE_WARNINGS "Enable extra warnings" ON)
option(BOX_ENABLE_ASAN "Enable AddressSanitizer (Debug)" OFF)
option(BOX_ENABLE_UBSAN "Enable UndefinedBehaviorSanitizer (Debug)" OFF)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

# OpenSSL requis
find_package(OpenSSL REQUIRED COMPONENTS SSL Crypto)

# Définitions globales
if(BOX_USE_PSK)
	add_compile_definitions(BOX_USE_PSK)
endif()

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)

# Librairie commune libBox
add_library(BoxFoundation
	src/lib/box.c
	src/lib/dtls_openssl.c
	src/lib/proto.c
)

target_link_libraries(BoxFoundation PUBLIC OpenSSL::SSL OpenSSL::Crypto)

if(BOX_ENABLE_WARNINGS)
	if (MSVC)
		target_compile_options(BoxFoundation PRIVATE /W4)
	else()
		target_compile_options(BoxFoundation PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion)
	endif()
endif()

if(BOX_ENABLE_ASAN AND CMAKE_BUILD_TYPE STREQUAL "Debug")
	if (NOT MSVC)
		target_compile_options(BoxFoundation PRIVATE -fsanitize=address)
		target_link_options(BoxFoundation PRIVATE -fsanitize=address)
	endif()
endif()

if(NOT MSVC)
  add_compile_options(-fno-omit-frame-pointer -fstack-protector-strong -D_FORTIFY_SOURCE=3)
  add_link_options(-Wl,-z,relro,-z,now)
  set(CMAKE_POSITION_INDEPENDENT_CODE ON)
  if(CMAKE_BUILD_TYPE STREQUAL "Release" OR CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
    add_link_options(-pie)
    add_compile_options(-fPIE)
  endif()
endif()

if(BOX_ENABLE_UBSAN AND CMAKE_BUILD_TYPE STREQUAL "Debug" AND NOT MSVC)
  add_compile_options(-fsanitize=undefined)
  add_link_options(-fsanitize=undefined)
endif()

# Executables
add_executable(boxd src/boxd/main.c)
target_link_libraries(boxd PRIVATE BoxFoundation)

add_executable(box src/box/main.c)
target_link_libraries(box PRIVATE BoxFoundation)

# Tests
enable_testing()
add_executable(test_proto test/test_proto.c src/lib/proto.c)
target_include_directories(test_proto PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
add_test(NAME test_proto COMMAND test_proto)

# Cible utilitaire : génération de certificats autosignés (build dir)
add_custom_target(certs
	COMMAND ${CMAKE_COMMAND} -E echo "Generating self-signed certs (server.key/server.pem)"
	COMMAND openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.pem -days 365 -nodes -subj "/CN=boxd"
	WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
	BYPRODUCTS ${CMAKE_CURRENT_BINARY_DIR}/server.key ${CMAKE_CURRENT_BINARY_DIR}/server.pem
VERBATIM)

include(GNUInstallDirs)
install(TARGETS boxd box Box
	RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
	LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
	ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(FILES systemd/boxd.service DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/systemd/system)
# Installe le fichier tmpfiles.d
# Debian/Ubuntu préfèrent /usr/lib/tmpfiles.d (système),
# /etc/tmpfiles.d est pour les overrides locaux.
install(FILES packaging/tmpfiles.d/boxd.conf
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/tmpfiles.d)  # maps to /usr/share/tmpfiles.d
# OU, si on veux vraiment /usr/lib/tmpfiles.d :
# install(FILES packaging/tmpfiles.d/boxd.conf DESTINATION /usr/lib/tmpfiles.d)


set(CPACK_PACKAGE_NAME "box")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
include(CPack)
