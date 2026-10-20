@P|#include <iomanip>
@P|#include <sstream>
@P|#include <string>
@P|
@P|// The shortest text that reads back as the same number, without trailing zeros.
@P|std::string format_number(double value) {
@P|  std::ostringstream out;
@P|  out << std::setprecision(15) << value;
@P|  return out.str();
@P|}
