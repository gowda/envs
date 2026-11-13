# envs

envs displays variables from S3 dotenv files and uploaded dotenv files. It uses Rails 8.1 and Ruby 3.4.12.

- Run `bin/setup` to install dependencies and prepare SQLite.
- Run `bin/rails server` to start the app.
- The root page redirects to `/files`.
- Open `/s3` to view local snapshots of S3 files.
- Select **Refresh from S3** to fetch the current files and remove snapshots of deleted files.
- Select a file card to view its variables.
- Open `/files` to select or drop a UTF-8 dotenv file of 1 MB or less.
- The app displays variables in file order and preserves literal commands and references.
- Valid uploads are stored on local disk and redirect to `/files/<public ID>`.
- The disk service stores uploads under `storage/` and test uploads under `tmp/storage/`.
- Uploaded bytes are unencrypted. Encryption and deletion are deferred.
- The app does not list stored uploads or load their variables into its environment.
- The app uses Stimulus through importmap for file selection and drop uploads.
- Use invented values in examples and test files. Do not commit secrets.
- Run `bundle exec rspec` to run the specs.
- Run `bin/ci` to run the local checks and specs.

## S3 settings

Settings and secrets come from environment variables. Restart the app after you change a setting.

| Variable | Purpose |
| --- | --- |
| `ENVS_S3_BUCKET` | Required bucket name. |
| `ENVS_S3_PREFIX` | Optional prefix for the S3 listing. The default is an empty prefix. |
| `AWS_REGION` | AWS region for the bucket. |
| `ENVS_ENCRYPTION_KEY` | Required primary key for Active Record encryption of snapshot content. |

- Configure credentials through the standard AWS credential chain.
- Grant `s3:ListBucket` on the bucket and `s3:GetObject` on the selected objects.
- Generate an encryption key with `openssl rand -hex 32`.
- Keep the encryption key stable and store it securely. Existing snapshots require the same key.
- The app uses a fixed salt for key derivation. It does not use Rails credentials.
- The test environment uses an invented encryption key.
- The app selects base names that are `.env`, start with `.env.`, or end with `.env`.
- Files over 1 MB have an error label. The app does not download them.
- Invalid files have an error label. Their content stays encrypted in the local snapshot.
- Refresh replaces local snapshots. Editing and publishing are not available.

The interface uses vendored Primer CSS 21.5.1 under the MIT licence.
