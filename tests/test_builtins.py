PROGRAMS = [
    (["+", 1, 2], 3),
    (["-", 5, 3], 2),
    (["*", 4, 2], 8),
    (["/", 10, 2], 5),
    (["+", ["+", 1, 2], ["*", 3, 4]], 15),
    (["*", ["-", 10, 5], ["/", 15, 3]], 25),
    (["=", 3, 3], True),
    (["<", 2, 5], True),
    ([">", 10, 5], True),
    ([">=", 5, 5], True),
    (["<=", 3, 5], True),
    (["=", ["+", 2, 3], 5], True),
    ([">", ["*", 3, 4], ["+", 5, 5]], True),
    (["and", True, True], True),
    (["or", False, True], True),
    (["not", False], True),
    (["and", [">", 5, 3], ["=", ["+", 2, 2], 4]], True),
    (["or", ["<", 10, 5], [">=", ["/", 10, 2], 5]], True),
]


def test_builtins(run_programs):
    results = run_programs([expr for expr, _ in PROGRAMS])
    for i, (expr, expected) in enumerate(PROGRAMS):
        assert results[i] == expected, f"Program {i} {expr}: expected {expected}, got {results[i]}"
