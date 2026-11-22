cmake_minimum_required(VERSION 3.10)
project(processor_sim C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

find_package(Threads REQUIRED)
add_executable(processor_sim processor_sim.cpp)
# The same strict set tools/check-sim.sh builds with -Werror.
target_compile_options(processor_sim PRIVATE
  -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wsign-conversion -Wold-style-cast
  -Wnull-dereference -Wdouble-promotion -Wformat=2 -Wimplicit-fallthrough)
target_link_libraries(processor_sim PRIVATE Threads::Threads)
install(TARGETS processor_sim RUNTIME DESTINATION bin)
