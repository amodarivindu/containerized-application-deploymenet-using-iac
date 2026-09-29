import pytest

from calculator import MAX_EXPRESSION_LENGTH, CalculationError, evaluate


@pytest.mark.parametrize(
    "expression, expected",
    [
        ("2 + 3", 5),
        ("10 - 4", 6),
        ("6 * 7", 42),
        ("8 / 2", 4),
        ("7 / 2", 3.5),
        ("10 % 3", 1),
        ("2 ^ 10", 1024),
        ("2 + 3 * 4", 14),
        ("(2 + 3) * 4", 20),
        ("-5 + 2", -3),
        ("--5", 5),
        ("0.1 + 0.2", 0.3),
        ("1.5 * 2", 3),
        ("2 ^ -1", 0.5),
        ("12 × 3", 36),
        ("12 ÷ 4", 3),
        ("9 − 10", -1),
    ],
)
def test_valid_expressions(expression, expected):
    assert evaluate(expression) == expected


def test_integer_results_are_ints():
    assert isinstance(evaluate("6 / 3"), int)


@pytest.mark.parametrize(
    "expression, message",
    [
        ("1 / 0", "Division by zero"),
        ("5 % 0", "Division by zero"),
        ("", "empty"),
        ("   ", "empty"),
        (None, "empty"),
        ("2 +", "Invalid expression"),
        ("(1 + 2", "Invalid expression"),
        ("abc", "Unsupported"),
        ("__import__('os').system('ls')", "Unsupported"),
        ("[1, 2]", "Unsupported"),
        ("'a' * 3", "Unsupported"),
        ("True + 1", "Unsupported"),
        ("9 ^ 9 ^ 9", "Exponent"),
        ("99999 ^ 999", "too large"),
        ("10.0 ^ 400", "too large"),
        ("(-8) ^ 0.5", "not a real number"),
    ],
)
def test_invalid_expressions(expression, message):
    with pytest.raises(CalculationError, match=message):
        evaluate(expression)


def test_expression_length_limit():
    with pytest.raises(CalculationError, match="longer than"):
        evaluate("1+" * MAX_EXPRESSION_LENGTH + "1")
