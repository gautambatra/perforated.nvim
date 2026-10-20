# calc

A small command-line calculator.

@1-11|    $ calc
@1-11|    > 2 * (3 + 4)
@1-11|    14
@11-|    $ calc
@11-|    > r = 2
@11-|    2
@11-|    > 3.14159 * r ^ 2
@11-|    12.5664
@12-|
@12-|Functions: `sqrt`, `abs`, `min`, `max`.
@14-|
@14-|## Operator precedence
@14-|
@14-|| Operator | Associativity |
@14-||---|---|
@14-|| `^` | right |
@14-|| unary `-` | right |
@14-|| `*` `/` | left |
@14-|| `+` `-` | left |
@14-|| `=` | right |
@P|
@P|`%` is the floating-point remainder: `7 % 3` is 1.
