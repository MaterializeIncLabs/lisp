WITH MUTUALLY RECURSIVE 
    expressions (call_stack bigint list, frame_pointer int, expr jsonb) AS (
        SELECT list[id], 0, program
        FROM lisp_programs

        UNION 

        SELECT call_stack, frame_pointer + 1, nested_expr
        FROM expressions
        CROSS JOIN LATERAL jsonb_array_elements(expr) AS nested_expr
        WHERE jsonb_typeof(expr) = 'array'
            AND expr->>0 NOT IN ('if', 'defun')
        
        UNION 

        SELECT call_stack, frame_pointer + 1, expr->1
        FROM expressions
        WHERE jsonb_typeof(expr) = 'array'
            AND expr->>0 = 'if'

        UNION

        SELECT call_stack, frame_pointer + 1, branch
        FROM if_branch

        UNION 

        SELECT call_stack, frame_pointer + 1, let
        FROM function_call 
    ),

    if_branch(call_stack bigint list, frame_pointer int, expr jsonb, branch jsonb) AS (
        SELECT 
            e.call_stack,
            e.frame_pointer,
            e.expr,
            CASE cond.result::boolean 
                WHEN TRUE THEN e.expr->2
                ELSE e.expr->3
            END
        FROM eval e
        JOIN eval cond ON e.call_stack = cond.call_stack 
            AND e.expr->1 = cond.expr
            AND cond.result IS NOT NULL
        WHERE jsonb_typeof(e.expr) = 'array'
            AND e.expr->>0 = 'if'
            AND e.result IS NULL
    ),

    env(call_stack bigint list, frame_pointer int, name text, value jsonb) AS (
        SELECT 
            e.call_stack,
            e.frame_pointer + 1,
            binding->>0,
            v.result
        FROM eval e
        CROSS JOIN LATERAL jsonb_array_elements(e.expr->1) AS binding(expr)
        JOIN eval v ON v.call_stack = e.call_stack 
            AND v.expr = binding->1
            AND v.result IS NOT NULL
        WHERE e.expr->>0 = 'let'
    ),

    vtable(name text, argument text, body jsonb) AS (
        SELECT
            expr->>1,
            expr->>2,
            expr->3
        FROM eval
        WHERE expr->>0 = 'defun'
    ),

    function_call(call_stack bigint list, frame_pointer int, expr jsonb, let jsonb) AS (
        SELECT DISTINCT
            eval.call_stack || crc32(jsonb_build_array(
                'let', 
                jsonb_build_array(jsonb_build_array(
                    vtable.argument, eval.expr->1
                )), vtable.body)::text)::bigint,
            0,
            jsonb_build_array(vtable.name, arg.result),
            jsonb_build_array(
                'let', 
                jsonb_build_array(jsonb_build_array(
                    vtable.argument, arg.result
                )), vtable.body)
        FROM eval
        JOIN vtable   ON eval.expr->>0 = vtable.name
        JOIN eval arg ON eval.call_stack = arg.call_stack
            AND eval.expr->1 = arg.expr
            AND arg.result IS NOT NULL
        WHERE eval.expr->1 IS NOT NULL
    ),

    eval(call_stack bigint list, frame_pointer int, expr jsonb, result jsonb) AS (
        -- Initialize evaluation 
        SELECT call_stack, frame_pointer, expr, NULL::jsonb
        FROM expressions

        UNION 
    
        -- Literals evaluate to themselves
        SELECT call_stack, frame_pointer, expr, expr
        FROM eval
        WHERE jsonb_typeof(expr) in ('number', 'boolean', 'null')
            AND result IS NULL

        UNION 

        -- Built in operators
        SELECT
            e.call_stack,
            e.frame_pointer,
            e.expr,
            CASE e.expr->>0
                WHEN '+'  THEN to_jsonb(arg1.result::numeric + arg2.result::numeric)
                WHEN '-'  THEN to_jsonb(arg1.result::numeric - arg2.result::numeric)
                WHEN '*'  THEN to_jsonb(arg1.result::numeric * arg2.result::numeric)
                WHEN '/'  THEN to_jsonb(arg1.result::numeric / arg2.result::numeric)
                WHEN '='  THEN to_jsonb(arg1.result::numeric = arg2.result::numeric) 
                WHEN '>=' THEN to_jsonb(arg1.result::numeric >= arg2.result::numeric) 
                WHEN '<=' THEN to_jsonb(arg1.result::numeric <= arg2.result::numeric) 
                WHEN '>'  THEN to_jsonb(arg1.result::numeric > arg2.result::numeric) 
                WHEN '<'  THEN to_jsonb(arg1.result::numeric < arg2.result::numeric)
            END
        FROM eval e
        JOIN eval arg1 ON e.call_stack = arg1.call_stack
            AND e.expr->1 = arg1.expr
            AND arg1.result IS NOT NULL
        JOIN eval arg2 ON e.call_stack = arg2.call_stack
            AND e.expr->2 = arg2.expr
            AND arg2.result IS NOT NULL
        WHERE jsonb_typeof(e.expr) = 'array'
            AND e.expr->>0 IN ('+', '-', '*', '/', '=', '>', '>=', '<', '<=')
            AND e.result IS NULL

        UNION
    
        -- built in boolean binary operators
        SELECT
            e.call_stack,
            e.frame_pointer,
            e.expr,
            CASE e.expr->>0
                WHEN 'and' THEN to_jsonb(arg1.result::boolean AND arg2.result::boolean)
                WHEN 'or'  THEN to_jsonb(arg1.result::boolean OR  arg2.result::boolean)
            END
        FROM eval e
        JOIN eval arg1 ON e.call_stack = arg1.call_stack
            AND e.expr->1 = arg1.expr
            AND arg1.result IS NOT NULL
        JOIN eval arg2 ON e.call_stack = arg2.call_stack
            AND e.expr->2 = arg2.expr
            AND arg2.result IS NOT NULL
        WHERE jsonb_typeof(e.expr) = 'array'
            AND e.expr->>0 IN ('and', 'or')
            AND e.result IS NULL

        UNION 

        -- built in boolean unary operators
        SELECT
            e.call_stack,
            e.frame_pointer,
            e.expr,
            to_jsonb(NOT (arg.result::boolean))
        FROM eval e
        JOIN eval arg ON e.call_stack = arg.call_stack
            AND e.expr->1 = arg.expr
            AND arg.result IS NOT NULL
        WHERE jsonb_typeof(e.expr) = 'array'
            AND e.expr->>0 IN ('not')
            AND e.result IS NULL

        UNION

        -- quote special form
        SELECT call_stack, frame_pointer, expr, expr->1
        FROM eval
        WHERE jsonb_typeof(expr) = 'array'
            AND result IS NULL
            AND expr->>0 = 'quote'

        UNION 
    
        -- cons special form
        SELECT
            e.call_stack,
            e.frame_pointer,
            e.expr,
            arg1.result || arg2.result
        FROM eval e
        JOIN eval arg1 ON arg1.call_stack = e.call_stack 
            AND arg1.expr = e.expr->1
            AND arg1.result IS NOT NULL
        JOIN eval arg2 ON arg2.call_stack = e.call_stack 
            AND arg2.expr = e.expr->2
            AND arg2.result IS NOT NULL
        WHERE jsonb_typeof(e.expr) = 'array'
            AND e.result IS NULL
            AND e.expr->>0 = 'cons'

        UNION 

        -- car and cdr special form
        SELECT
            e.call_stack,
            e.frame_pointer,
            e.expr,
            CASE e.expr->>0
                WHEN 'car' THEN arg.result->0
                WHEN 'cdr' THEN arg.result->1
            END
        FROM eval e
        JOIN eval arg ON arg.call_stack = e.call_stack 
            AND arg.expr = e.expr->1
            AND arg.result IS NOT NULL
        WHERE jsonb_typeof(e.expr) = 'array'
            AND e.result IS NULL
            AND e.expr->>0 IN ('car', 'cdr')

        UNION 

        -- If statements
        -- - Join the result of evaulating the branch back to the top level if statement
        SELECT 
            if_branch.call_stack,
            if_branch.frame_pointer,
            if_branch.expr,
            branch.result
        FROM if_branch 
        JOIN eval branch ON if_branch.call_stack = branch.call_stack
            AND if_branch.branch = branch.expr
            AND branch.result IS NOT NULL

        UNION 

        SELECT
            exec.call_stack, 
            exec.frame_pointer,
            exec.expr, 
            result.result
        FROM eval exec
        JOIN function_call fc ON exec.call_stack = fc.call_stack[:list_length(fc.call_stack) - 1] 
            AND exec.expr->>0 = fc.expr->>0
        JOIN eval result ON  result.expr = fc.let
            AND result.result IS NOT NULL
        WHERE jsonb_typeof(exec.expr) = 'array'

        UNION

        SELECT call_stack, frame_pointer, expr, value FROM (
            SELECT DISTINCT ON (e.call_stack, e.frame_pointer, e.expr)
                e.call_stack,
                e.frame_pointer,
                e.expr,
                env.value
            FROM eval e
            JOIN env ON env.call_stack = e.call_stack
                AND env.name = e.expr#>>'{}'
                AND env.value IS NOT NULL
                AND env.frame_pointer <= e.frame_pointer
            WHERE jsonb_typeof(e.expr) = 'string'
                AND e.result IS NULL
            ORDER BY e.call_stack, e.frame_pointer, e.expr, env.frame_pointer DESC
        )
    
        UNION 

        -- Let special form
        SELECT
            e.call_stack,
            e.frame_pointer,
            e.expr,
            body_eval.result
        FROM eval e
        JOIN eval body_eval 
            ON body_eval.call_stack = e.call_stack
            AND body_eval.expr = e.expr->2
            AND body_eval.result IS NOT NULL
        WHERE jsonb_typeof(e.expr) = 'array'
            AND e.expr->>0 = 'let'
            AND e.result IS NULL
    )

SELECT * 
FROM eval
WHERE frame_pointer = 0 AND result IS NOT NULL;
