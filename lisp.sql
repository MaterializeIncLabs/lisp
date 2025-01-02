
WITH MUTUALLY RECURSIVE 
    expressions (prog_id int, depth int, expr jsonb) AS (
        SELECT id, 0, program
        FROM lisp_programs

        UNION ALL 

        SELECT prog_id, depth + 1, nested_expr
        FROM expressions
        CROSS JOIN LATERAL jsonb_array_elements(expr) AS nested_expr
        WHERE jsonb_typeof(expr) = 'array'
            AND expr->>0 <> 'if'
        
        UNION ALL 

        SELECT prog_id, depth + 1, expr->1
        FROM expressions
        WHERE jsonb_typeof(expr) = 'array'
            AND expr->>0 = 'if'

        UNION ALL

        SELECT prog_id, depth + 1, branch
        FROM if_branch
    ),

    if_branch(prog_id int, depth int, expr jsonb, branch jsonb) AS (
        SELECT 
            e.prog_id,
            e.depth,
            e.expr,
            CASE cond.result::boolean 
                WHEN TRUE THEN e.expr->2
                ELSE e.expr->3
            END
        FROM eval e
        JOIN eval cond ON e.prog_id = cond.prog_id 
            AND e.expr->1 = cond.expr
            AND cond.result IS NOT NULL
        WHERE jsonb_typeof(e.expr) = 'array'
            AND e.expr->>0 = 'if'
            AND e.result IS NULL
    ),

    env(prog_id int, depth int, name text, value jsonb) AS (
        SELECT 
            e.prog_id,
            e.depth + 1,
            binding->>0,
            v.result
        FROM eval e
        CROSS JOIN LATERAL jsonb_array_elements(e.expr->1) AS binding(expr)
        JOIN eval v ON v.prog_id = e.prog_id 
            AND v.expr = binding->1
            AND v.result IS NOT NULL
        WHERE e.expr->>0 = 'let'
    ),

    eval(prog_id int, depth int, expr jsonb, result jsonb) AS (
        -- Initialize evaluation 
        SELECT prog_id, depth, expr, NULL::jsonb
        FROM expressions

        UNION 
    
        -- Literals evaluate to themselves
        SELECT prog_id, depth, expr, expr
        FROM eval
        WHERE jsonb_typeof(expr) in ('number', 'boolean', 'null')
            AND result IS NULL

        UNION 

        -- Built in operators
        SELECT
            e.prog_id,
            e.depth,
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
        JOIN eval arg1 ON e.prog_id = arg1.prog_id
            AND e.expr->1 = arg1.expr
            AND arg1.result IS NOT NULL
        JOIN eval arg2 ON e.prog_id = arg2.prog_id
            AND e.expr->2 = arg2.expr
            AND arg2.result IS NOT NULL
        WHERE jsonb_typeof(e.expr) = 'array'
            AND e.expr->>0 IN ('+', '-', '*', '/', '=', '>', '>=', '<', '<=')
            AND e.result IS NULL

        UNION
    
        -- built in boolean binary operators
        SELECT
            e.prog_id,
            e.depth,
            e.expr,
            CASE e.expr->>0
                WHEN 'and' THEN to_jsonb(arg1.result::boolean AND arg2.result::boolean)
                WHEN 'or'  THEN to_jsonb(arg1.result::boolean OR  arg2.result::boolean)
            END
        FROM eval e
        JOIN eval arg1 ON e.prog_id = arg1.prog_id
            AND e.expr->1 = arg1.expr
            AND arg1.result IS NOT NULL
        JOIN eval arg2 ON e.prog_id = arg2.prog_id
            AND e.expr->2 = arg2.expr
            AND arg2.result IS NOT NULL
        WHERE jsonb_typeof(e.expr) = 'array'
            AND e.expr->>0 IN ('and', 'or')
            AND e.result IS NULL

        UNION 

        -- built in boolean unary operators
        SELECT
            e.prog_id,
            e.depth,
            e.expr,
            to_jsonb(NOT (arg.result::boolean))
        FROM eval e
        JOIN eval arg ON e.prog_id = arg.prog_id
            AND e.expr->1 = arg.expr
            AND arg.result IS NOT NULL
        WHERE jsonb_typeof(e.expr) = 'array'
            AND e.expr->>0 IN ('not')
            AND e.result IS NULL

        UNION 

        -- quote special form
        SELECT prog_id, depth, expr, expr->1
        FROM eval
        WHERE jsonb_typeof(expr) = 'array'
            AND result IS NULL
            AND expr->>0 = 'quote'

        UNION 
    
        -- cons special form
        SELECT
            e.prog_id,
            e.depth,
            e.expr,
            arg1.result || arg2.result
        FROM eval e
        JOIN eval arg1 ON arg1.prog_id = e.prog_id 
            AND arg1.expr = e.expr->1
            AND arg1.result IS NOT NULL
        JOIN eval arg2 ON arg2.prog_id = e.prog_id 
            AND arg2.expr = e.expr->2
            AND arg2.result IS NOT NULL
        WHERE jsonb_typeof(e.expr) = 'array'
            AND e.result IS NULL
            AND e.expr->>0 = 'cons'

        UNION 

        -- car and cdr special form
        SELECT
            e.prog_id,
            e.depth,
            e.expr,
            CASE e.expr->>0
                WHEN 'car' THEN arg.result->0
                WHEN 'cdr' THEN arg.result->1
            END
        FROM eval e
        JOIN eval arg ON arg.prog_id = e.prog_id 
            AND arg.expr = e.expr->1
            AND arg.result IS NOT NULL
        WHERE jsonb_typeof(e.expr) = 'array'
            AND e.result IS NULL
            AND e.expr->>0 IN ('car', 'cdr')

        UNION 

        -- If statements
        -- - Join the result of evaulating the branch back to the top level if statement
        SELECT 
            if_branch.prog_id,
            if_branch.depth,
            if_branch.expr,
            branch.result
        FROM if_branch 
        JOIN eval branch ON if_branch.prog_id = branch.prog_id
            AND if_branch.branch = branch.expr
            AND branch.result IS NOT NULL

        UNION

        SELECT prog_id, depth, expr, value FROM (
            SELECT DISTINCT ON (e.prog_id, e.depth, e.expr)
                e.prog_id,
                e.depth,
                e.expr,
                env.value
            FROM eval e
            JOIN env ON env.prog_id = e.prog_id
                AND env.name = e.expr#>>'{}'
                AND env.depth <= e.depth
            WHERE jsonb_typeof(e.expr) = 'string'
                AND e.result IS NULL
            ORDER BY e.prog_id, e.depth, e.expr, env.depth DESC
        )
    
        UNION 

        -- Let special form
        SELECT
            e.prog_id,
            e.depth,
            e.expr,
            body_eval.result
        FROM eval e
        JOIN eval body_eval 
            ON body_eval.prog_id = e.prog_id
            AND body_eval.expr = e.expr->2
            AND body_eval.result IS NOT NULL
        WHERE jsonb_typeof(e.expr) = 'array'
            AND e.expr->>0 = 'let'
            AND e.result IS NULL
    )

SELECT * FROM eval WHERE depth = 0 AND result IS NOT NULL;

