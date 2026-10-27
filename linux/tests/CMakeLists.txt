add_executable(araso-document-tests DocumentTests.cpp)
target_link_libraries(araso-document-tests PRIVATE araso_core)
add_test(NAME document COMMAND araso-document-tests)
add_executable(araso-keys-tests KeysTests.cpp)
target_link_libraries(araso-keys-tests PRIVATE araso_core)
add_test(NAME keys COMMAND araso-keys-tests)

# Typing through a fcitx5 Instance with the addon built here and the Swift bridge given by
# ARASO_BRIDGE (swift build's libArasoBridge.so); the kanji dictionary from ARASO_RESOURCES.
add_executable(araso-typing-tests TypingTests.cpp)
target_link_libraries(araso-typing-tests PRIVATE araso_core Fcitx5::Core)
get_filename_component(DICTIONARY_PARENT "${DICTIONARY}" DIRECTORY)
set(TEST_DATA "${CMAKE_CURRENT_BINARY_DIR}/data")
file(MAKE_DIRECTORY "${TEST_DATA}/fcitx5/addon" "${TEST_DATA}/fcitx5/inputmethod" "${CMAKE_CURRENT_BINARY_DIR}/support"
     "${CMAKE_CURRENT_BINARY_DIR}/config")
configure_file("${CMAKE_BINARY_DIR}/araso-addon.conf" "${TEST_DATA}/fcitx5/addon/araso.conf" COPYONLY)
configure_file("${CMAKE_SOURCE_DIR}/data/araso.conf" "${TEST_DATA}/fcitx5/inputmethod/araso.conf" COPYONLY)
add_test(NAME typing COMMAND araso-typing-tests)
set_tests_properties(typing PROPERTIES ENVIRONMENT
  "FCITX_ADDON_DIRS=${CMAKE_BINARY_DIR}:${FCITX_INSTALL_ADDONDIR};XDG_DATA_DIRS=${TEST_DATA}:/usr/share;XDG_DATA_HOME=${TEST_DATA};XDG_CONFIG_HOME=${CMAKE_CURRENT_BINARY_DIR}/config;ARASO_SUPPORT_DIR=${CMAKE_CURRENT_BINARY_DIR}/support;ARASO_BRIDGE=${ARASO_BRIDGE};ARASO_RESOURCES=${DICTIONARY_PARENT};XDG_RUNTIME_DIR=${CMAKE_CURRENT_BINARY_DIR}"
  DEPENDS araso)
