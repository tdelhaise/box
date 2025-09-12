cmake_minimum_required(VERSION 3.16)
project(Box VERSION 0.1.0 LANGUAGES C)

# Options
option(BUILD_SHARED_LIBS "Build shared libraries" OFF)
option(BOX_ENABLE_WARNINGS "Enable extra warnings" ON)
option(BOX_ENABLE_ASAN "Enable AddressSanitizer (Debug)" OFF)
option(BOX_ENABLE_UBSAN "Enable UndefinedBehaviorSanitizer (Debug)" OFF)
option(BOX_ENABLE_LTO "Enable LTO/IPO in Release/RelWithDebInfo" ON)
option(BOX_HARDEN    "Enable hardening flags (by platform)"       ON)
option(BOX_USE_PRESHAREKEY   "Enable PreShareKey"       ON)
option(BOX_MEMORY_SIGNAL_TRACE "Enable BFMemory SIGUSR1 trace handler (POSIX)" ON)
option(BOX_USE_QUIC "Enable QUIC backend (requires external library)" OFF)
option(BOX_BUILD_MINIMAL "Build a minimal core library without DTLS/QUIC (useful for cross targets like Android)" OFF)
set(BOX_QUIC_IMPL "ngtcp2" CACHE STRING "QUIC implementation: ngtcp2|msquic|picoquic")
set_property(CACHE BOX_QUIC_IMPL PROPERTY STRINGS ngtcp2 msquic picoquic)

# Backward-compat: honor legacy -DBOX_USE_PSK=ON/OFF
if(DEFINED BOX_USE_PSK)
  message(WARNING "BOX_USE_PSK is deprecated. Use BOX_USE_PRESHAREKEY instead. Honoring legacy value.")
  set(BOX_USE_PRESHAREKEY ${BOX_USE_PSK})
endif()

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_VERBOSE_MAKEFILE ON CACHE BOOL "ON" FORCE)

# OpenSSL requis (skip for minimal builds)
if(NOT BOX_BUILD_MINIMAL)
  find_package(OpenSSL REQUIRED COMPONENTS SSL Crypto)
endif()

# Définitions globales
if(BOX_USE_PRESHAREKEY)
	add_compile_definitions(BOX_USE_PRESHAREKEY)
endif()

if(BOX_MEMORY_SIGNAL_TRACE)
	add_compile_definitions(BOX_MEMORY_SIGNAL_TRACE)
endif()



include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)

# Expose project version to C as BOX_VERSION
add_compile_definitions(BOX_VERSION="${PROJECT_VERSION}")

if(NOT BOX_BUILD_MINIMAL)
  # Full BoxFoundation library (with DTLS/OpenSSL)
  add_library(BoxFoundation
          src/lib/BFCommon.c
          src/lib/BFSocket.c
          src/lib/BFMemory.c
          src/lib/BFRunloop.c
          src/lib/BFSharedArray.c
          src/lib/BFSharedDictionary.c
          src/lib/BFBoxProtocolV1.c
          src/lib/BFNetwork.c
          src/lib/BFNetworkQuic.c
          src/lib/BFUdp.c
          src/lib/BFUdpServer.c
          src/lib/BFUdpClient.c
          src/lib/BFDtlsOpenSSL.c
          src/lib/BFBoxProtocol.c
          src/lib/BFVersion.c
  )
  target_link_libraries(BoxFoundation PUBLIC OpenSSL::SSL OpenSSL::Crypto)
else()
  # Minimal core library (no DTLS/QUIC/OpenSSL), for cross builds like Android
  add_library(BoxCoreMinimal
          src/lib/BFCommon.c
          src/lib/BFMemory.c
          src/lib/BFSharedArray.c
          src/lib/BFSharedDictionary.c
          src/lib/BFBoxProtocol.c
          src/lib/BFVersion.c
  )
  target_include_directories(BoxCoreMinimal PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
endif()
if(BOX_USE_QUIC)
  add_compile_definitions(BOX_USE_QUIC)
  if(BOX_QUIC_IMPL STREQUAL "ngtcp2")
    add_compile_definitions(BOX_QUIC_IMPL_NGTCP2)
    message(STATUS "QUIC: using ngtcp2 (adapter stubs; TODO: wire real lib)")
    # Try to discover ngtcp2 via pkg-config; tolerate absence (stubs will warn)
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
      pkg_check_modules(NGTCP2 QUIET IMPORTED_TARGET ngtcp2)
      pkg_check_modules(NGTCP2_CRYPTO QUIET IMPORTED_TARGET ngtcp2_crypto)
      pkg_check_modules(NGTCP2_CRYPTO_OPENSSL QUIET IMPORTED_TARGET ngtcp2_crypto_openssl)
      if(TARGET PkgConfig::NGTCP2)
        target_link_libraries(BoxFoundation PRIVATE PkgConfig::NGTCP2)
        add_compile_definitions(HAVE_NGTCP2)
      endif()
      if(TARGET PkgConfig::NGTCP2_CRYPTO)
        target_link_libraries(BoxFoundation PRIVATE PkgConfig::NGTCP2_CRYPTO)
        add_compile_definitions(HAVE_NGTCP2_CRYPTO)
      endif()
      if(TARGET PkgConfig::NGTCP2_CRYPTO_OPENSSL)
        target_link_libraries(BoxFoundation PRIVATE PkgConfig::NGTCP2_CRYPTO_OPENSSL)
        add_compile_definitions(HAVE_NGTCP2_CRYPTO_OPENSSL)
      endif()
    else()
      message(STATUS "pkg-config not found; skipping ngtcp2 autodiscovery")
    endif()
  elseif(BOX_QUIC_IMPL STREQUAL "msquic")
    add_compile_definitions(BOX_QUIC_IMPL_MSQUIC)
    message(STATUS "QUIC: using MsQuic (adapter stubs; TODO: wire real lib)")
  elseif(BOX_QUIC_IMPL STREQUAL "picoquic")
    add_compile_definitions(BOX_QUIC_IMPL_PICOQUIC)
    message(STATUS "QUIC: using picoquic (adapter stubs; TODO: wire real lib)")
  else()
    message(WARNING "Unknown BOX_QUIC_IMPL='${BOX_QUIC_IMPL}', defaulting to ngtcp2")
    add_compile_definitions(BOX_QUIC_IMPL_NGTCP2)
  endif()
endif()

if(BOX_ENABLE_WARNINGS)
	if (MSVC)
		if(NOT BOX_BUILD_MINIMAL)
			target_compile_options(BoxFoundation PRIVATE /W4)
		else()
			target_compile_options(BoxCoreMinimal PRIVATE /W4)
		endif()
	else()
		if(NOT BOX_BUILD_MINIMAL)
			target_compile_options(BoxFoundation PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion)
		else()
			target_compile_options(BoxCoreMinimal PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion)
		endif()
	endif()
endif()

if(NOT MSVC)
	if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
		add_compile_options(-fno-omit-frame-pointer -fstack-protector-strong -D_FORTIFY_SOURCE=3)
		add_link_options(-Wl,-z,relro,-z,now)
	elseif(APPLE)
		# macOS (ld64) — pas de -z,relro/now ; PIE déjà par défaut
		add_compile_options(-fno-omit-frame-pointer -fstack-protector-strong)
		# Évite -pie/-z ici : non valides sur Mach-O
	endif()
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

if(NOT BOX_BUILD_MINIMAL)
  # Executables
  add_executable(boxd src/boxd/server.c)
  target_link_libraries(boxd PRIVATE BoxFoundation)

  add_executable(box src/box/client.c)
  target_link_libraries(box PRIVATE BoxFoundation)
endif()

# ---- LTO / IPO ----
# CMake gère l'IPO via la propriété INTERPROCEDURAL_OPTIMIZATION (>= 3.9)
include(CheckIPOSupported)
if(BOX_ENABLE_LTO AND (CMAKE_BUILD_TYPE STREQUAL "Release" OR CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo") AND NOT BOX_BUILD_MINIMAL)
  check_ipo_supported(RESULT ipo_ok OUTPUT ipo_msg)
  if(ipo_ok)
    message(STATUS "IPO/LTO: enabled")
	foreach(tgt IN ITEMS BoxFoundation box boxd)
		get_target_property(_has ${tgt} TYPE)
		if(_has) # cible exist
    			set_property(TARGET ${tgt} PROPERTY INTERPROCEDURAL_OPTIMIZATION TRUE)
		endif()
	endforeach()
  else()
    message(WARNING "IPO/LTO not supported: ${ipo_msg}")
  endif()
endif()

# ---- Hardening flags ----
if(BOX_HARDEN AND (CMAKE_BUILD_TYPE STREQUAL "Release" OR CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo"))
  if (CMAKE_C_COMPILER_ID MATCHES "Clang|GNU")
	if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
		# Compile-time
		add_compile_options(-fno-omit-frame-pointer -fstack-protector-strong -D_FORTIFY_SOURCE=3 -fno-strict-overflow -fPIC)
		# Link-time
		add_link_options(-Wl,-z,relro -Wl,-z,now -pie)
	elseif(APPLE)
		# macOS (ld64) — pas de -z,relro/now ; PIE déjà par défaut
		add_compile_options(-fno-omit-frame-pointer -fstack-protector-strong)
		# Évite -pie/-z ici : non valides sur Mach-O
	endif()
  elseif (MSVC)
    # Durcissement Windows (indicatif)
    add_compile_options(/guard:cf /Qspectre)
    add_link_options(/CETCOMPAT /DYNAMICBASE /NXCOMPAT)
  endif()
endif()

if(NOT BOX_BUILD_MINIMAL)
  # Tests
  enable_testing()
  include(CTest)
  add_executable(test_BFBoxProtocol test/test_BFBoxProtocol.c src/lib/BFBoxProtocol.c)
  target_include_directories(test_BFBoxProtocol PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  add_test(NAME test_BFBoxProtocol COMMAND test_BFBoxProtocol)

  add_executable(test_BFBoxProtocolV1 test/test_BFBoxProtocolV1.c src/lib/BFBoxProtocolV1.c)
  target_include_directories(test_BFBoxProtocolV1 PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  add_test(NAME test_BFBoxProtocolV1 COMMAND test_BFBoxProtocolV1)

  # BFMemory unit test (links against BoxFoundation for implementation)
  add_executable(test_BFMemory test/test_BFMemory.c)
  target_include_directories(test_BFMemory PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_link_libraries(test_BFMemory PRIVATE BoxFoundation)
  add_test(NAME test_BFMemory COMMAND test_BFMemory)

  # Integration test: DTLS with certificates (client verifies server via CA + hostname)
  add_test(NAME it_dtls_cert_verify COMMAND bash ${CMAKE_SOURCE_DIR}/scripts/test_dtls_cert_verify.sh)
  add_executable(test_BFRunloop test/test_BFRunloop.c)
  target_include_directories(test_BFRunloop PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_link_libraries(test_BFRunloop PRIVATE BoxFoundation)
  add_test(NAME test_BFRunloop COMMAND test_BFRunloop)

  # BFSharedArray unit test
  add_executable(test_BFSharedArray test/test_BFSharedArray.c)
  target_include_directories(test_BFSharedArray PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_link_libraries(test_BFSharedArray PRIVATE BoxFoundation)
  add_test(NAME test_BFSharedArray COMMAND test_BFSharedArray)

  # BFSharedDictionary unit test
  add_executable(test_BFSharedDictionary test/test_BFSharedDictionary.c)
  target_include_directories(test_BFSharedDictionary PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_link_libraries(test_BFSharedDictionary PRIVATE BoxFoundation)
  add_test(NAME test_BFSharedDictionary COMMAND test_BFSharedDictionary)
  add_executable(test_BFSharedArrayStress test/test_BFSharedArrayStress.c)
  target_include_directories(test_BFSharedArrayStress PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_link_libraries(test_BFSharedArrayStress PRIVATE BoxFoundation)
  add_test(NAME test_BFSharedArrayStress COMMAND test_BFSharedArrayStress)
  add_executable(test_BFSharedDictionaryStress test/test_BFSharedDictionaryStress.c)
  target_include_directories(test_BFSharedDictionaryStress PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_link_libraries(test_BFSharedDictionaryStress PRIVATE BoxFoundation)
  add_test(NAME test_BFSharedDictionaryStress COMMAND test_BFSharedDictionaryStress)
  add_executable(bench_BFSharedArray bench/bench_BFSharedArray.c)
  target_include_directories(bench_BFSharedArray PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_link_libraries(bench_BFSharedArray PRIVATE BoxFoundation)
  add_executable(bench_BFSharedDictionary bench/bench_BFSharedDictionary.c)
  target_include_directories(bench_BFSharedDictionary PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_link_libraries(bench_BFSharedDictionary PRIVATE BoxFoundation)
  add_executable(example_shared_array examples/shared_array.c)
  target_include_directories(example_shared_array PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_link_libraries(example_shared_array PRIVATE BoxFoundation)
  add_executable(example_shared_dictionary examples/shared_dictionary.c)
  target_include_directories(example_shared_dictionary PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_link_libraries(example_shared_dictionary PRIVATE BoxFoundation)
endif()

# Cible utilitaire : génération de certificats autosignés (build dir)
add_custom_target(certs
	COMMAND ${CMAKE_COMMAND} -E echo "Generating self-signed certs (server.key/server.pem)"
	COMMAND openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.pem -days 365 -nodes -subj "/CN=boxd"
	WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
	BYPRODUCTS ${CMAKE_CURRENT_BINARY_DIR}/server.key ${CMAKE_CURRENT_BINARY_DIR}/server.pem
VERBATIM)

if(NOT BOX_BUILD_MINIMAL)
  include(GNUInstallDirs)
  install(TARGETS boxd box BoxFoundation
	RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
	LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
	ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
  install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
  install(FILES systemd/boxd.service DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/systemd/system)
  install(FILES packaging/tmpfiles.d/boxd.conf
          DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/tmpfiles.d)
endif()


set(CPACK_PACKAGE_NAME "box")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
include(CPack)

# ---- Utility targets ----
add_custom_target(check
  COMMAND bash ${CMAKE_SOURCE_DIR}/scripts/check_naming.sh
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Running naming convention checks")
