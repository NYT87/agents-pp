# Local dashboard API

`dashboard.sh --serve` binds only to `127.0.0.1`. POST routes require the
per-process `X-RL-Token` embedded in the private served page and a JSON object
body. Missing or incorrect tokens return 403; malformed JSON, invalid scope,
provider or backend names return 400. Unknown routes return 404. Commands use
validated argv arrays without a shell. The static dashboard has no API access.

## Refresh and save catalog: POST /api/models

Request example:

```json
{"backend":"codex","scope":"project","mode":"file","provider":"claude"}
```

`backend` must name an installed backend. Optional `scope` is `project` or
`user`; `mode` is `shared` (default), `section`, or `file`. Section/file mode
requires a valid provider name. Mode/provider cannot be supplied without scope.
These fields have the same meaning as config.sh's scope flags. If scope is
omitted, use the folder of the highest-precedence existing configuration file,
falling back to the project shared location when no config exists.

The route invokes `config.sh models --backend NAME --json` with those scope
flags. It atomically saves `review-loop-models.NAME.json` beside that config
file, without creating or modifying the config itself. It returns 200 with
`{"ok":true,"catalog":{...}}`; the catalog includes models, efforts, defaults,
`catalog_file`, `catalog_version`, backend, and save timestamp. Execution/write
failure returns 422 with `{"ok":false,"output":"..."}`.

This refresh reads the adapter's available catalog. It does not launch an
interactive login or force a provider to fetch new remote models. Codex still
needs its CLI model cache initialized. Empty catalogs include the adapter's
available setup note.

Saved catalogs follow configuration-file precedence when the dashboard is
generated or served. Invalid saved JSON falls back to another valid saved
catalog or the live adapter. Shareable pages continue redacting user defaults.

## Save settings: POST /api/config

The existing request is unchanged:

```json
{"scope":"project","mode":"shared","set":{"model":"example","effort":"high"},"unset":[]}
```

Keys, values, scopes and providers are validated before writing through
`config.sh set/unset`. A key cannot appear in both operations. On success the
200 response now includes `show`, the fresh `config.sh show --json` result, in
addition to `ok` and `output`. `show` resolves the provider selected for editing.
The response also includes `launch_effective`, the effective configuration for
the server's original provider, which `/api/start` uses. Clients keep these
separate so editing another provider cannot change the launch defaults. They
use `show`'s effective values, sources, and file contents to reconcile auto-save
without a page reload.
Execution or readback failure returns 422 with `ok:false`; writes may already
have occurred before readback fails, so clients retain edits and offer an
explicit, idempotent retry rather than repeatedly retrying automatically.

The Configuration page debounces valid edits by 400 ms and serializes requests.
Values changed during an in-flight request remain pending and save afterward.
The destination selector stays locked until a pending save finishes. The Start
page's per-loop choices remain per-loop overrides, not saved global defaults.
After a save, its controls, validation, and command preview refresh against
`launch_effective`, preserving the task and existing per-loop choices. The
copied command and Start request therefore use the same overrides.

## Static pages

Static pages cannot execute scripts or read arbitrary local config paths. They
embed saved catalogs at generation time, and can import a selected catalog file.
Where browser file access is available, choosing a config file once enables
automatic local saves for that target during the page session. Each save reads
the current file and merges only the edited values, preserving other content
and number literals. Invalid JSON is not overwritten. Effective precedence and
inherited values are refreshed when the dashboard is regenerated.
