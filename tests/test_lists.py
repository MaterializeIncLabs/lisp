PROGRAMS = [
    (["cons", 1, 2], [1, 2]),
    (["cons", 1, ["cons", 2, 3]], [1, [2, 3]]),
    (["car", ["cons", 1, 2]], 1),
    (["car", ["cons", 5, ["cons", 2, 3]]], 5),
    (["cdr", ["cons", 1, 2]], 2),
    (["cdr", ["cons", 1, ["cons", 2, 3]]], [2, 3]),
    (["car", ["cons", ["*", 2, 3], ["cons", 4, 5]]], 6),
    (["cdr", ["cons", 1, ["+", 2, 3]]], 5),
    (["let", [["pair", ["cons", 1, 2]]], ["car", "pair"]], 1),
    (["let", [["lst", ["cons", 1, ["cons", 2, 3]]]], ["cdr", "lst"]], [2, 3]),
    (["quote", 42], 42),
    (["quote", ["list", 1, 2, 3]], ["list", 1, 2, 3]),
    (["quote", ["a", "b", "c"]], ["a", "b", "c"]),
    (["quote", ["quote", ["a", "b"]]], ["quote", ["a", "b"]]),
    (["let", [["x", ["quote", ["+", 1, 2]]]], "x"], ["+", 1, 2]),
    (["quote", "x"], "x"),
]


def test_lists(run_programs):
    results = run_programs([expr for expr, _ in PROGRAMS])
    for i, (expr, expected) in enumerate(PROGRAMS):
        assert results[i] == expected, f"Program {i} {expr}: expected {expected}, got {results[i]}"
