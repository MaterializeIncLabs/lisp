PROGRAMS = [
    (["if", True, 1, 2], 1),
    (["if", False, 1, 2], 2),
    (["if", ["=", ["/", 10, 2], 5], True, False], True),
    (["if", ["not", ["or", False, False]], 1, ["/", 1, 0]], 1),
]


def test_conditionals(run_programs):
    results = run_programs([expr for expr, _ in PROGRAMS])
    for i, (expr, expected) in enumerate(PROGRAMS):
        assert results[i] == expected, f"Program {i} {expr}: expected {expected}, got {results[i]}"
