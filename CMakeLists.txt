cmake_minimum_required(VERSION 3.16)
project(Box VERSION 0.1.0 LANGUAGES C)

# Options
option(BUILD_SHARED_LIBS "Build shared libraries" OFF)
option(BOX_ENABLE_WARNINGS "Enable extra warnings" ON)
option(BOX_ENABLE_ASAN "Enable AddressSanitizer (Debug)" OFF)

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
add_library(Box
	src/lib/box.c
	src/lib/dtls_openssl.c
	src/lib/proto.c
)

target_link_libraries(Box PUBLIC OpenSSL::SSL OpenSSL::Crypto)

if(BOX_ENABLE_WARNINGS)
	if (MSVC)
		target_compile_options(Box PRIVATE /W4)
	else()
		target_compile_options(Box PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion)
	endif()
endif()

if(BOX_ENABLE_ASAN AND CMAKE_BUILD_TYPE STREQUAL "Debug")
	if (NOT MSVC)
		target_compile_options(Box PRIVATE -fsanitize=address)
		target_link_options(Box PRIVATE -fsanitize=address)
	endif()
endif()

# Executables
add_executable(boxd src/boxd/main.c)
target_link_libraries(boxd PRIVATE Box)

add_executable(box src/box/main.c)
target_link_libraries(box PRIVATE Box)

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

set(CPACK_PACKAGE_NAME "box")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
include(CPack)
