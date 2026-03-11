-- ============================================================================
-- Lisp Interpreter Implementation in SQL Using Materialize's Mutual Recursion
-- ============================================================================
--
-- This SQL-based Lisp interpreter leverages Materialize's iterative dataflow
-- for mutual recursion. Lisp expressions are represented as JSONB arrays.
--
-- Expression format: [operator, arg1, arg2, ...]
--   e.g., (+ 1 2) => ["+", 1, 2]
--
-- Key Concepts:
-- -------------
-- 1. call_stack (bigint list): Tracks nested evaluation contexts by storing
--    function call ancestry (think call frames).
-- 2. frame_pointer (int): Represents nesting of scopes; increments for each
--    nested expression or function call to manage lexical scoping.
-- 3. expr (jsonb): The current Lisp expression under evaluation.
-- 4. result (jsonb): The computed value of the expression once evaluated.
--
-- High-Level Architecture:
-- ------------------------
-- We define a series of CTEs using MUTUALLY RECURSIVE:
--   1. workset: A set of expressions that need evaluation. Sub-expressions
--      discovered during evaluation are re-inserted for processing.
--   2. resultset: Collects final results. Each specialized rule
--      (e.g. binary_operators, if_eval, function_eval) feeds into this.
--
-- How Mutual Recursion Works:
-- ---------------------------
-- - At a high level, `workset` and `resultset` continuously new
--   data into the system until a fixed point is reached.
-- - Some CTEs (like `branch_selector` or `function_call`) transform expressions
--   into *new expressions* that go back into `workset`. For example:
--     • `branch_selector` picks which branch of an 'if' to evaluate next.
--     • `function_call` expands (f arg) into a 'let' expression.
--   By returning these new expressions, they re-enter the pipeline (via UNION
--   into `workset`) to be evaluated in subsequent iterations.
-- - Other intermediate rule CTEs (like `binary_operators`) produce *results*
--   that are fed into `resultset`—but these same operators depend on *prior*
--   results to evaluate their arguments (`arg1.result` and `arg2.result`).
-- - The dependencies among these CTEs are resolved automatically by Materialize
--   using our JOIN conditions on `call_stack` and `expr`. Because the system
--   re-runs these CTEs iteratively and in parallel, we effectively get data
--   parallelism for free.
--
-- Materialize's Fixed-Point Iteration:
-- ------------------------------------
-- Materialize repeatedly evaluates these CTEs until no new rows appear
-- (fixed point):
--   1. Load initial expressions from lisp_programs into workset.
--   2. Sub-expressions get added back into workset.
--   3. Partial results appear in resultset, prompting more workset entries.
--   4. Stabilization => final results in resultset where frame_pointer = 0.
--
-- Duck Typing:
-- ------------
-- Numeric, boolean, array, or other types are inferred at runtime based
-- on the operator (e.g., (+ x y) => x,y are numeric).
-- Malformed types can cause runtime errors (not handled here).
--
-- Example Evaluation:
-- -------------------
-- Expression: (+ (* 2 3) 4)
--   1. The top-level ["+", ["*", 2, 3], 4] enters workset.
--   2. Sub-expressions ["*", 2, 3] and 4 also enter workset.
--   3. Numeric literals 2, 3, and 4 evaluate directly => resultset.
--   4. ["*", 2, 3] => 6 (binary_operators).
--   5. ["+", 6, 4] => 10, final result at frame_pointer = 0.
--
-- Variable Scoping and Functions:
-- -------------------------------
-- - call_stack: Grows by adding a hash-like ID for each function call.
-- - env CTE: Stores variable bindings with a certain frame_pointer (lexical scope).
-- - (defun ...) adds an entry to vtable, which function_call transforms into a
--   (let ...) expression for final evaluation.

CREATE VIEW lisp_interpreter AS
WITH MUTUALLY RECURSIVE

    -- ==========================================================================
    -- Core Execution Engine: workset
    -- ==========================================================================
    -- Tracks expressions we need to evaluate along with the call_stack and scope.
    workset (call_stack bigint list, frame_pointer int, expr jsonb) AS (
        --------------------------------------------------------------------------
        -- 1) Initial entries from lisp_programs: top-level expressions with
        --    frame_pointer = 0.
        --------------------------------------------------------------------------
        SELECT list[id], 0, program
        FROM materialize.storage.lisp_programs

        UNION

        --------------------------------------------------------------------------
        -- 2) Decompose array expressions into their sub-expressions.
        --    Skip special forms 'if' and 'defun' because they have custom logic.
        --------------------------------------------------------------------------
        SELECT call_stack,
               frame_pointer + 1,
               nested_expr
        FROM workset
        CROSS JOIN LATERAL jsonb_array_elements(expr) AS nested_expr
        WHERE jsonb_typeof(expr) = 'array'
          AND expr->>0 NOT IN ('if', 'defun', 'defmacro', 'quote')

        UNION

        --------------------------------------------------------------------------
        -- 3) Special handling for 'if' condition. Only evaluate condition first.
        --------------------------------------------------------------------------
        SELECT call_stack,
               frame_pointer + 1,
               expr->1
        FROM workset
        WHERE jsonb_typeof(expr) = 'array'
          AND expr->>0 = 'if'

        UNION

        --------------------------------------------------------------------------
        -- 4) Once condition is known (from branch_selector), evaluate the chosen
        --    branch next.
        --------------------------------------------------------------------------
        SELECT call_stack,
               frame_pointer + 1,
               branch
        FROM branch_selector

        UNION

        --------------------------------------------------------------------------
        -- 5) Function calls: transform (f arg) into a let expression
        --    (see function_call). Then evaluate that let expression.
        --------------------------------------------------------------------------
        SELECT call_stack,
               frame_pointer + 1,
               let
        FROM function_call

        UNION

        --------------------------------------------------------------------------
        -- 6) Macro expansion: expanded code re-enters workset for evaluation.
        --------------------------------------------------------------------------
        SELECT call_stack,
               frame_pointer + 1,
               expanded
        FROM macro_expansion
    ),

    -- ==========================================================================
    -- Literals
    -- ==========================================================================
    -- Numeric, boolean, or null expressions evaluate to themselves.
    literals(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb) AS (
        SELECT call_stack, frame_pointer, expr, expr
        FROM workset
        WHERE jsonb_typeof(expr) IN ('number', 'boolean', 'null')
    ),

    -- ==========================================================================
    -- Binary Operators
    -- ==========================================================================
    -- Supports arithmetic (+ - * /), comparisons (= > >= < <=), and logical
    -- (and, or). Requires that arg1 and arg2 have been evaluated in resultset.
    -- Note: Produces new rows in resultset by combining existing results,
    -- which in turn can unblock subsequent expressions that depend on these
    -- computations.
    binary_operators(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb)  AS (
        SELECT
            ws.call_stack,
            ws.frame_pointer,
            ws.expr,
            CASE ws.expr->>0
                WHEN '+'  THEN to_jsonb(arg1.result::numeric + arg2.result::numeric)
                WHEN '-'  THEN to_jsonb(arg1.result::numeric - arg2.result::numeric)
                WHEN '*'  THEN to_jsonb(arg1.result::numeric * arg2.result::numeric)
                WHEN '/'  THEN to_jsonb(arg1.result::numeric / arg2.result::numeric)
                WHEN '='  THEN to_jsonb(arg1.result::numeric = arg2.result::numeric)
                WHEN '>=' THEN to_jsonb(arg1.result::numeric >= arg2.result::numeric)
                WHEN '<=' THEN to_jsonb(arg1.result::numeric <= arg2.result::numeric)
                WHEN '>'  THEN to_jsonb(arg1.result::numeric > arg2.result::numeric)
                WHEN '<'  THEN to_jsonb(arg1.result::numeric < arg2.result::numeric)
                WHEN 'and' THEN to_jsonb(arg1.result::boolean AND arg2.result::boolean)
                WHEN 'or'  THEN to_jsonb(arg1.result::boolean OR arg2.result::boolean)
            END
        FROM workset ws
        JOIN resultset arg1
          ON ws.call_stack = arg1.call_stack
         AND ws.expr->1    = arg1.expr
        JOIN resultset arg2
          ON ws.call_stack = arg2.call_stack
         AND ws.expr->2    = arg2.expr
        WHERE jsonb_typeof(ws.expr) = 'array'
          AND ws.expr->>0 IN (
            '+', '-', '*', '/', '=', '>', '>=', '<', '<=', 'and', 'or'
          )
    ),

    -- ==========================================================================
    -- Unary Operators
    -- ==========================================================================
    -- Currently only supports (not x), treated as boolean.
    unary_operators(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb)  AS (
        SELECT
            ws.call_stack,
            ws.frame_pointer,
            ws.expr,
            to_jsonb(NOT (arg.result::boolean))
        FROM workset ws
        JOIN resultset arg
          ON ws.call_stack = arg.call_stack
         AND ws.expr->1    = arg.expr
        WHERE jsonb_typeof(ws.expr) = 'array'
          AND ws.expr->>0 IN ('not')
    ),

    -- ==========================================================================
    -- Quote Special Form
    -- ==========================================================================
    -- (quote x) => return x literally. No evaluation of x.
    quote(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb)  AS (
        SELECT call_stack,
               frame_pointer,
               expr,
               expr->1
        FROM workset
        WHERE jsonb_typeof(expr) = 'array'
          AND expr->>0 = 'quote'
    ),

    -- ==========================================================================
    -- List Construction: cons
    -- ==========================================================================
    -- (cons x y) => Evaluate x,y and produce a concatenated JSON array if possible.
    cons(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb)  AS (
        SELECT
            ws.call_stack,
            ws.frame_pointer,
            ws.expr,
            jsonb_build_array(arg1.result, arg2.result)
        FROM workset ws
        JOIN resultset arg1
          ON arg1.call_stack = ws.call_stack
         AND arg1.expr       = ws.expr->1
        JOIN resultset arg2
          ON arg2.call_stack = ws.call_stack
         AND arg2.expr       = ws.expr->2
        WHERE jsonb_typeof(ws.expr) = 'array'
          AND ws.expr->>0 = 'cons'
    ),

    -- ==========================================================================
    -- List Access: car / cdr
    -- ==========================================================================
    -- (car x) => first element, (cdr x) => all but first element.
    carcdr(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb)  AS (
        SELECT
            ws.call_stack,
            ws.frame_pointer,
            ws.expr,
            CASE ws.expr->>0
                WHEN 'car' THEN arg.result->0
                WHEN 'cdr' THEN arg.result->1
            END
        FROM workset ws
        JOIN resultset arg
          ON arg.call_stack = ws.call_stack
         AND arg.expr       = ws.expr->1
        WHERE jsonb_typeof(ws.expr) = 'array'
          AND ws.expr->>0 IN ('car', 'cdr')
    ),

    -- ==========================================================================
    -- Conditional Logic: branch_selector
    -- ==========================================================================
    -- Determines which branch of 'if' to evaluate based on the condition result.
    branch_selector(call_stack bigint list, frame_pointer int, expr jsonb, branch jsonb) AS (
        SELECT
            ws.call_stack,
            ws.frame_pointer,
            ws.expr,
            CASE cond.result::boolean
                WHEN TRUE THEN ws.expr->2  -- 'then' branch
                ELSE ws.expr->3            -- 'else' branch
            END
        FROM workset ws
        JOIN resultset cond
          ON ws.call_stack = cond.call_stack
         AND ws.expr->1    = cond.expr
        WHERE jsonb_typeof(ws.expr) = 'array'
          AND ws.expr->>0 = 'if'
    ),

    -- ==========================================================================
    -- If Expression Result: if_eval
    -- ==========================================================================
    -- Joins the chosen branch from branch_selector with its final result.
    if_eval(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb)  AS (
        SELECT
            selector.call_stack,
            selector.frame_pointer,
            selector.expr,
            branch.result
        FROM branch_selector selector
        JOIN resultset branch
          ON selector.call_stack = branch.call_stack
         AND selector.branch     = branch.expr
    ),

    -- ==========================================================================
    -- Function Definitions: vtable
    -- ==========================================================================
    -- Captures (defun name arg body).
    -- Used later to transform (name val) calls into let expressions.
    vtable(name text, argument text, body jsonb) AS (
        SELECT
            expr->>1,  -- function name
            expr->>2,  -- parameter name
            expr->3    -- function body
        FROM workset
        WHERE expr->>0 = 'defun'
    ),

    -- ==========================================================================
    -- Macro Definitions: macro_table
    -- ==========================================================================
    -- Captures (defmacro name params body).
    -- Normalizes single param to array for uniform handling.
    macro_table(name text, params jsonb, body jsonb) AS (
        SELECT expr->>1,
               CASE jsonb_typeof(expr->2)
                   WHEN 'array' THEN expr->2
                   ELSE jsonb_build_array(expr->2)
               END,
               expr->3
        FROM workset
        WHERE expr->>0 = 'defmacro'
    ),

    -- ==========================================================================
    -- Macro Body Bindings: macro_body_bindings
    -- ==========================================================================
    -- Extracts the names of variables bound by top-level 'let' forms inside
    -- macro body templates. These are the identifiers that need to be
    -- alpha-renamed during expansion to prevent variable capture (hygiene).
    --
    -- Each variable gets a positional index (var_idx) so the renaming pass
    -- (macro_rename) can process them one at a time in a deterministic order.
    macro_body_bindings(name text, var_idx int, var_name text) AS (
        SELECT mt.name, idx.i, mt.body->1->idx.i->>0
        FROM macro_table mt
        CROSS JOIN LATERAL generate_series(0, jsonb_array_length(mt.body->1) - 1) AS idx(i)
        WHERE mt.body->>0 = 'let'
    ),

    -- ==========================================================================
    -- Macro Hygienic Rename: macro_rename
    -- ==========================================================================
    -- Alpha-renames let-bound variables in the RAW macro body template BEFORE
    -- parameter substitution. This ensures that call-site arguments substituted
    -- later are not accidentally renamed, preventing variable capture.
    --
    -- Unique name format: __hyg_<original>_<hash>
    --   where <hash> = crc32(call_stack || frame_pointer || macro_name)
    macro_rename(call_stack bigint list, frame_pointer int, expr jsonb,
                 name text, current_body text, rename_idx int) AS (
        -- Seed: start from the raw macro body template
        SELECT ws.call_stack, ws.frame_pointer, ws.expr, mt.name,
               mt.body::text, 0
        FROM workset ws
        JOIN macro_table mt ON ws.expr->>0 = mt.name
        WHERE jsonb_typeof(ws.expr) = 'array'
          AND ws.expr->1 IS NOT NULL

        UNION

        -- Each iteration: rename the variable at position rename_idx to its gensym.
        SELECT mr.call_stack, mr.frame_pointer, mr.expr, mr.name,
               replace(mr.current_body,
                       '"' || mbb.var_name || '"',
                       '"__hyg_' || mbb.var_name || '_' ||
                       crc32(mr.call_stack::text || '_' || mr.frame_pointer::text || '_' || mr.name)::text
                       || '"'),
               mr.rename_idx + 1
        FROM macro_rename mr
        JOIN macro_body_bindings mbb
          ON mr.name = mbb.name
         AND mr.rename_idx = mbb.var_idx
    ),

    -- ==========================================================================
    -- Macro Substitution: macro_sub
    -- ==========================================================================
    -- Iteratively substitutes macro parameters into the (already renamed) body.
    -- Seeds from macro_rename's final output rather than the raw body, so that
    -- let-bound variables have already been alpha-renamed for hygiene.
    macro_sub(call_stack bigint list, frame_pointer int, expr jsonb, name text, current_body text, param_idx int) AS (
        -- Seed: renamed body template (or raw body if no let-bindings to rename)
        SELECT mr.call_stack, mr.frame_pointer, mr.expr, mr.name,
               mr.current_body, 0
        FROM macro_rename mr
        WHERE mr.rename_idx = (
            SELECT COALESCE(max(var_idx) + 1, 0)
            FROM macro_body_bindings mbb
            WHERE mbb.name = mr.name
        )

        UNION

        -- Each iteration: substitute one parameter
        SELECT ms.call_stack, ms.frame_pointer, ms.expr, ms.name,
               replace(ms.current_body,
                       '"' || (mt.params->>ms.param_idx) || '"',
                       (ms.expr->(ms.param_idx + 1))::text),
               ms.param_idx + 1
        FROM macro_sub ms
        JOIN macro_table mt ON ms.name = mt.name
        WHERE ms.param_idx < jsonb_array_length(mt.params)
    ),

    -- ==========================================================================
    -- Macro Expansion: macro_expansion
    -- ==========================================================================
    -- Extracts the fully renamed and substituted macro body, ready for evaluation.
    macro_expansion(call_stack bigint list, frame_pointer int, expr jsonb, expanded jsonb) AS (
        SELECT ms.call_stack, ms.frame_pointer, ms.expr, ms.current_body::jsonb
        FROM macro_sub ms
        JOIN macro_table mt ON ms.name = mt.name
        WHERE ms.param_idx = jsonb_array_length(mt.params)
    ),

    -- ==========================================================================
    -- Macro Evaluation: macro_eval
    -- ==========================================================================
    -- Bridges the original macro call to the result of the expanded expression.
    macro_eval(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb) AS (
        SELECT me.call_stack, me.frame_pointer, me.expr, rs.result
        FROM macro_expansion me
        JOIN resultset rs
          ON rs.call_stack = me.call_stack
         AND rs.expr = me.expanded
    ),

    -- ==========================================================================
    -- Function Application: function_call
    -- ==========================================================================
    -- Detects (f arg), looks up (f) in vtable, and builds a let expression
    -- that binds the function's parameter to arg's result. Creates a new call frame
    -- and resets frame_pointer so the function body starts at a new 0-level scope.
    function_call(call_stack bigint list, frame_pointer int, func text, arg jsonb, let jsonb) AS (
        SELECT
            ws.call_stack || crc32(
                jsonb_build_array(
                    'let',
                    jsonb_build_array(jsonb_build_array(vtable.argument, ws.expr->1)),
                    vtable.body
                )::text
            )::bigint,
            0,  -- new function scope
            vtable.name,
            arg.result,
            jsonb_build_array(
                'let',
                jsonb_build_array(jsonb_build_array(
                    vtable.argument, arg.result
                )),
                vtable.body
            )
        FROM workset ws
        JOIN vtable
          ON ws.expr->>0 = vtable.name
        JOIN resultset arg
          ON ws.call_stack = arg.call_stack
         AND ws.expr->1    = arg.expr
        WHERE ws.expr->1 IS NOT NULL
    ),

    -- ==========================================================================
    -- Function Evaluation: function_eval
    -- ==========================================================================
    -- Connects the original function call (f arg) to the final result of the
    -- let expression built in function_call.
    function_eval(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb)  AS (
        SELECT
            ws.call_stack,
            ws.frame_pointer,
            ws.expr,
            rs.result
        FROM workset ws
        JOIN function_call fc
          ON ws.call_stack = fc.call_stack[:list_length(fc.call_stack) - 1]
          AND ws.expr->>0  = fc.func
        JOIN resultset arg
          ON ws.call_stack = arg.call_stack
          AND ws.expr->1   = arg.expr
          AND fc.arg       = arg.result
        JOIN resultset rs
          ON rs.expr = fc.let
        WHERE jsonb_typeof(ws.expr) = 'array'
    ),

    -- ==========================================================================
    -- Variable Environment: env
    -- ==========================================================================
    -- Stores variable bindings introduced by (let ...).
    -- Each binding has a name, value, and a frame_pointer indicating its scope.
    env(call_stack bigint list, frame_pointer int, name text, value jsonb) AS (
        SELECT
            ws.call_stack,
            ws.frame_pointer + 1,
            binding->>0,          -- variable name
            rs.result             -- computed value
        FROM workset ws
        CROSS JOIN LATERAL jsonb_array_elements(ws.expr->1) AS binding(expr)
        JOIN resultset rs
          ON rs.call_stack = ws.call_stack
         AND rs.expr       = binding->1
        WHERE ws.expr->>0 = 'let'
    ),

    -- ==========================================================================
    -- Variable Binding Resolution: variable_binding
    -- ==========================================================================
    -- Resolves variable names by matching them to the highest env.frame_pointer
    -- <= current frame_pointer.
    variable_binding(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb)  AS (
        SELECT DISTINCT ON (ws.call_stack, ws.frame_pointer, ws.expr)
            ws.call_stack,
            ws.frame_pointer,
            ws.expr,
            env.value
        FROM workset ws
        JOIN env
          ON env.call_stack   = ws.call_stack
         AND env.name         = ws.expr#>>'{}'  -- JSON string -> text
         AND env.value        IS NOT NULL
         AND env.frame_pointer <= ws.frame_pointer
        WHERE jsonb_typeof(ws.expr) = 'string'
        ORDER BY ws.call_stack, ws.frame_pointer, ws.expr, env.frame_pointer DESC
    ),

    -- ==========================================================================
    -- Let Expression: let_eval
    -- ==========================================================================
    -- (let ((var expr) ...) body) => set up environment in env, then evaluate body.
    let_eval(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb)  AS (
        SELECT
            ws.call_stack,
            ws.frame_pointer,
            ws.expr,
            body_eval.result
        FROM workset ws
        JOIN resultset body_eval
          ON body_eval.call_stack = ws.call_stack
         AND body_eval.expr       = ws.expr->2
        WHERE jsonb_typeof(ws.expr) = 'array'
          AND ws.expr->>0 = 'let'
    ),

    -- ==========================================================================
    -- Aggregation of Partial Results: resultset
    -- ==========================================================================
    -- UNION of all specialized rules that produce results. Materialize updates
    -- this incrementally until no new rows remain, forming a fixed point of evaluation.
    resultset(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb)  AS (
        SELECT * FROM literals
        UNION SELECT * FROM binary_operators
        UNION SELECT * FROM unary_operators
        UNION SELECT * FROM quote
        UNION SELECT * FROM cons
        UNION SELECT * FROM carcdr
        UNION SELECT * FROM if_eval
        UNION SELECT * FROM function_eval
        UNION SELECT * FROM variable_binding
        UNION SELECT * FROM let_eval
        UNION SELECT * FROM macro_eval
    )

-- ============================================================================
-- Final Output
-- ============================================================================
-- Rows with frame_pointer = 0 are fully evaluated top-level expressions.
-- At fixed point, these represent the final answers of the interpreter.
SELECT *
FROM resultset
WHERE frame_pointer = 0
ORDER BY call_stack;

-- ============================================================================
-- Unit Tests
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Arithmetic: +, -, *, / and nested arithmetic
-- ---------------------------------------------------------------------------
EXECUTE UNIT TEST test_arithmetic
FOR materialize.public.lisp_interpreter
MOCK materialize.storage.lisp_programs(id int, program jsonb) AS (
  SELECT * FROM (VALUES
    (1, '["+"  , 1, 2]'::jsonb),
    (2, '["-", 5, 3]'::jsonb),
    (3, '["*", 4, 2]'::jsonb),
    (4, '["/", 10, 2]'::jsonb),
    (5, '["+", ["+", 1, 2], ["*", 3, 4]]'::jsonb),
    (6, '["*", ["-", 10, 5], ["/", 15, 3]]'::jsonb)
  )
),
EXPECTED(call_stack int8 list, frame_pointer int, expr jsonb, result jsonb) AS (
  SELECT * FROM (VALUES
    (LIST[1::bigint], 0, '["+"  , 1, 2]'::jsonb, '3'::jsonb),
    (LIST[2::bigint], 0, '["-", 5, 3]'::jsonb, '2'::jsonb),
    (LIST[3::bigint], 0, '["*", 4, 2]'::jsonb, '8'::jsonb),
    (LIST[4::bigint], 0, '["/", 10, 2]'::jsonb, '5'::jsonb),
    (LIST[5::bigint], 0, '["+", ["+", 1, 2], ["*", 3, 4]]'::jsonb, '15'::jsonb),
    (LIST[6::bigint], 0, '["*", ["-", 10, 5], ["/", 15, 3]]'::jsonb, '25'::jsonb)
  )
);

-- ---------------------------------------------------------------------------
-- Comparison: =, <, >, <=, >= operators
-- ---------------------------------------------------------------------------
EXECUTE UNIT TEST test_comparison
FOR materialize.public.lisp_interpreter
MOCK materialize.storage.lisp_programs(id int, program jsonb) AS (
  SELECT * FROM (VALUES
    (1, '["=", 3, 3]'::jsonb),
    (2, '["<", 2, 5]'::jsonb),
    (3, '[">", 10, 5]'::jsonb),
    (4, '[">=", 5, 5]'::jsonb),
    (5, '["<=", 3, 5]'::jsonb)
  )
),
EXPECTED(call_stack int8 list, frame_pointer int, expr jsonb, result jsonb) AS (
  SELECT * FROM (VALUES
    (LIST[1::bigint], 0, '["=", 3, 3]'::jsonb, 'true'::jsonb),
    (LIST[2::bigint], 0, '["<", 2, 5]'::jsonb, 'true'::jsonb),
    (LIST[3::bigint], 0, '[">", 10, 5]'::jsonb, 'true'::jsonb),
    (LIST[4::bigint], 0, '[">=", 5, 5]'::jsonb, 'true'::jsonb),
    (LIST[5::bigint], 0, '["<=", 3, 5]'::jsonb, 'true'::jsonb)
  )
);

-- ---------------------------------------------------------------------------
-- Logical: and, or, not and combinations
-- ---------------------------------------------------------------------------
EXECUTE UNIT TEST test_logical
FOR materialize.public.lisp_interpreter
MOCK materialize.storage.lisp_programs(id int, program jsonb) AS (
  SELECT * FROM (VALUES
    (1, '["and", true, true]'::jsonb),
    (2, '["or", false, true]'::jsonb),
    (3, '["not", false]'::jsonb),
    (4, '["and", [">", 5, 3], ["=", ["+", 2, 2], 4]]'::jsonb),
    (5, '["or", ["<", 10, 5], [">=", ["/", 10, 2], 5]]'::jsonb)
  )
),
EXPECTED(call_stack int8 list, frame_pointer int, expr jsonb, result jsonb) AS (
  SELECT * FROM (VALUES
    (LIST[1::bigint], 0, '["and", true, true]'::jsonb, 'true'::jsonb),
    (LIST[2::bigint], 0, '["or", false, true]'::jsonb, 'true'::jsonb),
    (LIST[3::bigint], 0, '["not", false]'::jsonb, 'true'::jsonb),
    (LIST[4::bigint], 0, '["and", [">", 5, 3], ["=", ["+", 2, 2], 4]]'::jsonb, 'true'::jsonb),
    (LIST[5::bigint], 0, '["or", ["<", 10, 5], [">=", ["/", 10, 2], 5]]'::jsonb, 'true'::jsonb)
  )
);

-- ---------------------------------------------------------------------------
-- Conditionals: if/else expressions
-- ---------------------------------------------------------------------------
EXECUTE UNIT TEST test_conditionals
FOR materialize.public.lisp_interpreter
MOCK materialize.storage.lisp_programs(id int, program jsonb) AS (
  SELECT * FROM (VALUES
    (1, '["if", true, 1, 2]'::jsonb),
    (2, '["if", false, 1, 2]'::jsonb),
    (3, '["if", ["=", ["/", 10, 2], 5], true, false]'::jsonb),
    (4, '["if", ["not", ["or", false, false]], 1, ["/", 1, 0]]'::jsonb)
  )
),
EXPECTED(call_stack int8 list, frame_pointer int, expr jsonb, result jsonb) AS (
  SELECT * FROM (VALUES
    (LIST[1::bigint], 0, '["if", true, 1, 2]'::jsonb, '1'::jsonb),
    (LIST[2::bigint], 0, '["if", false, 1, 2]'::jsonb, '2'::jsonb),
    (LIST[3::bigint], 0, '["if", ["=", ["/", 10, 2], 5], true, false]'::jsonb, 'true'::jsonb),
    (LIST[4::bigint], 0, '["if", ["not", ["or", false, false]], 1, ["/", 1, 0]]'::jsonb, '1'::jsonb)
  )
);

-- ---------------------------------------------------------------------------
-- Let bindings: variable scoping
-- ---------------------------------------------------------------------------
EXECUTE UNIT TEST test_let_bindings
FOR materialize.public.lisp_interpreter
MOCK materialize.storage.lisp_programs(id int, program jsonb) AS (
  SELECT * FROM (VALUES
    (1, '["let", [["x", 5]], "x"]'::jsonb),
    (2, '["let", [["x", 5]], ["+", "x", 3]]'::jsonb),
    (3, '["let", [["x", 10], ["y", 5]], ["+", "x", "y"]]'::jsonb),
    (4, '["let", [["x", 5], ["y", ["*", "x", 2]]], "y"]'::jsonb),
    (5, '["let", [["x", 5], ["y", 10]], ["if", [">", "x", 3], "x", "y"]]'::jsonb),
    (6, '["let", [["x", 5]], ["let", [["y", ["*", "x", 2]]], ["+", "x", "y"]]]'::jsonb),
    (7, '["let", [["base", 10], ["mult", 2]], ["*", ["+", "base", 5], "mult"]]'::jsonb)
  )
),
EXPECTED(call_stack int8 list, frame_pointer int, expr jsonb, result jsonb) AS (
  SELECT * FROM (VALUES
    (LIST[1::bigint], 0, '["let", [["x", 5]], "x"]'::jsonb, '5'::jsonb),
    (LIST[2::bigint], 0, '["let", [["x", 5]], ["+", "x", 3]]'::jsonb, '8'::jsonb),
    (LIST[3::bigint], 0, '["let", [["x", 10], ["y", 5]], ["+", "x", "y"]]'::jsonb, '15'::jsonb),
    (LIST[4::bigint], 0, '["let", [["x", 5], ["y", ["*", "x", 2]]], "y"]'::jsonb, '10'::jsonb),
    (LIST[5::bigint], 0, '["let", [["x", 5], ["y", 10]], ["if", [">", "x", 3], "x", "y"]]'::jsonb, '5'::jsonb),
    (LIST[6::bigint], 0, '["let", [["x", 5]], ["let", [["y", ["*", "x", 2]]], ["+", "x", "y"]]]'::jsonb, '15'::jsonb),
    (LIST[7::bigint], 0, '["let", [["base", 10], ["mult", 2]], ["*", ["+", "base", 5], "mult"]]'::jsonb, '30'::jsonb)
  )
);

-- ---------------------------------------------------------------------------
-- Lists: cons, car, cdr, quote
-- ---------------------------------------------------------------------------
EXECUTE UNIT TEST test_lists
FOR materialize.public.lisp_interpreter
MOCK materialize.storage.lisp_programs(id int, program jsonb) AS (
  SELECT * FROM (VALUES
    (1,  '["cons", 1, 2]'::jsonb),
    (2,  '["cons", 1, ["cons", 2, 3]]'::jsonb),
    (3,  '["car", ["cons", 1, 2]]'::jsonb),
    (4,  '["car", ["cons", 5, ["cons", 2, 3]]]'::jsonb),
    (5,  '["cdr", ["cons", 1, 2]]'::jsonb),
    (6,  '["cdr", ["cons", 1, ["cons", 2, 3]]]'::jsonb),
    (7,  '["car", ["cons", ["*", 2, 3], ["cons", 4, 5]]]'::jsonb),
    (8,  '["cdr", ["cons", 1, ["+", 2, 3]]]'::jsonb),
    (9,  '["let", [["pair", ["cons", 1, 2]]], ["car", "pair"]]'::jsonb),
    (10, '["let", [["lst", ["cons", 1, ["cons", 2, 3]]]], ["cdr", "lst"]]'::jsonb),
    (11, '["quote", 42]'::jsonb),
    (12, '["quote", ["list", 1, 2, 3]]'::jsonb),
    (13, '["quote", ["a", "b", "c"]]'::jsonb),
    (14, '["quote", ["quote", ["a", "b"]]]'::jsonb),
    (15, '["let", [["x", ["quote", ["+", 1, 2]]]], "x"]'::jsonb),
    (16, '["quote", "x"]'::jsonb)
  )
),
EXPECTED(call_stack int8 list, frame_pointer int, expr jsonb, result jsonb) AS (
  SELECT * FROM (VALUES
    (LIST[1::bigint],  0, '["cons", 1, 2]'::jsonb, '[1, 2]'::jsonb),
    (LIST[2::bigint],  0, '["cons", 1, ["cons", 2, 3]]'::jsonb, '[1, [2, 3]]'::jsonb),
    (LIST[3::bigint],  0, '["car", ["cons", 1, 2]]'::jsonb, '1'::jsonb),
    (LIST[4::bigint],  0, '["car", ["cons", 5, ["cons", 2, 3]]]'::jsonb, '5'::jsonb),
    (LIST[5::bigint],  0, '["cdr", ["cons", 1, 2]]'::jsonb, '2'::jsonb),
    (LIST[6::bigint],  0, '["cdr", ["cons", 1, ["cons", 2, 3]]]'::jsonb, '[2, 3]'::jsonb),
    (LIST[7::bigint],  0, '["car", ["cons", ["*", 2, 3], ["cons", 4, 5]]]'::jsonb, '6'::jsonb),
    (LIST[8::bigint],  0, '["cdr", ["cons", 1, ["+", 2, 3]]]'::jsonb, '5'::jsonb),
    (LIST[9::bigint],  0, '["let", [["pair", ["cons", 1, 2]]], ["car", "pair"]]'::jsonb, '1'::jsonb),
    (LIST[10::bigint], 0, '["let", [["lst", ["cons", 1, ["cons", 2, 3]]]], ["cdr", "lst"]]'::jsonb, '[2, 3]'::jsonb),
    (LIST[11::bigint], 0, '["quote", 42]'::jsonb, '42'::jsonb),
    (LIST[12::bigint], 0, '["quote", ["list", 1, 2, 3]]'::jsonb, '["list", 1, 2, 3]'::jsonb),
    (LIST[13::bigint], 0, '["quote", ["a", "b", "c"]]'::jsonb, '["a", "b", "c"]'::jsonb),
    (LIST[14::bigint], 0, '["quote", ["quote", ["a", "b"]]]'::jsonb, '["quote", ["a", "b"]]'::jsonb),
    (LIST[15::bigint], 0, '["let", [["x", ["quote", ["+", 1, 2]]]], "x"]'::jsonb, '["+", 1, 2]'::jsonb),
    (LIST[16::bigint], 0, '["quote", "x"]'::jsonb, '"x"'::jsonb)
  )
);

-- ---------------------------------------------------------------------------
-- Functions: defun + factorial, is-even/odd, fib
-- ---------------------------------------------------------------------------
EXECUTE UNIT TEST test_functions
FOR materialize.public.lisp_interpreter
MOCK materialize.storage.lisp_programs(id int, program jsonb) AS (
  SELECT * FROM (VALUES
    (1, '["defun", "factorial", "x", ["if", ["=", "x", 1], 1, ["*", "x", ["factorial", ["-", "x", 1]]]]]'::jsonb),
    (2, '["defun", "is-even", "n", ["if", ["=", "n", 0], true, ["if", ["=", "n", 1], false, ["is-odd", ["-", "n", 1]]]]]'::jsonb),
    (3, '["defun", "is-odd", "n", ["if", ["=", "n", 0], false, ["if", ["=", "n", 1], true, ["is-even", ["-", "n", 1]]]]]'::jsonb),
    (4, '["defun", "fib", "n", ["if", ["or", ["=", "n", 0], ["=", "n", 1]], "n", ["+", ["fib", ["-", "n", 1]], ["fib", ["-", "n", 2]]]]]'::jsonb),
    (5, '["factorial", 3]'::jsonb),
    (6, '["is-even", 4]'::jsonb),
    (7, '["is-odd", 7]'::jsonb),
    (8, '["is-even", 7]'::jsonb),
    (9, '["fib", 5]'::jsonb)
  )
),
EXPECTED(call_stack int8 list, frame_pointer int, expr jsonb, result jsonb) AS (
  SELECT * FROM (VALUES
    (LIST[5::bigint], 0, '["factorial", 3]'::jsonb, '6'::jsonb),
    (LIST[6::bigint], 0, '["is-even", 4]'::jsonb, 'true'::jsonb),
    (LIST[7::bigint], 0, '["is-odd", 7]'::jsonb, 'true'::jsonb),
    (LIST[8::bigint], 0, '["is-even", 7]'::jsonb, 'false'::jsonb),
    (LIST[9::bigint], 0, '["fib", 5]'::jsonb, '5'::jsonb)
  )
);

-- ---------------------------------------------------------------------------
-- Tower of Hanoi: macros + functions
-- ---------------------------------------------------------------------------
EXECUTE UNIT TEST test_tower_of_hanoi
FOR materialize.public.lisp_interpreter
MOCK materialize.storage.lisp_programs(id int, program jsonb) AS (
  SELECT * FROM (VALUES
    (1,  '["defmacro", "double", "x", ["+", "x", "x"]]'::jsonb),
    (2,  '["defmacro", "dec", "x", ["-", "x", 1]]'::jsonb),
    (3,  '["defmacro", "square", "x", ["*", "x", "x"]]'::jsonb),
    (4,  '["defmacro", "when", ["cond", "body"], ["if", "cond", "body", false]]'::jsonb),
    (5,  '["defmacro", "unless", ["cond", "body"], ["if", "cond", false, "body"]]'::jsonb),
    (6,  '["defun", "hanoi", "n", ["if", ["=", "n", 0], 0, ["+", ["double", ["hanoi", ["dec", "n"]]], 1]]]'::jsonb),
    (7,  '["defun", "pow2", "n", ["if", ["=", "n", 0], 1, ["double", ["pow2", ["dec", "n"]]]]]'::jsonb),
    (8,  '["hanoi", 1]'::jsonb),
    (9,  '["hanoi", 2]'::jsonb),
    (10, '["hanoi", 3]'::jsonb),
    (11, '["hanoi", 4]'::jsonb),
    (12, '["=", ["hanoi", 4], ["-", ["pow2", 4], 1]]'::jsonb),
    (13, '["let", [["moves", ["hanoi", 3]], ["total", ["pow2", 3]]], ["cons", "moves", ["cons", "total", ["=", "moves", ["-", "total", 1]]]]]'::jsonb),
    (14, '["when", [">", ["hanoi", 4], 10], ["square", 4]]'::jsonb),
    (15, '["unless", [">", ["hanoi", 1], 10], ["square", 5]]'::jsonb)
  )
),
EXPECTED(call_stack int8 list, frame_pointer int, expr jsonb, result jsonb) AS (
  SELECT * FROM (VALUES
    (LIST[8::bigint],  0, '["hanoi", 1]'::jsonb, '1'::jsonb),
    (LIST[9::bigint],  0, '["hanoi", 2]'::jsonb, '3'::jsonb),
    (LIST[10::bigint], 0, '["hanoi", 3]'::jsonb, '7'::jsonb),
    (LIST[11::bigint], 0, '["hanoi", 4]'::jsonb, '15'::jsonb),
    (LIST[12::bigint], 0, '["=", ["hanoi", 4], ["-", ["pow2", 4], 1]]'::jsonb, 'true'::jsonb),
    (LIST[13::bigint], 0, '["let", [["moves", ["hanoi", 3]], ["total", ["pow2", 3]]], ["cons", "moves", ["cons", "total", ["=", "moves", ["-", "total", 1]]]]]'::jsonb, '[7, [8, true]]'::jsonb),
    (LIST[14::bigint], 0, '["when", [">", ["hanoi", 4], 10], ["square", 4]]'::jsonb, '16'::jsonb),
    (LIST[15::bigint], 0, '["unless", [">", ["hanoi", 1], 10], ["square", 5]]'::jsonb, '25'::jsonb)
  )
);

-- ---------------------------------------------------------------------------
-- Macro hygiene: let-bound variables should not capture call-site names
-- ---------------------------------------------------------------------------
EXECUTE UNIT TEST test_macro_hygiene
FOR materialize.public.lisp_interpreter
MOCK materialize.storage.lisp_programs(id int, program jsonb) AS (
  SELECT * FROM (VALUES
    (1, '["defmacro", "swap-add", ["a", "b"], ["let", [["tmp", "a"]], ["+", "tmp", "b"]]]'::jsonb),
    (2, '["swap-add", 3, 4]'::jsonb),
    (3, '["let", [["tmp", 10]], ["swap-add", "tmp", 20]]'::jsonb)
  )
),
EXPECTED(call_stack int8 list, frame_pointer int, expr jsonb, result jsonb) AS (
  SELECT * FROM (VALUES
    (LIST[2::bigint], 0, '["swap-add", 3, 4]'::jsonb, '7'::jsonb),
    (LIST[3::bigint], 0, '["let", [["tmp", 10]], ["swap-add", "tmp", 20]]'::jsonb, '30'::jsonb)
  )
);
