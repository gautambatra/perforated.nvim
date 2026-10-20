#include "lexer.h"
#include "parser.h"

#include <iostream>
@11-|#include <map>
#include <string>

int main() {
@11-|  std::map<std::string, double> vars;
  std::string line;
  while (std::cout << "> " && std::getline(std::cin, line)) {
    try {
@1-11|      Parser parser(lex(line));
@11-|      Parser parser(lex(line), vars);
      std::cout << parser.parse() << '\n';
    } catch (const std::exception &e) {
      std::cout << "error: " << e.what() << '\n';
    }
  }
}
