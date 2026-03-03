PROGRAMS = [
    (["let", [["x", 5]], "x"], 5),
    (["let", [["x", 5]], ["+", "x", 3]], 8),
    (["let", [["x", 10], ["y", 5]], ["+", "x", "y"]], 15),
    (["let", [["x", 5], ["y", ["*", "x", 2]]], "y"], 10),
    (["let", [["x", 5], ["y", 10]], ["if", [">", "x", 3], "x", "y"]], 5),
    (["let", [["x", 5]], ["let", [["y", ["*", "x", 2]]], ["+", "x", "y"]]], 15),
    (["let", [["base", 10], ["mult", 2]], ["*", ["+", "base", 5], "mult"]], 30),
]


def test_let_bindings(run_programs):
    results = run_programs([expr for expr, _ in PROGRAMS])
    for i, (expr, expected) in enumerate(PROGRAMS):
        assert results[i] == expected, f"Program {i} {expr}: expected {expected}, got {results[i]}"
