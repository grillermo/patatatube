import os

# load_dotenv() (called by main.py/converter.py) never overrides an already-set
# var, so pinning this before any test module imports paths/router/main keeps
# the real .env's MEDIA_ROOT (an external volume) from leaking into tests.
os.environ.setdefault("MEDIA_ROOT", ".")
