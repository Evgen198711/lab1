# `mix.exs` and `test/test_helper.exs` explained for a Java developer

## `mix.exs` — 14 lines

`Mix` is Elixir's project/build tool, somewhat like **Maven or Gradle**. `defmodule DistributedPrint.MixProject do` defines build configuration; `use Mix.Project` sets up project DSL/callbacks.

- `def project do ... end`: returns a keyword list of project settings, similar to `build.gradle` metadata.
- `app: :distributed_print`: OTP application name (an atom).
- `version: "0.1.0"`: version string.
- `elixir: "~> 1.15"`: compatible Elixir version requirement, not a Java language level.
- `start_permanent: Mix.env() == :prod`: production mode setting.
- `deps: []`: no external Mix dependencies; standard libraries still used.
- `def application, do: [extra_applications: [:logger]]`: starts the standard logger OTP application.

Java analogy: Gradle project metadata, dependency list, application setup. `mix compile` compiles code; `mix test` runs ExUnit; `mix run` executes the app.

## `test/test_helper.exs` — line 1

`ExUnit.start(exclude: [:distributed])`

Like a JUnit tag filter: starts the test framework and **excludes distributed-tagged tests from the default suite**. Therefore ordinary `mix test` runs the four local tests only. To run the separate five-node suite, explicitly include its tag and start the prerequisite nodes.

## `.ex` vs `.exs`

`.ex` = usual compiled source files; `.exs` = Elixir script files, often tests and Mix configuration. There is no Java `public static void main` required for every file.
