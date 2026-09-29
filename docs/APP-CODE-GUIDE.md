# Application Code Guide

A walkthrough of every file in `app/`: what each one does, how a calculation flows through them, and why the `templates/` and `tests/` folders exist.

---

## Folder structure

The `app/` folder has 7 files in three groups:

```
app/
├── src/                     ← the application (what runs in production)
│   ├── app.py               ← web server: URLs and responses
│   ├── calculator.py        ← the maths engine
│   └── templates/
│       └── index.html       ← the web page the user sees
├── tests/                   ← automatic checks (never shipped to production)
│   ├── conftest.py          ← test setup
│   ├── test_app.py          ← tests the web server
│   └── test_calculator.py   ← tests the maths engine
├── requirements.txt         ← runtime libraries (flask, gunicorn)
├── requirements-dev.txt     ← test-only libraries (pytest)
├── .dockerignore            ← files kept out of the Docker build
└── Dockerfile               ← how the image is built
```

> **VS Code letters:** **M** means modified since your last commit. **U** means untracked, a new file git doesn't know about yet. They go away after you commit.

---

## How a calculation flows

```
Browser (index.html)            Server (app.py)                 calculator.py
────────────────────            ───────────────                 ─────────────
User clicks 2 + 3 =
  │
  │  POST /api/calculate
  │  {"expression": "2+3"}
  └──────────────────────────►  calculate()
                                  │ evaluate("2+3") ──────────►  parse → check → compute
                                  │ ◄───────────────────────────  5
  ◄──────────────────────────────┘ {"result": 5}
Shows "5" on screen
```

Each file has one job: the page handles display, `app.py` handles HTTP, and `calculator.py` handles the maths.

---

## 1. `src/app.py` — the web server

It uses **Flask**, a small Python web framework. Each `@app.get` or `@app.post` line connects a URL to a function:

| URL | Function | Returns | Who uses it |
|---|---|---|---|
| `GET /` | `index()` | The calculator page (HTML) | The user's browser |
| `POST /api/calculate` | `calculate()` | JSON result or error | The page's JavaScript |
| `GET /api/info` | `info()` | Version, environment, hostname | Jenkins smoke test |
| `GET /health` | `health()` | `{"status":"ok"}` | ECS container health check |

### Configuration from environment variables

```python
APP_VERSION = os.getenv("APP_VERSION", "dev")
ENVIRONMENT = os.getenv("ENVIRONMENT", "local")
```

In AWS, the ECS task definition (`terraform/ecs.tf`) sets `APP_VERSION` to the image tag, for example `abc1234-5`. The same image then shows the right version wherever it runs, with no code change. Locally it falls back to `dev` / `local`.

### The calculate endpoint

```python
@app.post("/api/calculate")
def calculate():
    payload = request.get_json(silent=True) or {}     # read the JSON body; {} if missing or broken
    expression = payload.get("expression")
    try:
        result = evaluate(expression)                  # hand the work to calculator.py
    except CalculationError as exc:
        return jsonify(expression=expression, error=str(exc)), 400   # 400 = "your input was bad"
    return jsonify(expression=expression, result=result, hostname=socket.gethostname())
```

This function doesn't do any maths. It unpacks the request, calls `evaluate()`, and turns the answer or the error into an HTTP response.

Example request and responses:

```
POST /api/calculate   {"expression": "(2 + 3) × 4 ^ 2"}
→ 200 {"expression": "(2 + 3) × 4 ^ 2", "result": 80, "hostname": "ip-10-20-0-15"}

POST /api/calculate   {"expression": "1 / 0"}
→ 400 {"expression": "1 / 0", "error": "Division by zero"}
```

### Why the hostname?

`socket.gethostname()` returns the container's ID. In AWS, every ECS task has a different one, so the page shows which task answered. Each task has its own public IP, so opening each task's URL shows a different hostname.

### Why `/health` must stay simple

ECS calls `/health` inside the container every 30 seconds (the `healthCheck` in `terraform/ecs.tf`). If it fails 3 times in a row, ECS decides the container is broken and replaces it. It should never depend on anything that could be slow or fail.

---

## 2. `src/calculator.py` — the maths engine

This is the most important file for security.

### The problem with `eval`

The easy way to calculate `"2+3*4"` in Python is `eval("2+3*4")`. But `eval` runs *any* Python code. If a user typed:

```
__import__('os').system('rm -rf /')
```

the server would run it. **Never use `eval` on user input.**

### The solution: parse, then whitelist

The expression is parsed into a tree (an AST, or abstract syntax tree), and only arithmetic parts of that tree are allowed:

```
"2 + 3 * 4"   ──ast.parse──►        BinOp(+)
                                   /        \
                            Constant(2)    BinOp(*)
                                           /      \
                                   Constant(3)  Constant(4)
```

`_eval(node)` walks this tree recursively:

```python
if isinstance(node, ast.Constant) and type(node.value) in (int, float):
    return node.value                      # a number → return it

if isinstance(node, ast.UnaryOp) ...:      # -5 → negate

if isinstance(node, ast.BinOp) ...:        # left OP right → compute both sides, apply operator

raise CalculationError("Unsupported expression...")   # ANYTHING else is rejected
```

This is a **whitelist**: only numbers, `+ - * / % **`, negation and brackets get through. Function calls, variable names, strings, lists and `True` are all rejected. Operator precedence (× before +) and brackets come for free from Python's own parser.

### Safety limits

These stop one request from freezing the server:

| Limit | Value | Why |
|---|---|---|
| `MAX_EXPRESSION_LENGTH` | 200 characters | Stops huge inputs |
| `MAX_EXPONENT` | 1000 | `9^9^9` would take forever to compute |
| `MAX_INT_BITS` | 3300 bits (~1000 digits) | Caps result size and JSON output |
| complex-number check | – | `(-8)^0.5` produces an imaginary number, which a calculator can't show |
| overflow / infinity check | – | `10.0^400` is too large for a float |

### Clean-ups

- **`_SYMBOLS`** converts the display symbols into Python operators: `×` → `*`, `÷` → `/`, `−` → `-`, `^` → `**`.
- **`_format()`** fixes floating-point noise. A computer gives `0.1 + 0.2 = 0.30000000000000004`, and this rounds it to `0.3`. It also turns `4.0` into `4`.

### One error type

Every failure raises `CalculationError`, whether it's an empty input, bad syntax, division by zero or a result that's too large. `app.py` then needs only one `except` to turn any bad input into a 400 response with a readable message.

---

## 3. `src/templates/index.html` — the web page

### Why a `templates/` folder?

**It's a Flask convention.** When `app.py` calls:

```python
render_template("index.html", **_info())
```

Flask automatically looks for the file in the `templates/` folder next to `app.py`. The folder name matters: rename it and the page breaks.

### Why a separate HTML file instead of HTML inside Python?

The first version of the app had the HTML as a Python string. That worked for a tiny page, but the calculator has a lot of CSS and JavaScript. A separate file:

- lets VS Code highlight and check HTML, CSS and JS properly;
- keeps Python logic and page design apart, so each is easier to change.

### What "template" means

A template has blanks that Flask fills in using **Jinja** syntax, `{{ ... }}`:

```html
Version <code>{{ version }}</code> · {{ environment }}
Served by task <code>{{ hostname }}</code>
```

Flask replaces these with real values (for example `abc1234-5 · dev`) before sending the page.

### The three parts of the page

1. **CSS** (`<style>`): the dark theme and the 4-column button grid.
2. **HTML**: the display, the buttons and the history panel. Each button carries its meaning in an attribute:
   - `data-value="7"` → adds `7` to the expression
   - `data-action="equals"` → runs the calculation
3. **JavaScript** (`<script>`):

   | Function | What it does |
   |---|---|
   | `input(value)` | Adds a character to the expression |
   | `calculate()` | Sends the expression to `/api/calculate` with `fetch()` and shows the result or error |
   | `addHistory()` | Keeps the last 10 results; clicking one reuses it |
   | `keydown` listener | Keyboard support: digits, `+ - * / % ^ ( )`, Enter, Backspace, Esc |

The browser **doesn't calculate anything itself**. It always asks the server, so the safe evaluator is the only source of answers.

---

## 4. `tests/` — why tests?

**Tests are code that checks your code automatically.** They matter here because nobody watches the Jenkins pipeline click buttons before a deploy. The tests are what stop a broken version from reaching AWS.

### How tests protect the deployment

```
Jenkins "Unit Tests" stage
   └── docker build --target test      ← Dockerfile "test" stage runs: python -m pytest
          ├── all pass  → pipeline continues → Build → Push → Deploy
          └── any fail  → build FAILS → nothing is deployed
```

If you accidentally break division tomorrow, Jenkins stops before touching AWS, and the live app keeps working.

### `conftest.py` — test setup

`pytest` loads this file automatically before any test. It fixes an import problem: the tests say `from app import app` and `from calculator import evaluate`, but those files are in `src/`, not `tests/`. This line adds `src/` to Python's search path:

```python
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
```

Without it, every test fails with `ModuleNotFoundError`.

### `test_calculator.py` — tests the maths directly

It checks the maths without any web server:

```python
@pytest.mark.parametrize("expression, expected", [
    ("2 + 3 * 4", 14),        # operator precedence
    ("(2 + 3) * 4", 20),      # brackets
    ("0.1 + 0.2", 0.3),       # float clean-up
    ("12 × 3", 36),           # UI symbols
    ...
])
def test_valid_expressions(expression, expected):
    assert evaluate(expression) == expected
```

`parametrize` runs the same test once per row, so it's many checks in a few lines.

The invalid list proves the security rules work:

| Input | Must fail with |
|---|---|
| `1 / 0` | Division by zero |
| `__import__('os').system('ls')` | Unsupported |
| `'a' * 3`, `[1, 2]`, `True + 1` | Unsupported |
| `9 ^ 9 ^ 9` | Exponent limit |
| `99999 ^ 999` | Result is too large |
| `(-8) ^ 0.5` | Not a real number |
| 401-character input | Longer than 200 characters |

### `test_app.py` — tests the web layer

Flask's `test_client()` sends fake HTTP requests without starting a real server:

```python
def test_calculate_division_by_zero_is_400(client):
    resp = client.post("/api/calculate", json={"expression": "1 / 0"})
    assert resp.status_code == 400
```

These check that the URLs, status codes and JSON shape are right:

- `/health` returns `200 {"status": "ok"}`. If it broke, AWS would kill every container.
- `/api/info` has version, environment, hostname and start time.
- `/` renders the calculator.
- `/api/calculate` returns results, 400 for bad input or code, and 405 for GET.
- Unknown URLs return 404.

`@pytest.fixture def client()` is shared setup. Any test that takes a `client` argument gets a fresh fake browser.

### Try it yourself

```powershell
docker build --target test app
```

Then break something on purpose, such as changing `operator.add` to `operator.sub` in `calculator.py`, and run it again to watch the build fail.

---

## 5. How the Dockerfile uses all this

```dockerfile
FROM python:3.12-slim AS base      ← installs flask + gunicorn
FROM base AS test                  ← copies src/ AND tests/, runs pytest   (Jenkins: --target test)
FROM base AS runtime               ← copies ONLY src/, runs gunicorn       (pushed to Docker Hub)
```

- The tests run during the build but **aren't included in the production image**. That keeps the image small and leaves test code out of production.
- The runtime image runs as a **non-root user** (`appuser`), so a compromised app has fewer permissions.
- A `HEALTHCHECK` calls `/health` inside the container every 30 seconds.

### Why gunicorn instead of `python app.py`?

Flask's built-in server is only meant for development. **Gunicorn** is built for real traffic: it runs several worker processes and restarts crashed ones.

- `WEB_CONCURRENCY` sets the number of workers (2 by default in the Dockerfile).
- `PORT` sets the listening port (8080).

---

## Summary

| File | One-line purpose |
|---|---|
| `src/app.py` | Maps URLs to functions and speaks HTTP/JSON |
| `src/calculator.py` | Does the maths safely, without `eval` |
| `src/templates/index.html` | The page, which Flask fills with version and hostname |
| `tests/conftest.py` | Lets tests import code from `src/` |
| `tests/test_calculator.py` | Proves the maths and security rules are right |
| `tests/test_app.py` | Proves the web endpoints behave correctly |
| `requirements.txt` / `requirements-dev.txt` | Runtime libraries / test-only libraries |
| `Dockerfile` | Runs tests at build time, ships only `src/` |
| `.dockerignore` | Keeps caches and local files out of the image |
