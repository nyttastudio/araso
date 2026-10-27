# Qt 6 or Qt 5 (ARASO_QT; empty: Qt 6 when there is one). Releases use Qt 5: Ubuntu 22.04's Qt 6 has
# no input method plugins, so a Qt 6 window can't be typed into there, while fcitx5's Qt 5 module
# is on every distribution.
set(ARASO_QT "" CACHE STRING "Qt major version for araso-settings: 5 or 6")
if(ARASO_QT)
  set(QT_VERSION_MAJOR ${ARASO_QT})
else()
  find_package(QT NAMES Qt6 Qt5 REQUIRED COMPONENTS Widgets)
endif()
find_package(Qt${QT_VERSION_MAJOR} REQUIRED COMPONENTS Widgets Network)
set(CMAKE_AUTOMOC OFF)
add_executable(araso-settings Main.cpp Window.cpp Panes.cpp Words.cpp About.cpp)
target_link_libraries(araso-settings PRIVATE araso_core Qt${QT_VERSION_MAJOR}::Widgets Qt${QT_VERSION_MAJOR}::Network)
install(TARGETS araso-settings DESTINATION "${ARASO_BINDIR}")
