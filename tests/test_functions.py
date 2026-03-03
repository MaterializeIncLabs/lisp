DEFINITIONS = [
    ["defun", "factorial", "x", ["if", ["=", "x", 1], 1, ["*", "x", ["factorial", ["-", "x", 1]]]]],
    ["defun", "is-even", "n", ["if", ["=", "n", 0], True, ["if", ["=", "n", 1], False, ["is-odd", ["-", "n", 1]]]]],
    ["defun", "is-odd", "n", ["if", ["=", "n", 0], False, ["if", ["=", "n", 1], True, ["is-even", ["-", "n", 1]]]]],
    ["defun", "fib", "n", ["if", ["or", ["=", "n", 0], ["=", "n", 1]], "n", ["+", ["fib", ["-", "n", 1]], ["fib", ["-", "n", 2]]]]],
]

CALLS = [
    (["factorial", 3], 6),
    (["is-even", 4], True),
    (["is-odd", 7], True),
    (["is-even", 7], False),
    (["fib", 5], 5),
]


def test_functions(run_programs):
    programs = DEFINITIONS + [expr for expr, _ in CALLS]
    results = run_programs(programs)
    for i, (expr, expected) in enumerate(CALLS):
        idx = len(DEFINITIONS) + i
        assert results[idx] == expected, f"{expr}: expected {expected}, got {results[idx]}"


HANOI_DEFINITIONS = [
    ["defmacro", "double", "x", ["+", "x", "x"]],
    ["defmacro", "dec", "x", ["-", "x", 1]],
    ["defmacro", "square", "x", ["*", "x", "x"]],
    ["defmacro", "when", ["cond", "body"], ["if", "cond", "body", False]],
    ["defmacro", "unless", ["cond", "body"], ["if", "cond", False, "body"]],
    ["defun", "hanoi", "n", ["if", ["=", "n", 0], 0, ["+", ["double", ["hanoi", ["dec", "n"]]], 1]]],
    ["defun", "pow2", "n", ["if", ["=", "n", 0], 1, ["double", ["pow2", ["dec", "n"]]]]],
]

HANOI_CALLS = [
    (["hanoi", 1], 1),
    (["hanoi", 2], 3),
    (["hanoi", 3], 7),
    (["hanoi", 4], 15),
    (["=", ["hanoi", 4], ["-", ["pow2", 4], 1]], True),
    (["let", [["moves", ["hanoi", 3]], ["total", ["pow2", 3]]], ["cons", "moves", ["cons", "total", ["=", "moves", ["-", "total", 1]]]]], [7, [8, True]]),
    (["when", [">", ["hanoi", 4], 10], ["square", 4]], 16),
    (["unless", [">", ["hanoi", 1], 10], ["square", 5]], 25),
]


def test_tower_of_hanoi(run_programs):
    programs = HANOI_DEFINITIONS + [expr for expr, _ in HANOI_CALLS]
    results = run_programs(programs)
    for i, (expr, expected) in enumerate(HANOI_CALLS):
        idx = len(HANOI_DEFINITIONS) + i
        assert results[idx] == expected, f"{expr}: expected {expected}, got {results[idx]}"
