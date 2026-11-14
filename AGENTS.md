# Project

envs is a web app for viewing env files from uploads and S3 snapshots.
The app supports local edits to S3 snapshots and publishes the changes to S3.

## Stack

- The app uses Rails 8.1.4.1 on Ruby 3.4.12.
- The database is SQLite. The database files are under `storage/`.
- The web server is Puma. The default port is 3000.
- The asset pipeline is Propshaft. The UI uses vendored Primer CSS 21.5.1.
- JavaScript is Stimulus through importmap. The app has no Turbo and no Node.
- Active Storage keeps uploaded files on the local disk, under `storage/`.
- Active Record encryption protects the S3 snapshots. The key is `ENVS_ENCRYPTION_KEY`.
- The S3 client is `aws-sdk-s3`. The settings are `ENVS_S3_BUCKET`, `ENVS_S3_PREFIX` and `AWS_REGION`.
- The app has no Action Mailer, Action Cable or job queue.
- The repository is public.

## Commands

- `.ruby-version` selects the Ruby version.
- Set up the app without starting the server: `bin/setup --skip-server`.
- Start the server: `bin/rails server`.
- Before the first spec run, prepare the test database: `RAILS_ENV=test bin/rails db:prepare`.
- Run the specs: `bundle exec rspec --fail-fast`.
- Run the local checks and specs: `bin/ci`.
- For a Ruby change, run Brakeman: `bin/brakeman --no-pager`.
- For a Ruby change, run the gem audit: `bin/bundler-audit`.

## Layout

- `/` redirects to `/files`.
- `/files` is the upload page. `/files/<public id>` shows a stored upload.
- `/s3` lists the S3 snapshots as cards. `/s3/<id>` shows one file.
- `EnvFileContents` reads an env file and holds the validity rules for every source.
- `variables/_list` renders the variable list for every source.
- `/s3/<id>/edits?name=<name>` is the edit page of one variable.
- `/s3/<id>/review` shows the difference before a publish.
- `PendingEdit` holds a local change.
- `EnvFileRewrite` applies the changes to the snapshot text.
- `EnvFilePublish` writes the file to S3.

## Product rules

- The app does not use Rails credentials. Every setting and secret comes from an environment variable.
- Do not run `bin/rails credentials:edit`.
- The app reads an env file the way Docker and Amazon ECS do.
- The value is the text after the first `=`, exactly as written.
- Quotes, spaces and `#` are part of the value.
- A value does not span lines.
- Do not add the `dotenv` gem.
- The identity of a variable is its name.
- Do not identify a variable by a line number.
- If a name is repeated, only the last line with that name takes effect.
- If a name is repeated, only the last line with that name is editable.
- The app warns the user about a repeated name.
- Only an S3 file is editable.
- An edit changes the value of one line and nothing else.
- An edit does not add or remove a line.
- A publish uses the stored ETag as a condition.
- A publish repeats the content type, the metadata and the encryption settings of the object.
- A value does not go into a URL or into the log.
- The app uses as little JavaScript as possible.
- Every script is a Stimulus controller, loaded through importmap.
- Do not add an inline script, Turbo or Node.
- If the prompt does not name a Stimulus controller, do not add one.
- The brand name in the UI is `envs`, in lowercase.
- Active Storage stores uploaded files on the local disk.
- Encryption and deletion of stored uploads are deferred.
- If the prompt does not request encryption or deletion of stored uploads, do not add them.
- The UI follows the GitHub look through vendored Primer CSS.
- Do not commit a real `.env` file, a key file or a real secret.
- The app has no login, no users table and no permission rules.
- An external system supplies the user identity and the permission set.

## Documentation

- `README.md` and `docs/` are for people and use prose.
- `AGENTS.md` is for agents.
- `README.md` is the front door.
- `docs/env-file-format.md` holds the rules of the reader.
- `docs/s3.md` holds the S3, edit and publish details.
- These files use the invented `postgres.env` example from `README.md`.
- `docs/images/variables.png` shows that example.
- If the behaviour of the app changes, update the matching documentation in the same change.
- If the variable list changes, make the screenshot again.

## Tests

- Specs use a stubbed S3 client.
- Do not call a real AWS endpoint.
- Every fixture and example uses invented values.
- The specs need no external datastore.
