CREATE VIEW lisp_interpreter AS
WITH MUTUALLY RECURSIVE 
    workset (call_stack bigint list, frame_pointer int, expr jsonb) AS (
        SELECT list[id], 0, program
        FROM lisp_programs

        UNION 

        SELECT call_stack, frame_pointer + 1, nested_expr
        FROM workset
        CROSS JOIN LATERAL jsonb_array_elements(expr) AS nested_expr
        WHERE jsonb_typeof(expr) = 'array'
            AND expr->>0 NOT IN ('if', 'defun')
        
        UNION 

        SELECT call_stack, frame_pointer + 1, expr->1
        FROM workset
        WHERE jsonb_typeof(expr) = 'array'
            AND expr->>0 = 'if'

        UNION

        SELECT call_stack, frame_pointer + 1, branch
        FROM branch_selector

        UNION 

        SELECT call_stack, frame_pointer + 1, let
        FROM function_call 
    ),

    branch_selector(call_stack bigint list, frame_pointer int, expr jsonb, branch jsonb) AS (
        SELECT 
            ws.call_stack,
            ws.frame_pointer,
            ws.expr,
            CASE cond.result::boolean 
                WHEN TRUE THEN ws.expr->2
                ELSE ws.expr->3
            END
        FROM workset ws
        JOIN resultset cond ON ws.call_stack = cond.call_stack 
            AND ws.expr->1 = cond.expr
            AND cond.result IS NOT NULL
        WHERE jsonb_typeof(ws.expr) = 'array'
            AND ws.expr->>0 = 'if'
    ),

    env(call_stack bigint list, frame_pointer int, name text, value jsonb) AS (
        SELECT 
            ws.call_stack,
            ws.frame_pointer + 1,
            binding->>0,
            rs.result
        FROM workset ws
        CROSS JOIN LATERAL jsonb_array_elements(ws.expr->1) AS binding(expr)
        JOIN resultset rs ON rs.call_stack = ws.call_stack 
            AND rs.expr = binding->1
        WHERE ws.expr->>0 = 'let'
    ),

    vtable(name text, argument text, body jsonb) AS (
        SELECT
            expr->>1,
            expr->>2,
            expr->3
        FROM workset
        WHERE expr->>0 = 'defun'
    ),

    function_call(call_stack bigint list, frame_pointer int, expr jsonb, let jsonb) AS (
        SELECT DISTINCT
            ws.call_stack || crc32(jsonb_build_array(
                'let', 
                jsonb_build_array(jsonb_build_array(
                    vtable.argument, ws.expr->1
                )), vtable.body)::text)::bigint,
            0,
            jsonb_build_array(vtable.name, arg.result),
            jsonb_build_array(
                'let', 
                jsonb_build_array(jsonb_build_array(
                    vtable.argument, arg.result
                )), vtable.body)
        FROM workset ws
        JOIN vtable   ON ws.expr->>0 = vtable.name
        JOIN resultset arg ON ws.call_stack = arg.call_stack
            AND ws.expr->1 = arg.expr
        WHERE ws.expr->1 IS NOT NULL
    ),

    literals(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb) AS (
        SELECT call_stack, frame_pointer, expr, expr
        FROM workset
        WHERE jsonb_typeof(expr) in ('number', 'boolean', 'null')
    ),

    binary_operators(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb) AS (
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
                WHEN 'or'  THEN to_jsonb(arg1.result::boolean OR  arg2.result::boolean)
            END
        FROM workset ws
        JOIN resultset arg1 ON ws.call_stack = arg1.call_stack
            AND ws.expr->1 = arg1.expr
        JOIN resultset arg2 ON ws.call_stack = arg2.call_stack
            AND ws.expr->2 = arg2.expr
        WHERE jsonb_typeof(ws.expr) = 'array'
            AND ws.expr->>0 IN ('+', '-', '*', '/', '=', '>', '>=', '<', '<=', 'and', 'or')
    ),

    unary_operators(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb) AS (
        SELECT
            ws.call_stack,
            ws.frame_pointer,
            ws.expr,
            to_jsonb(NOT (arg.result::boolean))
        FROM workset ws
        JOIN resultset arg ON ws.call_stack = arg.call_stack
            AND ws.expr->1 = arg.expr
        WHERE jsonb_typeof(ws.expr) = 'array'
            AND ws.expr->>0 IN ('not')
    ),

    quote(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb) AS (
        SELECT call_stack, frame_pointer, expr, expr - 0
        FROM workset
        WHERE jsonb_typeof(expr) = 'array'
            AND expr->>0 = 'quote'
    ),

    cons(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb) AS (
        SELECT
            ws.call_stack,
            ws.frame_pointer,
            ws.expr,
            arg1.result || arg2.result
        FROM workset ws
        JOIN resultset arg1 ON arg1.call_stack = ws.call_stack 
            AND arg1.expr = ws.expr->1
        JOIN resultset arg2 ON arg2.call_stack = ws.call_stack 
            AND arg2.expr = ws.expr->2
        WHERE jsonb_typeof(ws.expr) = 'array'
            AND ws.expr->>0 = 'cons'
    ),

    carcdr(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb) AS (
        SELECT
            ws.call_stack,
            ws.frame_pointer,
            ws.expr,
            CASE ws.expr->>0
                WHEN 'car' THEN arg.result->0
                WHEN 'cdr' THEN arg.result->1
            END
        FROM workset ws
        JOIN resultset arg ON arg.call_stack = ws.call_stack 
            AND arg.expr = ws.expr->1
        WHERE jsonb_typeof(ws.expr) = 'array'
            AND ws.expr->>0 IN ('car', 'cdr')
    ),

    if_eval(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb) AS (
        SELECT 
            selector.call_stack,
            selector.frame_pointer,
            selector.expr,
            branch.result
        FROM branch_selector selector
        JOIN resultset branch ON selector.call_stack = branch.call_stack
            AND selector.branch = branch.expr
    ),

    function_eval(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb) AS (
        SELECT
            ws.call_stack, 
            ws.frame_pointer,
            ws.expr, 
            rs.result
        FROM workset ws
        JOIN function_call fc ON ws.call_stack = fc.call_stack[:list_length(fc.call_stack) - 1] 
            AND ws.expr->>0 = fc.expr->>0
        JOIN resultset rs ON  rs.expr = fc.let
        WHERE jsonb_typeof(ws.expr) = 'array'
    ),

    variable_binding(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb) AS (
        SELECT DISTINCT ON (ws.call_stack, ws.frame_pointer, ws.expr)
            ws.call_stack,
            ws.frame_pointer,
            ws.expr,
            env.value
        FROM workset ws
        JOIN env ON env.call_stack = ws.call_stack
            AND env.name = ws.expr#>>'{}'
            AND env.value IS NOT NULL
            AND env.frame_pointer <= ws.frame_pointer
        WHERE jsonb_typeof(ws.expr) = 'string'
        ORDER BY ws.call_stack, ws.frame_pointer, ws.expr, env.frame_pointer DESC
    ),

    let_eval(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb) AS (
        SELECT
            ws.call_stack,
            ws.frame_pointer,
            ws.expr,
            body_eval.result
        FROM workset ws
        JOIN resultset body_eval ON body_eval.call_stack = ws.call_stack
            AND body_eval.expr = ws.expr->2
        WHERE jsonb_typeof(ws.expr) = 'array'
            AND ws.expr->>0 = 'let'
    ),

    resultset(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb) AS (
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
    )

SELECT * 
FROM resultset
WHERE frame_pointer = 0;
