# Suppress Winch Events from Web Server Output

## Goal

Discard Gunicorn `winch` signal events so they appear neither on the terminal nor in `log/backend.log`.

## Design

Add a dedicated shell function in `serve` that filters the web server output stream before it reaches the existing `colorize` function. The function will remove only lines that identify a `winch` signal event and will pass every other line through unchanged.

The web server pipeline will become:

`gunicorn output -> filter_winch_events -> colorize -> terminal and backend.log`

`colorize` remains responsible only for labeling and mirroring output. Caddy logging and all non-web streams are unchanged.

## Error Handling

The filter is line-oriented and introduces no persistent state. Unrecognized lines, including malformed or non-Gunicorn output, are preserved rather than discarded.

## Testing

Add focused coverage that verifies a winch event is removed and an ordinary Gunicorn log line passes through unchanged.
