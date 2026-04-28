#!/bin/bash
python_env/bin/uvicorn main:app --host 0.0.0.0 --port 8000 --reload
