[
  plugins: [Phoenix.LiveView.HTMLFormatter, DuskmoonBundler.Formatter],
  import_deps: [:phoenix],
  inputs: ["*.{heex,ex,exs}", "{lib,test}/**/*.{heex,ex,exs}", "assets/**/*.{js,ts,jsx,tsx}"]
]
