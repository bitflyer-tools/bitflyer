# Contributing

## Set up the development environment

Fork this repository on GitHub and clone your fork. Use the Ruby version in
[.ruby-version](.ruby-version) and the Bundler version listed under `BUNDLED WITH`
in [Gemfile.lock](Gemfile.lock). From the repository root, install the dependencies,
including the optional type-checking group:

```sh
bundle config set --local with typecheck
bundle install
```

See the [architecture guide](docs/architecture.md) for the HTTP and realtime
client structure and where to start reading the code.

## Run the checks

Run the same test, lint, and type-check commands used by
[CI](.github/workflows/test.yml):

```sh
bundle exec rspec
bundle exec rubocop lib
bundle exec rake steep
```

## Open a pull request

1. Create a branch in your fork and keep the change focused. Update the tests
   and documentation when you change behavior.
2. Run the checks above and push the branch to your fork.
3. Open a pull request against [bitflyer-tools/bitflyer](https://github.com/bitflyer-tools/bitflyer).
   Explain what changed, why, and how you verified it.

Follow the [code of conduct](CODE_OF_CONDUCT.md) when participating.
