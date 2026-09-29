"""Safe arithmetic expression evaluator.

Parses the expression into a Python AST and evaluates only whitelisted
arithmetic nodes, so user input is never passed to eval().
"""

import ast
import math
import operator

MAX_EXPRESSION_LENGTH = 200
MAX_EXPONENT = 1000
MAX_INT_BITS = 3300  # ~1000 decimal digits; keeps CPU and JSON output bounded

_BINARY_OPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.Div: operator.truediv,
    ast.Mod: operator.mod,
    ast.Pow: operator.pow,
}

_UNARY_OPS = {
    ast.UAdd: operator.pos,
    ast.USub: operator.neg,
}

# Symbols the UI shows, mapped to Python operators.
_SYMBOLS = {"×": "*", "÷": "/", "−": "-", "^": "**"}


class CalculationError(ValueError):
    """Raised for any expression that cannot be evaluated."""


def evaluate(expression):
    """Evaluate an arithmetic expression like '2 + 3 * (4 - 1) ^ 2'."""
    if not isinstance(expression, str) or not expression.strip():
        raise CalculationError("Expression is empty")
    if len(expression) > MAX_EXPRESSION_LENGTH:
        raise CalculationError(f"Expression is longer than {MAX_EXPRESSION_LENGTH} characters")

    for symbol, replacement in _SYMBOLS.items():
        expression = expression.replace(symbol, replacement)

    try:
        tree = ast.parse(expression.strip(), mode="eval")
    except SyntaxError:
        raise CalculationError("Invalid expression") from None

    return _format(_eval(tree.body))


def _eval(node):
    if isinstance(node, ast.Constant) and type(node.value) in (int, float):
        return node.value

    if isinstance(node, ast.UnaryOp) and type(node.op) in _UNARY_OPS:
        return _UNARY_OPS[type(node.op)](_eval(node.operand))

    if isinstance(node, ast.BinOp) and type(node.op) in _BINARY_OPS:
        left, right = _eval(node.left), _eval(node.right)
        if isinstance(node.op, ast.Pow):
            _check_power(left, right)
        try:
            result = _BINARY_OPS[type(node.op)](left, right)
        except ZeroDivisionError:
            raise CalculationError("Division by zero") from None
        except OverflowError:
            raise CalculationError("Result is too large") from None
        return _check_result(result)

    raise CalculationError("Unsupported expression: only numbers, + - * / % ^ and parentheses are allowed")


def _check_power(base, exponent):
    if abs(exponent) > MAX_EXPONENT:
        raise CalculationError(f"Exponent must be between -{MAX_EXPONENT} and {MAX_EXPONENT}")
    if isinstance(base, int) and isinstance(exponent, int) and abs(base) > 1:
        if base.bit_length() * exponent > MAX_INT_BITS:
            raise CalculationError("Result is too large")


def _check_result(value):
    if isinstance(value, complex):
        raise CalculationError("Result is not a real number")
    if isinstance(value, int) and value.bit_length() > MAX_INT_BITS:
        raise CalculationError("Result is too large")
    if isinstance(value, float) and (math.isinf(value) or math.isnan(value)):
        raise CalculationError("Result is too large")
    return value


def _format(value):
    """Return ints as ints and trim float noise (0.1 + 0.2 -> 0.3)."""
    if isinstance(value, float):
        value = float(f"{value:.12g}")
        if value.is_integer() and abs(value) < 1e15:
            return int(value)
    return value
