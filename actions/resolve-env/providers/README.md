# resolve-env providers

Each file here is a **plugin** for the `resolve-env` action. The provider is selected per
env via `SECRETS_PROVIDER=<name>` in that env's `tf-ci.env` (or the `secrets_provider`
workflow input). `resolve-env.sh` sources `providers/<name>.sh` and calls its functions.

## Add a provider

Drop `providers/<name>.sh` defining:

```sh
# required: echo the resolved value for a bare ref ($1) to stdout, or return non-zero.
provider_resolve() {
  _ref="$1"
  # ... fetch and print the secret ...
}

# optional: preflight (deps present, config set). Return non-zero to abort.
provider_check() { command -v mytool >/dev/null 2>&1; }
```

That's the whole contract. `resolve-env.sh` handles reading `tf-ci.env`, matching
`KEY=${ref}` placeholders, masking (`::add-mask::`), and writing the file back in place.

Rules:
- POSIX sh, no bashisms (the action runs under `sh`).
- Print **only** the secret value on stdout; send logs to stderr (`>&2`).
- Prefix helper vars with `_` to avoid clashing with the caller.
- Read config from the environment (forward it in `action.yml` + the reusable workflow).

## Shipped providers

| name     | ref form                        | needs                          | pre-OIDC? |
|----------|---------------------------------|--------------------------------|-----------|
| `github` | `${VARIABLE_OR_SECRET_NAME}`    | `toJSON(vars)`/`toJSON(secrets)` | yes     |
| `awssm`  | `${secret-id[#json-field]}`     | assumed-role AWS creds         | no (needs role first) |

`pre-OIDC?` = whether it can resolve the OIDC identity fields (`AWS_ROLE_ARN`,
`AWS_REGION`) in the resolve job. `awssm` needs the role first, so keep those literal or
use `github` for them.
