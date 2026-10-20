#include "lexer.h"

#include <cctype>
#include <stdexcept>

std::vector<Token> lex(const std::string &src) {
  std::vector<Token> out;
  size_t i = 0;
  while (i < src.size()) {
    char c = src[i];
    if (std::isspace(static_cast<unsigned char>(c))) {
      ++i;
      continue;
    }
@3-|    int column = static_cast<int>(i) + 1;
@P|    if (c == '0' && i + 1 < src.size() && (src[i + 1] == 'x' || src[i + 1] == 'X')) {
@P|      size_t start = i;
@P|      i += 2;
@P|      while (i < src.size() && std::isxdigit(static_cast<unsigned char>(src[i])))
@P|        ++i;
@P|      out.push_back({Tok::Num, src.substr(start, i - start), column});
@P|      continue;
@P|    }
    if (std::isdigit(static_cast<unsigned char>(c)) || c == '.') {
      size_t start = i;
      while (i < src.size() &&
             (std::isdigit(static_cast<unsigned char>(src[i])) || src[i] == '.'))
        ++i;
@15-|      if (i < src.size() && (src[i] == 'e' || src[i] == 'E')) {
@15-|        ++i;
@15-|        if (i < src.size() && (src[i] == '+' || src[i] == '-'))
@15-|          ++i;
@15-|        while (i < src.size() && std::isdigit(static_cast<unsigned char>(src[i])))
@15-|          ++i;
@15-|      }
@1-3|      out.push_back({Tok::Num, src.substr(start, i - start)});
@3-|      out.push_back({Tok::Num, src.substr(start, i - start), column});
      continue;
    }
@11-|    if (std::isalpha(static_cast<unsigned char>(c)) || c == '_') {
@11-|      size_t start = i;
@11-|      while (i < src.size() &&
@11-|             (std::isalnum(static_cast<unsigned char>(src[i])) || src[i] == '_'))
@11-|        ++i;
@11-|      out.push_back({Tok::Ident, src.substr(start, i - start), column});
@11-|      continue;
@11-|    }
@1-3|    if (c == '(') { out.push_back({Tok::LParen, "("}); ++i; continue; }
@1-3|    if (c == ')') { out.push_back({Tok::RParen, ")"}); ++i; continue; }
@3-|    if (c == '(') { out.push_back({Tok::LParen, "(", column}); ++i; continue; }
@3-|    if (c == ')') { out.push_back({Tok::RParen, ")", column}); ++i; continue; }
@12-|    if (c == ',') { out.push_back({Tok::Comma, ",", column}); ++i; continue; }
@1-9|    if (std::string("+-*/").find(c) != std::string::npos) {
@9-11|    if (std::string("+-*/^").find(c) != std::string::npos) {
@11-|    if (std::string("+-*/^=").find(c) != std::string::npos) {
@1-3|      out.push_back({Tok::Op, std::string(1, c)});
@3-|      out.push_back({Tok::Op, std::string(1, c), column});
      ++i;
      continue;
    }
@1-8|    throw std::runtime_error("unexpected character");
@8-|    throw std::runtime_error("unexpected character '" + std::string(1, c) + "' at column " +
@8-|                             std::to_string(column));
  }
@1-3|  out.push_back({Tok::End, ""});
@3-|  out.push_back({Tok::End, "", static_cast<int>(src.size()) + 1});
  return out;
}
