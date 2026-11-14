# Env file format

This reference explains how envs reads files for people inspecting Docker and Amazon ECS configuration. The same rules apply to uploaded files and S3 snapshots.

## File and line rules

These rules preserve the values a container receives, rather than interpreting the file as a shell script or a dotenv library would.

- The file must use valid UTF-8 and contain at least one entry with `=`.
- The file size limit is 1 MB. The line size limit is 65,536 bytes, without the line ending.
- The reader removes a UTF-8 byte order mark from the first line only.
- The reader removes leading whitespace from each line.
- The reader skips empty lines and lines that start with `#` after leading whitespace.
- The first `=` separates the name from the value.
- The name must not be empty or contain a space or a tab.
- The value is the exact text after `=`, including quotes, spaces, more `=` signs and `#`.
- `KEY=` has an empty value.
- CRLF line endings are accepted. The value does not include the CR.
- Quotes do not join lines. Values cannot span lines.
- Shell commands, variable references and escape sequences stay literal.
- Invalid files show an error. Errors identify the line and reason without showing a value.

## Repeated names

Repeated names remain separate entries in file order. Only the last line with a name takes effect, and only that line is editable in an S3 file.

Earlier lines with that name have an **Overridden** label. A warning gives the line numbers for each repeated name. S3 cards have a **Repeated names** label when the file has repeated names.

## Lines without `=`

A line without `=` is invalid if its name contains a space or a tab after leading whitespace is removed. Other lines without `=` have a warning with their line numbers. The app does not read the host environment.

Docker takes these values from the host environment or drops these lines. ECS gives these lines no value.

## Example

You can save this invented example as `postgres.env` and upload it to see seven variables:

```env
# PostgreSQL container settings
POSTGRES_USER=app
POSTGRES_PASSWORD=invented-password-123
POSTGRES_DB=app_production
POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=C.UTF-8"
POSTGRES_HOST_AUTH_METHOD=scram-sha-256
PGDATA=/var/lib/postgresql/data/pgdata
TZ=UTC
```

The quotes around `POSTGRES_INITDB_ARGS` are part of the value the container receives.
