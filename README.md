# envs

envs displays variables from S3 env files and uploaded env files. It uses Rails 8.1 and Ruby 3.4.12.

- Run `bin/setup` to install dependencies and prepare SQLite.
- Run `bin/rails server` to start the app.
- The root page redirects to `/files`.
- Open `/s3` to view local snapshots of S3 files.
- Select **Refresh from S3** to fetch the current files and remove snapshots of deleted files.
- Select a file card to view its variables.
- Open `/files` to select or drop a UTF-8 env file of 1 MB or less.
- The app displays variables in file order and preserves literal commands and references.
- Valid uploads are stored on local disk and redirect to `/files/<public ID>`.
- The disk service stores uploads under `storage/` and test uploads under `tmp/storage/`.
- Uploaded bytes are unencrypted. Encryption and deletion are deferred.
- The app does not list stored uploads or load their variables into its environment.
- The app uses Stimulus through importmap for file selection and drop uploads.
- Use invented values in examples and test files. Do not commit secrets.
- Run `bundle exec rspec` to run the specs.
- Run `bin/ci` to run the local checks and specs.

## Env file rules

The app reads files as Docker and Amazon ECS do. Each entry uses one line.

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
- Repeated names remain separate entries in file order. Only the last line with a name takes effect.
- Earlier lines with that name have an Overridden label. A warning gives the line numbers for each repeated name.
- S3 cards have a Repeated names label when the file has repeated names.
- A line without `=` is invalid if its name contains a space or a tab after leading whitespace is removed.
- Other lines without `=` have a warning with their line numbers. The app does not read the host environment.
- Docker takes these values from the host environment or drops these lines. ECS gives these lines no value.
- Invalid files show an error. Errors identify the line and reason without showing a value.

## S3 settings

Settings and secrets come from environment variables. Restart the app after you change a setting.

| Variable | Purpose |
| --- | --- |
| `ENVS_S3_BUCKET` | Required bucket name. |
| `ENVS_S3_PREFIX` | Optional prefix for the S3 listing. The default is an empty prefix. |
| `AWS_REGION` | AWS region for the bucket. |
| `ENVS_ENCRYPTION_KEY` | Required primary key for Active Record encryption of snapshot content. |

- Configure credentials through the standard AWS credential chain.
- Grant `s3:ListBucket` on the bucket and `s3:GetObject` and `s3:PutObject` on the selected objects.
- Generate an encryption key with `openssl rand -hex 32`.
- Keep the encryption key stable and store it securely. Existing snapshots require the same key.
- The app uses a fixed salt for key derivation. It does not use Rails credentials.
- The test environment uses an invented encryption key.
- The app selects base names that are `.env`, start with `.env.`, or end with `.env`.
- Files over 1 MB have an error label. The app does not download them.
- Invalid files have an error label. Their content stays encrypted in the local snapshot.
- Select **Edit** on a variable to save a local change for that name. Only its last line can be edited.
- Values stay literal. An empty value is valid. A value must use UTF-8 and must not contain CR or LF.
- A Modified label identifies each changed row and file card.
- A Leading or trailing whitespace label identifies values with spaces or tabs at either end.
- Select **Discard changes** to remove all local changes for a file.
- Select **Review & publish** to review the difference, then select **Publish** to write the file to S3.
- Publish preserves the content type, metadata and encryption settings from S3.
- If the S3 ETag changed, publish stops. Refresh the snapshots and review the local changes again.
- Refresh keeps local changes unless their name is gone or its last line already contains the new value.
- Only valid S3 snapshots can be edited. Uploaded files cannot be edited.

The interface uses vendored Primer CSS 21.5.1 under the MIT licence.
