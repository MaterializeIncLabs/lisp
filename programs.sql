-- Basic built-in operators
DELETE FROM lisp_programs;
INSERT INTO lisp_programs VALUES 
    -- Basic arithmetic
    (1, '["+", 1, 2]'::jsonb),                                    -- 3
    (2, '["-", 5, 3]'::jsonb),                                    -- 2
    (3, '["*", 4, 2]'::jsonb),                                    -- 8
    (4, '["/", 10, 2]'::jsonb),                                   -- 5
    
    -- Nested arithmetic
    (5, '["+", ["+", 1, 2], ["*", 3, 4]]'::jsonb),               -- 15
    (6, '["*", ["-", 10, 5], ["/", 15, 3]]'::jsonb),             -- 25
    
    -- Basic comparisons
    (7, '["=", 3, 3]'::jsonb),                                    -- true
    (8, '["<", 2, 5]'::jsonb),                                    -- true
    (9, '[">", 10, 5]'::jsonb),                                   -- true
    (10, '[">=", 5, 5]'::jsonb),                                  -- true
    (11, '["<=", 3, 5]'::jsonb),                                  -- true
    
    -- Comparisons with arithmetic
    (12, '["=", ["+", 2, 3], 5]'::jsonb),                        -- true
    (13, '[">", ["*", 3, 4], ["+", 5, 5]]'::jsonb),              -- true
    
    -- Basic boolean operations
    (14, '["and", true, true]'::jsonb),                          -- true
    (15, '["or", false, true]'::jsonb),                          -- true
    (16, '["not", false]'::jsonb),                               -- true
    
    -- Complex boolean expressions
    (17, '["and", [">", 5, 3], ["=", ["+", 2, 2], 4]]'::jsonb), -- true
    (18, '["or", ["<", 10, 5], [">=", ["/", 10, 2], 5]]'::jsonb); -- true

-- Conditionals
DELETE FROM lisp_programs;
INSERT INTO lisp_programs VALUES
    -- Basic if statements
    (21, '["if", true, 1, 2]'::jsonb), -- 1 (true condition)
    (22, '["if", false, 1, 2]'::jsonb), -- 2 (false condition)

    -- Edge cases for if statements
    (23, '["if", ["=", ["/", 10, 2], 5], true, false]'::jsonb), -- true
    (24, '["if", ["not", ["or", false, false]], 1, ["/" 1 0]]'::jsonb); -- 1

-- Let bindings
DELETE FROM lisp_programs;
INSERT INTO lisp_programs VALUES 
    -- Basic let binding - bind x to 5 and return it
    (25, '["let", [["x", 5]], "x"]'::jsonb),  -- 5

    -- Let with arithmetic using bound variable
    (26, '["let", [["x", 5]], ["+", "x", 3]]'::jsonb),  -- 8

    -- Multiple bindings
    (27, '["let", 
        [["x", 10], 
            ["y", 5]], 
        ["+", "x", "y"]]'::jsonb),  -- 15

    -- Using bound variable in subsequent binding
    (28, '["let",
        [["x", 5],
            ["y", ["*", "x", 2]]],
        "y"]'::jsonb),  -- 10

    -- Let with if using bound variables 
    (29, '["let",
        [["x", 5],
            ["y", 10]],
        ["if", [">", "x", 3], "x", "y"]]'::jsonb),  -- 5

    -- Nested let
    (30, '["let",
        [["x", 5]],
        ["let",
            [["y", ["*", "x", 2]]],
            ["+", "x", "y"]]]'::jsonb),  -- 15

    -- Complex arithmetic with bindings
    (31, '["let",
        [["base", 10],
            ["mult", 2]],
        ["*", ["+", "base", 5], "mult"]]'::jsonb); -- 30



-- List operations
DELETE FROM lisp_programs;
INSERT INTO lisp_programs VALUES 
    -- Cons operations (build lists)
    (32, '["cons", 1, 2]'::jsonb),  -- [1, 2]
    (33, '["cons", 1, ["cons", 2, 3]]'::jsonb),  -- [1, [2, 3]]

    -- Car operations (get first element)
    (34, '["car", ["cons", 1, 2]]'::jsonb),  -- 1
    (35, '["car", ["cons", 5, ["cons", 2, 3]]]'::jsonb),  -- 5

    -- cdr operations (get second element)
    (36, '["cdr", ["cons", 1, 2]]'::jsonb),  -- 2
    (37, '["cdr", ["cons", 1, ["cons", 2, 3]]]'::jsonb),  -- [2, 3]

    -- Mixed operations
    (38, '["car", ["cons", ["*", 2, 3], ["cons", 4, 5]]]'::jsonb),  -- 6
    (39, '["cdr", ["cons", 1, ["+", 2, 3]]]'::jsonb),  -- 5

    -- With let bindings
    (40, '["let", 
        [["pair", ["cons", 1, 2]]],
        ["car", "pair"]]'::jsonb),  -- 1

    (41, '["let",
        [["lst", ["cons", 1, ["cons", 2, 3]]]],
        ["cdr", "lst"]]'::jsonb),  -- [2, 3]

    -- Basic quote
    (42, '["quote", 42]'::jsonb),                                -- 42
    (43, '["quote", ["list", 1, 2, 3]]'::jsonb),                -- ["list", 1, 2, 3]
    (44, '["quote", ["a", "b", "c"]]'::jsonb),                  -- ["a", "b", "c"]
    
    -- Quote with nested expressions
    (45, '["quote", ["quote", ["a", "b"]]]'::jsonb),            -- ["quote", ["a", "b"]]
    
    -- Quote in let expressions
    (46, '["let", [["x", ["quote", ["+", 1, 2]]]], "x"]'::jsonb), -- ["+", 1, 2]
    
    -- Quote with symbols
    (47, '["quote", "x"]'::jsonb);                              -- "x"

-- Functions
DELETE FROM lisp_programs;
INSERT INTO lisp_programs VALUES 
    (48, '["defun","factorial","x",["if",["=","x",1],1,["*","x",["factorial",["-","x",1]]]]]'::jsonb),
    (49, '["factorial",3]'::jsonb),
    (50, '["defun","is-even","n",["if",["=","n",0],true,["if",["=","n",1],false,["is-odd",["-","n",1]]]]]'::jsonb),
    (51, '["defun","is-odd","n",["if",["=","n",0],false,["if",["=","n",1],true,["is-even",["-","n",1]]]]]'::jsonb),
    (52, '["is-even",4]'::jsonb),
    (53, '["is-odd",7]'::jsonb),
    (54, '["is-even",7]'::jsonb),
    (55, '["defun", "fib", "n", ["if", ["or", ["=", "n", 0], ["=", "n", 1]], "n", ["+", ["fib", ["-", "n", 1]], ["fib", ["-", "n", 2]]]]]'),
    (56, '["fib", 5]');