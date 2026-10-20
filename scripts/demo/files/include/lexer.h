#pragma once

#include <string>
#include <vector>

@1-11|enum class Tok { Num, Op, LParen, RParen, End };
@11-12|enum class Tok { Num, Ident, Op, LParen, RParen, End };
@12-|enum class Tok { Num, Ident, Op, LParen, RParen, Comma, End };

struct Token {
  Tok kind;
  std::string text;
@3-|  int column; // 1-based
};

std::vector<Token> lex(const std::string &src);
