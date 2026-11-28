# Contributing

See the [architecture guide](docs/architecture.md) for an overview of the
clients and where to start reading the code.

## Set up the development environment

Fork this repository on GitHub and clone your fork. Use the Ruby version in
[.ruby-version](.ruby-version) and the Bundler version listed under `BUNDLED WITH`
in [Gemfile.lock](Gemfile.lock). From the repository root, install the dependencies,
including the optional type-checking group:

```sh
bundle config set --local with typecheck
bundle install
```

## Run the checks

Run the same test, formatting, lint, and type-check commands used by
[CI](.github/workflows/test.yml):

```sh
COVERAGE=true bundle exec rspec
bundle exec rubocop --only Layout lib
bundle exec rubocop --except Layout lib
ruby script/generate_realtime_signatures.rb --check
bundle exec rake steep
```

To apply formatting fixes to the library code, run:

```sh
bundle exec rubocop --autocorrect --only Layout lib
```

## Open a pull request

1. Create a branch in your fork and keep the change focused. Update the tests
   and documentation when you change behavior.
2. Run the checks above and push the branch to your fork.
3. Open a pull request against [bitflyer-tools/bitflyer](https://github.com/bitflyer-tools/bitflyer).
   Explain what changed, why, and how you verified it.

Follow the [code of conduct](CODE_OF_CONDUCT.md) when participating.

## Publish the documentation

In the repository's **Settings → Pages**, set the publishing source to
**GitHub Actions**. To run the first deployment after merging the workflow,
open **Actions → pages → Run workflow**, select `master`, and run it.
Subsequent pushes to `master` that change `docs/` or the Pages workflow
trigger a deployment automatically.

## Release a gem

Update `Bitflyer::VERSION` in `lib/bitflyer/version.rb` and refresh
`Gemfile.lock` with `bundle lock`. After the version update is merged and CI
passes, push an annotated `vMAJOR.MINOR.PATCH` tag on that commit. The release
workflow checks that the tag matches the gem version, publishes to RubyGems.org,
and creates a GitHub release with generated notes.
