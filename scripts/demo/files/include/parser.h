#pragma once

#include "lexer.h"

@11-|#include <map>
#include <string>
#include <vector>

class Parser {
public:
@1-11|  explicit Parser(std::vector<Token> tokens);
@11-|  Parser(std::vector<Token> tokens, std::map<std::string, double> &vars);
  double parse();

private:
  double expr();
@2-|  double term();
@9-|  double power();
@7-|  double unary();
  double primary();
@12-|  double call(const std::string &name);
  const Token &peek() const;
  const Token &next();

  std::vector<Token> tokens_;
@1-6|  size_t pos_ = 0;
@6-|  size_t cursor_ = 0;
@11-|  std::map<std::string, double> &vars_;
};
