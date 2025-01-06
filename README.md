# Lisp in SQL: A Materialize-Based Lisp Interpreter

This repository implements a Lisp interpreter in SQL, leveraging Materialize's support for mutual recursion and iterative dataflows. It evaluates Lisp expressions encoded as JSON arrays, pushing the boundaries of what SQL can achieve while showcasing Materialize's unique capabilities.

---

## Overview

This project interprets Lisp expressions entirely in SQL. By combining recursive CTEs with Materialize's fixed-point iteration, it provides a functional interpreter capable of handling arithmetic operations, conditionals, list manipulation, and user-defined functions.

## How It Works

The interpreter operates by iteratively decomposing and evaluating Lisp expressions using recursive SQL queries. Materialize's engine ensures efficient, incremental computation by propagating changes through the dataflow until a fixed point is reached.

### Supported Features

- **Arithmetic Operators:** `+`, `-`, `*`, `/`
- **Comparisons:** `=`, `>`, `<`, `>=`, `<=`
- **Logical Operators:** `and`, `or`, `not`
- **Conditionals:** `if` expressions
- **List Manipulation:** `cons`, `car`, `cdr`
- **User-Defined Functions:** `defun` and function calls
- **Lexical Scoping:** Maintains proper variable environments across nested expressions through `let` bindings.
- **Recursion and Mutual Recursion:** Supports recursive function definitions and their evaluation.


