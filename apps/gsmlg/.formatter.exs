[
  import_deps: [:ecto],
  inputs: ["*.{ex,exs}", "priv/*/seeds.exs", "{lib,test}/**/*.{ex,exs}"],
  subdirectories: ["priv/*/migrations"]
]
