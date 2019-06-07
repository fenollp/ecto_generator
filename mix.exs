defmodule EctoGenerator.Mixfile do
  use Mix.Project

  def project,
    do: [
      app: :ecto_generator,
      version: "10.0.0",
      elixir: "~> 1.8",
      package: package(),
      aliases: aliases(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]

  def application, do: [extra_applications: [:logger]]

  defp aliases,
    do: [
      compile: ["format", "compile"]
    ]

  defp deps,
    do: [
      {:inflex, "~> 1.10"},
      {:ex_doc, "~> 0.14", only: :dev, runtime: false}
    ]

  defp package,
    do: [
      name: :ecto_generator,
      description: "Generate Ecto schemas from existing database in Phoenix - Elixir",
      files: ["lib", "config", "mix.exs", "README*"],
      maintainers: ["Bagu Alexandru Bogdan"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/alexandrubagu/ecto_generator",
        "Docs" => "https://github.com/alexandrubagu/ecto_generator",
        "Website" => "http://www.alexandrubagu.info"
      }
    ]
end
