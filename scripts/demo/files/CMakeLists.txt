cmake_minimum_required(VERSION 3.16)
project(calc CXX)

set(CMAKE_CXX_STANDARD 17)
include_directories(include)

add_executable(calc src/main.cpp src/lexer.cpp src/parser.cpp)
@5-|
@5-|enable_testing()
@5-|add_executable(test_parser tests/test_parser.cpp src/lexer.cpp src/parser.cpp)
@5-|add_test(NAME parser COMMAND test_parser)
