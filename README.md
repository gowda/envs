# Envs

Envs displays variables from an uploaded dotenv file. It uses Rails 8.1 and Ruby 3.4.12.

- Run `bin/setup` to install dependencies and prepare SQLite.
- Run `bin/rails server` to start the app.
- Open the root page and upload a UTF-8 dotenv file of 1 MB or less.
- The app displays variables in file order and preserves literal commands and references.
- The app does not save uploads or load dotenv files into its environment.
- Use invented values in examples and test files. Do not commit secrets.
- Run `bundle exec rspec` to run the specs.
- Run `bin/ci` to run the local checks and specs.

The interface uses vendored Primer CSS 21.5.1 under the MIT licence.
