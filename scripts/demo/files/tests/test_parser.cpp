@5-|#include "lexer.h"
@5-|#include "parser.h"
@5-|
@5-|#include <cassert>
@11-|#include <map>
@5-|#include <string>
@5-|
@5-11|static double eval(const std::string &src) { return Parser(lex(src)).parse(); }
@11-|static double eval(const std::string &src) {
@11-|  static std::map<std::string, double> vars;
@11-|  return Parser(lex(src), vars).parse();
@11-|}
@5-|
@5-|int main() {
@5-|  assert(eval("1 + 2") == 3);
@5-|  assert(eval("2 * 3 + 4") == 10);
@5-|  assert(eval("2 * (3 + 4)") == 14);
@5-|  assert(eval("10 / 4") == 2.5);
@7-|  assert(eval("-3 + 5") == 2);
@7-|  assert(eval("--2") == 2);
@9-|  assert(eval("2 ^ 3 ^ 2") == 512);
@11-|  assert(eval("x = 4") == 4);
@11-|  assert(eval("x * 2") == 8);
@12-|  assert(eval("sqrt(16)") == 4);
@12-|  assert(eval("max(2, 7)") == 7);
@P|  assert(eval("7 % 3") == 1);
@5-|  return 0;
@5-|}
