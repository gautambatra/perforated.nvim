#include "parser.h"

@12-|#include <algorithm>
@9-|#include <cmath>
@2-10|#include <iostream>
#include <stdexcept>

@1-11|Parser::Parser(std::vector<Token> tokens) : tokens_(std::move(tokens)) {}
@11-|Parser::Parser(std::vector<Token> tokens, std::map<std::string, double> &vars)
@11-|    : tokens_(std::move(tokens)), vars_(vars) {}

@1-6|const Token &Parser::peek() const { return tokens_[pos_]; }
@6-|const Token &Parser::peek() const { return tokens_[cursor_]; }

@1-6|const Token &Parser::next() { return tokens_[pos_++]; }
@6-|const Token &Parser::next() { return tokens_[cursor_++]; }

double Parser::parse() {
@13-|  if (peek().kind == Tok::End)
@13-|    throw std::runtime_error("empty expression");
@11-|  if (peek().kind == Tok::Ident && tokens_[cursor_ + 1].text == "=") {
@11-|    std::string name = next().text;
@11-|    next(); // '='
@11-|    double value = expr();
@11-|    vars_[name] = value;
@11-|    return value;
@11-|  }
  double value = expr();
@1-8|  if (peek().kind != Tok::End)
@1-8|    throw std::runtime_error("trailing input");
@8-|  if (peek().kind != Tok::End)
@8-|    throw std::runtime_error("unexpected '" + peek().text + "' at column " +
@8-|                             std::to_string(peek().column));
  return value;
}

@1-2|// expr := primary (('+' | '-') primary)*
@2-|// expr := term (('+' | '-') term)*
double Parser::expr() {
@1-2|  double lhs = primary();
@2-|  double lhs = term();
  while (peek().kind == Tok::Op && (peek().text == "+" || peek().text == "-")) {
    std::string op = next().text;
@1-2|    double rhs = primary();
@2-|    double rhs = term();
@2-10|    std::cerr << "expr: " << lhs << ' ' << op << ' ' << rhs << '\n';
    lhs = op == "+" ? lhs + rhs : lhs - rhs;
  }
  return lhs;
}
@2-|
@2-7|// term := primary (('*' | '/') primary)*
@7-9|// term := unary (('*' | '/') unary)*
@9-|// term := power (('*' | '/') power)*
@2-|double Parser::term() {
@2-7|  double lhs = primary();
@7-9|  double lhs = unary();
@9-|  double lhs = power();
@2-P|  while (peek().kind == Tok::Op && (peek().text == "*" || peek().text == "/")) {
@P|  while (peek().kind == Tok::Op &&
@P|         (peek().text == "*" || peek().text == "/" || peek().text == "%")) {
@2-|    std::string op = next().text;
@2-7|    double rhs = primary();
@7-9|    double rhs = unary();
@9-|    double rhs = power();
@2-10|    std::cerr << "term: " << lhs << ' ' << op << ' ' << rhs << '\n';
@2-|    if (op == "*") {
@2-|      lhs *= rhs;
@P|    } else if (op == "%") {
@P|      lhs = std::fmod(lhs, rhs);
@16-|    } else if (rhs == 0) {
@16-|      throw std::runtime_error("division by zero");
@2-|    } else {
@2-|      lhs /= rhs;
@2-|    }
@2-|  }
@2-|  return lhs;
@2-|}
@9-|
@9-|// power := unary ('^' power)?   (right-associative)
@9-|double Parser::power() {
@9-|  double base = unary();
@9-|  if (peek().kind == Tok::Op && peek().text == "^") {
@9-|    next();
@9-|    return std::pow(base, power());
@9-|  }
@9-|  return base;
@9-|}
@7-|
@7-|// unary := '-' unary | primary
@7-|double Parser::unary() {
@7-|  if (peek().kind == Tok::Op && peek().text == "-") {
@7-|    next();
@7-|    return -unary();
@7-|  }
@7-|  return primary();
@7-|}

@1-4|// primary := number
@4-11|// primary := number | '(' expr ')'
@11-12|// primary := number | name | '(' expr ')'
@12-|// primary := number | name | call | '(' expr ')'
double Parser::primary() {
  const Token &tok = next();
  if (tok.kind == Tok::Num)
    return std::stod(tok.text);
@11-|  if (tok.kind == Tok::Ident) {
@12-|    if (peek().kind == Tok::LParen)
@12-|      return call(tok.text);
@11-|    auto it = vars_.find(tok.text);
@11-|    if (it == vars_.end())
@11-|      throw std::runtime_error("unknown variable '" + tok.text + "'");
@11-|    return it->second;
@11-|  }
@4-|  if (tok.kind == Tok::LParen) {
@4-|    double value = expr();
@4-8|    if (next().kind != Tok::RParen)
@4-8|      throw std::runtime_error("expected ')'");
@8-|    if (next().kind != Tok::RParen)
@8-|      throw std::runtime_error("expected ')' to match column " + std::to_string(tok.column));
@4-|    return value;
@4-|  }
@1-8|  throw std::runtime_error("expected a number");
@8-|  throw std::runtime_error("expected a number at column " + std::to_string(tok.column));
}
@12-|
@12-|// call := name '(' expr (',' expr)* ')'
@12-|double Parser::call(const std::string &name) {
@12-|  next(); // '('
@12-|  std::vector<double> args{expr()};
@12-|  while (peek().kind == Tok::Comma) {
@12-|    next();
@12-|    args.push_back(expr());
@12-|  }
@12-|  if (next().kind != Tok::RParen)
@12-|    throw std::runtime_error("expected ')' after the arguments to " + name);
@12-|  if (name == "sqrt" && args.size() == 1)
@12-|    return std::sqrt(args[0]);
@12-|  if (name == "abs" && args.size() == 1)
@12-|    return std::fabs(args[0]);
@12-|  if (name == "min" && args.size() == 2)
@12-|    return std::min(args[0], args[1]);
@12-|  if (name == "max" && args.size() == 2)
@12-|    return std::max(args[0], args[1]);
@12-|  throw std::runtime_error("unknown function " + name + "/" + std::to_string(args.size()));
@12-|}
